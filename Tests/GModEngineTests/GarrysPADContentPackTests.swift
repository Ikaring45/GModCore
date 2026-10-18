import Foundation
import XCTest
import GModEngine
import GModGameAssets
import GModGameSession

final class GarrysPADContentPackTests: XCTestCase {
    func testConfiguredRealPackProfilesRepeatedQCFrames() throws {
        guard let path = ProcessInfo.processInfo.environment["GMOD_CONTENT_PACK_DIAGNOSTIC_PATH"], !path.isEmpty else {
            throw XCTSkip("GMOD_CONTENT_PACK_DIAGNOSTIC_PATH is not configured")
        }
        let start = ProcessInfo.processInfo.systemUptime
        let session = try GModPlayableSession(configuration: .init(map: .flatgrass,
            contentPackURL: URL(fileURLWithPath: path)), logger: { _, _ in })
        defer { _ = try? session.close() }
        print("[Owned VGUI profile] startup-ms=\((ProcessInfo.processInfo.systemUptime - start) * 1000)")
        _ = try session.updateViewport(width: 1024, height: 768)
        let registry = try XCTUnwrap(session.clientRuntime.vguiRegistry)
        let coldCensus = ProcessInfo.processInfo.environment["GMOD_VGUI_LAYOUT_CENSUS"] == "1"
        for cycle in 1...2 {
            for context in [false, true] {
                let opened = ProcessInfo.processInfo.systemUptime
                if context { try session.setContextMenuOpen(true) }
                else { try session.setSpawnMenuOpen(true) }
                let openMS = (ProcessInfo.processInfo.systemUptime - opened) * 1000
                if coldCensus && cycle == 1 && !context {
                    print("[Owned VGUI profile] instrumented layout census; timings are not baseline-comparable")
                    try session.clientRuntime.execute("""
                        COLD_LAYOUT_CENSUS = {}
                        for _, panel in ipairs(vgui.GetAll()) do
                            local original = panel.PerformLayout
                            if original then
                                local key = panel:GetClassName()
                                panel.PerformLayout = function(self, ...)
                                    local start = SysTime()
                                    local result = original(self, ...)
                                    local stats = COLD_LAYOUT_CENSUS[key] or { count = 0, seconds = 0 }
                                    stats.count = stats.count + 1
                                    stats.seconds = stats.seconds + SysTime() - start
                                    COLD_LAYOUT_CENSUS[key] = stats
                                    return result
                                end
                            end
                        end
                        """, sourceName: "=(owned cold layout census)")
                }
                var frameMS: [Double] = []
                var profiles: [GMLuaVGUIFrameProfile] = []
                var commands = 0
                let layouts = registry.completedLayoutPassCount
                for _ in 0..<10 {
                    let before = ProcessInfo.processInfo.systemUptime
                    let frame = try session.renderClientVGUIFrame(onFrameProfile: { profiles.append($0) })
                    frameMS.append((ProcessInfo.processInfo.systemUptime - before) * 1000)
                    commands = frame.commands.count
                    XCTAssertGreaterThan(commands, 0)
                }
                print("[Owned VGUI profile] menu=\(context ? "C" : "Q") cycle=\(cycle) open-ms=\(openMS) first-frame-ms=\(frameMS[0]) warm-mean-ms=\(frameMS.dropFirst().reduce(0, +) / 9) panels=\(registry.livePanelCount) layouts=\(registry.completedLayoutPassCount - layouts) commands=\(commands)")
                XCTAssertEqual(profiles.count, 10)
                let first = try XCTUnwrap(profiles.first)
                if coldCensus && cycle == 1 && !context {
                    let values = try session.clientRuntime.executeReturningValues("""
                        local result = {}
                        for name, stats in pairs(COLD_LAYOUT_CENSUS) do
                            result[#result + 1] = { name = name, count = stats.count, seconds = stats.seconds }
                        end
                        table.sort(result, function(a, b) return a.seconds > b.seconds end)
                        local lines = {}
                        for i = 1, math.min(12, #result) do
                            local value = result[i]
                            lines[#lines + 1] = value.name .. ':' .. value.count .. ':' .. value.seconds
                        end
                        return table.concat(lines, ',')
                        """, sourceName: "=(owned cold layout census result)")
                    if case let .string(value) = values.first {
                        print("[Owned cold layout census inclusive seconds] \(value.utf8String)")
                    }
                }
                print("[Owned VGUI stages ms] menu=\(context ? "C" : "Q") cycle=\(cycle) first layout=\(Double(first.layoutNanoseconds) / 1e6) think=\(Double(first.callbackNanoseconds) / 1e6) tree=\(Double(first.treeNanoseconds) / 1e6) paint=\(Double(first.paintNanoseconds) / 1e6)")
                let warm = profiles.dropFirst()
                print("[Owned VGUI stages ms] warm layout=\(warm.reduce(0.0) { $0 + Double($1.layoutNanoseconds) } / 9e6) think=\(warm.reduce(0.0) { $0 + Double($1.callbackNanoseconds) } / 9e6) tree=\(warm.reduce(0.0) { $0 + Double($1.treeNanoseconds) } / 9e6) paint=\(warm.reduce(0.0) { $0 + Double($1.paintNanoseconds) } / 9e6)")
                if cycle == 2 {
                    XCTAssertEqual(registry.completedLayoutPassCount, layouts,
                        "Unchanged reopened menus must not perpetually relayout their DTab controls")
                }
                if cycle == 2 && context {
                    // Separate diagnostic frame: wrapping callbacks changes
                    // their cost, so exclude it from the timings above.
                    try session.clientRuntime.execute("""
                        PROFILE_LAYOUTS = {}
                        for _, panel in ipairs(vgui.GetAll()) do
                            local original = panel.PerformLayout
                            if original then
                                local key = panel:GetClassName()
                                panel.PerformLayout = function(self, ...)
                                    PROFILE_LAYOUTS[key] = (PROFILE_LAYOUTS[key] or 0) + 1
                                    return original(self, ...)
                                end
                            end
                        end
                        """, sourceName: "=(owned VGUI layout census)")
                    _ = try session.renderClientVGUIFrame()
                    let census = try session.clientRuntime.executeReturningValues("""
                        local result = {}
                        for name, count in pairs(PROFILE_LAYOUTS) do
                            result[#result + 1] = name .. '=' .. count
                        end
                        table.sort(result)
                        return table.concat(result, ',')
                        """, sourceName: "=(owned VGUI layout census result)")
                    if case let .string(value) = census.first {
                        print("[Owned VGUI layout census] \(value.utf8String)")
                    }
                }
                if context { try session.setContextMenuOpen(false) }
                else { try session.setSpawnMenuOpen(false) }
            }
        }
    }

