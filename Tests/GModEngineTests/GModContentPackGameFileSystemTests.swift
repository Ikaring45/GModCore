import Foundation
import XCTest
import GModEngine
import GModGameAssets
import GModLua
@testable import GModGameSession

final class GModContentPackGameFileSystemTests: XCTestCase {
    func testLooseRootsAndNestedVPKFormOneCaseInsensitiveReadOnlyGameView()
        throws
    {
        let fixture = try makeContentPackFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let pack = try GarrysPADContentPack(url: fixture.archive)
        let source = try GModContentPackAssetSource(pack: pack)
        let fileSystem = try GModContentPackGameFileSystem(source: source)

        XCTAssertTrue(fileSystem.fileExists(
            at: "MATERIALS\\SYNTHETIC\\FROM_VPK.VTF"
        ))
        XCTAssertTrue(fileSystem.directoryExists(at: "materials/SYNTHETIC"))
        XCTAssertEqual(
            try fileSystem.readFile(at: "materials/precedence.txt"),
            Data("content".utf8),
            "loose GAME content must override the same nested-VPK path"
        )
        XCTAssertEqual(
            try fileSystem.readFile(at: "scripts/platform_only.txt"),
            Data("platform".utf8)
        )
        XCTAssertEqual(
            try fileSystem.readFile(at: "materials/vpk_priority.txt"),
            Data("garrysmod-vpk".utf8),
            "the ordered garrysmod VPK must precede platform_misc"
        )
        XCTAssertEqual(
            try fileSystem.listDirectory(at: "materials/synthetic"),
            [
                LuaVirtualFileSystemEntry(name: "base.vmt", isDirectory: false),
                LuaVirtualFileSystemEntry(
                    name: "from_vpk.vtf",
                    isDirectory: false
                ),
            ]
        )
        XCTAssertThrowsError(
            try fileSystem.writeFile(Data(), at: "materials/new.vmt")
        ) { error in
            guard case GMLuaFileSystemError.readOnly("materials/new.vmt") = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testMapPakThenContentPackThenBundledPriorityAndCrossMountMaterial()
        throws
    {
        let fixture = try makeContentPackFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let source = try GModContentPackAssetSource(
            pack: GarrysPADContentPack(url: fixture.archive)
        )
        let content = try GModContentPackGameFileSystem(source: source)
        let bundled = try LuaMemoryFileSystem(initialFiles: [
            "materials/precedence.txt": Data("bundled".utf8),
        ])
        let mapPak = try SourceBSPPakFileSystem(archiveData: makeStoredZIP([
            "materials/precedence.txt": Data("map".utf8),
            "materials/synthetic/map.vmt": Data(
                (
                    "\"Patch\" { " +
                        "\"include\" \"materials/synthetic/base.vmt\" " +
                        "\"replace\" { } }"
                ).utf8
            ),
        ]))

        // SERVER and CLIENT construct independent writable overlays while
        // sharing the same immutable map/content backing.
        for realm in ["SERVER", "CLIENT"] {
            let mounted = try GModPlayableSession.makeMountedContentFileSystem(
                mapPakFileSystem: mapPak,
                contentPackFileSystem: content,
                bundledFileSystemForTesting: bundled
            )
            XCTAssertEqual(
                try mounted.readFile(at: "MATERIALS/PRECEDENCE.TXT"),
                Data("map".utf8),
                "\(realm) did not keep BSP Pak above content and bundled"
            )

            let resolver = GMLuaVPKMaterialPixelResolver(
                looseFileSystem: mounted,
                archivesInPriorityOrder: []
            )
            let material = try resolver.resolve(named: "synthetic/map")
            XCTAssertEqual(material.metadata.shaderName.utf8String, "UnlitGeneric")
            XCTAssertEqual(material.metadata.status, .resolved)
            XCTAssertEqual(
                material.metadata.baseTextureName?.utf8String,
                "materials/synthetic/from_vpk.vtf"
            )
            XCTAssertEqual(material.rgbaBytes, Data([9, 8, 7, 6]))
        }

        let emptyPak = try SourceBSPPakFileSystem(archiveData: Data())
        let withoutMapOverride = try GModPlayableSession
            .makeMountedContentFileSystem(
                mapPakFileSystem: emptyPak,
                contentPackFileSystem: content,
                bundledFileSystemForTesting: bundled
            )
        XCTAssertEqual(
            try withoutMapOverride.readFile(at: "materials/precedence.txt"),
            Data("content".utf8)
        )

        let bundledOnly = try GModPlayableSession.makeMountedContentFileSystem(
            mapPakFileSystem: emptyPak,
            bundledFileSystemForTesting: bundled
        )
        XCTAssertEqual(
            try bundledOnly.readFile(at: "materials/precedence.txt"),
            Data("bundled".utf8)
        )
    }

    private func makeContentPackFixture() throws
        -> (directory: URL, archive: URL)
    {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "GModContentPackGameFileSystemTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        let vtf = makeRGBA8888VTF(pixel: [9, 8, 7, 6])
        let vpk = makePreloadedVPK([
            "materials/precedence.txt": Data("vpk".utf8),
            "materials/synthetic/from_vpk.vtf": vtf,
            "materials/vpk_priority.txt": Data("garrysmod-vpk".utf8),
        ])
        let platformVPK = makePreloadedVPK([
            "materials/vpk_priority.txt": Data("platform-vpk".utf8),
        ])
        let archive = directory.appendingPathComponent("GarrysPAD_Content_Test.zip")
        try makeStoredZIP([
            "garrysmod/maps/gm_construct.bsp": Data("construct".utf8),
            "garrysmod/maps/gm_flatgrass.bsp": Data("flatgrass".utf8),
            "garrysmod/html/img/bg.jpg": Data("jpg".utf8),
            "garrysmod/garrysmod_dir.vpk": vpk,
            "garrysmod/materials/precedence.txt": Data("content".utf8),
            "garrysmod/materials/synthetic/base.vmt": Data(
                (
                    "\"UnlitGeneric\" { " +
                        "\"$basetexture\" \"synthetic/from_vpk\" }"
                ).utf8
            ),
            "platform/scripts/platform_only.txt": Data("platform".utf8),
            "platform/platform_misc_dir.vpk": platformVPK,
        ]).write(to: archive)
        return (directory, archive)
    }
}

private func makePreloadedVPK(_ files: [String: Data]) -> Data {
    struct Entry {
        let directory: String
        let stem: String
        let fileExtension: String
        let data: Data
    }
    let entries = files.map { path, data -> Entry in
        let nsPath = path as NSString
        let fileName = nsPath.lastPathComponent as NSString
        return Entry(
            directory: nsPath.deletingLastPathComponent.isEmpty
                ? " " : nsPath.deletingLastPathComponent,
            stem: fileName.deletingPathExtension,
            fileExtension: fileName.pathExtension.isEmpty
                ? " " : fileName.pathExtension,
            data: data
        )
    }
    var tree = Data()
    for fileExtension in Set(entries.map(\.fileExtension)).sorted() {
        tree.appendContentGameCString(fileExtension)
        let extensionEntries = entries.filter {
            $0.fileExtension == fileExtension
        }
        for directory in Set(extensionEntries.map(\.directory)).sorted() {
            tree.appendContentGameCString(directory)
            for entry in extensionEntries.filter({ $0.directory == directory })
                .sorted(by: { $0.stem < $1.stem }) {
                tree.appendContentGameCString(entry.stem)
                tree.appendContentGameLE(entry.data.contentGameCRC32)
                tree.appendContentGameLE(UInt16(entry.data.count))
                tree.appendContentGameLE(UInt16(0x7FFF))
                tree.appendContentGameLE(UInt32(0))
                tree.appendContentGameLE(UInt32(0))
                tree.appendContentGameLE(UInt16(0xFFFF))
                tree.append(entry.data)
            }
            tree.append(0)
        }
        tree.append(0)
    }
    tree.append(0)

    var result = Data()
    result.appendContentGameLE(UInt32(0x55AA_1234))
    result.appendContentGameLE(UInt32(1))
    result.appendContentGameLE(UInt32(tree.count))
    result.append(tree)
    return result
}

private func makeStoredZIP(_ files: [String: Data]) -> Data {
    struct IndexedEntry {
        let path: String
        let data: Data
        let offset: UInt32
        let crc32: UInt32
    }
    var result = Data()
    var indexed: [IndexedEntry] = []
    for path in files.keys.sorted() {
        let data = files[path]!
        let pathData = Data(path.utf8)
        let offset = UInt32(result.count)
        let crc = data.contentGameCRC32
        result.appendContentGameLE(UInt32(0x0403_4B50))
        result.appendContentGameLE(UInt16(20))
        result.appendContentGameLE(UInt16(0))
        result.appendContentGameLE(UInt16(0))
        result.appendContentGameLE(UInt16(0))
        result.appendContentGameLE(UInt16(0))
        result.appendContentGameLE(crc)
        result.appendContentGameLE(UInt32(data.count))
        result.appendContentGameLE(UInt32(data.count))
        result.appendContentGameLE(UInt16(pathData.count))
        result.appendContentGameLE(UInt16(0))
        result.append(pathData)
        result.append(data)
        indexed.append(IndexedEntry(
            path: path,
            data: data,
            offset: offset,
            crc32: crc
        ))
    }

    let centralOffset = UInt32(result.count)
    for entry in indexed {
        let pathData = Data(entry.path.utf8)
        result.appendContentGameLE(UInt32(0x0201_4B50))
        result.appendContentGameLE(UInt16(20))
        result.appendContentGameLE(UInt16(20))
        result.appendContentGameLE(UInt16(0))
        result.appendContentGameLE(UInt16(0))
        result.appendContentGameLE(UInt16(0))
        result.appendContentGameLE(UInt16(0))
        result.appendContentGameLE(entry.crc32)
        result.appendContentGameLE(UInt32(entry.data.count))
        result.appendContentGameLE(UInt32(entry.data.count))
        result.appendContentGameLE(UInt16(pathData.count))
        result.appendContentGameLE(UInt16(0))
        result.appendContentGameLE(UInt16(0))
        result.appendContentGameLE(UInt16(0))
        result.appendContentGameLE(UInt16(0))
        result.appendContentGameLE(UInt32(0))
        result.appendContentGameLE(entry.offset)
        result.append(pathData)
    }
    let centralSize = UInt32(result.count) - centralOffset
    result.appendContentGameLE(UInt32(0x0605_4B50))
    result.appendContentGameLE(UInt16(0))
    result.appendContentGameLE(UInt16(0))
    result.appendContentGameLE(UInt16(indexed.count))
    result.appendContentGameLE(UInt16(indexed.count))
    result.appendContentGameLE(centralSize)
    result.appendContentGameLE(centralOffset)
    result.appendContentGameLE(UInt16(0))
    return result
}

private func makeRGBA8888VTF(pixel: [UInt8]) -> Data {
    precondition(pixel.count == 4)
    var bytes = [UInt8](repeating: 0, count: 80)
    func write(_ value: UInt16, at offset: Int) {
        bytes[offset] = UInt8(truncatingIfNeeded: value)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }
    func write(_ value: UInt32, at offset: Int) {
        bytes[offset] = UInt8(truncatingIfNeeded: value)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        bytes[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
        bytes[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
    }
    bytes.replaceSubrange(0..<4, with: [0x56, 0x54, 0x46, 0])
    write(UInt32(7), at: 4)
    write(UInt32(2), at: 8)
    write(UInt32(80), at: 12)
    write(UInt16(1), at: 16)
    write(UInt16(1), at: 18)
    write(UInt16(1), at: 24)
    write(Float(1).bitPattern, at: 48)
    write(UInt32(bitPattern: SourceVTFImageFormat.rgba8888.rawValue), at: 52)
    bytes[56] = 1
    write(UInt32(bitPattern: SourceVTFImageFormat.unknown.rawValue), at: 57)
    write(UInt16(1), at: 63)
    bytes.append(contentsOf: pixel)
    return Data(bytes)
}

private extension Data {
    mutating func appendContentGameCString(_ value: String) {
        append(contentsOf: value.utf8)
        append(0)
    }

    mutating func appendContentGameLE(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
    }

    mutating func appendContentGameLE(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 24))
    }

    var contentGameCRC32: UInt32 {
        var crc = UInt32.max
        for byte in self {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) == 1
                    ? (crc >> 1) ^ 0xEDB8_8320
                    : crc >> 1
            }
        }
        return ~crc
    }
}
