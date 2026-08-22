import Foundation
import XCTest
import GModEngine
import GModGameAssets
import GModLua

final class GMLuaVGUIRegistryTests: XCTestCase {
    func testStockDFrameBottomRightTouchResizeIsImmediateClampedAndReleasesCapture() throws {
        let fileSystem = try GMLuaHostDirectoryFileSystem(
            rootURL: GModGameAssets.clientContentRootURL(),
            writable: false
        )
        let runtime = GMLuaRuntime(
            realm: .client,
            logger: { _ in },
            virtualFileSystem: fileSystem,
            bootstrapMode: .strict,
            initialViewport: GMLuaViewportSize(width: 810, height: 1_080)
        )
        defer { _ = runtime.close() }
        try runtime.loadFile("lua/includes/init.lua")
        try runtime.loadFile("lua/derma/init.lua")
        try runtime.loadFile("lua/vgui/dlabel.lua")
        try runtime.loadFile("lua/vgui/dbutton.lua")
        try runtime.loadFile("lua/vgui/dframe.lua")

        let registry = try XCTUnwrap(runtime.vguiRegistry)
        let surface = try XCTUnwrap(runtime.surfaceCommandState)
        do {
            try runtime.execute(
                """
                DLabel.ApplySchemeSettings = function() end
                local DerivedTouchFrame = {}
                vgui.Register("DerivedTouchFrame", DerivedTouchFrame, "DFrame")
                FRAME = assert(vgui.Create("DerivedTouchFrame"))
                FRAME:SetPos(100, 100)
                FRAME:SetSize(200, 160)
                FRAME:SetSizable(true)
                assert(FRAME.m_bSizable == true)
                assert(vgui.GetControlTable("DerivedTouchFrame").Base == "DFrame")
                FRAME:SetMinWidth(150)
                FRAME:SetMinHeight(120)
                FRAME.Paint = function() return true end
                FRAME.btnClose.Paint = function() return true end
                FRAME.btnMaxim.Paint = function() return true end
                FRAME.btnMinim.Paint = function() return true end
                ORIGINAL_FRAME_RELEASE = FRAME.OnMouseReleased

                AFTER_BUTTON = assert(vgui.Create("DButton"))
                AFTER_BUTTON:SetPos(400, 100)
                AFTER_BUTTON:SetSize(100, 50)
                AFTER_BUTTON.Paint = function() return true end
                AFTER_BUTTON.DoClick = function()
                    AFTER_BUTTON_CLICKS = (AFTER_BUTTON_CLICKS or 0) + 1
                end
                """,
                sourceName: "@GMLuaStockDFrameTouchResizeSetup.lua"
            )
        } catch {
            return XCTFail(GMLuaRuntime.describe(error))
        }

        func dispatch(
            _ x: Double,
            _ y: Double,
            _ phase: GMLuaPointerPhase,
            _ timestamp: TimeInterval
        ) throws -> GMLuaPointerDispatchResult {
            try registry.dispatchPointerEvent(
                x: x,
                y: y,
                phase: phase,
                timestamp: timestamp,
                viewportWidth: 810,
                viewportHeight: 1_080
            )
        }

        // Thirty points from each edge is outside stock's visible 20px grip,
        // but inside the iPad-only transparent 44-point target. Moving only X
        // must change width in this same dispatch cycle without changing height.
        let extendedGrip = try dispatch(270, 230, .began, 1)
        XCTAssertEqual(
            registry.renderTree(viewportWidth: 810, viewportHeight: 1_080)
                .first(where: {
                    $0.requestedClassName == "DerivedTouchFrame"
                })?.identifier,
            extendedGrip.hitPanelIdentifier
        )
        _ = try dispatch(310, 230, .moved, 1.1)
        try runtime.execute(
            "assert(FRAME:GetWide() == 240 and FRAME:GetTall() == 160)",
            sourceName: "@GMLuaStockDFrameWidthResizeCheckpoint.lua"
        )
        _ = try dispatch(310, 230, .ended, 1.2)

        // The stock bottom-right corner changes both dimensions.
        _ = try dispatch(330, 250, .began, 2)
        _ = try dispatch(350, 280, .moved, 2.1)
        try runtime.execute(
            "assert(FRAME:GetWide() == 260 and FRAME:GetTall() == 190)",
            sourceName: "@GMLuaStockDFrameCornerResizeCheckpoint.lua"
        )
        _ = try dispatch(350, 280, .ended, 2.2)

        // The next renderer-neutral surface capture sees the new frame.
        _ = try registry.renderFrame(
            surface: surface,
            viewportWidth: 810,
            viewportHeight: 1_080
        )
        XCTAssertEqual(
            registry.renderTree(viewportWidth: 810, viewportHeight: 1_080)
                .first(where: {
                    $0.requestedClassName == "DerivedTouchFrame"
                })?.frame,
            GMLuaPanelRect(x: 100, y: 100, width: 260, height: 190)
        )

        // Stock min width/height clamp remains authoritative.
        _ = try dispatch(350, 280, .began, 3)
        _ = try dispatch(100, 100, .moved, 3.1)
        try runtime.execute(
            "assert(FRAME:GetWide() == 150 and FRAME:GetTall() == 120)",
            sourceName: "@GMLuaStockDFrameMinimumResizeCheckpoint.lua"
        )
        _ = try dispatch(100, 100, .ended, 3.2)

        // Screen lock caps the stock size at the live logical viewport.
        try runtime.execute("FRAME:SetScreenLock(true)")
        _ = try dispatch(240, 210, .began, 4)
        _ = try dispatch(2_000, 2_000, .moved, 4.1)
        try runtime.execute(
            "assert(FRAME:GetWide() == 710 and FRAME:GetTall() == 980)",
            sourceName: "@GMLuaStockDFrameScreenLockCheckpoint.lua"
        )
        _ = try dispatch(2_000, 2_000, .ended, 4.2)

        // Cancellation clears both Lua Sizing and native pointer capture.
        try runtime.execute(
            "FRAME:SetScreenLock(false); FRAME:SetSize(200, 160)"
        )
        _ = try dispatch(290, 250, .began, 5)
        _ = try dispatch(290, 250, .cancelled, 5.1)
        _ = try dispatch(500, 500, .moved, 5.2)
        try runtime.execute(
            "assert(FRAME.Sizing == nil); " +
                "assert(FRAME:GetWide() == 200 and FRAME:GetTall() == 160)",
            sourceName: "@GMLuaStockDFrameCancelledResizeCheckpoint.lua"
        )

        // Native capture and the stock Sizing field are lifecycle state, so a
        // throwing scripted release callback must not strand either one.
        try runtime.execute(
            """
            FRAME:SetSizable(true)
            FRAME.OnMouseReleased = function() error("release boom") end
            """
        )
        _ = try dispatch(290, 250, .began, 5.3)
        XCTAssertThrowsError(try dispatch(290, 250, .ended, 5.4))
        try runtime.execute(
            """
            assert(FRAME.Sizing == nil)
            FRAME.OnMouseReleased = ORIGINAL_FRAME_RELEASE
            """,
            sourceName: "@GMLuaStockDFrameThrowingReleaseCheckpoint.lua"
        )

        // A non-sizable frame is not intercepted by the widened touch zone.
        try runtime.execute("FRAME:SetSizable(false)")
        _ = try dispatch(270, 230, .began, 6)
        _ = try dispatch(320, 280, .moved, 6.1)
        _ = try dispatch(320, 280, .ended, 6.2)
        try runtime.execute(
            "assert(FRAME:GetWide() == 200 and FRAME:GetTall() == 160)",
            sourceName: "@GMLuaStockDFrameNonSizableCheckpoint.lua"
        )

        // Neither cancellation nor the no-op path may steal the next button tap.
        _ = try dispatch(420, 120, .began, 7)
        _ = try dispatch(420, 120, .ended, 7.1)
        try runtime.execute("assert(AFTER_BUTTON_CLICKS == 1)")
    }

