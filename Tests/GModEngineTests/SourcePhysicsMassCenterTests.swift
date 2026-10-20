import XCTest
@testable import GModEngine

final class SourcePhysicsMassCenterTests: XCTestCase {
    func testMassCenterMustBeFiniteAndWorldCenterCannotOverflow() throws {
        for value in [Float.nan, .infinity, -.infinity] {
            XCTAssertThrowsError(try SourcePhysicsMassProperties(
                massKilograms: 10, principalInertia: SourceVector3(2, 4, 8),
                massCenterLocal: SourceVector3(value, 0, 0)
            ))
        }
        XCTAssertThrowsError(try creation(
            center: SourceVector3(.greatestFiniteMagnitude, 0, 0),
            transform: SourceEntityTransform(
                origin: SourceVector3(.greatestFiniteMagnitude, 0, 0), angles: .zero
            )
        ))
        XCTAssertEqual(try SourcePhysicsMassProperties(
            massKilograms: 10, principalInertia: SourceVector3(2, 4, 8)
        ).massCenterLocal, .zero)
    }

    func testDynamicAndKinematicRotateAboutTheirMovingMassCenter() throws {
        for motion in [SourcePhysicsMotionType.dynamicBody, .kinematicBody] {
            let definition = try creation(
                center: SourceVector3(2, 0, 0),
                transform: SourceEntityTransform(origin: SourceVector3(10, 20, 30), angles: .zero),
                velocity: SourceVector3(4, -2, 1), angularVelocity: SourceVector3(0, 0, 6_000),
                motion: motion
            )
            let result = try simulate(definition)
            // A 90-degree +Z rotation takes local COM (2,0,0) to world (0,2,0).
            // COM translates by v*0.015; the model origin must orbit that COM.
            assertVector(result.transform.origin, SourceVector3(12.06, 17.97, 30.015))
            assertVector(result.massProperties.worldMassCenter(for: result.transform),
                SourceVector3(12.06, 19.97, 30.015))
            assertVector(result.linearVelocity, definition.linearVelocity)
            assertVector(result.angularVelocity, definition.angularVelocity)
        }
    }

    func testRotatedOffsetImpulseUsesMassCenterInsteadOfModelOrigin() throws {
        let definition = try creation(
            center: SourceVector3(2, 0, 0),
            transform: SourceEntityTransform(origin: SourceVector3(10, 20, 30), angles: SourceQAngle(yaw: 90))
        )
        let center = definition.massProperties.worldMassCenter(for: definition.transform)
        for (point, expectedAngular) in [
            (center, SourceVector3.zero),
            (definition.transform.origin, SourceVector3(0, 2 * 180 / Float.pi, 0))
        ] {
            let environment = SourceDeterministicPhysicsEnvironment()
            let snapshot = try environment.execute(SourcePhysicsCommandBatch(commands: [
                .init(sequence: 1, payload: .createBody(definition)),
                .init(sequence: 2, payload: .mutateBody(try .init(
                    bodyID: definition.bodyID,
                    mutation: .applyForceOffset(force: SourceVector3(0, 0, 4), worldPosition: point)
                )))
            ]))
            let result = try XCTUnwrap(snapshot.bodies.first)
            assertVector(result.linearVelocity, SourceVector3(0, 0, 0.4))
            assertVector(result.angularVelocity, expectedAngular, tolerance: 0.00003)
        }
    }

    func testMassChangeAndReplayRetainAuthoredCenter() throws {
        let definition = try creation(
            center: SourceVector3(2, -1, 3), velocity: SourceVector3(1, 2, 3),
            angularVelocity: SourceVector3(5, 7, 9)
        )
        let batch = try SourcePhysicsCommandBatch(commands: [
            .init(sequence: 1, payload: .createBody(definition)),
            .init(sequence: 2, payload: .mutateBody(try .init(
                bodyID: definition.bodyID, mutation: .setMassKilograms(20)
            ))),
            .init(sequence: 3, payload: .simulate(.init(simulationTick: 1)))
        ])
        let harness = SourcePhysicsDeterministicReplayHarness()
        let log = try harness.record(commandBatches: [batch], using: SourceDeterministicPhysicsEnvironment())
        let decoded = try SourcePhysicsReplayLog(canonicalBytes: log.canonicalBytes)
        XCTAssertEqual(decoded, log)
        let result = try XCTUnwrap(decoded.frames.first?.bodySnapshots.first)
        XCTAssertEqual(result.massProperties.massKilograms, 20)
        XCTAssertEqual(result.massProperties.principalInertia, SourceVector3(4, 8, 16))
        XCTAssertEqual(result.massProperties.massCenterLocal, definition.massProperties.massCenterLocal)
        _ = try harness.replay(decoded, using: SourceDeterministicPhysicsEnvironment())
        var legacyBytes = log.canonicalBytes
        legacyBytes[4] = 11
        XCTAssertThrowsError(try SourcePhysicsReplayLog(canonicalBytes: legacyBytes)) { error in
            XCTAssertEqual(error as? SourcePhysicsReplayError, .unsupportedFormatVersion(11))
        }
    }