    func testCompressedNestedVPKPreservesBackingCompressionError() throws {
        let fixture = try makeTemporaryZIP(entries: [
            ("garrysmod/maps/gm_construct.bsp", Data("construct".utf8), 0),
            ("garrysmod/maps/gm_flatgrass.bsp", Data("flatgrass".utf8), 0),
            ("garrysmod/html/img/bg.jpg", Data([1, 2, 3]), 0),
            ("garrysmod/garrysmod_dir.vpk", Data(repeating: 0, count: 28), 8),
        ])
        defer { try? FileManager.default.removeItem(at: fixture) }
        let pack = try GarrysPADContentPack(url: fixture)
        XCTAssertThrowsError(try GModContentPackAssetSource(pack: pack)) { error in
            XCTAssertEqual(error as? GarrysPADContentPackError,
                .unsupportedCompression(path: "garrysmod/garrysmod_dir.vpk", method: 8))
        }
    }

    func testConfiguredRealPackDecodesCrateModelAndCollision() throws {
        guard let path = ProcessInfo.processInfo.environment["GMOD_CONTENT_PACK_DIAGNOSTIC_PATH"], !path.isEmpty else {
            throw XCTSkip("GMOD_CONTENT_PACK_DIAGNOSTIC_PATH is not configured")
        }
        let pack = try GarrysPADContentPack(url: URL(fileURLWithPath: path))
        let source = try GModContentPackAssetSource(pack: pack)
        for archive in source.archives {
            if let candidate = try archive.data(for: "models/props_junk/wood_crate001a.mdl") {
                let identity = try SourceStudioFileIdentity(data: candidate)
                print("[Owned prop mount] \(archive.directoryFileURL.path): v\(identity.version) bytes=\(candidate.count) checksum=\(identity.checksum)")
            }
        }
        let mdl = try XCTUnwrap(source.data(for: "models/props_junk/wood_crate001a.mdl"))
        let phy = try XCTUnwrap(source.data(for: "models/props_junk/wood_crate001a.phy"))
        let model = try SourceStudioFileIdentity(data: mdl)
        let studio = try SourceStudioModel(data: mdl, expectedChecksum: model.checksum)
        XCTAssertFalse(studio.bones.isEmpty)
        print("[Owned prop Studio] bones=\(studio.bones.count) sequences=\(studio.sequences.count)")
        let loader = SourceStudioModelAssetLoader(reader: source, budget: .init(
            maximumBytesByKind: [.mdl: 16_777_216, .vvd: 16_777_216, .vtx: 16_777_216],
            maximumTotalBytes: 50_331_648, maximumVVDVertices: 65_536,
            maximumVVDFixups: 65_536, maximumVTXBodyParts: 256))
        let stem = "models/props_junk/wood_crate001a"
        let loaded = loader.load(paths: .init(mdl: stem + ".mdl", vvd: stem + ".vvd",
            vtx: stem + ".dx90.vtx"), requirement: .render)
        guard case let .loaded(asset) = loaded else {
            return XCTFail("Owned crate asset load failed: \(String(describing: loaded.unavailableReason))")
        }
        let mesh = try SourceStudioModelMeshDecoder.decodeRootLOD(asset.renderPayload,
            budget: .init(maximumRootVertices: 65_536, maximumBodyParts: 256,
                maximumModels: 256, maximumMeshes: 1024, maximumStripGroups: 4096,
                maximumDecodedVertices: 262_144, maximumIndices: 1_048_576,
                maximumStrips: 65_536, maximumBoneStateChanges: 65_536))
        let groups = mesh.bodyParts.flatMap(\.models).flatMap(\.meshes).flatMap(\.stripGroups)
        let vertices = groups.reduce(0) { $0 + $1.vertices.count }
        let indices = groups.reduce(0) { $0 + $1.indices.count }
        XCTAssertGreaterThan(vertices, 0)
        XCTAssertGreaterThan(indices, 0)
        print("[Owned prop mesh] vertices=\(vertices) indices=\(indices)")
        let renderable = try GModStudioRenderableModelCompiler.compile(asset: asset,
            bodyValue: 0, skinFamilyIndex: 0, policy: .initialIpadProp)
        XCTAssertFalse(renderable.drawRanges.isEmpty)
        XCTAssertEqual(renderable.indices.count, indices)
        let materialResolver = GMLuaSourceMaterialResolver { try source.data(for: $0) }
        for draw in renderable.drawRanges {
            let selected = try XCTUnwrap(draw.material.vmtCandidates.first(where: {
                (try? source.data(for: $0)) != nil
            }), "Owned crate must resolve an authored VMT, not a fallback")
            let material = try materialResolver.resolve(named: selected)
            XCTAssertEqual(material.metadata.status, .resolved)
            XCTAssertFalse(try XCTUnwrap(material.rgbaBytes).isEmpty)
            print("[Owned prop material] \(selected): \(String(describing: material.metadata.dimensions))")
        }
        let envelope = try SourcePHYCollisionDecoder.decodeEnvelope(phy,
            expectedSourceModelChecksum: model.checksum,
            budget: .init(maximumFileBytes: 16_777_216, maximumSolids: 64,
                maximumBytesPerSolid: 8_388_608, maximumTotalSolidBytes: 16_777_216,
                maximumKeyValuesBytes: 1_048_576))
        let outcome = SourceVPhysicsCollisionDecoder.decodeSolidZero(in: phy, envelope: envelope,
            budget: .init(maximumSourceDataBytes: 16_777_216, maximumPayloadBytes: 8_388_608,
                maximumTreeNodes: 65_536, maximumTreeDepth: 128, maximumLedges: 8192,
                maximumTriangles: 262_144, maximumPoints: 262_144))
        guard case let .decoded(collision) = outcome else {
            return XCTFail("Owned crate collision did not decode: \(outcome)")
        }
        XCTAssertFalse(collision.ledges.isEmpty)
        XCTAssertEqual(collision.verification, .unattested,
            "Structural decoding is not independent physics attestation")
        print("[Owned prop] wood_crate001a: version=\(model.version) MDL=\(mdl.count) PHY=\(phy.count) ledges=\(collision.ledges.count)")
    }

