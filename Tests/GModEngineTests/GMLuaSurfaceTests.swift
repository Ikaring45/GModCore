import Foundation
import XCTest
import GModEngine
import GModLua

final class GMLuaSurfaceTests: XCTestCase {
    func testPlaySoundCapturesOrderedBoundedRequestsForAppAudioHandoff() throws {
        let state = LuaState(output: { _ in })
        let surface = try GMLuaSurface.install(
            into: state,
            maximumSoundRequestCount: 2,
            maximumEstimatedSoundRequestByteCount: 1_024
        )

        try state.execute(
            """
            assert(select("#", surface.PlaySound("ui/buttonclickrelease.wav")) == 0)
            surface.PlaySound("ui/buttonclickrelease.wav")
            surface.PlaySound("ui/overflow.wav")

            assert(not pcall(surface.PlaySound, ""))
            assert(not pcall(surface.PlaySound, "../outside.wav"))
            assert(not pcall(surface.PlaySound, "/absolute.wav"))
            assert(not pcall(surface.PlaySound, "C:\\absolute.wav"))
            assert(not pcall(surface.PlaySound, "ui/" .. string.char(0) .. ".wav"))
            assert(not pcall(surface.PlaySound, {}))
            """,
            sourceName: "@GMLuaSurfacePlaySoundBoundedCapture.lua"
        )

        var report = surface.pendingSoundRequestReport
        XCTAssertEqual(report.requests.count, 2)
        XCTAssertEqual(
            report.requests.map(\.soundPath),
            ["ui/buttonclickrelease.wav", "ui/buttonclickrelease.wav"]
        )
        XCTAssertEqual(report.requests.map(\.sequenceNumber), [0, 1])
        XCTAssertEqual(report.requests.map(\.frameNumber), [0, 0])
        XCTAssertEqual(report.requests.map(\.eventIndex), [0, 1])
        XCTAssertTrue(report.requests.allSatisfy { !$0.hasAudioBacking })
        XCTAssertEqual(report.diagnostics.attemptedRequestCount, 3)
        XCTAssertEqual(report.diagnostics.retainedRequestCount, 2)
        XCTAssertEqual(report.diagnostics.droppedRequestCount, 1)
        XCTAssertEqual(report.diagnostics.maximumRequestCount, 2)
        XCTAssertTrue(report.diagnostics.overflowed)

        XCTAssertEqual(surface.drainSoundRequestReport(), report)
        report = surface.pendingSoundRequestReport
        XCTAssertTrue(report.requests.isEmpty)
        XCTAssertEqual(report.diagnostics.attemptedRequestCount, 0)
        XCTAssertFalse(report.diagnostics.overflowed)

        surface.beginFrame(viewportWidth: 320, viewportHeight: 180)
        try state.execute(
            "surface.PlaySound('ui/nextframe.wav')",
            sourceName: "@GMLuaSurfacePlaySoundNextFrame.lua"
        )
        report = surface.drainSoundRequestReport()
        let nextFrame = try XCTUnwrap(report.requests.first)
        XCTAssertEqual(nextFrame.soundPath, "ui/nextframe.wav")
        XCTAssertEqual(nextFrame.sequenceNumber, 3)
        XCTAssertEqual(nextFrame.frameNumber, 1)
        XCTAssertEqual(nextFrame.eventIndex, 0)
        XCTAssertFalse(nextFrame.hasAudioBacking)
    }

    func testStableTextureHandlesAndSelectedTextureState() throws {
        let fixtureURL = try XCTUnwrap(
            Bundle.module.url(
                forResource: "GLuaSurfaceRegression",
                withExtension: "lua",
                subdirectory: "Fixtures"
            ) ?? Bundle.module.url(
                forResource: "GLuaSurfaceRegression",
                withExtension: "lua"
            )
        )
        let source = try String(contentsOf: fixtureURL, encoding: .utf8)
        let state = LuaState(output: { _ in })
        let commandState = try GMLuaSurface.install(into: state)

        try state.execute(source, sourceName: "@GLuaSurfaceRegression.lua")
        guard case let .number(selected) = state.getGlobal("SURFACE_SELECTED_TEXTURE") else {
            return XCTFail("surface fixture did not expose its selected texture")
        }
        XCTAssertEqual(commandState.selectedTextureID, Int(selected))
        XCTAssertEqual(commandState.allocatedTextureCount, 2)
        XCTAssertEqual(commandState.customFontCount, 1)
        XCTAssertEqual(commandState.selectedFontName, "Trebuchet24")
        XCTAssertEqual(commandState.textMeasurementFidelity, .logicalEstimate)
        let descriptor = try XCTUnwrap(
            commandState.fontDescriptor(named: "mixedcasefont")
        )
        XCTAssertEqual(descriptor.name, "MIXEDCASEFONT")
        XCTAssertEqual(descriptor.font, "Helvetica")
        XCTAssertEqual(descriptor.size, 22)
        XCTAssertEqual(descriptor.weight, 800)
        XCTAssertEqual(descriptor.blurSize, 3)
        XCTAssertEqual(descriptor.scanlines, 2)
        XCTAssertTrue(descriptor.extended)
        XCTAssertFalse(descriptor.antialias)
        XCTAssertTrue(descriptor.underline)
        XCTAssertTrue(descriptor.italic)
        XCTAssertTrue(descriptor.strikeout)
        XCTAssertTrue(descriptor.symbol)
        XCTAssertTrue(descriptor.rotary)
        XCTAssertTrue(descriptor.shadow)
        XCTAssertTrue(descriptor.additive)
        XCTAssertTrue(descriptor.outline)
        XCTAssertEqual(descriptor.origin, .customUnresolved)
        XCTAssertFalse(descriptor.hasPlatformFontBacking)
        guard case .boolean(true) = state.getGlobal("GLUA_SURFACE_REGRESSION_OK") else {
            return XCTFail("surface regression fixture did not reach its success sentinel")
        }
    }

