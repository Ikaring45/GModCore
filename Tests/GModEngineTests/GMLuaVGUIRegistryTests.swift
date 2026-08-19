import Foundation
import XCTest
import GModEngine
import GModLua

final class GMLuaVGUIRegistryTests: XCTestCase {
    func testDockConstantsMatchGModABI() throws {
        XCTAssertEqual(GMLuaPanelDock.none.rawValue, 0)
        XCTAssertEqual(GMLuaPanelDock.fill.rawValue, 1)
        XCTAssertEqual(GMLuaPanelDock.left.rawValue, 2)
        XCTAssertEqual(GMLuaPanelDock.right.rawValue, 3)
        XCTAssertEqual(GMLuaPanelDock.top.rawValue, 4)
        XCTAssertEqual(GMLuaPanelDock.bottom.rawValue, 5)

        let state = LuaState(output: { _ in })
        let typeSystem = try GMLuaTypeSystem.install(
            into: state,
            utilityLayer: .bundledFallback
        )
        _ = try GMLuaVGUI.install(into: state, typeSystem: typeSystem)
        try state.execute(
            "assert(NODOCK == 0 and FILL == 1 and LEFT == 2 and " +
                "RIGHT == 3 and TOP == 4 and BOTTOM == 5)",
            sourceName: "@GMLuaDockABIRegression.lua"
        )
    }

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

    func testRenderTreeAppliesDockingClippingZOrderAndTextStateAtIPadViewport() throws {
        let state = LuaState(output: { _ in })
        let typeSystem = try GMLuaTypeSystem.install(
            into: state,
            utilityLayer: .bundledFallback
        )
        let registry = try GMLuaVGUI.install(into: state, typeSystem: typeSystem)
        try state.execute(
            """
            ROOT = vgui.Create("Panel")
            ROOT:SetSize(810, 1080)
            ROOT:DockPadding(20, 30, 40, 50)

            HEADER = vgui.Create("Label", ROOT)
            HEADER:SetTall(64)
            HEADER:Dock(TOP)
            HEADER:DockMargin(5, 6, 7, 8)
            HEADER:SetText("Sandbox")
            HEADER:SetFGColor(220, 230, 240, 255)
            HEADER:SetZPos(2)

            BODY = vgui.Create("Panel", ROOT)
            BODY:Dock(FILL)
            BODY:SetZPos(1)

            OVERFLOW = vgui.Create("Panel", BODY)
            OVERFLOW:SetPos(-10, -10)
            OVERFLOW:SetSize(900, 1200)
            """,
            sourceName: "@GMLuaPanelRenderTreeRegression.lua"
        )

        let tree = registry.renderTree(viewportWidth: 810, viewportHeight: 1080)
        XCTAssertEqual(tree.map(\.requestedClassName), ["Panel", "Panel", "Panel", "Label"])
        let header = try XCTUnwrap(tree.first(where: { $0.requestedClassName == "Label" }))
        XCTAssertEqual(header.frame, GMLuaPanelRect(x: 25, y: 36, width: 738, height: 64))
        XCTAssertEqual(header.text, LuaString("Sandbox"))
        XCTAssertEqual(header.foregroundColor?.red, 220)

        let body = try XCTUnwrap(tree.first(where: {
            $0.requestedClassName == "Panel" && $0.parentIdentifier == tree.first?.identifier
        }))
        // BODY has the lower ZPos, so it is docked first and fills the original
        // padded area before HEADER consumes space for later docked siblings.
        XCTAssertEqual(body.frame, GMLuaPanelRect(x: 20, y: 30, width: 750, height: 1000))
        let overflow = try XCTUnwrap(tree.first(where: { $0.parentIdentifier == body.identifier }))
        XCTAssertEqual(overflow.clipRect, body.clipRect)
        XCTAssertFalse(registry.hasPlatformViewBacking)
        registry.connectPlatformBridge(textBacking: true)
        XCTAssertTrue(registry.hasPlatformViewBacking)
        XCTAssertTrue(registry.hasPlatformTextBacking)
    }

    func testDockingUsesZPositionAndTransparentPanelsStillConsumeSpace() throws {
        let state = LuaState(output: { _ in })
        let typeSystem = try GMLuaTypeSystem.install(
            into: state,
            utilityLayer: .bundledFallback
        )
        let registry = try GMLuaVGUI.install(into: state, typeSystem: typeSystem)
        try state.execute(
            """
            ROOT = vgui.Create("Panel")
            ROOT:SetSize(100, 100)

            FILL_PANEL = vgui.Create("Panel", ROOT)
            FILL_PANEL:Dock(FILL)
            FILL_PANEL:SetZPos(2)

            TRANSPARENT_TOP = vgui.Create("Panel", ROOT)
            TRANSPARENT_TOP:SetTall(20)
            TRANSPARENT_TOP:Dock(TOP)
            TRANSPARENT_TOP:SetZPos(1)
            TRANSPARENT_TOP:SetAlpha(0)
            """,
            sourceName: "@GMLuaDockOrderingRegression.lua"
        )

        let tree = registry.renderTree(viewportWidth: 100, viewportHeight: 100)
        let fill = try XCTUnwrap(tree.first(where: {
            $0.requestedClassName == "Panel" && $0.parentIdentifier != nil
        }))
        XCTAssertEqual(fill.frame, GMLuaPanelRect(x: 0, y: 20, width: 100, height: 80))
        XCTAssertFalse(tree.contains(where: { $0.alpha == 0 }))
    }

