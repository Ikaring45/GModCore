import Testing
@testable import GModEngine

@Suite("Deterministic Source length physics constraints")
struct SourcePhysicsLengthConstraintTests {
    @Test("flexible rope clamps a dynamic body to the immutable world body")
    func dynamicBodyToStaticWorld() throws {
        let worldID = try bodyID(entry: 0, serial: 1)
        let propID = try bodyID(entry: 120, serial: 9)
        let scene = try SourceDeterministicPhysicsStaticScene(
            bodyID: worldID,
            geometry: staticFloor(),
            contents: .solid
        )
        let environment = SourceDeterministicPhysicsEnvironment(
            configuration: try .init(gravity: .zero),
            staticCollisionScene: scene
        )
        let constraintID = try SourcePhysicsConstraintID(rawValue: 91)
        let creation = try SourcePhysicsLengthConstraintCreationCommand(
            constraintID: constraintID,
            reference: SourcePhysicsLengthConstraintEndpoint(
                bodyID: worldID,
                kind: .staticWorld,
                localAnchor: SourceVector3(0, 0, 5)
            ),
            attached: SourcePhysicsLengthConstraintEndpoint(
                bodyID: propID,
                kind: .body,
                localAnchor: .zero
            ),
            minimumLength: 0,
            maximumLength: 10
        )
        let snapshot = try environment.execute(
            SourcePhysicsCommandBatch(commands: [
                SourcePhysicsCommand(
                    sequence: 1,
                    payload: .createBody(try bodyCreation(
                        bodyID: propID,
                        origin: SourceVector3(20, 0, 5)
                    ))
                ),
                SourcePhysicsCommand(
                    sequence: 2,
                    payload: .createLengthConstraint(creation)
                ),
                SourcePhysicsCommand(
                    sequence: 3,
                    payload: .simulate(.init(simulationTick: 1))
                ),
            ])
        )

        let prop = try #require(snapshot.bodies.first)
        #expect(abs(prop.transform.origin.x - 10) < 0.001)
        #expect(snapshot.lengthConstraints == [
            SourcePhysicsLengthConstraintSnapshot(
                creation: creation,
                simulationTick: 1
            ),
        ])
        #expect(snapshot.fixedConstraints.isEmpty)
    }

    @Test("positive break limit remains an explicit unsupported boundary")
    func breakableConstraintIsNotApproximated() throws {
        let first = try bodyID(entry: 121, serial: 1)
        let second = try bodyID(entry: 122, serial: 1)
        let constraintID = try SourcePhysicsConstraintID(rawValue: 92)
        let creation = try SourcePhysicsLengthConstraintCreationCommand(
            constraintID: constraintID,
            reference: SourcePhysicsLengthConstraintEndpoint(
                bodyID: first,
                kind: .body,
                localAnchor: .zero
            ),
            attached: SourcePhysicsLengthConstraintEndpoint(
                bodyID: second,
                kind: .body,
                localAnchor: .zero
            ),
            minimumLength: 0,
            maximumLength: 8,
            forceLimitKilogramInchesPerSecond: 1
        )
        let environment = SourceDeterministicPhysicsEnvironment(
            configuration: try .init(gravity: .zero)
        )
        #expect(throws: SourceDeterministicPhysicsEnvironment.Error
            .breakableLengthConstraintUnavailable(constraintID)) {
            _ = try environment.execute(SourcePhysicsCommandBatch(commands: [
                SourcePhysicsCommand(
                    sequence: 1,
                    payload: .createBody(try bodyCreation(
                        bodyID: first,
                        origin: .zero
                    ))
                ),
                SourcePhysicsCommand(
                    sequence: 2,
                    payload: .createBody(try bodyCreation(
                        bodyID: second,
                        origin: SourceVector3(8, 0, 0)
                    ))
                ),
                SourcePhysicsCommand(
                    sequence: 3,
                    payload: .createLengthConstraint(creation)
                ),
            ]))
        }
    }

    @Test("an off-center rope impulse matches analytical mass and inertia", arguments: [false, true])
    func offCenterImpulse(reverseEndpoints: Bool) throws {
        let fixed = try bodyCreation(bodyID: bodyID(entry: 121, serial: 1),
            origin: .zero, motion: .staticBody)
        let moving = try bodyCreation(bodyID: bodyID(entry: 122, serial: 1),
            origin: SourceVector3(10, -2, 0), velocity: SourceVector3(4, 0, 0))
        let snapshot = try simulate(
            fixed, moving, attachedAnchor: SourceVector3(0, 2, 0),
            reverseEndpoints: reverseEndpoints
        )
        let result = try body(moving.bodyID, in: snapshot)
        // K = 1/m + (r x n)^2 / Izz = 0.1 + 4/5. The endpoint,
        // not its COM, must have zero outward speed after J = 4/K.
        let impulse: Float = 4 / (0.1 + 4 / 5)
        expectVector(result.linearVelocity, SourceVector3(4 - impulse / 10, 0, 0))
        expectVector(result.angularVelocity, SourceVector3(0, 0, 2 * impulse / 5 * 180 / .pi))
        expectVector(anchorVelocity(result, localAnchor: SourceVector3(0, 2, 0)), .zero)
        expectVector(try body(fixed.bodyID, in: snapshot).transform.origin, .zero)
    }

    @Test("rotated principal inertia and authored COM determine the rope torque")
    func rotatedAuthoredCenter() throws {
        let fixed = try bodyCreation(bodyID: bodyID(entry: 121, serial: 1),
            origin: .zero, motion: .staticBody)
        // Roll +90 maps local +Y to world +Z and local +Z to world -Y.
        // COM is (10,0,-2); attachment is (10,0,0); model origin is neither.
        let moving = try bodyCreation(bodyID: bodyID(entry: 122, serial: 1),
            origin: SourceVector3(8, 1, 1), angles: SourceQAngle(roll: 90),
            center: SourceVector3(2, -3, 1), inertia: SourceVector3(2, 4, 8),
            velocity: SourceVector3(4, 0, 0))
        let anchor = SourceVector3(2, -1, 1)
        let snapshot = try simulate(fixed, moving, attachedAnchor: anchor)
        let result = try body(moving.bodyID, in: snapshot)
        let impulse: Float = 4 / (0.1 + 4 / 8)
        expectVector(result.linearVelocity, SourceVector3(4 - impulse / 10, 0, 0))
        expectVector(result.angularVelocity, SourceVector3(0, 0, 2 * impulse / 8 * 180 / .pi))
        expectVector(anchorVelocity(result, localAnchor: anchor), .zero)
        expectVector(result.massProperties.worldMassCenter(for: result.transform), SourceVector3(10, 0, -2))
        #expect(result.massProperties.massCenterLocal == moving.massProperties.massCenterLocal)
    }

    @Test("pure angular endpoint motion produces tension without COM separation speed")
    func pureAngularEndpointVelocity() throws {
        let fixed = try bodyCreation(bodyID: bodyID(entry: 121, serial: 1),
            origin: .zero, motion: .staticBody)
        let moving = try bodyCreation(bodyID: bodyID(entry: 122, serial: 1),
            origin: SourceVector3(10, -2, 0), angularVelocity: SourceVector3(0, 0, -120))
        let anchor = SourceVector3(0, 2, 0)
        let snapshot = try simulate(fixed, moving, attachedAnchor: anchor)
        let result = try body(moving.bodyID, in: snapshot)
        let worldAnchor = result.transform.transformPointFromLocal(anchor)
        let direction = worldAnchor / worldAnchor.length
        #expect(result.linearVelocity.x < 0)
        #expect(result.angularVelocity.z > -120)
        #expect(abs(anchorVelocity(result, localAnchor: anchor).dot(direction)) < 0.0001)
        let initialEnergy = Float(0.5 * 5) * pow2(120 * .pi / 180)
        let energy = Float(0.5 * 10) * result.linearVelocity.lengthSquared +
            Float(0.5 * 5) * pow2(result.angularVelocity.z * .pi / 180)
        #expect(energy < initialEnergy)
    }

    @Test("two off-center bodies share tension and preserve linear momentum")
    func twoDynamicEndpoints() throws {
        let first = try bodyCreation(bodyID: bodyID(entry: 121, serial: 1),
            origin: SourceVector3(0, -1, 0), mass: 2, inertia: SourceVector3(4, 4, 4),
            velocity: SourceVector3(0, 3, 0))
        let second = try bodyCreation(bodyID: bodyID(entry: 122, serial: 1),
            origin: SourceVector3(10, -2, 0), velocity: SourceVector3(4, 3, 0))
        let firstAnchor = SourceVector3(0, 1, 0)
        let secondAnchor = SourceVector3(0, 2, 0)
        let snapshot = try simulate(first, second, referenceAnchor: firstAnchor, attachedAnchor: secondAnchor)
        let a = try body(first.bodyID, in: snapshot)
        let b = try body(second.bodyID, in: snapshot)
        let inverseEffectiveMass: Float = 0.5 + 0.1 + 0.25 + 0.8
        let impulse: Float = 4 / inverseEffectiveMass
        expectVector(a.linearVelocity, SourceVector3(impulse / 2, 3, 0))
        expectVector(b.linearVelocity, SourceVector3(4 - impulse / 10, 3, 0))
        expectVector(a.angularVelocity, SourceVector3(0, 0, -impulse / 4 * 180 / .pi))
        expectVector(b.angularVelocity, SourceVector3(0, 0, 2 * impulse / 5 * 180 / .pi))
        expectVector(a.linearVelocity * 2 + b.linearVelocity * 10, SourceVector3(40, 36, 0))
        expectVector(anchorVelocity(a, localAnchor: firstAnchor), anchorVelocity(b, localAnchor: secondAnchor))
        // Translation projection retains total COM, including free drift.
        expectVector(a.transform.origin * 2 + b.transform.origin * 10,
            (first.transform.origin * 2 + second.transform.origin * 10) + SourceVector3(40, 36, 0) * 0.015)
    }

    @Test("kinematic rotation supplies point velocity but receives no rope impulse")
    func rotatingKinematicEndpoint() throws {
        let driven = try bodyCreation(bodyID: bodyID(entry: 121, serial: 1),
            origin: SourceVector3(-1, 0, 0), center: SourceVector3(1, 0, 0),
            angularVelocity: SourceVector3(0, 0, 6_000), motion: .kinematicBody)
        let moving = try bodyCreation(bodyID: bodyID(entry: 122, serial: 1), origin: SourceVector3(10, 1, 0))
        let snapshot = try simulate(driven, moving, referenceAnchor: SourceVector3(2, 0, 0))
        let a = try body(driven.bodyID, in: snapshot)
        let b = try body(moving.bodyID, in: snapshot)
        expectVector(a.transform.origin, SourceVector3(0, -1, 0))
        expectVector(a.angularVelocity, driven.angularVelocity)
        expectVector(a.linearVelocity, .zero)
        // +Z 6000 deg/s around the COM, at world lever arm (0,1,0).
        expectVector(b.linearVelocity, SourceVector3(-6_000 * .pi / 180, 0, 0), tolerance: 0.001)
        expectVector(b.angularVelocity, .zero)
    }

    @Test("motion-disabled endpoints cannot contribute stale stored velocities")
    func motionDisabledEndpoint() throws {
        let fixed = try bodyCreation(bodyID: bodyID(entry: 121, serial: 1),
            origin: .zero, velocity: SourceVector3(-100, 0, 0), angularVelocity: SourceVector3(0, 0, 90))
        let moving = try bodyCreation(bodyID: bodyID(entry: 122, serial: 1), origin: SourceVector3(10, 0, 0))
        let environment = SourceDeterministicPhysicsEnvironment(configuration: try .init(gravity: .zero))
        let snapshot = try environment.execute(SourcePhysicsCommandBatch(commands: [
            .init(sequence: 1, payload: .createBody(fixed)),
            .init(sequence: 2, payload: .createBody(moving)),
            .init(sequence: 3, payload: .mutateBody(try .init(bodyID: fixed.bodyID, mutation: .setMotionEnabled(false)))),
            .init(sequence: 4, payload: .mutateBody(try .init(bodyID: fixed.bodyID, mutation: .setLinearVelocity(fixed.linearVelocity)))),
            .init(sequence: 5, payload: .mutateBody(try .init(bodyID: fixed.bodyID, mutation: .setAngularVelocity(fixed.angularVelocity)))),
            .init(sequence: 6, payload: .mutateBody(try .init(bodyID: fixed.bodyID, mutation: .wake))),
            .init(sequence: 7, payload: .createLengthConstraint(try lengthConstraint(fixed, moving))),
            .init(sequence: 8, payload: .simulate(.init(simulationTick: 1)))
        ]))
        let result = try body(moving.bodyID, in: snapshot)
        expectVector(result.linearVelocity, .zero)
        expectVector(result.angularVelocity, .zero)
        let frozen = try body(fixed.bodyID, in: snapshot)
        expectVector(frozen.transform.origin, .zero)
        expectVector(frozen.linearVelocity, fixed.linearVelocity)
        expectVector(frozen.angularVelocity, fixed.angularVelocity)
        #expect(!frozen.isMotionEnabled)
        #expect(frozen.isSleeping)
    }

    @Test("flexible limits do not resist permitted motion; rigid limits resist both signs")
    func unilateralAndRigidLimits() throws {
        let fixed = try bodyCreation(bodyID: bodyID(entry: 121, serial: 1), origin: .zero, motion: .staticBody)
        // origin, speed, min, max, expected position after integration/projection, expected speed
        let cases: [(Float, Float, Float, Float, Float, Float)] = [
            (9, 6, 0, 10, 9.09, 6),       // slack, separating freely
            (9, -6, 0, 10, 8.91, -6),     // slack, closing freely
            (11, -6, 0, 10, 10, -6),      // already stretched but closing: no push
            (9.91, 6, 0, 10, 10, 0),      // exactly taut: no one-tick velocity leak
            (10.09, -6, 0, 10, 10, -6),   // exactly taut but closing
            (3, 6, 4, 10, 4, 6),         // below lower limit but leaving it
            (4.09, -6, 4, 10, 4, 0),     // lower limit resists compression
            (10.09, -6, 10, 10, 10, 0),  // rigid resists compression
            (9.91, 6, 10, 10, 10, 0),    // rigid resists extension
        ]
        for (x, speed, minimum, maximum, resultX, resultSpeed) in cases {
            let moving = try bodyCreation(bodyID: bodyID(entry: 122, serial: 1), origin: SourceVector3(x, 0, 0),
                velocity: SourceVector3(speed, 0, 0))
            let snapshot = try simulate(fixed, moving, minimum: minimum, maximum: maximum)
            let result = try body(moving.bodyID, in: snapshot)
            expectVector(result.transform.origin, SourceVector3(resultX, 0, 0))
            expectVector(result.linearVelocity, SourceVector3(resultSpeed, 0, 0))
            expectVector(result.angularVelocity, .zero)
        }
    }

    @Test("a quietly hanging rope body sleeps and is not awakened by idle solver passes")
    func hangingBodyCanSleep() throws {
        let fixed = try bodyCreation(bodyID: bodyID(entry: 121, serial: 1), origin: .zero, motion: .staticBody)
        let moving = try bodyCreation(bodyID: bodyID(entry: 122, serial: 1),
            origin: SourceVector3(0, 0, -10), gravity: true)
        let environment = SourceDeterministicPhysicsEnvironment(configuration: try .init(sleepAfterSettledTicks: 3))
        var commands: [SourcePhysicsCommand] = [
            .init(sequence: 1, payload: .createBody(fixed)),
            .init(sequence: 2, payload: .createBody(moving)),
            .init(sequence: 3, payload: .createLengthConstraint(try lengthConstraint(fixed, moving)))
        ]
        for tick in UInt64(1)...6 {
            commands.append(.init(sequence: tick + 3, payload: .simulate(.init(simulationTick: tick))))
        }
        let snapshot = try environment.execute(SourcePhysicsCommandBatch(commands: commands))
        let result = try body(moving.bodyID, in: snapshot)
        #expect(result.isSleeping)
        expectVector(result.transform.origin, moving.transform.origin)
        expectVector(result.linearVelocity, .zero)
    }

    @Test("overflowing world anchors reject constraint creation atomically")
    func overflowingAnchorRollsBackCreation() throws {
        let first = try bodyCreation(bodyID: bodyID(entry: 121, serial: 1), origin: .zero, motion: .staticBody)
        let second = try bodyCreation(bodyID: bodyID(entry: 122, serial: 1), origin: SourceVector3(.greatestFiniteMagnitude, 0, 0))
        let environment = SourceDeterministicPhysicsEnvironment()
        let before = try environment.execute(SourcePhysicsCommandBatch(commands: [
            .init(sequence: 1, payload: .createBody(first)), .init(sequence: 2, payload: .createBody(second))
        ]))
        let constraint = try lengthConstraint(first, second, attachedAnchor: SourceVector3(.greatestFiniteMagnitude, 0, 0))
        #expect(throws: SourceDeterministicPhysicsEnvironment.Error.nonFiniteConstraintResult(constraint.constraintID)) {
            _ = try environment.execute(SourcePhysicsCommandBatch(commands: [
                .init(sequence: 3, payload: .createLengthConstraint(constraint))
            ]))
        }
        let after = try environment.execute(SourcePhysicsCommandBatch(commands: [
            .init(sequence: 3, payload: .mutateBody(try .init(bodyID: second.bodyID, mutation: .wake)))
        ]))
        #expect(after.bodies == before.bodies)
        #expect(after.lengthConstraints.isEmpty)
    }

    @Test("non-finite constraint impulses roll back poses, velocities and FIFO sequence")
    func overflowingImpulseRollsBackStep() throws {
        let first = try bodyCreation(bodyID: bodyID(entry: 121, serial: 1), origin: .zero, motion: .staticBody)
        let second = try bodyCreation(bodyID: bodyID(entry: 122, serial: 1), origin: SourceVector3(10, 0, 0))
        let constraint = try lengthConstraint(first, second)
        let environment = SourceDeterministicPhysicsEnvironment()
        let before = try environment.execute(SourcePhysicsCommandBatch(commands: [
            .init(sequence: 1, payload: .createBody(first)), .init(sequence: 2, payload: .createBody(second)),
            .init(sequence: 3, payload: .createLengthConstraint(constraint))
        ]))
        #expect(throws: SourceDeterministicPhysicsEnvironment.Error.nonFiniteConstraintResult(constraint.constraintID)) {
            _ = try environment.execute(SourcePhysicsCommandBatch(commands: [
                .init(sequence: 4, payload: .mutateBody(try .init(bodyID: second.bodyID,
                    mutation: .setLinearVelocity(SourceVector3(.greatestFiniteMagnitude, 0, 0))))),
                .init(sequence: 5, payload: .simulate(.init(simulationTick: 1)))
            ]))
        }
        let after = try environment.execute(SourcePhysicsCommandBatch(commands: [
            .init(sequence: 4, payload: .mutateBody(try .init(bodyID: second.bodyID, mutation: .wake)))
        ]))
        #expect(after.bodies == before.bodies)
        #expect(after.lengthConstraints == before.lengthConstraints)
        #expect(after.simulationTick == before.simulationTick)
    }

    @Test("off-center rope simulation round-trips and replays deterministically")
    func angularRopeReplay() throws {
        let first = try bodyCreation(bodyID: bodyID(entry: 121, serial: 1), origin: .zero)
        let second = try bodyCreation(bodyID: bodyID(entry: 122, serial: 1), origin: SourceVector3(10, -2, 0),
            center: SourceVector3(0, 1, 0), velocity: SourceVector3(4, 0, 0))
        let creation = try lengthConstraint(first, second, attachedAnchor: SourceVector3(0, 2, 0))
        var batches = [try SourcePhysicsCommandBatch(commands: [
            .init(sequence: 1, payload: .createBody(first)), .init(sequence: 2, payload: .createBody(second)),
            .init(sequence: 3, payload: .mutateBody(try .init(bodyID: first.bodyID, mutation: .setMotionEnabled(false)))),
            .init(sequence: 4, payload: .mutateBody(try .init(bodyID: first.bodyID, mutation: .wake))),
            .init(sequence: 5, payload: .createLengthConstraint(creation)),
            .init(sequence: 6, payload: .simulate(.init(simulationTick: 1)))
        ])]
        for tick in UInt64(2)...12 {
            batches.append(try SourcePhysicsCommandBatch(commands: [
                .init(sequence: tick + 5, payload: .simulate(.init(simulationTick: tick)))
            ]))
        }
        let harness = SourcePhysicsDeterministicReplayHarness()
        let log = try harness.record(commandBatches: batches, using: SourceDeterministicPhysicsEnvironment())
        let decoded = try SourcePhysicsReplayLog(canonicalBytes: log.canonicalBytes)
        #expect(decoded == log)
        #expect(decoded.frames.last?.bodySnapshots.last?.angularVelocity != .zero)
        _ = try harness.replay(decoded, using: SourceDeterministicPhysicsEnvironment())
    }

    private func lengthConstraint(
        _ first: SourcePhysicsBodyCreationCommand,
        _ second: SourcePhysicsBodyCreationCommand,
        referenceAnchor: SourceVector3 = .zero,
        attachedAnchor: SourceVector3 = .zero,
        minimum: Float = 0,
        maximum: Float = 10,
        reverseEndpoints: Bool = false
    ) throws -> SourcePhysicsLengthConstraintCreationCommand {
        let a = try SourcePhysicsLengthConstraintEndpoint(bodyID: first.bodyID, kind: .body, localAnchor: referenceAnchor)
        let b = try SourcePhysicsLengthConstraintEndpoint(bodyID: second.bodyID, kind: .body, localAnchor: attachedAnchor)
        return try SourcePhysicsLengthConstraintCreationCommand(constraintID: SourcePhysicsConstraintID(rawValue: 93),
            reference: reverseEndpoints ? b : a, attached: reverseEndpoints ? a : b,
            minimumLength: minimum, maximumLength: maximum)
    }

    private func simulate(
        _ first: SourcePhysicsBodyCreationCommand,
        _ second: SourcePhysicsBodyCreationCommand,
        referenceAnchor: SourceVector3 = .zero,
        attachedAnchor: SourceVector3 = .zero,
        minimum: Float = 0,
        maximum: Float = 10,
        reverseEndpoints: Bool = false
    ) throws -> SourcePhysicsEnvironmentSnapshot {
        let environment = SourceDeterministicPhysicsEnvironment(configuration: try .init(gravity: .zero, contactSolverIterations: 1))
        return try environment.execute(SourcePhysicsCommandBatch(commands: [
            .init(sequence: 1, payload: .createBody(first)), .init(sequence: 2, payload: .createBody(second)),
            .init(sequence: 3, payload: .createLengthConstraint(try lengthConstraint(first, second,
                referenceAnchor: referenceAnchor, attachedAnchor: attachedAnchor, minimum: minimum, maximum: maximum,
                reverseEndpoints: reverseEndpoints))),
            .init(sequence: 4, payload: .simulate(.init(simulationTick: 1)))
        ]))
    }

    private func body(_ id: SourcePhysicsBodyID, in snapshot: SourcePhysicsEnvironmentSnapshot) throws -> SourcePhysicsBodySnapshot {
        try #require(snapshot.bodies.first { $0.bodyID == id })
    }

    private func anchorVelocity(_ body: SourcePhysicsBodySnapshot, localAnchor: SourceVector3) -> SourceVector3 {
        let angular = body.transform.transformDirectionFromLocal(body.angularVelocity) * (.pi / 180)
        let offset = body.transform.transformDirectionFromLocal(localAnchor - body.massProperties.massCenterLocal)
        return body.linearVelocity + SourceVector3(
            angular.y * offset.z - angular.z * offset.y,
            angular.z * offset.x - angular.x * offset.z,
            angular.x * offset.y - angular.y * offset.x
        )
    }

    private func expectVector(_ actual: SourceVector3, _ expected: SourceVector3, tolerance: Float = 0.0001) {
        #expect(abs(actual.x - expected.x) < tolerance)
        #expect(abs(actual.y - expected.y) < tolerance)
        #expect(abs(actual.z - expected.z) < tolerance)
    }

    private func pow2(_ value: Float) -> Float { value * value }

    private func bodyID(entry: Int, serial: Int) throws
        -> SourcePhysicsBodyID
    {
        try SourcePhysicsBodyID(
            entityIdentity: SourceCanonicalEntityIdentity(
                handle: SourceBaseHandle(
                    entryIndex: entry,
                    serialNumber: serial
                )
            ),
            solidIndex: 0
        )
    }

    private func bodyCreation(
        bodyID: SourcePhysicsBodyID,
        origin: SourceVector3,
        angles: SourceQAngle = .zero,
        center: SourceVector3 = .zero,
        mass: Float = 10,
        inertia: SourceVector3 = SourceVector3(5, 5, 5),
        velocity: SourceVector3 = .zero,
        angularVelocity: SourceVector3 = .zero,
        motion: SourcePhysicsMotionType = .dynamicBody,
        gravity: Bool = false
    ) throws -> SourcePhysicsBodyCreationCommand {
        try SourcePhysicsBodyCreationCommand(
            bodyID: bodyID,
            shape: cubeShape(),
            massProperties: SourcePhysicsMassProperties(
                massKilograms: mass,
                principalInertia: inertia,
                massCenterLocal: center
            ),
            transform: SourceEntityTransform(origin: origin, angles: angles),
            linearVelocity: velocity,
            angularVelocity: angularVelocity,
            damping: .zero,
            motionType: motion,
            materialIndex: 0,
            isGravityEnabled: gravity,
            isCollisionEnabled: false,
            startsAwake: true
        )
    }

    private func cubeShape() throws -> SourcePhysicsShapeSnapshot {
        let vertices = [
            SourceVector3(-1, -1, -1), SourceVector3(1, -1, -1),
            SourceVector3(1, 1, -1), SourceVector3(-1, 1, -1),
            SourceVector3(-1, -1, 1), SourceVector3(1, -1, 1),
            SourceVector3(1, 1, 1), SourceVector3(-1, 1, 1),
        ]
        let indices = [
            (0, 2, 1), (0, 3, 2), (4, 5, 6), (4, 6, 7),
            (0, 1, 5), (0, 5, 4), (1, 2, 6), (1, 6, 5),
            (2, 3, 7), (2, 7, 6), (3, 0, 4), (3, 4, 7),
        ]
        return try SourcePhysicsShapeSnapshot(
            topology: .convexParts,
            parts: [SourcePhysicsMeshPartSnapshot(
                vertices: vertices,
                triangles: try indices.map {
                    try SourcePhysicsIndexedTriangle(
                        first: $0.0,
                        second: $0.1,
                        third: $0.2,
                        materialIndex: 0
                    )
                }
            )]
        )
    }

    private func staticFloor() throws
        -> SourceDeterministicPhysicsStaticGeometry
    {
        try SourceDeterministicPhysicsStaticGeometry(parts: [
            SourceDeterministicPhysicsStaticMeshPart(
                vertices: [
                    SourceVector3(-32, -32, 0),
                    SourceVector3(32, -32, 0),
                    SourceVector3(32, 32, 0),
                    SourceVector3(-32, 32, 0),
                ],
                triangles: [
                    try SourceDeterministicPhysicsStaticTriangle(
                        first: 0, second: 1, third: 2
                    ),
                    try SourceDeterministicPhysicsStaticTriangle(
                        first: 0, second: 2, third: 3
                    ),
                ]
            ),
        ])
    }
}