    func testContactResponseDoesNotDependOnAuthoredModelOrigin() throws {
        let offset = SourceVector3(2, -3, 1)
        let rotation = SourceQAngle(pitch: 12, yaw: 37, roll: -23)
        let spin = SourceVector3(30, -40, 55)
        func run(center: SourceVector3, transform: SourceEntityTransform, velocity: SourceVector3) throws
            -> (SourcePhysicsBodySnapshot, SourceDeterministicPhysicsEnvironment.ContactSnapshot) {
            let environment = SourceDeterministicPhysicsEnvironment(
                configuration: try .init(gravity: .zero), staticCollisionScene: try floor(),
                materialTable: try SourcePhysicsMaterialTable(interactions: [
                    SourcePhysicsMaterialInteraction(firstMaterialIndex: 3, secondMaterialIndex: 7,
                        coefficients: SourcePhysicsContactMaterialCoefficients(
                            staticFriction: 0, dynamicFriction: 0, restitution: 0))
                ])
            )
            let body = try creation(
                center: center, transform: transform, velocity: velocity,
                angularVelocity: spin, shapeOffset: center, collisions: true
            )
            let snapshot = try environment.execute(SourcePhysicsCommandBatch(commands: [
                .init(sequence: 1, payload: .createBody(body)),
                .init(sequence: 2, payload: .simulate(.init(simulationTick: 1)))
            ]))
            return (try XCTUnwrap(snapshot.bodies.first), try XCTUnwrap(environment.latestContacts.first))
        }
        // Exercise both initial-overlap SAT and high-speed static CCD. The
        // physical solid, COM and inertia are identical in both model frames.
        for (height, velocity) in [(Float(0.2), SourceVector3(1, 2, -10)),
                                   (Float(5), SourceVector3(1, 2, -400))] {
            let centerTransform = SourceEntityTransform(origin: SourceVector3(0, 0, height), angles: rotation)
            let shiftedTransform = SourceEntityTransform(
                origin: centerTransform.origin - centerTransform.transformDirectionFromLocal(offset), angles: rotation
            )
            let (original, originalContact) = try run(center: .zero, transform: centerTransform, velocity: velocity)
            let (shifted, shiftedContact) = try run(center: offset, transform: shiftedTransform, velocity: velocity)
            XCTAssertGreaterThan((original.angularVelocity - spin).length, 1)
            assertVector(shifted.linearVelocity, original.linearVelocity, tolerance: 0.002)
            assertVector(shifted.angularVelocity, original.angularVelocity, tolerance: 0.02)
            assertVector(shifted.massProperties.worldMassCenter(for: shifted.transform),
                original.massProperties.worldMassCenter(for: original.transform), tolerance: 0.0001)
            assertVector(shiftedContact.position, originalContact.position, tolerance: 0.0001)
            assertVector(shiftedContact.normal, originalContact.normal, tolerance: 0.0001)
        }
    }

    func testFailedMutationBatchPreservesCenterMassAndPose() throws {
        let definition = try creation(center: SourceVector3(2, -1, 3))
        let environment = SourceDeterministicPhysicsEnvironment()
        let before = try environment.execute(SourcePhysicsCommandBatch(commands: [
            .init(sequence: 1, payload: .createBody(definition))
        ]))
        XCTAssertThrowsError(try environment.execute(SourcePhysicsCommandBatch(commands: [
            .init(sequence: 2, payload: .mutateBody(try .init(
                bodyID: definition.bodyID, mutation: .setMassKilograms(20)
            ))),
            .init(sequence: 3, payload: .mutateBody(try .init(
                bodyID: id(entry: 304), mutation: .setPosition(SourceVector3(99, 99, 99), teleport: true)
            )))
        ])))
        let after = try environment.execute(SourcePhysicsCommandBatch(commands: [
            .init(sequence: 2, payload: .mutateBody(try .init(bodyID: definition.bodyID, mutation: .wake)))
        ]))
        XCTAssertEqual(after.bodies, before.bodies)
    }

