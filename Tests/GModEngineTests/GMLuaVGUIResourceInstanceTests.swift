import XCTest
import GModEngine
import GModGameAssets

final class GMLuaVGUIResourceInstanceTests: XCTestCase {
    func testReadOnlyComboResourceUsesRealDropdownAndRetainsLiveChoice() throws {
        let files = try GMLuaHostDirectoryFileSystem(rootURL: GModGameAssets.clientContentRootURL(), writable: false)
        let session = GMLuaMenuSession(fileSystem: files, logger: { _ in })
        defer { _ = session.close() }
        _ = try session.start()
        let resource = try SourceVGUIResource(source: """
            "settings.res" {
                "Mode" { "ControlName" "ComboBox" "editable" "0" "text" "Choose mode"
                    "xpos" "20" "ypos" "20" "wide" "200" "tall" "30" }
            }
            """)
        let instance = try session.loadResource(resource) { _ in }
        try instance.layout(viewportWidth: 640, viewportHeight: 480)
        XCTAssertTrue(instance.unappliedFields.isEmpty)
        XCTAssertNil(try instance.selectedChoiceIndex(control: "Mode"))
        XCTAssertEqual(try instance.text(control: "Mode"), "Choose mode")
        XCTAssertEqual(try instance.addChoice("Zulu mode", control: "Mode"), 1)
        XCTAssertEqual(try instance.addChoice("Alpha mode", control: "Mode"), 2)
        try instance.selectChoice(at: 2, control: "Mode")
        XCTAssertEqual(try instance.text(control: "Mode"), "Alpha mode")
        XCTAssertThrowsError(try instance.selectChoice(at: 3, control: "Mode"))
        XCTAssertEqual(try instance.selectedChoiceIndex(control: "Mode"), 2)
        _ = try session.renderFrame(viewportWidth: 640, viewportHeight: 480)
        for phase: GMLuaPointerPhase in [.began, .ended] {
            _ = try session.dispatchPointerEvent(x: 100, y: 35, phase: phase, timestamp: 1,
                viewportWidth: 640, viewportHeight: 480)
        }
        let opened = try session.renderFrame(viewportWidth: 640, viewportHeight: 480)
        let choicePosition = try XCTUnwrap(opened.commands.compactMap { command -> GMLuaCursorPosition? in
            if case let .text(value, position, _, _, _) = command, value.utf8String == "Zulu mode" { return position }
            return nil
        }.first)
        let alphaY = try XCTUnwrap(opened.commands.compactMap { command -> Double? in
            if case let .text(value, position, _, _, _) = command, value.utf8String == "Alpha mode" { return position.y }
            return nil
        }.max())
        XCTAssertLessThan(choicePosition.y, alphaY, "Choices must retain insertion order, not alphabetical order")
        for phase: GMLuaPointerPhase in [.began, .ended] {
            _ = try session.dispatchPointerEvent(x: choicePosition.x + 5, y: choicePosition.y + 5,
                phase: phase, timestamp: 2, viewportWidth: 640, viewportHeight: 480)
        }
        XCTAssertEqual(try instance.selectedChoiceIndex(control: "Mode"), 1)
        XCTAssertEqual(try instance.text(control: "Mode"), "Zulu mode")
    }

    func testEditableComboResourcesAreRejectedBeforePanelCreation() throws {
        let files = try GMLuaHostDirectoryFileSystem(rootURL: GModGameAssets.clientContentRootURL(), writable: false)
        let session = GMLuaMenuSession(fileSystem: files, logger: { _ in })
        defer { _ = session.close() }
        _ = try session.start()
        for field in ["", "\"editable\" \"1\""] {
            let resource = try SourceVGUIResource(source: """
                "settings.res" { "Mode" { "ControlName" "ComboBox" \(field) } }
                """)
            XCTAssertThrowsError(try session.loadResource(resource) { _ in }) { error in
                XCTAssertEqual(error as? GMLuaVGUIResourceInstance.ResourceError,
                    .invalidField(control: "Mode", key: "editable"))
            }
        }
    }

    func testResourceTextEntryUsesInitialTextAndLiveUserEdits() throws {
        let files = try GMLuaHostDirectoryFileSystem(rootURL: GModGameAssets.clientContentRootURL(), writable: false)
        let session = GMLuaMenuSession(fileSystem: files, logger: { _ in })
        defer { _ = session.close() }
        _ = try session.start()
        let resource = try SourceVGUIResource(source: """
            "settings.res" {
                "Input" { "ControlName" "TextEntry" "text" "player" "editable" "1" "xpos" "20" "ypos" "20" "wide" "200" "tall" "30" }
                "ReadOnly" { "ControlName" "TextEntry" "text" "fixed" "editable" "0" "xpos" "20" "ypos" "80" "wide" "200" "tall" "30" }
            }
            """)
        let instance = try session.loadResource(resource) { _ in }
        try instance.layout(viewportWidth: 640, viewportHeight: 480)
        _ = try session.renderFrame(viewportWidth: 640, viewportHeight: 480)
        XCTAssertTrue(instance.unappliedFields.isEmpty)
        XCTAssertEqual(try instance.text(control: "Input"), "player")
        for phase: GMLuaPointerPhase in [.began, .ended] {
            _ = try session.dispatchPointerEvent(x: 180, y: 35, phase: phase, timestamp: 1,
                viewportWidth: 640, viewportHeight: 480)
        }
        _ = try session.insertText("1")
        XCTAssertEqual(try instance.text(control: "Input"), "1player",
            "SetText initializes the native caret at zero")
        for phase: GMLuaPointerPhase in [.began, .ended] {
            _ = try session.dispatchPointerEvent(x: 180, y: 95, phase: phase, timestamp: 2,
                viewportWidth: 640, viewportHeight: 480)
        }
        _ = try session.insertText("2")
        XCTAssertEqual(try instance.text(control: "ReadOnly"), "fixed")
    }