    func testTextureHandleRegistriesAreStateLocal() throws {
        let firstState = LuaState(output: { _ in })
        let firstCommands = try GMLuaSurface.install(into: firstState)
        try firstState.execute(
            "FIRST_A = surface.GetTextureID('a'); FIRST_B = surface.GetTextureID('b')",
            sourceName: "@GMLuaSurfaceFirstState.lua"
        )

        let secondState = LuaState(output: { _ in })
        let secondCommands = try GMLuaSurface.install(into: secondState)
        try secondState.execute(
            "SECOND_B = surface.GetTextureID('b')",
            sourceName: "@GMLuaSurfaceSecondState.lua"
        )

        guard case let .number(firstA) = firstState.getGlobal("FIRST_A"),
              case let .number(firstB) = firstState.getGlobal("FIRST_B"),
              case let .number(secondB) = secondState.getGlobal("SECOND_B") else {
            return XCTFail("texture IDs were not numeric")
        }
        XCTAssertEqual(firstA, 1)
        XCTAssertEqual(firstB, 2)
        XCTAssertEqual(secondB, 1)
        XCTAssertEqual(firstCommands.allocatedTextureCount, 2)
        XCTAssertEqual(secondCommands.allocatedTextureCount, 1)
    }

    func testFontDataDefaultsRangesOverwriteAndStateIsolation() throws {
        let firstState = LuaState(output: { _ in })
        let firstCommands = try GMLuaSurface.install(into: firstState)
        try firstState.execute(
            """
            surface.CreateFont("RangeFont", { size = 1, blursize = 999 })
            surface.CreateFont("rangefont", { size = 999, blursize = -4 })
            surface.CreateFont("HugeFiniteFont", { size = 9223372036854775808 })
            """,
            sourceName: "@GMLuaSurfaceFontRanges.lua"
        )
        let firstDescriptor = try XCTUnwrap(
            firstCommands.fontDescriptor(named: "RANGEFONT")
        )
        let hugeDescriptor = try XCTUnwrap(
            firstCommands.fontDescriptor(named: "HugeFiniteFont")
        )
        XCTAssertEqual(firstCommands.customFontCount, 2)
        XCTAssertEqual(firstDescriptor.font, "Arial")
        XCTAssertEqual(firstDescriptor.size, 255)
        XCTAssertEqual(firstDescriptor.weight, 500)
        XCTAssertEqual(firstDescriptor.blurSize, 0)
        XCTAssertTrue(firstDescriptor.antialias)
        XCTAssertEqual(hugeDescriptor.size, 255)

        let secondState = LuaState(output: { _ in })
        let secondCommands = try GMLuaSurface.install(into: secondState)
        XCTAssertNil(secondCommands.fontDescriptor(named: "RangeFont"))
        XCTAssertEqual(secondCommands.customFontCount, 0)
        XCTAssertNotNil(secondCommands.fontDescriptor(named: "default"))
        XCTAssertGreaterThan(secondCommands.registeredFontCount, 40)
    }

