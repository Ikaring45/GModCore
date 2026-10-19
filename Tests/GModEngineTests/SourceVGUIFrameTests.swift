import XCTest
import GModEngine
import GModGameAssets

final class SourceVGUIFrameTests: XCTestCase {
    private func scheme() throws -> SourceVGUIScheme {
        func edges(_ color: String) -> String {
            ["Left", "Right", "Top", "Bottom"].map {
                "\($0) { One { color \(color) offset \"0 0\" } }"
            }.joined(separator: "\n")
        }
        return try SourceVGUIScheme(source: """
            Scheme { Colors { Edge "110 111 112 255"
                ActiveEdge "120 121 122 255" DownEdge "130 131 132 255" InactiveEdge "140 141 142 255"
            } BaseSettings {
                Frame.BgColor "10 11 12 230" Frame.OutOfFocusBgColor "20 21 22 220"
                FrameTitleBar.TextColor "30 31 32 255" FrameTitleBar.BgColor "40 41 42 100"
                FrameTitleBar.DisabledTextColor "50 51 52 255" FrameTitleBar.DisabledBgColor "60 61 62 80"
                FrameTitleButton.FgColor "70 71 72 255" FrameTitleButton.BgColor "80 81 82 200"
                FrameTitleButton.DisabledFgColor "90 91 92 255" FrameTitleButton.DisabledBgColor "100 101 102 180"
                Frame.TitleTextInsetX 11 FrameTitleBar.Font SchemeTitle
                FrameSystemButton.Icon "" FrameSystemButton.DisabledIcon ""
            } Borders {
                FrameBorder { \(edges("Edge")) }
                TitleButtonBorder { \(edges("ActiveEdge")) }
                TitleButtonDepressedBorder { \(edges("DownEdge")) }
                TitleButtonDisabledBorder { \(edges("InactiveEdge")) }
            } Fonts {
                Default { One { name DefaultFace tall 13 weight 500 } }
                SchemeTitle { One { name SchemeFace tall 17 weight 700 } }
                CustomTitle { One { name CustomFace tall 19 weight 700 } }
                Marlett { One { name Marlett tall 14 weight 0 symbol 1 } }
            } }
            """, activeSymbols: [])
    }

