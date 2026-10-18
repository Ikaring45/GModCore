import Foundation
import XCTest
import GModEngine
import GModGameAssets

final class SourceVGUISchemeTests: XCTestCase {
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
    }
}
