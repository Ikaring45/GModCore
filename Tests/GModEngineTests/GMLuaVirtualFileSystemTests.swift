import Foundation
import XCTest
import GModEngine
import GModLua

final class GMLuaVirtualFileSystemTests: XCTestCase {
    func testMemoryListingIsCaseInsensitiveDeterministicAndUnicodeSafe() throws {
        let files = try LuaMemoryFileSystem(initialFiles: [
            "Root/İstanbul/Second.txt": Data("2".utf8),
            "Root/alpha.txt": Data("a".utf8),
            "Root/Beta/child.txt": Data("b".utf8),
        ])

        XCTAssertEqual(try files.listDirectory(at: "rOoT"), [
            LuaVirtualFileSystemEntry(name: "alpha.txt", isDirectory: false),
            LuaVirtualFileSystemEntry(name: "Beta", isDirectory: true),
            LuaVirtualFileSystemEntry(name: "İstanbul", isDirectory: true),
        ])
        XCTAssertEqual(
            try files.listDirectory(at: "root/i̇stanbul").map(\.name),
            ["Second.txt"]
        )
        XCTAssertTrue(files.fileExists(at: "ROOT/ALPHA.TXT"))
        XCTAssertThrowsError(try files.listDirectory(at: "../Root"))
    }

    func testHostDirectoryCanCreateNestedTreeFromEmptyRootAndListCaseFolded() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GMLuaHostVFS-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let files = try GMLuaHostDirectoryFileSystem(rootURL: root, writable: true)
        try files.writeFile(Data("ok".utf8), at: "Settings/Presets/Test/1-new.txt")

