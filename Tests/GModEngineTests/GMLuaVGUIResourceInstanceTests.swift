import XCTest
import GModEngine
import GModGameAssets

final class GMLuaVGUIResourceInstanceTests: XCTestCase {
    func testNativeResourceButtonsDoNotSwallowRapidRepeatedPressesAsDermaDoubleClicks() throws {
        let files = try GMLuaHostDirectoryFileSystem(rootURL: GModGameAssets.clientContentRootURL(), writable: false)
        let session = GMLuaMenuSession(fileSystem: files, logger: { _ in })
        defer { _ = session.close() }
        _ = try session.start()
        let resource = try SourceVGUIResource(source: """
            Native {
                Apply { ControlName Button labelText Apply command Apply xpos 20 ypos 20 wide 150 tall 30 }
                Toggle { ControlName CheckButton labelText Toggle selected 0 xpos 20 ypos 70 wide 150 tall 30 }
            }
            """)
        var commands: [String] = []
        let instance = try session.loadResource(resource) { commands.append($0) }
        try instance.layout(viewportWidth: 640, viewportHeight: 480)
        _ = try session.renderFrame(viewportWidth: 640, viewportHeight: 480)
        for index in 0..<3 {
            for phase: GMLuaPointerPhase in [.began, .ended] {
                _ = try session.dispatchPointerEvent(x: 60, y: 35, phase: phase, timestamp: Double(index) * 0.01,
                    viewportWidth: 640, viewportHeight: 480)
            }
        }
        XCTAssertEqual(commands, ["Apply", "Apply", "Apply"])
        for index in 0..<2 {
            for phase: GMLuaPointerPhase in [.began, .ended] {
                _ = try session.dispatchPointerEvent(x: 26, y: 85, phase: phase, timestamp: 1 + Double(index) * 0.01,
                    viewportWidth: 640, viewportHeight: 480)
            }
            XCTAssertEqual(try instance.isChecked(control: "Toggle"), index == 0)
        }
    }

    func testResourceCvarSliderUsesRealBoundsDeferredApplyAndExternalValue() throws {
        let files = try GMLuaHostDirectoryFileSystem(rootURL: GModGameAssets.clientContentRootURL(), writable: false)
        let catalog = try GMLuaEngineConVarCatalog(descriptors: [
            .init(name: "fps_max", defaultValue: "60", minimum: 40, maximum: 144)
        ])
        let session = GMLuaMenuSession(fileSystem: files, engineConVarCatalog: catalog, logger: { _ in })
        defer { _ = session.close() }
        _ = try session.start()
        let resource = try SourceVGUIResource(source: """
            "settings.res" { "FPS" { "ControlName" "CCvarSlider" "cvar_name" "fps_max"
                "minvalue" "30" "maxvalue" "300" "allowoutofrange" "0"
                "xpos" "20" "ypos" "20" "wide" "200" "tall" "50" } }
            """)
        let instance = try session.loadResource(resource) { _ in }
        try instance.layout(viewportWidth: 640, viewportHeight: 480)
        XCTAssertTrue(instance.unappliedFields.isEmpty)
        XCTAssertEqual(try instance.sliderValue(control: "FPS"), 60)
        XCTAssertFalse(try instance.sliderHasBeenModified(control: "FPS"))
        try instance.setSliderValue(60.129, control: "FPS")
        XCTAssertEqual(try instance.sliderValue(control: "FPS"), 60.12, "Native storage truncates at hundredth ticks")
        try instance.setSliderValue(200, control: "FPS")
        XCTAssertEqual(try instance.sliderValue(control: "FPS"), 144)
        XCTAssertEqual(catalog.currentValue(for: "fps_max"), "60", "Editing must not apply prematurely")
        XCTAssertTrue(try instance.sliderHasBeenModified(control: "FPS"))
        try instance.applySliderChanges(control: "FPS")
        XCTAssertEqual(Double(try XCTUnwrap(catalog.currentValue(for: "fps_max"))), 144)
        XCTAssertTrue(catalog.setCurrentValue("72", for: "fps_max"))
        let frame = try session.renderFrame(viewportWidth: 640, viewportHeight: 480)
        XCTAssertEqual(try instance.sliderValue(control: "FPS"), 72)
        XCTAssertTrue(frame.commands.contains {
            if case let .rectangle(rect, _, _) = $0 {
                return rect.width == 8 && rect.height == 16 && rect.x == 77 && rect.y == 22
            }; return false
        }, "External ConVar changes must move the thumb in the same captured frame")
        let captions = frame.commands.compactMap { command -> String? in
            if case let .text(text, _, _, _, _) = command { return text.utf8String }; return nil
        }
        XCTAssertTrue(captions.contains("40.00")); XCTAssertTrue(captions.contains("144.00"))
        XCTAssertEqual(frame.commands.filter {
            if case let .rectangle(rect, _, _) = $0 { return rect.width == 1 && rect.height == 5 }; return false
        }.count, 11)
        try instance.setSliderValue(20, control: "FPS")
        XCTAssertEqual(try instance.sliderValue(control: "FPS"), 40)
        try instance.resetSlider(control: "FPS")
        XCTAssertEqual(try instance.sliderValue(control: "FPS"), 72)
        XCTAssertTrue(try instance.sliderHasBeenModified(control: "FPS"), "Native modified-once flag is sticky across Reset")
        XCTAssertThrowsError(try instance.setSliderValue(.nan, control: "FPS"))
    }

