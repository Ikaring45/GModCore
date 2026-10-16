import XCTest
import GModEngine
import GModGameAssets
@testable import GModApp

final class GModDermaMenuSessionLaneTests: XCTestCase {
    func testOriginalProblemsStartupRenderAndTeardownOnAppActor() async throws {
        let lane = GModDermaMenuSessionLane()
        let files = try GMLuaHostDirectoryFileSystem(
            rootURL: GModGameAssets.clientContentRootURL(), writable: false
        )
        let session = GMLuaMenuSession(fileSystem: files, logger: { _ in })
        try await lane.replace(with: session, generation: 1)
        try await lane.updateProblems(["問題画面の診断"], expectedGeneration: 1)
        try await lane.updateLuaErrors([
            GMLuaMenuLuaError(realm: "client", message: "日本語のエラー")
        ], expectedGeneration: 1)
        let viewport = GMLuaViewportSize(width: 1_024, height: 768)
        for utility: GMLuaMenuUtility in [.problems, .settings, .problems, .console] {
            try await lane.present(utility, viewport: viewport, expectedGeneration: 1)
            let frame = try await lane.renderFrame(viewport: viewport, expectedGeneration: 1)
            XCTAssertFalse(frame.commands.isEmpty)
        }
        try await lane.present(.problems, viewport: viewport, expectedGeneration: 1)
        _ = try await lane.renderFrame(viewport: viewport, expectedGeneration: 1)
        for phase: GMLuaPointerPhase in [.began, .ended] {
            _ = try await lane.submitPointer(.init(
                x: 4, y: 4, viewWidth: 1_024, viewHeight: 768,
                phase: phase, timestamp: 1
            ), viewport: viewport, expectedGeneration: 1)
        }
        _ = try await lane.renderFrame(viewport: viewport, expectedGeneration: 1)
        let actions = try await lane.drainActions(expectedGeneration: 1)
        XCTAssertEqual(actions, [.closeUtility])
        await lane.removeSession(generation: 2)
    }
}
