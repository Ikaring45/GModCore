import XCTest
@testable import GModEngine
@testable import GModGameSession

final class GModPlayableSessionCanonicalEntityTests: XCTestCase {
    func testStartupAndMovementUseOneCanonicalPlayerAcrossFIFORealms() throws {
        let configuration = GModPlayableSessionConfiguration(
            map: .construct,
            playerEntityIndex: 7,
            playerUserID: 70
        )
        let session = try GModPlayableSession(configuration: configuration)
        defer { _ = try? session.close() }

        let serverRegistry = try XCTUnwrap(session.serverRuntime.entityRegistry)
        let clientRegistry = try XCTUnwrap(session.clientRuntime.entityRegistry)
        let serverWorld = try XCTUnwrap(serverRegistry.canonicalSnapshot(at: 0))
        let clientWorld = try XCTUnwrap(clientRegistry.canonicalSnapshot(at: 0))
        let serverPlayer = try XCTUnwrap(
            serverRegistry.canonicalSnapshot(at: configuration.playerEntityIndex)
        )
        let clientPlayer = try XCTUnwrap(
            clientRegistry.canonicalSnapshot(at: configuration.playerEntityIndex)
        )

        XCTAssertEqual(serverWorld.identity, session.worldIdentity)
        XCTAssertEqual(clientWorld, serverWorld)
        XCTAssertEqual(clientPlayer, serverPlayer)
        XCTAssertEqual(
            session.clientCanonicalEntitySnapshots,
            [clientWorld, clientPlayer]
        )
        let startupCursor = try XCTUnwrap(
            session.clientCanonicalEntityReplicationCursor
        )
        XCTAssertGreaterThan(startupCursor.sequence, 0)
        XCTAssertEqual(serverPlayer.kind, .player)
        XCTAssertEqual(serverWorld.lifecycle, .active)
        XCTAssertEqual(serverPlayer.lifecycle, .active)
        XCTAssertEqual(serverPlayer.transform.origin, session.spawnPoint.origin)
        XCTAssertEqual(serverPlayer.transform.angles, session.spawnPoint.angles)
        XCTAssertEqual(session.sharedSession.connectedPlayerIndices, [7])
        XCTAssertEqual(session.sharedSession.connectedUserIDs, [70])
        XCTAssertEqual(session.sharedSession.netTransport.pendingDeliveryCount, 0)
        XCTAssertTrue(session.startupReport.clientStartup.playerConnectionModeled)
        try session.serverRuntime.execute(
            "assert(Player(70) == Entity(7))",
            sourceName: "=(canonical playable server Player user ID)"
        )
        try session.clientRuntime.execute(
            "assert(LocalPlayer() == Entity(7) and Player(70) == Entity(7))",
            sourceName: "=(canonical playable client Player user ID)"
        )

        let tick = try session.runFixedTick(
            movementInput: GModPlayableMovementInput(
                viewAngles: session.spawnPoint.angles,
                forwardMove: 200,
                buttons: [.forward]
            )
        )
        guard case let .advanced(advanced) = tick.movement else {
            return XCTFail("construct movement was rejected")
        }
        let movedServerPlayer = try XCTUnwrap(
            serverRegistry.canonicalSnapshot(at: configuration.playerEntityIndex)
        )
        let movedClientPlayer = try XCTUnwrap(
            clientRegistry.canonicalSnapshot(at: configuration.playerEntityIndex)
        )
        XCTAssertEqual(movedServerPlayer.identity, serverPlayer.identity)
        XCTAssertGreaterThan(movedServerPlayer.revision, serverPlayer.revision)
        XCTAssertEqual(movedClientPlayer, movedServerPlayer)
        XCTAssertEqual(
            session.clientCanonicalEntitySnapshots,
            [clientWorld, movedClientPlayer]
        )
        let movedCursor = try XCTUnwrap(
            session.clientCanonicalEntityReplicationCursor
        )
        XCTAssertEqual(
            movedCursor.connectionGeneration,
            startupCursor.connectionGeneration
        )
        XCTAssertGreaterThan(movedCursor.sequence, startupCursor.sequence)
        XCTAssertEqual(movedServerPlayer.transform.origin, advanced.state.origin)
        XCTAssertEqual(movedServerPlayer.transform.angles, advanced.state.viewAngles)
        XCTAssertEqual(session.playerWalkState, advanced.state)
        XCTAssertEqual(session.sharedSession.netTransport.pendingDeliveryCount, 0)
    }

