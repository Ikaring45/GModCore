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

    func testUnsupportedCommandAndWorldFeaturesFailExplicitly() throws {
        let solver = makeSolver(world: floorWorld(), maximumSpeed: 200)
        let state = SourceWorldWalkState(origin: SourceVector3(0, 0, 1))

        let unsupportedCommands: [(SourceUserCommand, SourceWorldWalkError)] = [
            (
                SourceUserCommand(commandNumber: 1, buttons: [.duck]),
                .unsupported(.duck)
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

        XCTAssertTrue(SourceWorldWalkSolver.unsupportedFeatures.contains(.stepUp))
        XCTAssertFalse(SourceWorldWalkSolver.unsupportedFeatures.contains(.jump))
        XCTAssertTrue(SourceWorldWalkSolver.unsupportedFeatures.contains(.duck))
        XCTAssertTrue(SourceWorldWalkSolver.unsupportedFeatures.contains(.water))
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
        var waterWorld = floorWorld()
        waterWorld.addAxisAlignedBox(
            SourceAABBCollider(
                mins: SourceVector3(-100, -100, -10),
                maxs: SourceVector3(100, 100, 100),
                contents: .water,
                entityHandle: worldHandle
            )
        )
        let waterSolver = makeSolver(world: waterWorld, maximumSpeed: 200)
        let state = SourceWorldWalkState(origin: SourceVector3(0, 0, 1))
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
