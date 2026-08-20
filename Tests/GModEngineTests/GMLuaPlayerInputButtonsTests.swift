import XCTest
@testable import GModEngine
import GModLua

final class GMLuaPlayerInputButtonsTests: XCTestCase {
    func testOfficialInputGlobalsAndPlayerOnlyKeyDownUseExactSourceBits() throws {
        let runtime = GMLuaRuntime(realm: .server, logger: { _ in })
        defer { _ = runtime.close() }
        let registry = try XCTUnwrap(runtime.entityRegistry)
        let first = try registry.register(
            index: 9,
            kind: .player,
            className: "player"
        )
        runtime.state.setGlobal("TEST_PLAYER", value: first)

        try runtime.execute(
            """
            assert(IN_ATTACK == 1)
            assert(IN_JUMP == 2)
            assert(IN_DUCK == 4)
            assert(IN_FORWARD == 8)
            assert(IN_BACK == 16)
            assert(IN_USE == 32)
            assert(IN_CANCEL == 64)
            assert(IN_LEFT == 128)
            assert(IN_RIGHT == 256)
            assert(IN_MOVELEFT == 512)
            assert(IN_MOVERIGHT == 1024)
            assert(IN_ATTACK2 == 2048)
            assert(IN_RUN == 4096)
            assert(IN_RELOAD == 8192)
            assert(IN_ALT1 == 16384)
            assert(IN_ALT2 == 32768)
            assert(IN_SCORE == 65536)
            assert(IN_SPEED == 131072)
            assert(IN_WALK == 262144)
            assert(IN_ZOOM == 524288)
            assert(IN_WEAPON1 == 1048576)
            assert(IN_WEAPON2 == 2097152)
            assert(IN_BULLRUSH == 4194304)
            assert(IN_GRENADE1 == 8388608)
            assert(IN_GRENADE2 == 16777216)
            assert(IN_ATTACK3 == 33554432)

            assert(type(FindMetaTable("Player").KeyDown) == "function")
            assert(FindMetaTable("Entity").KeyDown == nil)
            assert(NULL.KeyDown == nil)
            assert(TEST_PLAYER:IsPlayer())
            assert(not TEST_PLAYER:KeyDown(IN_FORWARD))
            assert(not TEST_PLAYER:KeyDown(IN_FORWARD + IN_ATTACK2))
            local ok = pcall(function() TEST_PLAYER:KeyDown() end)
            assert(not ok)
            """,
            sourceName: "=(official IN globals and Player KeyDown)"
        )

        XCTAssertTrue(
            registry.setPlayerInputButtons(
                index: 9,
                generation: 0,
                buttons: [.forward, .attack2]
            )
        )
        try runtime.execute(
            """
            assert(TEST_PLAYER:KeyDown(IN_FORWARD))
            assert(TEST_PLAYER:KeyDown(IN_ATTACK2))
            assert(TEST_PLAYER:KeyDown(IN_FORWARD + IN_RELOAD))
            assert(not TEST_PLAYER:KeyDown(IN_BACK))
            assert(not TEST_PLAYER:KeyDown(0))
            OLD_PLAYER = TEST_PLAYER
            """
        )

        registry.unregister(index: 9)
        let replacement = try registry.register(
            index: 9,
            kind: .player,
            className: "player"
        )
        runtime.state.setGlobal("TEST_PLAYER", value: replacement)
        try runtime.execute(
            """
            assert(not OLD_PLAYER:IsValid() and OLD_PLAYER == NULL)
            assert(not OLD_PLAYER:KeyDown(IN_FORWARD))
            assert(TEST_PLAYER:IsValid() and TEST_PLAYER ~= OLD_PLAYER)
            assert(not TEST_PLAYER:KeyDown(IN_FORWARD))
            """
        )
    }

    func testSharedSessionPublishesExactButtonsToEveryRealmAndReconnectClearsState() throws {
        let session = GMLuaSharedSession()
        let server = GMLuaRuntime(
            realm: .server,
            logger: { _ in },
            netTransport: session.netTransport
        )
        let first = GMLuaRuntime(
            realm: .client,
            logger: { _ in },
            netTransport: session.netTransport
        )
        let second = GMLuaRuntime(
            realm: .client,
            logger: { _ in },
            netTransport: session.netTransport
        )
        defer {
            _ = first.close()
            _ = second.close()
            _ = server.close()
        }

        try session.connect(
            server: server,
            client: first,
            playerIndex: 1,
            userID: 101
        )
        try session.connect(
            server: server,
            client: second,
            playerIndex: 2,
            userID: 202
        )
        try session.updatePlayerInputButtons(
            for: first,
            buttons: [.forward, .attack2]
        )

        try server.execute(
            """
            assert(Player(101):KeyDown(IN_FORWARD))
            assert(Player(101):KeyDown(IN_ATTACK2))
            assert(not Player(101):KeyDown(IN_BACK))
            assert(not Player(202):KeyDown(IN_FORWARD))
            SERVER_OLD_PLAYER = Player(101)
            """
        )
        try first.execute(
            """
            assert(LocalPlayer() == Player(101))
            assert(LocalPlayer():KeyDown(IN_FORWARD))
            assert(LocalPlayer():KeyDown(IN_ATTACK2))
            CLIENT_OLD_PLAYER = LocalPlayer()
            """
        )
        try second.execute(
            """
            assert(LocalPlayer() == Player(202))
            assert(Player(101):KeyDown(IN_FORWARD))
            assert(not LocalPlayer():KeyDown(IN_FORWARD))
            """
        )

        try session.disconnect(client: first)
        try server.execute(
            """
            assert(not SERVER_OLD_PLAYER:IsValid())
            assert(not SERVER_OLD_PLAYER:KeyDown(IN_FORWARD))
            assert(Player(101) == NULL)
            """
        )
        try first.execute(
            """
            assert(LocalPlayer() == NULL)
            assert(not CLIENT_OLD_PLAYER:IsValid())
            assert(not CLIENT_OLD_PLAYER:KeyDown(IN_FORWARD))
            """
        )
        XCTAssertThrowsError(
            try session.updatePlayerInputButtons(for: first, buttons: [.use])
        )

        try session.connect(
            server: server,
            client: first,
            playerIndex: 1,
            userID: 101
        )
        try first.execute(
            """
            assert(LocalPlayer():IsValid() and LocalPlayer() ~= CLIENT_OLD_PLAYER)
            assert(not LocalPlayer():KeyDown(IN_FORWARD))
            assert(not LocalPlayer():KeyDown(IN_USE))
            """
        )
        try session.updatePlayerInputButtons(for: first, buttons: [.back])
        try server.execute(
            """
            assert(Player(101):KeyDown(IN_BACK))
            assert(not Player(101):KeyDown(IN_FORWARD))
            assert(not SERVER_OLD_PLAYER:KeyDown(IN_BACK))
            """
        )
        try first.execute(
            """
            assert(LocalPlayer():KeyDown(IN_BACK))
            assert(not LocalPlayer():KeyDown(IN_FORWARD))
            assert(not CLIENT_OLD_PLAYER:KeyDown(IN_BACK))
            """
        )
        try second.execute(
            """
            assert(Player(101):KeyDown(IN_BACK))
            assert(not Player(101):KeyDown(IN_FORWARD))
            """
        )
    }
}
