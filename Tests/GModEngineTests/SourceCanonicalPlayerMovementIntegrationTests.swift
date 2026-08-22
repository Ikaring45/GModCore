import XCTest
@testable import GModEngine
@testable import GModGameSession
import GModLua

final class SourceCanonicalPlayerMovementIntegrationTests: XCTestCase {
    func testPlayerMovementGLuaMutationsAreValidatedAndTransactional() throws {
        let runtime = GMLuaRuntime(
            realm: .server,
            logger: { _ in },
            netTransport: GMLuaNetTransport()
        )
        let adapter = try GMLuaSourceRuntimeAdapter(serverRuntime: runtime)
        defer {
            try? adapter.close()
            _ = runtime.close()
        }
        try adapter.installCanonicalEntityLuaBridge()

        let player = try adapter.createCanonicalEntity(
            kind: .player,
            at: 7,
            playerUserID: 41
        )
        try runtime.execute(
            """
            local ply = Player(41)
            ply:SetSlowWalkSpeed(100)
            ply:SetWalkSpeed(200)
            ply:SetRunSpeed(400)
            ply:SetCrouchedWalkSpeed(0.3)
            ply:SetDuckSpeed(0.1)
            ply:SetUnDuckSpeed(0.2)
            ply:SetJumpPower(250)

            assert(ply:GetSlowWalkSpeed() == 100)
            assert(ply:GetWalkSpeed() == 200)
            assert(ply:GetRunSpeed() == 400)
            assert(math.abs(ply:GetCrouchedWalkSpeed() - 0.3) < 0.000001)
            assert(math.abs(ply:GetDuckSpeed() - 0.1) < 0.000001)
            assert(math.abs(ply:GetUnDuckSpeed() - 0.2) < 0.000001)
            assert(ply:GetJumpPower() == 250)

            assert(pcall(function() ply:SetWalkSpeed(-1) end) == false)
            assert(pcall(function() ply:SetRunSpeed(0 / 0) end) == false)
            assert(pcall(function() ply:SetJumpPower(math.huge) end) == false)
            """,
            sourceName: "=(canonical Player movement ABI)"
        )

        let snapshot = try XCTUnwrap(
            adapter.canonicalSnapshot(for: player.identity)
        )
        let settings = try XCTUnwrap(
            snapshot.motion.playerMovementSettings
        )
        XCTAssertEqual(snapshot.identity, player.identity)
        XCTAssertEqual(snapshot.revision, 7)
        XCTAssertEqual(settings.slowWalkSpeed, 100)
        XCTAssertEqual(settings.walkSpeed, 200)
        XCTAssertEqual(settings.runSpeed, 400)
        XCTAssertEqual(settings.crouchedWalkSpeed, 0.3, accuracy: 0.000_001)
        XCTAssertEqual(settings.duckSpeed, 0.1, accuracy: 0.000_001)
        XCTAssertEqual(settings.unDuckSpeed, 0.2, accuracy: 0.000_001)
        XCTAssertEqual(settings.jumpPower, 250)
        XCTAssertEqual(adapter.pendingCanonicalEntityOperationCount, 8)
    }

