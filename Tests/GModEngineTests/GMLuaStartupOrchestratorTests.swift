import Foundation
import XCTest
@testable import GModEngine
import GModLua

final class GMLuaStartupOrchestratorTests: XCTestCase {
    func testServerStartupIsBaseAutorunTargetAndHostLifecycle() throws {
        let result = try runSyntheticStartup(realm: .server)
        defer { _ = result.runtime.close() }

        XCTAssertEqual(result.report.directAutorunPaths, [
            "lua/autorun/10_shared.lua",
            "lua/autorun/20_shared.lua",
            "lua/autorun/server/05_server.lua"
        ])
        XCTAssertEqual(result.runtime.includedFiles, [
            "lua/autorun/startup_parts/nested.lua"
        ])
        XCTAssertEqual(result.report.autorunTransitiveIncludePaths, [
            "lua/autorun/startup_parts/nested.lua"
        ])
        XCTAssertEqual(result.report.baseReport.newlyLoaded, ["base"])
        XCTAssertEqual(result.report.targetReport.newlyLoaded, ["sandbox"])
        XCTAssertEqual(result.runtime.gamemodeLoader?.loadedGamemodeNames, ["base", "sandbox"])
        XCTAssertFalse(result.report.addonsLoaded)
        XCTAssertFalse(result.report.playerConnectionModeled)
        XCTAssertEqual(result.report.stages.map(\.stage), [
            .baseGamemode,
            .sharedAutorun,
            .realmAutorun,
            .addons,
            .targetGamemode,
            .postGamemodeLoaded,
            .initialize,
            .initPostEntity
        ])
        XCTAssertEqual(
            result.report.stages.filter { $0.outcome == .skipped }.map(\.stage),
            [.addons]
        )
        try result.runtime.execute(
            """
            assert(table.concat(STARTUP_ORDER, ",") ==
                "base,shared-10,shared-nested,shared-20,server-05,sandbox," ..
                "hook-post,gm-post,hook-init,gm-init,hook-entity,gm-entity")
            assert(SERVER and not CLIENT)
            assert(VGUI_BOOTSTRAPPED == nil)
            """,
            sourceName: "=(server startup order assertion)"
        )
    }

    func testClientStartupSelectsClientAutorunAndDoesNotRunServerFiles() throws {
        let result = try runSyntheticStartup(realm: .client)
        defer { _ = result.runtime.close() }

        XCTAssertEqual(result.report.directAutorunPaths, [
            "lua/autorun/10_shared.lua",
            "lua/autorun/20_shared.lua",
            "lua/autorun/client/07_client.lua"
        ])
        XCTAssertEqual(result.report.stages.map(\.stage), [
            .clientVGUIBootstrap,
            .baseGamemode,
            .sharedAutorun,
            .realmAutorun,
            .addons,
            .targetGamemode,
            .postGamemodeLoaded,
            .initialize,
            .playerConnection,
            .initPostEntity
        ])
        XCTAssertEqual(
            result.report.stages.filter { $0.outcome == .skipped }.map(\.stage),
            [.addons, .playerConnection]
        )
        let vguiStage = try XCTUnwrap(
            result.report.stages.first { $0.stage == .clientVGUIBootstrap }
        )
        XCTAssertEqual(vguiStage.directPaths, ["lua/includes/vgui_base.lua"])
        XCTAssertEqual(vguiStage.transitiveIncludePaths, [
            "lua/includes/vgui/fixture_control.lua"
        ])
        try result.runtime.execute(
            """
            assert(table.concat(STARTUP_ORDER, ",") ==
                "vgui-base,vgui-control,base,shared-10,shared-nested,shared-20," ..
                "client-07,sandbox," ..
                "hook-post,gm-post,hook-init,gm-init,hook-entity,gm-entity")
            assert(CLIENT and not SERVER)
            assert(VGUI_BOOTSTRAPPED == true)
            """,
            sourceName: "=(client startup order assertion)"
        )
    }

    func testTargetStageRequiresExplicitBaseAndOrchestratorIsSingleUse() throws {
        let files = try LuaMemoryFileSystem(initialFiles: fixtureFiles())
        let mounted = try mounted(files)
        let runtime = GMLuaRuntime(
            realm: .server,
            logger: { _ in },
            virtualFileSystem: mounted,
            bootstrapMode: .strict
        )
        defer { _ = runtime.close() }
        try installSyntheticLibraries(in: runtime)
        let loader = try XCTUnwrap(runtime.gamemodeLoader)

        XCTAssertThrowsError(try loader.loadTargetGamemode(named: "sandbox")) { error in
            guard case let GMLuaGamemodeLoaderError.baseStageRequired(name) = error else {
                return XCTFail("unexpected staged loader error: \(error)")
            }
            XCTAssertEqual(name, "sandbox")
        }

        let startup = GMLuaStartupOrchestrator(runtime: runtime, fileSystem: mounted)
        _ = try startup.start(targetGamemodeNamed: "sandbox")
        XCTAssertThrowsError(try startup.start(targetGamemodeNamed: "sandbox")) { error in
            guard case GMLuaStartupError.alreadyStarted = error else {
                return XCTFail("unexpected repeated-start error: \(error)")
            }
        }
    }

    func testMenuRealmIsExplicitlyUnsupported() throws {
        let files = try LuaMemoryFileSystem(initialFiles: fixtureFiles())
        let mounted = try mounted(files)
        let runtime = GMLuaRuntime(
            realm: .menu,
            logger: { _ in },
            virtualFileSystem: mounted,
            bootstrapMode: .strict
        )
        defer { _ = runtime.close() }
        let startup = GMLuaStartupOrchestrator(runtime: runtime, fileSystem: mounted)

        XCTAssertThrowsError(try startup.start(targetGamemodeNamed: "sandbox")) { error in
            guard case let GMLuaStartupError.unsupportedRealm(realm) = error else {
                return XCTFail("unexpected menu startup error: \(error)")
            }
            XCTAssertEqual(realm, .menu)
        }
    }

