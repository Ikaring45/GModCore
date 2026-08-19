import Foundation
import XCTest
@testable import GModEngine
import GModLua

final class GMLuaEntityRegistryTests: XCTestCase {
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
            assert(type(ents) == "table" and type(player) == "table")
            assert(type(TEST_RUNTIME_PLAYER) == "userdata")
            assert(Entity(3) == TEST_RUNTIME_PLAYER)
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
            assert(TEST_RUNTIME_PLAYER:EntIndex() == -1)
            assert(Entity(3) == NULL)
            assert(#ents.GetAll() == 0 and #player.GetAll() == 0)
            """
        )
    }
}