        XCTAssertEqual(
            try files.readFile(at: "settings/presets/test/1-NEW.TXT"),
            Data("ok".utf8)
        )
        XCTAssertEqual(try files.listDirectory(at: "settings/presets/test"), [
            LuaVirtualFileSystemEntry(name: "1-new.txt", isDirectory: false),
        ])
        XCTAssertThrowsError(try files.writeFile(Data(), at: "../../escape.txt"))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.deletingLastPathComponent().appendingPathComponent("escape.txt").path
            )
        )
    }

    func testMountedListingUnionsPriorityAndExposesVirtualRoots() throws {
        let upper = try LuaMemoryFileSystem(initialFiles: [
            "writable/Lua/Upper.txt": Data("upper".utf8),
        ])
        let lower = try LuaMemoryFileSystem(initialFiles: [
            "content/Lua/upper.TXT": Data("shadowed".utf8),
            "content/Lua/lower.txt": Data("lower".utf8),
        ])
        let mounted = GMLuaMountedFileSystem(mounts: [
            try GMLuaFileMount(
                name: "upper",
                virtualRoot: "game",
                sourceRoot: "writable",
                priority: 100,
                writable: true,
                fileSystem: upper
            ),
            try GMLuaFileMount(
                name: "lower",
                virtualRoot: "game",
                sourceRoot: "content",
                priority: 0,
                fileSystem: lower
            ),
        ])

        XCTAssertEqual(try mounted.listDirectory(at: ""), [
            LuaVirtualFileSystemEntry(name: "game", isDirectory: true),
        ])
        XCTAssertEqual(try mounted.listDirectory(at: "GAME/LUA"), [
            LuaVirtualFileSystemEntry(name: "lower.txt", isDirectory: false),
            LuaVirtualFileSystemEntry(name: "Upper.txt", isDirectory: false),
        ])
        XCTAssertEqual(
            try mounted.readFile(at: "game/lua/UPPER.txt"),
            Data("upper".utf8)
        )
    }

    func testMountedPriorityMakesVisibleNodeTypeMutuallyExclusive() throws {
        let upper = try LuaMemoryFileSystem(initialFiles: [
            "content/collision/dir-wins/upper.txt": Data("upper directory".utf8),
            "content/collision/file-wins": Data("upper file".utf8),
        ])
        let lower = try LuaMemoryFileSystem(initialFiles: [
            "content/collision/dir-wins": Data("lower file".utf8),
            "content/collision/file-wins/lower.txt": Data("lower directory".utf8),
        ])
        let mounted = GMLuaMountedFileSystem(mounts: [
            try GMLuaFileMount(
                name: "upper",
                virtualRoot: "game",
                sourceRoot: "content",
                priority: 100,
                fileSystem: upper
            ),
            try GMLuaFileMount(
                name: "lower",
                virtualRoot: "game",
                sourceRoot: "content",
                priority: 0,
                fileSystem: lower
            ),
        ])

        XCTAssertTrue(mounted.directoryExists(at: "game/collision/dir-wins"))
        XCTAssertFalse(mounted.fileExists(at: "game/collision/dir-wins"))
        XCTAssertEqual(try mounted.listDirectory(at: "game/collision/dir-wins"), [
            LuaVirtualFileSystemEntry(name: "upper.txt", isDirectory: false),
        ])
        XCTAssertThrowsError(try mounted.readFile(at: "game/collision/dir-wins"))

        XCTAssertTrue(mounted.fileExists(at: "game/collision/file-wins"))
        XCTAssertFalse(mounted.directoryExists(at: "game/collision/file-wins"))
        XCTAssertEqual(
            try mounted.readFile(at: "game/collision/file-wins"),
            Data("upper file".utf8)
        )
        XCTAssertThrowsError(try mounted.listDirectory(at: "game/collision/file-wins"))
    }

    func testWhiteoutMasksAllLowerNodeTypesAndRecreationChoosesNewType() throws {
        let overlay = try LuaMemoryFileSystem(initialFiles: [
            "writable/masked/file-wins": Data("upper file".utf8),
        ])
        try overlay.createDirectory(at: "writable/masked/directory-wins")
        let lower = try LuaMemoryFileSystem(initialFiles: [
            "content/masked/file-wins/lower.txt": Data("lower directory".utf8),
            "content/masked/directory-wins": Data("lower file".utf8),
        ])
        let mounted = GMLuaMountedFileSystem(mounts: [
            try GMLuaFileMount(
                name: "overlay",
                virtualRoot: "game",
                sourceRoot: "writable",
                priority: 200,
                writable: true,
                fileSystem: overlay
            ),
            try GMLuaFileMount(
                name: "lower",
                virtualRoot: "game",
                sourceRoot: "content",
                priority: 0,
                fileSystem: lower
            ),
        ])

        try mounted.removeFile(at: "game/masked/file-wins")
        XCTAssertFalse(mounted.fileExists(at: "game/masked/file-wins"))
        XCTAssertFalse(mounted.directoryExists(at: "game/masked/file-wins"))
        XCTAssertThrowsError(try mounted.listDirectory(at: "game/masked/file-wins"))

        try mounted.createDirectory(at: "game/masked/file-wins")
        XCTAssertFalse(mounted.fileExists(at: "game/masked/file-wins"))
        XCTAssertTrue(mounted.directoryExists(at: "game/masked/file-wins"))

        try mounted.removeDirectory(at: "game/masked/directory-wins")
        XCTAssertFalse(mounted.fileExists(at: "game/masked/directory-wins"))
        XCTAssertFalse(mounted.directoryExists(at: "game/masked/directory-wins"))
        XCTAssertThrowsError(try mounted.readFile(at: "game/masked/directory-wins"))

        try mounted.writeFile(
            Data("replacement file".utf8),
            at: "game/masked/directory-wins"
        )
        XCTAssertTrue(mounted.fileExists(at: "game/masked/directory-wins"))
        XCTAssertFalse(mounted.directoryExists(at: "game/masked/directory-wins"))
        XCTAssertEqual(
            try mounted.readFile(at: "game/masked/directory-wins"),
            Data("replacement file".utf8)
        )
    }
}
