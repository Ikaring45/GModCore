import Foundation
import XCTest
@testable import GModEngine
import GModLua

private final class RemovalHookLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ message: String) {
        lock.lock()
        storage.append(message)
        lock.unlock()
    }

    var messages: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

final class CanonicalEntityRemovalHookIntegrationTests: XCTestCase {
    func testRemovalCallbacksAreRealmLocalGenerationSafeAndPurgedOnReconnect()
        throws
    {
        do {
        let transport = GMLuaNetTransport()
        let serverLog = RemovalHookLog()
        let firstLog = RemovalHookLog()
        let secondLog = RemovalHookLog()
        let server = makeRuntime(.server, transport: transport, log: serverLog)
        let first = makeRuntime(.client, transport: transport, log: firstLog)
        let second = makeRuntime(.client, transport: transport, log: secondLog)
        let adapter = try GMLuaSourceRuntimeAdapter(
            serverRuntime: server,
            initialEntitySerialNumber: 40
        )
        let session = GMLuaSharedSession(netTransport: transport)
        defer {
            try? session.disconnect(client: first)
            try? session.disconnect(client: second)
            try? adapter.close()
            _ = first.close()
            _ = second.close()
            _ = server.close()
        }

        try installRemovalSurface(in: server, prefix: "SERVER")
        try installRemovalSurface(in: first, prefix: "FIRST")
        try installRemovalSurface(in: second, prefix: "SECOND")

        _ = try adapter.createCanonicalEntity(kind: .world, at: 0)
        let firstPlayer = try adapter.createCanonicalEntity(
            kind: .player,
            at: 1,
            playerUserID: 11
        )
        let secondPlayer = try adapter.createCanonicalEntity(
            kind: .player,
            at: 2,
            playerUserID: 22
        )
        let original = try adapter.createCanonicalEntity(
            kind: .propPhysics,
            at: 20
        )
        _ = try adapter.discardPendingCanonicalEntityOperations()

        try session.connectCanonical(
            server: server,
            client: first,
            playerIdentity: firstPlayer.identity,
            userID: 11,
            authoritativeSnapshots: adapter.canonicalEntitySnapshots
        )
        try session.connectCanonical(
            server: server,
            client: second,
            playerIdentity: secondPlayer.identity,
            userID: 22,
            authoritativeSnapshots: adapter.canonicalEntitySnapshots
        )
        XCTAssertEqual(try session.pump(), 2)

        try registerRemovalProbe(
            in: server,
            prefix: "SERVER",
            entityIndex: original.identity.entryIndex,
            expectedMarker: "server-extra"
        )
        try registerRemovalProbe(
            in: first,
            prefix: "FIRST",
            entityIndex: original.identity.entryIndex,
            expectedMarker: "first-disconnected-extra"
        )
        try registerRemovalProbe(
            in: second,
            prefix: "SECOND",
            entityIndex: original.identity.entryIndex,
            expectedMarker: "second-extra"
        )

        // Disconnect invalidates the old realm-local userdata and drops its
        // sidecar callbacks without impersonating an EntityRemoved event.
        try session.disconnect(client: first)
        try first.execute(
            """
            assert(FIRST_CALLBACK_COUNT == 0)
            assert(FIRST_ENTITY_REMOVED_COUNT == 0)
            assert(not FIRST_OLD_ENTITY:IsValid())
            assert(FIRST_OLD_ENTITY:GetTable() == nil)
            """
        )

        try session.connectCanonical(
            server: server,
            client: first,
            playerIdentity: firstPlayer.identity,
            userID: 11,
            authoritativeSnapshots: adapter.canonicalEntitySnapshots
        )
        XCTAssertEqual(try session.pump(), 1)
        try registerRemovalProbe(
            in: first,
            prefix: "FIRST_RECONNECTED",
            entityIndex: original.identity.entryIndex,
            expectedMarker: "first-reconnected-extra"
        )

        _ = try adapter.markCanonicalEntityForRemoval(original.identity)
        let firstRemoval = try adapter.runServerFixedTick()
        XCTAssertEqual(firstRemoval.removedEntities, [original.identity])
        XCTAssertEqual(firstRemoval.hookFailures.count, 1)
        XCTAssertEqual(firstRemoval.hookFailures[0].event, "EntityRemoved")
        XCTAssertTrue(firstRemoval.hookFailures[0].message.contains("SERVER gm removal failure"))
        try publishPending(from: adapter, through: session)
        XCTAssertEqual(try session.pump(), 2)

        try assertRemovalProbe(
            in: server,
            prefix: "SERVER",
            expectedCallbackCount: 1
        )
        try first.execute(
            """
            assert(FIRST_CALLBACK_COUNT == 0)
            assert(FIRST_ENTITY_REMOVED_COUNT == 0)
            """
        )
        try assertRemovalProbe(
            in: first,
            prefix: "FIRST_RECONNECTED",
            expectedCallbackCount: 1
        )
        try assertRemovalProbe(
            in: second,
            prefix: "SECOND",
            expectedCallbackCount: 1
        )
        XCTAssertTrue(firstLog.messages.contains {
            $0.contains("FIRST_RECONNECTED gm removal failure")
        })
        XCTAssertTrue(secondLog.messages.contains {
            $0.contains("SECOND gm removal failure")
        })

        // Reuse the same entry with a new serial. Its sidecar starts empty,
        // so no callback retained by the old full EHANDLE can cross over.
        let replacement = try adapter.createCanonicalEntity(
            kind: .propPhysics,
            at: original.identity.entryIndex
        )
        XCTAssertNotEqual(replacement.identity.handle, original.identity.handle)
        try publishPending(from: adapter, through: session)
        XCTAssertEqual(try session.pump(), 2)
        try registerRemovalProbe(
            in: server,
            prefix: "SERVER_REUSE",
            entityIndex: replacement.identity.entryIndex,
            expectedMarker: "server-reuse-extra"
        )
        try registerRemovalProbe(
            in: first,
            prefix: "FIRST_REUSE",
            entityIndex: replacement.identity.entryIndex,
            expectedMarker: "first-reuse-extra"
        )
        try registerRemovalProbe(
            in: second,
            prefix: "SECOND_REUSE",
            entityIndex: replacement.identity.entryIndex,
            expectedMarker: "second-reuse-extra"
        )

        _ = try adapter.markCanonicalEntityForRemoval(replacement.identity)
        let replacementRemoval = try adapter.runServerFixedTick()
        XCTAssertEqual(replacementRemoval.removedEntities, [replacement.identity])
        XCTAssertEqual(replacementRemoval.hookFailures.count, 1)
        try publishPending(from: adapter, through: session)
        XCTAssertEqual(try session.pump(), 2)
        try assertRemovalProbe(
            in: server,
            prefix: "SERVER_REUSE",
            expectedCallbackCount: 1
        )
        try assertRemovalProbe(
            in: first,
            prefix: "FIRST_REUSE",
            expectedCallbackCount: 1
        )
        try assertRemovalProbe(
            in: second,
            prefix: "SECOND_REUSE",
            expectedCallbackCount: 1
        )
        try assertRemovalProbe(
            in: server,
            prefix: "SERVER",
            expectedCallbackCount: 1
        )
        try assertRemovalProbe(
            in: first,
            prefix: "FIRST_RECONNECTED",
            expectedCallbackCount: 1
        )
        try assertRemovalProbe(
            in: second,
            prefix: "SECOND",
            expectedCallbackCount: 1
        )

        // Adapter close is teardown, not a gameplay removal observation. It
        // invalidates and purges the sidecar without firing callbacks.
        let closeOnly = try adapter.createCanonicalEntity(
            kind: .propPhysics,
            at: 30
        )
        try server.execute(
            """
            CLOSE_ONLY_COUNT = 0
            CLOSE_ONLY_ENTITY = Entity(\(closeOnly.identity.entryIndex))
            CLOSE_ONLY_ENTITY:CallOnRemove("close-only", function()
                CLOSE_ONLY_COUNT = CLOSE_ONLY_COUNT + 1
            end)
            """
        )
        try adapter.close()
        try server.execute(
            """
            assert(CLOSE_ONLY_COUNT == 0)
            assert(not CLOSE_ONLY_ENTITY:IsValid())
            assert(CLOSE_ONLY_ENTITY:GetTable() == nil)
            """
        )
        } catch {
            XCTFail("removal integration failed: \(GMLuaRuntime.describe(error))")
            throw error
        }
    }