    func testPersistentTextureRegistryRejectsOnlyNewUniqueNamesAndSurvivesFrames() throws {
        let state = LuaState(output: { _ in })
        let surface = try GMLuaSurface.install(
            into: state,
            maximumPersistentTextureCount: 2
        )
        try state.execute(
            """
            TEXTURE_A = surface.GetTextureID("persistent/a")
            TEXTURE_B = surface.GetTextureID("persistent/b")
            TEXTURE_A_AGAIN = surface.GetTextureID("persistent/a")
            """,
            sourceName: "@GMLuaSurfacePersistentTextureBudget.lua"
        )
        guard case let .number(textureA) = state.getGlobal("TEXTURE_A"),
              case let .number(textureB) = state.getGlobal("TEXTURE_B"),
              case let .number(textureAAgain) = state.getGlobal("TEXTURE_A_AGAIN") else {
            return XCTFail("persistent texture handles were not numeric")
        }
        XCTAssertEqual(textureA, 1)
        XCTAssertEqual(textureB, 2)
        XCTAssertEqual(textureAAgain, textureA)

        surface.beginFrame(viewportWidth: 100, viewportHeight: 100)
        try state.execute(
            "TEXTURE_B_AFTER_FRAME = surface.GetTextureID('persistent/b')",
            sourceName: "@GMLuaSurfacePersistentTextureAfterFrame.lua"
        )
        guard case let .number(textureBAfterFrame) = state.getGlobal(
            "TEXTURE_B_AFTER_FRAME"
        ) else {
            return XCTFail("texture handle did not survive beginFrame")
        }
        XCTAssertEqual(textureBAfterFrame, textureB)

        XCTAssertThrowsError(
            try state.execute(
                "surface.GetTextureID('persistent/overflow')",
                sourceName: "@GMLuaSurfacePersistentTextureOverflow.lua"
            )
        ) { error in
            XCTAssertTrue(
                String(describing: error).contains(
                    "persistent texture registry limit (2) exceeded"
                )
            )
        }
        // A failed new registration must not poison already-issued handles.
        try state.execute(
            "TEXTURE_A_AFTER_OVERFLOW = surface.GetTextureID('persistent/a')"
        )
        guard case let .number(textureAAfterOverflow) = state.getGlobal(
            "TEXTURE_A_AFTER_OVERFLOW"
        ) else {
            return XCTFail("existing handle was unavailable after overflow")
        }
        XCTAssertEqual(textureAAfterOverflow, textureA)

        let diagnostics = surface.persistentResourceDiagnostics
        XCTAssertEqual(diagnostics.allocatedTextureCount, 2)
        XCTAssertEqual(diagnostics.maximumTextureCount, 2)
        XCTAssertEqual(diagnostics.rejectedTextureRegistrationCount, 1)
        XCTAssertEqual(diagnostics.rejectedFontRegistrationCount, 0)
        XCTAssertEqual(
            diagnostics.overflowPolicy,
            .rejectNewUniqueRegistrationWithLuaRuntimeError
        )
        XCTAssertTrue(diagnostics.overflowed)
    }

    func testPersistentFontRegistryAllowsSameNameOverwriteButRejectsNewUniqueName() throws {
        let state = LuaState(output: { _ in })
        let surface = try GMLuaSurface.install(
            into: state,
            maximumCustomFontCount: 2
        )
        let initialRegisteredFontCount = surface.registeredFontCount
        try state.execute(
            """
            surface.CreateFont("PersistentA", { size = 10 })
            surface.CreateFont("persistenta", { size = 20 })
            surface.CreateFont("PersistentB", { size = 30 })
            """,
            sourceName: "@GMLuaSurfacePersistentFontBudget.lua"
        )
        XCTAssertEqual(surface.customFontCount, 2)
        XCTAssertEqual(surface.registeredFontCount, initialRegisteredFontCount + 2)
        XCTAssertEqual(surface.fontDescriptor(named: "PERSISTENTA")?.size, 20)

        surface.beginFrame(viewportWidth: 100, viewportHeight: 100)
        try state.execute(
            "surface.CreateFont('PERSISTENTB', { size = 40 })",
            sourceName: "@GMLuaSurfacePersistentFontAfterFrame.lua"
        )
        XCTAssertEqual(surface.fontDescriptor(named: "persistentb")?.size, 40)

        XCTAssertThrowsError(
            try state.execute(
                "surface.CreateFont('PersistentOverflow', { size = 50 })",
                sourceName: "@GMLuaSurfacePersistentFontOverflow.lua"
            )
        ) { error in
            XCTAssertTrue(
                String(describing: error).contains(
                    "persistent custom font registry limit (2) exceeded"
                )
            )
        }
        // Re-registering a known canonical name remains idempotent at capacity.
        try state.execute(
            "surface.CreateFont('PersistentA', { size = 60 })"
        )
        XCTAssertEqual(surface.fontDescriptor(named: "persistenta")?.size, 60)

        let diagnostics = surface.persistentResourceDiagnostics
        XCTAssertEqual(diagnostics.customFontCount, 2)
        XCTAssertEqual(diagnostics.maximumCustomFontCount, 2)
        XCTAssertEqual(
            diagnostics.registeredFontCount,
            initialRegisteredFontCount + 2
        )
        XCTAssertEqual(
            diagnostics.maximumRegisteredFontCount,
            initialRegisteredFontCount + 2
        )
        XCTAssertEqual(diagnostics.rejectedTextureRegistrationCount, 0)
        XCTAssertEqual(diagnostics.rejectedFontRegistrationCount, 1)
        XCTAssertTrue(diagnostics.overflowed)
    }

