import Foundation
import XCTest
@testable import GModEngine
import GModGameAssets
import GModLua

final class GModBundledClientContentTests: XCTestCase {
    func testManifestCoversExactAuthorizedBaseClientContent() throws {
        let manifest = try GModGameAssets.clientContentManifest()

        XCTAssertEqual(manifest.formatVersion, 1)
        XCTAssertEqual(manifest.fileCount, 2_044)
        XCTAssertEqual(manifest.files.count, 2_044)
        XCTAssertEqual(manifest.byteCount, 11_675_792)
        XCTAssertEqual(manifest.files.reduce(0) { $0 + $1.byteCount }, 11_675_792)
        XCTAssertEqual(Set(manifest.files.map(\.logicalPath)).count, 2_044)
        XCTAssertEqual(
            Set(manifest.files.map { $0.logicalPath.lowercased() }).count,
            2_044
        )
        XCTAssertEqual(
            manifest.sourceScope,
            "Project-authorized base Garry's Mod lua/, gamemodes/base/, " +
                "gamemodes/sandbox/, and all materials/**/*.png entries from the base " +
                "garrysmod_dir.vpk; Workshop, cache, addons, downloads, and non-PNG " +
                "VPK material content excluded."
        )
        XCTAssertTrue(manifest.files.allSatisfy { entry in
            entry.logicalPath.hasPrefix("lua/") ||
                entry.logicalPath.hasPrefix("gamemodes/base/") ||
                entry.logicalPath.hasPrefix("gamemodes/sandbox/") ||
                (entry.logicalPath.hasPrefix("materials/") &&
                    entry.logicalPath.lowercased().hasSuffix(".png"))
        })
        XCTAssertEqual(
            manifest.files.filter { $0.logicalPath.hasPrefix("materials/") }.count,
            1_580
        )
        XCTAssertEqual(
            manifest.files.filter { $0.logicalPath.hasPrefix("materials/") }
                .reduce(0) { $0 + $1.byteCount },
            9_356_582
        )

        let expectedFiles: [(String, Int, String)] = [
            ("lua/includes/init.lua", 3_610, "04a0d82fa01f39c7470ae266aabfd1b38fce6ee9abbe01e93d2b70bf561ed276"),
            ("gamemodes/base/gamemode/init.lua", 5_735, "246da7494fa51173b85d1bf9a85fc2fc2ba1ddc142051e57fe2a25b8681894e3"),
            ("gamemodes/sandbox/gamemode/init.lua", 5_360, "96c94f27d2069353c88485160270d9e1cf45090e7bcff485b1b2d01f35ebe9b6"),
            ("materials/gwenskin/GModDefault.png", 28_865, "bef28a23e6a1f80a82742b153fd4d586d393046bf1aa01b551ae3f771e264e63"),
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

    func testInstalledVPKPNGCorpusMatchesBundledAuthorizedCopiesWhenConfigured() throws {
        guard let path = ProcessInfo.processInfo.environment["GMOD_VPK_DIAGNOSTIC_PATH"],
              !path.isEmpty else {
            throw XCTSkip("GMOD_VPK_DIAGNOSTIC_PATH was not supplied")
        }
        let archive = try GMLuaVPKArchive(
            directoryFileURL: URL(fileURLWithPath: path)
        )
        let materialFiles = try GModGameAssets.clientContentManifest().files.filter {
            $0.logicalPath.hasPrefix("materials/")
        }
        XCTAssertEqual(materialFiles.count, 1_580)
        for entry in materialFiles {
            let installed = try XCTUnwrap(
                archive.data(for: LuaString(entry.logicalPath)),
                entry.logicalPath
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
        try server.loadFile("lua/includes/init.lua")
        let serverReport = try GMLuaStartupOrchestrator(
            runtime: server,
            fileSystem: serverFiles
        ).start(targetGamemodeNamed: "sandbox")

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
