import Foundation
import XCTest
import GModEngine
import GModGameAssets

final class SourceVGUISchemeTests: XCTestCase {
    func testSourceCheckButtonUsesAuthoredColorsMarlettLayersAndSingleClickRegion() throws {
        let scheme = try SourceVGUIScheme(source: """
            Scheme { BaseSettings {
                CheckButton.TextColor "10 11 12 255" CheckButton.SelectedTextColor "20 21 22 255"
                CheckButton.HighlightFgColor "30 31 32 255" CheckButton.BgColor "40 41 42 200"
                CheckButton.Border1 "50 51 52 255" CheckButton.Border2 "60 61 62 255"
                CheckButton.Check "70 71 72 255" CheckButton.DisabledFgColor "80 81 82 255"
                CheckButton.DisabledBgColor "90 91 92 255" Label.DisabledFgColor1 "100 101 102 255"
                Label.DisabledFgColor2 "110 111 112 255"
            } Fonts {
                Default { One { name SourceFace tall 16 weight 500 } }
                Marlett { One { name Marlett tall 14 weight 0 symbol 1 } }
                MarlettSmall { One { name Marlett tall 10 weight 0 symbol 1 } }
            } }
            """, activeSymbols: [])
        let files = try GMLuaHostDirectoryFileSystem(rootURL: GModGameAssets.clientContentRootURL(), writable: false)
        let session = GMLuaMenuSession(fileSystem: files, logger: { _ in })
        defer { _ = session.close() }
        _ = try session.start()
        let resource = try SourceVGUIResource(source: """
            test {
                Enabled { ControlName CheckButton labelText Enable selected 0 textAlignment west
                    textinsetx 6 xpos 20 ypos 20 wide 230 tall 24 }
                Disabled { ControlName CheckButton labelText Disabled selected 1 enabled 0
                    smallcheckimage 1 xpos 20 ypos 70 wide 230 tall 24 }
            }
            """)
        let instance = try session.loadResource(resource, scheme: scheme) { _ in XCTFail("A plain CheckButton must not invent a command") }
        try instance.layout(viewportWidth: 640, viewportHeight: 480)
        XCTAssertTrue(instance.unappliedFields.isEmpty)
        XCTAssertTrue(instance.unappliedSchemeColorControls.isEmpty)
        XCTAssertTrue(instance.unappliedSchemeFontControls.isEmpty)
        func color(_ red: Double, _ alpha: Double = 255) -> GMLuaSurfaceColor {
            .init(red: red, green: red + 1, blue: red + 2, alpha: alpha)
        }
        let initial = try session.renderFrame(viewportWidth: 640, viewportHeight: 480)
        let glyphs = initial.commands.compactMap { command -> (String, GMLuaFontDescriptor, GMLuaSurfaceColor)? in
            if case let .text(text, _, font, color, _) = command, font.symbol { return (text.utf8String, font, color) }
            return nil
        }
        XCTAssertEqual(glyphs.map { $0.0 }, ["g", "e", "f", "g", "e", "f", "b"])
        XCTAssertEqual(glyphs[0].2, color(40, 200)); XCTAssertEqual(glyphs[1].2, color(50))
        XCTAssertEqual(glyphs[2].2, color(60)); XCTAssertEqual(glyphs[3].2, color(90))
        XCTAssertEqual(glyphs[6].2, color(80))
        XCTAssertEqual(glyphs[0].1.font.utf8String, "Marlett"); XCTAssertEqual(glyphs[0].1.size, 14)
        XCTAssertEqual(glyphs[3].1.size, 10)
        XCTAssertTrue(initial.commands.contains {
            if case let .text(text, _, font, c, _) = $0 {
                return text.utf8String == "Enable" && c == color(10) && font.size == 16
            }; return false
        })
        let imageX = try XCTUnwrap(initial.commands.compactMap { command -> Double? in
            if case let .text(text, position, font, _, _) = command, text.utf8String == "g", font.size == 14 {
                return position.x
            }; return nil
        }.first)
        XCTAssertEqual(imageX, 26, "The six-pixel offset is before the image; caption textinsetx does not move it")
        let embossed = initial.commands.compactMap { command -> (GMLuaCursorPosition, GMLuaSurfaceColor)? in
            if case let .text(text, position, _, c, _) = command, text.utf8String == "Disabled" {
                return (position, c)
            }; return nil
        }
        XCTAssertEqual(embossed.count, 2)
        XCTAssertEqual(embossed[0].1, color(100)); XCTAssertEqual(embossed[1].1, color(110))
        XCTAssertEqual(embossed[0].0.x, embossed[1].0.x + 1)
        XCTAssertEqual(embossed[0].0.y, embossed[1].0.y + 1)
        // Click whitespace inside the authored bounds, beyond both glyph and
        // caption. Native CheckButton is one input button, not two hit regions.
        for phase: GMLuaPointerPhase in [.began, .ended] {
            _ = try session.dispatchPointerEvent(x: 240, y: 32, phase: phase, timestamp: 1,
                viewportWidth: 640, viewportHeight: 480)
        }
        XCTAssertTrue(try instance.isChecked(control: "Enabled"))
        _ = try session.dispatchPointerEvent(x: 600, y: 400, phase: .moved, timestamp: 2,
            viewportWidth: 640, viewportHeight: 480)
        let selected = try session.renderFrame(viewportWidth: 640, viewportHeight: 480)
        XCTAssertTrue(selected.commands.contains {
            if case let .text(text, _, _, c, _) = $0 { return text.utf8String == "Enable" && c == color(20) }; return false
        })
        XCTAssertTrue(selected.commands.contains {
            if case let .text(text, _, font, c, _) = $0 { return text.utf8String == "b" && font.size == 14 && c == color(70) }; return false
        })
        _ = try session.dispatchPointerEvent(x: 240, y: 32, phase: .moved, timestamp: 3,
            viewportWidth: 640, viewportHeight: 480)
        let hovered = try session.renderFrame(viewportWidth: 640, viewportHeight: 480)
        XCTAssertTrue(hovered.commands.contains {
            if case let .text(text, _, _, c, _) = $0 { return text.utf8String == "Enable" && c == color(30) }; return false
        })
        for phase: GMLuaPointerPhase in [.began, .ended] {
            _ = try session.dispatchPointerEvent(x: 240, y: 82, phase: phase, timestamp: 4,
                viewportWidth: 640, viewportHeight: 480)
        }
        XCTAssertTrue(try instance.isChecked(control: "Disabled"))
    }