    func testStudioAssetReaderPreservesMissingOversizeAndPathIDBoundaries() throws {
        let modelBytes = Data(repeating: 0x53, count: 16)
        let fixture = try makeTemporaryZIP(entries: [
            ("garrysmod/maps/gm_construct.bsp", Data("construct".utf8), 0),
            ("garrysmod/maps/gm_flatgrass.bsp", Data("flatgrass".utf8), 0),
            ("garrysmod/html/img/bg.jpg", Data([0xFF, 0xD8, 0xFF, 0xD9]), 0),
            ("garrysmod/models/props/test.mdl", modelBytes, 0),
        ])
        defer { try? FileManager.default.removeItem(at: fixture) }

        let source = try GModContentPackAssetSource(
            pack: GarrysPADContentPack(url: fixture)
        )
        XCTAssertEqual(
            source.read(
                path: "models/props/test.mdl",
                pathID: "GAME",
                maximumBytes: modelBytes.count
            ),
            .data(modelBytes)
        )
        XCTAssertEqual(
            source.read(
                path: "models/props/missing.mdl",
                pathID: "GAME",
                maximumBytes: 64
            ),
            .missing
        )
        XCTAssertEqual(
            source.read(
                path: "models/props/test.mdl",
                pathID: "GAME",
                maximumBytes: 4
            ),
            .exceeded(actual: modelBytes.count)
        )
        guard case .failed = source.read(
            path: "models/props/test.mdl",
            pathID: "MOD",
            maximumBytes: modelBytes.count
        ) else {
            return XCTFail("non-GAME Studio reads must not silently use GAME")
        }
    }

