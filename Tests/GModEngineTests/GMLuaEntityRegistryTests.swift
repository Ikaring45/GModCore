import Foundation
import XCTest
@testable import GModEngine
import GModLua

final class GMLuaEntityRegistryTests: XCTestCase {
    func testEntityIndexRejectsIntOverflowWithoutTrapping() throws {
        let runtime = GMLuaRuntime(realm: .server, logger: { _ in })
        try runtime.execute(
            """
            local ok, err = pcall(Entity, 9223372036854775808)
            assert(not ok and string.find(err, "finite entity index expected", 1, true))
            """,
            sourceName: "@GMLuaEntityIndexRangeRegression.lua"
        )
    }

    func testNativeRegistryIdentityEnumerationAndInvalidationRegression() throws {
        let fixtureURL = try XCTUnwrap(
            Bundle.module.url(
                forResource: "GLuaEntityRegistryRegression",
                withExtension: "lua",
                subdirectory: "Fixtures"
            ) ?? Bundle.module.url(
                forResource: "GLuaEntityRegistryRegression",
                withExtension: "lua"
            )
        )
        let source = try String(contentsOf: fixtureURL, encoding: .utf8)

        let state = LuaState(output: { _ in })
        let typeSystem = try GMLuaTypeSystem.install(
            into: state,
            utilityLayer: .bundledFallback
        )
        let registry = try GMLuaEntityRegistry.install(
            into: state,
            typeSystem: typeSystem
        )

        let oldEntity = try registry.register(
            index: 5,
            className: "obsolete_prop"
        )
        let entity = try registry.register(
            index: 5,
            className: "prop_physics"
        )
        let removedEntity = try registry.register(
            index: 6,
            className: "removed_prop"
        )
        registry.unregister(index: 6)
        let player = try registry.register(
            index: 2,
            kind: .player,
            className: "player"
        )
        let weapon = try registry.register(
            index: 7,
            kind: .weapon,
            className: "weapon_crowbar"
        )
        let vehicle = try registry.register(
            index: 9,
            kind: .vehicle,
            className: "prop_vehicle_jeep"
        )

        state.setGlobal("TEST_OLD_ENTITY", value: oldEntity)
        state.setGlobal("TEST_ENTITY", value: entity)
        state.setGlobal("TEST_REMOVED_ENTITY", value: removedEntity)
        state.setGlobal("TEST_PLAYER", value: player)
        state.setGlobal("TEST_WEAPON", value: weapon)
        state.setGlobal("TEST_VEHICLE", value: vehicle)

        try state.execute(source, sourceName: "@GLuaEntityRegistryRegression.lua")
        guard case .boolean(true) = state.getGlobal("GLUA_ENTITY_REGISTRY_REGRESSION_OK") else {
            return XCTFail("Entity registry regression fixture did not reach its success sentinel")
        }

        XCTAssertEqual(registry.registeredCount, 4)
        XCTAssertFalse(try XCTUnwrap(GMLuaTypeSystem.typedObject(from: oldEntity)).isValid)
        XCTAssertFalse(try XCTUnwrap(GMLuaTypeSystem.typedObject(from: removedEntity)).isValid)
        XCTAssertTrue(try XCTUnwrap(GMLuaTypeSystem.typedObject(from: entity)).isValid)
    }

    func testStrictRuntimeRetainsRegistryAndExposesNativeCollections() throws {
        let runtime = GMLuaRuntime(
            realm: .server,
            logger: { _ in },
            bootstrapMode: .strict
        )
        let registry = try XCTUnwrap(runtime.entityRegistry)
        let player = try registry.register(
            index: 3,
            kind: .player,
            className: "player"
        )
        runtime.state.setGlobal("TEST_RUNTIME_PLAYER", value: player)

        try runtime.execute(
            """
            assert(type(Entity) == "function")
            assert(type(Player) == "function")
            assert(type(ents) == "table" and type(player) == "table")
            assert(type(TEST_RUNTIME_PLAYER) == "userdata")
            assert(Entity(3) == TEST_RUNTIME_PLAYER)
            assert(Player(3) == TEST_RUNTIME_PLAYER)
            assert(ents.GetByIndex(3) == TEST_RUNTIME_PLAYER)
            assert(TEST_RUNTIME_PLAYER:EntIndex() == 3)
            assert(TEST_RUNTIME_PLAYER:GetClass() == "player")
            assert(TEST_RUNTIME_PLAYER:IsPlayer() and TEST_RUNTIME_PLAYER:IsValid())
            local all = ents.GetAll()
            local players = player.GetAll()
            assert(#all == 1 and all[1] == TEST_RUNTIME_PLAYER)
            assert(#players == 1 and players[1] == TEST_RUNTIME_PLAYER)
            assert(Entity(999) == NULL and not Entity(999):IsValid())
            """,
            sourceName: "@GMLuaEntityRegistryStrictRuntime.lua"
        )

        registry.unregister(index: 3)
        try runtime.execute(
            """
            assert(not TEST_RUNTIME_PLAYER:IsValid())
            assert(TEST_RUNTIME_PLAYER == NULL and TEST_RUNTIME_PLAYER:EntIndex() == 0)
            assert(Entity(3) == NULL and Player(3) == NULL)
            assert(#ents.GetAll() == 0 and #player.GetAll() == 0)
            """
        )
    }