    func testResourceIdleLayoutPreservesTouchDraggedFrame() throws {
        let files = try GMLuaHostDirectoryFileSystem(rootURL: GModGameAssets.clientContentRootURL(), writable: false)
        let session = GMLuaMenuSession(fileSystem: files, logger: { _ in })
        defer { _ = session.close() }
        _ = try session.start()
        let resource = try SourceVGUIResource(source: """
            "test.res" {
                "Window" { "ControlName" "Frame" "title" "Draggable" "draggable" "1" "xpos" "40" "ypos" "40" "wide" "300" "tall" "150" }
                "Caption" { "ControlName" "Label" "labelText" "Drag marker" "xpos" "10" "ypos" "40" "wide" "200" "tall" "24" }
            }
            """)
        let instance = try session.loadResource(resource, rootControlName: "Window") { _ in }
        try instance.layout(viewportWidth: 640, viewportHeight: 480)
        func markerX() throws -> Double {
            let frame = try session.renderFrame(viewportWidth: 640, viewportHeight: 480)
            return try XCTUnwrap(frame.commands.compactMap { command -> Double? in
                if case let .text(value, position, _, _, _) = command, value.utf8String == "Drag marker" { return position.x }
                return nil
            }.first)
        }
        let before = try markerX()
        for (phase, x, y): (GMLuaPointerPhase, Double, Double) in [(.began, 100, 50), (.moved, 140, 80), (.ended, 140, 80)] {
            _ = try session.dispatchPointerEvent(x: x, y: y, phase: phase, timestamp: 1,
                viewportWidth: 640, viewportHeight: 480)
        }
        let dragged = try markerX()
        XCTAssertEqual(dragged - before, 40, accuracy: 0.001)
        for _ in 0..<5 { try instance.layout(viewportWidth: 640, viewportHeight: 480) }
        XCTAssertEqual(try markerX(), dragged, accuracy: 0.001)
        try instance.layout(viewportWidth: 800, viewportHeight: 600)
        XCTAssertEqual(try markerX(), before, accuracy: 0.001)
    }

    func testResourceCheckButtonRetainsCaptionAndAuthoredSelection() throws {
        let files = try GMLuaHostDirectoryFileSystem(rootURL: GModGameAssets.clientContentRootURL(), writable: false)
        let session = GMLuaMenuSession(fileSystem: files, logger: { _ in })
        defer { _ = session.close() }
        _ = try session.start()
        let resource = try SourceVGUIResource(source: """
            "settings.res" {
                "Toggle" { "ControlName" "CheckButton" "labelText" "Invert mouse" "selected" "1" "xpos" "30" "ypos" "40" "wide" "220" "tall" "24" }
            }
            """)
        let instance = try session.loadResource(resource) { _ in }
        try instance.layout(viewportWidth: 640, viewportHeight: 480)
        XCTAssertTrue(instance.unappliedFields.isEmpty)
        XCTAssertTrue(try instance.isChecked(control: "Toggle"))
        let frame = try session.renderFrame(viewportWidth: 640, viewportHeight: 480)
        XCTAssertTrue(frame.commands.contains {
            if case let .text(value, _, _, _, _) = $0 { return value.utf8String == "Invert mouse" }
            return false
        })
        for phase: GMLuaPointerPhase in [.began, .ended] {
            _ = try session.dispatchPointerEvent(x: 36, y: 52, phase: phase, timestamp: 1,
                viewportWidth: 640, viewportHeight: 480)
        }
        XCTAssertFalse(try instance.isChecked(control: "Toggle"))
        let invalid = try SourceVGUIResource(source: """
            "settings.res" { "Toggle" { "ControlName" "CheckButton" "selected" "yes" } }
            """)
        XCTAssertThrowsError(try session.loadResource(invalid) { _ in })
    }

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
        XCTAssertEqual(frame.commands.filter {
            if case let .rectangle(rect, _, _) = $0 { return rect.width == 8 && rect.height == 12 }
            return false
        }.count, 6, "150px native ProgressBar at 50% draws six complete segments")
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
