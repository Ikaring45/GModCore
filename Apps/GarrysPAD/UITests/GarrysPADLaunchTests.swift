import XCTest

final class GarrysPADLaunchTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testRootIsAccessibleAfterLaunch() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()

        let root = app
            .descendants(matching: .any)
            .matching(identifier: "garrys-pad-root")
            .firstMatch
        XCTAssertTrue(
            root.waitForExistence(timeout: 30),
            "GModMainView did not expose the host accessibility root"
        )
    }
}
