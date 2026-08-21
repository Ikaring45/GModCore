import XCTest
@testable import GModEngine
@testable import GModGameSession

private struct CanonicalPlayableLadderProvider:
    SourceWorldWalkCollisionProvider
{
    func traceWorldWalk(
        _ ray: SourceRay,
        mask _: SourceContents
    ) throws -> SourceGameTrace {
        SourceGameTrace(ray: ray)
    }

    func worldWalkPointContents(
        at _: SourceVector3,
        mask _: SourceContents
    ) throws -> SourceContents {
        .ladder
    }
}

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
        XCTAssertEqual(movedServerPlayer.transform.origin, advanced.state.origin)
        XCTAssertEqual(movedServerPlayer.transform.angles, advanced.state.viewAngles)
        XCTAssertEqual(session.playerWalkState, advanced.state)
        XCTAssertEqual(session.sharedSession.netTransport.pendingDeliveryCount, 0)
        _ = try session.close()

        let rejected = try GModPlayableSession(
            configuration: GModPlayableSessionConfiguration(map: .construct),
            textMeasurer: nil,
            logger: { _, _ in },
            worldWalkCollisionProvider: CanonicalPlayableLadderProvider()
        )
        defer { _ = try? rejected.close() }
        let rejectedServerRegistry = try XCTUnwrap(
            rejected.serverRuntime.entityRegistry
        )
        let rejectedClientRegistry = try XCTUnwrap(
            rejected.clientRuntime.entityRegistry
        )
        let playerIndex = rejected.configuration.playerEntityIndex
        let beforeServer = try XCTUnwrap(
            rejectedServerRegistry.canonicalSnapshot(at: playerIndex)
        )
        let beforeClient = try XCTUnwrap(
            rejectedClientRegistry.canonicalSnapshot(at: playerIndex)
        )
        let preservedState = rejected.playerWalkState

        let rejectedTick = try rejected.runFixedTick(
            movementInput: GModPlayableMovementInput(
                forwardMove: 200,
                buttons: [.forward]
            )
        )
        guard case let .rejected(rejection) = rejectedTick.movement else {
            return XCTFail("ladder movement advanced canonical Player")
        }
        XCTAssertEqual(rejection.reason, .feature(.ladder))
        XCTAssertEqual(rejection.preservedState, preservedState)
        XCTAssertEqual(rejected.playerWalkState, preservedState)
        XCTAssertEqual(
            rejectedServerRegistry.canonicalSnapshot(at: playerIndex),
            beforeServer
        )
        XCTAssertEqual(
            rejectedClientRegistry.canonicalSnapshot(at: playerIndex),
            beforeClient
        )
        XCTAssertEqual(rejected.sharedSession.netTransport.pendingDeliveryCount, 0)
    }
}
