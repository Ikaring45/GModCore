import Foundation
import XCTest
import GModEngine
import GModGameAssets
import GModGameSession

final class GarrysPADContentPackTests: XCTestCase {
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
        let origin = session.playerWalkState.origin
        let tick = try session.runFixedTick(movementInput: .init(forwardMove: 200))
        XCTAssertNotEqual(tick.movement.state.origin, origin)
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
            for name in mesh.materialRanges.compactMap(\.materialName) {
                do {
                    let material = try resolver.resolve(named: name)
                    if let pixels = material.rgbaBytes {
                        resolvedCount += 1
                        decodedByteCount += pixels.count
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
            XCTAssertLessThanOrEqual(decodedByteCount, 128 * 1_024 * 1_024)
            print(
                "\(map.rawValue): resolved \(resolvedCount)/" +
                    "\(mesh.materialRanges.count) world materials, " +
                    "\(decodedByteCount) decoded bytes"
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
