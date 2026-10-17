import XCTest
import GModEngine
import GModGameAssets

final class GMLuaVGUIResourceInstanceTests: XCTestCase {
    func testResourceAppliesLabelInsetsAndPaintFlags() throws {
        let files = try GMLuaHostDirectoryFileSystem(rootURL: GModGameAssets.clientContentRootURL(), writable: false)
        let session = GMLuaMenuSession(fileSystem: files, logger: { _ in })
        defer { _ = session.close() }
        _ = try session.start()
        let resource = try SourceVGUIResource(source: """
            "test.res" {
                "Plain" { "ControlName" "Label" "labelText" "Plain" "xpos" "10" "ypos" "20" "wide" "200" "tall" "40" "textAlignment" "west" }
                "Inset" { "ControlName" "Label" "labelText" "Inset" "xpos" "10" "ypos" "20" "wide" "200" "tall" "40" "textAlignment" "west" "textinsetx" "6" "textinsety" "3" "wrap" "0" "paintbackground" "0" "paintborder" "0" }
            }
            """)
        let instance = try session.loadResource(resource) { _ in }
        try instance.layout(viewportWidth: 640, viewportHeight: 480)
        XCTAssertTrue(instance.unappliedFields.isEmpty)
        let frame = try session.renderFrame(viewportWidth: 640, viewportHeight: 480)
        var positions: [String: (Double, Double)] = [:]
        for command in frame.commands {
            if case let .text(value, position, _, _, _) = command {
                positions[value.utf8String] = (position.x, position.y)
            }
        }
        let plain = try XCTUnwrap(positions["Plain"])
        let inset = try XCTUnwrap(positions["Inset"])
        XCTAssertEqual(inset.0 - plain.0, 6, accuracy: 0.001)
        XCTAssertEqual(inset.1 - plain.1, 3, accuracy: 0.001)
    }

    func testInstalledLoadingResourceCancelUsesRealSessionActionWhenExplicitlySupplied() throws {
        guard let path = ProcessInfo.processInfo.environment["GMOD_LOADING_RESOURCE_TEST_PATH"] else {
            throw XCTSkip("No user-owned installed resource supplied")
        }
        let resource = try SourceVGUIResource(source: String(contentsOfFile: path, encoding: .utf8))
        let files = try GMLuaHostDirectoryFileSystem(rootURL: GModGameAssets.clientContentRootURL(), writable: false)
        let session = GMLuaMenuSession(fileSystem: files, logger: { _ in })
        defer { _ = session.close() }
        _ = try session.start()
        let instance = try session.loadLoadingResource(resource)
        try instance.layout(viewportWidth: 1_024, viewportHeight: 768)
        try instance.setText("Real startup phase", control: "InfoLabel")
        try instance.setProgress(0.37, control: "Progress")
        let frame = try session.renderFrame(viewportWidth: 1_024, viewportHeight: 768)
        XCTAssertTrue(frame.commands.contains {
            if case let .text(value, _, _, _, _) = $0 { return value.utf8String == "Real startup phase" }
            return false
        })
        for phase: GMLuaPointerPhase in [.began, .ended] {
            _ = try session.dispatchPointerEvent(x: 971, y: 736, phase: phase, timestamp: 1,
                                                 viewportWidth: 1_024, viewportHeight: 768)
        }
        XCTAssertEqual(session.drainActions(), [.disconnect])
        XCTAssertFalse(instance.unappliedFields.isEmpty, "This is not a claim of complete native scheme/layout parity")
    }

    func testResourceCreatesRealDermaControlsAndRoutesCancelCommand() throws {
        let files = try GMLuaHostDirectoryFileSystem(
            rootURL: GModGameAssets.clientContentRootURL(), writable: false
        )
        let session = GMLuaMenuSession(fileSystem: files, logger: { _ in })
        defer { _ = session.close() }
        _ = try session.start()
        let resource = try SourceVGUIResource(source: """
            "test.res" {
                "Window" { "ControlName" "Frame" "title" "Resource window" "xpos" "40" "ypos" "40" "wide" "300" "tall" "150" }
                "Info" { "ControlName" "Label" "labelText" "Resource text 日本語" "xpos" "10" "ypos" "40" "wide" "200" "tall" "20" }
                "Cancel" { "ControlName" "Button" "labelText" "Cancel" "command" "Cancel" "xpos" "10" "ypos" "80" "wide" "100" "tall" "32" }
                "Progress" { "ControlName" "ProgressBar" "xpos" "125" "ypos" "80" "wide" "150" "tall" "20" "autoResize" "0" }
            }
            """)
        var commands: [String] = []
        let instance = try session.loadResource(resource, rootControlName: "Window") { commands.append($0) }
        try instance.layout(viewportWidth: 1_024, viewportHeight: 768)
        try instance.setProgress(0.5, control: "Progress")
        let frame = try session.renderFrame(viewportWidth: 1_024, viewportHeight: 768)
        XCTAssertTrue(frame.commands.contains {
            if case let .text(value, _, _, _, _) = $0 { return value.utf8String == "Resource text 日本語" }
            return false
        })
        XCTAssertTrue(instance.unappliedFields.contains { $0.control == "Progress" && $0.key == "autoResize" })
        for phase: GMLuaPointerPhase in [.began, .ended] {
            _ = try session.dispatchPointerEvent(x: 65, y: 135, phase: phase, timestamp: 1,
                                                 viewportWidth: 1_024, viewportHeight: 768)
        }
        XCTAssertEqual(commands, ["Cancel"])
        try instance.remove()
        _ = try session.renderFrame(viewportWidth: 1_024, viewportHeight: 768)
    }

    func testUnknownNativeControlsAreRejectedRatherThanMocked() throws {
        let files = try GMLuaHostDirectoryFileSystem(rootURL: GModGameAssets.clientContentRootURL(), writable: false)
        let session = GMLuaMenuSession(fileSystem: files, logger: { _ in })
        defer { _ = session.close() }
        _ = try session.start()
        let resource = try SourceVGUIResource(source: """
            "test.res" { "Slider" { "ControlName" "CCvarSlider" } }
            """)
        XCTAssertThrowsError(try session.loadResource(resource) { _ in })
    }
}