    func testTouchDispatchRoutesRawCallbacksOnceAndTextEntryOnlySignalsTextChanged() throws {
        let state = LuaState(output: { _ in })
        let typeSystem = try GMLuaTypeSystem.install(
            into: state,
            utilityLayer: .bundledFallback
        )
        let registry = try GMLuaVGUI.install(into: state, typeSystem: typeSystem)
        try state.execute(
            """
            local BUTTON = {}
            function BUTTON:OnCursorEntered() ENTERED = (ENTERED or 0) + 1 end
            function BUTTON:OnMousePressed(code) PRESSED_CODE = code end
            function BUTTON:OnMouseReleased(code)
                RELEASED_CODE = code
                if code == MOUSE_LEFT then self:DoClick() end
            end
            function BUTTON:DoClick() CLICKED = (CLICKED or 0) + 1 end
            function BUTTON:DoDoubleClick() DOUBLE_CLICKED = (DOUBLE_CLICKED or 0) + 1 end
            vgui.Register("FixtureButton", BUTTON, "Label")

            ROOT = vgui.Create("Panel")
            ROOT:SetSize(810, 1080)
            BUTTON_PANEL = vgui.Create("FixtureButton", ROOT)
            BUTTON_PANEL:SetPos(100, 200)
            BUTTON_PANEL:SetSize(240, 80)

            ENTRY = vgui.Create("TextEntry", ROOT)
            ENTRY:SetPos(100, 320)
            ENTRY:SetSize(300, 50)
            function ENTRY:OnTextChanged() TEXT_CHANGED = (TEXT_CHANGED or 0) + 1 end
            function ENTRY:OnValueChange(value) VALUE_CHANGED = (VALUE_CHANGED or 0) + 1 end
            """,
            sourceName: "@GMLuaPanelInputRegression.lua"
        )

        let began = try registry.dispatchPointerEvent(
            x: 120, y: 220, phase: .began, timestamp: 1,
            viewportWidth: 810, viewportHeight: 1080
        )
        XCTAssertEqual(began.callbackNames, ["OnCursorEntered", "OnMousePressed"])
        let ended = try registry.dispatchPointerEvent(
            x: 120, y: 220, phase: .ended, timestamp: 1.1,
            viewportWidth: 810, viewportHeight: 1080
        )
        XCTAssertEqual(ended.callbackNames, ["OnMouseReleased"])
        XCTAssertFalse(ended.clicked)
        XCTAssertFalse(ended.doubleClicked)

        _ = try registry.dispatchPointerEvent(
            x: 120, y: 340, phase: .began, timestamp: 2,
            viewportWidth: 810, viewportHeight: 1080
        )
        XCTAssertNotNil(try registry.insertText("テスト"))
        try state.execute(
            """
            assert(ENTERED == 1)
            assert(PRESSED_CODE == MOUSE_LEFT and RELEASED_CODE == MOUSE_LEFT)
            assert(CLICKED == 1 and DOUBLE_CLICKED == nil)
            assert(TEXT_CHANGED == 1 and VALUE_CHANGED == nil)
            assert(ENTRY:GetValue() == "テスト")
            """,
            sourceName: "@GMLuaPanelInputCheckpoint.lua"
        )
    }

    func testRootCenterUsesCurrentRuntimeViewportAndDirectRegistryFailsExplicitly() throws {
        let runtime = GMLuaRuntime(
            realm: .client,
            logger: { _ in },
            bootstrapMode: .strict,
            initialViewport: GMLuaViewportSize(width: 800, height: 600)
        )
        try runtime.execute(
            """
            ROOT = vgui.Create("Panel")
            ROOT:SetSize(200, 100)
            ROOT:Center()
            local x, y = ROOT:GetPos()
            assert(x == 300 and y == 250)
            """,
            sourceName: "@GMLuaRootCenterInitialViewport.lua"
        )
        XCTAssertTrue(runtime.updateViewport(width: 1024, height: 768))
        try runtime.execute(
            """
            ROOT:Center()
            local x, y = ROOT:GetPos()
            assert(x == 412 and y == 334)
            """,
            sourceName: "@GMLuaRootCenterUpdatedViewport.lua"
        )

        let state = LuaState(output: { _ in })
        let typeSystem = try GMLuaTypeSystem.install(
            into: state,
            utilityLayer: .bundledFallback
        )
        _ = try GMLuaVGUI.install(into: state, typeSystem: typeSystem)
        try state.execute(
            """
            local panel = vgui.Create("Panel")
            panel:SetSize(20, 10)
            local ok, message = pcall(panel.Center, panel)
            assert(ok == false)
            assert(string.find(message, "attached live viewport", 1, true))
            """,
            sourceName: "@GMLuaRootCenterMissingViewport.lua"
        )
    }
}
