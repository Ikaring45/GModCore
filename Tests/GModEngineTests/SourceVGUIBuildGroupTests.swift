import XCTest
@testable import GModEngine
import GModGameAssets

final class SourceVGUIBuildGroupTests: XCTestCase {
    private func session() throws -> GMLuaMenuSession {
        let files = try GMLuaHostDirectoryFileSystem(rootURL: GModGameAssets.clientContentRootURL(), writable: false)
        let session = GMLuaMenuSession(fileSystem: files, logger: { _ in })
        _ = try session.start()
        return session
    }

    func testExistingContextAndControlsMatchBlockKeysAndSurviveResourceRemoval() throws {
        let session = try session()
        defer { _ = session.close() }
        let owner = try session.loadResource(SourceVGUIResource(source: """
            Host {
                HostPage { ControlName EditablePanel fieldName NativePage xpos 20 ypos 30 wide 360 tall 240 }
                CodeEntry { ControlName TextEntry fieldName ExistingEntry text before xpos 8 ypos 40 wide 200 tall 24 }
            }
            """), rootControlName: "NativePage") { _ in }
        try owner.layout(viewportWidth: 640, viewportHeight: 480)
        let context = try owner.existingPanel(control: "NativePage")
        let entry = try owner.existingPanel(control: "ExistingEntry")
        let resource = try SourceVGUIResource(source: """
            Page {
                nAtIvEpAgE { ControlName COptionsSubTest fieldName PageAfterApply xpos 40 ypos 50 wide 300 tall 180 }
                EXISTINGENTRY { ControlName CodeOnlyEntry fieldName ResourceEntry text after xpos 10 ypos 40 wide 200 tall 24 }
                NewButton { ControlName Button labelText Apply command Apply xpos 10 ypos 90 wide 100 tall 24 }
                BuildDialog { ControlName BuildModeDialog wide 300 tall 420 }
            }
            """)
        XCTAssertThrowsError(try session.loadResource(resource, context: context, existingPanels: [entry]) { _ in })
        XCTAssertEqual(try owner.text(control: "ExistingEntry"), "before", "Strict preflight must not partially apply a missing factory")
        var commands: [String] = []
        let page = try session.loadResource(resource, context: context, existingPanels: [entry],
            missingFactoryPolicy: .sourceContinue) { commands.append($0) }
        XCTAssertEqual(page.reusedControls.map(\.name), ["nAtIvEpAgE", "EXISTINGENTRY"])
        XCTAssertEqual(page.reusedControls.map(\.appliedBaseControlName), ["EditablePanel", "TextEntry"])
        XCTAssertEqual(page.skippedControls.map(\.controlName), ["BuildModeDialog"])
        try page.layout(viewportWidth: 640, viewportHeight: 480)
        XCTAssertEqual(try owner.text(control: "ExistingEntry"), "after", "The actual code-created control, not a replacement, was changed")
        _ = try session.renderFrame(viewportWidth: 640, viewportHeight: 480)
        for phase: GMLuaPointerPhase in [.began, .ended] {
            _ = try session.dispatchPointerEvent(x: 70, y: 150, phase: phase, timestamp: 1,
                viewportWidth: 640, viewportHeight: 480)
        }
        XCTAssertEqual(commands, ["Apply"])
        try page.remove()
        XCTAssertTrue(try owner.isVisible(control: "NativePage"))
        XCTAssertEqual(try owner.text(control: "ExistingEntry"), "after")
        XCTAssertThrowsError(try page.setText("removed", control: "ResourceEntry"))
        let remaining = try session.renderFrame(viewportWidth: 640, viewportHeight: 480)
        XCTAssertFalse(remaining.commands.contains {
            if case let .text(value, _, _, _, _) = $0 { return value.utf8String == "Apply" }; return false
        })
        // Panel::ApplySettings can rename fieldName; the next load must read
        // that live name, not cache the previous resource block or API key.
        let again = try session.loadResource(SourceVGUIResource(source: """
            Page { PageAfterApply { ControlName CustomPage xpos 40 ypos 50 wide 300 tall 180 } }
            """), context: context) { _ in }
        XCTAssertEqual(again.reusedControls.count, 1)
        try again.remove()
        try owner.remove()
        XCTAssertThrowsError(try session.loadResource(resource, context: context,
            missingFactoryPolicy: .sourceContinue) { _ in }, "Removed bindings are invalid, not null factories")
    }