    func testPointerCallbacksMutateLuaAndNextSurfaceCaptureInSameHostInputCycle() throws {
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
            EVENT_PANEL = assert(vgui.Create("Label"))
            EVENT_PANEL:SetSize(200, 80)
            EVENT_PANEL:SetText("idle")
            function EVENT_PANEL:OnMousePressed(code)
                assert(code == MOUSE_LEFT)
                EVENT_BEGAN = (EVENT_BEGAN or 0) + 1
                self:SetText("began")
                self:MouseCapture(true)
            end
            function EVENT_PANEL:OnCursorMoved(x, y)
                EVENT_MOVED = (EVENT_MOVED or 0) + 1
                EVENT_MOVE_X, EVENT_MOVE_Y = x, y
                self:SetText("moved")
            end
            function EVENT_PANEL:OnMouseReleased(code)
                assert(code == MOUSE_LEFT)
                EVENT_ENDED = (EVENT_ENDED or 0) + 1
                self:SetText("ended")
                self:MouseCapture(false)
            end
            function EVENT_PANEL:OnMouseWheeled(delta)
                EVENT_SCROLLED = (EVENT_SCROLLED or 0) + 1
                EVENT_SCROLL_DELTA = delta
                self:SetText("scrolled")
            end
            """,
            sourceName: "@GMLuaImmediatePointerCallbackSetup.lua"
        )

        func capturedText() throws -> LuaString {
            let frame = try registry.renderFrame(
                surface: surface,
                viewportWidth: 320,
                viewportHeight: 180
            )
            return try XCTUnwrap(frame.commands.compactMap { command in
                guard case let .text(value, _, _, _, _) = command else { return nil }
                return value
            }.first)
        }

        let began = try registry.dispatchPointerEvent(
            x: 10, y: 10, phase: .began, timestamp: 1,
            viewportWidth: 320, viewportHeight: 180
        )
        XCTAssertTrue(began.callbackNames.contains("OnMousePressed"))
        try state.execute("assert(EVENT_BEGAN == 1 and EVENT_PANEL:GetText() == 'began')")
        XCTAssertEqual(try capturedText(), LuaString("began"))

        let moved = try registry.dispatchPointerEvent(
            x: 25, y: 30, phase: .moved, timestamp: 1.1,
            viewportWidth: 320, viewportHeight: 180
        )
        XCTAssertTrue(moved.callbackNames.contains("OnCursorMoved"))
        try state.execute(
            "assert(EVENT_MOVED == 1 and EVENT_MOVE_X == 25 and EVENT_MOVE_Y == 30 " +
                "and EVENT_PANEL:GetText() == 'moved')"
        )
        XCTAssertEqual(try capturedText(), LuaString("moved"))

        let ended = try registry.dispatchPointerEvent(
            x: 25, y: 30, phase: .ended, timestamp: 1.2,
            viewportWidth: 320, viewportHeight: 180
        )
        XCTAssertTrue(ended.callbackNames.contains("OnMouseReleased"))
        try state.execute("assert(EVENT_ENDED == 1 and EVENT_PANEL:GetText() == 'ended')")
        XCTAssertEqual(try capturedText(), LuaString("ended"))

        let scrolled = try registry.dispatchPointerEvent(
            x: 25, y: 30, phase: .scroll(delta: -2), timestamp: 1.3,
            viewportWidth: 320, viewportHeight: 180
        )
        XCTAssertTrue(scrolled.callbackNames.contains("OnMouseWheeled"))
        try state.execute(
            "assert(EVENT_SCROLLED == 1 and EVENT_SCROLL_DELTA == -2 " +
                "and EVENT_PANEL:GetText() == 'scrolled')"
        )
        XCTAssertEqual(try capturedText(), LuaString("scrolled"))
    }

    func testSetFocusTopLevelRaisesOwningWindowWhenDescendantRequestsFocus() throws {
        let state = LuaState(output: { _ in })
        let typeSystem = try GMLuaTypeSystem.install(
            into: state,
            utilityLayer: .bundledFallback
        )
        let registry = try GMLuaVGUI.install(into: state, typeSystem: typeSystem)
        try state.execute(
            """
            BACK_WINDOW = assert(vgui.Create("Panel"))
            BACK_WINDOW:SetSize(200, 100)
            BACK_WINDOW:SetFocusTopLevel(true)
            BACK_CHILD = assert(vgui.Create("Panel", BACK_WINDOW))
            BACK_CHILD:SetSize(200, 100)

            FRONT_WINDOW = assert(vgui.Create("Panel"))
            FRONT_WINDOW:SetSize(200, 100)
            """,
            sourceName: "@GMLuaFocusTopLevelSetup.lua"
        )

        let initiallyCovered = try registry.dispatchPointerEvent(
            x: 20, y: 20, phase: .moved, timestamp: 1,
            viewportWidth: 320, viewportHeight: 180
        )
        let frontIdentifier = try XCTUnwrap(
            registry.renderTree(viewportWidth: 320, viewportHeight: 180)
                .first(where: { $0.parentIdentifier == nil && $0.identifier == initiallyCovered.hitPanelIdentifier })?
                .identifier
        )

        try state.execute(
            "BACK_CHILD:RequestFocus(); assert(vgui.GetKeyboardFocus() == BACK_CHILD)",
            sourceName: "@GMLuaFocusTopLevelRaise.lua"
        )
        let raisedHit = try registry.dispatchPointerEvent(
            x: 20, y: 20, phase: .moved, timestamp: 1.1,
            viewportWidth: 320, viewportHeight: 180
        )
        XCTAssertNotEqual(raisedHit.hitPanelIdentifier, frontIdentifier)
        let raisedSnapshot = try XCTUnwrap(
            registry.renderTree(viewportWidth: 320, viewportHeight: 180)
                .first(where: { $0.identifier == raisedHit.hitPanelIdentifier })
        )
        XCTAssertNotNil(raisedSnapshot.parentIdentifier)
    }

    func testPanelHasChildrenTracksLiveNativeChildIdentity() throws {
        let runtime = GMLuaRuntime(realm: .client, logger: { _ in })
        try runtime.execute(
            """
            local parent = assert(vgui.Create("Panel"))
            assert(parent:ChildCount() == 0 and not parent:HasChildren())
            local child = assert(vgui.Create("Panel", parent))
            assert(parent:ChildCount() == 1 and parent:HasChildren())
            child:Remove()
            assert(parent:ChildCount() == 0 and not parent:HasChildren())
            """,
            sourceName: "@GMLuaPanelHasChildrenRegression.lua"
        )
    }

    func testHTMLJavaScriptObjectAndCallbackRegistrationIsRetainedLogically() throws {
        let runtime = GMLuaRuntime(realm: .client, logger: { _ in })
        let registry = try XCTUnwrap(runtime.vguiRegistry)

        try runtime.execute(
            """
            local html = assert(vgui.Create("HTML"))
            html:NewObject("console")
            html:NewObject("console")
            html:NewObjectCallback("console", "log")
            html:NewObjectCallback("console", "log")

            local ordinary = assert(vgui.Create("Panel"))
            assert(not pcall(ordinary.NewObject, ordinary, "console"))
            assert(not pcall(html.NewObject, html, 12))
            assert(not pcall(html.NewObjectCallback, html, "console"))
            """,
            sourceName: "@GMLuaHTMLJavaScriptBridgeRegistrationRegression.lua"
        )

        let snapshot = try XCTUnwrap(registry.htmlPanelStateSnapshots.first)
        XCTAssertEqual(snapshot.javascriptObjects, [LuaString("console")])
        XCTAssertEqual(
            snapshot.javascriptCallbacks,
            [GMLuaHTMLJavaScriptCallbackSnapshot(
                objectName: LuaString("console"),
                callbackName: LuaString("log")
            )]
        )
    }

    func testGUIMouseCoordinatesTrackHitTestPointerAndCancelToHiddenCursorSentinel() throws {
        let state = LuaState(output: { _ in })
        let typeSystem = try GMLuaTypeSystem.install(
            into: state,
            utilityLayer: .bundledFallback
        )
        let registry = try GMLuaVGUI.install(into: state, typeSystem: typeSystem)

        try state.execute(
            """
            assert(gui.MouseX() == 0 and gui.MouseY() == 0)
            local panel = assert(vgui.Create("Panel"))
            panel:SetSize(100, 100)
            """,
            sourceName: "@GMLuaGUIMouseHiddenCursorSentinel.lua"
        )

        _ = try registry.dispatchPointerEvent(
            x: 41,
            y: 73,
            phase: .moved,
            timestamp: 1,
            viewportWidth: 320,
            viewportHeight: 180
        )
        try state.execute(
            "assert(gui.MouseX() == 41 and gui.MouseY() == 73)",
            sourceName: "@GMLuaGUIMouseMovedPointer.lua"
        )

        _ = try registry.dispatchPointerEvent(
            x: 44.5,
            y: 76.25,
            phase: .ended,
            timestamp: 2,
            viewportWidth: 320,
            viewportHeight: 180
        )
        try state.execute(
            "assert(gui.MouseX() == 44.5 and gui.MouseY() == 76.25)",
            sourceName: "@GMLuaGUIMouseReleasedPointer.lua"
        )

        _ = try registry.dispatchPointerEvent(
            x: 999,
            y: 999,
            phase: .cancelled,
            timestamp: 3,
            viewportWidth: 320,
            viewportHeight: 180
        )
        try state.execute(
            "assert(gui.MouseX() == 0 and gui.MouseY() == 0)",
            sourceName: "@GMLuaGUIMouseCancelledPointer.lua"
        )
    }

    func testRemoveUsesDeferredDeletionAndStockControlPanelRecreatesForMarkedAncestor() throws {
        let fileSystem = try GMLuaHostDirectoryFileSystem(
            rootURL: GModGameAssets.clientContentRootURL(),
            writable: false
        )
        let runtime = GMLuaRuntime(
            realm: .client,
            logger: { _ in },
            virtualFileSystem: fileSystem,
            bootstrapMode: .strict
        )
        defer { _ = runtime.close() }
        try runtime.loadFile("lua/includes/init.lua")
        let registry = try XCTUnwrap(runtime.vguiRegistry)

        try runtime.execute(
            """
            local CONTROL = {}
            vgui.Register("ControlPanel", CONTROL, "Panel")

            local name = "__deferred_remove_regression"
            local first = assert(controlpanel.Get(name))
            assert(IsValid(first))
            assert(not first:IsMarkedForDeletion())

            local wrapper = assert(vgui.Create("Panel"))
            assert(IsValid(wrapper))
            assert(not wrapper:IsMarkedForDeletion())
            first:SetParent(wrapper)
            assert(first:GetParent() == wrapper)

            wrapper:Remove()
            assert(not IsValid(wrapper))
            assert(wrapper:IsMarkedForDeletion())
            assert(IsValid(first))
            assert(not first:IsMarkedForDeletion())
            assert(first:GetParent() == wrapper)

            -- Panel:Remove is idempotent throughout the deferred interval.
            wrapper:Remove()

            -- This invokes the unmodified stock ShouldReCreate path, whose
            -- parent walk must see the retained, marked wrapper userdata.
            local replacement = assert(controlpanel.Get(name))
            assert(replacement != first)
            assert(IsValid(replacement))
            assert(IsValid(first))

            DEFERRED_REMOVE_WRAPPER = wrapper
            DEFERRED_REMOVE_CHILD = first
            DEFERRED_REMOVE_REPLACEMENT = replacement
            """,
            sourceName: "@GMLuaDeferredPanelRemoveBeforeFrame.lua"
        )
        XCTAssertEqual(registry.livePanelCount, 2)

        _ = try registry.performPendingLayouts()
        try runtime.execute(
            """
            assert(not IsValid(DEFERRED_REMOVE_WRAPPER))
            assert(not DEFERRED_REMOVE_WRAPPER:IsMarkedForDeletion())
            assert(not IsValid(DEFERRED_REMOVE_CHILD))
            assert(IsValid(DEFERRED_REMOVE_REPLACEMENT))

            -- Repeating Remove after the deletion pass is also a no-op.
            DEFERRED_REMOVE_WRAPPER:Remove()
            """,
            sourceName: "@GMLuaDeferredPanelRemoveAfterFrame.lua"
        )
        XCTAssertEqual(registry.livePanelCount, 1)
    }

    func testNativePanelStartsAtSourceDefaultDimensionsBeforeScriptedSizing() throws {
        let state = LuaState(output: { _ in })
        let typeSystem = try GMLuaTypeSystem.install(
            into: state,
            utilityLayer: .bundledFallback
        )
        let registry = try GMLuaVGUI.install(into: state, typeSystem: typeSystem)

        try state.execute(
            """
            local panel = assert(vgui.Create("Panel"))
            local width, height = panel:GetSize()
            assert(width == 64 and height == 24)

            local explicitlySized = assert(vgui.Create("Panel"))
            explicitlySized:SetSize(11, 22)
            local explicitWidth, explicitHeight = explicitlySized:GetSize()
            assert(explicitWidth == 11 and explicitHeight == 22)

            local PROBE = {}
            vgui.Register("ViewportFillProbe", PROBE, "Panel")
            VIEWPORT_FILL_PROBE = assert(vgui.Create("ViewportFillProbe"))
            VIEWPORT_FILL_PROBE:Dock(FILL)
            """,
            sourceName: "@GMLuaNativePanelDefaultDimensionsRegression.lua"
        )

        let tree = registry.renderTree(viewportWidth: 320, viewportHeight: 180)
        let fillProbe = try XCTUnwrap(tree.first(where: {
            $0.requestedClassName == "ViewportFillProbe"
        }))
        XCTAssertEqual(
            fillProbe.frame,
            GMLuaPanelRect(x: 0, y: 0, width: 320, height: 180)
        )
    }

    func testHTMLLoadingLifecycleRequiresAnExplicitRendererResolution() throws {
        let state = LuaState(output: { _ in })
        let typeSystem = try GMLuaTypeSystem.install(
            into: state,
            utilityLayer: .bundledFallback
        )
        let registry = try GMLuaVGUI.install(into: state, typeSystem: typeSystem)

        try state.execute(
            """
            HTML_LIFECYCLE_LOG = {}
            HTML_LIFECYCLE = assert(vgui.Create("HTML"))
            function HTML_LIFECYCLE:OnBeginLoadingDocument(url)
                HTML_LIFECYCLE_LOG[#HTML_LIFECYCLE_LOG + 1] = "begin:" .. url
            end
            function HTML_LIFECYCLE:OnDocumentReady(url)
                assert(not self:IsLoading())
                HTML_LIFECYCLE_LOG[#HTML_LIFECYCLE_LOG + 1] = "ready:" .. url
            end
            function HTML_LIFECYCLE:OnFinishLoadingDocument(url)
                assert(not self:IsLoading())
                HTML_LIFECYCLE_LOG[#HTML_LIFECYCLE_LOG + 1] = "finish:" .. url
            end

            assert(not HTML_LIFECYCLE:IsLoading())
            HTML_LIFECYCLE:OpenURL("https://example.invalid/stock-panel")
            assert(HTML_LIFECYCLE:IsLoading())
            assert(table.concat(HTML_LIFECYCLE_LOG, "|") ==
                "begin:https://example.invalid/stock-panel")

            local ordinary = vgui.Create("Panel")
            assert(pcall(ordinary.IsLoading, ordinary) == false)
            """,
            sourceName: "@GMLuaHTMLLogicalLoadRequestRegression.lua"
        )

        var snapshot = try XCTUnwrap(registry.htmlPanelStateSnapshots.first)
        XCTAssertEqual(snapshot.state, .loading)
        XCTAssertEqual(snapshot.url, LuaString("https://example.invalid/stock-panel"))
        XCTAssertNil(snapshot.html)
        let firstRequest = snapshot.requestIdentifier
        XCTAssertTrue(try registry.resolveHTMLDocumentLoad(
            panelIdentifier: snapshot.panelIdentifier,
            requestIdentifier: firstRequest,
            result: .succeeded
        ))
        try state.execute(
            """
            assert(not HTML_LIFECYCLE:IsLoading())
            assert(table.concat(HTML_LIFECYCLE_LOG, "|") ==
                "begin:https://example.invalid/stock-panel|" ..
                "ready:https://example.invalid/stock-panel|" ..
                "finish:https://example.invalid/stock-panel")

            HTML_LIFECYCLE:SetHTML("<p>stock default.lua shape</p>")
            assert(HTML_LIFECYCLE:IsLoading())
            """,
            sourceName: "@GMLuaHTMLLogicalLoadCompletionRegression.lua"
        )

        snapshot = try XCTUnwrap(registry.htmlPanelStateSnapshots.first)
        XCTAssertEqual(snapshot.state, .loading)
        XCTAssertNil(snapshot.url)
        XCTAssertEqual(snapshot.html, LuaString("<p>stock default.lua shape</p>"))
        XCTAssertFalse(try registry.resolveHTMLDocumentLoad(
            panelIdentifier: snapshot.panelIdentifier,
            requestIdentifier: firstRequest,
            result: .succeeded
        ))
        XCTAssertTrue(try registry.resolveHTMLDocumentLoad(
            panelIdentifier: snapshot.panelIdentifier,
            requestIdentifier: snapshot.requestIdentifier,
            result: .failed(message: "platform renderer unavailable")
        ))

        snapshot = try XCTUnwrap(registry.htmlPanelStateSnapshots.first)
        XCTAssertEqual(snapshot.state, .failed)
        XCTAssertEqual(snapshot.failureMessage, "platform renderer unavailable")
        try state.execute(
            """
            assert(not HTML_LIFECYCLE:IsLoading())
            assert(HTML_LIFECYCLE_LOG[#HTML_LIFECYCLE_LOG] == "begin:about:blank")
            """,
            sourceName: "@GMLuaHTMLLogicalLoadFailureRegression.lua"
        )
    }

    func testBundledSpawnIconRetainsModelImageRequestWithoutFabricatingPreview() throws {
        let fileSystem = try GMLuaHostDirectoryFileSystem(
            rootURL: GModGameAssets.clientContentRootURL(),
            writable: false
        )
        let runtime = GMLuaRuntime(
            realm: .client,
            logger: { _ in },
            virtualFileSystem: fileSystem,
            bootstrapMode: .strict
        )
        defer { _ = runtime.close() }
        runtime.resourceRegistry?.setMaterialPixelResolver(
            GMLuaVPKMaterialPixelResolver(
                looseFileSystem: fileSystem,
                archivesInPriorityOrder: []
            )
        )
        try runtime.loadFile("lua/includes/init.lua")
        try runtime.loadFile("lua/derma/init.lua")
        try runtime.loadFile("lua/vgui/dlabel.lua")
        try runtime.loadFile("lua/vgui/dbutton.lua")
        try runtime.loadFile("lua/vgui/spawnicon.lua")

        try runtime.execute(
            """
            -- Scheme rendering is outside this state test; the full playable
            -- session supplies the stock skin before these controls are built.
            DLabel.ApplySchemeSettings = function() end
            MODEL_ICON = assert(vgui.Create("SpawnIcon"))
            MODEL_ICON:SetModel(
                "models/props_c17/oildrum001.mdl",
                2,
                "012345678"
            )
            assert(MODEL_ICON:GetModelName() ==
                "models/props_c17/oildrum001.mdl")
            assert(MODEL_ICON:GetSkinID() == 2)
            assert(MODEL_ICON:GetBodyGroup() == "012345678")

            MODEL_ICON:SetSpawnIcon("spawnicons/oildrum.png")
            assert(MODEL_ICON:GetIconName() == "spawnicons/oildrum.png")

            local ok = pcall(MODEL_ICON.Icon.SetModel, MODEL_ICON.Icon, {}, 0)
            assert(not ok)
            ok = pcall(MODEL_ICON.Icon.SetModel, MODEL_ICON.Icon, "model.mdl", 1.5)
            assert(not ok)
            local ordinary = assert(vgui.Create("Panel"))
            ok = pcall(ordinary.SetModel, ordinary, "model.mdl")
            assert(not ok)
            """,
            sourceName: "@GMLuaBundledSpawnIconModelImageStateRegression.lua"
        )

        let registry = try XCTUnwrap(runtime.vguiRegistry)
        let snapshot = try XCTUnwrap(registry.modelImageStateSnapshots.first(where: {
            $0.modelPath == LuaString("models/props_c17/oildrum001.mdl")
        }))
        XCTAssertEqual(snapshot.requestedClassName, "ModelImage")
        XCTAssertEqual(snapshot.skin, 2)
        XCTAssertEqual(snapshot.bodyGroups, LuaString("012345678"))
        XCTAssertEqual(snapshot.spawnIconName, LuaString("spawnicons/oildrum.png"))
        XCTAssertEqual(snapshot.previewState, .unavailable)
    }

    func testBundledHorizontalDividerPlacesRightPanelAfterLeftAndDivider() throws {
        let fileSystem = try GMLuaHostDirectoryFileSystem(
            rootURL: GModGameAssets.clientContentRootURL(),
            writable: false
        )
        let runtime = GMLuaRuntime(
            realm: .client,
            logger: { _ in },
            virtualFileSystem: fileSystem,
            bootstrapMode: .strict,
            initialViewport: GMLuaViewportSize(width: 1_280, height: 720)
        )
        defer { _ = runtime.close() }
        try runtime.loadFile("lua/includes/init.lua")
        try runtime.loadFile("lua/derma/init.lua")
        try runtime.loadFile("lua/vgui/dpanel.lua")
        try runtime.loadFile("lua/vgui/dhorizontaldivider.lua")

        try runtime.execute(
            """
            DIVIDER = assert(vgui.Create("DHorizontalDivider"))
            DIVIDER:SetPos(8, 58)
            DIVIDER:SetSize(798, 654)
            DIVIDER:SetLeftWidth(192)
            DIVIDER:SetDividerWidth(6)
            DIVIDER:SetLeftMin(192)
            DIVIDER:SetRightMin(100)

            DIVIDER_LEFT = assert(vgui.Create("Panel"))
            DIVIDER_RIGHT = assert(vgui.Create("Panel"))
            DIVIDER:SetLeft(DIVIDER_LEFT)
            DIVIDER:SetRight(DIVIDER_RIGHT)
            DIVIDER:InvalidateLayout(true)

            local lx, ly = DIVIDER_LEFT:GetPos()
            local rx, ry = DIVIDER_RIGHT:GetPos()
            assert(lx == 0 and ly == 0)
            assert(rx == 198 and ry == 0)
            assert(DIVIDER_LEFT.x == 0 and DIVIDER_LEFT.y == 0)
            assert(DIVIDER_RIGHT.x == 198 and DIVIDER_RIGHT.y == 0)
            assert(DIVIDER_LEFT:GetWide() == 192 and DIVIDER_LEFT:GetTall() == 654)
            assert(DIVIDER_RIGHT:GetWide() == 600 and DIVIDER_RIGHT:GetTall() == 654)
            """,
            sourceName: "@GMLuaBundledHorizontalDividerGeometryRegression.lua"
        )

        let registry = try XCTUnwrap(runtime.vguiRegistry)
        let tree = registry.renderTree(viewportWidth: 1_280, viewportHeight: 720)
        let right = try XCTUnwrap(tree.first(where: {
            $0.requestedClassName == "Panel" && $0.frame.x == 206 && $0.frame.y == 58
        }))
        XCTAssertEqual(
            right.frame,
            GMLuaPanelRect(x: 206, y: 58, width: 600, height: 654)
        )
    }

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

    func testSetSizeDispatchesOnSizeChangedOnlyForActualIntegerDimensionChanges() throws {
        let state = LuaState(output: { _ in })
        let typeSystem = try GMLuaTypeSystem.install(
            into: state,
            utilityLayer: .bundledFallback
        )
        let registry = try GMLuaVGUI.install(into: state, typeSystem: typeSystem)

        try state.execute(
            """
            local panelMeta = FindMetaTable("Panel")
            assert(type(panelMeta.OnSizeChanged) == "function")

            local PROBE = {}
            function PROBE:OnSizeChanged(width, height)
                SIZE_CHANGE_CALLS = (SIZE_CHANGE_CALLS or 0) + 1
                SIZE_CHANGE_WIDTH = width
                SIZE_CHANGE_HEIGHT = height
                panelMeta.OnSizeChanged(self, width, height)
            end
            vgui.Register("SizeChangeProbe", PROBE, "Panel")

            SIZE_CHANGE_PANEL = assert(vgui.Create("SizeChangeProbe"))
            SIZE_CHANGE_PANEL:SetSize(100.9, 20.9)
            assert(SIZE_CHANGE_CALLS == 1)
            assert(SIZE_CHANGE_WIDTH == 100 and SIZE_CHANGE_HEIGHT == 20)
            assert(SIZE_CHANGE_PANEL:GetWide() == 100 and SIZE_CHANGE_PANEL:GetTall() == 20)

            -- Each value floors to the already-observable integer dimension.
            SIZE_CHANGE_PANEL:SetSize(100.1, 20.1)
            SIZE_CHANGE_PANEL:SetWide(100.9)
            SIZE_CHANGE_PANEL:SetTall(20.9)
            assert(SIZE_CHANGE_CALLS == 1)

            SIZE_CHANGE_PANEL:SetWide(101)
            assert(SIZE_CHANGE_CALLS == 2)
            assert(SIZE_CHANGE_WIDTH == 101 and SIZE_CHANGE_HEIGHT == 20)
            SIZE_CHANGE_PANEL:SetTall(21)
            assert(SIZE_CHANGE_CALLS == 3)
            assert(SIZE_CHANGE_WIDTH == 101 and SIZE_CHANGE_HEIGHT == 21)
            """,
            sourceName: "@GMLuaPanelSizeChangedRegression.lua"
        )
        XCTAssertEqual(registry.pendingLayoutCount, 1)
        XCTAssertEqual(try registry.performPendingLayouts(), 1)
        XCTAssertEqual(registry.pendingLayoutCount, 0)
    }

    func testDockResizeDispatchesFinalSizeBeforeDockedChildLayout() throws {
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
            local panelMeta = FindMetaTable("Panel")
            local PROBE = {}
            function PROBE:OnSizeChanged(width, height)
                DOCK_SIZE_CHANGE_CALLS = (DOCK_SIZE_CHANGE_CALLS or 0) + 1
                DOCK_CALLBACK_WIDTH = width
                DOCK_CALLBACK_HEIGHT = height
                DOCK_CALLBACK_OBSERVED_WIDTH = self:GetWide()
                DOCK_CALLBACK_OBSERVED_HEIGHT = self:GetTall()
                panelMeta.OnSizeChanged(self, width, height)
            end
            function PROBE:PerformLayout(width, height)
                DOCK_LAYOUT_CALLS = (DOCK_LAYOUT_CALLS or 0) + 1
                DOCK_LAYOUT_WIDTH = width
                DOCK_LAYOUT_HEIGHT = height
                DOCK_LAYOUT_OBSERVED_WIDTH = self:GetWide()
                DOCK_LAYOUT_OBSERVED_HEIGHT = self:GetTall()
            end
            vgui.Register("DockSizeChangeProbe", PROBE, "Panel")

            DOCK_ROOT = assert(vgui.Create("Panel"))
            DOCK_ROOT:SetSize(320, 180)
            DOCK_CHILD = assert(vgui.Create("DockSizeChangeProbe", DOCK_ROOT))
            DOCK_CHILD:Dock(FILL)
            """,
            sourceName: "@GMLuaDockSizeChangedRegression.lua"
        )

        _ = try registry.renderFrame(
            surface: surface,
            viewportWidth: 320,
            viewportHeight: 180
        )
        try state.execute(
            """
            assert(DOCK_SIZE_CHANGE_CALLS == 1)
            assert(DOCK_CALLBACK_WIDTH == 320 and DOCK_CALLBACK_HEIGHT == 180)
            assert(DOCK_CALLBACK_OBSERVED_WIDTH == 320)
            assert(DOCK_CALLBACK_OBSERVED_HEIGHT == 180)
            assert(DOCK_LAYOUT_CALLS == 1)
            assert(DOCK_LAYOUT_WIDTH == 320 and DOCK_LAYOUT_HEIGHT == 180)
            assert(DOCK_LAYOUT_OBSERVED_WIDTH == 320)
            assert(DOCK_LAYOUT_OBSERVED_HEIGHT == 180)
            """,
            sourceName: "@GMLuaDockFinalSizeObservedByLayout.lua"
        )

        _ = try registry.renderFrame(
            surface: surface,
            viewportWidth: 320,
            viewportHeight: 180
        )
        try state.execute(
            """
            assert(DOCK_SIZE_CHANGE_CALLS == 1)
            assert(DOCK_LAYOUT_CALLS == 1)
            """,
            sourceName: "@GMLuaDockSameSizeNoOp.lua"
        )
    }

    func testLateChildLayoutRevisitsSizeToChildrenCanvasToStableFrame() throws {
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
            LATE_CANVAS = assert(vgui.Create("Panel"))
            LATE_CANVAS:SetSize(308, 18)
            LATE_CANVAS.LayoutCalls = 0
            function LATE_CANVAS:PerformLayout()
                self.LayoutCalls = self.LayoutCalls + 1
                self:SizeToChildren(false, true)
            end

            LATE_CONTROL_PANEL = assert(vgui.Create("Panel", LATE_CANVAS))
            LATE_CONTROL_PANEL:SetPos(2, 2)
            LATE_CONTROL_PANEL:SetSize(304, 16)
            LATE_CONTROL_PANEL.LayoutCalls = 0
            function LATE_CONTROL_PANEL:PerformLayout()
                self.LayoutCalls = self.LayoutCalls + 1
                self:SetTall(385)
            end

            LATE_CANVAS:InvalidateLayout()
            LATE_CONTROL_PANEL:InvalidateLayout()
            """,
            sourceName: "@GMLuaLateSizeToChildrenFixedPointSetup.lua"
        )

        _ = try registry.renderFrame(
            surface: surface,
            viewportWidth: 1280,
            viewportHeight: 720
        )
        let fixedPointProbe = try state.executeReturningValues(
            """
            return LATE_CONTROL_PANEL:GetTall(), LATE_CANVAS:GetTall(),
                LATE_CONTROL_PANEL.LayoutCalls, LATE_CANVAS.LayoutCalls
            """,
            sourceName: "@GMLuaLateSizeToChildrenFixedPointStable.lua"
        )
        guard fixedPointProbe.count == 4,
              case .number(385) = fixedPointProbe[0],
              case .number(387) = fixedPointProbe[1],
              case .number(1) = fixedPointProbe[2],
              case .number(2) = fixedPointProbe[3] else {
            return XCTFail("unexpected fixed-point geometry: \(fixedPointProbe)")
        }
        let stableLayoutPassCount = registry.completedLayoutPassCount

        _ = try registry.renderFrame(
            surface: surface,
            viewportWidth: 1280,
            viewportHeight: 720
        )
        XCTAssertEqual(registry.completedLayoutPassCount, stableLayoutPassCount)
        try state.execute(
            """
            assert(LATE_CONTROL_PANEL.LayoutCalls == 1)
            assert(LATE_CANVAS.LayoutCalls == 2)
            """,
            sourceName: "@GMLuaLateSizeToChildrenFixedPointNoOp.lua"
        )
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

        do {
            try state.execute(
                String(contentsOf: fixtureURL, encoding: .utf8),
                sourceName: "@GLuaPanelEngineControlRegression.lua"
            )
        } catch {
            return XCTFail(GMLuaRuntime.describe(error))
        }

        XCTAssertEqual(registry.registeredControlCount, 1)
        XCTAssertEqual(registry.livePanelCount, 1)
        XCTAssertFalse(registry.hasPlatformViewBacking)
        guard case .boolean(true) = state.getGlobal("GLUA_PANEL_ENGINE_CONTROL_REGRESSION_OK") else {
            return XCTFail("logical engine Panel fixture did not reach its success sentinel")
        }
        _ = try registry.performPendingLayouts()
        try state.execute(
            """
            assert(not IsValid(GLUA_PANEL_ENGINE_DEFERRED_PARENT))
            assert(not GLUA_PANEL_ENGINE_DEFERRED_PARENT:IsMarkedForDeletion())
            assert(not IsValid(GLUA_PANEL_ENGINE_DEFERRED_CHILD))
            assert(not IsValid(GLUA_PANEL_ENGINE_DEFERRED_SECOND))
            assert(not GLUA_PANEL_ENGINE_DEFERRED_SECOND:IsMarkedForDeletion())
            assert(#vgui.GetAll() == 0)
            """,
            sourceName: "@GLuaPanelEngineControlDeferredRemovalPass.lua"
        )
        XCTAssertEqual(registry.livePanelCount, 0)
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
            assert(type(LABEL.SetWrap) == "function")

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

    func testLabelSizingWrapAndNativePerformLayoutUseMeasuredContent() throws {
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

        let values = try state.executeReturningValues(
            """
            local label = assert(vgui.Create("Label"))
            label:SetFont("Default")
            label:SetText("AAAA BBBB")

            local tw, th = label:GetTextSize()

            label:SetSize(20, 100)
            label:SetWrap(true)
            local wrappedW, wrappedH = label:GetContentSize()

            label:SizeToContentsY(5)
            local afterYW, afterYH = label:GetSize()
            label:SizeToContentsX("2")
            local afterXW, afterXH = label:GetSize()

            label:SetWrap(false)
            label:SizeToContents()
            local sizedW, sizedH = label:GetSize()

            label:SetText("AAAA")
            label:SetTextInset(0, 3)
            label:SetSize(100, 20)
            label:PerformLayout()
            local laidOutW, laidOutH = label:GetContentSize()

            return label:GetFont(), tw, th, wrappedW, wrappedH,
                   afterYW, afterYH, afterXW, afterXH,
                   sizedW, sizedH, laidOutW, laidOutH
            """,
            sourceName: "@GMLuaLabelMeasuredSizingRegression.lua"
        )
        guard values.count == 13,
              case let .string(font) = values[0],
              case let .number(textWidth) = values[1],
              case let .number(textHeight) = values[2],
              case let .number(wrappedWidth) = values[3],
              case let .number(wrappedHeight) = values[4],
              case let .number(afterYWidth) = values[5],
              case let .number(afterYHeight) = values[6],
              case let .number(afterXWidth) = values[7],
              case let .number(afterXHeight) = values[8],
              case let .number(sizedWidth) = values[9],
              case let .number(sizedHeight) = values[10],
              case let .number(laidOutWidth) = values[11],
              case let .number(laidOutHeight) = values[12] else {
            return XCTFail("Label sizing probe did not return its numeric contract")
        }
        XCTAssertEqual(font, LuaString("Default"))
        XCTAssertEqual(textWidth, 59)
        XCTAssertEqual(textHeight, 13)
        XCTAssertEqual(wrappedWidth, 20)
        XCTAssertEqual(wrappedHeight, 39)
        XCTAssertEqual(afterYWidth, 20)
        XCTAssertEqual(afterYHeight, 44)
        XCTAssertEqual(afterXWidth, 22)
        XCTAssertEqual(afterXHeight, 44)
        XCTAssertEqual(sizedWidth, 59)
        XCTAssertEqual(sizedHeight, 13)
        XCTAssertEqual(laidOutWidth, 26)
        XCTAssertEqual(laidOutHeight, 16)

        let snapshot = try XCTUnwrap(registry.textPanelStateSnapshots.first)
        XCTAssertFalse(snapshot.wrapsText)
    }

    func testGenericPanelSizeToContentsUsesDirectChildBoundsAndStableSizeIsNoOp() throws {
        let state = LuaState(output: { _ in })
        let typeSystem = try GMLuaTypeSystem.install(
            into: state,
            utilityLayer: .bundledFallback
        )
        _ = try GMLuaVGUI.install(into: state, typeSystem: typeSystem)

        try state.execute(
            """
            local panelMeta = FindMetaTable("Panel")
            local PROBE = {}
            function PROBE:OnSizeChanged(width, height)
                GENERIC_SIZE_CALLS = (GENERIC_SIZE_CALLS or 0) + 1
                GENERIC_SIZE_WIDTH = self:GetWide()
                GENERIC_SIZE_HEIGHT = self:GetTall()
                GENERIC_SIZE_ARGUMENT_WIDTH = width
                GENERIC_SIZE_ARGUMENT_HEIGHT = height
                panelMeta.OnSizeChanged(self, width, height)
            end
            vgui.Register("GenericSizeToContentsProbe", PROBE, "Panel")

            local parent = vgui.Create("GenericSizeToContentsProbe")
            parent:SetSize(320, 240)
            GENERIC_SIZE_CALLS = 0

            local first = vgui.Create("Panel", parent)
            first:SetPos(10, 20)
            first:SetSize(30, 40)

            local farthest = vgui.Create("Panel", parent)
            farthest:SetPos(70, 15)
            farthest:SetSize(50, 100)

            -- Descendants do not enlarge the direct child extent.
            local grandchild = vgui.Create("Panel", first)
            grandchild:SetPos(500, 600)
            grandchild:SetSize(20, 30)

            parent:SizeToContents()
            assert(parent:GetWide() == 120 and parent:GetTall() == 115)
            assert(GENERIC_SIZE_CALLS == 1)
            assert(GENERIC_SIZE_WIDTH == 120 and GENERIC_SIZE_HEIGHT == 115)
            assert(GENERIC_SIZE_ARGUMENT_WIDTH == 120 and GENERIC_SIZE_ARGUMENT_HEIGHT == 115)

            parent:SizeToContents()
            assert(GENERIC_SIZE_CALLS == 1)
            """,
            sourceName: "@GMLuaGenericPanelSizeToContentsRegression.lua"
        )
    }

    func testBundledStockDCheckBoxLabelCallsEngineSizeToContentsAtLine129() throws {
        let fileSystem = try GMLuaHostDirectoryFileSystem(
            rootURL: GModGameAssets.clientContentRootURL(),
            writable: false
        )
        let runtime = GMLuaRuntime(
            realm: .client,
            logger: { _ in },
            virtualFileSystem: fileSystem,
            bootstrapMode: .strict,
            initialViewport: GMLuaViewportSize(width: 810, height: 1_080)
        )
        defer { _ = runtime.close() }
        runtime.resourceRegistry?.setMaterialPixelResolver(
            GMLuaVPKMaterialPixelResolver(
                looseFileSystem: fileSystem,
                archivesInPriorityOrder: []
            )
        )

        try runtime.loadFile("lua/includes/init.lua")
        try runtime.loadFile("lua/derma/init.lua")
        try runtime.loadFile("lua/vgui/dpanel.lua")
        try runtime.loadFile("lua/vgui/dlabel.lua")
        try runtime.loadFile("lua/vgui/dbutton.lua")
        try runtime.loadFile("lua/vgui/dcheckbox.lua")
        try runtime.loadFile("lua/skins/default.lua")

        try runtime.execute(
            """
            local panelMeta = FindMetaTable("Panel")
            assert(type(panelMeta.SizeToContents) == "function")
            assert(type(panelMeta.GetTextSize) == "function")
            assert(type(panelMeta.SetWrap) == "function")

            CHECK = assert(vgui.Create("DCheckBoxLabel"))
            CHECK:SetText("Sandbox")
            assert(CHECK:GetText() == "Sandbox")
            local contentW, contentH = CHECK.Label:GetContentSize()
            assert(CHECK.Label:GetWide() == contentW)
            assert(CHECK.Label:GetTall() == contentH)
            assert(contentW > 0 and contentH > 0)

            CHECK:SetFont("DermaDefaultBold")
            local textW, textH = CHECK.Label:GetTextSize()
            assert(textW > 0 and textH > 0)

            WRAPPED = assert(vgui.Create("DLabel"))
            WRAPPED:SetWide(30)
            WRAPPED:SetText("AAAA BBBB")
            WRAPPED:SetWrap(true)
            assert(type(WRAPPED.SetAutoStretchVertical) == "function")
            WRAPPED:SetAutoStretchVertical(true)
            WRAPPED:Think()
            assert(WRAPPED:GetTall() > 13)
            """,
            sourceName: "@GMLuaBundledDCheckBoxSizeToContentsRegression.lua"
        )

        let registry = try XCTUnwrap(runtime.vguiRegistry)
        XCTAssertTrue(registry.missingMethodDiagnostics.isEmpty)
    }

    func testMissingMethodDiagnosticsPreserveNilLookupAndClassifyLifecycleCall() throws {
        let state = LuaState(output: { _ in })
        let typeSystem = try GMLuaTypeSystem.install(
            into: state,
            utilityLayer: .bundledFallback
        )
        let registry = try GMLuaVGUI.install(into: state, typeSystem: typeSystem)

        try state.execute(
            """
            local PANEL = {}
            function PANEL:KnownMethod()
                return true
            end
            function PANEL:PerformLayout()
                assert(self:KnownMethod())
                assert(type(self.MissingThing) == "nil")
                self:MissingThing()
            end
            vgui.Register("MissingDiagnosticPanel", PANEL, "Panel")

            MISSING_DIAGNOSTIC_PANEL = assert(vgui.Create("MissingDiagnosticPanel"))
            assert(type(MISSING_DIAGNOSTIC_PANEL.MissingThing) == "nil")
            MISSING_DIAGNOSTIC_PANEL:InvalidateLayout()
            """,
            sourceName: "@GMLuaVGUIMissingMethodLifecycle.lua"
        )
        XCTAssertTrue(registry.missingMethodDiagnostics.isEmpty)

        XCTAssertThrowsError(try registry.performPendingLayouts()) { error in
            XCTAssertTrue(String(describing: error).contains(
                "[VGUI][MISSING] class=MissingDiagnosticPanel method=MissingThing " +
                    "source=GMLuaVGUIMissingMethodLifecycle.lua:8"
            ))
        }
        let diagnostic = try XCTUnwrap(registry.missingMethodDiagnostics.last)
        XCTAssertEqual(diagnostic.requestedClassName, "MissingDiagnosticPanel")
        XCTAssertEqual(diagnostic.engineClassName, "Panel")
        XCTAssertEqual(diagnostic.methodName, "MissingThing")
        XCTAssertEqual(diagnostic.source, "GMLuaVGUIMissingMethodLifecycle.lua")
        XCTAssertEqual(diagnostic.line, 8)
        XCTAssertEqual(
            diagnostic.logLine,
            "[VGUI][MISSING] class=MissingDiagnosticPanel method=MissingThing " +
                "source=GMLuaVGUIMissingMethodLifecycle.lua:8"
        )
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

    func testNoClippingWidensOnlyLuaPaintAndPaintOverNotNativeTextOrHitTesting() throws {
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
            function PROBE:Paint()
                surface.SetDrawColor(10, 20, 30, 255)
                surface.DrawRect(-15, 0, 40, 10)
            end
            function PROBE:PaintOver()
                surface.SetDrawColor(40, 50, 60, 255)
                surface.DrawRect(0, 12, 20, 5)
            end
            vgui.Register("NoClippingPaintProbe", PROBE, "Label")

            NOCLIP_ROOT = assert(vgui.Create("Panel"))
            NOCLIP_ROOT:SetPos(20, 20)
            NOCLIP_ROOT:SetSize(40, 40)
            NOCLIP_PROBE = assert(vgui.Create("NoClippingPaintProbe", NOCLIP_ROOT))
            NOCLIP_PROBE:SetPos(30, 5)
            NOCLIP_PROBE:SetSize(20, 20)
            NOCLIP_PROBE:SetText("native")

            assert(select("#", NOCLIP_PROBE:NoClipping(true)) == 0)
            assert(pcall(NOCLIP_PROBE.NoClipping, NOCLIP_PROBE, 1) == false)
            """,
            sourceName: "@GMLuaPanelNoClippingPaintSetup.lua"
        )

        let tree = registry.renderTree(viewportWidth: 100, viewportHeight: 100)
        let probe = try XCTUnwrap(tree.first(where: {
            $0.requestedClassName == "NoClippingPaintProbe"
        }))
        XCTAssertEqual(probe.frame, GMLuaPanelRect(x: 50, y: 25, width: 20, height: 20))
        XCTAssertEqual(probe.clipRect, GMLuaPanelRect(x: 50, y: 25, width: 10, height: 20))
        XCTAssertTrue(probe.paintClippingDisabled)
        XCTAssertEqual(probe.paintClipRect, GMLuaPanelRect(x: 0, y: 0, width: 100, height: 100))

        let frame = try registry.renderFrame(
            surface: surface,
            viewportWidth: 100,
            viewportHeight: 100
        )
        XCTAssertEqual(frame.commands.count, 3)
        guard case let .rectangle(paintFrame, _, paintClip) = frame.commands[0],
              case let .text(text, _, _, _, textClip) = frame.commands[1],
              case let .rectangle(paintOverFrame, _, paintOverClip) = frame.commands[2] else {
            return XCTFail("NoClipping probe emitted an unexpected draw-command sequence")
        }
        XCTAssertEqual(paintFrame, GMLuaPanelRect(x: 35, y: 25, width: 40, height: 10))
        XCTAssertEqual(paintClip, GMLuaPanelRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertEqual(text, LuaString("native"))
        XCTAssertEqual(textClip, probe.clipRect)
        XCTAssertEqual(paintOverFrame, GMLuaPanelRect(x: 50, y: 37, width: 20, height: 5))
        XCTAssertEqual(paintOverClip, paintClip)

        let outsideParent = try registry.dispatchPointerEvent(
            x: 65,
            y: 30,
            phase: .moved,
            timestamp: 1,
            viewportWidth: 100,
            viewportHeight: 100
        )
        XCTAssertNotEqual(outsideParent.hitPanelIdentifier, probe.identifier)
        let insideParent = try registry.dispatchPointerEvent(
            x: 55,
            y: 30,
            phase: .moved,
            timestamp: 1.1,
            viewportWidth: 100,
            viewportHeight: 100
        )
        XCTAssertEqual(insideParent.hitPanelIdentifier, probe.identifier)

        try state.execute(
            "NOCLIP_PROBE:NoClipping(false)",
            sourceName: "@GMLuaPanelNoClippingRestore.lua"
        )
        let restoredTree = registry.renderTree(viewportWidth: 100, viewportHeight: 100)
        let restoredProbe = try XCTUnwrap(restoredTree.first(where: {
            $0.identifier == probe.identifier
        }))
        XCTAssertFalse(restoredProbe.paintClippingDisabled)
        XCTAssertEqual(restoredProbe.paintClipRect, restoredProbe.clipRect)
        let restoredFrame = try registry.renderFrame(
            surface: surface,
            viewportWidth: 100,
            viewportHeight: 100
        )
        guard case let .rectangle(_, _, restoredPaintClip) = restoredFrame.commands[0],
              case let .rectangle(_, _, restoredPaintOverClip) = restoredFrame.commands[2] else {
            return XCTFail("restored clipping probe emitted unexpected commands")
        }
        XCTAssertEqual(restoredPaintClip, restoredProbe.clipRect)
        XCTAssertEqual(restoredPaintOverClip, restoredProbe.clipRect)
    }

    func testStockDColorButtonDrawFilledRectUsesPanelRectColorAlphaClipAndBudget() throws {
        let state = LuaState(output: { _ in })
        let typeSystem = try GMLuaTypeSystem.install(
            into: state,
            utilityLayer: .bundledFallback
        )
        let surface = try GMLuaSurface.install(
            into: state,
            maximumDrawCommandCount: 2
        )
        let registry = try GMLuaVGUI.install(
            into: state,
            typeSystem: typeSystem,
            surfaceCommandState: surface
        )
        try state.execute(
            """
            function Color(r, g, b, a)
                return { r = r, g = g, b = b, a = a }
            end

            local BUTTON = {}
            function BUTTON:Paint()
                local panelColor = self.PaintColor
                -- Exact rendering shape used by stock DColorButton:Paint.
                surface.SetDrawColor(
                    panelColor.r, panelColor.g, panelColor.b, panelColor.a
                )
                self:DrawFilledRect()
                return true
            end
            vgui.Register("DColorButtonShape", BUTTON, "Label")

            FILLED_ROOT = assert(vgui.Create("Panel"))
            FILLED_ROOT:SetPos(10, 10)
            FILLED_ROOT:SetSize(30, 40)
            FILLED_ROOT:SetAlpha(128)

            FILLED_CLIPPED = assert(vgui.Create("DColorButtonShape", FILLED_ROOT))
            FILLED_CLIPPED:SetPos(20, 5)
            FILLED_CLIPPED:SetSize(20, 10)
            FILLED_CLIPPED:SetAlpha(128)
            FILLED_CLIPPED.PaintColor = Color(10, 20, 30, 200)

            FILLED_NOCLIP = assert(vgui.Create("DColorButtonShape", FILLED_ROOT))
            FILLED_NOCLIP:SetPos(20, 18)
            FILLED_NOCLIP:SetSize(20, 10)
            FILLED_NOCLIP:SetAlpha(128)
            FILLED_NOCLIP.PaintColor = Color(40, 50, 60, 160)
            FILLED_NOCLIP:NoClipping(true)

            -- This third valid draw proves Panel:DrawFilledRect participates
            -- in the same bounded Surface command budget.
            FILLED_BUDGET = assert(vgui.Create("DColorButtonShape", FILLED_ROOT))
            FILLED_BUDGET:SetPos(0, 30)
            FILLED_BUDGET:SetSize(5, 5)
            FILLED_BUDGET.PaintColor = Color(70, 80, 90, 255)

            assert(select("#", FILLED_CLIPPED:DrawFilledRect()) == 0)
            assert(pcall(FILLED_CLIPPED.DrawFilledRect, {}) == false)
            """,
            sourceName: "@GMLuaStockDColorButtonDrawFilledRectSetup.lua"
        )

        let frame = try registry.renderFrame(
            surface: surface,
            viewportWidth: 100,
            viewportHeight: 100
        )
        XCTAssertEqual(frame.captureDiagnostics.attemptedCommandCount, 3)
        XCTAssertEqual(frame.captureDiagnostics.retainedCommandCount, 2)
        XCTAssertEqual(frame.captureDiagnostics.droppedCommandCount, 1)
        XCTAssertEqual(frame.commands.count, 2)
        guard case let .rectangle(clippedFrame, clippedColor, clippedClip) = frame.commands[0],
              case let .rectangle(noClipFrame, noClipColor, noClipClip) = frame.commands[1] else {
            return XCTFail("DrawFilledRect emitted an unexpected command sequence")
        }
        XCTAssertEqual(clippedFrame, GMLuaPanelRect(x: 30, y: 15, width: 20, height: 10))
        XCTAssertEqual(clippedClip, GMLuaPanelRect(x: 30, y: 15, width: 10, height: 10))
        XCTAssertEqual(clippedColor.red, 10)
        XCTAssertEqual(clippedColor.green, 20)
        XCTAssertEqual(clippedColor.blue, 30)
        let cumulativeAlpha = 128.0 * 128.0 / 255.0
        XCTAssertEqual(clippedColor.alpha, 200.0 * cumulativeAlpha / 255.0, accuracy: 0.000_001)

        XCTAssertEqual(noClipFrame, GMLuaPanelRect(x: 30, y: 28, width: 20, height: 10))
        XCTAssertEqual(noClipClip, GMLuaPanelRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertEqual(noClipColor.red, 40)
        XCTAssertEqual(noClipColor.green, 50)
        XCTAssertEqual(noClipColor.blue, 60)
        XCTAssertEqual(noClipColor.alpha, 160.0 * cumulativeAlpha / 255.0, accuracy: 0.000_001)
    }

    func testOutlinedRectUsesInnerEdgesTinyFillClipAlphaAndAtomicBudget() throws {
        let state = LuaState(output: { _ in })
        let typeSystem = try GMLuaTypeSystem.install(
            into: state,
            utilityLayer: .bundledFallback
        )
        let surface = try GMLuaSurface.install(
            into: state,
            maximumDrawCommandCount: 5
        )
        let registry = try GMLuaVGUI.install(
            into: state,
            typeSystem: typeSystem,
            surfaceCommandState: surface
        )
        try state.execute(
            """
            assert(type(surface.DrawOutlinedRect) == "function")
            assert(pcall(surface.DrawOutlinedRect, 0, 0, 1) == false)
            assert(pcall(surface.DrawOutlinedRect, {}, 0, 1, 1) == false)
            assert(pcall(surface.DrawOutlinedRect, 0, 0, 1, 1, 0 / 0) == false)
            assert(pcall(surface.DrawOutlinedRect, 0, 0, 1, 1, "wide") == false)
            assert(select("#", surface.DrawOutlinedRect(0, 0, 1, 1, 0)) == 0)

            local OUTLINE = {}
            function OUTLINE:Paint()
                local color = self.PaintColor
                surface.SetDrawColor(color[1], color[2], color[3], color[4])
                if self.PanelShorthand then
                    -- Stock DAlphaBar/DColorCube/DRGBPicker shape.
                    self:DrawOutlinedRect()
                else
                    surface.DrawOutlinedRect(
                        self.OutlineX or 0,
                        self.OutlineY or 0,
                        self.OutlineW or self:GetWide(),
                        self.OutlineH or self:GetTall(),
                        self.Thickness
                    )
                end
                return true
            end
            vgui.Register("DOutlinedRectShape", OUTLINE, "Panel")

            OUTLINE_ROOT = assert(vgui.Create("Panel"))
            OUTLINE_ROOT:SetPos(10, 10)
            OUTLINE_ROOT:SetSize(30, 40)
            OUTLINE_ROOT:SetAlpha(128)

            OUTLINE_CLIPPED = assert(vgui.Create("DOutlinedRectShape", OUTLINE_ROOT))
            OUTLINE_CLIPPED:SetPos(20, 5)
            OUTLINE_CLIPPED:SetSize(20, 10)
            OUTLINE_CLIPPED:SetAlpha(128)
            OUTLINE_CLIPPED.PaintColor = { 10, 20, 30, 200 }
            OUTLINE_CLIPPED.OutlineX = -2
            OUTLINE_CLIPPED.OutlineY = -1
            OUTLINE_CLIPPED.OutlineW = 8
            OUTLINE_CLIPPED.OutlineH = 6
            OUTLINE_CLIPPED.Thickness = 2

            OUTLINE_TINY = assert(vgui.Create("DOutlinedRectShape", OUTLINE_ROOT))
            OUTLINE_TINY:SetPos(20, 18)
            OUTLINE_TINY:SetSize(2, 1)
            OUTLINE_TINY:SetAlpha(128)
            OUTLINE_TINY.PaintColor = { 40, 50, 60, 160 }
            OUTLINE_TINY.PanelShorthand = true
            OUTLINE_TINY:NoClipping(true)

            -- The remaining budget cannot retain a partial four-edge outline.
            OUTLINE_BUDGET = assert(vgui.Create("DOutlinedRectShape", OUTLINE_ROOT))
            OUTLINE_BUDGET:SetPos(0, 30)
            OUTLINE_BUDGET:SetSize(5, 5)
            OUTLINE_BUDGET.PaintColor = { 70, 80, 90, 255 }

            assert(select("#", OUTLINE_TINY:DrawOutlinedRect()) == 0)
            assert(pcall(OUTLINE_TINY.DrawOutlinedRect, {}) == false)
            """,
            sourceName: "@GMLuaOutlinedRectSetup.lua"
        )

        let frame = try registry.renderFrame(
            surface: surface,
            viewportWidth: 100,
            viewportHeight: 100
        )
        XCTAssertEqual(frame.captureDiagnostics.attemptedCommandCount, 9)
        XCTAssertEqual(frame.captureDiagnostics.retainedCommandCount, 5)
        XCTAssertEqual(frame.captureDiagnostics.droppedCommandCount, 4)
        XCTAssertEqual(frame.commands.count, 5)

        let expectedFrames = [
            GMLuaPanelRect(x: 28, y: 14, width: 8, height: 2),
            GMLuaPanelRect(x: 28, y: 18, width: 8, height: 2),
            GMLuaPanelRect(x: 28, y: 16, width: 2, height: 2),
            GMLuaPanelRect(x: 34, y: 16, width: 2, height: 2),
            GMLuaPanelRect(x: 30, y: 28, width: 2, height: 1)
        ]
        let clippedClip = GMLuaPanelRect(x: 30, y: 15, width: 10, height: 10)
        let viewportClip = GMLuaPanelRect(x: 0, y: 0, width: 100, height: 100)
        let cumulativeAlpha = 128.0 * 128.0 / 255.0
        for (index, command) in frame.commands.enumerated() {
            guard case let .rectangle(actualFrame, color, clip) = command else {
                return XCTFail("outlined rectangle emitted a non-rectangle command")
            }
            XCTAssertEqual(actualFrame, expectedFrames[index])
            if index < 4 {
                XCTAssertEqual(clip, clippedClip)
                XCTAssertEqual(color.red, 10)
                XCTAssertEqual(color.green, 20)
                XCTAssertEqual(color.blue, 30)
                XCTAssertEqual(color.alpha, 200.0 * cumulativeAlpha / 255.0, accuracy: 0.000_001)
            } else {
                XCTAssertEqual(clip, viewportClip)
                XCTAssertEqual(color.red, 40)
                XCTAssertEqual(color.green, 50)
                XCTAssertEqual(color.blue, 60)
                XCTAssertEqual(color.alpha, 160.0 * cumulativeAlpha / 255.0, accuracy: 0.000_001)
            }
        }
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

    func testSetVisibleUsesNativeLuaTruthConversionForStockTreeNodes() throws {
        let state = LuaState(output: { _ in })
        let typeSystem = try GMLuaTypeSystem.install(
            into: state,
            utilityLayer: .bundledFallback
        )
        _ = try GMLuaVGUI.install(into: state, typeSystem: typeSystem)
        try state.execute(
            """
            PANEL = vgui.Create("Panel")
            PANEL:SetVisible(nil)
            assert(PANEL:IsVisible() == false)
            PANEL:SetVisible(1)
            assert(PANEL:IsVisible() == true)
            PANEL:SetVisible(false)
            assert(PANEL:IsVisible() == false)
            """,
            sourceName: "@GMLuaSetVisibleTruthinessRegression.lua"
        )
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

    func testTopLevelGetParentProjectsLiveWorldPanelForStockCenterHelpers()
        throws
    {
        let runtime = GMLuaRuntime(
            realm: .menu,
            logger: { _ in },
            initialViewport: GMLuaViewportSize(width: 640, height: 480)
        )
        defer { _ = runtime.close() }

        try runtime.execute(
            """
            local meta = assert(FindMetaTable("Panel"))
            function meta:GetX()
                local x = self:GetPos()
                return x
            end
            function meta:GetY()
                local _, y = self:GetPos()
                return y
            end
            function meta:SetX(x) self:SetPos(x, self:GetY()) end
            function meta:SetY(y) self:SetPos(self:GetX(), y) end
            function meta:CenterVertical(fraction)
                self:SetY(
                    self:GetParent():GetTall() * (fraction or 0.5)
                    - self:GetTall() * 0.5
                )
            end

            local world = assert(vgui.GetWorldPanel())
            assert(world:IsValid())
            assert(world:GetParent() == nil)
            assert(world:GetWide() == 640 and world:GetTall() == 480)

            ROOT = assert(vgui.Create("Panel"))
            ROOT:SetSize(100, 40)
            assert(ROOT:GetParent() == world)
            assert(ROOT:HasParent(world))
            assert(world:ChildCount() == 1)
            local HUD_ROOT = assert(vgui.Create("Panel"))
            local HUD_CHILD = assert(vgui.Create("Panel", HUD_ROOT))
            HUD_ROOT:ParentToHUD()
            assert(HUD_ROOT:GetParent() == nil)
            assert(not HUD_ROOT:HasParent(world))
            assert(not HUD_CHILD:HasParent(world))
            HUD_ROOT:SetParent(world)
            assert(HUD_ROOT:GetParent() == world)
            assert(HUD_ROOT:HasParent(world))
            assert(HUD_CHILD:HasParent(world))
            ROOT:CenterVertical()
            assert(ROOT:GetY() == 220)
            """,
            sourceName: "@GMLuaWorldPanelCenterRegression.lua"
        )

        XCTAssertTrue(runtime.updateViewport(width: 800, height: 600))
        try runtime.execute(
            """
            assert(vgui.GetWorldPanel():GetTall() == 600)
            ROOT:CenterVertical()
            assert(ROOT:GetY() == 280)
            """,
            sourceName: "@GMLuaWorldPanelResizeRegression.lua"
        )
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

    func testSizeToChildrenDispatchesChangedFinalSizeAndSameSizeIsNoOp() throws {
        let state = LuaState(output: { _ in })
        let typeSystem = try GMLuaTypeSystem.install(
            into: state,
            utilityLayer: .bundledFallback
        )
        _ = try GMLuaVGUI.install(into: state, typeSystem: typeSystem)

        try state.execute(
            """
            local panelMeta = FindMetaTable("Panel")
            local PROBE = {}
            function PROBE:OnSizeChanged(width, height)
                SIZE_TO_CHILDREN_CALLS = (SIZE_TO_CHILDREN_CALLS or 0) + 1
                SIZE_TO_CHILDREN_WIDTH = width
                SIZE_TO_CHILDREN_HEIGHT = height
                panelMeta.OnSizeChanged(self, width, height)
            end
            vgui.Register("SizeToChildrenProbe", PROBE, "Panel")

            local parent = vgui.Create("SizeToChildrenProbe")
            parent:SetSize(320, 240)
            SIZE_TO_CHILDREN_CALLS = 0

            local child = vgui.Create("Panel", parent)
            child:SetPos(10, 20)
            child:SetSize(50, 70)

            parent:SizeToChildren(false, true)
            assert(SIZE_TO_CHILDREN_CALLS == 1)
            assert(SIZE_TO_CHILDREN_WIDTH == 320 and SIZE_TO_CHILDREN_HEIGHT == 90)
            assert(parent:GetWide() == 320 and parent:GetTall() == 90)

            parent:SizeToChildren(false, true)
            assert(SIZE_TO_CHILDREN_CALLS == 1)
            """,
            sourceName: "@GMLuaPanelSizeToChildrenCallbackRegression.lua"
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
            assert(vgui.GetHoveredPanel() == nil)
            assert(vgui.GetKeyboardFocus() == nil)
            """,
            sourceName: "@GMLuaPanelInputRegression.lua"
        )

        let began = try registry.dispatchPointerEvent(
            x: 120, y: 220, phase: .began, timestamp: 1,
            viewportWidth: 810, viewportHeight: 1080
        )
        XCTAssertEqual(began.callbackNames, ["OnCursorEntered", "OnMousePressed"])
        try state.execute(
            """
            assert(vgui.GetHoveredPanel() == BUTTON_PANEL)
            assert(vgui.GetKeyboardFocus() == BUTTON_PANEL)
            """,
            sourceName: "@GMLuaPanelHoveredAndFocusButtonCheckpoint.lua"
        )
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
            assert(vgui.GetHoveredPanel() == ENTRY)
            assert(vgui.GetKeyboardFocus() == ENTRY)
            ENTRY:Remove()
            assert(vgui.GetHoveredPanel() == nil)
            assert(vgui.GetKeyboardFocus() == nil)
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

    func testTextEntryCaretTracksSetTextSetCaretAndHostInsertion() throws {
        let state = LuaState(output: { _ in })
        let typeSystem = try GMLuaTypeSystem.install(
            into: state,
            utilityLayer: .bundledFallback
        )
        let registry = try GMLuaVGUI.install(into: state, typeSystem: typeSystem)
        try state.execute(
            """
            local STOCK_SHAPED = {}
            function STOCK_SHAPED:SetValue(strValue)
                -- Exact caret-preservation sequence from bundled dtextentry.lua.
                local caretPos = self:GetCaretPos()
                self:SetText(strValue)
                self:SetCaretPos(caretPos)
            end
            vgui.Register("CaretPreservingTextEntry", STOCK_SHAPED, "TextEntry")

            CARET_ENTRY = assert(vgui.Create("CaretPreservingTextEntry"))
            assert(CARET_ENTRY:GetCaretPos() == 0)
            CARET_ENTRY:SetText("A日本B")
            assert(CARET_ENTRY:GetCaretPos() == 0)
            assert(select("#", CARET_ENTRY:SetCaretPos(2)) == 0)
            assert(CARET_ENTRY:GetCaretPos() == 2)

            CARET_ENTRY:SetValue("A日本B")
            assert(CARET_ENTRY:GetCaretPos() == 2)
            CARET_ENTRY:SetCaretPos(-100)
            assert(CARET_ENTRY:GetCaretPos() == 0)
            CARET_ENTRY:SetCaretPos(100)
            assert(CARET_ENTRY:GetCaretPos() == 4)
            CARET_ENTRY:SetCaretPos(1.9)
            assert(CARET_ENTRY:GetCaretPos() == 1)
            CARET_ENTRY:SetCaretPos(2)
            CARET_ENTRY:SetAllowNonAsciiCharacters(true)

            local panel = assert(vgui.Create("Panel"))
            assert(pcall(panel.GetCaretPos, panel) == false)
            assert(pcall(CARET_ENTRY.SetCaretPos, CARET_ENTRY, "2") == false)
            """,
            sourceName: "@GMLuaTextEntryCaretMutationSetup.lua"
        )
        try state.execute(
            "CARET_ENTRY:RequestFocus()",
            sourceName: "@GMLuaTextEntryCaretMutationFocus.lua"
        )
        XCTAssertNotNil(try registry.insertText("語"))
        try state.execute(
            """
            assert(CARET_ENTRY:GetText() == "A日語本B")
            assert(CARET_ENTRY:GetCaretPos() == 3)
            CARET_ENTRY:SetAllowNonAsciiCharacters(false)
            CARET_ENTRY:SetCaretPos(1)
            """,
            sourceName: "@GMLuaTextEntryCaretUnicodeInsertion.lua"
        )
        XCTAssertNotNil(try registry.insertText("XテY"))
        try state.execute(
            """
            assert(CARET_ENTRY:GetText() == "AXY日語本B")
            assert(CARET_ENTRY:GetCaretPos() == 3)
            """,
            sourceName: "@GMLuaTextEntryCaretRestrictedInsertion.lua"
        )
        let snapshot = try XCTUnwrap(registry.textPanelStateSnapshots.first(where: {
            $0.requestedClassName == "CaretPreservingTextEntry"
        }))
        XCTAssertEqual(snapshot.caretPosition, 3)
    }

    func testStockTextEntryPaintUsesCurrentValueInsetColorsAndPanelClip() throws {
        let state = LuaState(output: { _ in })
        let typeSystem = try GMLuaTypeSystem.install(
            into: state,
            utilityLayer: .bundledFallback
        )
        let surface = try GMLuaSurface.install(
            into: state,
            maximumDrawCommandCount: 2
        )
        let registry = try GMLuaVGUI.install(
            into: state,
            typeSystem: typeSystem,
            surfaceCommandState: surface
        )
        try state.execute(
            """
            function Color(r, g, b, a)
                return { r = r, g = g, b = b, a = a }
            end

            local ENABLED = Color(11, 22, 33, 201)
            local DISABLED = Color(44, 55, 66, 151)
            local HIGHLIGHT = Color(77, 88, 99, 101)
            local CURSOR = Color(111, 122, 133, 51)
            local ENTRY = {}
            function ENTRY:Paint()
                local textColor = self:IsEnabled() and ENABLED or DISABLED
                -- Exact call shape used by default.lua:PaintTextEntry.
                self:DrawTextEntryText(textColor, HIGHLIGHT, CURSOR)
                return true
            end
            vgui.Register("StockPaintTextEntryProbe", ENTRY, "TextEntry")

            TEXT_ROOT = assert(vgui.Create("Panel"))
            TEXT_ROOT:SetSize(200, 100)
            TEXT_ENTRY = assert(vgui.Create("StockPaintTextEntryProbe", TEXT_ROOT))
            TEXT_ENTRY:SetPos(10, 20)
            TEXT_ENTRY:SetSize(120, 24)
            TEXT_ENTRY:SetFont("DermaDefault")
            TEXT_ENTRY:SetTextInset(4, 2)
            TEXT_ENTRY:SetText("Search")
            """,
            sourceName: "@GMLuaDefaultSkinTextEntryPaintRegression.lua"
        )

        let enabledFrame = try registry.renderFrame(
            surface: surface,
            viewportWidth: 200,
            viewportHeight: 100
        )
        XCTAssertEqual(enabledFrame.captureDiagnostics.attemptedCommandCount, 1)
        XCTAssertEqual(enabledFrame.captureDiagnostics.droppedCommandCount, 0)
        guard case let .text(value, position, font, color, clip) =
                try XCTUnwrap(enabledFrame.commands.first) else {
            return XCTFail("DrawTextEntryText did not retain one text command")
        }
        XCTAssertEqual(value, LuaString("Search"))
        XCTAssertEqual(font.name, LuaString("DermaDefault"))
        XCTAssertEqual(position.x, 14)
        XCTAssertEqual(position.y, 27)
        XCTAssertEqual(color, GMLuaSurfaceColor(red: 11, green: 22, blue: 33, alpha: 201))
        XCTAssertEqual(clip, GMLuaPanelRect(x: 10, y: 20, width: 120, height: 24))

        try state.execute(
            "TEXT_ENTRY:SetEnabled(false)",
            sourceName: "@GMLuaDisabledTextEntryPaintColor.lua"
        )
        let disabledFrame = try registry.renderFrame(
            surface: surface,
            viewportWidth: 200,
            viewportHeight: 100
        )
        guard case let .text(_, _, _, disabledColor, _) =
                try XCTUnwrap(disabledFrame.commands.first) else {
            return XCTFail("disabled DrawTextEntryText did not retain text")
        }
        XCTAssertEqual(
            disabledColor,
            GMLuaSurfaceColor(red: 44, green: 55, blue: 66, alpha: 151)
        )

        try state.execute(
            "TEXT_ENTRY:SetEnabled(true); TEXT_ENTRY:RequestFocus()",
            sourceName: "@GMLuaFocusedTextEntryMissingCaretState.lua"
        )
        let focusedFrame = try registry.renderFrame(
            surface: surface,
            viewportWidth: 200,
            viewportHeight: 100
        )
        XCTAssertEqual(focusedFrame.captureDiagnostics.attemptedCommandCount, 2)
        XCTAssertEqual(focusedFrame.captureDiagnostics.droppedCommandCount, 0)
        XCTAssertEqual(focusedFrame.commands.count, 2)
        guard case let .rectangle(caretFrame, caretColor, _) = focusedFrame.commands[1] else {
            return XCTFail("focused TextEntry did not emit a caret rectangle")
        }
        XCTAssertEqual(caretFrame.width, 1)
        XCTAssertGreaterThan(caretFrame.height, 0)
        XCTAssertEqual(
            caretColor,
            GMLuaSurfaceColor(red: 111, green: 122, blue: 133, alpha: 51)
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

    func testLocalAndScreenCoordinatesRoundTripThroughNestedPanelHierarchy() throws {
        let state = LuaState(output: { _ in })
        let typeSystem = try GMLuaTypeSystem.install(
            into: state,
            utilityLayer: .bundledFallback
        )
        _ = try GMLuaVGUI.install(into: state, typeSystem: typeSystem)

        try state.execute(
            """
            local root = vgui.Create("Panel")
            root:SetPos(10, 20)

            local child = vgui.Create("Panel", root)
            child:SetPos(30, 40)

            local grandchild = vgui.Create("Panel", child)
            grandchild:SetPos(5, 6)

            local screenX, screenY = grandchild:LocalToScreen(2, 3)
            assert(screenX == 47 and screenY == 69)

            local localX, localY = grandchild:ScreenToLocal(screenX, screenY)
            assert(localX == 2 and localY == 3)

            local childScreenX, childScreenY = child:LocalToScreen(-4, 8)
            assert(childScreenX == 36 and childScreenY == 68)
            local childLocalX, childLocalY = child:ScreenToLocal(36, 68)
            assert(childLocalX == -4 and childLocalY == 8)

            assert(pcall(grandchild.LocalToScreen, grandchild, 0 / 0, 0) == false)
            assert(pcall(grandchild.ScreenToLocal, grandchild, 0, math.huge) == false)

            grandchild:Remove()
            assert(pcall(grandchild.LocalToScreen, grandchild, 0, 0) == false)
            """,
            sourceName: "@GMLuaPanelCoordinateTransformRegression.lua"
        )
    }

    func testReparentDispatchesChildCallbacksAfterNewRelationshipIsObservable() throws {
        let state = LuaState(output: { _ in })
        let typeSystem = try GMLuaTypeSystem.install(
            into: state,
            utilityLayer: .bundledFallback
        )
        _ = try GMLuaVGUI.install(into: state, typeSystem: typeSystem)

        try state.execute(
            """
            local PROBE = {}
            function PROBE:OnChildAdded(child)
                local parent = child:GetParent()
                PARENT_CHANGE_LOG[#PARENT_CHANGE_LOG + 1] =
                    self:GetName() .. ":added:" .. parent:GetName()
                -- DListLayout uses this exact callback to dock every child.
                child:Dock(TOP)
            end
            function PROBE:OnChildRemoved(child)
                local parent = child:GetParent()
                PARENT_CHANGE_LOG[#PARENT_CHANGE_LOG + 1] =
                    self:GetName() .. ":removed:" ..
                    (IsValid(parent) and parent:GetName() or "nil")
            end
            vgui.Register("ParentChangeProbe", PROBE, "Panel")

            local oldParent = vgui.Create("ParentChangeProbe")
            oldParent:SetName("old")
            local newParent = vgui.Create("ParentChangeProbe")
            newParent:SetName("new")
            local child = vgui.Create("Panel")

            PARENT_CHANGE_LOG = {}
            child:SetParent(oldParent)
            assert(table.concat(PARENT_CHANGE_LOG, "|") == "old:added:old")
            assert(child:GetDock() == TOP)

            PARENT_CHANGE_LOG = {}
            child:SetParent(newParent)
            assert(table.concat(PARENT_CHANGE_LOG, "|") ==
                "old:removed:new|new:added:new")

            -- Reapplying the same parent is a native no-op.
            child:SetParent(newParent)
            assert(#PARENT_CHANGE_LOG == 2)

            PARENT_CHANGE_LOG = {}
            child:SetParent(nil)
            assert(table.concat(PARENT_CHANGE_LOG, "|") ==
                "new:removed:WorldPanel")
            assert(child:GetParent() == vgui.GetWorldPanel())
            """,
            sourceName: "@GMLuaPanelParentChangeCallbackRegression.lua"
        )
    }
}
