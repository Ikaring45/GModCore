import XCTest
@testable import GModEngine
import GModLua

final class SourceCanonicalEntityNetworkVariableGLuaBridgeTests: XCTestCase {
    func testServerNWValuesReachTwoClientsOnlyThroughEntityFIFO() throws {
        let transport = GMLuaNetTransport()
        let shared = GMLuaSharedSession(netTransport: transport)
        let server = makeRuntime(.server, transport: transport)
        let firstClient = makeRuntime(.client, transport: transport)
        let secondClient = makeRuntime(.client, transport: transport)
        let adapter = try GMLuaSourceRuntimeAdapter(
            serverRuntime: server,
            initialEntitySerialNumber: 17
        )
        defer {
            try? shared.disconnect(client: secondClient)
            try? shared.disconnect(client: firstClient)
            try? adapter.close()
            _ = secondClient.close()
            _ = firstClient.close()
            _ = server.close()
        }

        try installNoopHooks(in: server)
        try installNoopHooks(in: firstClient)
        try installNoopHooks(in: secondClient)
        try adapter.installCanonicalEntityLuaBridge()
        try adapter.attach(client: firstClient)
        try adapter.attach(client: secondClient)

        let firstPlayer = try adapter.createCanonicalEntity(
            kind: .player,
            at: 1,
            playerUserID: 101
        )
        let secondPlayer = try adapter.createCanonicalEntity(
            kind: .player,
            at: 2,
            playerUserID: 102
        )
        let prop = try adapter.createCanonicalEntity(
            kind: .propPhysics,
            at: 20
        )

        try shared.connectCanonical(
            server: server,
            client: firstClient,
            playerIdentity: firstPlayer.identity,
            userID: 101,
            authoritativeSnapshots: adapter.canonicalEntitySnapshots
        )
        try shared.connectCanonical(
            server: server,
            client: secondClient,
            playerIdentity: secondPlayer.identity,
            userID: 102,
            authoritativeSnapshots: adapter.canonicalEntitySnapshots
        )
        _ = try adapter.discardPendingCanonicalEntityOperations()
        XCTAssertEqual(try shared.pump(), 2)

        for runtime in [server, firstClient, secondClient] {
            try runtime.execute(
                """
                assert(Entity(1):GetNWString("missing", false) == false)
                assert(Entity(1):GetNWString("missing") == nil)
                assert(Entity(1):GetNWInt("missing") == 0)
                assert(Entity(1):GetNWInt("missing", "fallback") == "fallback")
                """,
                sourceName: "=(canonical NW defaults)"
            )
        }
        try firstClient.execute(
            "assert(Entity(1).SetNWString == nil and Entity(1).SetNWInt == nil)",
            sourceName: "=(canonical CLIENT NW setter boundary)"
        )

        try server.execute(
            """
            Player(101):SetNWString("UserGroup", "superadmin")
            Player(101):SetNWInt("Count.props", 12.5)
            Entity(20):SetNWString("UserGroup", "prop-owner")
            """,
            sourceName: "=(canonical SERVER NW mutations)"
        )
        let playerAfterSet = try XCTUnwrap(
            adapter.canonicalSnapshot(for: firstPlayer.identity)
        )
        let propAfterSet = try XCTUnwrap(
            adapter.canonicalSnapshot(for: prop.identity)
        )
        XCTAssertEqual(playerAfterSet.revision, firstPlayer.revision + 2)
        XCTAssertEqual(propAfterSet.revision, prop.revision + 1)
        XCTAssertEqual(adapter.pendingCanonicalEntityOperationCount, 3)

        // Exact duplicate values must not manufacture another revision or
        // consume one journal slot.
        try server.execute(
            """
            Player(101):SetNWString("UserGroup", "superadmin")
            Player(101):SetNWInt("Count.props", 12.5)
            """,
            sourceName: "=(canonical NW no-op mutations)"
        )
        XCTAssertEqual(
            adapter.canonicalSnapshot(for: firstPlayer.identity),
            playerAfterSet
        )
        XCTAssertEqual(adapter.pendingCanonicalEntityOperationCount, 3)

        let journalBeforeRejection = adapter.pendingCanonicalEntityOperationCount
        try server.execute(
            """
            local before = Player(101):GetNWInt("Count.props")
            local ok = pcall(function()
                Player(101):SetNWInt("Count.props", {})
            end)
            assert(ok == false)
            assert(Player(101):GetNWInt("Count.props") == before)
            """,
            sourceName: "=(canonical NW rejected mutation)"
        )
        XCTAssertEqual(
            adapter.canonicalSnapshot(for: firstPlayer.identity),
            playerAfterSet
        )
        XCTAssertEqual(
            adapter.pendingCanonicalEntityOperationCount,
            journalBeforeRejection
        )

        for client in [firstClient, secondClient] {
            try assertInitialValues(in: client)
        }
        XCTAssertEqual(try publish(adapter: adapter, through: shared), 2)
        for client in [firstClient, secondClient] {
            try assertInitialValues(in: client)
        }

        // Fan-out is still two independent entries in the global FIFO. The
        // first destination becoming current cannot mutate the second realm.
        XCTAssertEqual(try shared.pump(maxDeliveries: 1), 1)
        try assertReplicatedValues(in: firstClient)
        try assertInitialValues(in: secondClient)
        XCTAssertEqual(try shared.pump(maxDeliveries: 1), 1)
        try assertReplicatedValues(in: secondClient)

        let revisionBeforeOverwrite = playerAfterSet.revision
        try server.execute(
            "Player(101):SetNWString(\"UserGroup\", \"operator\")",
            sourceName: "=(canonical NW overwrite)"
        )
        let overwritten = try XCTUnwrap(
            adapter.canonicalSnapshot(for: firstPlayer.identity)
        )
        XCTAssertEqual(overwritten.revision, revisionBeforeOverwrite + 1)
        XCTAssertEqual(adapter.pendingCanonicalEntityOperationCount, 1)
        XCTAssertEqual(try publish(adapter: adapter, through: shared), 2)
        try assertReplicatedValues(in: firstClient)
        try assertReplicatedValues(in: secondClient)
        XCTAssertEqual(try shared.pump(), 2)
        for client in [firstClient, secondClient] {
            try client.execute(
                """
                assert(Entity(1):GetNWString("UserGroup") == "operator")
                assert(Entity(2):GetNWString("UserGroup", "user") == "user")
                assert(Entity(20):GetNWString("UserGroup") == "prop-owner")
                """,
                sourceName: "=(canonical NW overwritten projection)"
            )
        }
    }

