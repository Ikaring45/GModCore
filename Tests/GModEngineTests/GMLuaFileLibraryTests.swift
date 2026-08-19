import Foundation
import XCTest
@testable import GModEngine
import GModLua

final class GMLuaFileLibraryTests: XCTestCase {
    func testTTTStyleFindDynamicIncludeAndWritableDataOperations() throws {
        let fixtureURL = try XCTUnwrap(
            Bundle.module.url(
                forResource: "GLuaFileLibraryRegression",
                withExtension: "lua",
                subdirectory: "Fixtures"
            ) ?? Bundle.module.url(
                forResource: "GLuaFileLibraryRegression",
                withExtension: "lua"
            )
        )
        let source = try String(contentsOf: fixtureURL, encoding: .utf8)
        let lower = try LuaMemoryFileSystem(initialFiles: [
            "gamemodes/terrortown/gamemode/lang/Alpha.lua": data("return 'alpha'"),
            "gamemodes/terrortown/gamemode/lang/english.lua": data("return 'english'"),
            "gamemodes/terrortown/gamemode/lang/zulu.LUA": data("return 'zulu'"),
            "gamemodes/terrortown/gamemode/lang/notes.txt": data("ignored"),
            "data/legacy.txt": data("lower-only"),
            "data/rename_me.txt": data("from-lower-mount"),
            "lua/includes/init.lua": data("return true")
        ])
        let overlay = try LuaMemoryFileSystem()
        try lower.createDirectory(at: "data/lower_empty_deleted")
        try lower.createDirectory(at: "data/lower_empty_recreated")
        let mounted = GMLuaMountedFileSystem(mounts: [
            try GMLuaFileMount(
                name: "writable-data",
                priority: 100,
                writable: true,
                fileSystem: overlay
            ),
            try GMLuaFileMount(
                name: "read-only-content",
                priority: 0,
                writable: false,
                fileSystem: lower
            )
        ])
        let runtime = GMLuaRuntime(
            realm: .server,
            logger: { _ in },
            virtualFileSystem: mounted,
            bootstrapMode: .strict
        )
        defer { _ = runtime.close() }

        try runtime.execute(
            source,
            sourceName: "@gamemodes/terrortown/gamemode/lang_shd_fixture.lua"
        )

        guard case .boolean(true) = runtime.state.getGlobal("GLUA_FILE_LIBRARY_REGRESSION_OK") else {
            return XCTFail("file library fixture did not reach its success sentinel")
        }
        XCTAssertEqual(runtime.includedFiles, [
            "gamemodes/terrortown/gamemode/lang/Alpha.lua",
            "gamemodes/terrortown/gamemode/lang/english.lua",
            "gamemodes/terrortown/gamemode/lang/zulu.LUA"
        ])
        XCTAssertFalse(mounted.fileExists(at: "data/legacy.txt"))
        XCTAssertFalse(mounted.fileExists(at: "data/rename_me.txt"))
        XCTAssertFalse(mounted.directoryExists(at: "data/lower_empty_deleted"))
        XCTAssertTrue(mounted.directoryExists(at: "data/lower_empty_recreated"))
        XCTAssertEqual(
            try String(decoding: mounted.readFile(at: "data/renamed/result.txt"), as: UTF8.self),
            "from-lower-mount"
        )
        XCTAssertFalse(
            try mounted.listDirectory(at: "data").contains {
                $0.name.lowercased().contains("garrys-pad-vfs-whiteouts")
            }
        )

        // Whiteouts belong to the writable mount, so recreating the mount
        // graph must not resurrect a deleted file from lower content.
        let remounted = GMLuaMountedFileSystem(mounts: [
            try GMLuaFileMount(
                name: "same-writable-data",
                priority: 100,
                writable: true,
                fileSystem: overlay
            ),
            try GMLuaFileMount(
                name: "same-read-only-content",
                priority: 0,
                writable: false,
                fileSystem: lower
            )
        ])
        XCTAssertFalse(remounted.fileExists(at: "data/legacy.txt"))
        XCTAssertFalse(remounted.directoryExists(at: "data/lower_empty_deleted"))
        XCTAssertTrue(remounted.directoryExists(at: "data/lower_empty_recreated"))
        XCTAssertThrowsError(try remounted.readFile(at: "data/legacy.txt"))
    }

    func testExplicitEmptyDirectoriesAndContainment() throws {
        let memory = try LuaMemoryFileSystem()
        try memory.createDirectory(at: "data/One/Two")
        XCTAssertTrue(memory.directoryExists(at: "DATA/one/two"))
        XCTAssertEqual(
            try memory.listDirectory(at: "data/one"),
            [LuaVirtualFileSystemEntry(name: "Two", isDirectory: true)]
        )
        try memory.removeDirectory(at: "data/one/two")
        XCTAssertFalse(memory.directoryExists(at: "data/one/two"))
        XCTAssertThrowsError(try memory.createDirectory(at: "../escape"))
        XCTAssertThrowsError(try memory.writeFile(data("no"), at: "../../escape.txt"))
    }

    func testMemoryRejectsFileAsParentWithoutPartialMutation() throws {
        let memory = try LuaMemoryFileSystem(initialFiles: [
            "parent": data("file-parent"),
            "move-source.txt": data("move-source")
        ])

        XCTAssertThrowsError(try memory.writeFile(data("child"), at: "parent/child.txt"))
        XCTAssertEqual(try memory.readFile(at: "parent"), data("file-parent"))
        XCTAssertFalse(memory.fileExists(at: "parent/child.txt"))
        XCTAssertFalse(memory.directoryExists(at: "parent"))

        XCTAssertThrowsError(
            try memory.moveFile(
                from: "move-source.txt",
                to: "parent/moved.txt"
            )
        )
        XCTAssertEqual(try memory.readFile(at: "move-source.txt"), data("move-source"))
        XCTAssertFalse(memory.fileExists(at: "parent/moved.txt"))

        XCTAssertThrowsError(try memory.createDirectory(at: "parent/child"))
        try memory.createDirectory(at: "directory-source/empty")
        XCTAssertThrowsError(
            try memory.moveDirectory(
                from: "directory-source",
                to: "parent/directory"
            )
        )
        XCTAssertTrue(memory.directoryExists(at: "directory-source/empty"))
        XCTAssertFalse(memory.directoryExists(at: "parent/directory"))

        XCTAssertThrowsError(
            try LuaMemoryFileSystem(initialFiles: [
                "conflict": data("parent"),
                "conflict/child.txt": data("child")
            ])
        )
    }

    private func data(_ value: String) -> Data { Data(value.utf8) }
}