    func testNetworkEntityCreatedFailureIsLoggedAndDoesNotReplayPacket()
        throws
    {
        let transport = GMLuaNetTransport()
        let serverLog = RemovalHookLog()
        let clientLog = RemovalHookLog()
        let server = makeRuntime(.server, transport: transport, log: serverLog)
        let client = makeRuntime(.client, transport: transport, log: clientLog)
        let adapter = try GMLuaSourceRuntimeAdapter(
            serverRuntime: server,
            initialEntitySerialNumber: 70
        )
        let session = GMLuaSharedSession(netTransport: transport)
        defer {
            try? session.disconnect(client: client)
            try? adapter.close()
            _ = client.close()
            _ = server.close()
        }

        let player = try adapter.createCanonicalEntity(
            kind: .player,
            at: 1,
            playerUserID: 91
        )
        let firstProp = try adapter.createCanonicalEntity(
            kind: .propPhysics,
            at: 15
        )
        _ = try adapter.discardPendingCanonicalEntityOperations()
        try client.execute(
            """
            GAMEMODE = {}
            hook = {}
            NETWORK_CREATED_FAILURE_COUNT = 0
            function hook.Call(event, gm, ...)
                assert(gm == GAMEMODE)
                if event == "NetworkEntityCreated" then
                    local ent = ...
                    assert(ent:IsValid())
                    NETWORK_CREATED_FAILURE_COUNT = NETWORK_CREATED_FAILURE_COUNT + 1
                    error("intentional NetworkEntityCreated failure")
                end
            end
            """
        )

        try session.connectCanonical(
            server: server,
            client: client,
            playerIdentity: player.identity,
            userID: 91,
            authoritativeSnapshots: adapter.canonicalEntitySnapshots
        )
        XCTAssertEqual(try session.pump(), 1)
        XCTAssertEqual(
            client.entityRegistry?.canonicalEntityReplicationCursor?.sequence,
            1
        )
        XCTAssertEqual(
            client.entityRegistry?.canonicalSnapshot(at: firstProp.identity.entryIndex),
            firstProp
        )
        try client.execute("assert(NETWORK_CREATED_FAILURE_COUNT == 2)")

        let secondProp = try adapter.createCanonicalEntity(
            kind: .propPhysics,
            at: 16
        )
        try publishPending(from: adapter, through: session)
        XCTAssertEqual(try session.pump(), 1)
        XCTAssertEqual(try session.pump(), 0)
        XCTAssertEqual(
            client.entityRegistry?.canonicalEntityReplicationCursor?.sequence,
            2
        )
        XCTAssertEqual(
            client.entityRegistry?.canonicalSnapshot(at: secondProp.identity.entryIndex),
            secondProp
        )
        try client.execute("assert(NETWORK_CREATED_FAILURE_COUNT == 3)")
        XCTAssertEqual(
            clientLog.messages.filter {
                $0.contains("intentional NetworkEntityCreated failure")
            }.count,
            3
        )
    }