    func testResourceSchemeColorsFollowHoverPressAndRetainRealButtonCommand() throws {
        let roles: [(String, String)] = [
            ("Frame.BgColor", "20 21 22 250"), ("Frame.OutOfFocusBgColor", "30 31 32 240"),
            ("Label.TextColor", "1 2 3 255"), ("Label.TextDullColor", "4 5 6 255"),
            ("Label.TextBrightColor", "7 8 9 255"), ("Label.DisabledFgColor1", "10 11 12 255"),
            ("Button.TextColor", "40 41 42 255"), ("Button.BgColor", "50 51 52 255"),
            ("Button.ArmedTextColor", "60 61 62 255"), ("Button.ArmedBgColor", "70 71 72 255"),
            ("Button.DepressedTextColor", "80 81 82 255"), ("Button.DepressedBgColor", "90 91 92 255")
        ]
        let fields = roles.map { "\($0.0) \"\($0.1)\"" }.joined(separator: "\n")
        let edges = ["Left", "Right", "Top", "Bottom"].map {
            "\($0) { \"1\" { color Edge offset \"0 0\" } }"
        }.joined(separator: "\n")
        let scheme = try SourceVGUIScheme(source: """
            Scheme { Colors { Edge "101 102 103 255" } BaseSettings { \(fields) }
                Borders { Common { \(edges) } FrameBorder Common ButtonBorder Common ButtonDepressedBorder Common } }
            """, activeSymbols: ["WIN32", "WINDOWS"])
        let files = try GMLuaHostDirectoryFileSystem(rootURL: GModGameAssets.clientContentRootURL(), writable: false)
        let session = GMLuaMenuSession(fileSystem: files, logger: { _ in })
        defer { _ = session.close() }
        _ = try session.start()
        let resource = try SourceVGUIResource(source: """
            test {
                Root { ControlName Frame settitlebarvisible 0 title 0 xpos 10 ypos 10 wide 240 tall 160 }
                Apply { ControlName Button labelText Apply command Apply xpos 20 ypos 20 wide 100 tall 30 }
                Caption { ControlName Label labelText Caption dulltext 1 xpos 20 ypos 60 wide 100 tall 30 }
            }
            """)
        var commands: [String] = []
        let instance = try session.loadResource(resource, rootControlName: "Root", scheme: scheme) { commands.append($0) }
        XCTAssertEqual(instance.unappliedSchemeFontControls.sorted(), ["Apply", "Caption"],
            "A palette-only Scheme must not claim native font application")
        try instance.layout(viewportWidth: 640, viewportHeight: 480)
        func frameWithButtonColor(_ rgb: Double) throws -> GMLuaSurfaceFrameSnapshot {
            let frame = try session.renderFrame(viewportWidth: 640, viewportHeight: 480)
            XCTAssertTrue(frame.commands.contains {
                if case let .rectangle(rect, color, _) = $0 {
                    return rect.width == 100 && rect.height == 30 && color == .init(red: rgb, green: rgb + 1, blue: rgb + 2, alpha: 255)
                }; return false
            })
            return frame
        }
        let initial = try frameWithButtonColor(50)
        XCTAssertTrue(initial.commands.contains {
            if case let .text(text, _, _, color, _) = $0 {
                return text.utf8String == "Caption" && color == .init(red: 4, green: 5, blue: 6, alpha: 255)
            }; return false
        })
        _ = try session.dispatchPointerEvent(x: 80, y: 45, phase: .moved, timestamp: 1, viewportWidth: 640, viewportHeight: 480)
        _ = try frameWithButtonColor(70)
        _ = try session.dispatchPointerEvent(x: 80, y: 45, phase: .began, timestamp: 2, viewportWidth: 640, viewportHeight: 480)
        let down = try frameWithButtonColor(90)
        XCTAssertTrue(down.commands.contains {
            if case let .text(text, _, _, color, _) = $0 {
                return text.utf8String == "Apply" && color == .init(red: 80, green: 81, blue: 82, alpha: 255)
            }; return false
        })
        _ = try session.dispatchPointerEvent(x: 80, y: 45, phase: .ended, timestamp: 3, viewportWidth: 640, viewportHeight: 480)
        XCTAssertEqual(commands, ["Apply"])
    }