    func testRemovalDisconnectAndIndexReuseCannotReviveStaleNWState() throws {
        let transport = GMLuaNetTransport()
        let shared = GMLuaSharedSession(netTransport: transport)
        let server = makeRuntime(.server, transport: transport)
        let client = makeRuntime(.client, transport: transport)
        let adapter = try GMLuaSourceRuntimeAdapter(
            serverRuntime: server,
            initialEntitySerialNumber: 23
        )
        defer {
            try? shared.disconnect(client: client)
            try? adapter.close()
            _ = client.close()
            _ = server.close()
        }

        try installNoopHooks(in: server)
        try installNoopHooks(in: client)
        try adapter.installCanonicalEntityLuaBridge()
        try adapter.attach(client: client)
        let player = try adapter.createCanonicalEntity(
            kind: .player,
            at: 1,
            playerUserID: 201
        )
        let original = try adapter.createCanonicalEntity(
            kind: .propPhysics,
            at: 20
        )
        try shared.connectCanonical(
            server: server,
            client: client,
            playerIdentity: player.identity,
            userID: 201,
            authoritativeSnapshots: adapter.canonicalEntitySnapshots
        )
        _ = try adapter.discardPendingCanonicalEntityOperations()
        XCTAssertEqual(try shared.pump(), 1)

        try server.execute(
            "Entity(20):SetNWString(\"generation\", \"old\")"
        )
        XCTAssertEqual(try publish(adapter: adapter, through: shared), 1)
        XCTAssertEqual(try shared.pump(), 1)
        try client.execute(
            """
            OLD_ENTITY = Entity(20)
            assert(OLD_ENTITY:GetNWString("generation") == "old")
            """,
            sourceName: "=(capture original NW generation)"
        )

        _ = try adapter.markCanonicalEntityForRemoval(original.identity)
        let cleanup = try adapter.runServerFixedTick()
        XCTAssertEqual(cleanup.removedEntities, [original.identity])
        XCTAssertEqual(try publish(adapter: adapter, through: shared), 1)
        XCTAssertEqual(try shared.pump(), 1)
        try client.execute(
            """
            assert(OLD_ENTITY:IsValid() == false)
            assert(Entity(20):IsValid() == false)
            """,
            sourceName: "=(removed NW generation stays invalid)"
        )

        let replacement = try adapter.createCanonicalEntity(
            kind: .propPhysics,
            at: 20
        )
        XCTAssertNotEqual(replacement.identity, original.identity)
        XCTAssertEqual(try publish(adapter: adapter, through: shared), 1)
        XCTAssertEqual(try shared.pump(), 1)
        try client.execute(
            """
            assert(OLD_ENTITY:IsValid() == false)
            assert(Entity(20):IsValid() == true)
            assert(Entity(20):GetNWString("generation", "fresh") == "fresh")
            PRE_DISCONNECT_ENTITY = Entity(20)
            """,
            sourceName: "=(replacement NW state starts empty)"
        )

        try shared.disconnect(client: client)
        XCTAssertNil(client.entityRegistry?.canonicalSnapshot(at: 20))
        try client.execute(
            "assert(PRE_DISCONNECT_ENTITY:IsValid() == false)",
            sourceName: "=(disconnected canonical generation invalidated)"
        )
        try shared.connectCanonical(
            server: server,
            client: client,
            playerIdentity: player.identity,
            userID: 201,
            authoritativeSnapshots: adapter.canonicalEntitySnapshots
        )
        XCTAssertEqual(try shared.pump(), 1)
        try client.execute(
            """
            assert(PRE_DISCONNECT_ENTITY:IsValid() == false)
            assert(Entity(20):IsValid() == true)
            assert(Entity(20):GetNWString("generation", "fresh") == "fresh")
            """,
            sourceName: "=(fresh connection has only current NW snapshot)"
        )
    }

