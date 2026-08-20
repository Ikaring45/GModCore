import Foundation
import XCTest
@testable import GModEngine
import GModGameAssets
import GModLua

final class GModBundledClientContentTests: XCTestCase {
    func testManifestCoversExactAuthorizedBaseClientContent() throws {
        let manifest = try GModGameAssets.clientContentManifest()

        XCTAssertEqual(manifest.formatVersion, 1)
        XCTAssertEqual(manifest.fileCount, 2_162)
        XCTAssertEqual(manifest.files.count, 2_162)
        XCTAssertEqual(manifest.byteCount, 14_689_206)
        XCTAssertEqual(manifest.files.reduce(0) { $0 + $1.byteCount }, 14_689_206)
        XCTAssertEqual(Set(manifest.files.map(\.logicalPath)).count, 2_162)
        XCTAssertEqual(
            Set(manifest.files.map { $0.logicalPath.lowercased() }).count,
            2_162
        )
        XCTAssertEqual(
            manifest.sourceScope,
            "Project-authorized base Garry's Mod lua/, gamemodes/base/, " +
                "gamemodes/sandbox/, all materials/**/*.png entries, and the exact " +
                "generated GModSourceMaterialAllowlist.json VMT/VTF closure from " +
                "garrysmod/garrysmod_dir.vpk and platform/platform_misc_dir.vpk; " +
                "Workshop, cache, addons, downloads, and all other VPK content excluded."
        )
        let sourceMaterialAllowlist = try GModGameAssets.sourceMaterialAllowlist()
        let sourceMaterialPaths = Set(
            sourceMaterialAllowlist.assets.map(\.logicalPath)
        )
        XCTAssertTrue(manifest.files.allSatisfy { entry in
            entry.logicalPath.hasPrefix("lua/") ||
                entry.logicalPath.hasPrefix("gamemodes/base/") ||
                entry.logicalPath.hasPrefix("gamemodes/sandbox/") ||
                (entry.logicalPath.hasPrefix("materials/") &&
                    entry.logicalPath.lowercased().hasSuffix(".png")) ||
                sourceMaterialPaths.contains(entry.logicalPath)
        })
        XCTAssertEqual(
            manifest.files.filter { $0.logicalPath.hasPrefix("materials/") }.count,
            1_698
        )
        XCTAssertEqual(
            manifest.files.filter { $0.logicalPath.hasPrefix("materials/") }
                .reduce(0) { $0 + $1.byteCount },
            12_369_996
        )

        XCTAssertEqual(sourceMaterialAllowlist.schemaVersion, 2)
        XCTAssertEqual(sourceMaterialAllowlist.sourceArchives, [
            "garrysmod/garrysmod_dir.vpk",
            "platform/platform_misc_dir.vpk",
        ])
        XCTAssertEqual(sourceMaterialAllowlist.fileCount, 118)
        XCTAssertEqual(sourceMaterialAllowlist.byteCount, 3_013_414)
        XCTAssertEqual(sourceMaterialAllowlist.vmtCount, 72)
        XCTAssertEqual(sourceMaterialAllowlist.vtfCount, 46)
        XCTAssertEqual(sourceMaterialAllowlist.decodedMip0ByteCount, 8_075_776)
        XCTAssertEqual(Set(sourceMaterialAllowlist.assets.map(\.logicalPath)).count, 118)
        XCTAssertEqual(
            Set(sourceMaterialAllowlist.surfaceTextureMaterialPaths),
            Set([
                "materials/gui/corner16.vmt", "materials/gui/corner32.vmt",
                "materials/gui/corner512.vmt", "materials/gui/corner64.vmt",
                "materials/gui/corner8.vmt", "materials/gui/faceposer_indicator.vmt",
                "materials/gui/gradient.vmt", "materials/gui/icorner8.vmt",
                "materials/gui/info.vmt", "materials/gui/speech_lid.vmt",
                "materials/models/weapons/v_toolgun/screen_bg.vmt",
                "materials/vgui/gmod_camera.vmt", "materials/vgui/gmod_tool.vmt",
                "materials/vgui/white.vmt", "materials/weapons/swep.vmt",
            ])
        )
        XCTAssertTrue(sourceMaterialAllowlist.surfaceTextureMaterialPaths.allSatisfy {
            sourceMaterialPaths.contains($0)
        })
        XCTAssertEqual(
            sourceMaterialAllowlist.unresolvedDynamicBaseTextures,
            [
                "materials/_gmod_frameblend.vtf",
                "materials/_rt_fullframefb.vtf",
                "materials/sprites/glow_test02.vtf",
                "materials/sprites/light_glow01.vtf",
            ]
        )
        XCTAssertEqual(
            Set(sourceMaterialAllowlist.unresolvedMaterialLiterals),
            Set([
                "effects/fire_cloud1", "effects/spark", "effects/strider_muzzle",
                "sprites/heatwave", "sprites/light_glow02_add", "vgui/white_additive",
                "scripted/breen_fakemonitor_1", "../",
            ])
        )

        let expectedFiles: [(String, Int, String)] = [
            ("lua/includes/init.lua", 3_610, "04a0d82fa01f39c7470ae266aabfd1b38fce6ee9abbe01e93d2b70bf561ed276"),
            ("gamemodes/base/gamemode/init.lua", 5_735, "246da7494fa51173b85d1bf9a85fc2fc2ba1ddc142051e57fe2a25b8681894e3"),
            ("gamemodes/sandbox/gamemode/init.lua", 5_360, "96c94f27d2069353c88485160270d9e1cf45090e7bcff485b1b2d01f35ebe9b6"),
            ("materials/gwenskin/GModDefault.png", 28_865, "bef28a23e6a1f80a82742b153fd4d586d393046bf1aa01b551ae3f771e264e63"),
            ("materials/gui/spawnmenu_toggle.vmt", 129, "14667fe3ab8600b44e054835e79c93860c3de4f689ca66a766424756f0483e77"),
            ("materials/gui/spawnmenu_toggle.vtf", 576, "4d0cff292e3ff854929ae958fc10c72405b62b5f9664a36a291b755008b4cbff"),
            ("materials/gui/spawnmenu_toggle_back.vmt", 134, "1230729479ad9f5c84f3f603582c3aed8663bb67fb00179e621d9225fabc1aec"),
            ("materials/gui/spawnmenu_toggle_back.vtf", 576, "e43a65fd72f4d8715516fc125635662f752b01efe89576e4543c6b9f8d173e98"),
            ("materials/gui/corner8.vmt", 118, "51cc8a95338f57bd82a5d5b683cc2c72d743111e03bd722a210a71393e05dfb6"),
            ("materials/gui/corner8.vtf", 336, "2dda7a79be5efa7f8eebfbce46edf68c2a81ce13d0aa00872068067dd59e3fbb"),
            ("materials/models/weapons/v_toolgun/screen_bg.vmt", 104, "08b110d41d4d1122bc33ac071d5527443907675e3a974c8a3fd255e0ccf7adf1"),
            ("materials/vgui/white.vmt", 251, "b5149aadde708e90c9061ac7d0d8e6c69f800ae6bdb4d05e7622dc0334a59d1f"),
        ]
        for (logicalPath, byteCount, sha256) in expectedFiles {
            let entry = try XCTUnwrap(
                manifest.files.first { $0.logicalPath == logicalPath }
            )
            XCTAssertEqual(entry.byteCount, byteCount, logicalPath)
            XCTAssertEqual(entry.sha256, sha256, logicalPath)
            XCTAssertEqual(
                try GModGameAssets.clientContentData(for: logicalPath).count,
                byteCount,
                logicalPath
            )
        }
    }