    private func makeRuntime(
        _ realm: GMLuaRealm,
        transport: GMLuaNetTransport,
        log: RemovalHookLog
    ) -> GMLuaRuntime {
        GMLuaRuntime(
            realm: realm,
            logger: { log.append($0) },
            netTransport: transport
        )
    }

    private func installRemovalSurface(
        in runtime: GMLuaRuntime,
        prefix: String
    ) throws {
        try runtime.execute(
            """
            GAMEMODE = {}
            hook = {}
            local handlers = {}
            function hook.Add(event, identifier, callback)
                handlers[event] = handlers[event] or {}
                handlers[event][identifier] = callback
            end
            function hook.Call(event, gm, ...)
                assert(gm == GAMEMODE)
                local callbacks = handlers[event]
                if callbacks then
                    for _, callback in pairs(callbacks) do callback(...) end
                end
                local gamemodeCallback = gm and gm[event]
                if gamemodeCallback then return gamemodeCallback(gm, ...) end
            end

            local entityMeta = assert(FindMetaTable("Entity"))
            function entityMeta:CallOnRemove(identifier, callback, ...)
                local sidecar = self:GetTable()
                sidecar.OnDieFunctions = sidecar.OnDieFunctions or {}
                sidecar.OnDieFunctions[identifier] = {
                    Name = identifier,
                    Function = callback,
                    Args = { ... }
                }
            end
            function entityMeta:RemoveCallOnRemove(identifier)
                local sidecar = self:GetTable()
                sidecar.OnDieFunctions = sidecar.OnDieFunctions or {}
                sidecar.OnDieFunctions[identifier] = nil
            end
            hook.Add("EntityRemoved", "DoDieFunction", function(ent)
                if not ent.OnDieFunctions then return end
                for _, data in pairs(ent.OnDieFunctions) do
                    if data and data.Function then
                        ProtectedCall(
                            data.Function,
                            ent,
                            unpack(data.Args)
                        )
                    end
                end
            end)

            \(prefix)_CALLBACK_COUNT = 0
            \(prefix)_CANCELLED_COUNT = 0
            \(prefix)_ENTITY_REMOVED_COUNT = 0
            """,
            sourceName: "=(\(prefix) removal surface)"
        )
    }

