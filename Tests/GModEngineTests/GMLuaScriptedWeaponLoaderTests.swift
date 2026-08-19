import Foundation
import XCTest
@testable import GModEngine
import GModLua

final class GMLuaScriptedWeaponLoaderTests: XCTestCase {
    func testClientUsesBaseGlobalTargetOrderAndRealmEntries() throws {
        let files = try LuaMemoryFileSystem(initialFiles: [
            "gamemodes/base/entities/weapons/alpha/cl_init.lua": data(
                "assert(CLIENT and not SERVER); CLIENT_TABLE = SWEP; include('shared.lua'); " +
                    "table.insert(LOAD_ORDER, 'alpha-client')"
            ),
            "gamemodes/base/entities/weapons/alpha/shared.lua": data(
                "assert(SWEP == CLIENT_TABLE); table.insert(LOAD_ORDER, 'alpha-shared')"
            ),
            "gamemodes/base/entities/weapons/alpha/init.lua": data(
                "error('server entry executed in client realm')"
            ),
            "lua/weapons/bravo.lua": data(
                "assert(CLIENT and SWEP.Primary and SWEP.Secondary); " +
                    "table.insert(LOAD_ORDER, 'bravo-shared')"
            ),
            "gamemodes/sandbox/entities/weapons/charlie/shared.lua": data(
                "assert(CLIENT); table.insert(LOAD_ORDER, 'charlie-fallback-shared')"
            ),
            "gamemodes/sandbox/entities/weapons/ignored/readme.txt": data(
                "error('non-Lua weapon entry executed')"
            ),
        ])
        let mounted = try self.mounted(files)
        let runtime = GMLuaRuntime(
            realm: .client,
            logger: { _ in },
            virtualFileSystem: mounted,
            bootstrapMode: .strict
        )
        defer { _ = runtime.close() }
        try installWeaponLibrary(in: runtime)

        let report = try GMLuaScriptedWeaponLoader(
            runtime: runtime,
            fileSystem: mounted
        ).load(targetGamemodeNamed: "SandBox")

        XCTAssertEqual(report.roots, [
            "gamemodes/base/entities/weapons",
            "lua/weapons",
            "gamemodes/sandbox/entities/weapons",
        ])
        XCTAssertEqual(report.classes.map(\.className), ["alpha", "bravo", "charlie"])
        XCTAssertEqual(report.directPaths, [
            "lua/weapons/alpha/cl_init.lua",
            "lua/weapons/bravo.lua",
            "lua/weapons/charlie/shared.lua",
        ])
        XCTAssertEqual(report.classes[0].transitiveIncludePaths, [
            "lua/weapons/alpha/shared.lua"
        ])
        XCTAssertEqual(report.classes.map(\.sourceRoot), [
            "gamemodes/base/entities/weapons",
            "lua/weapons",
            "gamemodes/sandbox/entities/weapons",
        ])
        try runtime.execute(
            """
            assert(table.concat(LOAD_ORDER, ",") ==
                "alpha-shared,alpha-client,register-alpha," ..
                "bravo-shared,register-bravo," ..
                "charlie-fallback-shared,register-charlie,on-loaded")
            assert(weapons.GetStored("alpha") == CLIENT_TABLE)
            assert(weapons.GetStored("alpha").Folder == "weapons/alpha")
            assert(SWEP == "previous-swep")
            """
        )
    }

    func testServerSelectsInitAndSharedFallbackWithoutClientEntry() throws {
        let files = try LuaMemoryFileSystem(initialFiles: [
            "gamemodes/base/entities/weapons/alpha/init.lua": data(
                "assert(SERVER and not CLIENT); SERVER_TABLE = SWEP; include('shared.lua'); " +
                    "table.insert(LOAD_ORDER, 'alpha-server')"
            ),
            "gamemodes/base/entities/weapons/alpha/shared.lua": data(
                "assert(SWEP == SERVER_TABLE); table.insert(LOAD_ORDER, 'alpha-shared')"
            ),
            "gamemodes/base/entities/weapons/alpha/cl_init.lua": data(
                "error('client entry executed in server realm')"
            ),
            "lua/weapons/fallback/shared.lua": data(
                "assert(SERVER); table.insert(LOAD_ORDER, 'fallback-shared')"
            ),
        ])
        let mounted = try self.mounted(files)
        let runtime = GMLuaRuntime(
            realm: .server,
            logger: { _ in },
            virtualFileSystem: mounted,
            bootstrapMode: .strict
        )
        defer { _ = runtime.close() }
        try installWeaponLibrary(in: runtime)

        let report = try GMLuaScriptedWeaponLoader(
            runtime: runtime,
            fileSystem: mounted
        ).load(targetGamemodeNamed: "sandbox")

        XCTAssertEqual(report.classes.map(\.entryPath), [
            "lua/weapons/alpha/init.lua",
            "lua/weapons/fallback/shared.lua",
        ])
        try runtime.execute(
            """
            assert(table.concat(LOAD_ORDER, ",") ==
                "alpha-shared,alpha-server,register-alpha," ..
                "fallback-shared,register-fallback,on-loaded")
            assert(weapons.GetStored("alpha") == SERVER_TABLE)
            assert(SWEP == "previous-swep")
            """
        )
    }

