import XCTest
@testable import GModEngine

final class SourceMovementTests: XCTestCase {
    func testUserCommandMakeInertMatchesSourceFieldScope() {
        var command = SourceUserCommand(
            commandNumber: 12,
            tickCount: 34,
            viewAngles: SourceQAngle(pitch: 1, yaw: 2, roll: 3),
            forwardMove: 100,
            sideMove: -20,
            upMove: 5,
            buttons: [.attack, .jump],
            impulse: 9,
            weaponSelect: 4,
            randomSeed: 99,
            mouseDX: 7,
            mouseDY: -8,
            hasBeenPredicted: true
        )

        command.makeInert()

        XCTAssertEqual(command.commandNumber, 12)
        XCTAssertEqual(command.tickCount, 34)
        XCTAssertEqual(command.viewAngles, .zero)
        XCTAssertEqual(command.forwardMove, 0)
        XCTAssertEqual(command.sideMove, 0)
        XCTAssertEqual(command.upMove, 0)
        XCTAssertEqual(command.buttons, [])
        XCTAssertEqual(command.impulse, 0)
        XCTAssertEqual(command.weaponSelect, 4)
        XCTAssertEqual(command.randomSeed, 99)
        XCTAssertEqual(command.mouseDX, 7)
        XCTAssertEqual(command.mouseDY, -8)
        XCTAssertTrue(command.hasBeenPredicted)
    }

    func testStartAndFinishGravityRetainSourceFloatExpressionOrder() {
        let parameters = SourceMovementParameters(frameTime: Float(0.015), gravity: 800)
        var move = SourceMoveData(
            velocity: SourceVector3(0, 0, 100),
            baseVelocity: SourceVector3(2, 3, 10),
            entityGravity: 0
        )

        var expectedAfterStart = Float(100)
        expectedAfterStart -= Float(1) * Float(800) * Float(0.5) * Float(0.015)
        expectedAfterStart += Float(10) * Float(0.015)

        SourceGameMovement.startGravity(move: &move, parameters: parameters)

        XCTAssertEqual(move.velocity.z, expectedAfterStart)
        XCTAssertEqual(move.baseVelocity, SourceVector3(2, 3, 0))

        var expectedAfterFinish = expectedAfterStart
        expectedAfterFinish -= Float(1) * Float(800) * Float(0.015) * Float(0.5)
        SourceGameMovement.finishGravity(move: &move, parameters: parameters)
        XCTAssertEqual(move.velocity.z, expectedAfterFinish)
    }

    func testFinishGravityIsSuppressedDuringWaterJump() {
        let parameters = SourceMovementParameters()
        var move = SourceMoveData(
            velocity: SourceVector3(0, 0, 50),
            waterJumpTime: 0.25
        )

        SourceGameMovement.finishGravity(move: &move, parameters: parameters)

        XCTAssertEqual(move.velocity.z, 50)
    }

    func testCheckVelocityResetsNonFiniteStateAndClampsEachAxis() {
        XCTAssertEqual(SourceMovementParameters().maximumVelocity, 3500)
        let parameters = SourceMovementParameters(maximumVelocity: 100)
        var move = SourceMoveData(
            origin: SourceVector3(.nan, .infinity, -.infinity),
            velocity: SourceVector3(101, -101, .infinity)
        )

        SourceGameMovement.checkVelocity(move: &move, parameters: parameters)

        XCTAssertEqual(move.origin, .zero)
        XCTAssertEqual(move.velocity, SourceVector3(100, -100, 0))
    }

    func testGravityHalvesRunCheckVelocityAtTheOfficialCallSites() {
        let parameters = SourceMovementParameters(
            frameTime: 1,
            gravity: 800,
            maximumVelocity: 100
        )
        var startMove = SourceMoveData(
            origin: SourceVector3(.nan, 2, 3),
            velocity: SourceVector3(250, -250, 0),
            baseVelocity: SourceVector3(0, 0, .infinity)
        )

        SourceGameMovement.startGravity(move: &startMove, parameters: parameters)

        XCTAssertEqual(startMove.origin, SourceVector3(0, 2, 3))
        XCTAssertEqual(startMove.velocity, SourceVector3(100, -100, 0))
        XCTAssertEqual(startMove.baseVelocity.z, 0)

        var finishMove = SourceMoveData(velocity: SourceVector3(0, 0, -99))
        SourceGameMovement.finishGravity(move: &finishMove, parameters: parameters)
        XCTAssertEqual(finishMove.velocity.z, -100)
    }