    func testStoredEntriesAreIndexedAndReadWithoutExtraction() throws {
        let fixture = try makeTemporaryZIP(entries: [
            ("garrysmod/maps/gm_construct.bsp", Data("construct".utf8), 0),
            ("garrysmod/maps/gm_flatgrass.bsp", Data("flatgrass".utf8), 0),
            ("garrysmod/html/img/bg.jpg", Data([0xFF, 0xD8, 0xFF, 0xD9]), 0),
        ])
        defer { try? FileManager.default.removeItem(at: fixture) }

        let pack = try GarrysPADContentPack(url: fixture)
        XCTAssertEqual(pack.entries.count, 3)
        XCTAssertTrue(pack.contains("GARRYSMOD\\MAPS\\GM_CONSTRUCT.BSP"))
        XCTAssertEqual(
            try pack.data(for: "garrysmod/maps/gm_flatgrass.bsp"),
            Data("flatgrass".utf8)
        )
        XCTAssertEqual(
            try pack.data(
                for: "garrysmod/maps/gm_flatgrass.bsp",
                offset: 2,
                count: 4
            ),
            Data("atgr".utf8)
        )
        XCTAssertEqual(
            try pack.byteCount(for: "garrysmod/maps/gm_flatgrass.bsp"),
            9
        )
    }

    func testCandidateRejectsOversizeMapBeforeReadingEntryData() throws {
        let fixture = try makeTemporaryZIP(entries: [
            ("garrysmod/maps/gm_construct.bsp", Data("construct".utf8), 0),
            ("garrysmod/maps/gm_flatgrass.bsp", Data("flatgrass".utf8), 0),
            ("garrysmod/html/img/bg.jpg", Data([0xFF, 0xD8, 0xFF, 0xD9]), 0),
        ])
        defer { try? FileManager.default.removeItem(at: fixture) }
        let policy = GModMapAllocationPolicy(
            maximumBSPEncodedByteCount: 8,
            maximumWorldVertexWorkingByteCount: .max,
            maximumWorldIndexWorkingByteCount: .max,
            maximumDisplacementVertexWorkingByteCount: .max,
            maximumDisplacementIndexWorkingByteCount: .max,
            maximumLightmapAtlasByteCount: .max
        )

        XCTAssertThrowsError(try GarrysPADContentPack(
            url: fixture,
            mapAllocationPolicy: policy
        )) { error in
            XCTAssertEqual(
                error as? GarrysPADContentPackError,
                .mapAllocationExceeded(
                    path: "garrysmod/maps/gm_construct.bsp",
                    failure: GModMapAllocationPolicyError(
                        resource: .bspEncodedBytes,
                        requestedByteCount: 9,
                        maximumByteCount: 8
                    )
                )
            )
        }
    }