    func testContextWithoutMatchingBlockParentsNewControlsAndRejectsOtherRuntime() throws {
        let session = try session()
        let other = try self.session()
        defer { _ = session.close(); _ = other.close() }
        let owner = try session.loadResource(SourceVGUIResource(source: """
            Host { Page { ControlName EditablePanel xpos 100 ypos 60 wide 300 tall 180 } }
            """)) { _ in }
        try owner.layout(viewportWidth: 640, viewportHeight: 480)
        let context = try owner.existingPanel(control: "Page")
        let resource = try SourceVGUIResource(source: """
            Page { Caption { ControlName Label labelText Child textAlignment northwest xpos c-30 ypos 20 wide 80 tall 20 } }
            """)
        XCTAssertThrowsError(try other.loadResource(resource, context: context) { _ in }) { error in
            XCTAssertEqual(error as? GMLuaVGUIResourceInstance.ResourceError, .foreignPanel)
        }
        let page = try session.loadResource(resource, context: context) { _ in }
        try page.layout(viewportWidth: 640, viewportHeight: 480)
        let frame = try session.renderFrame(viewportWidth: 640, viewportHeight: 480)
        XCTAssertTrue(frame.commands.contains {
            if case let .text(text, position, _, _, _) = $0 {
                return text.utf8String == "Child" && position.x == 220
            }; return false
        }, "Centering uses the 300px context, not the 640px screen")
        let resize = try session.loadResource(SourceVGUIResource(source: """
            Host { Page { ControlName CustomPage xpos 100 ypos 60 wide 400 tall 180 } }
            """), context: context) { _ in }
        try resize.layout(viewportWidth: 640, viewportHeight: 480)
        try page.layout(viewportWidth: 640, viewportHeight: 480)
        let resized = try session.renderFrame(viewportWidth: 640, viewportHeight: 480)
        XCTAssertTrue(resized.commands.contains {
            if case let .text(text, position, _, _, _) = $0 {
                return text.utf8String == "Child" && position.x == 270
            }; return false
        }, "A context resize invalidates resource layout even when the screen size did not change")
        let centered = try session.loadResource(SourceVGUIResource(source: """
            Host { Page { ControlName CustomPage xpos c-10 ypos 60 wide 400 tall 180 } }
            """), context: context) { _ in }
        try centered.layout(viewportWidth: 800, viewportHeight: 600)
        try page.layout(viewportWidth: 800, viewportHeight: 600)
        let centeredFrame = try session.renderFrame(viewportWidth: 800, viewportHeight: 600)
        XCTAssertTrue(centeredFrame.commands.contains {
            if case let .text(text, position, _, _, _) = $0 {
                return text.utf8String == "Child" && position.x == 560
            }; return false
        }, "A top-level context uses the requested viewport, not stale WorldPanel metrics before renderFrame")
    }