    func testContentRootIsTraversalSafeAndReadOnlyThroughTheGModVFS() throws {
        let root = try GModGameAssets.clientContentRootURL()
        let files = try GMLuaHostDirectoryFileSystem(rootURL: root, writable: false)

        XCTAssertTrue(files.fileExists(at: "lua/includes/init.lua"))
        XCTAssertTrue(files.fileExists(at: "LUA/INCLUDES/INIT.LUA"))
        XCTAssertTrue(files.directoryExists(at: "gamemodes/sandbox/gamemode"))
        XCTAssertTrue(
            try files.listDirectory(at: "gamemodes").contains {
                $0.name == "sandbox" && $0.isDirectory
            }
        )
        XCTAssertEqual(
            try files.readFile(at: "materials/gwenskin/gmoddefault.png").count,
            28_865
        )
        let resolver = GMLuaVPKMaterialPixelResolver(
            looseFileSystem: files,
            archivesInPriorityOrder: []
        )
        for logicalPath in ["gui/ps_hover.png", "gui/sm_hover.png"] {
            XCTAssertEqual(
                try resolver.dimensions(
                    materialPath: LuaString(logicalPath),
                    encodedParameters: nil
                ),
                GMLuaImageDimensions(width: 64, height: 64),
                logicalPath
            )
        }
        for logicalPath in ["gui/spawnmenu_toggle", "gui/spawnmenu_toggle_back"] {
            let resolved = try resolver.resolve(named: logicalPath)
            XCTAssertEqual(resolved.metadata.shaderName, "UnlitGeneric", logicalPath)
            XCTAssertEqual(
                resolved.metadata.dimensions,
                GMLuaImageDimensions(width: 16, height: 16),
                logicalPath
            )
            XCTAssertEqual(resolved.metadata.status, .resolved, logicalPath)
            XCTAssertFalse(resolved.metadata.isError, logicalPath)
            XCTAssertEqual(resolved.sourceTextureFormat, .dxt5, logicalPath)
            XCTAssertEqual(resolved.rgbaBytes?.count, 1_024, logicalPath)
        }
        XCTAssertThrowsError(
            try files.writeFile(Data("no mutation".utf8), at: "lua/autorun/mutated.lua")
        )

        for invalidPath in [
            "", ".", "..", "../escape", "lua/../escape", "lua//init.lua",
            "/lua/includes/init.lua", "C:/lua/includes/init.lua", "lua\\includes\\init.lua",
        ] {
            XCTAssertThrowsError(
                try GModGameAssets.clientContentURL(for: invalidPath),
                "accepted invalid logical path: \(invalidPath)"
            )
        }
        XCTAssertThrowsError(try GModGameAssets.clientContentURL(for: "lua"))
        XCTAssertThrowsError(
            try GModGameAssets.clientContentURL(for: "materials/example.vtf")
        )
        XCTAssertThrowsError(
            try GModGameAssets.clientContentURL(for: "addons/example/lua/init.lua")
        )
        XCTAssertFalse(root.path.isEmpty)
    }