    func testCompressedEntryIsRejectedWithoutInventingDecodedBytes() throws {
        let fixture = try makeTemporaryZIP(entries: [
            ("garrysmod/maps/gm_construct.bsp", Data("construct".utf8), 0),
            ("garrysmod/maps/gm_flatgrass.bsp", Data("flatgrass".utf8), 0),
            ("garrysmod/html/img/bg.jpg", Data([1, 2, 3]), 0),
            ("garrysmod/html/menu.html", Data("not really deflated".utf8), 8),
        ])
        defer { try? FileManager.default.removeItem(at: fixture) }
        let pack = try GarrysPADContentPack(url: fixture)

        XCTAssertThrowsError(try pack.data(for: "garrysmod/html/menu.html")) { error in
            XCTAssertEqual(
                error as? GarrysPADContentPackError,
                .unsupportedCompression(
                    path: "garrysmod/html/menu.html",
                    method: 8
                )
            )
        }
    }

    func testDiscoveryAcceptsPlaygroundsRootAndOneResourcesWrapper() throws {
        let fixture = try makeTemporaryZIP(entries: [
            ("garrysmod/maps/gm_construct.bsp", Data("construct".utf8), 0),
            ("garrysmod/maps/gm_flatgrass.bsp", Data("flatgrass".utf8), 0),
            ("garrysmod/html/img/bg.jpg", Data([0xFF, 0xD8, 0xFF, 0xD9]), 0),
        ])
        defer { try? FileManager.default.removeItem(at: fixture) }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GarrysPAD-discovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let direct = root.appendingPathComponent("GarrysPAD_Content_Playable.zip")
        try FileManager.default.copyItem(at: fixture, to: direct)
        XCTAssertEqual(
            try GarrysPADContentPack.discover(resourceRootURL: root)?.archiveURL,
            direct.standardizedFileURL
        )

        try FileManager.default.removeItem(at: direct)
        let wrappedRoot = root.appendingPathComponent("Resources")
        try FileManager.default.createDirectory(
            at: wrappedRoot,
            withIntermediateDirectories: true
        )
        let wrapped = wrappedRoot.appendingPathComponent(
            "GarrysPAD_Content_Playable.zip"
        )
        try FileManager.default.copyItem(at: fixture, to: wrapped)
        XCTAssertEqual(
            try GarrysPADContentPack.discover(resourceRootURL: root)?.archiveURL,
            wrapped.standardizedFileURL
        )
    }