    func testEntityLuaTableSupportsAccessorFuncPrecedenceExactSetTableAndStaleDrop() throws {
        let runtime = GMLuaRuntime(realm: .server, logger: { _ in })
        defer { _ = runtime.close() }
        let registry = try XCTUnwrap(runtime.entityRegistry)
        let oldPlayer = try registry.register(
            index: 4,
            kind: .player,
            className: "player"
        )
        runtime.state.setGlobal("TEST_PLAYER", value: oldPlayer)

        try runtime.execute(
            """
            local entityMeta = FindMetaTable("Entity")
            local playerMeta = FindMetaTable("Player")
            assert(TEST_PLAYER:GetTable() == TEST_PLAYER:GetTable())
            local originalTable = TEST_PLAYER:GetTable()

            playerMeta.SetRole = function(self, value)
                self.role = tonumber(value)
            end
            playerMeta.GetRole = function(self)
                return self.role
            end
            TEST_PLAYER:SetRole("7")
            assert(TEST_PLAYER:GetRole() == 7)
            assert(originalTable.role == 7)

            entityMeta.BaseProbe = function() return "entity-method" end
            playerMeta.PrecedenceProbe = function() return "player-method" end
            entityMeta.PrecedenceProbe = function() return "entity-method" end
            originalTable.BaseProbe = "sidecar-base"
            originalTable.PrecedenceProbe = "sidecar-player"
            originalTable.IsValid = "sidecar-validity"
            originalTable.SidecarOnly = "sidecar-only"
            assert(TEST_PLAYER:BaseProbe() == "entity-method")
            assert(TEST_PLAYER:PrecedenceProbe() == "player-method")
            assert(type(TEST_PLAYER.IsValid) == "function")
            assert(rawget(originalTable, "IsValid") == "sidecar-validity")
            assert(TEST_PLAYER.SidecarOnly == "sidecar-only")

            local routed = {}
            local replacement = setmetatable({}, {
                __index = routed,
                __newindex = function(_, key, value) routed[key] = value * 2 end
            })
            TEST_PLAYER:SetTable(replacement)
            assert(TEST_PLAYER:GetTable() == replacement)
            TEST_PLAYER.routed = 5
            TEST_PLAYER:GetTable().direct = 6
            assert(routed.routed == 10 and TEST_PLAYER.routed == 10)
            assert(routed.direct == 12 and TEST_PLAYER.direct == 12)

            local environment = { environmentOnly = true }
            debug.setfenv(TEST_PLAYER, environment)
            assert(debug.getfenv(TEST_PLAYER) == environment)
            assert(TEST_PLAYER:GetTable() ~= environment)
            assert(TEST_PLAYER.environmentOnly == nil)

            NULL.ignoredWrite = 123
            assert(NULL.ignoredWrite == nil and NULL:GetTable() == nil)
            OLD_PLAYER = TEST_PLAYER
            OLD_TABLE = TEST_PLAYER:GetTable()
            """,
            sourceName: "@GMLuaEntityTableRegression.lua"
        )

        let replacement = try registry.register(
            index: 4,
            kind: .player,
            className: "player"
        )
        runtime.state.setGlobal("NEW_PLAYER", value: replacement)
        try runtime.execute(
            """
            assert(not OLD_PLAYER:IsValid())
            assert(OLD_PLAYER == NULL and OLD_PLAYER:EntIndex() == 0)
            assert(OLD_PLAYER:GetTable() == nil)
            OLD_PLAYER.staleWrite = 99
            assert(OLD_PLAYER.staleWrite == nil)
            assert(NEW_PLAYER:IsValid() and NEW_PLAYER == Player(4))
            assert(NEW_PLAYER:GetTable() ~= OLD_TABLE)
            assert(NEW_PLAYER:GetTable().role == nil)
            NEW_PLAYER.fresh = "new-generation"
            assert(NEW_PLAYER.fresh == "new-generation")
            """
        )
    }

