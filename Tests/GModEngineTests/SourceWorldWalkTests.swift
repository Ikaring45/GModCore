import Foundation
import XCTest
@testable import GModEngine
import GModGameAssets

private struct CollisionWorldWalkProvider: SourceWorldWalkCollisionProvider {
    let world: SourceCollisionWorld

    func traceWorldWalk(
        _ ray: SourceRay,
        mask: SourceContents
    ) throws -> SourceGameTrace {
        world.trace(ray, mask: mask)
    }

    func worldWalkPointContents(
        at point: SourceVector3,
        mask: SourceContents
    ) throws -> SourceContents {
        world.pointContents(at: point, mask: mask)
    }
}

private struct ForcedWorldWalkProvider: SourceWorldWalkCollisionProvider {
    enum Mode {
        case dynamicEntity
        case displacement
        case missingIdentity
        case nonUnitNormal
        case inconsistentEndPosition
    }

    let mode: Mode

    func traceWorldWalk(
        _ ray: SourceRay,
        mask _: SourceContents
    ) throws -> SourceGameTrace {
        var result = SourceGameTrace(ray: ray)
        result.fraction = 0.5
        result.endPosition = ray.actualStart + ray.delta * Float(0.5)
        result.plane = SourcePlane(normal: SourceVector3(0, 0, 1))
        switch mode {
        case .dynamicEntity:
            result.entityHandle = SourceBaseHandle(entryIndex: 7, serialNumber: 1)
        case .displacement:
            result.entityHandle = SourceBaseHandle(entryIndex: 0, serialNumber: 0)
            result.displacementFlags = 1
        case .missingIdentity:
            result.entityHandle = nil
        case .nonUnitNormal:
            result.entityHandle = SourceBaseHandle(entryIndex: 0, serialNumber: 0)
            result.plane = SourcePlane(normal: SourceVector3(0, 0, 2))
        case .inconsistentEndPosition:
            result.entityHandle = SourceBaseHandle(entryIndex: 0, serialNumber: 0)
            result.endPosition.x += 1
        }
        return result
    }

    func worldWalkPointContents(
        at _: SourceVector3,
        mask _: SourceContents
    ) throws -> SourceContents {
        .empty
    }
}

private struct FractionZeroGroundProvider: SourceWorldWalkCollisionProvider {
    func traceWorldWalk(
        _ ray: SourceRay,
        mask _: SourceContents
    ) throws -> SourceGameTrace {
        var result = SourceGameTrace(ray: ray)
        if ray.delta == SourceVector3(0, 0, -SourceWorldWalkSolver.groundProbeDistance) {
            result.fraction = 0
            result.endPosition = ray.actualStart
            result.plane = SourcePlane(normal: SourceVector3(0, 0, 1))
            result.entityHandle = SourceBaseHandle(entryIndex: 0, serialNumber: 0)
        }
        return result
    }

    func worldWalkPointContents(
        at _: SourceVector3,
        mask _: SourceContents
    ) throws -> SourceContents {
        .empty
    }
}

private enum WorldWalkInjectedTraceError: Error, Equatable {
    case ladderContact
    case stepUp
}

private struct LadderContactThrowingProvider: SourceWorldWalkCollisionProvider {
    func traceWorldWalk(
        _ ray: SourceRay,
        mask _: SourceContents
    ) throws -> SourceGameTrace {
        if ray.delta.z == 0, ray.delta.lengthSquared > 0 {
            throw WorldWalkInjectedTraceError.ladderContact
        }
        return SourceGameTrace(ray: ray)
    }

    func worldWalkPointContents(
        at _: SourceVector3,
        mask _: SourceContents
    ) throws -> SourceContents {
        .empty
    }
}

private struct StepUpThrowingProvider: SourceWorldWalkCollisionProvider {
    let world: SourceCollisionWorld

    func traceWorldWalk(
        _ ray: SourceRay,
        mask: SourceContents
    ) throws -> SourceGameTrace {
        if ray.delta.x == 0,
           ray.delta.y == 0,
           ray.delta.z > SourceWorldWalkConfiguration.sourceSDKDefaultStepSize {
            throw WorldWalkInjectedTraceError.stepUp
        }
        return world.trace(ray, mask: mask)
    }

    func worldWalkPointContents(
        at point: SourceVector3,
        mask: SourceContents
    ) throws -> SourceContents {
        world.pointContents(at: point, mask: mask)
    }
}

final class SourceWorldWalkTests: XCTestCase {
    private let worldHandle = SourceBaseHandle(entryIndex: 0, serialNumber: 0)

    func testRecoverableClassificationIncludesOnlyExplicitUnsupportedErrors() {
        for feature in SourceWorldWalkUnsupportedFeature.allCases {
            XCTAssertEqual(
                SourceWorldWalkError.unsupported(feature)
                    .recoverableUnsupportedReason,
                .feature(feature)
            )
        }
        XCTAssertEqual(
            SourceWorldWalkError.unsupportedDynamicEntity(7)
                .recoverableUnsupportedReason,
            .dynamicEntityCollision(entityIndex: 7)
        )

        let fatalErrors: [SourceWorldWalkError] = [
            .nonFinite("velocity.x"),
            .invalidConfiguration("frameTime"),
            .embeddedInWorld(allSolid: false),
            .embeddedInWorld(allSolid: true),
            .hitMissingWorldIdentity,
            .inconsistentTrace("HitPos"),
        ]
        for error in fatalErrors {
            XCTAssertNil(error.recoverableUnsupportedReason)
        }
    }

    func testStandingHullGroundWalkUsesExistingFloatEquationsAndSnapsToFloor() throws {
        let solver = makeSolver(world: floorWorld(), maximumSpeed: 200)
        let initial = SourceWorldWalkState(
            origin: SourceVector3(0, 0, 1),
            viewAngles: .zero
        )
        let command = SourceUserCommand(
            commandNumber: 1,
            tickCount: 1,
            viewAngles: .zero,
            forwardMove: 200,
            buttons: [.forward]
        )

        let tick = try solver.simulate(state: initial, command: command)

        XCTAssertEqual(tick.commandNumber, 1)
        XCTAssertEqual(tick.state.velocity.x, 29.999_998, accuracy: 0.000_001)
        XCTAssertEqual(tick.state.velocity.y, 0, accuracy: 0.000_001)
        XCTAssertEqual(tick.state.velocity.z, 0, accuracy: 0.000_001)
        XCTAssertEqual(tick.state.origin.x, 0.45, accuracy: 0.000_001)
        XCTAssertEqual(tick.state.origin.y, 0, accuracy: 0.000_001)
        XCTAssertEqual(
            tick.state.origin.z,
            SourceCollisionConstants.distanceEpsilon,
            accuracy: 0.000_001
        )
        XCTAssertTrue(tick.state.isOnGround)
        XCTAssertEqual(tick.bumpCount, 1)
        XCTAssertEqual(tick.collisionCount, 0)
        XCTAssertTrue(tick.didSnapToGround)
        XCTAssertEqual(initial.origin, SourceVector3(0, 0, 1), "input state is immutable")
    }

