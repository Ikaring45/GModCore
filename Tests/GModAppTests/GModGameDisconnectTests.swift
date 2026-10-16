import XCTest
@testable import GModApp

final class GModGameDisconnectTests: XCTestCase {
    @MainActor
    func testDisconnectCancelsStartBeforeFirstActorHopAndReturnsHomeSafeState() async throws {
        let model = GModGameSessionModel(runtimeFactory: GModAppRuntimeFactory())
        model.start(map: .flatgrass)
        XCTAssertTrue(model.isStarting)
        model.disconnect()
        XCTAssertFalse(model.isStarting)
        XCTAssertFalse(model.isReady)
        for _ in 0..<100 where model.isDisconnecting {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(model.isDisconnecting)
        XCTAssertFalse(model.hasActiveSession)
        XCTAssertNil(model.worldScene)
        XCTAssertNil(model.surfaceScene)
        XCTAssertNil(model.startFailure)
    }

    func testStockGameMenuCommandAliasesRouteToRealLifecycle() {
        XCTAssertEqual(GModHomeMenuCommandParser.parse("RunConsoleCommand('gamemenucommand', 'Disconnect')"), .disconnect)
        XCTAssertEqual(GModHomeMenuCommandParser.parse("RunConsoleCommand('gamemenucommand', 'ResumeGame')"), .hideGameUI)
    }
}