    func testInjectedPlatformMeasurementBoundaryDrivesLuaResults() throws {
        struct ProbeMeasurer: GMLuaTextMeasurer {
            let fidelity = GMLuaTextMeasurementFidelity.platformGlyphMetrics

            func measure(
                _ text: LuaString,
                using font: GMLuaFontDescriptor
            ) -> GMLuaTextMeasurement {
                GMLuaTextMeasurement(
                    width: text.count * 100 + font.size,
                    height: 777
                )
            }
        }

        let state = LuaState(output: { _ in })
        let commands = try GMLuaSurface.install(
            into: state,
            textMeasurer: ProbeMeasurer()
        )
        try state.execute(
            """
            surface.CreateFont("Probe", { size = 20 })
            surface.SetFont("Probe")
            PROBE_W, PROBE_H = surface.GetTextSize("abc")
            """,
            sourceName: "@GMLuaSurfaceInjectedMetrics.lua"
        )
        guard case let .number(width) = state.getGlobal("PROBE_W"),
              case let .number(height) = state.getGlobal("PROBE_H") else {
            return XCTFail("injected text metrics were not returned to Lua")
        }
        XCTAssertEqual(width, 320)
        XCTAssertEqual(height, 777)
        XCTAssertEqual(commands.textMeasurementFidelity, .platformGlyphMetrics)
    }

    func testSourceFontTallMetricScalingIsPlatformIndependentAndExactPerLine() {
        XCTAssertEqual(
            GMLuaSourceFontTallMetrics.scaledPointSize(
                unscaledPointSize: 13,
                unscaledLineHeight: 15.6,
                requestedTall: 13
            ),
            10.833_333_333_333_334,
            accuracy: 0.000_000_000_001
        )
        XCTAssertEqual(
            GMLuaSourceFontTallMetrics.scaledPointSize(
                unscaledPointSize: .nan,
                unscaledLineHeight: 0,
                requestedTall: 20
            ),
            20
        )
        XCTAssertEqual(
            GMLuaSourceFontTallMetrics.exactTextHeight(
                lineCount: 0,
                requestedTall: 13
            ),
            13
        )
        XCTAssertEqual(
            GMLuaSourceFontTallMetrics.exactTextHeight(
                lineCount: 2,
                requestedTall: 13
            ),
            26
        )
        XCTAssertEqual(
            GMLuaSourceFontTallMetrics.exactTextHeight(
                lineCount: 2,
                requestedTall: 20
            ),
            40
        )
    }

    func testRuntimeForwardsInjectedTextMeasurerToSurfaceAndVGUI() throws {
        struct RuntimeProbeMeasurer: GMLuaTextMeasurer {
            let fidelity = GMLuaTextMeasurementFidelity.platformGlyphMetrics

            func measure(
                _ text: LuaString,
                using font: GMLuaFontDescriptor
            ) -> GMLuaTextMeasurement {
                GMLuaTextMeasurement(
                    width: text.count * 10 + font.size,
                    height: font.size + 3
                )
            }
        }

        let runtime = GMLuaRuntime(
            realm: .client,
            logger: { _ in },
            textMeasurer: RuntimeProbeMeasurer()
        )
        try runtime.execute(
            """
            surface.CreateFont("RuntimeProbe", { size = 20 })
            surface.SetFont("RuntimeProbe")
            RUNTIME_SURFACE_W, RUNTIME_SURFACE_H = surface.GetTextSize("abc")

            local label = assert(vgui.Create("Label"))
            label:SetFontInternal("RuntimeProbe")
            label:SetText("abcd")
            RUNTIME_LABEL_W, RUNTIME_LABEL_H = label:GetContentSize()
            """,
            sourceName: "@GMLuaRuntimeInjectedTextMeasurer.lua"
        )
        let values = try runtime.executeReturningValues(
            """
            return RUNTIME_SURFACE_W, RUNTIME_SURFACE_H,
                   RUNTIME_LABEL_W, RUNTIME_LABEL_H
            """,
            sourceName: "@GMLuaRuntimeInjectedTextMeasurerResults.lua"
        )
        guard values.count == 4,
              case let .number(surfaceWidth) = values[0],
              case let .number(surfaceHeight) = values[1],
              case let .number(labelWidth) = values[2],
              case let .number(labelHeight) = values[3] else {
            return XCTFail("runtime probe metrics were not numeric")
        }
        XCTAssertEqual(surfaceWidth, 50)
        XCTAssertEqual(surfaceHeight, 23)
        XCTAssertEqual(labelWidth, 60)
        XCTAssertEqual(labelHeight, 23)
        XCTAssertEqual(
            try XCTUnwrap(runtime.surfaceCommandState).textMeasurementFidelity,
            .platformGlyphMetrics
        )
    }

    func testRuntimeInstallsSurfaceOnlyInClientCapableRealms() throws {
        for realm in [GMLuaRealm.client, .menu] {
            let runtime = GMLuaRuntime(
                realm: realm,
                logger: { _ in },
                bootstrapMode: .strict
            )
            try runtime.execute(
                """
                assert(type(surface) == "table")
                assert(surface.GetTextureID("gui/corner8") > 0)
                surface.CreateFont("RuntimeFont", { font = "Helvetica", size = 22 })
                surface.SetFont("runtimefont")
                local width, height = surface.GetTextSize("abcd")
                assert(width == 44 and height == 22)
                """,
                sourceName: "@GMLuaSurfaceRealmBootstrap.lua"
            )
            XCTAssertNotNil(runtime.surfaceCommandState)
        }

        let server = GMLuaRuntime(
            realm: .server,
            logger: { _ in },
            bootstrapMode: .strict
        )
        try server.execute(
            "assert(surface == nil)",
            sourceName: "@GMLuaSurfaceServerAbsence.lua"
        )
        XCTAssertNil(server.surfaceCommandState)
    }