    func testConfiguredRealPackReadsBothStockMapsAndHomeBackground() throws {
        guard let path = ProcessInfo.processInfo.environment[
            "GMOD_CONTENT_PACK_DIAGNOSTIC_PATH"
        ], !path.isEmpty else {
            throw XCTSkip("GMOD_CONTENT_PACK_DIAGNOSTIC_PATH is not configured")
        }
        let pack = try GarrysPADContentPack(url: URL(fileURLWithPath: path))
        for map in ["gm_construct", "gm_flatgrass"] {
            let data = try pack.data(for: "garrysmod/maps/\(map).bsp")
            XCTAssertGreaterThan(data.count, 1_024)
            XCTAssertEqual(Array(data.prefix(4)), [0x56, 0x42, 0x53, 0x50])
        }
        let background = try pack.data(for: "garrysmod/html/img/bg.jpg")
        XCTAssertEqual(Array(background.prefix(2)), [0xFF, 0xD8])

        let source = try GModContentPackAssetSource(pack: pack)
        let material = try XCTUnwrap(
            source.data(
                for: "materials/gm_construct/construct_concrete_ground.vmt"
            )
        )
        XCTAssertFalse(material.isEmpty)
        let texture = try XCTUnwrap(
            source.data(
                for: "materials/gm_construct/construct_concrete_ground.vtf"
            )
        )
        XCTAssertEqual(Array(texture.prefix(4)), [0x56, 0x54, 0x46, 0x00])
        let resolver = GMLuaSourceMaterialResolver { logicalPath in
            try source.data(for: logicalPath)
        }
        let resolvedMaterial = try resolver.resolve(
            named: "gm_construct/construct_concrete_ground"
        )
        XCTAssertEqual(resolvedMaterial.metadata.status, .resolved)
        XCTAssertGreaterThan(resolvedMaterial.metadata.dimensions?.width ?? 0, 0)
        XCTAssertGreaterThan(resolvedMaterial.metadata.dimensions?.height ?? 0, 0)
        XCTAssertFalse(try XCTUnwrap(resolvedMaterial.rgbaBytes).isEmpty)
        let dermaAtlas = try XCTUnwrap(
            source.data(for: "materials/gwenskin/gmoddefault.png")
        )
        XCTAssertEqual(
            Array(dermaAtlas.prefix(4)),
            [0x89, 0x50, 0x4E, 0x47]
        )
        let click = try XCTUnwrap(
            source.data(for: "sound/garrysmod/ui_click.wav")
        )
        XCTAssertEqual(Array(click.prefix(4)), Array("RIFF".utf8))
    }

    func testConfiguredRealPackStartsSandboxAndAdvancesMovement() throws {
        guard let path = ProcessInfo.processInfo.environment[
            "GMOD_CONTENT_PACK_DIAGNOSTIC_PATH"
        ], !path.isEmpty else {
            throw XCTSkip("GMOD_CONTENT_PACK_DIAGNOSTIC_PATH is not configured")
        }
        let session = try GModPlayableSession(configuration: .init(
            map: .construct,
            contentPackURL: URL(fileURLWithPath: path)
        ))
        defer { _ = try? session.close() }
        XCTAssertEqual(session.startupReport.map, .construct)
        let surfaceProperties = try XCTUnwrap(
            session.surfacePropertiesAttestation,
            "the configured installed corpus must expose its real GAME manifest"
        )
        XCTAssertFalse(surfaceProperties.files.isEmpty)
        XCTAssertFalse(surfaceProperties.materials.isEmpty)
        let origin = session.playerWalkState.origin
        let tick = try session.runFixedTick(movementInput: .init(forwardMove: 200))
        XCTAssertNotEqual(tick.movement.state.origin, origin)
    }

    func testConfiguredRealPackResolvesAllSixPaintedSkyboxFaces() throws {
        guard let path = ProcessInfo.processInfo.environment[
            "GMOD_CONTENT_PACK_DIAGNOSTIC_PATH"
        ], !path.isEmpty else {
            throw XCTSkip("GMOD_CONTENT_PACK_DIAGNOSTIC_PATH is not configured")
        }
        let pack = try GarrysPADContentPack(url: URL(fileURLWithPath: path))
        let source = try GModContentPackAssetSource(pack: pack)
        let resolver = GMLuaSourceMaterialResolver { logicalPath in
            try source.data(for: logicalPath)
        }
        let expectedNames = [
            "skybox/paintedrt", "skybox/paintedbk", "skybox/paintedlf",
            "skybox/paintedft", "skybox/paintedup", "skybox/painteddn",
        ]

        for name in expectedNames {
            let resolved = try resolver.resolve(named: name)
            XCTAssertEqual(resolved.metadata.status, .resolved, name)
            XCTAssertGreaterThan(resolved.metadata.dimensions?.width ?? 0, 0, name)
            XCTAssertGreaterThan(resolved.metadata.dimensions?.height ?? 0, 0, name)
            XCTAssertFalse(try XCTUnwrap(resolved.rgbaBytes, name).isEmpty)
        }
    }

