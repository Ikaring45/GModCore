import Foundation
import XCTest
import GModEngine
import GModLua

final class GMLuaVGUIRegistryTests: XCTestCase {
    func testLogicalEnginePanelStateSupportsScriptedDPanelBase() throws {
        let state = LuaState(output: { _ in })
        let typeSystem = try GMLuaTypeSystem.install(
            into: state,
            utilityLayer: .bundledFallback
        )
        let registry = try GMLuaVGUI.install(into: state, typeSystem: typeSystem)
        _ = try GMLuaDerma.install(into: state, vguiRegistry: registry)
        let fixtureURL = try XCTUnwrap(
            Bundle.module.url(
                forResource: "GLuaPanelEngineControlRegression",
                withExtension: "lua",
                subdirectory: "Fixtures"
            ) ?? Bundle.module.url(
                forResource: "GLuaPanelEngineControlRegression",
                withExtension: "lua"
            )
        )

        try state.execute(
            String(contentsOf: fixtureURL, encoding: .utf8),
            sourceName: "@GLuaPanelEngineControlRegression.lua"
        )

        XCTAssertEqual(registry.registeredControlCount, 1)
        XCTAssertEqual(registry.livePanelCount, 0)
        XCTAssertFalse(registry.hasPlatformViewBacking)
        guard case .boolean(true) = state.getGlobal("GLUA_PANEL_ENGINE_CONTROL_REGRESSION_OK") else {
            return XCTFail("logical engine Panel fixture did not reach its success sentinel")
        }
    }

    func testNativePanelIdentityRegistryAndScriptedControlInheritance() throws {
        let state = LuaState(output: { _ in })
        let typeSystem = try GMLuaTypeSystem.install(
            into: state,
            utilityLayer: .bundledFallback
        )
        let registry = try GMLuaVGUI.install(into: state, typeSystem: typeSystem)
        let fixtureURL = try XCTUnwrap(
            Bundle.module.url(
                forResource: "GLuaVGUIRegistryRegression",
                withExtension: "lua",
                subdirectory: "Fixtures"
            ) ?? Bundle.module.url(
                forResource: "GLuaVGUIRegistryRegression",
                withExtension: "lua"
            )
        )

        try state.execute(
            String(contentsOf: fixtureURL, encoding: .utf8),
            sourceName: "@GLuaVGUIRegistryRegression.lua"
        )

        XCTAssertEqual(registry.registeredControlCount, 2)
        XCTAssertEqual(registry.livePanelCount, 0)
        XCTAssertFalse(registry.hasPlatformViewBacking)
        guard case .boolean(true) = state.getGlobal("GLUA_VGUI_REGISTRY_REGRESSION_OK") else {
            return XCTFail("VGUI fixture did not reach its success sentinel")
        }
    }

    func testRegistriesAndPanelIdentityAreStateLocal() throws {
        func makeState() throws -> (LuaState, GMLuaVGUIRegistry) {
            let state = LuaState(output: { _ in })
            let typeSystem = try GMLuaTypeSystem.install(
                into: state,
                utilityLayer: .bundledFallback
            )
            return (state, try GMLuaVGUI.install(into: state, typeSystem: typeSystem))
        }
        let (first, firstRegistry) = try makeState()
        let (second, secondRegistry) = try makeState()
        try first.execute("FIRST = vgui.Create('Panel')")
        try second.execute("SECOND = vgui.Create('Panel')")

        guard case let .userdata(firstPanel) = first.getGlobal("FIRST"),
              case let .userdata(secondPanel) = second.getGlobal("SECOND") else {
            return XCTFail("vgui.Create did not return Panel userdata")
        }
        XCTAssertFalse(firstPanel === secondPanel)
        XCTAssertEqual(firstRegistry.livePanelCount, 1)
        XCTAssertEqual(secondRegistry.livePanelCount, 1)
    }

    func testRuntimeInstallsVGUIOnlyInClientCapableRealms() throws {
        for realm in [GMLuaRealm.client, .menu] {
            let runtime = GMLuaRuntime(
                realm: realm,
                logger: { _ in },
                bootstrapMode: .strict
            )
            try runtime.execute(
                """
                assert(type(vgui) == "table")
                local panel = vgui.Create("Panel")
                assert(type(panel) == "userdata")
                assert(getmetatable(panel).MetaName == "Panel")
                """,
                sourceName: "@GMLuaVGUIRealmBootstrap.lua"
            )
            XCTAssertNotNil(runtime.vguiRegistry)
        }

        let server = GMLuaRuntime(
            realm: .server,
            logger: { _ in },
            bootstrapMode: .strict
        )
        try server.execute("assert(vgui == nil)")
        XCTAssertNil(server.vguiRegistry)
    }
}
