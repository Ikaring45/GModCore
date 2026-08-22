import XCTest
@testable import GModEngine

final class SourceNoClipMovementTests: XCTestCase {
    func testDefaultMovevarsMatchSourceSDK2013() {
        let parameters = SourceNoClipMovementParameters()
        XCTAssertEqual(parameters.speedFactor, 5)
        XCTAssertEqual(parameters.maximumAcceleration, 5)
        XCTAssertEqual(parameters.maximumSpeed, 320)
        XCTAssertEqual(parameters.friction, 4)
        XCTAssertEqual(SourceGameMovement.status(of: .noClipMove), .equationCompatible)
    }

    func testFullNoClipMoveUsesViewBasisAndDoesNotTraceOrApplyGravity() {
        let parameters = SourceNoClipMovementParameters(
            frameTime: 0.015,
            speedFactor: 5,
            maximumAcceleration: 0,
            maximumSpeed: 320,
            friction: 4
        )
        var move = SourceMoveData(
            origin: SourceVector3(10, 20, 30),
            velocity: SourceVector3(9, 8, 7)
        )
        let command = SourceUserCommand(
            viewAngles: SourceQAngle(pitch: 90, yaw: 0),
            forwardMove: 100,
            sideMove: 20,
            upMove: 10
        )

        SourceGameMovement.fullNoClipMove(
            move: &move,
            command: command,
            parameters: parameters
        )

        // At pitch 90, forward is -Z and Source right at yaw 0 is -Y.
        let expectedVelocity = SourceVector3(0, -100, -450)
        XCTAssertEqual(move.velocity.x, expectedVelocity.x, accuracy: 0.000_1)
        XCTAssertEqual(move.velocity.y, expectedVelocity.y, accuracy: 0.000_01)
        XCTAssertEqual(move.velocity.z, expectedVelocity.z, accuracy: 0.000_01)
        XCTAssertEqual(move.origin.x, 10, accuracy: 0.000_01)
        XCTAssertEqual(move.origin.y, 18.5, accuracy: 0.000_01)
        XCTAssertEqual(move.origin.z, 23.25, accuracy: 0.000_01)
    }

    func testPositiveAccelerationAndSourceFrictionPreserveExpressionOrder() {
        let parameters = SourceNoClipMovementParameters(
            frameTime: 0.015,
            speedFactor: 5,
            maximumAcceleration: 5,
            maximumSpeed: 320,
            friction: 4
        )
        var move = SourceMoveData(surfaceFriction: 1)
        let command = SourceUserCommand(
            viewAngles: .zero,
            forwardMove: 100
        )

        SourceGameMovement.fullNoClipMove(
            move: &move,
            command: command,
            parameters: parameters
        )

        let accelerated = Float(5) * Float(0.015) * Float(500)
        let maxWishSpeed = Float(320) * Float(5)
        let drop = (maxWishSpeed / Float(4)) * Float(4) * Float(0.015)
        let expectedSpeed = accelerated * ((accelerated - drop) / accelerated)
        XCTAssertEqual(move.velocity.x, expectedSpeed, accuracy: 0.000_01)
        XCTAssertEqual(move.origin.x, expectedSpeed * 0.015, accuracy: 0.000_01)
    }

    func testSpeedButtonHalvesInputAfterComputingTheNormalSpeedCap() {
        let parameters = SourceNoClipMovementParameters(
            frameTime: 1,
            speedFactor: 5,
            maximumAcceleration: 0,
            maximumSpeed: 320,
            friction: 4
        )
        var move = SourceMoveData()
        let command = SourceUserCommand(
            viewAngles: .zero,
            forwardMove: 100,
            buttons: [.speed]
        )

        SourceGameMovement.fullNoClipMove(
            move: &move,
            command: command,
            parameters: parameters
        )

        XCTAssertEqual(move.velocity, SourceVector3(250, 0, 0))
        XCTAssertEqual(move.origin, SourceVector3(250, 0, 0))
    }

    func testNegativeAccelerationMovesOnceThenClearsVelocity() {
        let parameters = SourceNoClipMovementParameters(
            frameTime: 0.5,
            speedFactor: 1,
            maximumAcceleration: -1,
            maximumSpeed: 320,
            friction: 4
        )
        var move = SourceMoveData(origin: SourceVector3(1, 2, 3))
        let command = SourceUserCommand(viewAngles: .zero, forwardMove: 10)

        SourceGameMovement.fullNoClipMove(
            move: &move,
            command: command,
            parameters: parameters
        )

        XCTAssertEqual(move.origin, SourceVector3(6, 2, 3))
        XCTAssertEqual(move.velocity, .zero)
    }
}
