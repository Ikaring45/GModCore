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
}