    func testEntityHostRootsSurviveGlobalOverwriteAndDetachSidecarForCollection() throws {
        let runtime = GMLuaRuntime(realm: .server, logger: { _ in })
        defer { _ = runtime.close() }
        let registry = try XCTUnwrap(runtime.entityRegistry)
        let playerValue = try registry.register(
            index: 14,
            kind: .player,
            className: "player"
        )
        runtime.state.setGlobal("ROOTED_PLAYER", value: playerValue)
        try runtime.execute(
            """
            ROOTED_PLAYER.strong = { marker = 9 }
            ROOTED_PLAYER.weakContainer = setmetatable(
                { value = { collectMe = true } },
                { __mode = "v" }
            )
            """
        )
        let firstTableValue = try XCTUnwrap(
            runtime.executeReturningValues("return ROOTED_PLAYER:GetTable()").first
        )
        guard case let .table(firstTable) = firstTableValue else {
            return XCTFail("Entity:GetTable did not return a table")
        }

        try runtime.execute(
            """
            ROOTED_PLAYER = nil
            Entity = nil
            Player = nil
            ents = nil
            player = nil
            FindMetaTable = nil
            NULL = nil
            collectgarbage("collect")
            """
        )
        XCTAssertTrue(
            GMLuaTypeSystem.typedObject(from: registry.player(at: 14))?.isValid == true
        )
        runtime.state.setGlobal("RESTORED_PLAYER", value: registry.player(at: 14))
        try runtime.execute(
            """
            assert(RESTORED_PLAYER:IsValid())
            assert(RESTORED_PLAYER.strong.marker == 9)
            assert(RESTORED_PLAYER.weakContainer.value == nil)
            """
        )
        let restoredTableValue = try XCTUnwrap(
            runtime.executeReturningValues("return RESTORED_PLAYER:GetTable()").first
        )
        guard case let .table(restoredTable) = restoredTableValue else {
            return XCTFail("rooted Entity sidecar disappeared after global overwrite")
        }
        XCTAssertTrue(firstTable === restoredTable)

        registry.unregister(index: 14)
        runtime.state.setGlobal("RESTORED_PLAYER", value: .nilValue)
        try runtime.execute("collectgarbage('collect')")
        XCTAssertTrue(
            try runtime.state.rawTablePairs(in: firstTable).isEmpty,
            "unregistered Entity kept its detached sidecar rooted"
        )
    }

    func testEntitySidecarDoesNotChangeGenericUserdataAssignment() throws {
        let runtime = GMLuaRuntime(realm: .server, logger: { _ in })
        defer { _ = runtime.close() }
        try runtime.execute(
            """
            local proxy = newproxy(true)
            local ok, message = pcall(function() proxy.field = 1 end)
            assert(not ok)
            assert(string.find(message, "attempt to index a userdata value", 1, true))
            """
        )
    }

    func testPlayerGlobalUsesUserIDWhileEntityAndNetRegistryUseEntityIndex() throws {
        let runtime = GMLuaRuntime(realm: .server, logger: { _ in })
        defer { _ = runtime.close() }
        let registry = try XCTUnwrap(runtime.entityRegistry)
        let first = try registry.registerPlayerMirror(
            index: 17,
            generation: 5,
            userID: 91,
            className: "player"
        )
        runtime.state.setGlobal("FIRST_PLAYER", value: first)
        try runtime.execute(
            """
            assert(Entity(17) == FIRST_PLAYER)
            assert(Player(91) == FIRST_PLAYER)
            assert(Player(17) == NULL)
            """
        )

        registry.unregisterPlayerMirror(index: 17, generation: 4)
        try runtime.execute("assert(Player(91) == FIRST_PLAYER and FIRST_PLAYER:IsValid())")
        registry.unregisterPlayerMirror(index: 17, generation: 5)
        try runtime.execute(
            """
            assert(Entity(17) == NULL and Player(91) == NULL)
            assert(FIRST_PLAYER == NULL and FIRST_PLAYER:EntIndex() == 0)
            """
        )

        let replacement = try registry.registerPlayerMirror(
            index: 17,
            generation: 6,
            userID: 92,
            className: "player"
        )
        runtime.state.setGlobal("REPLACEMENT_PLAYER", value: replacement)
        try runtime.execute(
            """
            assert(Player(91) == NULL)
            assert(Player(92) == REPLACEMENT_PLAYER)
            assert(Entity(17) == REPLACEMENT_PLAYER)
            assert(REPLACEMENT_PLAYER ~= FIRST_PLAYER)
            """
        )
        XCTAssertThrowsError(
            try registry.registerPlayerMirror(
                index: 18,
                generation: 7,
                userID: 92,
                className: "player"
            )
        )
        try runtime.execute("assert(Player(92) == REPLACEMENT_PLAYER and Entity(18) == NULL)")
    }
}