    func testRuntimeSharesSurfaceFontCatalogWithVGUIWithoutChangingSurfaceSelection() throws {
        let runtime = GMLuaRuntime(
            realm: .client,
            logger: { _ in },
            bootstrapMode: .strict
        )
        try runtime.execute(
            """
            surface.CreateFont("RuntimeLabelShared", { size = 22 })
            surface.SetFont("Default")

            local label = assert(vgui.Create("Label"))
            label:SetFontInternal("runtimelabelshared")
            label:SetText("abcd")
            local labelWidth, labelHeight = label:GetContentSize()
            assert(labelWidth == 44 and labelHeight == 22)

            local surfaceWidth, surfaceHeight = surface.GetTextSize("abcd")
            assert(surfaceWidth == 26 and surfaceHeight == 13)
            """,
            sourceName: "@GMLuaRuntimeSharedSurfaceVGUIFontCatalog.lua"
        )
        XCTAssertEqual(
            try XCTUnwrap(runtime.surfaceCommandState).selectedFontName,
            LuaString("Default")
        )
    }

    func testPanelPaintProducesClippedRendererCommandsWithoutClaimingGPUBacking() throws {
        let runtime = GMLuaRuntime(
            realm: .client,
            logger: { _ in },
            bootstrapMode: .strict
        )
        try runtime.execute(
            """
            ROOT = vgui.Create("Panel")
            ROOT:SetSize(810, 1080)
            function ROOT:Paint(w, h)
                surface.SetDrawColor(20, 30, 40, 200)
                surface.DrawRect(0, 0, w, h)
            end

            TITLE = vgui.Create("Label", ROOT)
            TITLE:SetPos(30, 40)
            TITLE:SetSize(300, 50)
            TITLE:SetText("Sandbox")
            TITLE:SetFGColor(230, 240, 250, 255)

            ICON = vgui.Create("Panel", ROOT)
            ICON:SetPos(40, 120)
            ICON:SetSize(64, 64)
            ICON:SetImage("icon16/brick.png")
            """,
            sourceName: "@GMLuaSurfacePanelPaintRegression.lua"
        )
        let registry = try XCTUnwrap(runtime.vguiRegistry)
        let surface = try XCTUnwrap(runtime.surfaceCommandState)
        let frame = try registry.renderFrame(
            surface: surface,
            viewportWidth: 810,
            viewportHeight: 1080
        )

        XCTAssertEqual(frame.viewportWidth, 810)
        XCTAssertEqual(frame.viewportHeight, 1080)
        XCTAssertEqual(frame.drawCallCount, 3)
        XCTAssertEqual(frame.textureCount, 1)
        guard case let .rectangle(rect, color, clip) = frame.commands[0] else {
            return XCTFail("first command was not ROOT's Paint rectangle")
        }
        XCTAssertEqual(rect, GMLuaPanelRect(x: 0, y: 0, width: 810, height: 1080))
        XCTAssertEqual(color.alpha, 200)
        XCTAssertEqual(clip, rect)
        guard case let .text(value, position, _, textColor, textClip) = frame.commands[1] else {
            return XCTFail("second command was not the engine Label text")
        }
        XCTAssertEqual(value, LuaString("Sandbox"))
        XCTAssertGreaterThanOrEqual(position.x, 30)
        XCTAssertEqual(textColor.blue, 250)
        XCTAssertEqual(textClip, GMLuaPanelRect(x: 30, y: 40, width: 300, height: 50))
        guard case let .texturedRectangle(imageRect, _, textureName, _, imageClip) = frame.commands[2] else {
            return XCTFail("third command was not the DImage-compatible texture")
        }
        XCTAssertEqual(textureName, LuaString("icon16/brick.png"))
        XCTAssertEqual(imageRect, GMLuaPanelRect(x: 40, y: 120, width: 64, height: 64))
        XCTAssertEqual(imageClip, imageRect)
        XCTAssertFalse(registry.hasPlatformViewBacking)
    }