    func testBundledToggleMaterialsBackGLuaMaterialAndTextureMetadata() throws {
        let files = try mountedContentFileSystem()
        let runtime = GMLuaRuntime(
            realm: .client,
            logger: { _ in },
            virtualFileSystem: files,
            bootstrapMode: .strict
        )
        defer { _ = runtime.close() }
        runtime.resourceRegistry?.setMaterialPixelResolver(
            GMLuaVPKMaterialPixelResolver(
                looseFileSystem: files,
                archivesInPriorityOrder: []
            )
        )

        do {
            try runtime.execute(
            """
            for _, name in ipairs({ "gui/spawnmenu_toggle", "gui/spawnmenu_toggle_back" }) do
                local material = Material(name)
                assert(material:GetShader() == "UnlitGeneric")
                assert(not material:IsError())
                assert(material:Width() == 16 and material:Height() == 16)
                local texture = material:GetTexture("$basetexture")
                assert(texture ~= nil)
                assert(texture:GetName() == "materials/" .. name .. ".vtf")
                assert(texture:Width() == 16 and texture:Height() == 16)
            end
            assert(Material("missing/not_bundled"):IsError())
            """,
            sourceName: "=(bundled Source spawn-menu toggle material contract)"
            )
        } catch let raised as LuaRaisedError {
            XCTFail(raised.value.printable)
        }
    }

