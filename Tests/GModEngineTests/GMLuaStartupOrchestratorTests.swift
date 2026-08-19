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
            "lua/autorun/startup_parts/nested.lua",
            "lua/weapons/startup_probe/shared.lua",
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
            .scriptedWeapons,
            .onGamemodeLoaded,
            .postGamemodeLoaded,
            .initialize,
            .initPostEntity
        ])
        XCTAssertEqual(
            result.report.stages.filter { $0.outcome == .skipped }.map(\.stage),
            [.addons]
        )
        XCTAssertEqual(result.report.scriptedWeapons.realm, .server)
        XCTAssertEqual(result.report.scriptedWeapons.directPaths, [
            "lua/weapons/startup_probe/init.lua"
        ])
        XCTAssertEqual(result.report.scriptedWeapons.transitiveIncludePaths, [
            "lua/weapons/startup_probe/shared.lua"
        ])
        try result.runtime.execute(
            """
            assert(table.concat(STARTUP_ORDER, ",") ==
                "base,shared-10,shared-nested,shared-20,server-05,sandbox," ..
                "weapon-shared,weapon-server," ..
                "hook-on,gm-on,hook-post,gm-post,hook-init,gm-init," ..
                "hook-entity,gm-entity")
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
            .clientDermaBootstrap,
            .baseGamemode,
            .sharedAutorun,
            .realmAutorun,
            .addons,
            .clientPostProcessBootstrap,
            .clientVGUIBootstrap,
            .clientMaterialProxyBootstrap,
            .clientDefaultSkinBootstrap,
            .targetGamemode,
            .scriptedWeapons,
            .onGamemodeLoaded,
            .postGamemodeLoaded,
            .initialize,
            .playerConnection,
            .initPostEntity
        ])
        XCTAssertEqual(
            result.report.stages.filter { $0.outcome == .skipped }.map(\.stage),
            [.addons, .playerConnection]
        )
        XCTAssertEqual(result.report.scriptedWeapons.realm, .client)
        XCTAssertEqual(result.report.scriptedWeapons.directPaths, [
            "lua/weapons/startup_probe/cl_init.lua"
        ])
        XCTAssertEqual(result.report.scriptedWeapons.transitiveIncludePaths, [
            "lua/weapons/startup_probe/shared.lua"
        ])
        let dermaStage = try XCTUnwrap(
            result.report.stages.first { $0.stage == .clientDermaBootstrap }
        )
        XCTAssertEqual(dermaStage.directPaths, ["lua/derma/init.lua"])
        XCTAssertEqual(dermaStage.transitiveIncludePaths, [
            "lua/derma/parts/core.lua"
        ])
        let postProcessStage = try XCTUnwrap(
            result.report.stages.first { $0.stage == .clientPostProcessBootstrap }
        )
        XCTAssertEqual(postProcessStage.directPaths, [
            "lua/postprocess/10_first.lua",
            "lua/postprocess/20_second.lua"
        ])
        let vguiStage = try XCTUnwrap(
            result.report.stages.first { $0.stage == .clientVGUIBootstrap }
        )
        XCTAssertEqual(vguiStage.directPaths, [
            "lua/vgui/10_control.lua",
            "lua/vgui/20_control.lua"
        ])
        XCTAssertEqual(vguiStage.transitiveIncludePaths, [
            "lua/vgui/parts/nested.lua"
        ])
        let materialProxyStage = try XCTUnwrap(
            result.report.stages.first { $0.stage == .clientMaterialProxyBootstrap }
        )
        XCTAssertEqual(materialProxyStage.directPaths, ["lua/matproxy/10_proxy.lua"])
        let skinStage = try XCTUnwrap(
            result.report.stages.first { $0.stage == .clientDefaultSkinBootstrap }
        )
        XCTAssertEqual(skinStage.directPaths, ["lua/skins/default.lua"])
        try result.runtime.execute(
            """
            assert(table.concat(STARTUP_ORDER, ",") ==
                "derma,derma-core,base,shared-10,shared-nested,shared-20," ..
                "client-07,post-10,post-20,vgui-10,vgui-nested,vgui-20," ..
                "matproxy-10,skin,sandbox,weapon-shared,weapon-client," ..
                "hook-on,gm-on,hook-post,gm-post,hook-init,gm-init," ..
                "hook-entity,gm-entity")
            assert(CLIENT and not SERVER)
            assert(DERMA_BOOTSTRAPPED and VGUI_BOOTSTRAPPED and DEFAULT_SKIN_LOADED)
            assert(MENU_VGUI_BASE_EXECUTED == nil)
            """,
            sourceName: "=(client startup order assertion)"
        )
    }

    func testExplicitClientConnectionRunsAfterInitializeAndBeforeInitPostEntity() throws {
        let files = try LuaMemoryFileSystem(initialFiles: fixtureFiles())
        let mounted = try mounted(files)
        let session = GMLuaSharedSession()
        let server = GMLuaRuntime(
            realm: .server,
            logger: { _ in },
            netTransport: session.netTransport
        )
        let client = GMLuaRuntime(
            realm: .client,
            logger: { _ in },
            virtualFileSystem: mounted,
            bootstrapMode: .strict,
            netTransport: session.netTransport
        )
        defer {
            _ = client.close()
            _ = server.close()
        }
        try installSyntheticLibraries(in: client)
        try client.execute("EXPECT_CONNECTED = true; assert(LocalPlayer() == NULL)")
        let startup = GMLuaStartupOrchestrator(
            runtime: client,
            fileSystem: mounted,
            playerConnection: {
                try session.connect(
                    server: server,
                    client: client,
                    playerIndex: 12,
                    userID: 112
                )
                try client.execute(
                    """
                    assert(LocalPlayer():IsValid())
                    assert(LocalPlayer() == Entity(12) and LocalPlayer() == Player(112))
                    assert(Player(12) == NULL)
                    table.insert(STARTUP_ORDER, "connection")
                    """
                )
            }
        )

        let report = try startup.start(targetGamemodeNamed: "sandbox")

        XCTAssertTrue(report.playerConnectionModeled)
        XCTAssertEqual(
            report.stages.first { $0.stage == .playerConnection }?.outcome,
            .completed
        )
        try client.execute(
            """
            assert(table.concat(STARTUP_ORDER, ",") ==
                "derma,derma-core,base,shared-10,shared-nested,shared-20," ..
                "client-07,post-10,post-20,vgui-10,vgui-nested,vgui-20," ..
                "matproxy-10,skin,sandbox," ..
                "hook-on,gm-on,hook-post,gm-post,hook-init,gm-init," ..
                "connection,hook-entity,gm-entity")
            """
        )
    }

    func testExplicitClientConnectionFailureStopsBeforeInitPostEntity() throws {
        let files = try LuaMemoryFileSystem(initialFiles: fixtureFiles())
        let mounted = try mounted(files)
        let runtime = GMLuaRuntime(
            realm: .client,
            logger: { _ in },
            virtualFileSystem: mounted,
            bootstrapMode: .strict
        )
        defer { _ = runtime.close() }
        try installSyntheticLibraries(in: runtime)
        let startup = GMLuaStartupOrchestrator(
            runtime: runtime,
            fileSystem: mounted,
            playerConnection: {
                throw LuaError.runtime("synthetic connection refusal")
            }
        )

        XCTAssertThrowsError(try startup.start(targetGamemodeNamed: "sandbox")) { error in
            guard case let GMLuaStartupError.playerConnection(reason) = error else {
                return XCTFail("unexpected connection-stage error: \(error)")
            }
            XCTAssertTrue(reason.contains("synthetic connection refusal"))
        }
        XCTAssertEqual(startup.activeStage, .playerConnection)
        XCTAssertFalse(startup.stages.contains { $0.stage == .initPostEntity })
        try runtime.execute(
            """
            assert(table.concat(STARTUP_ORDER, ",") ==
                "derma,derma-core,base,shared-10,shared-nested,shared-20," ..
                "client-07,post-10,post-20,vgui-10,vgui-nested,vgui-20," ..
                "matproxy-10,skin,sandbox," ..
                "hook-on,gm-on,hook-post,gm-post,hook-init,gm-init")
            """
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

    func testClientRequiresDermaAndExactDefaultSkinBootstraps() throws {
        for (missingPath, expectedStage) in [
            ("lua/derma/init.lua", GMLuaStartupStage.clientDermaBootstrap),
            ("lua/skins/default.lua", GMLuaStartupStage.clientDefaultSkinBootstrap)
        ] {
            var files = fixtureFiles()
            files.removeValue(forKey: missingPath)
            let mounted = try mounted(LuaMemoryFileSystem(initialFiles: files))
            let runtime = GMLuaRuntime(
                realm: .client,
                logger: { _ in },
                virtualFileSystem: mounted,
                bootstrapMode: .strict
            )
            defer { _ = runtime.close() }
            try installSyntheticLibraries(in: runtime)
            let startup = GMLuaStartupOrchestrator(runtime: runtime, fileSystem: mounted)

            XCTAssertThrowsError(try startup.start(targetGamemodeNamed: "sandbox")) { error in
                guard case let GMLuaStartupError.clientBootstrap(stage, path, _) = error else {
                    return XCTFail("unexpected missing-bootstrap error: \(error)")
                }
                XCTAssertEqual(stage, expectedStage)
                XCTAssertEqual(path, missingPath)
            }
        }
    }

    func testAbsentClientSpecialDirectoriesAreCompletedWithZeroDirectFiles() throws {
        var files = fixtureFiles().filter { path, _ in
            !path.hasPrefix("lua/postprocess/") &&
                !path.hasPrefix("lua/vgui/") &&
                !path.hasPrefix("lua/matproxy/")
        }
        files["lua/skins/default.lua"] = data(
            "DEFAULT_SKIN_LOADED = true; table.insert(STARTUP_ORDER, 'skin')"
        )
        let mounted = try mounted(LuaMemoryFileSystem(initialFiles: files))
        let runtime = GMLuaRuntime(
            realm: .client,
            logger: { _ in },
            virtualFileSystem: mounted,
            bootstrapMode: .strict
        )
        defer { _ = runtime.close() }
        try installSyntheticLibraries(in: runtime)
        let report = try GMLuaStartupOrchestrator(
            runtime: runtime,
            fileSystem: mounted
        ).start(targetGamemodeNamed: "sandbox")

        for stage in [
            GMLuaStartupStage.clientPostProcessBootstrap,
            .clientVGUIBootstrap,
            .clientMaterialProxyBootstrap
        ] {
            let record = try XCTUnwrap(report.stages.first { $0.stage == stage })
            XCTAssertEqual(record.outcome, .completed)
            XCTAssertTrue(record.directPaths.isEmpty)
            XCTAssertTrue(record.transitiveIncludePaths.isEmpty)
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
        var initialFiles = fixtureFiles()
        initialFiles["gamemodes/sandbox/entities/weapons/startup_probe/init.lua"] = data(
            "assert(SERVER and not CLIENT); include('shared.lua'); " +
                "table.insert(STARTUP_ORDER, 'weapon-server')"
        )
        initialFiles["gamemodes/sandbox/entities/weapons/startup_probe/cl_init.lua"] = data(
            "assert(CLIENT and not SERVER); include('shared.lua'); " +
                "table.insert(STARTUP_ORDER, 'weapon-client')"
        )
        initialFiles["gamemodes/sandbox/entities/weapons/startup_probe/shared.lua"] = data(
            "assert(SWEP.Primary and SWEP.Secondary); " +
                "table.insert(STARTUP_ORDER, 'weapon-shared')"
        )
        let files = try LuaMemoryFileSystem(initialFiles: initialFiles)
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
                "assert(DERMA_BOOTSTRAPPED and not VGUI_BOOTSTRAPPED); " +
                "table.insert(STARTUP_ORDER, 'base'); " +
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
            "lua/derma/init.lua": data(
                "assert(CLIENT and STARTUP_ORDER == nil); " +
                "STARTUP_ORDER = { 'derma' }; DERMA_BOOTSTRAPPED = true; " +
                "include('parts/core.lua')"
            ),
            "lua/derma/parts/core.lua": data(
                "assert(DERMA_BOOTSTRAPPED); table.insert(STARTUP_ORDER, 'derma-core')"
            ),
            "lua/includes/vgui_base.lua": data(
                "MENU_VGUI_BASE_EXECUTED = true; error('menu-only vgui_base executed in CLIENT')"
            ),
            "lua/postprocess/20_second.lua": data(
                "assert(not VGUI_BOOTSTRAPPED); table.insert(STARTUP_ORDER, 'post-20')"
            ),
            "lua/postprocess/10_first.lua": data(
                "assert(not VGUI_BOOTSTRAPPED); table.insert(STARTUP_ORDER, 'post-10')"
            ),
            "lua/postprocess/subdirectory/ignored.lua": data(
                "error('recursive postprocess file was executed')"
            ),
            "lua/vgui/10_control.lua": data(
                "VGUI_BOOTSTRAPPED = true; table.insert(STARTUP_ORDER, 'vgui-10'); " +
                "include('parts/nested.lua')"
            ),
            "lua/vgui/20_control.lua": data(
                "assert(VGUI_BOOTSTRAPPED); table.insert(STARTUP_ORDER, 'vgui-20')"
            ),
            "lua/vgui/parts/nested.lua": data(
                "table.insert(STARTUP_ORDER, 'vgui-nested')"
            ),
            "lua/matproxy/10_proxy.lua": data(
                "assert(VGUI_BOOTSTRAPPED); table.insert(STARTUP_ORDER, 'matproxy-10')"
            ),
            "lua/skins/default.lua": data(
                "assert(VGUI_BOOTSTRAPPED); DEFAULT_SKIN_LOADED = true; " +
                "table.insert(STARTUP_ORDER, 'skin')"
            )
        ]
    }

    private func targetSource() -> String {
        """
        assert(GAMEMODE.FolderName == "base")
        assert(GM.FolderName == "sandbox")
        if CLIENT then assert(DEFAULT_SKIN_LOADED) end
        table.insert(STARTUP_ORDER, "sandbox")
        function GM:OnGamemodeLoaded()
            if CLIENT then assert(LocalPlayer() == NULL) end
            table.insert(STARTUP_ORDER, "gm-on")
        end
        function GM:PostGamemodeLoaded() table.insert(STARTUP_ORDER, "gm-post") end
        function GM:Initialize() table.insert(STARTUP_ORDER, "gm-init") end
        function GM:InitPostEntity()
            if CLIENT and EXPECT_CONNECTED then
                assert(LocalPlayer():IsValid())
            end
            table.insert(STARTUP_ORDER, "gm-entity")
        end
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

            weapons = { values = {} }
            function weapons.Register(value, name)
                value.ClassName = name
                weapons.values[name] = value
            end
            function weapons.GetStored(name) return weapons.values[name] end
            function weapons.OnLoaded() end

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
            hook.Add("OnGamemodeLoaded", "fixture", function()
                if CLIENT then assert(LocalPlayer() == NULL) end
                table.insert(STARTUP_ORDER, "hook-on")
            end)
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