    func testFixedJointPoseCorrectionPreservesTotalMassCenter() throws {
        let first = try creation(center: SourceVector3(2, -3, 1))
        let secondTemplate = try creation(center: SourceVector3(-1, 2, -0.5),
            transform: SourceEntityTransform(origin: SourceVector3(4, 0, 0), angles: SourceQAngle(yaw: 90)))
        let second = try SourcePhysicsBodyCreationCommand(
            bodyID: id(entry: 304), shape: secondTemplate.shape,
            massProperties: secondTemplate.massProperties, transform: secondTemplate.transform,
            linearVelocity: .zero, angularVelocity: .zero, damping: .zero,
            motionType: .dynamicBody, materialIndex: 7, isGravityEnabled: false,
            isCollisionEnabled: false, startsAwake: true
        )
        let environment = SourceDeterministicPhysicsEnvironment()
        let prepared = try environment.execute(SourcePhysicsCommandBatch(commands: [
            .init(sequence: 1, payload: .createBody(first)),
            .init(sequence: 2, payload: .createBody(second)),
            .init(sequence: 3, payload: .createFixedConstraint(try .init(
                constraintID: SourcePhysicsConstraintID(rawValue: 1),
                referenceBodyID: first.bodyID, attachedBodyID: second.bodyID
            ))),
            .init(sequence: 4, payload: .mutateBody(try .init(
                bodyID: second.bodyID, mutation: .setAngles(SourceQAngle(pitch: 30, yaw: 120, roll: -15))
            )))
        ]))
        func totalCenter(_ bodies: [SourcePhysicsBodySnapshot]) -> SourceVector3 {
            bodies.reduce(.zero) { $0 + $1.massProperties.worldMassCenter(for: $1.transform) } / 2
        }
        let solved = try environment.execute(SourcePhysicsCommandBatch(commands: [
            .init(sequence: 5, payload: .simulate(.init(simulationTick: 1)))
        ]))
        assertVector(totalCenter(solved.bodies), totalCenter(prepared.bodies), tolerance: 0.0001)
        let a = try XCTUnwrap(solved.bodies.first { $0.bodyID == first.bodyID })
        let b = try XCTUnwrap(solved.bodies.first { $0.bodyID == second.bodyID })
        assertVector(a.transform.inverseTransformPointToLocal(b.transform.origin), SourceVector3(4, 0, 0), tolerance: 0.0001)
    }

    private func simulate(_ body: SourcePhysicsBodyCreationCommand) throws -> SourcePhysicsBodySnapshot {
        let environment = SourceDeterministicPhysicsEnvironment(configuration: try .init(gravity: .zero))
        return try XCTUnwrap(environment.execute(SourcePhysicsCommandBatch(commands: [
            .init(sequence: 1, payload: .createBody(body)),
            .init(sequence: 2, payload: .simulate(.init(simulationTick: 1)))
        ])).bodies.first)
    }

    private func id(entry: Int = 303) throws -> SourcePhysicsBodyID {
        try SourcePhysicsBodyID(entityIdentity: SourceCanonicalEntityIdentity(
            handle: SourceBaseHandle(entryIndex: entry, serialNumber: 17)), solidIndex: 0)
    }

    private func creation(
        center: SourceVector3, transform: SourceEntityTransform = .identity,
        velocity: SourceVector3 = .zero, angularVelocity: SourceVector3 = .zero,
        motion: SourcePhysicsMotionType = .dynamicBody,
        shapeOffset: SourceVector3 = .zero, collisions: Bool = false
    ) throws -> SourcePhysicsBodyCreationCommand {
        let vertices = [SourceVector3(0, 0, -0.5), SourceVector3(1, 0, 0.5),
            SourceVector3(-0.5, 0.8660254, 0.5), SourceVector3(-0.5, -0.8660254, 0.5)]
            .map { $0 + shapeOffset }
        let triangles = try [(0, 2, 1), (0, 3, 2), (0, 1, 3), (1, 2, 3)].map {
            try SourcePhysicsIndexedTriangle(first: $0.0, second: $0.1, third: $0.2, materialIndex: 7)
        }
        return try SourcePhysicsBodyCreationCommand(
            bodyID: id(), shape: SourcePhysicsShapeSnapshot(topology: .convexParts,
                parts: [SourcePhysicsMeshPartSnapshot(vertices: vertices, triangles: triangles)]),
            massProperties: SourcePhysicsMassProperties(massKilograms: 10,
                principalInertia: SourceVector3(2, 4, 8), massCenterLocal: center),
            transform: transform, linearVelocity: velocity, angularVelocity: angularVelocity,
            damping: .zero, motionType: motion, materialIndex: 7,
            isGravityEnabled: false, isCollisionEnabled: collisions, startsAwake: true
        )
    }

    private func floor() throws -> SourceDeterministicPhysicsStaticScene {
        try SourceDeterministicPhysicsStaticScene(bodyID: id(entry: 0),
            geometry: SourceDeterministicPhysicsStaticGeometry(parts: [
                SourceDeterministicPhysicsStaticMeshPart(vertices: [SourceVector3(-20, -20, 0),
                    SourceVector3(20, -20, 0), SourceVector3(0, 20, 0)],
                    triangles: [SourceDeterministicPhysicsStaticTriangle(first: 0, second: 1, third: 2, materialIndex: 3)],
                    topology: .openTriangleMesh)
            ]), contents: .solid)
    }

    private func assertVector(_ actual: SourceVector3, _ expected: SourceVector3,
                              tolerance: Float = 0.00001, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.x, expected.x, accuracy: tolerance, file: file, line: line)
        XCTAssertEqual(actual.y, expected.y, accuracy: tolerance, file: file, line: line)
        XCTAssertEqual(actual.z, expected.z, accuracy: tolerance, file: file, line: line)
    }
}