    func testRepeatedSchemeApplicationReplacesThinkWrapperInsteadOfGrowingCallDepth() throws {
        let files = try GMLuaHostDirectoryFileSystem(rootURL: GModGameAssets.clientContentRootURL(), writable: false)
        let runtime = GMLuaRuntime(realm: .client, logger: { _ in }, virtualFileSystem: files)
        defer { _ = runtime.close() }
        runtime.resourceRegistry?.setMaterialPixelResolver(GMLuaVPKMaterialPixelResolver(
            looseFileSystem: files, archivesInPriorityOrder: []))
        for path in ["lua/includes/init.lua", "lua/derma/init.lua", "lua/vgui/dlabel.lua", "lua/skins/default.lua"] {
            try runtime.loadFile(path)
        }
        try runtime.execute("""
            TEST_SOURCE_LABEL = vgui.Create('DLabel')
            TEST_SOURCE_LABEL.Calls = 0
            TEST_SOURCE_LABEL.Think = function(self)
                self.Calls = self.Calls + 1
                local depth = 1
                while debug.getinfo(depth, 'f') do depth = depth + 1 end
                self.ObservedDepth = depth
            end
            """)
        let panel = try XCTUnwrap(runtime.executeReturningValues("return TEST_SOURCE_LABEL").first)
        let resource = try SourceVGUIResource(source: "Test { Caption { ControlName Label } }")
        let scheme = try SourceVGUIScheme(source: """
            Scheme { BaseSettings { Label.TextColor "10 11 12 255" Label.TextDullColor "20 21 22 255"
                Label.TextBrightColor "30 31 32 255" Label.DisabledFgColor1 "40 41 42 255" } }
            """, activeSymbols: [])
        for _ in 0..<40 {
            try GMLuaVGUIResourceSchemeColors.install(runtime: runtime, panel: panel,
                control: resource.controls[0], scheme: scheme)
        }
        try runtime.execute("""
            TEST_SOURCE_LABEL:Think()
            assert(TEST_SOURCE_LABEL.Calls == 1)
            assert(TEST_SOURCE_LABEL.ObservedDepth <= 6, 'Scheme Think wrappers accumulated')
            TEST_SOURCE_LABEL.Think = function(self) self.ReplacementCalls = (self.ReplacementCalls or 0) + 1 end
            """)
        try GMLuaVGUIResourceSchemeColors.install(runtime: runtime, panel: panel,
            control: resource.controls[0], scheme: scheme)
        try runtime.execute("""
            TEST_SOURCE_LABEL:Think()
            assert(TEST_SOURCE_LABEL.Calls == 1, 'A new host Think must replace the old base callback')
            assert(TEST_SOURCE_LABEL.ReplacementCalls == 1)
            """)
    }

    func testOwnedSevenOptionsResourcesResolveReferencePlatformWithoutClaimingFactories() throws {
        guard let path = ProcessInfo.processInfo.environment["GMOD_CONTENT_PACK_DIAGNOSTIC_PATH"], !path.isEmpty else {
            throw XCTSkip("No user-owned content pack supplied")
        }
        let pack = try GarrysPADContentPack(url: URL(fileURLWithPath: path))
        for path in ["garrysmod/resource/OptionsSubMultiplayer.res", "garrysmod/resource/OptionsSubKeyboard.res",
                     "sourceengine/resource/optionssubmouse.res", "garrysmod/resource/OptionsSubAudio.res",
                     "garrysmod/resource/OptionsSubVideo.res", "garrysmod/resource/OptionsSubVoice.res",
                     "garrysmod/resource/OptionsSubGModLegal.res"] {
            let data = try pack.data(for: path, maximumByteCount: 1_024 * 1_024)
            let source = String(decoding: data, as: UTF8.self)
            let original = try SourceVGUIResource(source: source)
            let windows = try SourceVGUIResource(source: source, activeSymbols: ["WIN32", "WINDOWS"])
            let mac = try SourceVGUIResource(source: source, activeSymbols: ["OSX", "POSIX"])
            XCTAssertFalse(windows.controls.isEmpty, path)
            XCTAssertEqual(windows.controls.count, original.controls.count, path)
            XCTAssertEqual(mac.controls.count, original.controls.count, path)
            for control in windows.controls {
                XCTAssertNil(control.conditional)
                XCTAssertTrue(control.entries.allSatisfy { $0.conditional == nil }, path)
                if let input = original.controls.first(where: { $0.name == control.name }),
                   input.entries.contains(where: { $0.key.lowercased() == "enabled" && $0.conditional != nil }) {
                    XCTAssertEqual(control.value("enabled"), "1", "Owned Windows Mouse controls are enabled")
                    XCTAssertEqual(mac.controls.first(where: { $0.name == control.name })?.value("enabled"), "0",
                        "The same authored OSX/POSIX branches disable those controls")
                }
            }
        }
    }

