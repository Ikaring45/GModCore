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
            """,
            sourceName: "@GMLuaSurfaceFontRanges.lua"
        )
        let firstDescriptor = try XCTUnwrap(
            firstCommands.fontDescriptor(named: "RANGEFONT")
        )
        XCTAssertEqual(firstCommands.customFontCount, 1)
        XCTAssertEqual(firstDescriptor.font, "Arial")
        XCTAssertEqual(firstDescriptor.size, 255)
        XCTAssertEqual(firstDescriptor.weight, 500)
        XCTAssertEqual(firstDescriptor.blurSize, 0)
        XCTAssertTrue(firstDescriptor.antialias)

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
}
