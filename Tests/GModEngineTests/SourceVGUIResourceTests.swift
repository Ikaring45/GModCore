import XCTest
@testable import GModEngine

final class SourceVGUIResourceTests: XCTestCase {
    func testLoadingResourceCoordinatesFieldsAndUnknownControlsArePreserved() throws {
        let resource = try SourceVGUIResource(source: """
            #base "common.res"
            "Resource/LoadingDialog.res" {
                "LoadingDialog" { "ControlName" "Frame" "xpos" "r10" "ypos" "r10" "wide" "400" "tall" "75" }
                "CancelButton" { "ControlName" "Button" "fieldName" "CancelButton" "command" "Cancel" }
                "Extension" { "ControlName" "CustomNativeControl" "futureSetting" "keep me" }
            }
            """)
        XCTAssertEqual(resource.controls.count, 3)
        XCTAssertEqual(resource.directives.first?.key, "#base")
        XCTAssertEqual(resource.controls[1].value("COMMAND"), "Cancel")
        XCTAssertEqual(resource.controls[2].controlName, "CustomNativeControl")
        XCTAssertEqual(resource.controls[2].value("futureSetting"), "keep me")
        let screen = GMLuaPanelRect(x: 0, y: 0, width: 1_024, height: 768)
        XCTAssertEqual(try resource.controls[0].frame(parent: screen, screen: screen),
                       GMLuaPanelRect(x: 614, y: 683, width: 400, height: 75))
    }

    func testUnsupportedCoordinatesFailRatherThanSilentlyPlacingControlsAtZero() throws {
        let resource = try SourceVGUIResource(source: """
            "test.res" { "Panel" { "xpos" "unknown" "wide" "10" "tall" "10" } }
            """)
        let bounds = GMLuaPanelRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertThrowsError(try resource.controls[0].frame(parent: bounds, screen: bounds))
    }

    func testReferencePlatformSelectionPrecedesFirstCaseInsensitiveLookup() throws {
        let source = """
            #base "shared.res"
            Test {
                Desktop [$WIN32] { ControlName Label labelText Windows [$WINDOWS] labelText Other [!$WINDOWS]
                    WIDE 120 wide 240 }
                Console { ControlName Label } [$X360]
            }
            """
        let preserved = try SourceVGUIResource(source: source)
        XCTAssertEqual(preserved.controls.count, 2)
        XCTAssertEqual(preserved.controls[0].conditional, "$WIN32")
        let selected = try SourceVGUIResource(source: source, activeSymbols: ["win32", "windows"])
        XCTAssertEqual(selected.controls.count, 1)
        XCTAssertEqual(selected.controls[0].value("LABELTEXT"), "Windows")
        XCTAssertEqual(selected.controls[0].value("wide"), "120", "Native KeyValues lookup is first-match")
        XCTAssertNil(selected.controls[0].conditional)
        XCTAssertTrue(selected.controls[0].entries.allSatisfy { $0.conditional == nil })
        XCTAssertEqual(selected.directives.first?.key, "#base", "Selecting a platform must not resolve an include")
        XCTAssertThrowsError(try SourceVGUIResource(source: source, activeSymbols: ["IPAD"]))
        XCTAssertThrowsError(try SourceVGUIResource(source: "Test { P { wide 10 [$UNKNOWN] } }", activeSymbols: []))
        XCTAssertThrowsError(try SourceVGUIResource(source: "Test { P { wide 10 [$WIN32||$LINUX] } }", activeSymbols: []))
    }
}