    func testSixteenGroundTicksAreExactAndReplayDeterministically() throws {
        let solver = makeSolver(world: floorWorld(), maximumSpeed: 200)
        let initial = SourceWorldWalkState(
            origin: SourceVector3(0, 0, SourceCollisionConstants.distanceEpsilon),
            viewAngles: .zero,
            isOnGround: true
        )

        func replay() throws -> SourceWorldWalkState {
            var state = initial
            for commandNumber in Int32(1) ... Int32(16) {
                state = try solver.simulate(
                    state: state,
                    command: SourceUserCommand(
                        commandNumber: commandNumber,
                        tickCount: commandNumber,
                        forwardMove: 200,
                        buttons: [.forward]
                    )
                ).state
            }
            return state
        }

        let first = try replay()
        let second = try replay()
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.origin.x, 37.453_45, accuracy: 0.001)
        XCTAssertEqual(first.origin.y, 0, accuracy: 0.000_001)
        XCTAssertEqual(first.velocity.x, 200, accuracy: 0.000_1)
        XCTAssertTrue(first.isOnGround)
    }

    func testHorizontalBasisPreservesForwardYawAndPositiveSideSigns() throws {
        let solver = makeSolver(world: floorWorld(), maximumSpeed: 200)
        let origin = SourceVector3(0, 0, SourceCollisionConstants.distanceEpsilon)

        let yawNinety = try solver.simulate(
            state: SourceWorldWalkState(origin: origin, isOnGround: true),
            command: SourceUserCommand(
                commandNumber: 1,
                viewAngles: SourceQAngle(pitch: 0, yaw: 90, roll: 0),
                forwardMove: 200
            )
        ).state
        XCTAssertEqual(yawNinety.origin.x, 0, accuracy: 0.000_001)
        XCTAssertGreaterThan(yawNinety.origin.y, 0)

        let positiveSide = try solver.simulate(
            state: SourceWorldWalkState(origin: origin, isOnGround: true),
            command: SourceUserCommand(commandNumber: 1, sideMove: 200)
        ).state
        XCTAssertEqual(positiveSide.origin.x, 0, accuracy: 0.000_001)
        XCTAssertLessThan(positiveSide.origin.y, 0)
    }

    func testFractionZeroUpwardPlaneStillCategorizesAsGround() throws {
        let solver = SourceWorldWalkSolver(
            collisionProvider: FractionZeroGroundProvider(),
            configuration: SourceWorldWalkConfiguration(maximumSpeed: 200)
        )
        let tick = try solver.simulate(
            state: SourceWorldWalkState(origin: SourceVector3(0, 0, 10)),
            command: SourceUserCommand(commandNumber: 1)
        )

        XCTAssertTrue(tick.state.isOnGround)
        XCTAssertEqual(tick.state.origin, SourceVector3(0, 0, 10))
        XCTAssertEqual(tick.state.movement.surfaceFriction, 1)
    }

    func testStandingPlayerSlidesAlongWorldWallWithAtMostFourBumps() throws {
        var world = floorWorld()
        world.addAxisAlignedBox(
            SourceAABBCollider(
                mins: SourceVector3(18, -100, -100),
                maxs: SourceVector3(30, 100, 100),
                contents: .solid,
                entityHandle: worldHandle
            )
        )
        let solver = makeSolver(world: world, maximumSpeed: 200)
        let initial = SourceWorldWalkState(
            origin: SourceVector3(0, 0, SourceCollisionConstants.distanceEpsilon),
            velocity: SourceVector3(200, -100, 0),
            viewAngles: .zero,
            isOnGround: true
        )

        let tick = try solver.simulate(
            state: initial,
            command: SourceUserCommand(commandNumber: 1, tickCount: 1)
        )

        XCTAssertGreaterThan(tick.collisionCount, 0)
        XCTAssertLessThanOrEqual(tick.bumpCount, SourceWorldWalkSolver.maximumBumps)
        XCTAssertEqual(tick.state.origin.x, 1.968_75, accuracy: 0.000_1)
        XCTAssertLessThan(tick.state.origin.y, -1)
        XCTAssertEqual(tick.state.velocity.x, 0, accuracy: 0.000_1)
        XCTAssertLessThan(tick.state.velocity.y, 0)
        XCTAssertTrue(tick.state.isOnGround)
    }

    func testGroundedPlayerStepsOntoLowWorldBrush() throws {
        let solver = makeSolver(world: stairWorld(height: 12), maximumSpeed: 200)
        let initial = SourceWorldWalkState(
            origin: SourceVector3(-16, 0, SourceCollisionConstants.distanceEpsilon),
            velocity: SourceVector3(200, 0, 0),
            isOnGround: true
        )

        let tick = try solver.simulate(
            state: initial,
            command: SourceUserCommand(
                commandNumber: 1,
                forwardMove: 200,
                buttons: [.forward]
            )
        )

        XCTAssertGreaterThan(tick.state.origin.x, -14)
        XCTAssertEqual(
            tick.state.origin.z,
            12 + SourceCollisionConstants.distanceEpsilon,
            accuracy: 0.000_1
        )
        XCTAssertEqual(tick.state.velocity.z, 0, accuracy: 0.000_1)
        XCTAssertEqual(tick.stepHeight, 12, accuracy: 0.000_1)
        XCTAssertTrue(tick.state.isOnGround)
    }

    func testObstacleAboveSourceStepSizeDoesNotStep() throws {
        let solver = makeSolver(world: stairWorld(height: 24), maximumSpeed: 200)
        let initial = SourceWorldWalkState(
            origin: SourceVector3(-16, 0, SourceCollisionConstants.distanceEpsilon),
            velocity: SourceVector3(200, 0, 0),
            isOnGround: true
        )

        let tick = try solver.simulate(
            state: initial,
            command: SourceUserCommand(
                commandNumber: 1,
                forwardMove: 200,
                buttons: [.forward]
            )
        )

        XCTAssertLessThan(tick.state.origin.x, -13)
        XCTAssertEqual(
            tick.state.origin.z,
            SourceCollisionConstants.distanceEpsilon,
            accuracy: 0.000_1
        )
        XCTAssertEqual(tick.stepHeight, 0)
    }

    func testLowStepRequiresStandingHullHeadClearance() throws {
        let solver = makeSolver(
            world: stairWorld(height: 12, ceilingBottom: 80),
            maximumSpeed: 200
        )
        let initial = SourceWorldWalkState(
            origin: SourceVector3(-16, 0, SourceCollisionConstants.distanceEpsilon),
            velocity: SourceVector3(200, 0, 0),
            isOnGround: true
        )

        let tick = try solver.simulate(
            state: initial,
            command: SourceUserCommand(
                commandNumber: 1,
                forwardMove: 200,
                buttons: [.forward]
            )
        )

        XCTAssertLessThan(tick.state.origin.x, -13)
        XCTAssertEqual(
            tick.state.origin.z,
            SourceCollisionConstants.distanceEpsilon,
            accuracy: 0.000_1
        )
        XCTAssertEqual(tick.stepHeight, 0)
    }

    func testAirMoveCannotAcquireWorldBrushStep() throws {
        let solver = makeSolver(world: stairWorld(height: 12), maximumSpeed: 200)
        let initial = SourceWorldWalkState(
            origin: SourceVector3(-16, 0, 5),
            velocity: SourceVector3(200, 0, 0),
            isOnGround: false
        )

        let tick = try solver.simulate(
            state: initial,
            command: SourceUserCommand(
                commandNumber: 1,
                forwardMove: 200,
                buttons: [.forward]
            )
        )

        XCTAssertLessThan(tick.state.origin.x, -13)
        XCTAssertLessThan(tick.state.origin.z, initial.origin.z)
        XCTAssertEqual(tick.stepHeight, 0)
    }

    func testStepBranchTraceFailureIsTransactional() throws {
        let world = stairWorld(height: 12)
        let solver = SourceWorldWalkSolver(
            collisionProvider: StepUpThrowingProvider(world: world),
            configuration: SourceWorldWalkConfiguration(maximumSpeed: 200)
        )
        let input = SourceWorldWalkState(
            origin: SourceVector3(-16, 0, SourceCollisionConstants.distanceEpsilon),
            velocity: SourceVector3(200, 0, 0),
            isOnGround: true
        )

        XCTAssertThrowsError(
            try solver.simulate(
                state: input,
                command: SourceUserCommand(
                    commandNumber: 1,
                    forwardMove: 200,
                    buttons: [.forward]
                )
            )
        ) {
            XCTAssertEqual($0 as? WorldWalkInjectedTraceError, .stepUp)
        }
        XCTAssertEqual(
            input,
            SourceWorldWalkState(
                origin: SourceVector3(
                    -16,
                    0,
                    SourceCollisionConstants.distanceEpsilon
                ),
                velocity: SourceVector3(200, 0, 0),
                isOnGround: true
            )
        )
    }

    func testAirGravityLandsWithoutPenetratingWorld() throws {
        let solver = makeSolver(world: floorWorld(), maximumSpeed: 200)
        var state = SourceWorldWalkState(origin: SourceVector3(0, 0, 100))

        for commandNumber in Int32(1) ... Int32(100) {
            let tick = try solver.simulate(
                state: state,
                command: SourceUserCommand(
                    commandNumber: commandNumber,
                    tickCount: commandNumber
                )
            )
            state = tick.state
            if state.isOnGround,
               abs(state.origin.z - SourceCollisionConstants.distanceEpsilon) < 0.000_1 {
                break
            }
        }

        XCTAssertTrue(state.isOnGround)
        XCTAssertEqual(
            state.origin.z,
            SourceCollisionConstants.distanceEpsilon,
            accuracy: 0.000_1
        )
        XCTAssertEqual(state.velocity.z, 0, accuracy: 0.000_1)
    }

    func testDuckUsesHL2MPHullViewAndInstantEndpointTransitions() throws {
        XCTAssertEqual(
            SourceWorldWalkSolver.duckHullMins,
            SourceVector3(-16, -16, 0)
        )
        XCTAssertEqual(
            SourceWorldWalkSolver.duckHullMaxs,
            SourceVector3(16, 16, 36)
        )

        let solver = makeSolver(world: floorWorld(), maximumSpeed: 200)
        let standing = SourceWorldWalkState(
            origin: SourceVector3(
                0,
                0,
                SourceCollisionConstants.distanceEpsilon
            ),
            isOnGround: true
        )
        let ducked = try solver.simulate(
            state: standing,
            command: SourceUserCommand(commandNumber: 1, buttons: [.duck])
        ).state
        XCTAssertTrue(ducked.isDucked)
        XCTAssertEqual(ducked.viewOffset, SourceVector3(0, 0, 28))
        XCTAssertEqual(ducked.origin, standing.origin)

        let stood = try solver.simulate(
            state: ducked,
            command: SourceUserCommand(commandNumber: 2)
        ).state
        XCTAssertFalse(stood.isDucked)
        XCTAssertEqual(stood.viewOffset, SourceVector3(0, 0, 64))
        XCTAssertEqual(stood.origin, standing.origin)
    }

    func testFullyDuckedGroundInputUsesExactSDKOneThirdCrop() throws {
        let solver = makeSolver(world: floorWorld(), maximumSpeed: 200)
        let ducked = SourceWorldWalkState(
            movement: SourceMoveData(
                origin: SourceVector3(
                    0,
                    0,
                    SourceCollisionConstants.distanceEpsilon
                ),
                isOnGround: true
            ),
            isDucked: true,
            viewOffset: SourceVector3(0, 0, 28)
        )

        let moved = try solver.simulate(
            state: ducked,
            command: SourceUserCommand(
                commandNumber: 1,
                forwardMove: 200,
                buttons: [.duck, .forward]
            )
        ).state

        XCTAssertTrue(moved.isDucked)
        XCTAssertEqual(moved.velocity.x, 10, accuracy: 0.000_01)
        XCTAssertEqual(moved.origin.x, 0.15, accuracy: 0.000_01)
        XCTAssertEqual(
            moved.movement.outputWishVelocity.x,
            66.666_664,
            accuracy: 0.000_01
        )
    }

    func testStandingHullCeilingTraceBlocksUnduckTransactionally() throws {
        var lowCeiling = floorWorld()
        lowCeiling.addAxisAlignedBox(
            SourceAABBCollider(
                mins: SourceVector3(-100, -100, 50),
                maxs: SourceVector3(100, 100, 100),
                contents: .solid,
                entityHandle: worldHandle
            )
        )
        let ducked = SourceWorldWalkState(
            movement: SourceMoveData(
                origin: SourceVector3(
                    0,
                    0,
                    SourceCollisionConstants.distanceEpsilon
                ),
                isOnGround: true
            ),
            isDucked: true,
            viewOffset: SourceVector3(0, 0, 28)
        )

        let blocked = try makeSolver(
            world: lowCeiling,
            maximumSpeed: 200
        ).simulate(
            state: ducked,
            command: SourceUserCommand(commandNumber: 1)
        ).state
        XCTAssertTrue(blocked.isDucked)
        XCTAssertEqual(blocked.origin, ducked.origin)
        XCTAssertEqual(blocked.viewOffset, ducked.viewOffset)

        let clear = try makeSolver(
            world: floorWorld(),
            maximumSpeed: 200
        ).simulate(
            state: blocked,
            command: SourceUserCommand(commandNumber: 2)
        ).state
        XCTAssertFalse(clear.isDucked)
        XCTAssertEqual(clear.viewOffset, SourceVector3(0, 0, 64))
    }

    func testAirDuckKeepsHullTopFixedAcrossBothEndpoints() throws {
        let solver = SourceWorldWalkSolver(
            collisionProvider: CollisionWorldWalkProvider(world: SourceCollisionWorld()),
            configuration: SourceWorldWalkConfiguration(
                movement: SourceMovementParameters(gravity: 0),
                maximumSpeed: 200
            )
        )
        let standing = SourceWorldWalkState(origin: SourceVector3(0, 0, 100))

        let ducked = try solver.simulate(
            state: standing,
            command: SourceUserCommand(commandNumber: 1, buttons: [.duck])
        ).state
        XCTAssertTrue(ducked.isDucked)
        XCTAssertEqual(ducked.origin.z, 136, accuracy: 0.000_01)
        XCTAssertEqual(
            ducked.origin.z + SourceWorldWalkSolver.duckHullMaxs.z,
            standing.origin.z + SourceWorldWalkSolver.standingHullMaxs.z,
            accuracy: 0.000_01
        )

        let stood = try solver.simulate(
            state: ducked,
            command: SourceUserCommand(commandNumber: 2)
        ).state
        XCTAssertFalse(stood.isDucked)
        XCTAssertEqual(stood.origin, standing.origin)
    }

    func testDuckEyeOffsetDrivesSourceWaterLevelSampling() throws {
        var shallowWater = floorWorld()
        shallowWater.addAxisAlignedBox(
            SourceAABBCollider(
                mins: SourceVector3(-100, -100, 0),
                maxs: SourceVector3(100, 100, 30),
                contents: .water,
                entityHandle: worldHandle
            )
        )
        let solver = makeSolver(
            world: shallowWater,
            maximumSpeed: 200
        )
        let origin = SourceVector3(
            0,
            0,
            SourceCollisionConstants.distanceEpsilon
        )
        let standing = try solver.simulate(
            state: SourceWorldWalkState(origin: origin, isOnGround: true),
            command: SourceUserCommand(commandNumber: 1)
        ).state
        XCTAssertEqual(standing.waterLevel, .feet)

        let ducked = try solver.simulate(
            state: SourceWorldWalkState(origin: origin, isOnGround: true),
            command: SourceUserCommand(commandNumber: 2, buttons: [.duck])
        ).state
        XCTAssertTrue(ducked.isDucked)
        XCTAssertEqual(ducked.waterLevel, .eyes)
    }

    func testUnsupportedCommandAndWorldFeaturesFailExplicitly() throws {
        let solver = makeSolver(world: floorWorld(), maximumSpeed: 200)
        let state = SourceWorldWalkState(origin: SourceVector3(0, 0, 1))

        let unsupportedCommands: [(SourceUserCommand, SourceWorldWalkError)] = [
            (
                SourceUserCommand(commandNumber: 1, buttons: [.duck, .jump]),
                .unsupported(.duckJump)
            ),
            (
                SourceUserCommand(commandNumber: 1, upMove: 1),
                .unsupported(.verticalMove)
            ),
        ]
        for (command, expected) in unsupportedCommands {
            XCTAssertThrowsError(try solver.simulate(state: state, command: command)) {
                XCTAssertEqual($0 as? SourceWorldWalkError, expected)
            }
            XCTAssertEqual(state.origin, SourceVector3(0, 0, 1))
        }

        XCTAssertFalse(SourceWorldWalkSolver.unsupportedFeatures.contains(.stepUp))
        XCTAssertFalse(SourceWorldWalkSolver.unsupportedFeatures.contains(.jump))
        XCTAssertTrue(
            SourceWorldWalkSolver.unsupportedFeatures.contains(.duckTransition)
        )
        XCTAssertTrue(SourceWorldWalkSolver.unsupportedFeatures.contains(.duckJump))
        XCTAssertTrue(SourceWorldWalkSolver.unsupportedFeatures.contains(.waterJump))
        XCTAssertTrue(SourceWorldWalkSolver.unsupportedFeatures.contains(.waterCurrent))
        XCTAssertTrue(
            SourceWorldWalkSolver.unsupportedFeatures.contains(.dynamicWaterVolume)
        )
        XCTAssertFalse(SourceWorldWalkSolver.unsupportedFeatures.contains(.ladder))
        XCTAssertFalse(
            SourceWorldWalkSolver.unsupportedFeatures.contains(.displacementCollision)
        )
        XCTAssertTrue(
            SourceWorldWalkSolver.unsupportedFeatures.contains(.dynamicEntityCollision)
        )
        XCTAssertTrue(SourceWorldWalkSolver.unsupportedFeatures.contains(.vPhysics))

        var dead = state
        dead.movement.isDead = true
        XCTAssertThrowsError(
            try solver.simulate(state: dead, command: SourceUserCommand(commandNumber: 1))
        ) {
            XCTAssertEqual($0 as? SourceWorldWalkError, .unsupported(.deadPlayer))
        }

        var nonWalk = state
        nonWalk.moveType = .noClip
        XCTAssertThrowsError(
            try solver.simulate(state: nonWalk, command: SourceUserCommand(commandNumber: 1))
        ) {
            XCTAssertEqual($0 as? SourceWorldWalkError, .unsupported(.nonWalkMoveType))
        }
    }

    func testGroundJumpUsesSourceHeightImpulseAndLeavesGround() throws {
        let solver = makeSolver(world: floorWorld(), maximumSpeed: 200)
        let state = SourceWorldWalkState(
            origin: SourceVector3(0, 0, SourceCollisionConstants.distanceEpsilon),
            isOnGround: true
        )

        let tick = try solver.simulate(
            state: state,
            command: SourceUserCommand(commandNumber: 1, buttons: [.jump])
        )

        XCTAssertFalse(tick.state.isOnGround)
        XCTAssertGreaterThan(tick.state.origin.z, state.origin.z)
        XCTAssertGreaterThan(tick.state.velocity.z, 0)
        XCTAssertEqual(tick.commandNumber, 1)
    }

    func testWaterMovesAndJumpSwims() throws {
        let waterSolver = makeSolver(
            world: waterWorld(contents: .water),
            maximumSpeed: 200
        )
        let state = SourceWorldWalkState(origin: SourceVector3(0, 0, 0))
        let swimming = try waterSolver.simulate(
            state: state,
            command: SourceUserCommand(
                commandNumber: 1,
                forwardMove: 200,
                buttons: [.jump]
            )
        )
        XCTAssertGreaterThan(swimming.state.origin.x, state.origin.x)
        XCTAssertGreaterThan(swimming.state.origin.z, state.origin.z)
        XCTAssertFalse(swimming.state.isOnGround)
        XCTAssertEqual(swimming.state.waterLevel, .eyes)
        XCTAssertEqual(swimming.state.velocity.x, 16.970_562, accuracy: 0.000_01)
        XCTAssertEqual(swimming.state.velocity.z, 110.970_56, accuracy: 0.000_01)
    }

    func testWaterLevelSamplesFeetWaistAndStandingEyeOffset() throws {
        let expectations: [(maximumZ: Float, level: SourcePlayerWaterLevel)] = [
            (20, .feet),
            (50, .waist),
            // The standing eye is at z + 64 in the Source player state. This
            // volume deliberately ends below the old hull-top approximation.
            (65, .eyes),
        ]

        for expectation in expectations {
            let solver = makeSolver(
                world: waterWorld(maximumZ: expectation.maximumZ),
                maximumSpeed: 200
            )
            let tick = try solver.simulate(
                state: SourceWorldWalkState(origin: .zero),
                command: SourceUserCommand(commandNumber: 1)
            )
            XCTAssertEqual(
                tick.state.waterLevel,
                expectation.level,
                "water top z=\(expectation.maximumZ)"
            )
        }
    }

    func testWaterMoveUsesSDKFrictionAccelerationSinkAndUpInput() throws {
        let solver = makeSolver(world: waterWorld(), maximumSpeed: 200)
        let state = SourceWorldWalkState(origin: .zero)

        let accelerated = try solver.simulate(
            state: state,
            command: SourceUserCommand(commandNumber: 1, forwardMove: 100)
        ).state
        XCTAssertEqual(accelerated.velocity.x, 12, accuracy: 0.000_01)
        XCTAssertEqual(accelerated.origin.x, 0.18, accuracy: 0.000_01)
        XCTAssertEqual(
            accelerated.movement.outputWishVelocity.x,
            12,
            accuracy: 0.000_01
        )

        let sinking = try solver.simulate(
            state: state,
            command: SourceUserCommand(commandNumber: 2)
        ).state
        XCTAssertEqual(sinking.velocity.z, -7.2, accuracy: 0.000_01)
        XCTAssertEqual(sinking.origin.z, -0.108, accuracy: 0.000_01)

        let rising = try solver.simulate(
            state: state,
            command: SourceUserCommand(commandNumber: 3, upMove: 50)
        ).state
        XCTAssertEqual(rising.velocity.z, 6, accuracy: 0.000_01)
        XCTAssertEqual(rising.origin.z, 0.09, accuracy: 0.000_01)

        let frictionState = SourceWorldWalkState(
            origin: .zero,
            velocity: SourceVector3(100, 0, 0)
        )
        let friction = try solver.simulate(
            state: frictionState,
            command: SourceUserCommand(commandNumber: 4)
        ).state
        XCTAssertEqual(friction.velocity.x, 94, accuracy: 0.000_01)
        XCTAssertEqual(friction.velocity.z, 0, accuracy: 0.000_01)
    }

    func testWaterAndSlimeJumpAuthorExactSDKVerticalSpeeds() throws {
        let state = SourceWorldWalkState(origin: .zero)
        let command = SourceUserCommand(commandNumber: 1, buttons: [.jump])

        let water = try makeSolver(
            world: waterWorld(contents: [.water, .detail]),
            maximumSpeed: 200
        ).simulate(state: state, command: command).state
        XCTAssertEqual(water.velocity.z, 118, accuracy: 0.000_01)

        let slime = try makeSolver(
            world: waterWorld(contents: [.water, .slime, .detail]),
            maximumSpeed: 200
        ).simulate(state: state, command: command).state
        XCTAssertEqual(slime.velocity.z, 99.2, accuracy: 0.000_01)
    }

    func testEnteringWaistWaterSuppressesSecondHalfGravity() throws {
        let world = SourceCollisionWorld(
            primitives: [
                .axisAlignedBox(
                    SourceAABBCollider(
                        mins: SourceVector3(0, -100, -100),
                        maxs: SourceVector3(100, 100, 100),
                        contents: .water,
                        entityHandle: worldHandle
                    )
                ),
            ]
        )
        let tick = try makeSolver(world: world, maximumSpeed: 200).simulate(
            state: SourceWorldWalkState(origin: SourceVector3(-0.1, 0, 0)),
            command: SourceUserCommand(commandNumber: 1, forwardMove: 200)
        )

        XCTAssertEqual(tick.state.waterLevel, .eyes)
        XCTAssertEqual(tick.state.velocity.z, -6, accuracy: 0.000_01)
    }

    func testWaterCurrentRemainsAnExplicitTransactionalCapabilityMiss() throws {
        let solver = makeSolver(
            world: waterWorld(contents: [.water, .current0]),
            maximumSpeed: 200
        )
        let state = SourceWorldWalkState(origin: .zero)

        XCTAssertThrowsError(try solver.simulate(
            state: state,
            command: SourceUserCommand(commandNumber: 1)
        )) {
            XCTAssertEqual(
                $0 as? SourceWorldWalkError,
                .unsupported(.waterCurrent)
            )
        }
        XCTAssertEqual(state, SourceWorldWalkState(origin: .zero))
    }

    func testBundledConstructWaterLeafDrivesWorldOnlySwimming() throws {
        let bsp = try SourceBSP(data: GModGameAssets.data(for: .construct, kind: .bsp))
        let waterOrigins = bsp.faces.compactMap { face -> SourceVector3? in
            guard face.textureInfoIndex >= 0 else { return nil }
            let textureInfo = bsp.textureInfo[Int(face.textureInfoIndex)]
            guard let materialName = bsp.textureName(
                forTextureDataIndex: Int(textureInfo.textureDataIndex)
            ), materialName.contains("water_13"),
               !materialName.contains("water_13_beneath") else { return nil }

            let firstEdge = Int(face.firstSurfaceEdge)
            let points = (0..<Int(face.surfaceEdgeCount)).map { offset in
                let signedEdge = bsp.surfaceEdges[firstEdge + offset]
                let edge = bsp.edges[Int(abs(Int64(signedEdge)))]
                let vertexIndex = signedEdge >= 0
                    ? Int(edge.firstVertex)
                    : Int(edge.secondVertex)
                return bsp.vertices[vertexIndex].point
            }
            guard !points.isEmpty else { return nil }
            let center = points.reduce(SourceVector3.zero) { partial, point in
                partial + SourceVector3(point.x, point.y, point.z)
            } / Float(points.count)
            return center - SourceVector3(0, 0, 65)
        }
        let origin = try XCTUnwrap(waterOrigins.first { candidate in
            let sampleOffsets: [Float] = [1, 36, 64]
            return sampleOffsets.allSatisfy { offset in
                guard let contents = try? bsp.worldPointContents(
                    at: candidate + SourceVector3(0, 0, offset),
                    mask: SourceMasks.water
                ) else { return false }
                return !contents.intersection(SourceMasks.water).isEmpty
            }
        }, "expected an authored gm_construct water leaf")
        let solver = SourceWorldWalkSolver(
            collisionProvider: SourceBSPWorldWalkCollisionProvider(bsp: bsp),
            configuration: SourceWorldWalkConfiguration(maximumSpeed: 200)
        )

        let tick = try solver.simulate(
            state: SourceWorldWalkState(origin: origin),
            command: SourceUserCommand(commandNumber: 1)
        )
        XCTAssertEqual(tick.state.waterLevel, .eyes)
        XCTAssertLessThan(tick.state.velocity.z, 0)
    }

    func testConstructRealLadderContentsPlaneClimbDescendJumpAndContactLoss() throws {
        let data = try GModGameAssets.data(for: .construct, kind: .bsp)
        let bsp = try SourceBSP(data: data)
        let ladderBrushes = bsp.brushes.enumerated().filter { _, brush in
            SourceContents(rawValue: UInt32(bitPattern: brush.contents)).contains(.ladder)
        }
        XCTAssertEqual(ladderBrushes.map(\.offset), [803])

        // Authored gm_construct LADDER brush 803 spans x -2932 ... -2908,
        // y -1058 ... -1056, z -144 ... -16. This standing origin is one
        // Source unit outside the -Y expanded hull face, in the authored room
        // leaf, so the SDK's exact
        // two-unit LadderDistance trace must select the map-authored plane.
        let origin = SourceVector3(-2920, -1075, -95)
        let towardLadder = SourceVector3(0, 1, 0)
        let contact = try bsp.traceWorld(
            SourceRay(
                start: origin,
                end: origin + towardLadder * SourceWorldWalkSolver.ladderDistance,
                mins: SourceWorldWalkSolver.standingHullMins,
                maxs: SourceWorldWalkSolver.standingHullMaxs
            ),
            mask: SourceWorldWalkSolver.ladderMask
        )
        XCTAssertTrue(contact.contents.contains(.ladder))
        XCTAssertEqual(contact.plane.normal, SourceVector3(0, -1, 0))
        XCTAssertEqual(contact.fraction, 0.484_375, accuracy: 0.000_001)

        let solver = SourceWorldWalkSolver(
            collisionProvider: SourceBSPWorldWalkCollisionProvider(bsp: bsp),
            configuration: SourceWorldWalkConfiguration(maximumSpeed: 200)
        )
        let facingLadder = SourceQAngle(pitch: 0, yaw: 90, roll: 0)

        let climbed = try solver.simulate(
            state: SourceWorldWalkState(origin: origin, viewAngles: facingLadder),
            command: SourceUserCommand(
                commandNumber: 1,
                tickCount: 1,
                viewAngles: facingLadder,
                forwardMove: 200,
                buttons: [.forward]
            )
        ).state
        XCTAssertEqual(climbed.moveType, .ladder)
        XCTAssertEqual(climbed.ladderNormal, SourceVector3(0, -1, 0))
        XCTAssertEqual(climbed.velocity.x, 0, accuracy: 0.000_01)
        XCTAssertEqual(climbed.velocity.y, 0, accuracy: 0.000_01)
        XCTAssertEqual(climbed.velocity.z, 200, accuracy: 0.000_01)
        XCTAssertEqual(
            climbed.origin.z - origin.z,
            SourceWorldWalkSolver.maximumClimbSpeed * SourceGlobalVars.intervalPerTick,
            accuracy: 0.000_001
        )

        let descended = try solver.simulate(
            state: climbed,
            command: SourceUserCommand(
                commandNumber: 2,
                tickCount: 2,
                viewAngles: facingLadder,
                forwardMove: -200,
                buttons: [.back]
            )
        ).state
        XCTAssertEqual(descended.moveType, .ladder)
        XCTAssertEqual(descended.velocity.x, 0, accuracy: 0.000_01)
        XCTAssertEqual(descended.velocity.y, 0, accuracy: 0.000_01)
        XCTAssertEqual(descended.velocity.z, -200, accuracy: 0.000_01)
        XCTAssertEqual(descended.origin.z, origin.z, accuracy: 0.000_001)

        let jumped = try solver.simulate(
            state: descended,
            command: SourceUserCommand(
                commandNumber: 3,
                tickCount: 3,
                viewAngles: facingLadder,
                buttons: [.jump]
            )
        ).state
        XCTAssertEqual(jumped.moveType, .walk)
        XCTAssertEqual(jumped.velocity.y, -SourceWorldWalkSolver.ladderJumpOffSpeed)
        XCTAssertLessThan(jumped.origin.y, descended.origin.y)

        var lostContact = descended
        lostContact.origin.y = -1084
        let detached = try solver.simulate(
            state: lostContact,
            command: SourceUserCommand(
                commandNumber: 4,
                tickCount: 4,
                viewAngles: facingLadder
            )
        ).state
        XCTAssertEqual(detached.moveType, .walk)
        XCTAssertEqual(detached.origin.y, lostContact.origin.y)
    }

    func testConstructAuthoredBrush137StepsUpSixteenUnits() throws {
        let bsp = try SourceBSP(
            data: GModGameAssets.data(for: .construct, kind: .bsp)
        )

        // Authored gm_construct world brush 137 has a west face at x -3200
        // and a walkable top at z 256. The adjacent authored floor is z 240,
        // so the standing hull must climb the real 16-unit map step.
        let origin = SourceVector3(-3217, -2816, 240.031_25)
        let destination = origin + SourceVector3(3, 0, 0)
        let blocked = try bsp.traceWorld(
            SourceRay(
                start: origin,
                end: destination,
                mins: SourceWorldWalkSolver.standingHullMins,
                maxs: SourceWorldWalkSolver.standingHullMaxs
            ),
            mask: SourceWorldWalkSolver.playerMask
        )
        XCTAssertTrue(blocked.didHitWorld)
        XCTAssertEqual(blocked.plane.normal, SourceVector3(-1, 0, 0))
        XCTAssertLessThan(blocked.fraction, 1)

        let solver = SourceWorldWalkSolver(
            collisionProvider: SourceBSPWorldWalkCollisionProvider(bsp: bsp),
            configuration: SourceWorldWalkConfiguration(maximumSpeed: 200)
        )
        let tick = try solver.simulate(
            state: SourceWorldWalkState(
                origin: origin,
                velocity: SourceVector3(200, 0, 0),
                isOnGround: true
            ),
            command: SourceUserCommand(
                commandNumber: 1,
                forwardMove: 200,
                buttons: [.forward]
            )
        )

        XCTAssertEqual(tick.state.origin, SourceVector3(-3214, -2816, 256.031_25))
        XCTAssertEqual(tick.state.velocity, SourceVector3(200, 0, 0))
        XCTAssertEqual(tick.stepHeight, 16)
        XCTAssertTrue(tick.state.isOnGround)
    }

    func testLadderTraceAndMalformedLadderStateFailTransactionally() throws {
        let throwingSolver = SourceWorldWalkSolver(
            collisionProvider: LadderContactThrowingProvider()
        )
        let input = SourceWorldWalkState(origin: SourceVector3(10, 20, 30))
        XCTAssertThrowsError(
            try throwingSolver.simulate(
                state: input,
                command: SourceUserCommand(
                    commandNumber: 1,
                    forwardMove: 200,
                    buttons: [.forward]
                )
            )
        ) {
            XCTAssertEqual($0 as? WorldWalkInjectedTraceError, .ladderContact)
        }
        XCTAssertEqual(input, SourceWorldWalkState(origin: SourceVector3(10, 20, 30)))

        var malformed = input
        malformed.moveType = .ladder
        malformed.ladderNormal = SourceVector3(.nan, 0, 0)
        XCTAssertThrowsError(
            try throwingSolver.simulate(
                state: malformed,
                command: SourceUserCommand(commandNumber: 2)
            )
        ) {
            XCTAssertEqual(
                $0 as? SourceWorldWalkError,
                .nonFinite("state ladderNormal.x")
            )
        }
        XCTAssertTrue(malformed.ladderNormal.x.isNaN)
    }

    func testProviderCannotInjectDynamicOrIdentitylessHits() throws {
        for (mode, expected) in [
            (
                ForcedWorldWalkProvider.Mode.dynamicEntity,
                SourceWorldWalkError.unsupportedDynamicEntity(7)
            ),
            (
                .missingIdentity,
                .hitMissingWorldIdentity
            ),
            (
                .nonUnitNormal,
                .inconsistentTrace("non-unit hit plane normal")
            ),
            (
                .inconsistentEndPosition,
                .inconsistentTrace("HitPos")
            ),
        ] {
            let solver = SourceWorldWalkSolver(
                collisionProvider: ForcedWorldWalkProvider(mode: mode)
            )
            XCTAssertThrowsError(
                try solver.simulate(
                    state: SourceWorldWalkState(origin: SourceVector3(0, 0, 1)),
                    command: SourceUserCommand(commandNumber: 1)
                )
            ) {
                XCTAssertEqual($0 as? SourceWorldWalkError, expected)
            }
        }
    }

    func testProviderMayReturnRealDisplacementSurfaceFlags() throws {
        let solver = SourceWorldWalkSolver(
            collisionProvider: ForcedWorldWalkProvider(mode: .displacement)
        )
        let tick = try solver.simulate(
            state: SourceWorldWalkState(origin: SourceVector3(0, 0, 10)),
            command: SourceUserCommand(commandNumber: 1)
        )

        XCTAssertTrue(tick.state.isOnGround)
    }

    func testEmbeddedAndNonFiniteInputsAreTransactionalFailures() throws {
        let solver = makeSolver(world: floorWorld(), maximumSpeed: 200)
        let embedded = SourceWorldWalkState(origin: SourceVector3(0, 0, -1))
        XCTAssertThrowsError(
            try solver.simulate(
                state: embedded,
                command: SourceUserCommand(commandNumber: 1)
            )
        ) {
            XCTAssertEqual(
                $0 as? SourceWorldWalkError,
                .embeddedInWorld(allSolid: true)
            )
        }
        XCTAssertEqual(embedded.origin, SourceVector3(0, 0, -1))

        var nonFinite = SourceWorldWalkState(origin: SourceVector3(0, 0, 1))
        nonFinite.velocity.x = .nan
        XCTAssertThrowsError(
            try solver.simulate(
                state: nonFinite,
                command: SourceUserCommand(commandNumber: 1)
            )
        ) {
            XCTAssertEqual($0 as? SourceWorldWalkError, .nonFinite("state velocity.x"))
        }
        XCTAssertTrue(nonFinite.velocity.x.isNaN)

        XCTAssertThrowsError(
            try solver.simulate(
                state: SourceWorldWalkState(origin: SourceVector3(0, 0, 1)),
                command: SourceUserCommand(commandNumber: 1, forwardMove: .infinity)
            )
        ) {
            XCTAssertEqual(
                $0 as? SourceWorldWalkError,
                .nonFinite("command forwardMove")
            )
        }

        XCTAssertThrowsError(
            try solver.simulate(
                state: SourceWorldWalkState(origin: SourceVector3(0, 0, 1)),
                command: SourceUserCommand(
                    commandNumber: 1,
                    forwardMove: .greatestFiniteMagnitude,
                    sideMove: .greatestFiniteMagnitude
                )
            )
        ) {
            XCTAssertEqual(
                $0 as? SourceWorldWalkError,
                .nonFinite("ladder wish velocity lengthSquared")
            )
        }
    }

    func testBundledConstructAndFlatgrassWalkSixteenTicksFromFirstPlayerStart() throws {
        struct ExpectedMap {
            let map: GModBundledMap
            let spawn: SourceVector3
            let angles: SourceQAngle
            let expectedX: Float
        }
        let expectedMaps = [
            ExpectedMap(
                map: .construct,
                spawn: SourceVector3(704, 132, -143),
                angles: SourceQAngle(pitch: 0, yaw: 180, roll: 0),
                expectedX: 666.546_55
            ),
            ExpectedMap(
                map: .flatgrass,
                spawn: SourceVector3(-512, 576, -12_287),
                angles: SourceQAngle(pitch: 0, yaw: 0, roll: 0),
                expectedX: -474.546_55
            ),
        ]

        for expected in expectedMaps {
            let data = try GModGameAssets.data(for: expected.map, kind: .bsp)
            let bsp = try SourceBSP(data: data)
            XCTAssertEqual(
                bsp.prebuiltWorldCollisionPrimitiveCount,
                bsp.brushes.count
            )
            let parsedSpawn = try XCTUnwrap(
                try parsePlayerStarts(try XCTUnwrap(bsp.entities.text)).first
            )
            XCTAssertEqual(parsedSpawn.origin, expected.spawn)
            XCTAssertEqual(parsedSpawn.angles, expected.angles)

            let solver = SourceWorldWalkSolver(
                collisionProvider: SourceBSPWorldWalkCollisionProvider(bsp: bsp),
                configuration: SourceWorldWalkConfiguration(maximumSpeed: 200)
            )
            var state = SourceWorldWalkState(
                origin: parsedSpawn.origin,
                viewAngles: parsedSpawn.angles
            )
            var collisionCount = 0

            for commandNumber in Int32(1) ... Int32(16) {
                let tick = try solver.simulate(
                    state: state,
                    command: SourceUserCommand(
                        commandNumber: commandNumber,
                        tickCount: commandNumber,
                        viewAngles: parsedSpawn.angles,
                        forwardMove: 200,
                        buttons: [.forward]
                    )
                )
                state = tick.state
                collisionCount += tick.collisionCount
                XCTAssertTrue(
                    state.isOnGround,
                    "\(expected.map.rawValue) left the spawn floor at command \(commandNumber)"
                )
                XCTAssertEqual(
                    state.origin.z,
                    parsedSpawn.origin.z - Float(0.968_75),
                    accuracy: 0.001
                )
            }

            XCTAssertEqual(state.origin.x, expected.expectedX, accuracy: 0.001)
            XCTAssertEqual(state.origin.y, expected.spawn.y, accuracy: 0.01)
            XCTAssertEqual(collisionCount, 0)
            XCTAssertEqual(state.velocity.length, 200, accuracy: 0.01)
        }
    }

    private func floorWorld() -> SourceCollisionWorld {
        SourceCollisionWorld(
            primitives: [
                .axisAlignedBox(
                    SourceAABBCollider(
                        mins: SourceVector3(-1_000, -1_000, -100),
                        maxs: SourceVector3(1_000, 1_000, 0),
                        contents: .solid,
                        entityHandle: worldHandle
                    )
                ),
            ]
        )
    }

    private func waterWorld(
        maximumZ: Float = 100,
        contents: SourceContents = .water
    ) -> SourceCollisionWorld {
        SourceCollisionWorld(
            primitives: [
                .axisAlignedBox(
                    SourceAABBCollider(
                        mins: SourceVector3(-100, -100, -100),
                        maxs: SourceVector3(100, 100, maximumZ),
                        contents: contents,
                        entityHandle: worldHandle
                    )
                ),
            ]
        )
    }

    private func stairWorld(
        height: Float,
        ceilingBottom: Float? = nil
    ) -> SourceCollisionWorld {
        var world = floorWorld()
        world.addAxisAlignedBox(
            SourceAABBCollider(
                mins: SourceVector3(2, -100, 0),
                maxs: SourceVector3(30, 100, height),
                contents: .solid,
                entityHandle: worldHandle
            )
        )
        if let ceilingBottom {
            world.addAxisAlignedBox(
                SourceAABBCollider(
                    mins: SourceVector3(-100, -100, ceilingBottom),
                    maxs: SourceVector3(100, 100, ceilingBottom + 20),
                    contents: .solid,
                    entityHandle: worldHandle
                )
            )
        }
        return world
    }

    private func makeSolver(
        world: SourceCollisionWorld,
        maximumSpeed: Float
    ) -> SourceWorldWalkSolver {
        SourceWorldWalkSolver(
            collisionProvider: CollisionWorldWalkProvider(world: world),
            configuration: SourceWorldWalkConfiguration(maximumSpeed: maximumSpeed)
        )
    }

    private func parsePlayerStarts(_ text: String) throws
        -> [(origin: SourceVector3, angles: SourceQAngle)] {
        let pairExpression = try NSRegularExpression(
            pattern: #"\"([^\"]+)\"\s+\"([^\"]*)\""#
        )
        var starts: [(origin: SourceVector3, angles: SourceQAngle)] = []
        for block in text.split(separator: "}", omittingEmptySubsequences: true) {
            let string = String(block)
            let range = NSRange(string.startIndex ..< string.endIndex, in: string)
            var values: [String: String] = [:]
            for match in pairExpression.matches(in: string, range: range) {
                guard let keyRange = Range(match.range(at: 1), in: string),
                      let valueRange = Range(match.range(at: 2), in: string) else {
                    continue
                }
                values[String(string[keyRange])] = String(string[valueRange])
            }
            guard values["classname"] == "info_player_start",
                  let origin = values["origin"],
                  let angles = values["angles"],
                  let originVector = parseVector(origin),
                  let angleVector = parseVector(angles) else {
                continue
            }
            starts.append(
                (
                    originVector,
                    SourceQAngle(
                        pitch: angleVector.x,
                        yaw: angleVector.y,
                        roll: angleVector.z
                    )
                )
            )
        }
        return starts
    }

    private func parseVector(_ value: String) -> SourceVector3? {
        let components = value.split(whereSeparator: \.isWhitespace)
        guard components.count == 3,
              let x = Float(components[0]),
              let y = Float(components[1]),
              let z = Float(components[2]) else {
            return nil
        }
        return SourceVector3(x, y, z)
    }
}
