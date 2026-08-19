import Foundation
import Testing
@testable import GModEngine

@Suite("Source filesystem search paths")
struct SourceFileSystemTests {
    @Test("head/tail priority, PathIDs, and by-request-only match Source lookup")
    func priorityPathIDsAndRequestOnly() throws {
        let base = try SourceMemoryFileProvider(utf8Files: [
            "Materials/Test.VMT": "base",
            "scripts/base.txt": "base-only"
        ])
        let addon = try SourceMemoryFileProvider(utf8Files: [
            "materials/test.vmt": "addon",
            "scripts/private.txt": "private"
        ])
        let fileSystem = SourceSearchPathFileSystem()
        _ = try fileSystem.addSearchPath(
            provider: base,
            name: "base",
            pathIDs: ["GAME"],
            add: .tail
        )
        _ = try fileSystem.addSearchPath(
            provider: addon,
            name: "addon",
            pathIDs: ["GAME", "ADDON_PRIVATE"],
            add: .head
        )

        #expect(String(decoding: try fileSystem.readFile("MATERIALS\\TEST.VMT"), as: UTF8.self)
            == "addon")
        #expect(fileSystem.fileExists("scripts/base.txt", pathID: "game"))
        #expect(fileSystem.fileExists("scripts/private.txt"))

        try fileSystem.markPathIDByRequestOnly("GAME", enabled: true)
        try fileSystem.markPathIDByRequestOnly("ADDON_PRIVATE", enabled: true)
        #expect(!fileSystem.fileExists("materials/test.vmt"))
        #expect(fileSystem.fileExists("materials/test.vmt", pathID: "GAME"))

