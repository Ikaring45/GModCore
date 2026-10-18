import XCTest
@testable import GModEngine
import GModGameAssets

final class SourceVGUISchemeFontTests: XCTestCase {
    func testAuthoredFaceSizeWeightFlagsAndYresAreResolvedWithoutCollapsingGlyphSets() throws {
        let scheme = try SourceVGUIScheme(source: """
            Scheme { Fonts {
                Default { "1" [$WIN32] { name SourceFace tall 16 weight 700 dropshadow 1 underline 1 } }
                Console {
                    Small { name SmallFace tall 10 weight 400 yres "0 480" }
                    Large { name LargeFace tall 18 weight 500 yres "481 10000" antialias 1 }
                }
                Multiple { One { name Latin tall 16 weight 500 } Two { name CJK tall 16 weight 500 } }
            } }
            """, activeSymbols: ["WIN32", "WINDOWS"])
        let font = try scheme.font("default", viewportHeight: 768)
        XCTAssertEqual(font.face, "SourceFace"); XCTAssertEqual(font.tall, 16); XCTAssertEqual(font.weight, 700)
        XCTAssertEqual(font.flags["shadow"], true); XCTAssertEqual(font.flags["underline"], true)
        XCTAssertEqual(font.flags["antialias"], false)
        XCTAssertEqual(try scheme.font("Console", viewportHeight: 480).face, "SmallFace")
        XCTAssertEqual(try scheme.font("Console", viewportHeight: 481).face, "LargeFace")
        XCTAssertThrowsError(try scheme.font("Multiple", viewportHeight: 768))
        XCTAssertThrowsError(try scheme.font("Missing", viewportHeight: 768))
    }

    func testRegistrationReusesIdenticalDescriptorAndDoesNotOverwriteDefault() throws {
        let runtime = GMLuaRuntime(realm: .menu, logger: { _ in }, bootstrapMode: .strict)
        defer { _ = runtime.close() }
        try runtime.execute("assert(surface)")
        let surface = try XCTUnwrap(runtime.surfaceCommandState)
        let before = try XCTUnwrap(surface.fontDescriptor(named: "Default"))
        let count = surface.customFontCount
        let scheme = try SourceVGUIScheme(source: """
            Scheme { Fonts { Default { "1" { name SourceFace tall 16 weight 500 } } } }
            """, activeSymbols: [])
        let font = try scheme.font("Default", viewportHeight: 768)
        let name = try GMLuaVGUIResourceSchemeFont.install(font, runtime: runtime)
        for _ in 0..<20 { XCTAssertEqual(try GMLuaVGUIResourceSchemeFont.install(font, runtime: runtime), name) }
        XCTAssertEqual(surface.customFontCount, count + 1)
        XCTAssertEqual(surface.fontDescriptor(named: "Default"), before)
        let source = try XCTUnwrap(surface.fontDescriptor(named: .init(name)))
        XCTAssertEqual(source.size, 16); XCTAssertEqual(source.font.utf8String, "SourceFace")
        XCTAssertFalse(source.hasPlatformFontBacking)
    }

    func testResourceFontsRemainSeparateAcrossSchemesAndViewportChanges() throws {
        func scheme(_ tall: Int) throws -> SourceVGUIScheme {
            try SourceVGUIScheme(source: """
                Scheme { BaseSettings {
                    Label.TextColor "1 2 3 255" Label.TextDullColor "4 5 6 255"
                    Label.TextBrightColor "7 8 9 255" Label.DisabledFgColor1 "10 11 12 255"
                } Fonts { Default { "1" { name SourceFace tall \(tall) weight 700 underline 1 } } } }
                """, activeSymbols: ["WIN32", "WINDOWS"])
        }
        let files = try GMLuaHostDirectoryFileSystem(rootURL: GModGameAssets.clientContentRootURL(), writable: false)
        let session = GMLuaMenuSession(fileSystem: files, logger: { _ in })
        defer { _ = session.close() }
        _ = try session.start()
        func resource(_ text: String, _ y: Int) throws -> SourceVGUIResource {
            try SourceVGUIResource(source: """
                test { Caption { ControlName Label labelText \(text) font Default xpos 20 ypos \(y) wide 200 tall 35 } }
                """)
        }
        let legacy = try session.loadResource(resource("Legacy", 10)) { _ in }
        try legacy.layout(viewportWidth: 640, viewportHeight: 480)
        func captured(_ frame: GMLuaSurfaceFrameSnapshot, _ text: String) throws -> GMLuaFontDescriptor {
            try XCTUnwrap(frame.commands.compactMap { command -> GMLuaFontDescriptor? in
                if case let .text(value, _, font, _, _) = command, value.utf8String == text { return font }; return nil
            }.first)
        }
        let before = try captured(session.renderFrame(viewportWidth: 640, viewportHeight: 480), "Legacy")
        let first = try session.loadResource(resource("ThemeOne", 60), scheme: scheme(16)) { _ in }
        try first.layout(viewportWidth: 640, viewportHeight: 480)
        let second = try session.loadResource(resource("ThemeTwo", 110), scheme: scheme(20)) { _ in }
        try second.layout(viewportWidth: 640, viewportHeight: 480)
        let frame = try session.renderFrame(viewportWidth: 640, viewportHeight: 480)
        let one = try captured(frame, "ThemeOne"); let two = try captured(frame, "ThemeTwo")
        XCTAssertEqual(one.font.utf8String, "SourceFace"); XCTAssertEqual(one.size, 16)
        XCTAssertEqual(two.size, 20); XCTAssertNotEqual(one.name, two.name)
        XCTAssertTrue(one.underline); XCTAssertEqual(one.weight, 700)
        XCTAssertEqual(try captured(frame, "Legacy"), before)
        try first.layout(viewportWidth: 800, viewportHeight: 600)
        XCTAssertEqual(try captured(session.renderFrame(viewportWidth: 800, viewportHeight: 600), "ThemeOne").name, one.name)
        try first.remove()
        XCTAssertThrowsError(try first.layout(viewportWidth: 640, viewportHeight: 480))
    }
}