    func testResourceCvarSliderPointerReleaseAppliesLiveCatalog() throws {
        let files = try GMLuaHostDirectoryFileSystem(rootURL: GModGameAssets.clientContentRootURL(), writable: false)
        let catalog = try GMLuaEngineConVarCatalog(descriptors: [.init(name: "test_slider", defaultValue: "25")])
        let session = GMLuaMenuSession(fileSystem: files, engineConVarCatalog: catalog, logger: { _ in })
        defer { _ = session.close() }
        _ = try session.start()
        let resource = try SourceVGUIResource(source: """
            "settings.res" { "Volume" { "ControlName" "CCvarSlider" "cvar_name" "test_slider"
                "minvalue" "0" "maxvalue" "100" "xpos" "20" "ypos" "20" "wide" "200" "tall" "50" } }
            """)
        let instance = try session.loadResource(resource) { _ in }
        try instance.layout(viewportWidth: 640, viewportHeight: 480)
        _ = try session.renderFrame(viewportWidth: 640, viewportHeight: 480)
        _ = try session.dispatchPointerEvent(x: 180, y: 30, phase: .began, timestamp: 1,
            viewportWidth: 640, viewportHeight: 480)
        let trackValue = try instance.sliderValue(control: "Volume")
        XCTAssertEqual(trackValue, 83.77, "Native track jump uses width minus thumb minus one, with nearest tick rounding")
        XCTAssertEqual(catalog.currentValue(for: "test_slider"), "25")
        _ = try session.dispatchPointerEvent(x: 200, y: 30, phase: .moved, timestamp: 2,
            viewportWidth: 640, viewportHeight: 480)
        XCTAssertEqual(try instance.sliderValue(control: "Volume"), trackValue,
            "Native default does not begin dragging after a track jump")
        XCTAssertEqual(catalog.currentValue(for: "test_slider"), "25")
        _ = try session.dispatchPointerEvent(x: 200, y: 30, phase: .ended, timestamp: 3,
            viewportWidth: 640, viewportHeight: 480)
        XCTAssertEqual(Double(try XCTUnwrap(catalog.currentValue(for: "test_slider"))),
            try instance.sliderValue(control: "Volume"))
        // Reset to an exactly located thumb: 25% of 184 free pixels = 46.
        try instance.setSliderValue(25, control: "Volume")
        try instance.applySliderChanges(control: "Volume")
        _ = try session.renderFrame(viewportWidth: 640, viewportHeight: 480)
        _ = try session.dispatchPointerEvent(x: 70, y: 30, phase: .began, timestamp: 4,
            viewportWidth: 640, viewportHeight: 480)
        XCTAssertEqual(try instance.sliderValue(control: "Volume"), 25, "Pressing the thumb must not jump its value")
        _ = try session.dispatchPointerEvent(x: 116, y: 30, phase: .moved, timestamp: 5,
            viewportWidth: 640, viewportHeight: 480)
        XCTAssertEqual(try instance.sliderValue(control: "Volume"), 50, "Drag retains the initial press offset")
        XCTAssertEqual(Double(try XCTUnwrap(catalog.currentValue(for: "test_slider"))), 25)
        _ = try session.dispatchPointerEvent(x: 116, y: 30, phase: .ended, timestamp: 6,
            viewportWidth: 640, viewportHeight: 480)
        XCTAssertEqual(Double(try XCTUnwrap(catalog.currentValue(for: "test_slider"))), 50)
    }