        try fileSystem.markPathIDByRequestOnly("GAME", enabled: false)
        #expect(fileSystem.fileExists("materials/test.vmt"))
    }

    @Test("pack/non-pack filtering uses Source PathTypeFilter semantics")
    func pathTypeFiltering() throws {
        let loose = try SourceMemoryFileProvider(utf8Files: ["same.txt": "loose"])
        let pack = try SourceMemoryFileProvider(utf8Files: ["same.txt": "pack"])
        let fileSystem = SourceSearchPathFileSystem()
        _ = try fileSystem.addSearchPath(
            provider: pack,
            name: "pak01_dir.vpk",
            pathIDs: ["GAME"],
            kind: .packFile,
            add: .head
        )
        _ = try fileSystem.addSearchPath(
            provider: loose,
            name: "garrysmod",
            pathIDs: ["GAME"],
            kind: .normal,
            add: .tail
        )

        #expect(String(decoding: try fileSystem.readFile("same.txt"), as: UTF8.self) == "pack")
        #expect(String(
            decoding: try fileSystem.readFile("same.txt", filter: .cullPack),
            as: UTF8.self
        ) == "loose")
        #expect(String(
            decoding: try fileSystem.readFile("same.txt", filter: .cullNonPack),
            as: UTF8.self
        ) == "pack")
        #expect(fileSystem.searchPaths(includePackFiles: false).map(\.name) == ["garrysmod"])
    }

    @Test("directory union keeps the first visible node type")
    func directoryUnion() throws {
        let upper = try SourceMemoryFileProvider(utf8Files: [
            "lua/Shared": "upper-file",
            "lua/a.lua": "a"
        ])
        let lower = try SourceMemoryFileProvider(utf8Files: [
            "lua/shared/init.lua": "hidden directory",
            "lua/B.lua": "b"
        ])
        let fileSystem = SourceSearchPathFileSystem()
        _ = try fileSystem.addSearchPath(
            provider: upper,
            name: "upper",
            pathIDs: ["GAME"]
        )
        _ = try fileSystem.addSearchPath(
            provider: lower,
            name: "lower",
            pathIDs: ["GAME"]
        )

        let entries = try fileSystem.listDirectory("LUA")
        #expect(entries == [
            SourceFileSystemEntry(name: "a.lua", isDirectory: false),
            SourceFileSystemEntry(name: "B.lua", isDirectory: false),
            SourceFileSystemEntry(name: "Shared", isDirectory: false)
        ])
    }

    @Test("GameInfo preserves duplicate order, composite IDs, macros and conditionals")
    func gameInfoSearchPaths() throws {
        let source = #"""
        "GameInfo"
        {
            "FileSystem"
            {
                "SearchPaths"
                {
                    game+mod "garrysmod/addons/*"
                    game "|all_source_engine_paths|sourceengine/hl2_misc.vpk"
                    mod+mod_write+default_write_path "|gameinfo_path|."
                    game "optional" [$WIN32]
                }
            }
        }
        """#
        let paths = try SourceGameInfoSearchPathParser.parse(
            source: source,
            macros: [
                "ALL_SOURCE_ENGINE_PATHS": "C:/Steam/GarrysMod/",
                "gameinfo_path": "C:/Steam/GarrysMod/garrysmod/"
            ]
        )
        #expect(paths.map(\.pathIDs) == [
            ["game", "mod"],
            ["game"],
            ["mod", "mod_write", "default_write_path"],
            ["game"]
        ])
        #expect(paths[0].isWildcard)
        #expect(paths[1].resolvedLocation == "C:/Steam/GarrysMod/sourceengine/hl2_misc.vpk")
        #expect(paths[2].resolvedLocation == "C:/Steam/GarrysMod/garrysmod/.")
        #expect(paths[3].conditional == "$WIN32")
    }

    @Test("Removing one composite PathID preserves the other association")
    func compositePathIDRemovalIsAssociationScoped() throws {
        let provider = try SourceMemoryFileProvider(files: [
            "scripts/shared.txt": Data("shared".utf8)
        ])
        let fileSystem = SourceSearchPathFileSystem()
        _ = try fileSystem.addSearchPath(
            provider: provider,
            name: "shared-content",
            pathIDs: ["GAME", "MOD"]
        )

        #expect(fileSystem.removeSearchPath(name: "shared-content", pathID: "game"))
        #expect(!fileSystem.fileExists("scripts/shared.txt", pathID: "GAME"))
        #expect(fileSystem.fileExists("scripts/shared.txt", pathID: "MOD"))
        #expect(fileSystem.searchPaths().map(\.pathIDs) == [["MOD"]])

        fileSystem.removeSearchPaths(pathID: "mod")
        #expect(fileSystem.searchPaths().isEmpty)
    }

    @Test("Composite PathIDs expand into Source-order independent associations")
    func compositePathIDsExpandLikeSequentialAddSearchPathCalls() throws {
        let provider = try SourceMemoryFileProvider(files: ["shared.txt": Data()])
        let tail = SourceSearchPathFileSystem()
        let tailToken = try tail.addSearchPath(
            provider: provider,
            name: "shared",
            pathIDs: ["GAME", "MOD"],
            add: .tail
        )
        #expect(tail.searchPaths().map(\.pathIDs) == [["GAME"], ["MOD"]])
        #expect(tail.searchPaths().allSatisfy { $0.token == tailToken })

        let head = SourceSearchPathFileSystem()
        _ = try head.addSearchPath(
            provider: provider,
            name: "base",
            pathIDs: ["BASE"]
        )
        _ = try head.addSearchPath(
            provider: provider,
            name: "shared",
            pathIDs: ["GAME", "MOD"],
            add: .head
        )
        #expect(head.searchPaths().map(\.pathIDs) == [["MOD"], ["GAME"], ["BASE"]])
    }

    @Test("RemoveSearchPaths strips only the requested association from every mount")
    func removeSearchPathsPreservesOtherCompositeAssociations() throws {
        let first = try SourceMemoryFileProvider(files: ["first.txt": Data()])
        let second = try SourceMemoryFileProvider(files: ["second.txt": Data()])
        let fileSystem = SourceSearchPathFileSystem()
        _ = try fileSystem.addSearchPath(
            provider: first,
            name: "first",
            pathIDs: ["GAME", "MOD"]
        )
        _ = try fileSystem.addSearchPath(
            provider: second,
            name: "second",
            pathIDs: ["MOD"]
        )

        fileSystem.removeSearchPaths(pathID: "MOD")

        #expect(fileSystem.fileExists("first.txt", pathID: "GAME"))
        #expect(!fileSystem.fileExists("first.txt", pathID: "MOD"))
        #expect(fileSystem.searchPaths().map(\.name) == ["first"])
        #expect(fileSystem.searchPaths()[0].pathIDs == ["GAME"])
    }

    @Test("unsafe virtual paths and unresolved macros fail explicitly")
    func invalidPaths() throws {
        #expect(throws: SourceFileSystemError.invalidPath("../outside")) {
            _ = try SourceLogicalPath.normalize("../outside", allowEmpty: false)
        }
        #expect(throws: SourceFileSystemError.invalidPath("C:/absolute")) {
            _ = try SourceLogicalPath.normalize("C:/absolute", allowEmpty: false)
        }

        let source = #"""
        GameInfo { FileSystem { SearchPaths { game "|missing|content" } } }
        """#
        #expect(throws: SourceFileSystemError.unknownSearchPathMacro("missing")) {
            _ = try SourceGameInfoSearchPathParser.parse(source: source, macros: [:])
        }
    }

    @Test("host provider resolves case-insensitively and contains symlinks")
    func hostProviderCaseInsensitivity() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SourceHostProvider-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Materials", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("ok".utf8).write(to: root.appendingPathComponent("Materials/GwenSkin.VMT"))
        defer { try? FileManager.default.removeItem(at: root) }

        let provider = try SourceHostDirectoryProvider(rootURL: root)
        #expect(provider.fileExists(at: "materials/gwenskin.vmt"))
        #expect(String(
            decoding: try provider.readFile(at: "MATERIALS/GWENSKIN.VMT"),
            as: UTF8.self
        ) == "ok")
    }

    @Test("host containment does not fold case-distinct canonical siblings")
    func hostProviderRejectsCaseDistinctSymlinkEscape() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("SourceHostProvider-\(UUID().uuidString)", isDirectory: true)
        let root = parent.appendingPathComponent("Content", isDirectory: true)
        let caseDistinctSibling = parent.appendingPathComponent("content", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        // Case-insensitive hosts cannot create the adversarial sibling. The
        // exact-prefix behavior is exercised on case-sensitive CI/hosts.
        try? FileManager.default.createDirectory(
            at: caseDistinctSibling,
            withIntermediateDirectories: false
        )
        try Data("outside".utf8).write(
            to: caseDistinctSibling.appendingPathComponent("secret.txt")
        )
        guard !FileManager.default.fileExists(
            atPath: root.appendingPathComponent("secret.txt").path
        ) else {
            return
        }
        let link = root.appendingPathComponent("escape", isDirectory: true)
        do {
            try FileManager.default.createSymbolicLink(
                at: link,
                withDestinationURL: caseDistinctSibling
            )
        } catch {
            // Windows may deny symlink creation unless Developer Mode or the
            // SeCreateSymbolicLink privilege is enabled.
            return
        }

        let provider = try SourceHostDirectoryProvider(rootURL: root)
        #expect(!provider.fileExists(at: "escape/secret.txt"))
        #expect(throws: SourceFileSystemError.invalidPath("escape/secret.txt")) {
            _ = try provider.readFile(at: "escape/secret.txt")
        }
    }

    @Test("host containment is revalidated after a symlink target is swapped")
    func hostProviderRevalidatesSwappedSymlink() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("SourceHostProvider-\(UUID().uuidString)", isDirectory: true)
        let root = parent.appendingPathComponent("root", isDirectory: true)
        let inside = root.appendingPathComponent("inside", isDirectory: true)
        let outside = parent.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("inside".utf8).write(to: inside.appendingPathComponent("value.txt"))
        try Data("outside".utf8).write(to: outside.appendingPathComponent("value.txt"))
        defer { try? FileManager.default.removeItem(at: parent) }

        let link = root.appendingPathComponent("current", isDirectory: true)
        do {
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: inside)
        } catch {
            return
        }
        let provider = try SourceHostDirectoryProvider(rootURL: root)
        #expect(String(decoding: try provider.readFile(at: "current/value.txt"), as: UTF8.self) == "inside")

        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        #expect(!provider.fileExists(at: "current/value.txt"))
        #expect(throws: SourceFileSystemError.invalidPath("current/value.txt")) {
            _ = try provider.readFile(at: "current/value.txt")
        }
    }
}
