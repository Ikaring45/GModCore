import Foundation
import XCTest
@testable import GModEngine
import GModLua

final class GMLuaGamemodeLoaderTests: XCTestCase {
    func testBaseFirstRegistrationInheritanceAndDefineBaseClass() throws {
        let (fixtureRoot, files) = try temporaryServerHierarchyFileSystem()
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        let (runtime, loader) = try makeRuntime(fileSystem: files, realm: .server)
        defer { _ = runtime.close() }
        try installSyntheticGamemodeLibrary(in: runtime)

        let report = try loader.loadGamemode(named: "Derived")

        XCTAssertEqual(report.requestedName, "derived")
        XCTAssertEqual(report.loadOrder, ["base", "derived"])
        XCTAssertEqual(report.newlyLoaded, ["base", "derived"])
        XCTAssertEqual(report.entryPaths, [
            "gamemodes/base/gamemode/init.lua",
            "gamemodes/derived/gamemode/init.lua"
        ])
        XCTAssertFalse(report.autorunLoaded)
        XCTAssertFalse(report.addonsLoaded)
        XCTAssertEqual(loader.loadedGamemodeNames, ["base", "derived"])

        try runtime.execute(
            """
            local base = assert(gamemode.Get("base"))
            local derived = assert(gamemode.Get("derived"))
            assert(GM == derived and GAMEMODE == derived)
            assert(GAMEMODE_NAME == "derived")
            assert(base.FolderName == "base")
            assert(base.Folder == "gamemodes/base" and base.Base == "")
            assert(derived.FolderName == "derived")
            assert(derived.Folder == "gamemodes/derived" and derived.Base == "base")
            assert(derived.BaseClass == base)
            assert(derived.BaseSeenDuringLoad == base)
            assert(derived.BaseValue == "base-shared")
            assert(derived.DerivedValue == "derived-shared")
            assert(derived:InheritedMethod() == "base-method")
            assert(base.ThisClass == "gamemode_base")
            assert(derived.ThisClass == "gamemode_derived")
            assert(rawget(_G, "BaseClass") == nil)
            assert(#LOAD_ORDER == 2 and LOAD_ORDER[1] == "base" and LOAD_ORDER[2] == "derived")
            """,
            sourceName: "=(synthetic gamemode hierarchy assertions)"
        )
        XCTAssertEqual(runtime.includedFiles, [
            "gamemodes/base/gamemode/shared.lua",
            "gamemodes/derived/gamemode/shared.lua"
        ])

        let secondReport = try loader.loadGamemode(named: "derived")
        XCTAssertEqual(secondReport.loadOrder, ["base", "derived"])
        XCTAssertEqual(secondReport.newlyLoaded, [])
        XCTAssertEqual(loader.loadedGamemodeNames, ["base", "derived"])
    }

    func testClientRealmSelectsClientEntriesInTheSameHierarchy() throws {
        let files = try LuaMemoryFileSystem(initialFiles: [
            "gamemodes/base/base.txt": data("\"base\" { \"base\" \"\" }"),
            "gamemodes/base/gamemode/cl_init.lua": data(
                "LOAD_ORDER = { 'base-client' }; GM.ClientBase = true"
            ),
            "gamemodes/base/gamemode/init.lua": data("error('server entry selected on client')"),
            "gamemodes/derived/derived.txt": data(
                "\"derived\" { \"base\" \"base\" }"
            ),
            "gamemodes/derived/gamemode/cl_init.lua": data(
                """
                DEFINE_BASECLASS("gamemode_base")
                assert(BaseClass.ClientBase)
                table.insert(LOAD_ORDER, "derived-client")
                GM.ClientDerived = true
                """
            ),
            "gamemodes/derived/gamemode/init.lua": data("error('server entry selected on client')")
        ])
        let (runtime, loader) = try makeRuntime(fileSystem: files, realm: .client)
        defer { _ = runtime.close() }
        try installSyntheticGamemodeLibrary(in: runtime)

        let report = try loader.loadGamemode(named: "derived")
        XCTAssertEqual(report.entryPaths, [
            "gamemodes/base/gamemode/cl_init.lua",
            "gamemodes/derived/gamemode/cl_init.lua"
        ])
        try runtime.execute(
            """
            assert(GAMEMODE.ClientBase and GAMEMODE.ClientDerived)
            assert(#LOAD_ORDER == 2)
            assert(LOAD_ORDER[1] == "base-client" and LOAD_ORDER[2] == "derived-client")
            """
        )
    }