    func testOwnedUnmodifiedLegalPageLoadsIntoRealContextWithAuthoredPaletteAndCommands() throws {
        guard let path = ProcessInfo.processInfo.environment["GMOD_CONTENT_PACK_DIAGNOSTIC_PATH"], !path.isEmpty else {
            throw XCTSkip("No user-owned content pack supplied")
        }
        let pack = try GarrysPADContentPack(url: URL(fileURLWithPath: path))
        let data = try pack.data(for: "garrysmod/resource/OptionsSubGModLegal.res", maximumByteCount: 1_024 * 1_024)
        let resource = try SourceVGUIResource(source: String(decoding: data, as: UTF8.self), activeSymbols: ["WIN32", "WINDOWS"])
        let schemeData = try pack.data(for: "garrysmod/resource/SourceScheme.res", maximumByteCount: 1_024 * 1_024)
        let scheme = try SourceVGUIScheme(source: String(decoding: schemeData, as: UTF8.self), activeSymbols: ["WIN32", "WINDOWS"])
        let session = try session()
        defer { _ = session.close() }
        let owner = try session.loadResource(SourceVGUIResource(source: """
            Host { OptionsSubGModLegal { ControlName EditablePanel wide 496 tall 314 } }
            """)) { _ in }
        let context = try owner.existingPanel(control: "OptionsSubGModLegal")
        var commands: [String] = []
        let page = try session.loadResource(resource, scheme: scheme, context: context,
            missingFactoryPolicy: .sourceContinue) { commands.append($0) }
        XCTAssertEqual(page.reusedControls.map(\.declaredControlName), ["OptionsSubGModLegal"])
        XCTAssertEqual(page.skippedControls.map(\.controlName), ["BuildModeDialog"])
        XCTAssertTrue(page.unappliedSchemeColorControls.isEmpty)
        XCTAssertFalse(page.unappliedFields.isEmpty, "Loading the authored page does not implement all native page behavior")
        try page.layout(viewportWidth: 1_024, viewportHeight: 768)
        let frame = try session.renderFrame(viewportWidth: 1_024, viewportHeight: 768)
        let panel = try scheme.color("Panel.BgColor")
        let button = try scheme.color("Button.BgColor")
        XCTAssertTrue(frame.commands.contains {
            if case let .rectangle(rect, c, _) = $0 {
                return rect.width == 496 && rect.height == 314 &&
                    c == .init(red: panel.red, green: panel.green, blue: panel.blue, alpha: panel.alpha)
            }; return false
        })
        XCTAssertEqual(frame.commands.filter {
            if case let .rectangle(rect, c, _) = $0 {
                return rect.width == 300 && rect.height == 24 &&
                    c == .init(red: button.red, green: button.green, blue: button.blue, alpha: button.alpha)
            }; return false
        }.count, 5)
        for (index, y) in [64.0, 112, 160, 256, 304].enumerated() {
            for phase: GMLuaPointerPhase in [.began, .ended] {
                _ = try session.dispatchPointerEvent(x: 200, y: y, phase: phase, timestamp: Double(index + 1),
                    viewportWidth: 1_024, viewportHeight: 768)
            }
        }
        XCTAssertEqual(commands, ["PrivacyPolicy", "TermsOfService", "ChromiumCredits", "ServerGuidelines", "ModdingGuidelines"])
        // No guessed URLs, placeholder C++ handlers, or BuildMode editor window.
        try page.remove()
        XCTAssertTrue(try owner.isVisible(control: "OptionsSubGModLegal"))
    }
}