    func testStockContentIconTextureFilterScopesAreCapturedPerDraw() throws {
        let runtime = GMLuaRuntime(
            realm: .client,
            logger: { _ in },
            bootstrapMode: .strict
        )
        try runtime.execute(
            """
            assert(TEXFILTER.NONE == 0)
            assert(TEXFILTER.POINT == 1)
            assert(TEXFILTER.LINEAR == 2)
            assert(TEXFILTER.ANISOTROPIC == 3)

            local ok, message = pcall(render.PopFilterMin)
            assert(ok == false and string.find(message, "matching", 1, true))
            ok, message = pcall(render.PopFilterMag)
            assert(ok == false and string.find(message, "matching", 1, true))
            assert(pcall(render.PushFilterMin, -1) == false)
            assert(pcall(render.PushFilterMin, 3.5) == false)
            assert(pcall(render.PushFilterMag, 4) == false)
            assert(pcall(render.PushFilterMag, "3") == false)

            FILTER_ICON = assert(vgui.Create("Panel"))
            FILTER_ICON:SetSize(128, 128)
            function FILTER_ICON:Paint(w, h)
                surface.SetTexture(surface.GetTextureID("spawnicons/filter_probe.png"))
                surface.SetDrawColor(255, 255, 255, 255)

                -- Exact scope used by stock ContentIcon:Paint.
                render.PushFilterMag(TEXFILTER.ANISOTROPIC)
                render.PushFilterMin(TEXFILTER.ANISOTROPIC)
                surface.DrawTexturedRect(3, 3, w - 8, h - 8)
                render.PopFilterMin()

                -- Min/mag are independent stacks; mag remains active here.
                surface.DrawTexturedRect(4, 4, 16, 16)
                render.PopFilterMag()
                return true
            end
            """,
            sourceName: "@GMLuaStockContentIconTextureFilterScope.lua"
        )

        let registry = try XCTUnwrap(runtime.vguiRegistry)
        let surface = try XCTUnwrap(runtime.surfaceCommandState)
        let frame = try registry.renderFrame(
            surface: surface,
            viewportWidth: 128,
            viewportHeight: 128
        )
        XCTAssertEqual(frame.commands.count, 2)
        XCTAssertEqual(frame.textureFilters, [
            GMLuaSurfaceTextureFilterSnapshot(
                commandIndex: 0,
                minification: .anisotropic,
                magnification: .anisotropic
            ),
            GMLuaSurfaceTextureFilterSnapshot(
                commandIndex: 1,
                minification: nil,
                magnification: .anisotropic
            )
        ])
        XCTAssertEqual(frame.captureDiagnostics.attemptedCommandCount, 2)
        XCTAssertEqual(frame.captureDiagnostics.droppedCommandCount, 0)
    }

    func testNumericThreeComponentColorsAndGlobalDisableClippingMatchGModSurfaceAPI() throws {
        let runtime = GMLuaRuntime(
            realm: .client,
            logger: { _ in },
            bootstrapMode: .strict
        )
        try runtime.execute(
            """
            assert(type(DisableClipping) == "function")
            ROOT = vgui.Create("Panel")
            ROOT:SetPos(10, 20)
            ROOT:SetSize(30, 40)
            function ROOT:Paint(w, h)
                surface.SetDrawColor(11, 22, 33)
                local previous = DisableClipping(true)
                assert(previous == false)
                surface.DrawRect(-100, -100, 300, 300)
                assert(surface.DisableClipping(previous) == true)

                surface.SetTextColor(44, 55, 66)
                surface.SetFont("Default")
                surface.SetTextPos(0, 0)
                surface.DrawText("alpha")
            end
            """,
            sourceName: "@GMLuaSurfaceThreeColorAndGlobalClip.lua"
        )
        let registry = try XCTUnwrap(runtime.vguiRegistry)
        let surface = try XCTUnwrap(runtime.surfaceCommandState)
        let frame = try registry.renderFrame(
            surface: surface,
            viewportWidth: 100,
            viewportHeight: 100
        )
        XCTAssertEqual(frame.commands.count, 2)
        guard case let .rectangle(_, drawColor, drawClip) = frame.commands[0] else {
            return XCTFail("first command was not the unclipped rectangle")
        }
        XCTAssertEqual(drawColor, GMLuaSurfaceColor(red: 11, green: 22, blue: 33, alpha: 255))
        XCTAssertEqual(drawClip, GMLuaPanelRect(x: 0, y: 0, width: 100, height: 100))
        guard case let .text(_, _, _, textColor, textClip) = frame.commands[1] else {
            return XCTFail("second command was not text")
        }
        XCTAssertEqual(textColor, GMLuaSurfaceColor(red: 44, green: 55, blue: 66, alpha: 255))
        XCTAssertEqual(textClip, GMLuaPanelRect(x: 10, y: 20, width: 30, height: 40))
    }

    func testRenderScissorRectUsesScreenCoordinatesAndRestoresPanelClip() throws {
        let runtime = GMLuaRuntime(
            realm: .client,
            logger: { _ in },
            bootstrapMode: .strict
        )
        try runtime.execute(
            """
            assert(type(render.SetScissorRect) == "function")
            assert(pcall(render.SetScissorRect, 0, 0, 10, 10) == false)
            assert(pcall(render.SetScissorRect, 0, 0, 10, 10, 1) == false)
            assert(pcall(render.SetScissorRect, 0 / 0, 0, 10, 10, true) == false)

            ROOT = vgui.Create("Panel")
            ROOT:SetPos(10, 20)
            ROOT:SetSize(80, 60)

            CHILD = vgui.Create("Panel", ROOT)
            CHILD:SetPos(30, 10)
            CHILD:SetSize(50, 50)
            function CHILD:Paint()
                surface.SetDrawColor(255, 255, 255, 255)
                surface.DrawRect(-100, -100, 300, 300)

                -- Stock ContentIcon supplies screen-space start/end points.
                render.SetScissorRect(45, 35, 70, 60, true)
                surface.DrawRect(-100, -100, 300, 300)

                render.SetScissorRect(0, 0, 0, 0, false)
                surface.DrawRect(-100, -100, 300, 300)
                return true
            end
            """,
            sourceName: "@GMLuaRenderScissorRectRegression.lua"
        )

        let registry = try XCTUnwrap(runtime.vguiRegistry)
        let surface = try XCTUnwrap(runtime.surfaceCommandState)
        let frame = try registry.renderFrame(
            surface: surface,
            viewportWidth: 200,
            viewportHeight: 120
        )
        XCTAssertEqual(frame.commands.count, 3)
        var clips: [GMLuaPanelRect] = []
        for command in frame.commands {
            guard case let .rectangle(_, _, clip) = command else {
                XCTFail("expected rectangle command")
                continue
            }
            clips.append(clip)
        }
        XCTAssertEqual(clips, [
            GMLuaPanelRect(x: 40, y: 30, width: 50, height: 50),
            GMLuaPanelRect(x: 45, y: 35, width: 25, height: 25),
            GMLuaPanelRect(x: 40, y: 30, width: 50, height: 50)
        ])
    }