    private func runSyntheticStartup(
        realm: GMLuaRealm
    ) throws -> (runtime: GMLuaRuntime, report: GMLuaStartupReport) {
        let files = try LuaMemoryFileSystem(initialFiles: fixtureFiles())
        let mounted = try mounted(files)
        let runtime = GMLuaRuntime(
            realm: realm,
            logger: { _ in },
            virtualFileSystem: mounted,
            bootstrapMode: .strict
        )
        try installSyntheticLibraries(in: runtime)
        let startup = GMLuaStartupOrchestrator(runtime: runtime, fileSystem: mounted)
        return (runtime, try startup.start(targetGamemodeNamed: "sandbox"))
    }

    private func mounted(
        _ files: LuaVirtualFileSystem
    ) throws -> GMLuaMountedFileSystem {
        GMLuaMountedFileSystem(mounts: [
            try GMLuaFileMount(
                name: "synthetic-startup",
                priority: 0,
                writable: false,
                fileSystem: files
            )
        ])
    }

    private func fixtureFiles() -> [String: Data] {
        [
            "gamemodes/base/base.txt": data("\"base\" { \"base\" \"\" }"),
            "gamemodes/base/gamemode/init.lua": data(
                "STARTUP_ORDER = { 'base' }; GM.BaseLoaded = true"
            ),
            "gamemodes/base/gamemode/cl_init.lua": data(
                "assert(VGUI_BOOTSTRAPPED); table.insert(STARTUP_ORDER, 'base'); " +
                "GM.BaseLoaded = true"
            ),
            "gamemodes/sandbox/sandbox.txt": data(
                "\"sandbox\" { \"base\" \"base\" }"
            ),
            "gamemodes/sandbox/gamemode/init.lua": data(targetSource()),
            "gamemodes/sandbox/gamemode/cl_init.lua": data(targetSource()),
            "lua/autorun/20_shared.lua": data(
                "include('startup_parts/nested.lua'); table.insert(STARTUP_ORDER, 'shared-20')"
            ),
            "lua/autorun/10_shared.lua": data(
                "assert(GAMEMODE.FolderName == 'base'); table.insert(STARTUP_ORDER, 'shared-10')"
            ),
            "lua/autorun/startup_parts/nested.lua": data(
                "table.insert(STARTUP_ORDER, 'shared-nested')"
            ),
            "lua/autorun/not_lua.txt": data("error('non-lua autorun was executed')"),
            "lua/autorun/server/05_server.lua": data(
                "assert(SERVER); table.insert(STARTUP_ORDER, 'server-05')"
            ),
            "lua/autorun/client/07_client.lua": data(
                "assert(CLIENT); table.insert(STARTUP_ORDER, 'client-07')"
            ),
            "lua/includes/vgui_base.lua": data(
                "assert(CLIENT and STARTUP_ORDER == nil); " +
                "STARTUP_ORDER = { 'vgui-base' }; VGUI_BOOTSTRAPPED = true; " +
                "include('vgui/fixture_control.lua')"
            ),
            "lua/includes/vgui/fixture_control.lua": data(
                "assert(VGUI_BOOTSTRAPPED); table.insert(STARTUP_ORDER, 'vgui-control')"
            )
        ]
    }

    private func targetSource() -> String {
        """
        assert(GAMEMODE.FolderName == "base")
        assert(GM.FolderName == "sandbox")
        table.insert(STARTUP_ORDER, "sandbox")
        function GM:PostGamemodeLoaded() table.insert(STARTUP_ORDER, "gm-post") end
        function GM:Initialize() table.insert(STARTUP_ORDER, "gm-init") end
        function GM:InitPostEntity() table.insert(STARTUP_ORDER, "gm-entity") end
        """
    }

    private func installSyntheticLibraries(in runtime: GMLuaRuntime) throws {
        try runtime.execute(
            """
            baseclass = { values = {} }
            function baseclass.Set(name, value) baseclass.values[name] = value end
            function baseclass.Get(name) return baseclass.values[name] end

            gamemode = { values = {} }
            function gamemode.Register(value, name, derived)
                if name ~= "base" then
                    local parent = assert(gamemode.values[derived])
                    for key, field in pairs(parent) do
                        if value[key] == nil then value[key] = field end
                    end
                    value.BaseClass = parent
                end
                gamemode.values[name] = value
                baseclass.Set("gamemode_" .. name, value)
            end
            function gamemode.Get(name) return gamemode.values[name] end

            hook = { values = {} }
            function hook.Add(event, name, callback)
                hook.values[event] = hook.values[event] or {}
                hook.values[event][name] = callback
            end
            function hook.Call(event, gm, ...)
                local values = hook.values[event]
                if values then
                    for _, callback in pairs(values) do
                        local result = callback(...)
                        if result ~= nil then return result end
                    end
                end
                local callback = gm and gm[event]
                if callback then return callback(gm, ...) end
            end
            hook.Add("PostGamemodeLoaded", "fixture", function()
                table.insert(STARTUP_ORDER, "hook-post")
            end)
            hook.Add("Initialize", "fixture", function()
                table.insert(STARTUP_ORDER, "hook-init")
            end)
            hook.Add("InitPostEntity", "fixture", function()
                table.insert(STARTUP_ORDER, "hook-entity")
            end)
            """,
            sourceName: "=(synthetic startup libraries)"
        )
    }

    private func data(_ source: String) -> Data { Data(source.utf8) }
}