    func testValidationFailuresAndPartialLoadAreExplicit() throws {
        let files = try LuaMemoryFileSystem(initialFiles: [
            "gamemodes/cycle_a/cycle_a.txt": data(
                "\"cycle_a\" { \"base\" \"cycle_b\" }"
            ),
            "gamemodes/cycle_a/gamemode/init.lua": data("return true"),
            "gamemodes/cycle_b/cycle_b.txt": data(
                "\"cycle_b\" { \"base\" \"cycle_a\" }"
            ),
            "gamemodes/cycle_b/gamemode/init.lua": data("return true"),
            "gamemodes/wrong/wrong.txt": data("\"other\" { \"base\" \"\" }"),
            "gamemodes/no_base/no_base.txt": data("\"no_base\" { \"title\" \"No Base\" }"),
            "gamemodes/traversing_base/traversing_base.txt": data(
                "\"traversing_base\" { \"base\" \"../escape\" }"
            ),
            "gamemodes/traversing_base/gamemode/init.lua": data("return true"),
            "gamemodes/no_entry/no_entry.txt": data("\"no_entry\" { \"base\" \"\" }"),
            "gamemodes/missing_parent/missing_parent.txt": data(
                "\"missing_parent\" { \"base\" \"absent\" }"
            ),
            "gamemodes/missing_parent/gamemode/init.lua": data("return true"),
            "gamemodes/unrelated/unrelated.txt": data("\"unrelated\" { \"base\" \"\" }"),
            "gamemodes/unrelated/gamemode/init.lua": data("GM.Unrelated = true"),
            "gamemodes/base_ok/base_ok.txt": data("\"base_ok\" { \"base\" \"\" }"),
            "gamemodes/base_ok/gamemode/init.lua": data("GM.BaseLoaded = true"),
            "gamemodes/child_broken/child_broken.txt": data(
                "\"child_broken\" { \"base\" \"base_ok\" }"
            ),
            "gamemodes/child_broken/gamemode/init.lua": data(
                "PARTIAL_TOUCHED = true; error('synthetic entry explosion')"
            ),
            "gamemodes/child_register/child_register.txt": data(
                "\"child_register\" { \"base\" \"base_ok\" }"
            ),
            "gamemodes/child_register/gamemode/init.lua": data(
                "GM.EntryLoaded = true"
            )
        ])
        let (runtime, loader) = try makeRuntime(fileSystem: files, realm: .server)
        defer { _ = runtime.close() }
        try installSyntheticGamemodeLibrary(in: runtime)

        assertLoaderError(try loader.loadGamemode(named: "../escape")) { error in
            guard case .invalidName = error else {
                return XCTFail("unexpected traversal error: \(error)")
            }
        }
        assertLoaderError(try loader.loadGamemode(named: "unknown")) { error in
            guard case let .unknownManifest(name, path) = error else {
                return XCTFail("unexpected unknown error: \(error)")
            }
            XCTAssertEqual(name, "unknown")
            XCTAssertEqual(path, "gamemodes/unknown/unknown.txt")
        }
        assertLoaderError(try loader.loadGamemode(named: "wrong")) { error in
            guard case .invalidManifest = error else {
                return XCTFail("unexpected root mismatch error: \(error)")
            }
        }
        assertLoaderError(try loader.loadGamemode(named: "no_base")) { error in
            guard case .invalidManifest = error else {
                return XCTFail("unexpected missing-base error: \(error)")
            }
        }
        assertLoaderError(try loader.loadGamemode(named: "traversing_base")) { error in
            guard case let .invalidManifest(name, path, reason) = error else {
                return XCTFail("unexpected manifest traversal error: \(error)")
            }
            XCTAssertEqual(name, "traversing_base")
            XCTAssertEqual(path, "gamemodes/traversing_base/traversing_base.txt")
            XCTAssertTrue(reason.contains("path traversal"), reason)
        }
        assertLoaderError(try loader.loadGamemode(named: "no_entry")) { error in
            guard case let .missingEntry(name, path, realm) = error else {
                return XCTFail("unexpected missing-entry error: \(error)")
            }
            XCTAssertEqual(name, "no_entry")
            XCTAssertEqual(path, "gamemodes/no_entry/gamemode/init.lua")
            XCTAssertEqual(realm, .server)
        }
        assertLoaderError(try loader.loadGamemode(named: "missing_parent")) { error in
            guard case let .unknownManifest(name, _) = error else {
                return XCTFail("unexpected missing-parent error: \(error)")
            }
            XCTAssertEqual(name, "absent")
        }
        assertLoaderError(try loader.loadGamemode(named: "cycle_a")) { error in
            guard case let .inheritanceCycle(chain) = error else {
                return XCTFail("unexpected cycle error: \(error)")
            }
            XCTAssertEqual(chain, ["cycle_a", "cycle_b", "cycle_a"])
        }
        XCTAssertEqual(loader.loadedGamemodeNames, [])
        _ = try loader.loadGamemode(named: "unrelated")
        XCTAssertEqual(loader.loadedGamemodeNames, ["unrelated"])

        try runtime.execute(
            """
            OLD_GM = { marker = "loading" }
            OLD_GAMEMODE = { marker = "active" }
            GM = OLD_GM
            GAMEMODE = OLD_GAMEMODE
            GAMEMODE_NAME = "old"
            """
        )
        assertLoaderError(try loader.loadGamemode(named: "child_broken")) { error in
            guard case let .partialLoad(name, path, phase, registered, reason) = error else {
                return XCTFail("unexpected partial-load error: \(error)")
            }
            XCTAssertEqual(name, "child_broken")
            XCTAssertEqual(path, "gamemodes/child_broken/gamemode/init.lua")
            XCTAssertEqual(phase, .entry)
            XCTAssertEqual(registered, ["base_ok"])
            XCTAssertTrue(reason.contains("synthetic entry explosion"), reason)
        }
        XCTAssertEqual(loader.loadedGamemodeNames, ["unrelated", "base_ok"])
        try runtime.execute(
            """
            assert(PARTIAL_TOUCHED == true)
            assert(GM == OLD_GM and GAMEMODE == OLD_GAMEMODE)
            assert(GAMEMODE_NAME == "old")
            assert(gamemode.Get("base_ok").BaseLoaded)
            assert(gamemode.Get("child_broken") == nil)
            """
        )

        try runtime.execute("REGISTER_FAILURE = 'child_register'")
        assertLoaderError(try loader.loadGamemode(named: "child_register")) { error in
            guard case let .partialLoad(name, path, phase, registered, reason) = error else {
                return XCTFail("unexpected registration partial-load error: \(error)")
            }
            XCTAssertEqual(name, "child_register")
            XCTAssertEqual(path, "gamemodes/child_register/gamemode/init.lua")
            XCTAssertEqual(phase, .registration)
            XCTAssertEqual(registered, [])
            XCTAssertTrue(reason.contains("synthetic registration explosion"), reason)
        }
        XCTAssertEqual(loader.loadedGamemodeNames, ["unrelated", "base_ok"])
        try runtime.execute(
            "assert(gamemode.Get('child_register') == nil and GM == OLD_GM and GAMEMODE == OLD_GAMEMODE)"
        )
    }