    func testColorsResolveAliasesPlatformSelectionAlphaAndFirstKeyValuesMatch() throws {
        let scheme = try SourceVGUIScheme(source: """
            Scheme {
                Colors { White "255 255 255 204" Blank "0 0 0 0" RGB "1 2 3" }
                BaseSettings {
                    Frame.BgColor "20 21 22 240" [$WIN32]
                    Frame.BgColor "90 91 92 255" [$X360]
                    Frame.BgColor "200 201 202 255" [$WIN32]
                    Label.TextColor White Slider.TextColor Label.TextColor
                    NativeOnly Blank [!$POSIX]
                }
                Fonts { Default { "1" { name Tahoma tall 13 } } }
            }
            """, activeSymbols: ["WIN32", "WINDOWS"])
        XCTAssertEqual(try scheme.color("frame.bgcolor"), .init(red: 20, green: 21, blue: 22, alpha: 240))
        XCTAssertEqual(try scheme.color("Slider.TextColor"), .init(red: 255, green: 255, blue: 255, alpha: 204))
        XCTAssertEqual(try scheme.color("NativeOnly").alpha, 0)
        XCTAssertEqual(try scheme.color("RGB").alpha, 255)
        XCTAssertEqual(scheme.fonts.count, 1)
    }

    func testInvalidColorsAliasesDirectivesAndUnknownConditionsAreExplicitErrors() throws {
        let scheme = try SourceVGUIScheme(source: """
            Scheme { Colors { A B B A Bad "256 0 0 255" Fraction "1.5 2 3 255" } }
            """, activeSymbols: [])
        XCTAssertThrowsError(try scheme.color("A"))
        XCTAssertThrowsError(try scheme.color("Bad"))
        XCTAssertThrowsError(try scheme.color("Fraction"))
        XCTAssertThrowsError(try scheme.color("Missing"))
        XCTAssertThrowsError(try SourceVGUIScheme(source: "#base \"base.res\" Scheme {}", activeSymbols: []))
        XCTAssertThrowsError(try SourceVGUIScheme(source: "Scheme { BaseSettings { Color White [$UNKNOWN] } }", activeSymbols: []))
    }

