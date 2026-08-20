import Foundation
import XCTest
import GModEngine
import GModGameAssets
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

    func testGetTableMergedAccessorSurvivesCollectionDuringScriptedControlInit() throws {
        let state = LuaState(output: { _ in })
        let typeSystem = try GMLuaTypeSystem.install(
            into: state,
            utilityLayer: .bundledFallback
        )
        let registry = try GMLuaVGUI.install(into: state, typeSystem: typeSystem)

        try state.execute(
            """
            -- Original synthetic reproduction of GMod's scripted-panel shape:
            -- preserve the engine factory, merge a control table into GetTable,
            -- then run Init before Prepare.
            local engineCreate = vgui.Create
            local controls = {}

            local function addAccessor(target, field, suffix)
                target["Get" .. suffix] = function(self) return self[field] end
                target["Set" .. suffix] = function(self, value) self[field] = value end
            end

            local function register(name, control, base)
                control.Base = base or "Panel"
                control.Init = control.Init or function() end
                controls[name] = control
                return control
            end

            local function create(name, parent, instanceName)
                local control = controls[name]
                if control then
                    local panel = assert(create(control.Base, parent, instanceName or name))
                    for key, value in pairs(control) do
                        panel:GetTable()[key] = value
                    end
                    panel.BaseClass = controls[control.Base]
                    panel.ClassName = name
                    if panel.Init then panel:Init() end
                    panel:Prepare()
                    return panel
                end
                return engineCreate(name, parent, instanceName or name)
            end

            vgui.Register = register
            vgui.Create = create

            local SCROLL = {}
            addAccessor(SCROLL, "hiddenButtons", "HideButtons")
            function SCROLL:Init()
                -- Child construction can trigger an automatic collection in the
                -- real bootstrap. A forced collection makes the root contract
                -- deterministic without copying any installed control source.
                collectgarbage("collect")
                assert(type(self.SetHideButtons) == "function")
                self:SetHideButtons(false)
            end
            register("SyntheticScrollBar", SCROLL, "Panel")

            SYNTHETIC_SCROLL = assert(vgui.Create("SyntheticScrollBar"))
            assert(SYNTHETIC_SCROLL:GetHideButtons() == false)
            assert(SYNTHETIC_SCROLL:GetTable().SetHideButtons == SCROLL.SetHideButtons)
            """,
            sourceName: "@GMLuaScriptedControlAccessorGCRegression.lua"
        )

        XCTAssertEqual(registry.livePanelCount, 1)
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

    func testDButtonCursorStateUsesOfficialNamesAndInvalidFallbackInHostSnapshot() throws {
        let state = LuaState(output: { _ in })
        let typeSystem = try GMLuaTypeSystem.install(
            into: state,
            utilityLayer: .bundledFallback
        )
        let registry = try GMLuaVGUI.install(into: state, typeSystem: typeSystem)
        try state.execute(
            """
            local BUTTON = {}
            function BUTTON:Init()
                self:SetCursor("hand")
            end
            vgui.Register("SyntheticDButton", BUTTON, "Panel")

            BUTTON_PANEL = assert(vgui.Create("SyntheticDButton"))
            BUTTON_PANEL:SetSize(100, 20)

            FALLBACK_PANEL = assert(vgui.Create("Panel"))
            FALLBACK_PANEL:SetPos(0, 30)
            FALLBACK_PANEL:SetSize(100, 20)
            FALLBACK_PANEL:SetCursor("unsupported-cursor")

            BLANK_PANEL = assert(vgui.Create("Panel"))
            BLANK_PANEL:SetPos(0, 60)
            BLANK_PANEL:SetSize(100, 20)
            BLANK_PANEL:SetCursor("blank")

            local ok = pcall(FALLBACK_PANEL.SetCursor, FALLBACK_PANEL, nil)
            assert(ok == false)
            """,
            sourceName: "@GMLuaDButtonCursorRegression.lua"
        )

        let tree = registry.renderTree(viewportWidth: 200, viewportHeight: 100)
        let button = try XCTUnwrap(
            tree.first(where: { $0.requestedClassName == "SyntheticDButton" })
        )
        XCTAssertEqual(button.cursorName, "hand")
        XCTAssertEqual(
            tree.first(where: { $0.identifier != button.identifier && $0.frame.y == 30 })?.cursorName,
            "none"
        )
        XCTAssertEqual(tree.first(where: { $0.frame.y == 60 })?.cursorName, "blank")
    }

    func testDrawOnTopUsesLastCallPriorityAndFalseReturnsPanelToNormalOrder() throws {
        let state = LuaState(output: { _ in })
        let typeSystem = try GMLuaTypeSystem.install(
            into: state,
            utilityLayer: .bundledFallback
        )
        let registry = try GMLuaVGUI.install(into: state, typeSystem: typeSystem)
        try state.execute(
            """
            vgui.Register("NormalPanel", {}, "Panel")
            local FIRST_TOP = {}
            function FIRST_TOP:OnMousePressed() POINTER_HIT = "first" end
            vgui.Register("FirstTopPanel", FIRST_TOP, "Panel")
            local SECOND_TOP = {}
            function SECOND_TOP:OnMousePressed() POINTER_HIT = "second" end
            vgui.Register("SecondTopPanel", SECOND_TOP, "Panel")

            NORMAL_PANEL = assert(vgui.Create("NormalPanel"))
            FIRST_TOP_PANEL = assert(vgui.Create("FirstTopPanel"))
            SECOND_TOP_PANEL = assert(vgui.Create("SecondTopPanel"))
            NORMAL_PANEL:SetSize(100, 100)
            FIRST_TOP_PANEL:SetSize(100, 100)
            SECOND_TOP_PANEL:SetSize(100, 100)

            FIRST_TOP_PANEL:SetDrawOnTop(true)
            SECOND_TOP_PANEL:SetDrawOnTop(true)
            FIRST_TOP_PANEL:SetDrawOnTop(true)
            """,
            sourceName: "@GMLuaDrawOnTopRegression.lua"
        )

        var tree = registry.renderTree(viewportWidth: 100, viewportHeight: 100)
        XCTAssertEqual(
            tree.map(\.requestedClassName),
            ["NormalPanel", "SecondTopPanel", "FirstTopPanel"]
        )
        XCTAssertFalse(tree[0].drawOnTop)
        XCTAssertNil(tree[0].drawOnTopOrder)
        XCTAssertTrue(tree[1].drawOnTop)
        let secondTopOrder = try XCTUnwrap(tree[1].drawOnTopOrder)
        let firstTopOrder = try XCTUnwrap(tree[2].drawOnTopOrder)
        XCTAssertLessThan(secondTopOrder, firstTopOrder)
        let pointer = try registry.dispatchPointerEvent(
            x: 10,
            y: 10,
            phase: .began,
            timestamp: 1,
            viewportWidth: 100,
            viewportHeight: 100
        )
        XCTAssertEqual(pointer.callbackNames, ["OnMousePressed"])
        try state.execute(
            "assert(POINTER_HIT == 'second')",
            sourceName: "@GMLuaDrawOnTopInputOrderRegression.lua"
        )

        try state.execute(
            "FIRST_TOP_PANEL:SetDrawOnTop(false)",
            sourceName: "@GMLuaDrawOnTopReleaseRegression.lua"
        )
        tree = registry.renderTree(viewportWidth: 100, viewportHeight: 100)
        XCTAssertEqual(
            tree.map(\.requestedClassName),
            ["NormalPanel", "FirstTopPanel", "SecondTopPanel"]
        )
        XCTAssertFalse(tree[1].drawOnTop)

        try state.execute(
            "SECOND_TOP_PANEL:SetDrawOnTop()",
            sourceName: "@GMLuaDrawOnTopDefaultFalseRegression.lua"
        )
        tree = registry.renderTree(viewportWidth: 100, viewportHeight: 100)
        XCTAssertEqual(
            tree.map(\.requestedClassName),
            ["NormalPanel", "FirstTopPanel", "SecondTopPanel"]
        )
        XCTAssertTrue(tree.allSatisfy { !$0.drawOnTop && $0.drawOnTopOrder == nil })
    }

    func testMoveToStackEdgesReordersTopLevelAndSiblingDocking() throws {
        let state = LuaState(output: { _ in })
        let typeSystem = try GMLuaTypeSystem.install(
            into: state,
            utilityLayer: .bundledFallback
        )
        let registry = try GMLuaVGUI.install(into: state, typeSystem: typeSystem)
        try state.execute(
            """
            vgui.Register("TopFirst", {}, "Panel")
            vgui.Register("TopSecond", {}, "Panel")
            vgui.Register("TopThird", {}, "Panel")
            vgui.Register("DockFirst", {}, "Panel")
            vgui.Register("DockSecond", {}, "Panel")
            vgui.Register("DockThird", {}, "Panel")

            TOP_FIRST = vgui.Create("TopFirst")
            TOP_SECOND = vgui.Create("TopSecond")
            TOP_THIRD = vgui.Create("TopThird")
            for _, panel in ipairs({ TOP_FIRST, TOP_SECOND, TOP_THIRD }) do
                panel:SetSize(100, 100)
            end
            TOP_SECOND:MoveToBack()
            TOP_FIRST:MoveToFront()

            DOCK_ROOT = vgui.Create("Panel")
            DOCK_ROOT:SetPos(120, 0)
            DOCK_ROOT:SetSize(100, 100)
            DOCK_FIRST = vgui.Create("DockFirst", DOCK_ROOT)
            DOCK_SECOND = vgui.Create("DockSecond", DOCK_ROOT)
            DOCK_THIRD = vgui.Create("DockThird", DOCK_ROOT)
            for _, panel in ipairs({ DOCK_FIRST, DOCK_SECOND, DOCK_THIRD }) do
                panel:SetTall(10)
                panel:Dock(TOP)
            end
            DOCK_THIRD:MoveToBack()
            """,
            sourceName: "@GMLuaMoveToStackEdgesRegression.lua"
        )

        var tree = registry.renderTree(viewportWidth: 220, viewportHeight: 100)
        XCTAssertEqual(
            tree.filter { $0.parentIdentifier == nil && $0.frame.x == 0 }
                .map(\.requestedClassName),
            ["TopSecond", "TopThird", "TopFirst"]
        )
        let docked = tree.filter { $0.parentIdentifier != nil }
        XCTAssertEqual(
            docked.map(\.requestedClassName),
            ["DockThird", "DockFirst", "DockSecond"]
        )
        XCTAssertEqual(docked.map(\.frame.y), [0, 10, 20])

        try state.execute(
            "DOCK_THIRD:MoveToFront()",
            sourceName: "@GMLuaMoveDockedPanelToFrontRegression.lua"
        )
        tree = registry.renderTree(viewportWidth: 220, viewportHeight: 100)
        let movedDocked = tree.filter { $0.parentIdentifier != nil }
        XCTAssertEqual(
            movedDocked.map(\.requestedClassName),
            ["DockFirst", "DockSecond", "DockThird"]
        )
        XCTAssertEqual(movedDocked.map(\.frame.y), [0, 10, 20])
    }

    func testPopupTierStaysAheadOfNonPopupAcrossStackMovesAndHitTesting() throws {
        let state = LuaState(output: { _ in })
        let typeSystem = try GMLuaTypeSystem.install(
            into: state,
            utilityLayer: .bundledFallback
        )
        let registry = try GMLuaVGUI.install(into: state, typeSystem: typeSystem)
        try state.execute(
            """
            local function control()
                return {
                    OnMousePressed = function(self) POPUP_HIT = self:GetName() end
                }
            end
            vgui.Register("StackNormalFirst", control(), "Panel")
            vgui.Register("StackNormalSecond", control(), "Panel")
            vgui.Register("StackPopupFirst", control(), "EditablePanel")
            vgui.Register("StackPopupSecond", control(), "EditablePanel")

            NORMAL_FIRST = vgui.Create("StackNormalFirst", nil, "normal-first")
            POPUP_FIRST = vgui.Create("StackPopupFirst", nil, "popup-first")
            NORMAL_SECOND = vgui.Create("StackNormalSecond", nil, "normal-second")
            POPUP_SECOND = vgui.Create("StackPopupSecond", nil, "popup-second")
            for _, panel in ipairs({
                NORMAL_FIRST, POPUP_FIRST, NORMAL_SECOND, POPUP_SECOND
            }) do
                panel:SetSize(100, 100)
            end
            POPUP_FIRST:SetMouseInputEnabled(false)
            POPUP_FIRST:SetKeyboardInputEnabled(false)
            POPUP_FIRST:MakePopup()
            POPUP_SECOND:MakePopup()
            assert(POPUP_FIRST:IsPopup() and POPUP_SECOND:IsPopup())
            assert(POPUP_FIRST:IsMouseInputEnabled())
            assert(POPUP_FIRST:IsKeyboardInputEnabled())
            assert(not NORMAL_FIRST:IsPopup())

            POPUP_FIRST:MoveToBack()
            NORMAL_SECOND:MoveToFront()
            """,
            sourceName: "@GMLuaPopupTierRegression.lua"
        )

        var tree = registry.renderTree(viewportWidth: 100, viewportHeight: 100)
        XCTAssertEqual(
            tree.map(\.requestedClassName),
            ["StackNormalFirst", "StackNormalSecond", "StackPopupFirst", "StackPopupSecond"]
        )
        XCTAssertEqual(tree.map(\.isPopup), [false, false, true, true])
        _ = try registry.dispatchPointerEvent(
            x: 10, y: 10, phase: .began, timestamp: 1,
            viewportWidth: 100, viewportHeight: 100
        )
        try state.execute(
            "assert(POPUP_HIT == 'popup-second')",
            sourceName: "@GMLuaPopupTierBackHitRegression.lua"
        )

        try state.execute(
            "POPUP_FIRST:MoveToFront()",
            sourceName: "@GMLuaPopupTierFrontRegression.lua"
        )
        tree = registry.renderTree(viewportWidth: 100, viewportHeight: 100)
        XCTAssertEqual(
            tree.map(\.requestedClassName),
            ["StackNormalFirst", "StackNormalSecond", "StackPopupSecond", "StackPopupFirst"]
        )
        _ = try registry.dispatchPointerEvent(
            x: 10, y: 10, phase: .began, timestamp: 2,
            viewportWidth: 100, viewportHeight: 100
        )
        try state.execute(
            "assert(POPUP_HIT == 'popup-first')",
            sourceName: "@GMLuaPopupTierFrontHitRegression.lua"
        )
    }

    func testLabelInsetsAndNoWrapContentSizeUseSharedNamedSurfaceMeasurement() throws {
        struct LabelOracleMeasurer: GMLuaTextMeasurer {
            let fidelity = GMLuaTextMeasurementFidelity.platformGlyphMetrics

            func measure(
                _ text: LuaString,
                using font: GMLuaFontDescriptor
            ) -> GMLuaTextMeasurement {
                let value = String(decoding: text.bytes, as: UTF8.self)
                switch (font.name.utf8String, value) {
                case ("Oracle", "ABC"):
                    return GMLuaTextMeasurement(width: 20, height: 13)
                case ("Oracle", ""):
                    return GMLuaTextMeasurement(width: 0, height: 13)
                case ("Oracle", "ABC\nDEF"):
                    return GMLuaTextMeasurement(width: 24, height: 26)
                case ("Default", "fallback"):
                    return GMLuaTextMeasurement(width: 41, height: 13)
                default:
                    return GMLuaTextMeasurement(width: 900, height: 900)
                }
            }
        }

        let state = LuaState(output: { _ in })
        let typeSystem = try GMLuaTypeSystem.install(
            into: state,
            utilityLayer: .bundledFallback
        )
        let surface = try GMLuaSurface.install(
            into: state,
            textMeasurer: LabelOracleMeasurer()
        )
        _ = try GMLuaVGUI.install(
            into: state,
            typeSystem: typeSystem,
            surfaceCommandState: surface
        )

        try state.execute(
            """
            surface.CreateFont("Oracle", { size = 31 })
            surface.SetFont("Trebuchet24")

            LABEL = assert(vgui.Create("Label"))
            LABEL:SetFontInternal("oRaClE")
            LABEL:SetText("ABC")
            local w, h = LABEL:GetContentSize()
            assert(w == 20 and h == 13)

            LABEL:SetTextInset("7", "3", "ignored extra argument")
            local ix, iy = LABEL:GetTextInset()
            assert(ix == 7 and iy == 3)
            w, h = LABEL:GetContentSize()
            assert(w == 27 and h == 13)

            LABEL:SetText("")
            w, h = LABEL:GetContentSize()
            assert(w == 7 and h == 13)

            LABEL:SetText("ABC\\nDEF")
            w, h = LABEL:GetContentSize()
            assert(w == 31 and h == 26)

            -- Label.cpp takes max(current TextImage height + insetY,
            -- full content height). The DLabel bootstrap has a zero-height
            -- current TextImage, matching the authenticated Windows oracle.
            LABEL:SetTextInset(0, 14)
            w, h = LABEL:GetContentSize()
            assert(w == 24 and h == 26)
            LABEL:SetTextInset(0, 100)
            w, h = LABEL:GetContentSize()
            assert(w == 24 and h == 100)
            LABEL:SetTextInset(0, -3)
            w, h = LABEL:GetContentSize()
            assert(w == 24 and h == 26)

            LABEL:SetText("ABC")
            LABEL:SetTextInset(0, 3)
            w, h = LABEL:GetContentSize()
            assert(w == 20 and h == 13)
            LABEL:SetTextInset(0, 14)
            w, h = LABEL:GetContentSize()
            assert(w == 20 and h == 14)
            LABEL:SetTextInset(0, 100)
            w, h = LABEL:GetContentSize()
            assert(w == 20 and h == 100)
            LABEL:SetTextInset(0, -3)
            w, h = LABEL:GetContentSize()
            assert(w == 20 and h == 13)

            LABEL:SetText("")
            LABEL:SetTextInset(0, 14)
            w, h = LABEL:GetContentSize()
            assert(w == 0 and h == 14)
            LABEL:SetTextInset(0, 100)
            w, h = LABEL:GetContentSize()
            assert(w == 0 and h == 100)
            LABEL:SetTextInset(0, -3)
            w, h = LABEL:GetContentSize()
            assert(w == 0 and h == 13)

            LABEL:SetText("ABC")
            LABEL:SetTextInset(-10, 0)
            w, h = LABEL:GetContentSize()
            assert(w == 10 and h == 13)
            LABEL:SetTextInset(1000, 0)
            w, h = LABEL:GetContentSize()
            assert(w == 1020 and h == 13)
            LABEL:SetTextInset(7.9, 3.9)
            ix, iy = LABEL:GetTextInset()
            assert(ix == 7 and iy == 3)
            LABEL:SetTextInset(-7.9, -3.9)
            ix, iy = LABEL:GetTextInset()
            assert(ix == -7 and iy == -3)
            LABEL:SetTextInset("7.9", "3.9")
            ix, iy = LABEL:GetTextInset()
            assert(ix == 7 and iy == 3)

            local missingY = pcall(LABEL.SetTextInset, LABEL, 19)
            assert(missingY == false)
            ix, iy = LABEL:GetTextInset()
            assert(ix == 7 and iy == 3)

            local panel = assert(vgui.Create("Panel"))
            assert(pcall(panel.GetContentSize, panel) == false)
            assert(type(LABEL.SetWrap) == "nil")

            LABEL:SetFontInternal("FontThatDoesNotExist")
            LABEL:SetText("fallback")
            w, h = LABEL:GetContentSize()
            assert(w == 48 and h == 13)
            """,
            sourceName: "@GMLuaLabelContentSizeOracle.lua"
        )

        XCTAssertEqual(surface.selectedFontName, LuaString("Trebuchet24"))
        XCTAssertEqual(surface.textMeasurementFidelity, .platformGlyphMetrics)
    }

    func testSyntheticDButtonSizeToContentsXUsesLabelContentWidthFormula() throws {
        struct ButtonOracleMeasurer: GMLuaTextMeasurer {
            let fidelity = GMLuaTextMeasurementFidelity.platformGlyphMetrics

            func measure(
                _ text: LuaString,
                using font: GMLuaFontDescriptor
            ) -> GMLuaTextMeasurement {
                XCTAssertEqual(font.name, LuaString("Default"))
                XCTAssertEqual(text, LuaString("ABC"))
                return GMLuaTextMeasurement(width: 20, height: 13)
            }
        }

        let state = LuaState(output: { _ in })
        let typeSystem = try GMLuaTypeSystem.install(
            into: state,
            utilityLayer: .bundledFallback
        )
        let surface = try GMLuaSurface.install(
            into: state,
            textMeasurer: ButtonOracleMeasurer()
        )
        _ = try GMLuaVGUI.install(
            into: state,
            typeSystem: typeSystem,
            surfaceCommandState: surface
        )
        try state.execute(
            """
            local BUTTON = {}
            function BUTTON:SizeToContentsX(addVal)
                local w, h = self:GetContentSize()
                self:SetWide(w + 8 + (addVal or 0))
            end
            vgui.Register("SyntheticDButtonSize", BUTTON, "Label")

            local button = assert(vgui.Create("SyntheticDButtonSize"))
            button:SetText("ABC")
            button:SetTextInset(7, 3)
            button:SizeToContentsX(16)
            assert(button:GetWide() == 51)
            """,
            sourceName: "@GMLuaDButtonSizeToContentsXRegression.lua"
        )
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

    func testTopLevelDockingUsesImplicitWorldPanelAndVisibilityAlphaRules() throws {
        let state = LuaState(output: { _ in })
        let typeSystem = try GMLuaTypeSystem.install(
            into: state,
            utilityLayer: .bundledFallback
        )
        let registry = try GMLuaVGUI.install(into: state, typeSystem: typeSystem)
        try state.execute(
            """
            ROOT_TOP = vgui.Create("Panel")
            ROOT_TOP:SetTall(20)
            ROOT_TOP:Dock(TOP)
            ROOT_TOP:SetZPos(1)

            ROOT_HIDDEN_TOP = vgui.Create("Panel")
            ROOT_HIDDEN_TOP:SetTall(40)
            ROOT_HIDDEN_TOP:Dock(TOP)
            ROOT_HIDDEN_TOP:SetZPos(2)
            ROOT_HIDDEN_TOP:SetVisible(false)

            ROOT_TRANSPARENT_BOTTOM = vgui.Create("Panel")
            ROOT_TRANSPARENT_BOTTOM:SetTall(30)
            ROOT_TRANSPARENT_BOTTOM:Dock(BOTTOM)
            ROOT_TRANSPARENT_BOTTOM:SetZPos(3)
            ROOT_TRANSPARENT_BOTTOM:SetAlpha(0)

            ROOT_ABSOLUTE = vgui.Create("Panel")
            ROOT_ABSOLUTE:SetPos(7, 8)
            ROOT_ABSOLUTE:SetSize(11, 12)
            ROOT_ABSOLUTE:SetZPos(4)
            assert(ROOT_ABSOLUTE:GetDock() == NODOCK)

            ROOT_FILL = vgui.Create("EditablePanel")
            ROOT_FILL:Dock(FILL)
            ROOT_FILL:SetZPos(5)
            ROOT_FILL:MakePopup()
            """,
            sourceName: "@GMLuaTopLevelWorldPanelDockRegression.lua"
        )

        let tree = registry.renderTree(viewportWidth: 300, viewportHeight: 200)
        XCTAssertEqual(tree.count, 3)
        let top = try XCTUnwrap(tree.first(where: {
            !$0.isPopup && $0.frame.height == 20 && $0.frame.width == 300
        }))
        XCTAssertEqual(top.frame, GMLuaPanelRect(x: 0, y: 0, width: 300, height: 20))
        let absolute = try XCTUnwrap(tree.first(where: { $0.frame.width == 11 }))
        XCTAssertEqual(absolute.frame, GMLuaPanelRect(x: 7, y: 8, width: 11, height: 12))
        let fill = try XCTUnwrap(tree.first(where: { $0.isPopup }))
        XCTAssertEqual(fill.frame, GMLuaPanelRect(x: 0, y: 20, width: 300, height: 150))
        XCTAssertEqual(tree.last?.identifier, fill.identifier)
        // The hidden TOP root consumes no space. The alpha-zero BOTTOM root
        // consumes 30 pixels but is omitted from the renderer-facing tree.
        XCTAssertFalse(tree.contains(where: { $0.alpha == 0 }))
    }

    func testRenderFrameDocksRootBeforeLuaLayoutAndReappliesAfterLayout() throws {
        let state = LuaState(output: { _ in })
        let typeSystem = try GMLuaTypeSystem.install(
            into: state,
            utilityLayer: .bundledFallback
        )
        let surface = try GMLuaSurface.install(into: state)
        let registry = try GMLuaVGUI.install(
            into: state,
            typeSystem: typeSystem,
            surfaceCommandState: surface
        )
        try state.execute(
            """
            local PROBE = {}
            function PROBE:Init()
                self.Child = vgui.Create("Panel", self)
            end
            function PROBE:PerformLayout(width, height)
                ROOT_LAYOUT_CALLS = (ROOT_LAYOUT_CALLS or 0) + 1
                ROOT_LAYOUT_WIDTH = self:GetWide()
                ROOT_LAYOUT_HEIGHT = self:GetTall()
                ROOT_LAYOUT_ARGUMENT_WIDTH = width
                ROOT_LAYOUT_ARGUMENT_HEIGHT = height
                self.Child:SetTall(25)
                self.Child:Dock(BOTTOM)
            end
            vgui.Register("RootDockLayoutProbe", PROBE, "Panel")

            ROOT_LAYOUT = vgui.Create("RootDockLayoutProbe")
            ROOT_LAYOUT:Dock(FILL)
            ROOT_LAYOUT:InvalidateLayout()
            """,
            sourceName: "@GMLuaRootDockBeforeLayoutRegression.lua"
        )
        XCTAssertEqual(registry.pendingLayoutCount, 1)

        _ = try registry.renderFrame(
            surface: surface,
            viewportWidth: 320,
            viewportHeight: 180
        )
        try state.execute(
            """
            assert(ROOT_LAYOUT_CALLS == 1)
            assert(ROOT_LAYOUT_WIDTH == 320 and ROOT_LAYOUT_HEIGHT == 180)
            assert(ROOT_LAYOUT_ARGUMENT_WIDTH == 320 and ROOT_LAYOUT_ARGUMENT_HEIGHT == 180)
            """,
            sourceName: "@GMLuaRootDockLayoutObservedViewport.lua"
        )

        let tree = registry.renderTree(viewportWidth: 320, viewportHeight: 180)
        let root = try XCTUnwrap(tree.first(where: {
            $0.requestedClassName == "RootDockLayoutProbe"
        }))
        XCTAssertEqual(root.frame, GMLuaPanelRect(x: 0, y: 0, width: 320, height: 180))
        let child = try XCTUnwrap(tree.first(where: {
            $0.parentIdentifier == root.identifier
        }))
        XCTAssertEqual(child.frame, GMLuaPanelRect(x: 0, y: 155, width: 320, height: 25))
    }

    func testSizeToChildrenUsesDirectChildLowerRightBoundsAndBooleanDefaults() throws {
        let state = LuaState(output: { _ in })
        let typeSystem = try GMLuaTypeSystem.install(
            into: state,
            utilityLayer: .bundledFallback
        )
        _ = try GMLuaVGUI.install(into: state, typeSystem: typeSystem)
        try state.execute(
            """
            local parent = vgui.Create("Panel")
            parent:SetSize(320, 240)

            local first = vgui.Create("Panel", parent)
            first:SetPos(10, 20)
            first:SetSize(30, 40)

            local farthest = vgui.Create("Panel", parent)
            farthest:SetPos(70, 15)
            farthest:SetSize(50, 100)

            -- Only direct children define the parent extent.
            local grandchild = vgui.Create("Panel", first)
            grandchild:SetPos(500, 600)
            grandchild:SetSize(20, 30)

            local childWide, childTall = parent:ChildrenSize()
            assert(childWide == 120 and childTall == 115)

            -- Both flags default to false, so the documented no-argument call
            -- is a no-op.
            parent:SizeToChildren()
            assert(parent:GetWide() == 320 and parent:GetTall() == 240)

            parent:SizeToChildren(false, true)
            assert(parent:GetWide() == 320 and parent:GetTall() == 115)

            parent:SetSize(320, 240)
            parent:SizeToChildren(true, false)
            assert(parent:GetWide() == 120 and parent:GetTall() == 240)

            parent:SetSize(320, 240)
            parent:SizeToChildren(true, true)
            assert(parent:GetWide() == 120 and parent:GetTall() == 115)

            parent:SetSize(320, 240)
            parent:SizeToChildren(nil, true)
            assert(parent:GetWide() == 320 and parent:GetTall() == 115)

            local okWidth = pcall(parent.SizeToChildren, parent, 1, true)
            local okHeight = pcall(parent.SizeToChildren, parent, true, 1)
            assert(okWidth == false and okHeight == false)
            """,
            sourceName: "@GMLuaPanelSizeToChildrenRegression.lua"
        )
    }

    func testStockShapedContextMenuExposesWorldClickerWithoutSynthesizingWorldInput() throws {
        let state = LuaState(output: { _ in })
        let typeSystem = try GMLuaTypeSystem.install(
            into: state,
            utilityLayer: .bundledFallback
        )
        let registry = try GMLuaVGUI.install(into: state, typeSystem: typeSystem)
        try state.execute(
            """
            -- Exact pointer-relevant shape of Sandbox ContextMenu:Init. The
            -- stock control sets this on its EditablePanel before adding UI.
            local CONTEXT = {}
            function CONTEXT:Init()
                self:SetWorldClicker(true)
            end
            vgui.Register("StockShapedContextMenu", CONTEXT, "EditablePanel")

            CONTEXT_PANEL = vgui.Create("StockShapedContextMenu")
            CONTEXT_PANEL:SetSize(200, 100)
            CONTEXT_CHILD = vgui.Create("Panel", CONTEXT_PANEL)
            CONTEXT_CHILD:SetSize(200, 100)

            ORDINARY_PANEL = vgui.Create("Panel")
            ORDINARY_PANEL:SetPos(300, 0)
            ORDINARY_PANEL:SetSize(200, 100)

            assert(CONTEXT_PANEL:IsWorldClicker())
            assert(not CONTEXT_CHILD:IsWorldClicker())
            assert(not ORDINARY_PANEL:IsWorldClicker())
            assert(pcall(ORDINARY_PANEL.SetWorldClicker, ORDINARY_PANEL, 1) == false)
            """,
            sourceName: "@GMLuaStockShapedContextMenuWorldClicker.lua"
        )

        let tree = registry.renderTree(viewportWidth: 810, viewportHeight: 1_080)
        let contextSnapshot = try XCTUnwrap(tree.first(where: {
            $0.requestedClassName == "StockShapedContextMenu"
        }))
        XCTAssertTrue(contextSnapshot.worldClicker)
        XCTAssertFalse(try XCTUnwrap(tree.first(where: {
            $0.parentIdentifier == contextSnapshot.identifier
        })).worldClicker)
        XCTAssertFalse(try XCTUnwrap(tree.first(where: {
            $0.requestedClassName == "Panel" && $0.frame.x == 300
        })).worldClicker)

        let contextHit = try registry.dispatchPointerEvent(
            x: 50, y: 50, phase: .began, timestamp: 1,
            viewportWidth: 810, viewportHeight: 1_080
        )
        XCTAssertNotNil(contextHit.hitPanelIdentifier)
        XCTAssertNotEqual(contextHit.hitPanelIdentifier, contextSnapshot.identifier)
        // Pointer pass-through is effective across the hit panel's ancestor
        // chain, while each render snapshot and IsWorldClicker stays raw.
        XCTAssertTrue(contextHit.worldClicker)
        XCTAssertFalse(contextHit.clicked)

        let ordinaryHit = try registry.dispatchPointerEvent(
            x: 350, y: 50, phase: .began, timestamp: 2,
            viewportWidth: 810, viewportHeight: 1_080
        )
        XCTAssertNotNil(ordinaryHit.hitPanelIdentifier)
        XCTAssertFalse(ordinaryHit.worldClicker)
        XCTAssertFalse(ordinaryHit.clicked)

        let worldOnly = try registry.dispatchPointerEvent(
            x: 700, y: 900, phase: .began, timestamp: 3,
            viewportWidth: 810, viewportHeight: 1_080
        )
        XCTAssertNil(worldOnly.hitPanelIdentifier)
        XCTAssertFalse(worldOnly.worldClicker)
        XCTAssertFalse(worldOnly.clicked)
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
            ENTRY:SetAllowNonAsciiCharacters(true)
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

    func testBundledStockDButtonOwnsClickDecisionAcrossCaptureHoverAndCancellation() throws {
        let fileSystem = try GMLuaHostDirectoryFileSystem(
            rootURL: GModGameAssets.clientContentRootURL(),
            writable: false
        )
        let sharedSession = GMLuaSharedSession()
        let server = GMLuaRuntime(
            realm: .server,
            logger: { _ in },
            bootstrapMode: .strict,
            netTransport: sharedSession.netTransport
        )
        let runtime = GMLuaRuntime(
            realm: .client,
            logger: { _ in },
            virtualFileSystem: fileSystem,
            bootstrapMode: .strict,
            initialViewport: GMLuaViewportSize(width: 810, height: 1_080),
            netTransport: sharedSession.netTransport
        )
        try sharedSession.connect(server: server, client: runtime)
        defer {
            try? sharedSession.disconnect(client: runtime)
            _ = runtime.close()
            _ = server.close()
        }
        try runtime.loadFile("lua/includes/init.lua")
        try runtime.loadFile("lua/derma/init.lua")
        try runtime.loadFile("lua/vgui/dlabel.lua")
        try runtime.loadFile("lua/vgui/dbutton.lua")

        let registry = try XCTUnwrap(runtime.vguiRegistry)
        try runtime.execute(
            """
            -- Both methods below must come from the bundled panel extensions;
            -- the host deliberately does not synthesize DragMousePress/Release.
            local panelMeta = FindMetaTable("Panel")
            assert(type(panelMeta.DragMousePress) == "function")
            assert(type(panelMeta.DragMouseRelease) == "function")
            assert(IsValid(LocalPlayer()) and LocalPlayer():IsPlayer())

            -- Skin rendering is outside this pointer test. Keep the exact
            -- bundled DLabel pointer methods while preventing its unrelated
            -- scheme hook from requiring an Apple image-backed material.
            DLabel.ApplySchemeSettings = function() end

            local native = vgui.Create("Panel")
            assert(native:IsEnabled())
            native:SetEnabled(false)
            assert(not native:IsEnabled())
            native:SetEnabled(true)
            assert(native:IsEnabled())

            ROOT = vgui.Create("Panel")
            ROOT:SetSize(810, 1080)
            STOCK_BUTTON = vgui.Create("DButton", ROOT)
            STOCK_BUTTON:SetPos(100, 200)
            STOCK_BUTTON:SetSize(240, 80)
            STOCK_BUTTON:SetDoubleClickingEnabled(false)
            STOCK_BUTTON.DoClick = function(self)
                STOCK_CLICK_COUNT = (STOCK_CLICK_COUNT or 0) + 1
            end
            STOCK_BUTTON.OnCursorMoved = function(self, x, y)
                STOCK_CAPTURED_MOVE_COUNT = (STOCK_CAPTURED_MOVE_COUNT or 0) + 1
            end
            """,
            sourceName: "@GMLuaBundledStockDButtonPointerSetup.lua"
        )
        let buttonIdentifier = try XCTUnwrap(
            registry.renderTree(viewportWidth: 810, viewportHeight: 1_080)
                .first(where: { $0.requestedClassName == "DButton" })?
                .identifier
        )

        // A complete inside tap is decided by the bundled DLabel release path,
        // so the host reports only raw callbacks and DoClick runs exactly once.
        let insideBegan = try registry.dispatchPointerEvent(
            x: 120, y: 220, phase: .began, timestamp: 1,
            viewportWidth: 810, viewportHeight: 1_080
        )
        XCTAssertEqual(insideBegan.callbackNames, ["OnCursorEntered", "OnMousePressed"])
        try runtime.execute(
            "assert(STOCK_BUTTON.Hovered and STOCK_BUTTON.Depressed)",
            sourceName: "@GMLuaBundledStockDButtonInsidePress.lua"
        )
        let insideEnded = try registry.dispatchPointerEvent(
            x: 120, y: 220, phase: .ended, timestamp: 1.1,
            viewportWidth: 810, viewportHeight: 1_080
        )
        XCTAssertEqual(insideEnded.callbackNames, ["OnMouseReleased"])
        XCTAssertFalse(insideEnded.clicked)
        try runtime.execute(
            "assert(STOCK_CLICK_COUNT == 1 and not STOCK_BUTTON.Depressed)",
            sourceName: "@GMLuaBundledStockDButtonInsideRelease.lua"
        )

        // DLabel captured on press: movement continues to reach it outside,
        // while hit-based Hovered is already false and the outside release is
        // therefore not a click. Its MouseCapture(false) clears host capture.
        _ = try registry.dispatchPointerEvent(
            x: 120, y: 220, phase: .began, timestamp: 2,
            viewportWidth: 810, viewportHeight: 1_080
        )
        let capturedMove = try registry.dispatchPointerEvent(
            x: 700, y: 900, phase: .moved, timestamp: 2.1,
            viewportWidth: 810, viewportHeight: 1_080
        )
        XCTAssertNotNil(capturedMove.hitPanelIdentifier)
        XCTAssertNotEqual(capturedMove.hitPanelIdentifier, buttonIdentifier)
        XCTAssertTrue(capturedMove.callbackNames.contains("OnCursorExited"))
        XCTAssertTrue(capturedMove.callbackNames.contains("OnCursorMoved"))
        _ = try registry.dispatchPointerEvent(
            x: 700, y: 900, phase: .ended, timestamp: 2.2,
            viewportWidth: 810, viewportHeight: 1_080
        )
        let moveAfterRelease = try registry.dispatchPointerEvent(
            x: 700, y: 900, phase: .moved, timestamp: 2.3,
            viewportWidth: 810, viewportHeight: 1_080
        )
        XCTAssertFalse(moveAfterRelease.callbackNames.contains("OnCursorMoved"))
        try runtime.execute(
            """
            assert(STOCK_CLICK_COUNT == 1)
            assert(STOCK_CAPTURED_MOVE_COUNT == 1)
            assert(not STOCK_BUTTON.Hovered and not STOCK_BUTTON.Depressed)
            """,
            sourceName: "@GMLuaBundledStockDButtonOutsideRelease.lua"
        )

        // Cancellation releases capture before the stock callback and forces
        // Hovered false, even when the cancellation coordinate is still inside.
        _ = try registry.dispatchPointerEvent(
            x: 120, y: 220, phase: .began, timestamp: 3,
            viewportWidth: 810, viewportHeight: 1_080
        )
        _ = try registry.dispatchPointerEvent(
            x: 120, y: 220, phase: .cancelled, timestamp: 3.1,
            viewportWidth: 810, viewportHeight: 1_080
        )
        _ = try registry.dispatchPointerEvent(
            x: 700, y: 900, phase: .moved, timestamp: 3.2,
            viewportWidth: 810, viewportHeight: 1_080
        )
        try runtime.execute(
            """
            assert(STOCK_CLICK_COUNT == 1)
            assert(STOCK_CAPTURED_MOVE_COUNT == 1)
            assert(not STOCK_BUTTON.Hovered and not STOCK_BUTTON.Depressed)
            """,
            sourceName: "@GMLuaBundledStockDButtonCancellation.lua"
        )

        // The bundled DLabel refuses the press before depressing or capturing
        // a disabled DButton, so it cannot click on release.
        try runtime.execute(
            "STOCK_BUTTON:SetEnabled(false)",
            sourceName: "@GMLuaBundledStockDButtonDisable.lua"
        )
        _ = try registry.dispatchPointerEvent(
            x: 120, y: 220, phase: .began, timestamp: 4,
            viewportWidth: 810, viewportHeight: 1_080
        )
        _ = try registry.dispatchPointerEvent(
            x: 120, y: 220, phase: .ended, timestamp: 4.1,
            viewportWidth: 810, viewportHeight: 1_080
        )
        try runtime.execute(
            "assert(STOCK_CLICK_COUNT == 1 and not STOCK_BUTTON.Depressed)",
            sourceName: "@GMLuaBundledStockDButtonDisabledRelease.lua"
        )
    }

    func testTextEntryNonASCIIStateMatchesStockInitializationAndHostInputPolicy() throws {
        let state = LuaState(output: { _ in })
        let typeSystem = try GMLuaTypeSystem.install(
            into: state,
            utilityLayer: .bundledFallback
        )
        let registry = try GMLuaVGUI.install(into: state, typeSystem: typeSystem)
        try state.execute(
            """
            -- Source-shaped minimum of the original DTextEntry:Init path.
            local DTextEntry = {}
            function DTextEntry:Init()
                self:SetAllowNonAsciiCharacters(true)
            end
            vgui.Register("StockShapedDTextEntry", DTextEntry, "TextEntry")

            RESTRICTED_ENTRY = vgui.Create("TextEntry")
            STOCK_SHAPED_ENTRY = vgui.Create("StockShapedDTextEntry")
            function RESTRICTED_ENTRY:OnTextChanged()
                RESTRICTED_CHANGES = (RESTRICTED_CHANGES or 0) + 1
            end
            function STOCK_SHAPED_ENTRY:OnTextChanged()
                STOCK_SHAPED_CHANGES = (STOCK_SHAPED_CHANGES or 0) + 1
            end

            local panel = vgui.Create("Panel")
            local okPanel = pcall(
                panel.SetAllowNonAsciiCharacters,
                panel,
                true
            )
            local okType = pcall(
                RESTRICTED_ENTRY.SetAllowNonAsciiCharacters,
                RESTRICTED_ENTRY,
                1
            )
            assert(okPanel == false and okType == false)
            """,
            sourceName: "@GMLuaDTextEntryNonASCIIInitialization.lua"
        )

        let initialSnapshots = registry.textPanelStateSnapshots
        XCTAssertFalse(try XCTUnwrap(initialSnapshots.first(where: {
            $0.requestedClassName == "TextEntry"
        })).allowsNonASCIICharacters)
        XCTAssertTrue(try XCTUnwrap(initialSnapshots.first(where: {
            $0.requestedClassName == "StockShapedDTextEntry"
        })).allowsNonASCIICharacters)

        try state.execute(
            "RESTRICTED_ENTRY:RequestFocus()",
            sourceName: "@GMLuaRestrictedTextEntryFocus.lua"
        )
        // This mixed-batch split is the explicit host insertText policy. The
        // public GMod API does not specify native mixed-paste aggregation.
        XCTAssertNotNil(try registry.insertText("AテBéC"))
        XCTAssertNotNil(try registry.insertText("日本"))
        try state.execute(
            """
            assert(RESTRICTED_ENTRY:GetValue() == "ABC")
            assert(RESTRICTED_CHANGES == 1)
            RESTRICTED_ENTRY:SetAllowNonAsciiCharacters(true)
            """,
            sourceName: "@GMLuaRestrictedTextEntryCheckpoint.lua"
        )
        XCTAssertNotNil(try registry.insertText("日本"))

        try state.execute(
            "STOCK_SHAPED_ENTRY:RequestFocus()",
            sourceName: "@GMLuaStockShapedTextEntryFocus.lua"
        )
        XCTAssertNotNil(try registry.insertText("テスト"))
        try state.execute(
            """
            assert(RESTRICTED_ENTRY:GetValue() == "ABC日本")
            assert(RESTRICTED_CHANGES == 2)
            assert(STOCK_SHAPED_ENTRY:GetValue() == "テスト")
            assert(STOCK_SHAPED_CHANGES == 1)
            """,
            sourceName: "@GMLuaDTextEntryNonASCIICheckpoint.lua"
        )
    }

    func testExpensiveShadowStoresLabelStateAndEmitsShadowBeforeMainText() throws {
        let state = LuaState(output: { _ in })
        let typeSystem = try GMLuaTypeSystem.install(
            into: state,
            utilityLayer: .bundledFallback
        )
        let surface = try GMLuaSurface.install(into: state)
        let registry = try GMLuaVGUI.install(
            into: state,
            typeSystem: typeSystem,
            surfaceCommandState: surface
        )
        try state.execute(
            """
            -- Minimal source-shaped Color value and DCategoryHeader shadow path.
            function Color(r, g, b, a)
                return { r = r, g = g, b = b, a = a }
            end

            ROOT = vgui.Create("Panel")
            ROOT:SetSize(200, 100)
            ROOT:SetAlpha(128)

            HEADER = vgui.Create("Label", ROOT)
            HEADER:SetSize(120, 30)
            HEADER:SetAlpha(128)
            HEADER:SetText("Sandbox")
            HEADER:SetFGColor(220, 230, 240, 200)

            local supplied = Color(10, 20, 30, 100)
            HEADER:SetExpensiveShadow(2, supplied)
            supplied.r, supplied.g, supplied.b, supplied.a = 1, 2, 3, 4

            local plain = vgui.Create("Panel")
            assert(pcall(plain.SetExpensiveShadow, plain, 1, Color(0, 0, 0, 100)) == false)
            assert(pcall(HEADER.SetExpensiveShadow, HEADER, 1, 0, 0, 0, 100) == false)
            """,
            sourceName: "@GMLuaLabelExpensiveShadowRegression.lua"
        )

        let stateSnapshot = try XCTUnwrap(registry.textPanelStateSnapshots.first(where: {
            $0.requestedClassName == "Label" && $0.text == LuaString("Sandbox")
        }))
        XCTAssertEqual(stateSnapshot.expensiveShadow, GMLuaTextShadowSnapshot(
            distance: 2,
            color: GMLuaPanelColorSnapshot(red: 10, green: 20, blue: 30, alpha: 100)
        ))

        let activeFrame = try registry.renderFrame(
            surface: surface,
            viewportWidth: 200,
            viewportHeight: 100
        )
        XCTAssertEqual(activeFrame.commands.count, 2)
        guard case let .text(shadowText, shadowPosition, shadowFont, shadowColor, shadowClip) =
                activeFrame.commands[0],
              case let .text(mainText, mainPosition, mainFont, mainColor, mainClip) =
                activeFrame.commands[1] else {
            return XCTFail("Label shadow and main text commands were not emitted in order")
        }
        XCTAssertEqual(shadowText, mainText)
        XCTAssertEqual(shadowFont, mainFont)
        XCTAssertEqual(shadowPosition.x, mainPosition.x + 2)
        XCTAssertEqual(shadowPosition.y, mainPosition.y + 2)
        XCTAssertEqual(shadowColor.red, 10)
        XCTAssertEqual(shadowColor.green, 20)
        XCTAssertEqual(shadowColor.blue, 30)
        let cumulativeAlpha = 128.0 * 128.0 / 255.0
        XCTAssertEqual(shadowColor.alpha, 100.0 * cumulativeAlpha / 255.0, accuracy: 0.000_001)
        XCTAssertEqual(mainColor.alpha, 200.0 * cumulativeAlpha / 255.0, accuracy: 0.000_001)
        XCTAssertEqual(shadowClip, mainClip)

        try state.execute(
            "HEADER:SetExpensiveShadow(0, Color(40, 50, 60, 70))",
            sourceName: "@GMLuaLabelExpensiveShadowDisabled.lua"
        )
        let disabledState = try XCTUnwrap(registry.textPanelStateSnapshots.first(where: {
            $0.text == LuaString("Sandbox")
        })?.expensiveShadow)
        XCTAssertEqual(disabledState.distance, 0)
        XCTAssertEqual(disabledState.color, GMLuaPanelColorSnapshot(
            red: 40,
            green: 50,
            blue: 60,
            alpha: 70
        ))
        let disabledFrame = try registry.renderFrame(
            surface: surface,
            viewportWidth: 200,
            viewportHeight: 100
        )
        XCTAssertEqual(disabledFrame.commands.count, 1)
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