    func testFrameChromeFocusCustomTitleFontAndRetainedCloseReopen() throws {
        let files = try GMLuaHostDirectoryFileSystem(rootURL: GModGameAssets.clientContentRootURL(), writable: false)
        let session = GMLuaMenuSession(fileSystem: files, logger: { _ in })
        defer { _ = session.close() }
        _ = try session.start()
        let resource = try SourceVGUIResource(source: """
            Settings {
                Root { ControlName Frame title Options title_font CustomTitle settitlebarvisible 1
                    setclosebuttonvisible 1 visible 0 xpos 20 ypos 30 wide 300 tall 180 }
                Name { ControlName TextEntry text saved editable 1 xpos 20 ypos 60 wide 180 tall 24 }
            }
            """)
        let instance = try session.loadResource(resource, rootControlName: "Root", scheme: scheme()) { _ in XCTFail("Closing a Frame must not invent a resource command") }
        try instance.layout(viewportWidth: 640, viewportHeight: 480)
        XCTAssertTrue(instance.unappliedFields.isEmpty)
        XCTAssertEqual(instance.unappliedSchemeColorControls, ["Name"], "TextEntry palette is still not native")
        XCTAssertTrue(try instance.isVisible(control: "Root"), "Source Frame ignores the saved visible field")
        func color(_ red: Double, _ alpha: Double = 255) -> GMLuaSurfaceColor {
            .init(red: red, green: red + 1, blue: red + 2, alpha: alpha)
        }
        let inactive = try session.renderFrame(viewportWidth: 640, viewportHeight: 480)
        XCTAssertTrue(inactive.commands.contains {
            if case let .rectangle(rect, c, _) = $0 { return rect.width == 300 && rect.height == 180 && c == color(20, 220) }; return false
        })
        XCTAssertTrue(inactive.commands.contains {
            if case let .rectangle(rect, c, _) = $0 {
                return rect.x == 25 && rect.y == 35 && rect.width == 290 && rect.height == 23 && c == color(60, 80)
            }; return false
        })
        XCTAssertTrue(inactive.commands.contains {
            if case let .rectangle(_, c, _) = $0 { return c == color(140) }; return false
        })
        XCTAssertTrue(inactive.commands.contains {
            if case let .text(text, position, font, c, _) = $0 {
                return text.utf8String == "Options" && position.x == 31 && position.y == 39 &&
                    font.font.utf8String == "CustomFace" && font.size == 19 && c == color(50)
            }; return false
        })
        XCTAssertTrue(inactive.commands.contains {
            if case let .text(text, position, font, c, _) = $0 {
                return text.utf8String == "r" && position.x == 297 && position.y == 39 &&
                    font.symbol && font.font.utf8String == "Marlett" && c == color(90)
            }; return false
        })
        try instance.requestFocus(control: "Name")
        let active = try session.renderFrame(viewportWidth: 640, viewportHeight: 480)
        XCTAssertTrue(active.commands.contains {
            if case let .rectangle(rect, c, _) = $0 { return rect.width == 300 && rect.height == 180 && c == color(10, 230) }; return false
        })
        XCTAssertTrue(active.commands.contains {
            if case let .text(text, _, _, c, _) = $0 { return text.utf8String == "Options" && c == color(30) }; return false
        })
        XCTAssertTrue(active.commands.contains {
            if case let .rectangle(_, c, _) = $0 { return c == color(120) }; return false
        })
        try instance.setText("edited", control: "Name")
        for _ in 0..<3 {
            _ = try session.dispatchPointerEvent(x: 304, y: 47, phase: .began, timestamp: 1,
                viewportWidth: 640, viewportHeight: 480)
            let down = try session.renderFrame(viewportWidth: 640, viewportHeight: 480)
            XCTAssertTrue(down.commands.contains {
                if case let .rectangle(_, c, _) = $0 { return c == color(130) }; return false
            })
            _ = try session.dispatchPointerEvent(x: 304, y: 47, phase: .ended, timestamp: 1,
                viewportWidth: 640, viewportHeight: 480)
            XCTAssertFalse(try instance.isVisible(control: "Root"))
            let closed = try session.renderFrame(viewportWidth: 640, viewportHeight: 480)
            XCTAssertFalse(closed.commands.contains {
                if case let .text(text, _, _, _, _) = $0 { return text.utf8String == "Options" }; return false
            })
            try instance.setVisible(true, control: "Root")
            try instance.requestFocus(control: "Root")
            try instance.layout(viewportWidth: 640, viewportHeight: 480)
            XCTAssertTrue(try instance.isVisible(control: "Root"))
            XCTAssertEqual(try instance.text(control: "Name"), "edited", "Close must retain live control state")
            _ = try session.renderFrame(viewportWidth: 640, viewportHeight: 480)
        }
        try instance.remove()
        XCTAssertThrowsError(try instance.isVisible(control: "Root"))
        XCTAssertThrowsError(try instance.requestFocus(control: "Root"))
    }

    func testCloseVisibilityAndSchemeTitleFontAreAuthoredWithoutChangingGlobalDerma() throws {
        let files = try GMLuaHostDirectoryFileSystem(rootURL: GModGameAssets.clientContentRootURL(), writable: false)
        let session = GMLuaMenuSession(fileSystem: files, logger: { _ in })
        defer { _ = session.close() }
        _ = try session.start()
        let resource = try SourceVGUIResource(source: """
            Settings { Root { ControlName Frame title NoClose settitlebarvisible 1 setclosebuttonvisible 0
                xpos 20 ypos 30 wide 300 tall 180 } }
            """)
        let instance = try session.loadResource(resource, rootControlName: "Root", scheme: scheme()) { _ in }
        try instance.layout(viewportWidth: 640, viewportHeight: 480)
        let frame = try session.renderFrame(viewportWidth: 640, viewportHeight: 480)
        XCTAssertTrue(frame.commands.contains {
            if case let .text(text, _, font, _, _) = $0 {
                return text.utf8String == "NoClose" && font.font.utf8String == "SchemeFace" && font.size == 17
            }; return false
        })
        XCTAssertFalse(frame.commands.contains {
            if case let .text(_, _, font, _, _) = $0 { return font.symbol }; return false
        })
        for phase: GMLuaPointerPhase in [.began, .ended] {
            _ = try session.dispatchPointerEvent(x: 304, y: 47, phase: phase, timestamp: 1,
                viewportWidth: 640, viewportHeight: 480)
        }
        XCTAssertTrue(try instance.isVisible(control: "Root"))
    }

    func testOnlyExplicitEmptyTypeZeroBordersAreAccepted() throws {
        let scheme = try SourceVGUIScheme(source: """
            Scheme { Borders {
                Empty { backgroundtype 0 } Alias Empty
                Image { backgroundtype 1 } Unspecified { }
            } }
            """, activeSymbols: [])
        XCTAssertEqual(try scheme.borderSegments("Alias"), [])
        XCTAssertThrowsError(try scheme.borderSegments("Image"))
        XCTAssertThrowsError(try scheme.borderSegments("Unspecified"))
    }
}
