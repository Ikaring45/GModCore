import Testing
@testable import GModEngine

@Suite("Deterministic CPU Source physics environment")
struct SourceDeterministicPhysicsEnvironmentTests {
    @Test("verified convex prop falls onto massless world mesh and sleeps")
    func gravityContactAndSleep() throws {
        let configuration = try SourceDeterministicPhysicsEnvironment.Configuration(
            sleepAfterSettledTicks: 4
        )
        let worldID = try makeBodyID(entry: 0, serial: 41)
        let scene = try SourceDeterministicPhysicsStaticScene(
            bodyID: worldID,
            geometry: makeStaticFloorGeometry(),
            contents: .solid
        )
        let environment = SourceDeterministicPhysicsEnvironment(
            configuration: configuration,
            staticCollisionScene: scene,
            materialTable: try makeFrictionlessTestMaterialTable([(3, 7)])
        )
        let propID = try makeBodyID(entry: 41, serial: 7)
        var sequence: UInt64 = 100

        var snapshot = try environment.execute(SourcePhysicsCommandBatch(commands: [
            SourcePhysicsCommand(
                sequence: sequence,
                payload: .createBody(try makeCreation(
                    bodyID: propID,
                    shape: makeCubeShape(),
                    origin: SourceVector3(0, 0, 4),
                    motionType: .dynamicBody,
                    mass: 12,
                    inertia: SourceVector3(8, 8, 8),
                    material: 7,
                    gravity: true
                ))
            ),
            SourcePhysicsCommand(
                sequence: sequence + 1,
                payload: .simulate(SourcePhysicsSimulateCommand(
                    simulationTick: 1
                ))
            )
        ]))
        sequence += 2

        for tick in 2 ... 40 {
            snapshot = try environment.execute(SourcePhysicsCommandBatch(commands: [
                SourcePhysicsCommand(
                    sequence: sequence,
                    payload: .simulate(SourcePhysicsSimulateCommand(
                        simulationTick: UInt64(tick)
                    ))
                )
            ]))
            sequence += 1
        }

        let prop = try #require(snapshot.bodies.first { $0.bodyID == propID })
        #expect(abs(prop.transform.origin.x) < 0.001)
        #expect(abs(prop.transform.origin.y) < 0.001)
        #expect(abs(prop.transform.origin.z - 1) < 0.01)
        #expect(prop.linearVelocity == .zero)
        #expect(prop.angularVelocity == .zero)
        #expect(prop.isSleeping)
        #expect(prop.massProperties.massKilograms == 12)
        #expect(prop.massProperties.principalInertia == SourceVector3(8, 8, 8))
        #expect(prop.simulationTick == 40)
        #expect(snapshot.fixedTimeStepSeconds == 0.015)
        #expect(snapshot.bodies.map(\.bodyID) == [propID])
        #expect(environment.staticCollisionScene?.bodyID == worldID)
        #expect(environment.latestContacts.contains {
            $0.firstBodyID == worldID && $0.secondBodyID == propID
        })
    }

    @Test("an authored kinematic impact wakes a sleeping dynamic body")
    func collisionWake() throws {
        let configuration = try SourceDeterministicPhysicsEnvironment.Configuration(
            gravity: .zero,
            sleepAfterSettledTicks: 4
        )
        let environment = SourceDeterministicPhysicsEnvironment(
            configuration: configuration,
            materialTable: try makeFrictionlessTestMaterialTable([(1, 2)])
        )
        let sleepingID = try makeBodyID(entry: 2, serial: 8)
        let moverID = try makeBodyID(entry: 3, serial: 8)
        let snapshot = try environment.execute(SourcePhysicsCommandBatch(commands: [
            SourcePhysicsCommand(
                sequence: 1,
                payload: .createBody(try makeCreation(
                    bodyID: sleepingID,
                    shape: makeCubeShape(),
                    origin: .zero,
                    motionType: .dynamicBody,
                    mass: 10,
                    inertia: SourceVector3(4, 5, 6),
                    material: 1,
                    gravity: false,
                    startsAwake: false
                ))
            ),
            SourcePhysicsCommand(
                sequence: 2,
                payload: .createBody(try makeCreation(
                    bodyID: moverID,
                    shape: makeCubeShape(),
                    origin: SourceVector3(-3, 0, 0),
                    motionType: .kinematicBody,
                    mass: 20,
                    inertia: SourceVector3(7, 8, 9),
                    material: 2,
                    gravity: false,
                    linearVelocity: SourceVector3(100, 0, 0)
                ))
            ),
            SourcePhysicsCommand(
                sequence: 3,
                payload: .simulate(SourcePhysicsSimulateCommand(
                    simulationTick: 1
                ))
            )
        ]))

        let sleeper = try #require(
            snapshot.bodies.first { $0.bodyID == sleepingID }
        )
        let mover = try #require(snapshot.bodies.first { $0.bodyID == moverID })
        #expect(!sleeper.isSleeping)
        #expect(sleeper.linearVelocity.x > 0)
        #expect(mover.linearVelocity == SourceVector3(100, 0, 0))
        let contact = try #require(environment.latestContacts.first)
        #expect(contact.firstBodyID == sleepingID)
        #expect(contact.secondBodyID == moverID)
        #expect(contact.simulationTick == 1)
    }

    @Test("SetMass preserves authored inertia ratio and failed batches roll back")
    func setMassAndTransactionalRollback() throws {
        let environment = SourceDeterministicPhysicsEnvironment(
            configuration: try .init(gravity: .zero)
        )
        let bodyID = try makeBodyID(entry: 90, serial: 12)
        let missingBodyID = try makeBodyID(entry: 91, serial: 12)
        _ = try environment.execute(SourcePhysicsCommandBatch(commands: [
            SourcePhysicsCommand(
                sequence: 1,
                payload: .createBody(try makeCreation(
                    bodyID: bodyID,
                    shape: makeCubeShape(),
                    origin: .zero,
                    motionType: .dynamicBody,
                    mass: 10,
                    inertia: SourceVector3(2, 4, 6),
                    material: 1,
                    gravity: false
                ))
            ),
            SourcePhysicsCommand(
                sequence: 2,
                payload: .simulate(SourcePhysicsSimulateCommand(
                    simulationTick: 1
                ))
            ),
        ]))

        let changed = try environment.execute(SourcePhysicsCommandBatch(commands: [
            SourcePhysicsCommand(
                sequence: 3,
                payload: .mutateBody(try SourcePhysicsBodyMutationCommand(
                    bodyID: bodyID,
                    mutation: .setMassKilograms(20)
                ))
            ),
            SourcePhysicsCommand(
                sequence: 4,
                payload: .simulate(SourcePhysicsSimulateCommand(
                    simulationTick: 2
                ))
            ),
        ]))
        let changedBody = try #require(changed.bodies.first)
        #expect(changedBody.massProperties.massKilograms == 20)
        #expect(
            changedBody.massProperties.principalInertia ==
                SourceVector3(4, 8, 12)
        )

        #expect(throws: SourceDeterministicPhysicsEnvironment.Error.missingBody(
            missingBodyID
        )) {
            _ = try environment.execute(SourcePhysicsCommandBatch(commands: [
                SourcePhysicsCommand(
                    sequence: 5,
                    payload: .mutateBody(try SourcePhysicsBodyMutationCommand(
                        bodyID: bodyID,
                        mutation: .setMassKilograms(30)
                    ))
                ),
                SourcePhysicsCommand(
                    sequence: 6,
                    payload: .mutateBody(try SourcePhysicsBodyMutationCommand(
                        bodyID: missingBodyID,
                        mutation: .setMassKilograms(40)
                    ))
                ),
            ]))
        }

        let afterRollback = try environment.execute(
            SourcePhysicsCommandBatch(commands: [
                SourcePhysicsCommand(
                    sequence: 5,
                    payload: .simulate(SourcePhysicsSimulateCommand(
                        simulationTick: 3
                    ))
                ),
            ])
        )
        let rolledBackBody = try #require(afterRollback.bodies.first)
        #expect(rolledBackBody.massProperties == changedBody.massProperties)
    }

    @Test("transform setters support static, dynamic, and motion-disabled bodies")
    func transformMutationsAndRollback() throws {
        let environment = SourceDeterministicPhysicsEnvironment(
            configuration: try .init(gravity: .zero)
        )
        let staticID = try makeBodyID(entry: 92, serial: 12)
        let dynamicID = try makeBodyID(entry: 93, serial: 12)
        let disabledID = try makeBodyID(entry: 94, serial: 12)
        let missingID = try makeBodyID(entry: 95, serial: 12)
        let staticAngles = SourceQAngle(pitch: 1, yaw: 2, roll: 3)
        let dynamicAngles = SourceQAngle(pitch: 11, yaw: 22, roll: 33)
        let disabledAngles = SourceQAngle(pitch: 44, yaw: 55, roll: 66)

        let transformed = try environment.execute(
            SourcePhysicsCommandBatch(commands: [
                SourcePhysicsCommand(
                    sequence: 1,
                    payload: .createBody(try makeCreation(
                        bodyID: staticID,
                        shape: makeCubeShape(),
                        origin: .zero,
                        motionType: .staticBody,
                        mass: 10,
                        inertia: SourceVector3(2, 3, 4),
                        material: 1,
                        gravity: false
                    ))
                ),
                SourcePhysicsCommand(
                    sequence: 2,
                    payload: .createBody(try makeCreation(
                        bodyID: dynamicID,
                        shape: makeCubeShape(),
                        origin: SourceVector3(100, 0, 0),
                        motionType: .dynamicBody,
                        mass: 10,
                        inertia: SourceVector3(2, 3, 4),
                        material: 1,
                        gravity: false
                    ))
                ),
                SourcePhysicsCommand(
                    sequence: 3,
                    payload: .createBody(try makeCreation(
                        bodyID: disabledID,
                        shape: makeCubeShape(),
                        origin: SourceVector3(200, 0, 0),
                        motionType: .dynamicBody,
                        mass: 10,
                        inertia: SourceVector3(2, 3, 4),
                        material: 1,
                        gravity: false
                    ))
                ),
                SourcePhysicsCommand(
                    sequence: 4,
                    payload: .mutateBody(try .init(
                        bodyID: disabledID,
                        mutation: .setMotionEnabled(false)
                    ))
                ),
                SourcePhysicsCommand(
                    sequence: 5,
                    payload: .mutateBody(try .init(
                        bodyID: staticID,
                        mutation: .setPosition(
                            SourceVector3(10, 0, 0),
                            teleport: false
                        )
                    ))
                ),
                SourcePhysicsCommand(
                    sequence: 6,
                    payload: .mutateBody(try .init(
                        bodyID: staticID,
                        mutation: .setAngles(staticAngles)
                    ))
                ),
                SourcePhysicsCommand(
                    sequence: 7,
                    payload: .mutateBody(try .init(
                        bodyID: dynamicID,
                        mutation: .setPosition(
                            SourceVector3(110, 0, 0),
                            teleport: true
                        )
                    ))
                ),
                SourcePhysicsCommand(
                    sequence: 8,
                    payload: .mutateBody(try .init(
                        bodyID: dynamicID,
                        mutation: .setAngles(dynamicAngles)
                    ))
                ),
                SourcePhysicsCommand(
                    sequence: 9,
                    payload: .mutateBody(try .init(
                        bodyID: disabledID,
                        mutation: .setPosition(
                            SourceVector3(210, 0, 0),
                            teleport: false
                        )
                    ))
                ),
                SourcePhysicsCommand(
                    sequence: 10,
                    payload: .mutateBody(try .init(
                        bodyID: disabledID,
                        mutation: .setAngles(disabledAngles)
                    ))
                ),
                SourcePhysicsCommand(
                    sequence: 11,
                    payload: .simulate(.init(simulationTick: 1))
                ),
            ])
        )
        let bodies = Dictionary(
            uniqueKeysWithValues: transformed.bodies.map { ($0.bodyID, $0) }
        )
        #expect(bodies[staticID]?.transform.origin == SourceVector3(10, 0, 0))
        #expect(bodies[staticID]?.transform.angles == staticAngles)
        #expect(bodies[staticID]?.isMotionEnabled == false)
        #expect(bodies[dynamicID]?.transform.origin == SourceVector3(110, 0, 0))
        #expect(bodies[dynamicID]?.transform.angles == dynamicAngles)
        #expect(bodies[dynamicID]?.isMotionEnabled == true)
        #expect(bodies[disabledID]?.transform.origin == SourceVector3(210, 0, 0))
        #expect(bodies[disabledID]?.transform.angles == disabledAngles)
        #expect(bodies[disabledID]?.isMotionEnabled == false)
        #expect(bodies.values.allSatisfy { $0.linearVelocity == .zero })

        #expect(throws: SourceDeterministicPhysicsEnvironment.Error.missingBody(
            missingID
        )) {
            _ = try environment.execute(SourcePhysicsCommandBatch(commands: [
                SourcePhysicsCommand(
                    sequence: 12,
                    payload: .mutateBody(try .init(
                        bodyID: dynamicID,
                        mutation: .setPosition(
                            SourceVector3(999, 0, 0),
                            teleport: true
                        )
                    ))
                ),
                SourcePhysicsCommand(
                    sequence: 13,
                    payload: .mutateBody(try .init(
                        bodyID: missingID,
                        mutation: .setAngles(.zero)
                    ))
                ),
            ]))
        }
        let afterRollback = try environment.execute(
            SourcePhysicsCommandBatch(commands: [
                SourcePhysicsCommand(
                    sequence: 12,
                    payload: .simulate(.init(simulationTick: 2))
                ),
            ])
        )
        let dynamicAfterRollback = try #require(
            afterRollback.bodies.first { $0.bodyID == dynamicID }
        )
        #expect(dynamicAfterRollback.transform.origin == SourceVector3(110, 0, 0))
        #expect(dynamicAfterRollback.transform.angles == dynamicAngles)
    }

    @Test("line and swept hull queries filter exact EHANDLE generations")
    func generationSafeQueries() throws {
        let environment = SourceDeterministicPhysicsEnvironment()
        let oldID = try makeBodyID(entry: 75, serial: 1)
        let newID = try makeBodyID(entry: 75, serial: 2)
        let oldIdentity = oldID.entityIdentity
        let line = try SourcePhysicsQueryCommand(
            queryID: 500,
            geometry: .lineSegment(
                start: .zero,
                end: SourceVector3(20, 0, 0)
            ),
            contentsMask: UInt32.max,
            collisionGroup: 0,
            scope: .staticOnly,
            ignoredEntities: [oldIdentity]
        )
        let hull = try SourcePhysicsQueryCommand(
            queryID: 501,
            geometry: .sweptHull(
                start: .zero,
                end: SourceVector3(20, 0, 0),
                minimums: SourceVector3(-1, -1, -1),
                maximums: SourceVector3(1, 1, 1)
            ),
            contentsMask: UInt32.max,
            collisionGroup: 0,
            scope: .staticAndMoving,
            ignoredEntities: [oldIdentity]
        )

        let snapshot = try environment.execute(SourcePhysicsCommandBatch(commands: [
            SourcePhysicsCommand(
                sequence: 10,
                payload: .createBody(try makeCreation(
                    bodyID: newID,
                    shape: makeCubeShape(),
                    origin: SourceVector3(10, 0, 0),
                    motionType: .staticBody,
                    mass: 10,
                    inertia: SourceVector3(2, 2, 2),
                    material: 9,
                    gravity: false
                ))
            ),
            SourcePhysicsCommand(
                sequence: 11,
                payload: .createBody(try makeCreation(
                    bodyID: oldID,
                    shape: makeCubeShape(),
                    origin: SourceVector3(5, 0, 0),
                    motionType: .staticBody,
                    mass: 10,
                    inertia: SourceVector3(2, 2, 2),
                    material: 8,
                    gravity: false
                ))
            ),
            SourcePhysicsCommand(sequence: 12, payload: .query(line)),
            SourcePhysicsCommand(sequence: 13, payload: .query(hull))
        ]))

        #expect(snapshot.bodies.map(\.bodyID) == [oldID, newID])
        #expect(snapshot.queryResults.map(\.queryID) == [500, 501])
        let lineHit = try #require(snapshot.queryResults[0].hit)
        #expect(lineHit.bodyID == newID)
        #expect(abs(lineHit.fraction - 0.45) < 0.0001)
        #expect(lineHit.position == SourceVector3(9, 0, 0))
        #expect(lineHit.normal == SourceVector3(-1, 0, 0))
        // Line traces resolve the verified seven-bit per-triangle material,
        // rather than replacing it with the body's selected material index.
        #expect(lineHit.materialIndex == 7)

        let hullHit = try #require(snapshot.queryResults[1].hit)
        #expect(hullHit.bodyID == newID)
        #expect(abs(hullHit.fraction - 0.4) < 0.0001)
        #expect(hullHit.position == SourceVector3(8, 0, 0))
        #expect(hullHit.normal == SourceVector3(-1, 0, 0))
        #expect(hullHit.materialIndex == 9)
    }

    @Test("static BVH prunes parts without changing tie or StartSolid order")
    func staticBroadphasePreservesNarrowphaseOrder() throws {
        var parts = [
            try makeStaticCubePart(
                center: .zero,
                halfExtent: 4,
                material: 3
            ),
            try makeStaticCubePart(
                center: .zero,
                halfExtent: 1,
                material: 5
            ),
        ]
        for index in 0 ..< 32 {
            parts.append(try makeStaticCubePart(
                center: SourceVector3(Float(index + 1) * 1_000, 0, 0),
                halfExtent: 4,
                material: 6
            ))
        }
        // An exact duplicate later in original part order proves that spatial
        // BVH order cannot replace the established first-part fraction tie.
        parts.append(try makeStaticCubePart(
            center: .zero,
            halfExtent: 4,
            material: 9
        ))
        let worldID = try makeBodyID(entry: 0, serial: 91)
        let scene = try SourceDeterministicPhysicsStaticScene(
            bodyID: worldID,
            geometry: SourceDeterministicPhysicsStaticGeometry(parts: parts),
            contents: .solid
        )
        let environment = SourceDeterministicPhysicsEnvironment(
            staticCollisionScene: scene
        )
        let line = try SourcePhysicsQueryCommand(
            queryID: 700,
            geometry: .lineSegment(
                start: SourceVector3(-10, 0, 0),
                end: SourceVector3(10, 0, 0)
            ),
            contentsMask: SourceContents.solid.rawValue,
            collisionGroup: 0,
            scope: .staticOnly,
            ignoredEntities: []
        )
        var snapshot = try environment.execute(SourcePhysicsCommandBatch(
            commands: [SourcePhysicsCommand(sequence: 1, payload: .query(line))]
        ))
        let lineHit = try #require(snapshot.queryResults.first?.hit)
        #expect(lineHit.bodyID == worldID)
        #expect(abs(lineHit.fraction - 0.3) < 0.0001)
        #expect(lineHit.position == SourceVector3(-4, 0, 0))
        #expect(lineHit.normal == SourceVector3(-1, 0, 0))
        #expect(lineHit.materialIndex == 3)
        #expect(
            environment.latestStaticBroadphaseDiagnostics.candidatePartCount <
                parts.count
        )
        #expect(
            environment.latestStaticBroadphaseDiagnostics.totalPartCount ==
                parts.count
        )

        let hull = try SourcePhysicsQueryCommand(
            queryID: 701,
            geometry: .sweptHull(
                start: .zero,
                end: SourceVector3(2, 0, 0),
                minimums: SourceVector3(-0.25, -0.25, -0.25),
                maximums: SourceVector3(0.25, 0.25, 0.25)
            ),
            contentsMask: SourceContents.solid.rawValue,
            collisionGroup: 0,
            scope: .staticOnly,
            ignoredEntities: []
        )
        snapshot = try environment.execute(SourcePhysicsCommandBatch(
            commands: [SourcePhysicsCommand(sequence: 2, payload: .query(hull))]
        ))
        let hullHit = try #require(snapshot.queryResults.first?.hit)
        #expect(hullHit.bodyID == worldID)
        #expect(hullHit.fraction == 0)
        #expect(hullHit.startedSolid)
        #expect(hullHit.allSolid)
        #expect(hullHit.materialIndex == nil)
        #expect(
            environment.latestStaticBroadphaseDiagnostics.candidatePartCount <
                parts.count
        )
    }

    @Test("FIFO failures leave the environment transactionally unchanged")
    func transactionalFIFO() throws {
        let environment = SourceDeterministicPhysicsEnvironment()
        let bodyID = try makeBodyID(entry: 8, serial: 3)
        let creation = try makeCreation(
            bodyID: bodyID,
            shape: makeCubeShape(),
            origin: .zero,
            motionType: .dynamicBody,
            mass: 4,
            inertia: SourceVector3(1, 2, 3),
            material: 2,
            gravity: false
        )
        let initial = try environment.execute(SourcePhysicsCommandBatch(commands: [
            SourcePhysicsCommand(sequence: 10, payload: .createBody(creation))
        ]))
        #expect(initial.bodies.count == 1)

        #expect(throws: SourceDeterministicPhysicsEnvironment.Error
            .duplicateBody(bodyID)) {
            _ = try environment.execute(SourcePhysicsCommandBatch(commands: [
                SourcePhysicsCommand(sequence: 11, payload: .createBody(creation)),
                SourcePhysicsCommand(
                    sequence: 12,
                    payload: .deleteBody(SourcePhysicsBodyDeletionCommand(
                        bodyID: bodyID
                    ))
                )
            ]))
        }
        #expect(throws: SourceDeterministicPhysicsEnvironment.Error
            .commandSequenceNotIncreasing(previous: 10, current: 10)) {
            _ = try environment.execute(SourcePhysicsCommandBatch(commands: [
                SourcePhysicsCommand(
                    sequence: 10,
                    payload: .simulate(SourcePhysicsSimulateCommand(
                        simulationTick: 1
                    ))
                )
            ]))
        }
        let missingID = try makeBodyID(entry: 9, serial: 3)
        #expect(throws: SourceDeterministicPhysicsEnvironment.Error
            .missingBody(missingID)) {
            _ = try environment.execute(SourcePhysicsCommandBatch(commands: [
                SourcePhysicsCommand(
                    sequence: 11,
                    payload: .deleteBody(SourcePhysicsBodyDeletionCommand(
                        bodyID: missingID
                    ))
                )
            ]))
        }

        let unchanged = try environment.execute(
            SourcePhysicsCommandBatch(commands: [])
        )
        #expect(unchanged.bodies.map(\.bodyID) == [bodyID])
        #expect(unchanged.lastProcessedCommandSequence == 10)
    }

    @Test("validated body mutations execute in FIFO order on the next fixed tick")
    func bodyMutationFIFO() throws {
        let environment = SourceDeterministicPhysicsEnvironment()
        let bodyID = try makeBodyID(entry: 81, serial: 23)
        let creation = try makeCreation(
            bodyID: bodyID,
            shape: makeCubeShape(),
            origin: SourceVector3(0, 0, 10),
            motionType: .dynamicBody,
            mass: 10,
            inertia: SourceVector3(2, 3, 4),
            material: 5,
            gravity: false
        )
        let mutations: [SourcePhysicsBodyMutation] = [
            .setLinearVelocity(SourceVector3(1, 0, 0)),
            .addLinearVelocity(SourceVector3(2, 0, 0)),
            .setAngularVelocity(SourceVector3(4, 0, 0)),
            .addAngularVelocity(SourceVector3(1, 0, 0)),
            .applyCenterImpulse(SourceVector3(20, 0, 0)),
            .applyCenterForce(SourceVector3(10, 0, 0)),
            .setCollisionEnabled(false),
        ]
        var commands = [SourcePhysicsCommand(
            sequence: 1,
            payload: .createBody(creation)
        )]
        for (offset, mutation) in mutations.enumerated() {
            commands.append(SourcePhysicsCommand(
                sequence: UInt64(offset + 2),
                payload: .mutateBody(try SourcePhysicsBodyMutationCommand(
                    bodyID: bodyID,
                    mutation: mutation
                ))
            ))
        }
        commands.append(SourcePhysicsCommand(
            sequence: UInt64(commands.count + 1),
            payload: .simulate(SourcePhysicsSimulateCommand(simulationTick: 1))
        ))
        var snapshot = try environment.execute(
            SourcePhysicsCommandBatch(commands: commands)
        )
        var body = try #require(snapshot.bodies.first)
        #expect(abs(body.linearVelocity.x - 5.015) < 0.000_01)
        #expect(abs(body.transform.origin.x - 0.075_225) < 0.000_01)
        #expect(abs(body.transform.angles.pitch - 0.075) < 0.000_01)
        #expect(body.angularVelocity == SourceVector3(5, 0, 0))
        #expect(body.isMotionEnabled)
        #expect(!body.isGravityEnabled)
        #expect(!body.isCollisionEnabled)
        #expect(!body.isSleeping)

        snapshot = try environment.execute(SourcePhysicsCommandBatch(commands: [
            SourcePhysicsCommand(
                sequence: 10,
                payload: .mutateBody(try SourcePhysicsBodyMutationCommand(
                    bodyID: bodyID,
                    mutation: .setMotionEnabled(false)
                ))
            ),
            SourcePhysicsCommand(
                sequence: 11,
                payload: .simulate(SourcePhysicsSimulateCommand(simulationTick: 2))
            ),
        ]))
        body = try #require(snapshot.bodies.first)
        let frozenOrigin = body.transform.origin
        #expect(!body.isMotionEnabled)
        #expect(body.isSleeping)
        #expect(body.linearVelocity == .zero)
        #expect(body.angularVelocity == .zero)

        snapshot = try environment.execute(SourcePhysicsCommandBatch(commands: [
            SourcePhysicsCommand(
                sequence: 12,
                payload: .mutateBody(try SourcePhysicsBodyMutationCommand(
                    bodyID: bodyID,
                    mutation: .setMotionEnabled(true)
                ))
            ),
            SourcePhysicsCommand(
                sequence: 13,
                payload: .mutateBody(try SourcePhysicsBodyMutationCommand(
                    bodyID: bodyID,
                    mutation: .setGravityEnabled(true)
                ))
            ),
            SourcePhysicsCommand(
                sequence: 14,
                payload: .simulate(SourcePhysicsSimulateCommand(simulationTick: 3))
            ),
        ]))
        body = try #require(snapshot.bodies.first)
        #expect(body.isMotionEnabled)
        #expect(body.isGravityEnabled)
        #expect(!body.isSleeping)
        #expect(body.transform.origin.x == frozenOrigin.x)
        #expect(body.transform.origin.z < frozenOrigin.z)
    }

    @Test("world offset force integrates linear and principal-inertia angular acceleration")
    func applyForceOffsetUsesWorldPointAndBodyInertiaFrame() throws {
        let environment = SourceDeterministicPhysicsEnvironment()
        let bodyID = try makeBodyID(entry: 82, serial: 23)
        let origin = SourceVector3(10, 20, 30)
        let creation = try makeCreation(
            bodyID: bodyID,
            shape: makeCubeShape(),
            origin: origin,
            motionType: .dynamicBody,
            mass: 2,
            inertia: SourceVector3(2, 4, 8),
            material: 5,
            gravity: false,
            angles: SourceQAngle(yaw: 90)
        )
        let force = SourceVector3(0, 10, 0)
        let worldPosition = origin + SourceVector3(0, 0, 1)
        let snapshot = try environment.execute(SourcePhysicsCommandBatch(
            commands: [
                SourcePhysicsCommand(
                    sequence: 1,
                    payload: .createBody(creation)
                ),
                SourcePhysicsCommand(
                    sequence: 2,
                    payload: .mutateBody(
                        try SourcePhysicsBodyMutationCommand(
                            bodyID: bodyID,
                            mutation: .applyForceOffset(
                                force: force,
                                worldPosition: worldPosition
                            )
                        )
                    )
                ),
                SourcePhysicsCommand(
                    sequence: 3,
                    payload: .simulate(SourcePhysicsSimulateCommand(
                        simulationTick: 1
                    ))
                ),
            ]
        ))

        let body = try #require(snapshot.bodies.first)
        // Linear force uses the existing fixed-tick ApplyForceCenter unit:
        // dv = F / m * 0.015.
        #expect(abs(body.linearVelocity.x) < 0.000_001)
        #expect(abs(body.linearVelocity.y - 0.075) < 0.000_001)
        #expect(abs(body.linearVelocity.z) < 0.000_001)

        // r x F is (-10, 0, 0) in world space. At yaw 90 that axis maps to
        // the body's principal Y inertia (4), then radians/s becomes the
        // Source angular-velocity degrees/s contract.
        let expectedAngularX = (-10 / Float(4)) *
            SourcePhysicsContract.fixedTimeStepSeconds *
            (180 / Float.pi)
        #expect(abs(body.angularVelocity.x - expectedAngularX) < 0.000_01)
        #expect(abs(body.angularVelocity.y) < 0.000_01)
        #expect(abs(body.angularVelocity.z) < 0.000_01)
        #expect(
            abs(
                body.transform.angles.pitch -
                    expectedAngularX *
                    SourcePhysicsContract.fixedTimeStepSeconds
            ) < 0.000_01
        )
    }

    @Test("center torque impulse is immediate in world axes and principal inertia")
    func applyTorqueCenterUsesWorldAxesAndBodyInertiaFrame() throws {
        let environment = SourceDeterministicPhysicsEnvironment()
        let bodyID = try makeBodyID(entry: 83, serial: 23)
        let creation = try makeCreation(
            bodyID: bodyID,
            shape: makeCubeShape(),
            origin: SourceVector3(10, 20, 30),
            motionType: .dynamicBody,
            mass: 2,
            inertia: SourceVector3(2, 4, 8),
            material: 5,
            gravity: false,
            startsAwake: false,
            angularVelocity: SourceVector3(1, 2, 3),
            angles: SourceQAngle(yaw: 90)
        )
        let snapshot = try environment.execute(SourcePhysicsCommandBatch(
            commands: [
                SourcePhysicsCommand(
                    sequence: 1,
                    payload: .createBody(creation)
                ),
                SourcePhysicsCommand(
                    sequence: 2,
                    payload: .mutateBody(
                        try SourcePhysicsBodyMutationCommand(
                            bodyID: bodyID,
                            mutation: .applyTorqueCenter(
                                SourceVector3(8, 0, 0)
                            )
                        )
                    )
                ),
            ]
        ))

        let body = try #require(snapshot.bodies.first)
        // Yaw 90 maps world +X onto the body Y principal axis. Valve's
        // AngularImpulse is already kilograms-degrees/second, so 8 / 4 adds
        // exactly 2 degrees/second without a radians conversion or fixed tick.
        #expect(abs(body.angularVelocity.x - 3) < 0.000_01)
        #expect(abs(body.angularVelocity.y - 2) < 0.000_01)
        #expect(abs(body.angularVelocity.z - 3) < 0.000_01)
        #expect(body.transform == creation.transform)
        #expect(!body.isSleeping)
        #expect(body.simulationTick == 0)
    }

    @Test("fixed-tick damping decays both velocities and rolls back atomically")
    func dampingUsesFixedTickAndTransactionalFIFO() throws {
        let environment = SourceDeterministicPhysicsEnvironment()
        let bodyID = try makeBodyID(entry: 84, serial: 23)
        let missingID = try makeBodyID(entry: 84, serial: 24)
        let creation = try makeCreation(
            bodyID: bodyID,
            shape: makeCubeShape(),
            origin: SourceVector3(1, 2, 3),
            motionType: .dynamicBody,
            mass: 2,
            inertia: SourceVector3(2, 4, 8),
            material: 5,
            gravity: false,
            linearVelocity: SourceVector3(10, -4, 2),
            angularVelocity: SourceVector3(20, -10, 5)
        )
        let snapshot = try environment.execute(SourcePhysicsCommandBatch(
            commands: [
                SourcePhysicsCommand(
                    sequence: 1,
                    payload: .createBody(creation)
                ),
                SourcePhysicsCommand(
                    sequence: 2,
                    payload: .mutateBody(try SourcePhysicsBodyMutationCommand(
                        bodyID: bodyID,
                        mutation: .setDamping(linear: 2, angular: 4)
                    ))
                ),
                SourcePhysicsCommand(
                    sequence: 3,
                    payload: .simulate(SourcePhysicsSimulateCommand(
                        simulationTick: 1
                    ))
                ),
            ]
        ))

        let body = try #require(snapshot.bodies.first)
        let linearScale: Float = 1 - 2 *
            SourcePhysicsContract.fixedTimeStepSeconds
        let angularScale: Float = 1 - 4 *
            SourcePhysicsContract.fixedTimeStepSeconds
        #expect(body.bodyID == bodyID)
        let expectedDamping = try SourcePhysicsDamping(linear: 2, angular: 4)
        #expect(body.damping == expectedDamping)
        #expect(body.linearVelocity == creation.linearVelocity * linearScale)
        #expect(body.angularVelocity == creation.angularVelocity * angularScale)
        #expect(
            body.transform.origin == creation.transform.origin +
                body.linearVelocity * SourcePhysicsContract.fixedTimeStepSeconds
        )

        #expect(throws: SourceDeterministicPhysicsEnvironment.Error
            .missingBody(missingID)) {
            _ = try environment.execute(SourcePhysicsCommandBatch(commands: [
                SourcePhysicsCommand(
                    sequence: 4,
                    payload: .mutateBody(try SourcePhysicsBodyMutationCommand(
                        bodyID: bodyID,
                        mutation: .setDamping(linear: 9, angular: 11)
                    ))
                ),
                SourcePhysicsCommand(
                    sequence: 5,
                    payload: .mutateBody(try SourcePhysicsBodyMutationCommand(
                        bodyID: missingID,
                        mutation: .setDamping(linear: 1, angular: 1)
                    ))
                ),
            ]))
        }
        let unchanged = try environment.execute(SourcePhysicsCommandBatch(commands: []))
        #expect(unchanged.lastProcessedCommandSequence == 3)
        #expect(unchanged.bodies.first?.damping == body.damping)
    }

    @Test("a later invalid body mutation rolls back earlier mutations")
    func bodyMutationRollback() throws {
        let environment = SourceDeterministicPhysicsEnvironment()
        let bodyID = try makeBodyID(entry: 82, serial: 23)
        let missingID = try makeBodyID(entry: 82, serial: 24)
        _ = try environment.execute(SourcePhysicsCommandBatch(commands: [
            SourcePhysicsCommand(
                sequence: 1,
                payload: .createBody(try makeCreation(
                    bodyID: bodyID,
                    shape: makeCubeShape(),
                    origin: .zero,
                    motionType: .dynamicBody,
                    mass: 5,
                    inertia: SourceVector3(1, 1, 1),
                    material: 2,
                    gravity: false
                ))
            )
        ]))

        #expect(throws: SourceDeterministicPhysicsEnvironment.Error
            .missingBody(missingID)) {
            _ = try environment.execute(SourcePhysicsCommandBatch(commands: [
                SourcePhysicsCommand(
                    sequence: 2,
                    payload: .mutateBody(try SourcePhysicsBodyMutationCommand(
                        bodyID: bodyID,
                        mutation: .setLinearVelocity(SourceVector3(99, 0, 0))
                    ))
                ),
                SourcePhysicsCommand(
                    sequence: 3,
                    payload: .mutateBody(try SourcePhysicsBodyMutationCommand(
                        bodyID: missingID,
                        mutation: .wake
                    ))
                ),
            ]))
        }
        let unchanged = try environment.execute(SourcePhysicsCommandBatch(commands: []))
        #expect(unchanged.lastProcessedCommandSequence == 1)
        #expect(unchanged.bodies.first?.linearVelocity == .zero)
        #expect(unchanged.bodies.first?.isMotionEnabled == true)
    }

    @Test("two environments produce byte-for-byte equal deterministic state")
    func deterministicReplay() throws {
        let first = SourceDeterministicPhysicsEnvironment()
        let second = SourceDeterministicPhysicsEnvironment()
        let bodyID = try makeBodyID(entry: 600, serial: 19)
        let creation = try makeCreation(
            bodyID: bodyID,
            shape: makeCubeShape(),
            origin: SourceVector3(1, 2, 30),
            motionType: .dynamicBody,
            mass: 14,
            inertia: SourceVector3(3, 4, 5),
            material: 6,
            gravity: true,
            linearVelocity: SourceVector3(10, -2, 1),
            angularVelocity: SourceVector3(3, 5, 7)
        )

        var sequence: UInt64 = 1
        for tick in 1 ... 12 {
            var commands: [SourcePhysicsCommand] = []
            if tick == 1 {
                commands.append(SourcePhysicsCommand(
                    sequence: sequence,
                    payload: .createBody(creation)
                ))
                sequence += 1
            }
            commands.append(SourcePhysicsCommand(
                sequence: sequence,
                payload: .simulate(SourcePhysicsSimulateCommand(
                    simulationTick: UInt64(tick)
                ))
            ))
            sequence += 1
            let batch = try SourcePhysicsCommandBatch(commands: commands)
            let firstSnapshot = try first.execute(batch)
            let secondSnapshot = try second.execute(batch)
            #expect(firstSnapshot == secondSnapshot)
            #expect(first.latestContacts == second.latestContacts)
        }
    }

    private func makeBodyID(
        entry: Int,
        serial: Int
    ) throws -> SourcePhysicsBodyID {
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

    private func makeCreation(
        bodyID: SourcePhysicsBodyID,
        shape: SourcePhysicsShapeSnapshot,
        origin: SourceVector3,
        motionType: SourcePhysicsMotionType,
        mass: Float,
        inertia: SourceVector3,
        material: Int,
        gravity: Bool,
        startsAwake: Bool = true,
        linearVelocity: SourceVector3 = .zero,
        angularVelocity: SourceVector3 = .zero,
        damping: SourcePhysicsDamping = .zero,
        angles: SourceQAngle = .zero
    ) throws -> SourcePhysicsBodyCreationCommand {
        try SourcePhysicsBodyCreationCommand(
            bodyID: bodyID,
            shape: shape,
            massProperties: SourcePhysicsMassProperties(
                massKilograms: mass,
                principalInertia: inertia
            ),
            transform: SourceEntityTransform(origin: origin, angles: angles),
            linearVelocity: linearVelocity,
            angularVelocity: angularVelocity,
            damping: damping,
            motionType: motionType,
            materialIndex: material,
            isGravityEnabled: gravity,
            isCollisionEnabled: true,
            startsAwake: startsAwake
        )
    }

    private func makeCubeShape() throws -> SourcePhysicsShapeSnapshot {
        let vertices = [
            SourceVector3(-1, -1, -1),
            SourceVector3(1, -1, -1),
            SourceVector3(1, 1, -1),
            SourceVector3(-1, 1, -1),
            SourceVector3(-1, -1, 1),
            SourceVector3(1, -1, 1),
            SourceVector3(1, 1, 1),
            SourceVector3(-1, 1, 1)
        ]
        let indices = [
            (0, 2, 1), (0, 3, 2),
            (4, 5, 6), (4, 6, 7),
            (0, 1, 5), (0, 5, 4),
            (1, 2, 6), (1, 6, 5),
            (2, 3, 7), (2, 7, 6),
            (3, 0, 4), (3, 4, 7)
        ]
        let triangles = try indices.map {
            try SourcePhysicsIndexedTriangle(
                first: $0.0,
                second: $0.1,
                third: $0.2,
                materialIndex: 7
            )
        }
        return try SourcePhysicsShapeSnapshot(
            topology: .convexParts,
            parts: [SourcePhysicsMeshPartSnapshot(
                vertices: vertices,
                triangles: triangles
            )]
        )
    }

    private func makeStaticFloorGeometry()
        throws -> SourceDeterministicPhysicsStaticGeometry
    {
        let vertices = [
            SourceVector3(-20, -20, 0),
            SourceVector3(20, -20, 0),
            SourceVector3(20, 20, 0),
            SourceVector3(-20, 20, 0)
        ]
        let triangles = try [
            SourceDeterministicPhysicsStaticTriangle(
                first: 0,
                second: 1,
                third: 2,
                materialIndex: 3
            ),
            SourceDeterministicPhysicsStaticTriangle(
                first: 0,
                second: 2,
                third: 3,
                materialIndex: 3
            )
        ]
        return try SourceDeterministicPhysicsStaticGeometry(
            parts: [SourceDeterministicPhysicsStaticMeshPart(
                vertices: vertices,
                triangles: triangles
            )]
        )
    }

    private func makeStaticCubePart(
        center: SourceVector3,
        halfExtent: Float,
        material: Int
    ) throws -> SourceDeterministicPhysicsStaticMeshPart {
        let x = halfExtent
        let vertices = [
            center + SourceVector3(-x, -x, -x),
            center + SourceVector3(x, -x, -x),
            center + SourceVector3(x, x, -x),
            center + SourceVector3(-x, x, -x),
            center + SourceVector3(-x, -x, x),
            center + SourceVector3(x, -x, x),
            center + SourceVector3(x, x, x),
            center + SourceVector3(-x, x, x),
        ]
        let indices = [
            (0, 2, 1), (0, 3, 2),
            (4, 5, 6), (4, 6, 7),
            (0, 1, 5), (0, 5, 4),
            (1, 2, 6), (1, 6, 5),
            (2, 3, 7), (2, 7, 6),
            (3, 0, 4), (3, 4, 7),
        ]
        let triangles = try indices.map {
            try SourceDeterministicPhysicsStaticTriangle(
                first: $0.0,
                second: $0.1,
                third: $0.2,
                materialIndex: material
            )
        }
        return try SourceDeterministicPhysicsStaticMeshPart(
            vertices: vertices,
            triangles: triangles
        )
    }

    private func makeFrictionlessTestMaterialTable(
        _ pairs: [(Int, Int)]
    ) throws -> SourcePhysicsMaterialTable {
        let coefficients = try SourcePhysicsContactMaterialCoefficients(
            staticFriction: 0,
            dynamicFriction: 0,
            restitution: 0
        )
        return try SourcePhysicsMaterialTable(interactions: pairs.map {
            try SourcePhysicsMaterialInteraction(
                firstMaterialIndex: $0.0,
                secondMaterialIndex: $0.1,
                coefficients: coefficients
            )
        })
    }
}
