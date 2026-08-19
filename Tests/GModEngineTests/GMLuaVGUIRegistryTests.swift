import Foundation
import XCTest
import GModEngine
import GModLua

final class GMLuaVGUIRegistryTests: XCTestCase {
    func testLogicalEngineLabelStateRunsRealSchemeAndPreservesLuaStringBytes() throws {
        let state = LuaState(output: { _ in })
        let typeSystem = try GMLuaTypeSystem.install(
            into: state,
            utilityLayer: .bundledFallback
        )
        let registry = try GMLuaVGUI.install(into: state, typeSystem: typeSystem)
        let fixtureURL = try XCTUnwrap(
            Bundle.module.url(
                forResource: "GLuaLabelEngineControlRegression",
                withExtension: "lua",
                subdirectory: "Fixtures"
            ) ?? Bundle.module.url(
                forResource: "GLuaLabelEngineControlRegression",
                withExtension: "lua"
            )
        )

        try state.execute(
            String(contentsOf: fixtureURL, encoding: .utf8),
            sourceName: "@GLuaLabelEngineControlRegression.lua"
        )

        guard case .boolean(true) = state.getGlobal(
            "GLUA_LABEL_ENGINE_CONTROL_REGRESSION_READY"
        ) else {
            return XCTFail("logical engine Label fixture did not reach its ready sentinel")
        }
        XCTAssertEqual(registry.pendingLayoutCount, 1)
        XCTAssertEqual(try registry.performPendingLayouts(), 1)

        let snapshots = registry.textPanelStateSnapshots
        XCTAssertEqual(snapshots.count, 3)
        let label = try XCTUnwrap(
            snapshots.first(where: { $0.requestedClassName == "FixtureLabel" })
        )
        XCTAssertEqual(label.engineClassName, "Label")
        XCTAssertEqual(label.fontName, LuaString("DermaDefault"))
        XCTAssertEqual(label.text.count, 1_023)
        XCTAssertEqual(label.foregroundColor, GMLuaPanelColorSnapshot(
            red: 12,
            green: 34,
            blue: 56,
            alpha: 78
        ))
        XCTAssertEqual(label.contentAlignment, 9)

        let textEntry = try XCTUnwrap(
            snapshots.first(where: { $0.engineClassName == "TextEntry" })
        )
        XCTAssertEqual(textEntry.text.count, 8_201)
        XCTAssertEqual(textEntry.text.bytes.last, 255)
        XCTAssertEqual(textEntry.fontName, LuaString("EntryFont"))

        XCTAssertFalse(registry.hasPlatformTextBacking)
        try state.execute(
            "assert(FIXTURE_LABEL.LayoutCalls == 1 and FIXTURE_LABEL.SchemeCalls == 2)",
            sourceName: "@GLuaLabelEngineControlLayoutCheckpoint.lua"
        )
    }

    func testLogicalLayoutInvalidationDefersOrDispatchesPerformLayoutExactly() throws {
        let state = LuaState(output: { _ in })
        let typeSystem = try GMLuaTypeSystem.install(
            into: state,
            utilityLayer: .bundledFallback
        )
        let registry = try GMLuaVGUI.install(into: state, typeSystem: typeSystem)
        let fixtureURL = try XCTUnwrap(
            Bundle.module.url(
                forResource: "GLuaPanelLayoutInvalidationRegression",
                withExtension: "lua",
                subdirectory: "Fixtures"
            ) ?? Bundle.module.url(
                forResource: "GLuaPanelLayoutInvalidationRegression",
                withExtension: "lua"
            )
        )

        try state.execute(
            String(contentsOf: fixtureURL, encoding: .utf8),
            sourceName: "@GLuaPanelLayoutInvalidationRegression.lua"
        )

        guard case .boolean(true) = state.getGlobal(
            "GLUA_PANEL_LAYOUT_INVALIDATION_FIXTURE_READY"
        ) else {
            return XCTFail("logical layout invalidation fixture did not reach its ready sentinel")
        }
        XCTAssertEqual(registry.pendingLayoutCount, 2)
        XCTAssertEqual(registry.completedLayoutPassCount, 2)

        XCTAssertEqual(try registry.performPendingLayouts(maxLayouts: 1), 1)
        XCTAssertEqual(registry.pendingLayoutCount, 1)
        try state.execute(
            """
            assert(DEFERRED_LAYOUT_PANEL.LayoutCalls == 1)
            assert(DEFERRED_LAYOUT_PANEL.LastLayoutWidth == 120)
            assert(DEFERRED_LAYOUT_PANEL.LastLayoutHeight == 40)
            assert(REQUEUED_LAYOUT_PANEL.LayoutCalls == 1)
            """,
            sourceName: "@GLuaPanelLayoutInvalidationDeferredCheckpoint.lua"
        )

        XCTAssertEqual(try registry.performPendingLayouts(), 1)
        XCTAssertEqual(registry.pendingLayoutCount, 0)
        XCTAssertEqual(registry.completedLayoutPassCount, 4)
        try state.execute(
            "assert(REQUEUED_LAYOUT_PANEL.LayoutCalls == 2)",
            sourceName: "@GLuaPanelLayoutInvalidationRequeueCheckpoint.lua"
        )
        XCTAssertEqual(try registry.performPendingLayouts(), 0)
        XCTAssertFalse(registry.hasPlatformViewBacking)
    }

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