    private func temporaryServerHierarchyFileSystem()
        throws -> (URL, GMLuaHostDirectoryFileSystem)
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "GarrysPAD-GamemodeLoader-\(UUID().uuidString)",
            isDirectory: true
        )
        let files: [String: Data] = [
            "gamemodes/base/base.txt": data("\"base\" { \"base\" \"\" }"),
            "gamemodes/base/gamemode/init.lua": data(
                "LOAD_ORDER = LOAD_ORDER or {}; table.insert(LOAD_ORDER, 'base'); include('shared.lua')"
            ),
            "gamemodes/base/gamemode/shared.lua": data(
                "GM.BaseValue = 'base-shared'; function GM:InheritedMethod() return 'base-method' end"
            ),
            "gamemodes/derived/derived.txt": data(
                "\"derived\" { \"base\" \"base\" }"
            ),
            "gamemodes/derived/gamemode/init.lua": data(
                """
                assert(GM.FolderName == "derived")
                assert(GM.Folder == "gamemodes/derived" and GM.Base == "base")
                DEFINE_BASECLASS("gamemode_base")
                GM.BaseSeenDuringLoad = BaseClass
                table.insert(LOAD_ORDER, "derived")
                include("shared.lua")
                """
            ),
            "gamemodes/derived/gamemode/shared.lua": data(
                "GM.DerivedValue = 'derived-shared'"
            )
        ]
        for (logicalPath, contents) in files {
            let destination = logicalPath.split(separator: "/").reduce(root) {
                $0.appendingPathComponent(String($1))
            }
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try contents.write(to: destination)
        }
        return (
            root,
            try GMLuaHostDirectoryFileSystem(rootURL: root, writable: false)
        )
    }

    private func makeRuntime(
        fileSystem: LuaVirtualFileSystem,
        realm: GMLuaRealm
    ) throws -> (GMLuaRuntime, GMLuaGamemodeLoader) {
        let mounted = GMLuaMountedFileSystem(mounts: [
            try GMLuaFileMount(
                name: "synthetic-gamemodes",
                priority: 0,
                writable: false,
                fileSystem: fileSystem
            )
        ])
        let runtime = GMLuaRuntime(
            realm: realm,
            logger: { _ in },
            virtualFileSystem: mounted,
            bootstrapMode: .strict
        )
        return (runtime, try XCTUnwrap(runtime.gamemodeLoader))
    }

    private func installSyntheticGamemodeLibrary(in runtime: GMLuaRuntime) throws {
        try runtime.execute(
            """
            baseclass = { values = {} }
            function baseclass.Get(name)
                baseclass.values[name] = baseclass.values[name] or {}
                return baseclass.values[name]
            end
            function baseclass.Set(name, value)
                local target = baseclass.values[name]
                if target and target ~= value then
                    for key, field in pairs(value) do target[key] = field end
                else
                    target = value
                    baseclass.values[name] = target
                end
                target.ThisClass = name
            end

            gamemode = { values = {} }
            function gamemode.Register(value, name, derived)
                if REGISTER_FAILURE == name then
                    error("synthetic registration explosion for " .. name)
                end
                if name ~= "base" and derived ~= "" then
                    local parent = assert(gamemode.values[derived], "missing base " .. derived)
                    for key, field in pairs(parent) do
                        if value[key] == nil then value[key] = field end
                    end
                    value.BaseClass = parent
                end
                gamemode.values[name] = value
                baseclass.Set("gamemode_" .. name, value)
            end
            function gamemode.Get(name) return gamemode.values[name] end
            """,
            sourceName: "=(synthetic gamemode library)"
        )
    }

    private func assertLoaderError(
        _ expression: @autoclosure () throws -> GMLuaGamemodeLoadReport,
        verify: (GMLuaGamemodeLoaderError) -> Void
    ) {
        XCTAssertThrowsError(try expression()) { error in
            guard let loaderError = error as? GMLuaGamemodeLoaderError else {
                return XCTFail("unexpected non-loader error: \(error)")
            }
            verify(loaderError)
        }
    }

    private func data(_ string: String) -> Data { Data(string.utf8) }
}