    func testAncestorAlphaIsCumulativeAndPaintTrueSuppressesDefaultLabelAndImage() throws {
        let runtime = GMLuaRuntime(
            realm: .client,
            logger: { _ in },
            bootstrapMode: .strict
        )
        try runtime.execute(
            """
            ROOT = vgui.Create("Panel")
            ROOT:SetSize(300, 200)
            ROOT:SetAlpha(128)

            VISIBLE = vgui.Create("Label", ROOT)
            VISIBLE:SetSize(100, 20)
            VISIBLE:SetAlpha(128)
            VISIBLE:SetText("visible")
            VISIBLE:SetFGColor(1, 2, 3, 200)

            HIDDEN_LABEL = vgui.Create("Label", ROOT)
            HIDDEN_LABEL:SetPos(0, 30)
            HIDDEN_LABEL:SetSize(100, 20)
            HIDDEN_LABEL:SetText("must not draw")
            function HIDDEN_LABEL:Paint() return true end

            HIDDEN_IMAGE = vgui.Create("Panel", ROOT)
            HIDDEN_IMAGE:SetPos(0, 60)
            HIDDEN_IMAGE:SetSize(16, 16)
            HIDDEN_IMAGE:SetImage("icon16/brick.png")
            function HIDDEN_IMAGE:Paint() return true end
            """,
            sourceName: "@GMLuaSurfacePaintSuppressionAndAlpha.lua"
        )
        let registry = try XCTUnwrap(runtime.vguiRegistry)
        let surface = try XCTUnwrap(runtime.surfaceCommandState)
        let tree = registry.renderTree(viewportWidth: 300, viewportHeight: 200)
        let visible = try XCTUnwrap(tree.first(where: { $0.text == LuaString("visible") }))
        let expectedEffectiveAlpha = 128.0 * 128.0 / 255.0
        XCTAssertEqual(visible.alpha, expectedEffectiveAlpha, accuracy: 0.000_001)

        let frame = try registry.renderFrame(
            surface: surface,
            viewportWidth: 300,
            viewportHeight: 200
        )
        XCTAssertEqual(frame.commands.count, 1)
        XCTAssertEqual(frame.textureCount, 0)
        guard case let .text(value, _, _, color, _) = frame.commands[0] else {
            return XCTFail("unsuppressed label was not the only default draw command")
        }
        XCTAssertEqual(value, LuaString("visible"))
        XCTAssertEqual(color.alpha, 200.0 * expectedEffectiveAlpha / 255.0, accuracy: 0.000_001)
    }

    func testCommandCaptureCountLimitDropsExcessAndResetsNextFrame() throws {
        let state = LuaState(output: { _ in })
        let typeSystem = try GMLuaTypeSystem.install(
            into: state,
            utilityLayer: .bundledFallback
        )
        let surface = try GMLuaSurface.install(
            into: state,
            maximumDrawCommandCount: 2,
            maximumEstimatedCommandByteCount: 1_024
        )
        let registry = try GMLuaVGUI.install(
            into: state,
            typeSystem: typeSystem,
            surfaceCommandState: surface
        )
        try state.execute(
            """
            DRAW_COUNT = 4
            ROOT = vgui.Create("Panel")
            ROOT:SetSize(100, 100)
            function ROOT:Paint()
                for index = 1, DRAW_COUNT do
                    surface.DrawRect(index, 0, 1, 1)
                end
            end
            """,
            sourceName: "@GMLuaSurfaceCommandCountBudget.lua"
        )

        let overflowed = try registry.renderFrame(
            surface: surface,
            viewportWidth: 100,
            viewportHeight: 100
        )
        XCTAssertEqual(overflowed.commands.count, 2)
        XCTAssertEqual(overflowed.captureDiagnostics.attemptedCommandCount, 4)
        XCTAssertEqual(overflowed.captureDiagnostics.retainedCommandCount, 2)
        XCTAssertEqual(overflowed.captureDiagnostics.droppedCommandCount, 2)
        XCTAssertEqual(overflowed.captureDiagnostics.maximumCommandCount, 2)
        XCTAssertTrue(overflowed.captureDiagnostics.overflowed)

        try state.execute("DRAW_COUNT = 1")
        let reset = try registry.renderFrame(
            surface: surface,
            viewportWidth: 100,
            viewportHeight: 100
        )
        XCTAssertEqual(reset.commands.count, 1)
        XCTAssertEqual(reset.captureDiagnostics.attemptedCommandCount, 1)
        XCTAssertEqual(reset.captureDiagnostics.retainedCommandCount, 1)
        XCTAssertEqual(reset.captureDiagnostics.droppedCommandCount, 0)
        XCTAssertFalse(reset.captureDiagnostics.overflowed)
    }

