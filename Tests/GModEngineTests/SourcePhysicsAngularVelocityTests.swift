import XCTest
@testable import GModEngine

final class SourcePhysicsAngularVelocityTests: XCTestCase {
    func testEachLocalAxisIsAnAxisTwistNotAnEulerRateForDynamicAndKinematicBodies() throws {
        let axes = [SourceVector3(1, 0, 0), SourceVector3(0, 1, 0), SourceVector3(0, 0, 1)]
        let motionTypes: [SourcePhysicsMotionType] = [.dynamicBody, .kinematicBody]
        for motion in motionTypes {
            for axis in axes {
                let body = try simulate(angles: .zero, velocity: axis * 6_000, motion: motion)
                assertBasis(body.transform.angles, start: .zero, axis: axis, degrees: 90)
            }
        }
    }

    func testMixedAxisRotationUsesLocalFrameAndRemainsStableAcrossMultipleTicks() throws {
        let angles = SourceQAngle(pitch: 23, yaw: 77, roll: -41)
        let velocity = SourceVector3(30, -80, 55)
        let speed = velocity.length
        let body = try simulate(angles: angles, velocity: velocity, ticks: 40)
        assertBasis(body.transform.angles, start: angles, axis: velocity / speed,
            degrees: speed * 0.015 * 40, tolerance: 0.00003)
        XCTAssertEqual(body.angularVelocity, velocity, "The public snapshot retains local degrees/second")
    }

    func testRotatedOffsetImpulseAndWorldTorquePublishLocalAngularVelocity() throws {
        let angles = SourceQAngle(pitch: 0, yaw: 90, roll: 0)
        let offset = try simulate(angles: angles, velocity: .zero, ticks: 0,
            mutation: .applyForceOffset(force: SourceVector3(0, 0, 4), worldPosition: SourceVector3(0, 2, 0)))
        assertVector(offset.angularVelocity, SourceVector3(0, -2 * 180 / Float.pi, 0), tolerance: 0.00002)
        assertVector(offset.linearVelocity, SourceVector3(0, 0, 0.4))
        let torque = try simulate(angles: angles, velocity: .zero, ticks: 0,
            mutation: .applyTorqueCenter(SourceVector3(8, 0, 0)))
        assertVector(torque.angularVelocity, SourceVector3(0, -2, 0))
    }

    func testShortestLocalOrientationErrorReachesTargetAcrossWrapAndNearGimbal() {
        for (start, target) in [
            (SourceQAngle(pitch: 12, yaw: 179, roll: -27), SourceQAngle(pitch: -18, yaw: -178, roll: 38)),
            (SourceQAngle(pitch: 89, yaw: 70, roll: 35), SourceQAngle(pitch: -89, yaw: -80, roll: -40))
        ] {
            let rotation = SourcePhysicsConstraintQuaternion(start)
            let error = rotation.localAngularDisplacement(to: SourcePhysicsConstraintQuaternion(target))
            XCTAssertLessThanOrEqual(error.length, 180.0001)
            let reached = rotation.advanced(localAngularVelocity: error / 0.015, deltaSeconds: 0.015).sourceAngles
            let a = reached.sourceBasis, b = target.sourceBasis
            assertVector(a.forward, b.forward, tolerance: 0.00002)
            assertVector(a.right, b.right, tolerance: 0.00002)
            assertVector(a.up, b.up, tolerance: 0.00002)
        }
    }

    private func simulate(angles: SourceQAngle, velocity: SourceVector3,
                          motion: SourcePhysicsMotionType = .dynamicBody, ticks: Int = 1,
                          mutation: SourcePhysicsBodyMutation? = nil) throws -> SourcePhysicsBodySnapshot {
        let id = try SourcePhysicsBodyID(entityIdentity: SourceCanonicalEntityIdentity(
            handle: SourceBaseHandle(entryIndex: 300, serialNumber: 17)), solidIndex: 0)
        let vertices = [SourceVector3(0, 0, 0), SourceVector3(1, 0, 0), SourceVector3(0, 1, 0), SourceVector3(0, 0, 1)]
        let triangles = try [(0, 2, 1), (0, 1, 3), (0, 3, 2), (1, 2, 3)].map {
            try SourcePhysicsIndexedTriangle(first: $0.0, second: $0.1, third: $0.2, materialIndex: 0)
        }
        let shape = try SourcePhysicsShapeSnapshot(topology: .convexParts,
            parts: [SourcePhysicsMeshPartSnapshot(vertices: vertices, triangles: triangles)])
        let creation = try SourcePhysicsBodyCreationCommand(bodyID: id, shape: shape,
            massProperties: SourcePhysicsMassProperties(massKilograms: 10, principalInertia: SourceVector3(2, 4, 8)),
            transform: SourceEntityTransform(origin: .zero, angles: angles), linearVelocity: .zero,
            angularVelocity: velocity, damping: .zero, motionType: motion, materialIndex: 0,
            isGravityEnabled: false, isCollisionEnabled: false, startsAwake: true)
        let environment = SourceDeterministicPhysicsEnvironment(configuration: try .init(gravity: .zero))
        var sequence: UInt64 = 1
        var commands = [SourcePhysicsCommand(sequence: sequence, payload: .createBody(creation))]
        if let mutation {
            sequence += 1
            commands.append(SourcePhysicsCommand(sequence: sequence, payload: .mutateBody(
                try SourcePhysicsBodyMutationCommand(bodyID: id, mutation: mutation))))
        }
        for tick in 0..<ticks {
            sequence += 1
            commands.append(SourcePhysicsCommand(sequence: sequence, payload: .simulate(.init(simulationTick: UInt64(tick + 1)))))
        }
        return try XCTUnwrap(environment.execute(SourcePhysicsCommandBatch(commands: commands)).bodies.first)
    }

    private func assertBasis(_ actual: SourceQAngle, start: SourceQAngle, axis: SourceVector3,
                             degrees: Float, tolerance: Float = 0.00001) {
        // Independent Rodrigues reference, not the production quaternion code.
        let radians = degrees * Float.pi / 180
        let c = cos(radians), s = sin(radians)
        func rotated(_ v: SourceVector3) -> SourceVector3 {
            let cross = SourceVector3(axis.y * v.z - axis.z * v.y,
                axis.z * v.x - axis.x * v.z, axis.x * v.y - axis.y * v.x)
            let dot = axis.x * v.x + axis.y * v.y + axis.z * v.z
            let local = v * c + cross * s + axis * (dot * (1 - c))
            return SourceEntityTransform(origin: .zero, angles: start).transformDirectionFromLocal(local)
        }
        let basis = actual.sourceBasis
        assertVector(basis.forward, rotated(SourceVector3(1, 0, 0)), tolerance: tolerance)
        assertVector(-basis.right, rotated(SourceVector3(0, 1, 0)), tolerance: tolerance)
        assertVector(basis.up, rotated(SourceVector3(0, 0, 1)), tolerance: tolerance)
    }

    private func assertVector(_ actual: SourceVector3, _ expected: SourceVector3, tolerance: Float = 0.00001,
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.x, expected.x, accuracy: tolerance, file: file, line: line)
        XCTAssertEqual(actual.y, expected.y, accuracy: tolerance, file: file, line: line)
        XCTAssertEqual(actual.z, expected.z, accuracy: tolerance, file: file, line: line)
    }
}