    func testMergedNamespaceAppliesFileLevelRootPrecedenceAndCanonicalFolder() throws {
        let files = try LuaMemoryFileSystem(initialFiles: [
            "gamemodes/base/entities/weapons/same/cl_init.lua": data(
                "error('lower realm entry executed')"
            ),
            "gamemodes/base/entities/weapons/same/shared.lua": data(
                "error('base shared should be shadowed by global shared')"
            ),
            "gamemodes/base/entities/weapons/same/stools/base_only.lua": data(
                "base-only"
            ),
            "gamemodes/base/entities/weapons/same/stools/shadow.lua": data(
                "base-shadow"
            ),
            "lua/weapons/same/shared.lua": data(
                "assert(SWEP.Folder == 'weapons/same'); SWEP.sharedOrigin = 'global'"
            ),
            "lua/weapons/same/stools/global_only.lua": data(
                "global-only"
            ),
            "lua/weapons/same/stools/shadow.lua": data(
                "global-shadow"
            ),
            "gamemodes/sandbox/entities/weapons/same/cl_init.lua": data(
                "assert(SWEP.Folder == 'weapons/same'); TARGET_SWEP = SWEP; " +
                    "include('shared.lua'); " +
                    "local found = file.Find(SWEP.Folder .. '/stools/*.lua', 'LUA'); " +
                    "assert(table.concat(found, ',') == " +
                    "'base_only.lua,global_only.lua,shadow.lua,target_only.lua'); " +
                    "assert(file.Read(SWEP.Folder .. '/stools/shadow.lua', 'LUA') == " +
                    "'target-shadow')"
            ),
            "gamemodes/sandbox/entities/weapons/same/stools/target_only.lua": data(
                "target-only"
            ),
            "gamemodes/sandbox/entities/weapons/same/stools/shadow.lua": data(
                "target-shadow"
            ),
        ])
        let mounted = try self.mounted(files)
        let runtime = GMLuaRuntime(
            realm: .client,
            logger: { _ in },
            virtualFileSystem: mounted,
            bootstrapMode: .strict
        )
        defer { _ = runtime.close() }
        try installWeaponLibrary(in: runtime)

        let report = try GMLuaScriptedWeaponLoader(
            runtime: runtime,
            fileSystem: mounted
        ).load(targetGamemodeNamed: "sandbox")

        XCTAssertEqual(report.classes.map(\.className), ["same"])
        XCTAssertEqual(report.classes.map(\.entryPath), ["lua/weapons/same/cl_init.lua"])
        XCTAssertEqual(report.classes.map(\.sourceRoot), [
            "gamemodes/sandbox/entities/weapons"
        ])
        XCTAssertEqual(report.classes[0].transitiveIncludePaths, [
            "lua/weapons/same/shared.lua"
        ])
        try runtime.execute(
            """
            assert(#REGISTERED_TABLES == 1)
            assert(REGISTERED_TABLES[1] == TARGET_SWEP)
            assert(weapons.GetStored("same") == TARGET_SWEP)
            assert(weapons.GetStored("same").Folder == "weapons/same")
            assert(weapons.GetStored("same").sharedOrigin == "global")
            """
        )
    }

    func testFullGamemodeInheritanceChainKeepsIntermediateWeaponRoots() throws {
        let files = try LuaMemoryFileSystem(initialFiles: [
            "gamemodes/base/entities/weapons/base_only.lua": data(
                "table.insert(LOAD_ORDER, 'base-only')"
            ),
            "lua/weapons/global_only.lua": data(
                "table.insert(LOAD_ORDER, 'global-only')"
            ),
            "gamemodes/sandbox/entities/weapons/sandbox_only.lua": data(
                "table.insert(LOAD_ORDER, 'sandbox-only')"
            ),
            "gamemodes/derived/entities/weapons/derived_only.lua": data(
                "table.insert(LOAD_ORDER, 'derived-only')"
            ),
        ])
        let mounted = try self.mounted(files)
        let runtime = GMLuaRuntime(
            realm: .client,
            logger: { _ in },
            virtualFileSystem: mounted,
            bootstrapMode: .strict
        )
        defer { _ = runtime.close() }
        try installWeaponLibrary(in: runtime)

        let report = try GMLuaScriptedWeaponLoader(
            runtime: runtime,
            fileSystem: mounted
        ).load(gamemodeLoadOrder: ["base", "sandbox", "derived"])

        XCTAssertEqual(report.targetGamemode, "derived")
        XCTAssertEqual(report.roots, [
            "gamemodes/base/entities/weapons",
            "lua/weapons",
            "gamemodes/sandbox/entities/weapons",
            "gamemodes/derived/entities/weapons",
        ])
        XCTAssertEqual(report.classes.map(\.className), [
            "base_only", "derived_only", "global_only", "sandbox_only"
        ])
        try runtime.execute(
            """
            assert(table.concat(LOAD_ORDER, ",") ==
                "base-only,register-base_only," ..
                "derived-only,register-derived_only," ..
                "global-only,register-global_only," ..
                "sandbox-only,register-sandbox_only,on-loaded")
            """
        )
    }

    private func installWeaponLibrary(in runtime: GMLuaRuntime) throws {
        try runtime.execute(
            """
            LOAD_ORDER = {}
            REGISTERED_TABLES = {}
            SWEP = "previous-swep"
            weapons = { values = {} }
            function weapons.Register(value, name)
                assert(value == SWEP)
                value.ClassName = name
                weapons.values[name] = value
                table.insert(REGISTERED_TABLES, value)
                table.insert(LOAD_ORDER, "register-" .. name)
            end
            function weapons.GetStored(name) return weapons.values[name] end
            function weapons.OnLoaded() table.insert(LOAD_ORDER, "on-loaded") end
            """,
            sourceName: "=(synthetic weapons library)"
        )
    }

    private func mounted(_ files: LuaVirtualFileSystem) throws -> GMLuaMountedFileSystem {
        GMLuaMountedFileSystem(mounts: [
            try GMLuaFileMount(
                name: "scripted-weapons",
                priority: 0,
                writable: false,
                fileSystem: files
            )
        ])
    }

    private func data(_ source: String) -> Data { Data(source.utf8) }
}
