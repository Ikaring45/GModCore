import Foundation
import XCTest
import GModEngine
import GModLua

final class GMLuaDermaRegistryTests: XCTestCase {
    func testControlReloadSkinDispatchAndConVarHelpers() throws {
        let state = LuaState(output: { _ in })
        let typeSystem = try GMLuaTypeSystem.install(
            into: state,
            utilityLayer: .bundledFallback
        )
        let vgui = try GMLuaVGUI.install(into: state, typeSystem: typeSystem)
        let derma = try GMLuaDerma.install(into: state, vguiRegistry: vgui)
        let fixtureURL = try XCTUnwrap(
            Bundle.module.url(
                forResource: "GLuaDermaRegistryRegression",
                withExtension: "lua",
                subdirectory: "Fixtures"
            ) ?? Bundle.module.url(
                forResource: "GLuaDermaRegistryRegression",
                withExtension: "lua"
            )
        )

        try state.execute(
            String(contentsOf: fixtureURL, encoding: .utf8),
            sourceName: "@GLuaDermaRegistryRegression.lua"
        )

        XCTAssertEqual(derma.registeredControlCount, 3)
        XCTAssertEqual(derma.registeredSkinCount, 2)
        XCTAssertFalse(derma.hasPlatformViewBacking)
        guard case .boolean(true) = state.getGlobal("GLUA_DERMA_REGISTRY_REGRESSION_OK") else {
            return XCTFail("Derma fixture did not reach its success sentinel")
        }
    }

    func testDermaRegistriesAreStateLocal() throws {
        func makeState() throws -> (LuaState, GMLuaDermaRegistry) {
            let state = LuaState(output: { _ in })
            let typeSystem = try GMLuaTypeSystem.install(
                into: state,
                utilityLayer: .bundledFallback
            )
            let vgui = try GMLuaVGUI.install(into: state, typeSystem: typeSystem)
            return (state, try GMLuaDerma.install(into: state, vguiRegistry: vgui))
        }
        let (first, firstRegistry) = try makeState()
        let (second, secondRegistry) = try makeState()
        try first.execute("derma.DefineControl('OnlyFirst', '', {}, 'Panel')")

        XCTAssertEqual(firstRegistry.registeredControlCount, 1)
        XCTAssertEqual(secondRegistry.registeredControlCount, 0)
        try second.execute("assert(derma.GetControlList().OnlyFirst == nil)")
    }

    func testRuntimeInstallsDermaOnlyInClientCapableRealms() throws {
        for realm in [GMLuaRealm.client, .menu] {
            let runtime = GMLuaRuntime(
                realm: realm,
                logger: { _ in },
                bootstrapMode: .strict
            )
            try runtime.execute(
                """
                assert(type(derma) == "table")
                assert(type(derma.DefineControl) == "function")
                assert(type(Derma_Hook) == "function")
                assert(type(Derma_Install_Convar_Functions) == "function")
                """,
                sourceName: "@GMLuaDermaRealmBootstrap.lua"
            )
            XCTAssertNotNil(runtime.dermaRegistry)
        }

        let server = GMLuaRuntime(
            realm: .server,
            logger: { _ in },
            bootstrapMode: .strict
        )
        try server.execute("assert(derma == nil and Derma_Hook == nil)")
        XCTAssertNil(server.dermaRegistry)
    }
}