    func testConfiguredOwnedGameUISchemeAndLoadingColorsUseActualPack() throws {
        guard let path = ProcessInfo.processInfo.environment["GMOD_CONTENT_PACK_DIAGNOSTIC_PATH"], !path.isEmpty else {
            throw XCTSkip("No user-owned content pack supplied")
        }
        let pack = try GarrysPADContentPack(url: URL(fileURLWithPath: path))
        let schemeData = try pack.data(for: "garrysmod/resource/SourceScheme.res", maximumByteCount: 1_024 * 1_024)
        let scheme = try SourceVGUIScheme(source: String(decoding: schemeData, as: UTF8.self),
            activeSymbols: ["WIN32", "WINDOWS"])
        XCTAssertEqual(try scheme.color("Frame.BgColor"), .init(red: 108, green: 111, blue: 114, alpha: 250))
        XCTAssertEqual(try scheme.color("Button.ArmedBgColor"), .init(red: 240, green: 240, blue: 240, alpha: 255))
        XCTAssertEqual(try scheme.color("Slider.TrackColor"), .init(red: 184, green: 184, blue: 184, alpha: 229))
        XCTAssertEqual(try scheme.flatBorderColor("FrameBorder"), .init(red: 40, green: 40, blue: 40, alpha: 255))
        let files = try GMLuaHostDirectoryFileSystem(rootURL: GModGameAssets.clientContentRootURL(), writable: false)
        let catalog = try GMLuaEngineConVarCatalog(descriptors: [.init(name: "fps_max", defaultValue: "60")])
        let session = GMLuaMenuSession(fileSystem: files, engineConVarCatalog: catalog, logger: { _ in })
        defer { _ = session.close() }
        _ = try session.start()
        let resourceData = try pack.data(for: "garrysmod/resource/LoadingDialogGMod.res", maximumByteCount: 1_024 * 1_024)
        let resource = try SourceVGUIResource(source: String(decoding: resourceData, as: UTF8.self))
        let instance = try session.loadLoadingResource(resource, scheme: scheme)
        try instance.layout(viewportWidth: 1_024, viewportHeight: 768)
        try instance.setText("Starting Lua...", control: "InfoLabel")
        try instance.setProgress(0.5, control: "Progress")
        func capturedColor(_ key: String) throws -> GMLuaSurfaceColor {
            let c = try scheme.color(key)
            return .init(red: c.red, green: c.green, blue: c.blue, alpha: c.alpha)
        }
        let normalButton = try capturedColor("Button.BgColor")
        let label = try capturedColor("Label.TextColor")
        let frame = try session.renderFrame(viewportWidth: 1_024, viewportHeight: 768)
        XCTAssertTrue(frame.commands.contains {
            if case let .rectangle(rect, color, _) = $0 {
                return rect.width == 66 && rect.height == 24 && color == normalButton
            }; return false
        })
        XCTAssertTrue(frame.commands.contains {
            if case let .text(text, _, font, color, _) = $0 {
                return text.utf8String == "Starting Lua..." && color == label &&
                    font.font.utf8String == "Tahoma" && font.size == 16 && font.name.utf8String.hasPrefix("GarrysPAD.GameUI.")
            }; return false
        })
        for phase: GMLuaPointerPhase in [.began, .ended] {
            _ = try session.dispatchPointerEvent(x: 970, y: 740, phase: phase, timestamp: 1,
                viewportWidth: 1_024, viewportHeight: 768)
        }
        XCTAssertEqual(session.drainActions(), [.disconnect])
        try instance.remove()
        _ = try session.renderFrame(viewportWidth: 1_024, viewportHeight: 768)
        let sliderResource = try SourceVGUIResource(source: """
            test { FPS { ControlName CCvarSlider cvar_name fps_max minvalue 30 maxvalue 300
                xpos 20 ypos 20 wide 200 tall 50 } }
            """)
        let slider = try session.loadResource(sliderResource, scheme: scheme) { _ in }
        try slider.layout(viewportWidth: 1_024, viewportHeight: 768)
        let sliderFrame = try session.renderFrame(viewportWidth: 1_024, viewportHeight: 768)
        let track = try capturedColor("Slider.TrackColor")
        let knob = try capturedColor("Slider.NobColor")
        XCTAssertTrue(sliderFrame.commands.contains {
            if case let .rectangle(rect, color, _) = $0 { return rect.width == 192 && rect.height == 4 && color == track }; return false
        })
        XCTAssertTrue(sliderFrame.commands.contains {
            if case let .rectangle(rect, color, _) = $0 { return rect.width == 8 && rect.height == 16 && color == knob }; return false
        })
        XCTAssertTrue(sliderFrame.commands.contains {
            if case let .text(text, _, font, _, _) = $0 {
                return text.utf8String == "30.00" && font.font.utf8String == "Tahoma" && font.size == 12
            }; return false
        })
        try slider.remove()
        _ = try session.renderFrame(viewportWidth: 1_024, viewportHeight: 768)
        // Project an actual, unmodified plain CheckButton block from the owned
        // Voice page. Other factories on that page are not claimed as supported.
        let voiceData = try pack.data(for: "garrysmod/resource/OptionsSubVoice.res", maximumByteCount: 1_024 * 1_024)
        let voice = try SourceVGUIResource(source: String(decoding: voiceData, as: UTF8.self))
        let original = try XCTUnwrap(voice.controls.first { $0.fieldName == "voice_modenable" })
        XCTAssertEqual(original.controlName, "CheckButton")
        let fields = try original.entries.map { entry -> String in
            guard entry.conditional == nil, case let .string(value) = entry.value,
                  !entry.key.contains("\""), !value.contains("\"") else { throw CocoaError(.fileReadCorruptFile) }
            return "\"\(entry.key)\" \"\(value)\""
        }.joined(separator: "\n")
        let checkResource = try SourceVGUIResource(source: "Voice { Original { \(fields) } }")
        let check = try session.loadResource(checkResource, scheme: scheme) { _ in }
        try check.layout(viewportWidth: 1_024, viewportHeight: 768)
        let checkFrame = try session.renderFrame(viewportWidth: 1_024, viewportHeight: 768)
        let background = try capturedColor("CheckButton.BgColor")
        XCTAssertTrue(checkFrame.commands.contains {
            if case let .text(text, _, font, color, _) = $0 {
                return text.utf8String == "g" && font.font.utf8String == "Marlett" && font.symbol &&
                    font.size == 14 && color == background
            }; return false
        })
        for phase: GMLuaPointerPhase in [.began, .ended] {
            _ = try session.dispatchPointerEvent(x: 240, y: 46, phase: phase, timestamp: 2,
                viewportWidth: 1_024, viewportHeight: 768)
        }
        XCTAssertTrue(try check.isChecked(control: "voice_modenable"))
        XCTAssertFalse(check.unappliedFields.isEmpty, "Remaining native page fields must still be reported")
        try check.remove()
        _ = try session.renderFrame(viewportWidth: 1_024, viewportHeight: 768)
        XCTAssertTrue(try scheme.borderSegments("TitleButtonBorder").isEmpty)
        let nativeFrame = try SourceVGUIResource(source: """
            Test { Root { ControlName Frame title "Source Frame" xpos 300 ypos 50 wide 240 tall 150 } }
            """)
        let window = try session.loadResource(nativeFrame, rootControlName: "Root", scheme: scheme) { _ in }
        try window.layout(viewportWidth: 1_024, viewportHeight: 768)
        try window.requestFocus(control: "Root")
        let windowFrame = try session.renderFrame(viewportWidth: 1_024, viewportHeight: 768)
        let titleColor = try capturedColor("FrameTitleBar.TextColor")
        XCTAssertTrue(windowFrame.commands.contains {
            if case let .text(text, position, font, color, _) = $0 {
                return text.utf8String == "Source Frame" && position.x == 316 && position.y == 59 &&
                    font.font.utf8String == "Tahoma" && font.size == 12 && font.weight == 1_000 && color == titleColor
            }; return false
        })
        XCTAssertTrue(windowFrame.commands.contains {
            if case let .text(text, _, font, _, _) = $0 { return text.utf8String == "r" && font.symbol && font.font.utf8String == "Marlett" }; return false
        })
        for phase: GMLuaPointerPhase in [.began, .ended] {
            _ = try session.dispatchPointerEvent(x: 524, y: 67, phase: phase, timestamp: 3,
                viewportWidth: 1_024, viewportHeight: 768)
        }
        XCTAssertFalse(try window.isVisible(control: "Root"))
        try window.setVisible(true, control: "Root")
        XCTAssertTrue(try window.isVisible(control: "Root"))
    }
}
