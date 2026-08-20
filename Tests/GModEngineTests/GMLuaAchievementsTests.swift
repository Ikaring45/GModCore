import XCTest
import GModEngine

final class GMLuaAchievementsTests: XCTestCase {
    func testSpawnMenuOpenCapturesOneHostRequestWithoutInventingProgress() throws {
        let runtime = GMLuaRuntime(realm: .client) { _ in }
        let achievements = try XCTUnwrap(runtime.achievements)
        let sink = RequestRecorder()
        achievements.connectRequestSink { request in
            sink.append(request)
        }

        try runtime.execute(
            """
            assert(type(achievements) == "table")
            assert(type(achievements.SpawnMenuOpen) == "function")
            assert(achievements.Count == nil)
            assert(achievements.GetCount == nil)
            assert(achievements.IsAchieved == nil)
            achievements.SpawnMenuOpen()
            """,
            sourceName: "=(stock-shaped achievements SpawnMenuOpen)"
        )

        XCTAssertEqual(achievements.capturedRequests, [.spawnMenuOpened])
        XCTAssertEqual(sink.requests, [.spawnMenuOpened])
        XCTAssertEqual(
            achievements.drainCapturedRequests(),
            GMLuaAchievementRequestBufferSnapshot(
                requests: [.spawnMenuOpened],
                droppedRequestCount: 0,
                didDropCountSaturate: false
            )
        )
        XCTAssertEqual(achievements.capturedRequests, [])
        XCTAssertEqual(achievements.droppedRequestCount, 0)
    }

    func testOfflineRequestBufferIsBoundedAndReportsOverflow() throws {
        let runtime = GMLuaRuntime(realm: .client) { _ in }
        let achievements = try XCTUnwrap(runtime.achievements)
        let overflow = 17

        try runtime.execute(
            """
            for _ = 1, \(GMLuaAchievements.maxBufferedRequests + overflow) do
                achievements.SpawnMenuOpen()
            end
            """,
            sourceName: "=(achievement request buffer overflow)"
        )

        XCTAssertEqual(
            achievements.capturedRequests.count,
            GMLuaAchievements.maxBufferedRequests
        )
        XCTAssertEqual(achievements.droppedRequestCount, UInt64(overflow))
        let drained = achievements.drainCapturedRequests()
        XCTAssertEqual(drained.requests.count, GMLuaAchievements.maxBufferedRequests)
        XCTAssertEqual(drained.droppedRequestCount, UInt64(overflow))
        XCTAssertFalse(drained.didDropCountSaturate)
        XCTAssertEqual(achievements.capturedRequests, [])
        XCTAssertEqual(achievements.droppedRequestCount, 0)
    }

    func testAchievementsLibraryIsNotFabricatedOutsideClientRealm() throws {
        let server = GMLuaRuntime(realm: .server) { _ in }
        let menu = GMLuaRuntime(realm: .menu) { _ in }

        XCTAssertNil(server.achievements)
        XCTAssertNil(menu.achievements)
        try server.execute(
            "assert(achievements == nil)",
            sourceName: "=(server achievements realm boundary)"
        )
        try menu.execute(
            "assert(achievements == nil)",
            sourceName: "=(menu achievements realm boundary)"
        )
    }
}

private final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [GMLuaAchievementRequest] = []

    var requests: [GMLuaAchievementRequest] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ request: GMLuaAchievementRequest) {
        lock.lock()
        storage.append(request)
        lock.unlock()
    }
}
