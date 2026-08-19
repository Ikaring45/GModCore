import Foundation
import XCTest
import GModEngine
import GModLua

final class GMLuaSurfaceTests: XCTestCase {
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
}
