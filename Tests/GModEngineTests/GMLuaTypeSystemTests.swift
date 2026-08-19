import Foundation
import XCTest
import GModEngine
import GModLua

final class GMLuaTypeSystemTests: XCTestCase {
    func testCoreLua51TypeRemainsUnchangedWithoutInstaller() throws {
        let state = LuaState(output: { _ in })
        try state.execute(
            """
            assert(type(nil) == "nil")
            assert(type({ MetaName = "Vector", MetaID = 10 }) == "table")
            assert(type(newproxy()) == "userdata")
            assert(TypeID == nil)
            assert(FindMetaTable == nil)
            assert(RegisterMetaTable == nil)
            assert(TYPE_VECTOR == nil)
            assert(NULL == nil)
            """
        )
    }

    func testGLuaTypeABIRegressionCorpus() throws {
        let fixtureURL = try XCTUnwrap(
            Bundle.module.url(
                forResource: "GLuaTypeSystemRegression",
                withExtension: "lua",
                subdirectory: "Fixtures"
            ) ?? Bundle.module.url(
                forResource: "GLuaTypeSystemRegression",
                withExtension: "lua"
            )
        )
        let source = try String(contentsOf: fixtureURL, encoding: .utf8)
        let state = LuaState(output: { _ in })
        let typeSystem = try GMLuaTypeSystem.install(
            into: state,
            utilityLayer: .bundledFallback
        )
        // Reinstalling the native standalone layer remains idempotent.
        try typeSystem.installFallbackUtilities()

        let vector = try typeSystem.makeObject(metaName: "Vector")
        let angle = try typeSystem.makeObject(metaName: "Angle")
        let entity = try typeSystem.makeObject(metaName: "Entity")
        let player = try typeSystem.makeObject(metaName: "Player")
        let weapon = try typeSystem.makeObject(metaName: "Weapon")
        let panel = try typeSystem.makeObject(metaName: "Panel")
        let invalidEntity = try typeSystem.makeObject(metaName: "Entity", isValid: false)

        state.setGlobal("TEST_VECTOR", value: vector)
        state.setGlobal("TEST_ANGLE", value: angle)
        state.setGlobal("TEST_ENTITY", value: entity)
        state.setGlobal("TEST_PLAYER", value: player)
        state.setGlobal("TEST_WEAPON", value: weapon)
        state.setGlobal("TEST_PANEL", value: panel)
        state.setGlobal("TEST_INVALID_ENTITY", value: invalidEntity)

        try state.execute(source, sourceName: "@GLuaTypeSystemRegression.lua")

        let custom = try typeSystem.makeObject(metaName: "CustomABI")
        state.setGlobal("TEST_CUSTOM", value: custom)
        try state.execute(
            """
            assert(type(TEST_CUSTOM) == "CustomABI")
            assert(TypeID(TEST_CUSTOM) == TYPE_COUNT)
            """
        )

        let nativeEntity = try XCTUnwrap(GMLuaTypeSystem.typedObject(from: entity))
        XCTAssertEqual(nativeEntity.metaName, "Entity")
        XCTAssertEqual(nativeEntity.typeID, GMLuaTypeID.entity)
        nativeEntity.isValid = false
        try state.execute("assert(not IsValid(TEST_ENTITY))")

        XCTAssertThrowsError(try typeSystem.makeObject(metaName: "ForgedUnknownType"))
    }

    func testSyntheticCoreTypeCapturePreservesOfficialLoadOrderingContract() throws {
        let fixtureURL = try XCTUnwrap(
            Bundle.module.url(
                forResource: "GLuaSyntheticTypeCapture",
                withExtension: "lua",
                subdirectory: "Fixtures"
            ) ?? Bundle.module.url(
                forResource: "GLuaSyntheticTypeCapture",
                withExtension: "lua"
            )
        )
        let syntheticCapture = try String(contentsOf: fixtureURL, encoding: .utf8)

        // Production ordering: native ABI first, then a Lua utility layer that
        // captures the untouched core type. The fixture is original synthetic
        // code and contains no Facepunch/GMod implementation.
        let nativeState = LuaState(output: { _ in })
        let nativeTypes = try GMLuaTypeSystem.install(into: nativeState)
        let nativePlayer = try nativeTypes.makeObject(metaName: "Player")
        nativeState.setGlobal("TEST_PLAYER", value: nativePlayer)
        try nativeState.execute(
            """
            assert(type(TEST_PLAYER) == "userdata")
            assert(TypeID == nil and isentity == nil)
            """
        )
        try nativeState.execute(syntheticCapture, sourceName: "@SyntheticTypeCapture.lua")
        try nativeState.execute(
            """
            local name, base = SyntheticCapturedUserdataDescriptor(TEST_PLAYER)
            assert(name == "Player" and base == "Entity")
            """
        )
        try nativeTypes.installFallbackUtilities()
        try nativeState.execute(
            """
            assert(type(TEST_PLAYER) == "Player")
            assert(TypeID(TEST_PLAYER) == TYPE_ENTITY)
            assert(isentity(TEST_PLAYER) and IsEntity(TEST_PLAYER))
            """
        )

        // A standalone-to-production transition must remove its fallback
        // wrapper before any ordering-sensitive capture happens.
        let transitionState = LuaState(output: { _ in })
        let transitionTypes = try GMLuaTypeSystem.install(
            into: transitionState,
            utilityLayer: .bundledFallback
        )
        let transitionPlayer = try transitionTypes.makeObject(metaName: "Player")
        transitionState.setGlobal("TEST_PLAYER", value: transitionPlayer)
        try transitionState.execute(
            """
            assert(type(TEST_PLAYER) == "Player")
            assert(isentity(TEST_PLAYER))
            """
        )
        transitionTypes.prepareForOfficialUtilityLoad()
        try transitionState.execute(
            """
            assert(type(TEST_PLAYER) == "userdata")
            assert(TypeID == nil and isentity == nil)
            """
        )
        try transitionState.execute(syntheticCapture, sourceName: "@SyntheticTypeCapture.lua")
        try transitionState.execute(
            """
            local name, base = SyntheticCapturedUserdataDescriptor(TEST_PLAYER)
            assert(name == "Player" and base == "Entity")
            """
        )
        try transitionTypes.installFallbackUtilities()
        try transitionState.execute(
            """
            assert(type(TEST_PLAYER) == "Player")
            assert(TypeID(TEST_PLAYER) == TYPE_ENTITY)
            assert(isentity(TEST_PLAYER) and IsEntity(TEST_PLAYER))
            assert(IsValid(TEST_PLAYER))
            """
        )
    }
}
