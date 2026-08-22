import Foundation
import XCTest
import GModEngine
import GModGameAssets
import GModGameSession
import GModLua

final class GMLuaStartupPerformanceCacheTests: XCTestCase {
    func testReadOnlyHostIndexSharesOnlyImmutableMetadataAcrossRealms() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GMLuaReadOnlyIndex-\(UUID().uuidString)", isDirectory: true)
        let lua = root
            .appendingPathComponent("Content", isDirectory: true)
            .appendingPathComponent("Lua", isDirectory: true)
        try FileManager.default.createDirectory(at: lua, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("one".utf8).write(to: lua.appendingPathComponent("One.lua"))
        try Data("two".utf8).write(to: lua.appendingPathComponent("Two.lua"))

        let server = try GMLuaHostDirectoryFileSystem(rootURL: root, writable: false)
        XCTAssertTrue(server.fileExists(at: "CONTENT/LUA/ONE.LUA"))
        XCTAssertEqual(
            try server.readFile(at: "CONTENT/LUA/ONE.LUA"),
            Data("one".utf8)
        )
        XCTAssertFalse(server.fileExists(at: "content/lua/missing.lua"))
        XCTAssertFalse(server.fileExists(at: "content/lua/missing.lua"))
        XCTAssertEqual(try server.listDirectory(at: "content/lua"), [
            LuaVirtualFileSystemEntry(name: "One.lua", isDirectory: false),
            LuaVirtualFileSystemEntry(name: "Two.lua", isDirectory: false),
        ])

        let client = try GMLuaHostDirectoryFileSystem(rootURL: root, writable: false)
        XCTAssertEqual(
            try client.readFile(at: "CONTENT/LUA/ONE.LUA"),
            Data("one".utf8)
        )
        XCTAssertEqual(client.cacheDiagnostics, server.cacheDiagnostics)

        let diagnostics = try XCTUnwrap(client.cacheDiagnostics)
        XCTAssertEqual(diagnostics.directoryEnumerationCount, 3)
        XCTAssertEqual(diagnostics.directorySnapshotHitCount, 12)
        XCTAssertEqual(diagnostics.resolvedPathCacheHitCount, 2)
        XCTAssertEqual(diagnostics.resolvedPathCacheMissCount, 5)
        XCTAssertEqual(diagnostics.missingPathCacheHitCount, 1)
        XCTAssertEqual(diagnostics.dataReadCount, 2)
    }

    /// Opt-in real-content benchmark. It remains skipped in ordinary suites;
    /// set `GMOD_RUN_STARTUP_PERFORMANCE=1` to record cold/warm stage timing,
    /// immutable host enumeration, cache-hit, and actual data-read counts.
    func testBundledPlayableSessionColdWarmProfileWhenRequested() throws {
        guard ProcessInfo.processInfo.environment["GMOD_RUN_STARTUP_PERFORMANCE"] == "1" else {
            throw XCTSkip("set GMOD_RUN_STARTUP_PERFORMANCE=1 for the real startup profile")
        }

        let root = try GModGameAssets.clientContentRootURL()
        let before = GMLuaHostDirectoryFileSystem.cacheDiagnostics(forRootURL: root)
        let cold = try profileSession(label: "cold")
        let afterCold = try XCTUnwrap(
            GMLuaHostDirectoryFileSystem.cacheDiagnostics(forRootURL: root)
        )
        let warm = try profileSession(label: "warm")
        let afterWarm = try XCTUnwrap(
            GMLuaHostDirectoryFileSystem.cacheDiagnostics(forRootURL: root)
        )

        let initialEnumerations = before?.directoryEnumerationCount ?? 0
        let initialReads = before?.dataReadCount ?? 0
        XCTAssertGreaterThan(afterCold.directoryEnumerationCount, initialEnumerations)
        XCTAssertEqual(
            afterWarm.directoryEnumerationCount,
            afterCold.directoryEnumerationCount
        )
        XCTAssertGreaterThan(
            afterWarm.resolvedPathCacheHitCount,
            afterCold.resolvedPathCacheHitCount
        )
        XCTAssertGreaterThan(afterCold.dataReadCount, initialReads)
        XCTAssertGreaterThan(afterWarm.dataReadCount, afterCold.dataReadCount)
        let coldReads = afterCold.dataReadCount - initialReads
        let warmReads = afterWarm.dataReadCount - afterCold.dataReadCount
        XCTAssertEqual(
            warmReads,
            coldReads,
            "immutable metadata caching must not suppress demand-loaded file data reads"
        )

        print("STARTUP_PROFILE cold_seconds=\(cold) warm_seconds=\(warm)")
        print(
            "STARTUP_IO cold_enumerations=" +
                "\(afterCold.directoryEnumerationCount - initialEnumerations) " +
                "warm_enumerations=" +
                "\(afterWarm.directoryEnumerationCount - afterCold.directoryEnumerationCount) " +
                "cold_reads=\(coldReads) " +
                "warm_reads=\(warmReads) " +
                "resolved_hits=\(afterWarm.resolvedPathCacheHitCount) " +
                "missing_hits=\(afterWarm.missingPathCacheHitCount)"
        )
    }

    private func profileSession(label: String) throws -> Double {
        let recorder = StageRecorder()
        let start = Date.timeIntervalSinceReferenceDate
        let session = try GModPlayableSession(
            configuration: .init(map: .flatgrass),
            progress: { progress in recorder.append(progress.stage) }
        )
        let elapsed = Date.timeIntervalSinceReferenceDate - start
        print("STARTUP_STAGES \(label) \(recorder.report(finalTime: Date.timeIntervalSinceReferenceDate))")
        _ = try session.close()
        return elapsed
    }
}

private final class StageRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [(GModPlayableSessionLoadingStage, TimeInterval)] = []

    func append(_ stage: GModPlayableSessionLoadingStage) {
        lock.lock()
        records.append((stage, Date.timeIntervalSinceReferenceDate))
        lock.unlock()
    }

    func report(finalTime: TimeInterval) -> String {
        lock.lock()
        defer { lock.unlock() }
        guard !records.isEmpty else { return "<no stages>" }
        var result: [String] = []
        for index in records.indices {
            let end = index + 1 < records.count ? records[index + 1].1 : finalTime
            result.append(
                "\(records[index].0)=\(String(format: "%.3f", end - records[index].1))s"
            )
        }
        return result.joined(separator: ",")
    }
}