    func testResourceCvarSliderPreservesAllowedOutOfRangeValueAndConvarBoundsMode() throws {
        let files = try GMLuaHostDirectoryFileSystem(rootURL: GModGameAssets.clientContentRootURL(), writable: false)
        let catalog = try GMLuaEngineConVarCatalog(descriptors: [
            .init(name: "free_slider", defaultValue: "1"),
            .init(name: "bounded_slider", defaultValue: "5", minimum: 2, maximum: 8)
        ])
        let session = GMLuaMenuSession(fileSystem: files, engineConVarCatalog: catalog, logger: { _ in })
        defer { _ = session.close() }
        _ = try session.start()
        let resource = try SourceVGUIResource(source: """
            "settings.res" {
                "Free" { "ControlName" "CCvarSlider" "cvar_name" "free_slider"
                    "minvalue" "0" "maxvalue" "2" "allowoutofrange" "1" }
                "Bounded" { "ControlName" "CCvarSlider" "cvar_name" "bounded_slider"
                    "minvalue" "3" "maxvalue" "7" "use_convar_minmax" "1" }
                "Fractional" { "ControlName" "CCvarSlider" "cvar_name" "free_slider"
                    "minvalue" "0.129" "maxvalue" "1.237" "ypos" "100" "wide" "200" "tall" "50" }
            }
            """)
        let instance = try session.loadResource(resource) { _ in }
        try instance.layout(viewportWidth: 640, viewportHeight: 480)
        let frame = try session.renderFrame(viewportWidth: 640, viewportHeight: 480)
        let captions = frame.commands.compactMap { command -> String? in
            if case let .text(text, _, _, _, _) = command { return text.utf8String }; return nil
        }
        XCTAssertTrue(captions.contains("0.13")); XCTAssertTrue(captions.contains("1.24"),
            "Captions round original bounds, not the truncated integer storage ticks")
        try instance.setSliderValue(3.259, control: "Free")
        XCTAssertEqual(try instance.sliderValue(control: "Free"), 3.259)
        try instance.applySliderChanges(control: "Free")
        XCTAssertEqual(Double(try XCTUnwrap(catalog.currentValue(for: "free_slider"))), 3.259)
        try instance.setSliderValue(0, control: "Bounded")
        XCTAssertEqual(try instance.sliderValue(control: "Bounded"), 2)
        try instance.setSliderValue(9, control: "Bounded")
        XCTAssertEqual(try instance.sliderValue(control: "Bounded"), 8)
    }

    func testResourceCvarSliderRejectsMissingBindingAndInvalidRangesBeforeConstruction() throws {
        let files = try GMLuaHostDirectoryFileSystem(rootURL: GModGameAssets.clientContentRootURL(), writable: false)
        let catalog = try GMLuaEngineConVarCatalog(descriptors: [.init(name: "known", defaultValue: "0.5")])
        let session = GMLuaMenuSession(fileSystem: files, engineConVarCatalog: catalog, logger: { _ in })
        defer { _ = session.close() }
        _ = try session.start()
        for (fields, key) in [
            ("\"cvar_name\" \"unknown\"", "cvar_name"),
            ("\"cvar_name\" \"known\" \"minvalue\" \"nan\"", "minvalue"),
            ("\"cvar_name\" \"known\" \"minvalue\" \"2\" \"maxvalue\" \"1\"", "minvalue/maxvalue"),
            ("\"cvar_name\" \"known\" \"allowoutofrange\" \"2\"", "allowoutofrange")
        ] {
            let resource = try SourceVGUIResource(source: """
                "test.res" { "First" { "ControlName" "Label" "labelText" "must not leak" }
                    "Slider" { "ControlName" "CCvarSlider" \(fields) } }
                """)
            XCTAssertThrowsError(try session.loadResource(resource) { _ in }) { error in
                XCTAssertEqual(error as? GMLuaVGUIResourceInstance.ResourceError,
                    .invalidField(control: "Slider", key: key))
            }
            XCTAssertTrue(try session.renderFrame(viewportWidth: 640, viewportHeight: 480).commands.isEmpty)
        }
    }

    func testResourceFPSInputAppliesNumericMaximumAndUnicodeFields() throws {
        let files = try GMLuaHostDirectoryFileSystem(rootURL: GModGameAssets.clientContentRootURL(), writable: false)
        let session = GMLuaMenuSession(fileSystem: files, logger: { _ in })
        defer { _ = session.close() }
        _ = try session.start()
        let resource = try SourceVGUIResource(source: """
            "settings.res" {
                "FPS" { "ControlName" "TextEntry" "editable" "1" "maxchars" "3"
                    "NumericInputOnly" "1" "unicode" "0"
                    "xpos" "20" "ypos" "20" "wide" "100" "tall" "30" }
            }
            """)
        let instance = try session.loadResource(resource) { _ in }
        try instance.layout(viewportWidth: 640, viewportHeight: 480)
        XCTAssertTrue(instance.unappliedFields.isEmpty)
        _ = try session.renderFrame(viewportWidth: 640, viewportHeight: 480)
        for phase: GMLuaPointerPhase in [.began, .ended] {
            _ = try session.dispatchPointerEvent(x: 80, y: 35, phase: phase, timestamp: 1,
                viewportWidth: 640, viewportHeight: 480)
        }
        _ = try session.insertText("a30語00")
        XCTAssertEqual(try instance.text(control: "FPS"), "300")
        _ = try session.insertText("9")
        XCTAssertEqual(try instance.text(control: "FPS"), "300")
    }

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
            "test.res" { "Unimplemented" { "ControlName" "URLButton" } }
            """)
        XCTAssertThrowsError(try session.loadResource(resource) { _ in })
    }
}