    func testConstructLadderStatePersistsInCanonicalPlayerAcrossTicksAndFIFO()
        throws
    {
        let session = try GModPlayableSession(
            configuration: GModPlayableSessionConfiguration(map: .construct)
        )
        defer { _ = try? session.close() }
        let serverRegistry = try XCTUnwrap(session.serverRuntime.entityRegistry)
        let clientRegistry = try XCTUnwrap(session.clientRuntime.entityRegistry)
        let playerIndex = session.configuration.playerEntityIndex
        let player = try XCTUnwrap(
            serverRegistry.canonicalSnapshot(at: playerIndex)
        )
        let ladderOrigin = SourceVector3(-2920, -1075, -95)
        let facingLadder = SourceQAngle(pitch: 0, yaw: 90, roll: 0)
        _ = try session.sourceAdapter.updateCanonicalEntity(player.identity) {
            $0.applyPlayerWalkState(SourceWorldWalkState(
                origin: ladderOrigin,
                viewAngles: facingLadder
            ))
        }

        let climbedReport = try session.runFixedTick(
            movementInput: GModPlayableMovementInput(
                viewAngles: facingLadder,
                forwardMove: 200,
                buttons: [.forward]
            )
        )
        guard case let .advanced(climbedTick) = climbedReport.movement else {
            return XCTFail("authored gm_construct ladder climb was rejected")
        }
        XCTAssertEqual(climbedTick.state.moveType, .ladder)
        XCTAssertEqual(
            climbedTick.state.ladderNormal,
            SourceVector3(0, -1, 0)
        )
        XCTAssertEqual(climbedTick.state.velocity.z, 200, accuracy: 0.000_01)
        XCTAssertEqual(
            climbedTick.state.origin.z - ladderOrigin.z,
            SourceWorldWalkSolver.maximumClimbSpeed *
                SourceGlobalVars.intervalPerTick,
            accuracy: 0.000_001
        )
        XCTAssertEqual(session.playerWalkState, climbedTick.state)
        let climbedServer = try XCTUnwrap(
            serverRegistry.canonicalSnapshot(at: playerIndex)
        )
        let climbedClient = try XCTUnwrap(
            clientRegistry.canonicalSnapshot(at: playerIndex)
        )
        XCTAssertEqual(climbedServer, climbedClient)
        XCTAssertEqual(climbedServer.moveType, .ladder)
        XCTAssertEqual(
            climbedServer.motion.ladderNormal,
            SourceVector3(0, -1, 0)
        )

        let descendedReport = try session.runFixedTick(
            movementInput: GModPlayableMovementInput(
                viewAngles: facingLadder,
                forwardMove: -200,
                buttons: [.back]
            )
        )
        guard case let .advanced(descendedTick) = descendedReport.movement else {
            return XCTFail("canonical ladder descent was rejected")
        }
        XCTAssertEqual(descendedTick.state.moveType, .ladder)
        XCTAssertEqual(
            descendedTick.state.ladderNormal,
            climbedTick.state.ladderNormal
        )
        XCTAssertEqual(descendedTick.state.velocity.z, -200, accuracy: 0.000_01)
        XCTAssertEqual(descendedTick.state.origin.z, ladderOrigin.z, accuracy: 0.000_001)
        XCTAssertEqual(session.playerWalkState, descendedTick.state)

        let jumpedReport = try session.runFixedTick(
            movementInput: GModPlayableMovementInput(
                viewAngles: facingLadder,
                buttons: [.jump]
            )
        )
        guard case let .advanced(jumpedTick) = jumpedReport.movement else {
            return XCTFail("canonical ladder jump-off was rejected")
        }
        XCTAssertEqual(jumpedTick.state.moveType, .walk)
        XCTAssertEqual(
            jumpedTick.state.velocity.y,
            -SourceWorldWalkSolver.ladderJumpOffSpeed
        )
        XCTAssertLessThan(jumpedTick.state.origin.y, descendedTick.state.origin.y)
        XCTAssertEqual(session.playerWalkState, jumpedTick.state)
        XCTAssertEqual(
            clientRegistry.canonicalSnapshot(at: playerIndex),
            serverRegistry.canonicalSnapshot(at: playerIndex)
        )
        XCTAssertEqual(session.sharedSession.netTransport.pendingDeliveryCount, 0)
    }
}