    func testInstalledVPKMaterialCorpusMatchesBundledAuthorizedCopiesWhenConfigured() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["GMOD_VPK_DIAGNOSTIC_PATH"],
              !path.isEmpty else {
            throw XCTSkip("GMOD_VPK_DIAGNOSTIC_PATH was not supplied")
        }
        guard let platformPath = environment["GMOD_PLATFORM_VPK_DIAGNOSTIC_PATH"],
              !platformPath.isEmpty else {
            throw XCTSkip("GMOD_PLATFORM_VPK_DIAGNOSTIC_PATH was not supplied")
        }
        let archives = [
            "garrysmod/garrysmod_dir.vpk": try GMLuaVPKArchive(
                directoryFileURL: URL(fileURLWithPath: path)
            ),
            "platform/platform_misc_dir.vpk": try GMLuaVPKArchive(
                directoryFileURL: URL(fileURLWithPath: platformPath)
            ),
        ]
        let sourceArchiveByPath = Dictionary(
            uniqueKeysWithValues: try GModGameAssets.sourceMaterialAllowlist()
                .assets.map { ($0.logicalPath, $0.sourceArchive) }
        )
        let materialFiles = try GModGameAssets.clientContentManifest().files.filter {
            $0.logicalPath.hasPrefix("materials/")
        }
        XCTAssertEqual(materialFiles.count, 1_698)
        for entry in materialFiles {
            let sourceArchive = sourceArchiveByPath[entry.logicalPath]
                ?? "garrysmod/garrysmod_dir.vpk"
            let archive = try XCTUnwrap(
                archives[sourceArchive],
                "no diagnostic archive configured for \(sourceArchive)"
            )
            let installed = try XCTUnwrap(
                archive.data(for: LuaString(entry.logicalPath)),
                "\(sourceArchive)::\(entry.logicalPath)"
            )
            let bundled = try GModGameAssets.clientContentData(
                for: entry.logicalPath,
                mappedIfSafe: false
            )
            XCTAssertEqual(installed.count, entry.byteCount, entry.logicalPath)
            XCTAssertEqual(installed, bundled, entry.logicalPath)
        }
    }

    func testBundledContentRunsStrictPairedSandboxStartupWithoutAnInstalledTree() throws {
        let session = GMLuaSharedSession()
        let serverFiles = try mountedContentFileSystem()
        let clientFiles = try mountedContentFileSystem()
        let server = try makeRuntime(
            realm: .server,
            fileSystem: serverFiles,
            netTransport: session.netTransport
        )
        let client = try makeRuntime(
            realm: .client,
            fileSystem: clientFiles,
            netTransport: session.netTransport
        )
        defer {
            _ = client.close()
            _ = server.close()
        }

        server.consoleCommandDispatcher?.connectHost { invocation in
            invocation.command.caseInsensitiveCompare("mp_friendlyfire") == .orderedSame
                ? .handled
                : .unhandled
        }
        client.resourceRegistry?.setMaterialPixelResolver(
            GMLuaVPKMaterialPixelResolver(
                looseFileSystem: clientFiles,
                archivesInPriorityOrder: []
            )
        )
        try client.execute(
            """
            for _, name in ipairs({ "gui/spawnmenu_toggle", "gui/spawnmenu_toggle_back" }) do
                local material = Material(name)
                assert(material:GetShader() == "UnlitGeneric")
                assert(not material:IsError())
                assert(material:Width() == 16 and material:Height() == 16)
                local texture = material:GetTexture("$basetexture")
                assert(texture ~= nil)
                assert(texture:GetName() == "materials/" .. name .. ".vtf")
                assert(texture:Width() == 16 and texture:Height() == 16)
            end
            """,
            sourceName: "=(bundled Source spawn-menu toggle material contract)"
        )
        try server.loadFile("lua/includes/init.lua")
        let serverReport = try GMLuaStartupOrchestrator(
            runtime: server,
            fileSystem: serverFiles
        ).start(targetGamemodeNamed: "sandbox")
        XCTAssertEqual(serverReport.scriptedWeapons.realm, .server)
        XCTAssertTrue(
            serverReport.scriptedWeapons.directPaths.contains(
                "lua/weapons/gmod_tool/init.lua"
            )
        )
        XCTAssertEqual(
            serverReport.stages.first { $0.stage == .scriptedWeapons }?.outcome,
            .completed
        )

        try client.loadFile("lua/includes/init.lua")
        let clientReport = try GMLuaStartupOrchestrator(
            runtime: client,
            fileSystem: clientFiles,
            playerConnection: {
                try session.connect(
                    server: server,
                    client: client,
                    playerIndex: 1,
                    userID: 1
                )
            }
        ).start(targetGamemodeNamed: "sandbox")

        var delivered = 0
        while session.netTransport.pendingDeliveryCount > 0 {
            delivered += try session.pump(maxDeliveries: 1_000)
            XCTAssertLessThan(delivered, 10_000)
        }

        XCTAssertEqual(serverReport.targetReport.requestedName, "sandbox")
        XCTAssertEqual(clientReport.targetReport.requestedName, "sandbox")
        let weaponReport = clientReport.scriptedWeapons
        XCTAssertTrue(
            weaponReport.directPaths.contains(
                "lua/weapons/gmod_tool/cl_init.lua"
            )
        )
        XCTAssertEqual(
            clientReport.stages.first { $0.stage == .scriptedWeapons }?.outcome,
            .completed
        )
        XCTAssertTrue(client.conVarRegistry?.contains("gmod_toolmode") == true)
        XCTAssertEqual(client.conVarRegistry?.stringValue(for: "gmod_toolmode"), "rope")
        XCTAssertTrue(clientReport.playerConnectionModeled)
        XCTAssertEqual(server.compatibilityGaps, [])
        XCTAssertEqual(client.compatibilityGaps, [])
        XCTAssertEqual(delivered, 0)
        try client.execute(
            "assert(IsValid(LocalPlayer()) and LocalPlayer() == Entity(1))",
            sourceName: "=(bundled client-content LocalPlayer identity)"
        )
    }

    private func mountedContentFileSystem() throws -> GMLuaMountedFileSystem {
        let install = try GMLuaHostDirectoryFileSystem(
            rootURL: GModGameAssets.clientContentRootURL(),
            writable: false
        )
        let writable = try LuaMemoryFileSystem()
        return GMLuaMountedFileSystem(mounts: [
            try GMLuaFileMount(
                name: "runtime-data",
                priority: 1_000,
                writable: true,
                fileSystem: writable
            ),
            try GMLuaFileMount(
                name: "bundled-gmod-base",
                priority: 0,
                writable: false,
                fileSystem: install
            ),
        ])
    }

    private func makeRuntime(
        realm: GMLuaRealm,
        fileSystem: GMLuaMountedFileSystem,
        netTransport: GMLuaNetTransport?
    ) throws -> GMLuaRuntime {
        let environment = try GMLuaGameEnvironmentConfiguration(
            maxPlayers: 32,
            mapName: "gm_construct",
            sessionKind: .listenServer
        )
        let engine = GMLuaEngineConfiguration(
            games: [],
            isPlayingDemo: false,
            isRecordingDemo: false
        )
        let conVars = try GMLuaEngineConVarCatalog(
            descriptors: realm == .server ? [] : [
                GMLuaEngineConVarDescriptor(
                    name: "gmod_language",
                    defaultValue: "en"
                ),
            ]
        )
        return GMLuaRuntime(
            realm: realm,
            logger: { _ in },
            virtualFileSystem: fileSystem,
            bootstrapMode: .strict,
            gameEnvironmentConfiguration: environment,
            engineConfiguration: engine,
            engineConVarCatalog: conVars,
            netTransport: netTransport,
            inputConfiguration: GMLuaInputConfiguration()
        )
    }
}