    private func registerRemovalProbe(
        in runtime: GMLuaRuntime,
        prefix: String,
        entityIndex: Int,
        expectedMarker: String
    ) throws {
        try runtime.execute(
            """
            \(prefix)_CALLBACK_COUNT = \(prefix)_CALLBACK_COUNT or 0
            \(prefix)_CANCELLED_COUNT = \(prefix)_CANCELLED_COUNT or 0
            \(prefix)_ENTITY_REMOVED_COUNT = \(prefix)_ENTITY_REMOVED_COUNT or 0
            \(prefix)_OLD_ENTITY = Entity(\(entityIndex))
            assert(\(prefix)_OLD_ENTITY:IsValid())
            \(prefix)_OLD_ENTITY:CallOnRemove(
                "replaceable",
                function() error("replaced callback must not run") end
            )
            \(prefix)_OLD_ENTITY:CallOnRemove(
                "replaceable",
                function(ent, marker, payload)
                    assert(ent:IsValid())
                    assert(Entity(\(entityIndex)) == ent)
                    assert(marker == "\(expectedMarker)")
                    assert(payload.token == 37)
                    \(prefix)_CALLBACK_COUNT = \(prefix)_CALLBACK_COUNT + 1
                end,
                "\(expectedMarker)",
                { token = 37 }
            )
            \(prefix)_OLD_ENTITY:CallOnRemove("cancelled", function()
                \(prefix)_CANCELLED_COUNT = \(prefix)_CANCELLED_COUNT + 1
            end)
            \(prefix)_OLD_ENTITY:RemoveCallOnRemove("cancelled")
            \(prefix)_OLD_ENTITY:CallOnRemove("contained-error", function()
                error("\(prefix) contained CallOnRemove failure")
            end)
            collectgarbage()

            hook.Add("EntityRemoved", "\(prefix)-observer", function(ent, fullUpdate)
                if ent ~= \(prefix)_OLD_ENTITY then return end
                assert(ent:IsValid())
                assert(Entity(\(entityIndex)) == ent)
                assert(fullUpdate == false)
                \(prefix)_ENTITY_REMOVED_COUNT = \(prefix)_ENTITY_REMOVED_COUNT + 1
            end)
            function GAMEMODE:EntityRemoved(ent, fullUpdate)
                if ent ~= \(prefix)_OLD_ENTITY then return end
                assert(ent:IsValid())
                assert(fullUpdate == false)
                error("\(prefix) gm removal failure")
            end
            """,
            sourceName: "=(\(prefix) removal probe)"
        )
    }

    private func assertRemovalProbe(
        in runtime: GMLuaRuntime,
        prefix: String,
        expectedCallbackCount: Int
    ) throws {
        try runtime.execute(
            """
            assert(
                \(prefix)_CALLBACK_COUNT == \(expectedCallbackCount),
                "callback=" .. tostring(\(prefix)_CALLBACK_COUNT)
            )
            assert(
                \(prefix)_CANCELLED_COUNT == 0,
                "cancelled=" .. tostring(\(prefix)_CANCELLED_COUNT)
            )
            assert(
                \(prefix)_ENTITY_REMOVED_COUNT == 1,
                "hook=" .. tostring(\(prefix)_ENTITY_REMOVED_COUNT)
            )
            assert(not \(prefix)_OLD_ENTITY:IsValid())
            assert(\(prefix)_OLD_ENTITY:GetTable() == nil)
            """,
            sourceName: "=(\(prefix) removal assertions)"
        )
    }

    private func publishPending(
        from adapter: GMLuaSourceRuntimeAdapter,
        through session: GMLuaSharedSession
    ) throws {
        _ = try adapter.publishPendingCanonicalEntityOperations {
            try session.publishCanonicalEntityUpdates($0)
        }
    }
}