    func testConfiguredRealPackResolvesConstructWaterWithoutInventedTextures() throws {
        guard let path = ProcessInfo.processInfo.environment[
            "GMOD_CONTENT_PACK_DIAGNOSTIC_PATH"
        ], !path.isEmpty else {
            throw XCTSkip("GMOD_CONTENT_PACK_DIAGNOSTIC_PATH is not configured")
        }
        let pack = try GarrysPADContentPack(url: URL(fileURLWithPath: path))
        let source = try GModContentPackAssetSource(pack: pack)
        let resolver = GMLuaSourceMaterialResolver { logicalPath in
            try source.data(for: logicalPath)
        }

        let top = try XCTUnwrap(
            resolver.resolveWater(named: "gm_construct/water_13")
        )
        XCTAssertEqual(top.isAboveWater, true)
        XCTAssertEqual(top.fogEnabled, true)
        XCTAssertEqual(top.fogColor, [7, 58, 66])
        XCTAssertEqual(top.fogStart, 0)
        XCTAssertEqual(top.fogEnd, 1_024)
        XCTAssertEqual(top.reflectionAmount, 0.4)
        XCTAssertEqual(top.refractionAmount, 1)
        XCTAssertEqual(top.normalTexture?.status, .decoded)
        XCTAssertEqual(top.normalTexture?.imageFormat, .bgra8888)
        let normalBytes = try XCTUnwrap(top.normalTexture?.rgbaBytes)
        XCTAssertTrue(
            stride(from: 3, to: normalBytes.count, by: 4).allSatisfy {
                normalBytes[$0] == 255
            },
            "the retained surface-bitmap adapter must not alter this normal map"
        )
        XCTAssertEqual(
            top.bumpTexture?.status,
            .unsupportedImageFormat(.uv88)
        )
        XCTAssertNil(top.bumpTexture?.rgbaBytes)
        XCTAssertEqual(top.textureScroll?.targetVariable.lowercased(), "$bumptransform")
        XCTAssertEqual(top.textureScroll?.rate, 0.02)
        XCTAssertEqual(top.textureScroll?.angleDegrees, 25)

        let beneath = try XCTUnwrap(
            resolver.resolveWater(named: "gm_construct/water_13_beneath")
        )
        XCTAssertEqual(beneath.isAboveWater, false)
        XCTAssertEqual(beneath.fogColor, [24, 64, 72])
        XCTAssertEqual(beneath.fogStart, -1_024)
        XCTAssertEqual(beneath.fogEnd, 2_048)
        XCTAssertNil(beneath.reflectionAmount)
        XCTAssertEqual(beneath.refractionAmount, 1)
        XCTAssertEqual(beneath.normalTexture?.status, .decoded)
        XCTAssertEqual(
            beneath.bumpTexture?.status,
            .unsupportedImageFormat(.uv88)
        )
        XCTAssertEqual(
            beneath.textureScroll?.targetVariable.lowercased(),
            "$bumptransform"
        )
        XCTAssertEqual(beneath.textureScroll?.rate, 0.05)
        XCTAssertEqual(beneath.textureScroll?.angleDegrees, 45)
    }