    func testCommandCaptureEstimatedByteLimitIsEnforced() throws {
        let state = LuaState(output: { _ in })
        let typeSystem = try GMLuaTypeSystem.install(
            into: state,
            utilityLayer: .bundledFallback
        )
        let surface = try GMLuaSurface.install(
            into: state,
            maximumDrawCommandCount: 10,
            maximumEstimatedCommandByteCount: 128
        )
        let registry = try GMLuaVGUI.install(
            into: state,
            typeSystem: typeSystem,
            surfaceCommandState: surface
        )
        try state.execute(
            """
            ROOT = vgui.Create("Panel")
            ROOT:SetSize(100, 100)
            function ROOT:Paint()
                surface.DrawRect(0, 0, 1, 1)
                surface.DrawRect(1, 0, 1, 1)
                surface.DrawRect(2, 0, 1, 1)
            end
            """,
            sourceName: "@GMLuaSurfaceCommandByteBudget.lua"
        )

        let frame = try registry.renderFrame(
            surface: surface,
            viewportWidth: 100,
            viewportHeight: 100
        )
        XCTAssertEqual(frame.commands.count, 1)
        XCTAssertEqual(frame.captureDiagnostics.attemptedCommandCount, 3)
        XCTAssertEqual(frame.captureDiagnostics.droppedCommandCount, 2)
        XCTAssertEqual(frame.captureDiagnostics.estimatedRetainedByteCount, 128)
        XCTAssertEqual(frame.captureDiagnostics.maximumEstimatedByteCount, 128)
        XCTAssertTrue(frame.captureDiagnostics.overflowed)
    }

    func testLabelInsetsFollowValveAlignedEdgeAndPreserveNegativeOrigins() throws {
        struct FixedLabelMeasurer: GMLuaTextMeasurer {
            let fidelity = GMLuaTextMeasurementFidelity.platformGlyphMetrics

            func measure(
                _ text: LuaString,
                using font: GMLuaFontDescriptor
            ) -> GMLuaTextMeasurement {
                GMLuaTextMeasurement(width: 20, height: 10)
            }
        }

        let state = LuaState(output: { _ in })
        let typeSystem = try GMLuaTypeSystem.install(
            into: state,
            utilityLayer: .bundledFallback
        )
        let surface = try GMLuaSurface.install(
            into: state,
            textMeasurer: FixedLabelMeasurer()
        )
        let registry = try GMLuaVGUI.install(
            into: state,
            typeSystem: typeSystem,
            surfaceCommandState: surface
        )
        try state.execute(
            """
            local function label(name, x, y, alignment)
                local value = vgui.Create("Label")
                value:SetName(name)
                value:SetPos(x, y)
                value:SetSize(10, 6)
                value:SetText(name)
                value:SetTextInset(3, 1)
                value:SetContentAlignment(alignment)
                return value
            end
            NORTHWEST = label("northwest", 20, 20, 7)
            CENTER = label("center", 50, 50, 5)
            CENTER:SetSize(9, 5)
            SOUTHEAST = label("southeast", 80, 80, 3)
            """,
            sourceName: "@GMLuaSurfaceLabelInsetAlignment.lua"
        )

        let tree = registry.renderTree(viewportWidth: 200, viewportHeight: 200)
        XCTAssertTrue(tree.allSatisfy { panel in
            panel.textInsetX == 3 && panel.textInsetY == 1
        })
        XCTAssertTrue(registry.textPanelStateSnapshots.allSatisfy { panel in
            panel.textInsetX == 3 && panel.textInsetY == 1
        })
        let frame = try registry.renderFrame(
            surface: surface,
            viewportWidth: 200,
            viewportHeight: 200
        )
        let positions = Dictionary(uniqueKeysWithValues: frame.commands.compactMap {
            command -> (String, GMLuaCursorPosition)? in
            guard case let .text(value, position, _, _, _) = command else {
                return nil
            }
            return (value.utf8String, position)
        })
        XCTAssertEqual(
            positions["northwest"],
            GMLuaCursorPosition(x: 23, y: 21)
        )
        XCTAssertEqual(
            positions["center"],
            GMLuaCursorPosition(x: 45, y: 49)
        )
        XCTAssertEqual(
            positions["southeast"],
            GMLuaCursorPosition(x: 67, y: 77)
        )
    }
}