    func testFrictionUsesStopSpeedAndScalesFullVelocity() {
        let parameters = SourceMovementParameters(
            frameTime: Float(0.015),
            friction: 4,
            stopSpeed: 100
        )
        var move = SourceMoveData(
            velocity: SourceVector3(30, 40, 0),
            isOnGround: true,
            surfaceFriction: 0.5
        )

        let speed = Float(50)
        let friction = Float(4) * Float(0.5)
        let drop = Float(100) * friction * Float(0.015)
        let ratio = (speed - drop) / speed
        let expectedVelocity = SourceVector3(30, 40, 0) * ratio
        let expectedWish = -(Float(1) - ratio) * expectedVelocity

        SourceGameMovement.friction(move: &move, parameters: parameters)

        XCTAssertEqual(move.velocity, expectedVelocity)
        XCTAssertEqual(move.outputWishVelocity, expectedWish)
    }

    func testGroundAccelerationUsesSourceEquationAndCapsAtAddSpeed() {
        let parameters = SourceMovementParameters(
            frameTime: Float(0.015),
            acceleration: 10
        )
        var move = SourceMoveData(
            velocity: SourceVector3(10, 0, 0),
            surfaceFriction: 0.5
        )

        SourceGameMovement.accelerate(
            move: &move,
            wishDirection: SourceVector3(1, 0, 0),
            wishSpeed: 100,
            parameters: parameters
        )

        let accelerationSpeed = Float(10) * Float(0.015) * Float(100) * Float(0.5)
        XCTAssertEqual(move.velocity, SourceVector3(10 + accelerationSpeed, 0, 0))

        SourceGameMovement.accelerate(
            move: &move,
            wishDirection: SourceVector3(1, 0, 0),
            wishSpeed: 20,
            acceleration: 10_000,
            parameters: parameters
        )
        XCTAssertEqual(move.velocity.x, 20, "acceleration must cap at remaining addSpeed")
    }

    func testAirAccelerationCapsAddSpeedButUsesUncappedWishSpeedInEquation() {
        let parameters = SourceMovementParameters(
            frameTime: Float(0.015),
            airAcceleration: 10,
            airSpeedCap: 30
        )
        var move = SourceMoveData(surfaceFriction: 1)

        SourceGameMovement.airAccelerate(
            move: &move,
            wishDirection: SourceVector3(1, 0, 0),
            wishSpeed: 100,
            parameters: parameters
        )

        let expected = Float(10) * Float(100) * Float(0.015) * Float(1)
        XCTAssertEqual(expected, 15)
        XCTAssertEqual(move.velocity, SourceVector3(expected, 0, 0))
        XCTAssertEqual(move.outputWishVelocity, SourceVector3(expected, 0, 0))
    }

    func testAccelerationRejectsDeadAndWaterJumpingPlayers() {
        let parameters = SourceMovementParameters()
        for blockedMove in [
            SourceMoveData(isDead: true),
            SourceMoveData(waterJumpTime: 0.25),
        ] {
            var groundMove = blockedMove
            SourceGameMovement.accelerate(
                move: &groundMove,
                wishDirection: SourceVector3(1, 0, 0),
                wishSpeed: 100,
                parameters: parameters
            )
            XCTAssertEqual(groundMove.velocity, .zero)

            var airMove = blockedMove
            SourceGameMovement.airAccelerate(
                move: &airMove,
                wishDirection: SourceVector3(1, 0, 0),
                wishSpeed: 100,
                parameters: parameters
            )
            XCTAssertEqual(airMove.velocity, .zero)
        }
    }

    func testStepWaterAndVPhysicsAreExplicitlyUnimplemented() {
        for feature in [
            SourceMovementFeature.stepMove,
            .waterMove,
            .vPhysics,
        ] {
            XCTAssertEqual(SourceGameMovement.status(of: feature), .unimplemented)
            XCTAssertThrowsError(try SourceGameMovement.requireImplemented(feature)) { error in
                XCTAssertEqual(error as? SourceMovementError, .unimplemented(feature))
            }
        }

        for feature in [
            SourceMovementFeature.gravitySplit,
            .friction,
            .groundAcceleration,
            .airAcceleration,
        ] {
            XCTAssertEqual(SourceGameMovement.status(of: feature), .equationCompatible)
            XCTAssertNoThrow(try SourceGameMovement.requireImplemented(feature))
        }
    }
}
