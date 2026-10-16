import XCTest
import GModEngine
import GModGameAssets
import GModGameSession

private actor MenuThreadHarness {
    nonisolated let thread = GModMenuSessionThread()
    nonisolated var unownedExecutor: UnownedSerialExecutor { thread.unownedExecutor }

    func exerciseProblems() throws -> (String, Int) {
        thread.preconditionIsCurrentWorker()
        let files = try GMLuaHostDirectoryFileSystem(
            rootURL: GModGameAssets.clientContentRootURL(), writable: false
        )
        let session = GMLuaMenuSession(fileSystem: files, logger: { _ in })
        thread.retainForShutdown(session)
        defer {
            _ = session.close()
            thread.clearShutdownCleanup()
        }
        _ = try session.start()
        try session.updateProblems(["問題画面の診断"])
        try session.updateLuaErrors([
            GMLuaMenuLuaError(realm: "client", message: "日本語のエラー")
        ])
        try session.present(.problems)
        let frame = try session.renderFrame(viewportWidth: 1_024, viewportHeight: 768)
        return (thread.workerIdentity, frame.commands.count)
    }
}

final class GModMenuSessionThreadTests: XCTestCase {
    func testOriginalProblemsRunsOnStableLargeStackActorWorker() async throws {
        let lane = MenuThreadHarness()
        let first = try await lane.exerciseProblems()
        let second = try await lane.exerciseProblems()
        XCTAssertEqual(first.0, second.0)
        XCTAssertGreaterThan(first.1, 0)
        XCTAssertGreaterThan(second.1, 0)
        XCTAssertEqual(GModMenuSessionThread.stackSize, 16 * 1_024 * 1_024)
    }
}