    private func makeRuntime(
        _ realm: GMLuaRealm,
        transport: GMLuaNetTransport
    ) -> GMLuaRuntime {
        GMLuaRuntime(
            realm: realm,
            logger: { _ in },
            netTransport: transport
        )
    }

    private func installNoopHooks(in runtime: GMLuaRuntime) throws {
        try runtime.execute(
            """
            GAMEMODE = {}
            hook = {}
            function hook.Call(event, gm) assert(gm == GAMEMODE) end
            """,
            sourceName: "=(canonical NW no-op hooks)"
        )
    }

    @discardableResult
    private func publish(
        adapter: GMLuaSourceRuntimeAdapter,
        through shared: GMLuaSharedSession
    ) throws -> Int {
        try adapter.publishPendingCanonicalEntityOperations {
            try shared.publishCanonicalEntityUpdates($0)
        }
    }

    private func assertInitialValues(in runtime: GMLuaRuntime) throws {
        try runtime.execute(
            """
            assert(Entity(1):GetNWString("UserGroup", "user") == "user")
            assert(Entity(1):GetNWInt("Count.props", -1) == -1)
            assert(Entity(2):GetNWString("UserGroup", "user") == "user")
            assert(Entity(20):GetNWString("UserGroup", "none") == "none")
            """,
            sourceName: "=(canonical NW pre-FIFO values)"
        )
    }

    private func assertReplicatedValues(in runtime: GMLuaRuntime) throws {
        try runtime.execute(
            """
            assert(Entity(1):GetNWString("UserGroup") == "superadmin")
            assert(Entity(1):GetNWInt("Count.props") == 12.5)
            assert(Entity(2):GetNWString("UserGroup", "user") == "user")
            assert(Entity(2):GetNWInt("Count.props") == 0)
            assert(Entity(20):GetNWString("UserGroup") == "prop-owner")
            """,
            sourceName: "=(canonical NW replicated values)"
        )
    }
}