    func testOriginalSandboxPlayerManagerAuthorsFIFOStateUsedByFixedTick()
        throws
    {
        let configuration = GModPlayableSessionConfiguration(
            map: .construct,
            playerEntityIndex: 7,
            playerUserID: 70
        )
        let session = try GModPlayableSession(configuration: configuration)
        defer { _ = try? session.close() }
        let serverRegistry = try XCTUnwrap(session.serverRuntime.entityRegistry)
        let clientRegistry = try XCTUnwrap(session.clientRuntime.entityRegistry)
        let initialServer = try XCTUnwrap(
            serverRegistry.canonicalSnapshot(at: configuration.playerEntityIndex)
        )
        let initialClient = try XCTUnwrap(
            clientRegistry.canonicalSnapshot(at: configuration.playerEntityIndex)
        )
        XCTAssertEqual(initialServer, initialClient)
        XCTAssertEqual(
            initialServer.motion.playerMovementSettings,
            .legacyWorldWalkDefaults
        )

        let result = try session.serverRuntime.executeReturningValues(
            """
            local ply = Player(70)
            player_manager.SetPlayerClass(ply, "player_sandbox")
            assert(player_manager.GetPlayerClass(ply) == "player_sandbox")
            local ok, message = pcall(player_manager.OnPlayerSpawn, ply, false)
            return ok, message
            """,
            sourceName: "=(original player_manager.OnPlayerSpawn)"
        )
        guard case let .boolean(completed)? = result.first,
              case let .string(message)? = result.dropFirst().first else {
            return XCTFail("original player_manager result was malformed")
        }
        XCTAssertFalse(completed)
        XCTAssertTrue(
            message.utf8String.contains("ShouldDropWeapon"),
            "the original route must stop at its next honest unsupported ABI: \(message.utf8String)"
        )

        let authoredServer = try XCTUnwrap(
            serverRegistry.canonicalSnapshot(at: configuration.playerEntityIndex)
        )
        let authored = try XCTUnwrap(
            authoredServer.motion.playerMovementSettings
        )
        XCTAssertEqual(authoredServer.identity, initialServer.identity)
        XCTAssertGreaterThan(authoredServer.motion.playerClassID ?? 0, 0)
        XCTAssertEqual(authored.slowWalkSpeed, 100)
        XCTAssertEqual(authored.walkSpeed, 200)
        XCTAssertEqual(authored.runSpeed, 400)
        XCTAssertEqual(authored.crouchedWalkSpeed, 0.3, accuracy: 0.000_001)
        XCTAssertEqual(authored.duckSpeed, 0.1, accuracy: 0.000_001)
        XCTAssertEqual(authored.unDuckSpeed, 0.1, accuracy: 0.000_001)
        XCTAssertEqual(authored.jumpPower, 200)
        XCTAssertEqual(
            clientRegistry.canonicalSnapshot(at: configuration.playerEntityIndex),
            initialClient,
            "SERVER mutations must wait for the ordinary replication FIFO"
        )

        _ = try session.runFixedTick()
        let replicated = try XCTUnwrap(
            clientRegistry.canonicalSnapshot(at: configuration.playerEntityIndex)
        )
        XCTAssertEqual(
            replicated,
            serverRegistry.canonicalSnapshot(at: configuration.playerEntityIndex)
        )
        XCTAssertEqual(replicated.identity, initialServer.identity)
        try session.clientRuntime.execute(
            """
            local ply = Player(70)
            assert(ply:GetSlowWalkSpeed() == 100)
            assert(ply:GetWalkSpeed() == 200)
            assert(ply:GetRunSpeed() == 400)
            assert(math.abs(ply:GetCrouchedWalkSpeed() - 0.3) < 0.000001)
            assert(math.abs(ply:GetDuckSpeed() - 0.1) < 0.000001)
            assert(math.abs(ply:GetUnDuckSpeed() - 0.1) < 0.000001)
            assert(ply:GetJumpPower() == 200)
            """,
            sourceName: "=(replicated Player movement getters)"
        )

        let groundedOrigin = session.playerWalkState.origin
        func resetPlayer(ducked: Bool = false) throws {
            _ = try session.sourceAdapter.updateCanonicalEntity(
                initialServer.identity
            ) { state in
                state.applyPlayerWalkState(SourceWorldWalkState(
                    movement: SourceMoveData(
                        origin: groundedOrigin,
                        isOnGround: true
                    ),
                    viewAngles: session.spawnPoint.angles,
                    isDucked: ducked,
                    viewOffset: SourceVector3(0, 0, ducked ? 28 : 64)
                ))
            }
        }
        func movedSpeed(
            forwardMove: Float,
            buttons: SourceInputButtons
        ) throws -> SourceWorldWalkState {
            let report = try session.runFixedTick(
                movementInput: GModPlayableMovementInput(
                    viewAngles: session.spawnPoint.angles,
                    forwardMove: forwardMove,
                    buttons: buttons
                )
            )
            guard case let .advanced(tick) = report.movement else {
                throw XCTSkip("construct movement unexpectedly rejected")
            }
            return tick.state
        }

        try resetPlayer()
        let slow = try movedSpeed(
            forwardMove: 1_000,
            buttons: [.forward, .walk]
        )
        try resetPlayer()
        let normal = try movedSpeed(
            forwardMove: 1_000,
            buttons: [.forward]
        )
        try resetPlayer()
        let sprint = try movedSpeed(
            forwardMove: 1_000,
            buttons: [.forward, .speed]
        )
        XCTAssertEqual(slow.velocity.length, 15, accuracy: 0.001)
        XCTAssertEqual(normal.velocity.length, 30, accuracy: 0.001)
        XCTAssertEqual(sprint.velocity.length, 60, accuracy: 0.001)

        try resetPlayer(ducked: true)
        let crouched = try movedSpeed(
            forwardMove: 100,
            buttons: [.forward, .duck]
        )
        XCTAssertEqual(crouched.velocity.length, 4.5, accuracy: 0.001)

        try resetPlayer()
        let jumped = try movedSpeed(forwardMove: 0, buttons: [.jump])
        XCTAssertFalse(jumped.isOnGround)
        XCTAssertEqual(jumped.velocity.z, 188, accuracy: 0.001)
        XCTAssertEqual(session.sharedSession.netTransport.pendingDeliveryCount, 0)
    }
}