    func testConfiguredRealPackResolvesStockWorldMaterialBudget() throws {
        guard let path = ProcessInfo.processInfo.environment[
            "GMOD_CONTENT_PACK_DIAGNOSTIC_PATH"
        ], !path.isEmpty else {
            throw XCTSkip("GMOD_CONTENT_PACK_DIAGNOSTIC_PATH is not configured")
        }
        let pack = try GarrysPADContentPack(url: URL(fileURLWithPath: path))
        let source = try GModContentPackAssetSource(pack: pack)
        let resolver = GMLuaSourceMaterialResolver { logicalPath in
            try source.data(for: logicalPath)
        }

        for map in GModBundledMap.allCases {
            let bsp = try SourceBSP(data: GModGameAssets.data(for: map, kind: .bsp))
            let mesh = try GModWorldRenderMesh.build(from: bsp)
            var resolvedCount = 0
            var decodedByteCount = 0
            var allocationFailures: [String] = []
            var unresolvedMaterials: [String] = []
            for name in mesh.materialRanges.compactMap(\.materialName) {
                do {
                    let material = try resolver.resolve(named: name)
                    if let pixels = material.rgbaBytes {
                        resolvedCount += 1
                        decodedByteCount += pixels.count
                    } else {
                        unresolvedMaterials.append(
                            "\(name) [\(material.metadata.status.rawValue)]"
                        )
                    }
                } catch let error as SourceVTFError {
                    if case .allocationLimitExceeded = error {
                        allocationFailures.append("\(name): \(error)")
                    }
                }
            }
            XCTAssertTrue(
                allocationFailures.isEmpty,
                "\(map.rawValue) exceeded bounded texture limits: " +
                    allocationFailures.joined(separator: "; ")
            )
            XCTAssertGreaterThan(
                resolvedCount,
                map == .construct ? 10 : 2
            )
            XCTAssertEqual(resolvedCount, map == .construct ? 55 : 14)
            XCTAssertEqual(
                Set(unresolvedMaterials),
                map == .construct
                    ? Set([
                        "gm_construct/water_13 [materialWithoutBaseTexture]",
                        "gm_construct/water_13_beneath [materialWithoutBaseTexture]",
                    ])
                    : Set<String>()
            )
            XCTAssertLessThanOrEqual(decodedByteCount, 128 * 1_024 * 1_024)
            print(
                "\(map.rawValue): resolved \(resolvedCount)/" +
                    "\(mesh.materialRanges.count) world materials, " +
                    "\(decodedByteCount) decoded bytes; unresolved " +
                    (unresolvedMaterials.isEmpty
                        ? "none"
                        : unresolvedMaterials.joined(separator: ", "))
            )
        }
    }

    private func makeTemporaryZIP(
        entries: [(path: String, data: Data, method: UInt16)]
    ) throws -> URL {
        var archive = Data()
        var records: [(String, Data, UInt16, UInt32)] = []
        for item in entries {
            let name = Data(item.path.utf8)
            let localOffset = UInt32(archive.count)
            archive.appendLE(UInt32(0x0403_4B50))
            archive.appendLE(UInt16(20))
            archive.appendLE(UInt16(0x0800))
            archive.appendLE(item.method)
            archive.appendLE(UInt16(0)); archive.appendLE(UInt16(0))
            archive.appendLE(item.data.testCRC32)
            archive.appendLE(UInt32(item.data.count))
            archive.appendLE(UInt32(item.data.count))
            archive.appendLE(UInt16(name.count)); archive.appendLE(UInt16(0))
            archive.append(name); archive.append(item.data)
            records.append((item.path, item.data, item.method, localOffset))
        }
        let centralOffset = UInt32(archive.count)
        for record in records {
            let name = Data(record.0.utf8)
            archive.appendLE(UInt32(0x0201_4B50))
            archive.appendLE(UInt16(20)); archive.appendLE(UInt16(20))
            archive.appendLE(UInt16(0x0800)); archive.appendLE(record.2)
            archive.appendLE(UInt16(0)); archive.appendLE(UInt16(0))
            archive.appendLE(record.1.testCRC32)
            archive.appendLE(UInt32(record.1.count)); archive.appendLE(UInt32(record.1.count))
            archive.appendLE(UInt16(name.count)); archive.appendLE(UInt16(0))
            archive.appendLE(UInt16(0)); archive.appendLE(UInt16(0))
            archive.appendLE(UInt16(0)); archive.appendLE(UInt32(0))
            archive.appendLE(record.3); archive.append(name)
        }
        let centralSize = UInt32(archive.count) - centralOffset
        archive.appendLE(UInt32(0x0605_4B50))
        archive.appendLE(UInt16(0)); archive.appendLE(UInt16(0))
        archive.appendLE(UInt16(records.count)); archive.appendLE(UInt16(records.count))
        archive.appendLE(centralSize); archive.appendLE(centralOffset)
        archive.appendLE(UInt16(0))

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("GarrysPAD_Content_Test_\(UUID().uuidString).zip")
        try archive.write(to: url, options: .atomic)
        return url
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }

    var testCRC32: UInt32 {
        var crc = UInt32.max
        for byte in self {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                let mask = UInt32(bitPattern: -Int32(crc & 1))
                crc = (crc >> 1) ^ (0xEDB8_8320 & mask)
            }
        }
        return ~crc
    }
}
