import Foundation
import XCTest
import GModEngine

final class GMLuaPlatformImageAndVPKTests: XCTestCase {
    func testPNGDecodePreservesTopLeftOrientationAndStraightAlphaRGBA() throws {
#if os(Windows) || os(iOS) || os(macOS)
        // A deliberately asymmetric 2x2 RGBA PNG. The two translucent primary
        // colors make a premultiplied-alpha result observably different.
        let png = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAF0lEQVR42mP4z8DwHwgbGIC0g6CS8X8AOTAGIm/J6C0AAAAASUVORK5CYII="
        ))
        let image = try GMLuaPlatformImageDecoder.decode(png)

        XCTAssertEqual(image.width, 2)
        XCTAssertEqual(image.height, 2)
        XCTAssertEqual(image.bytesPerRow, 8)
        XCTAssertEqual(
            image.pixel(x: 0, y: 0),
            GMLuaRGBA8(red: 255, green: 0, blue: 0, alpha: 255)
        )
        XCTAssertEqual(
            image.pixel(x: 1, y: 0),
            GMLuaRGBA8(red: 0, green: 255, blue: 0, alpha: 128)
        )
        XCTAssertEqual(
            image.pixel(x: 0, y: 1),
            GMLuaRGBA8(red: 0, green: 0, blue: 255, alpha: 64)
        )
        XCTAssertEqual(
            image.pixel(x: 1, y: 1),
            GMLuaRGBA8(red: 17, green: 34, blue: 51, alpha: 255)
        )
        XCTAssertNil(image.pixel(x: -1, y: 0))
        XCTAssertNil(image.pixel(x: 2, y: 0))
        XCTAssertNil(image.pixel(x: 0, y: 2))
#else
        throw XCTSkip("the package image bridge is available on Windows and Apple platforms")
#endif
    }

    func testImageDecoderClassifiesEmptyAndMalformedInput() throws {
        XCTAssertThrowsError(try GMLuaPlatformImageDecoder.decode(Data())) { error in
            XCTAssertEqual(error as? GMLuaImageDecodeError, .invalidArgument)
        }

#if os(Windows) || os(iOS) || os(macOS)
        let truncatedPNG = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        XCTAssertThrowsError(try GMLuaPlatformImageDecoder.decode(truncatedPNG)) { error in
            XCTAssertEqual(error as? GMLuaImageDecodeError, .malformedImage)
        }
#endif
    }

    func testVPKV1ReadsPreloadAndDirectoryInlineDataWithNormalizedPaths() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let preload = Data([0x50, 0x52, 0x45])
        let inline = Data([0x49, 0x4E, 0x4C, 0x49, 0x4E, 0x45])
        let completePayload = preload + inline
        let entries = [
            SyntheticVPKEntry(
                fileExtension: "PNG",
                directory: "Materials\\Synthetic",
                stem: "Atlas",
                crc32: crc32(completePayload),
                preloadData: preload,
                archiveIndex: 0x7FFF,
                offset: 0,
                length: UInt32(inline.count)
            ),
            SyntheticVPKEntry(
                fileExtension: " ",
                directory: " ",
                stem: "README",
                crc32: crc32(Data("preload-only".utf8)),
                preloadData: Data("preload-only".utf8),
                archiveIndex: 0x7FFF,
                offset: UInt32(inline.count),
                length: 0
            ),
        ]
        let tree = makeVPKTree(entries)
        var directoryFile = makeVPKHeader(version: 1, treeSize: tree.count)
        directoryFile.append(tree)
        directoryFile.append(inline)
        let directoryURL = root.appendingPathComponent("synthetic_dir.vpk")
        try directoryFile.write(to: directoryURL, options: .atomic)

        let archive = try GMLuaVPKArchive(directoryFileURL: directoryURL)
        XCTAssertEqual(archive.version, 1)
        XCTAssertEqual(archive.fileCount, 2)
        XCTAssertTrue(archive.contains("MATERIALS\\SYNTHETIC\\ATLAS.PNG"))
        XCTAssertEqual(
            try archive.data(for: "materials/synthetic/atlas.png"),
            completePayload
        )
        XCTAssertEqual(try archive.data(for: "readme"), Data("preload-only".utf8))
        XCTAssertNil(try archive.data(for: "materials/synthetic/missing.png"))

        XCTAssertFalse(archive.contains("../materials/synthetic/atlas.png"))
        XCTAssertFalse(archive.contains("materials//synthetic/atlas.png"))
        XCTAssertThrowsError(try archive.data(for: "materials/../synthetic/atlas.png")) { error in
            guard case .unsafePath = error as? GMLuaVPKError else {
                return XCTFail("expected unsafePath, got \(error)")
            }
        }
    }

    func testVPKV2ReadsPreloadPlusExternalChunkAndDirectoryFileData() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let chunkPrefix = Data([0xAA, 0xBB, 0xCC, 0xDD])
        let chunkPreload = Data("pre-".utf8)
        let chunkPayload = Data("chunk".utf8)
        let inlinePayload = Data("directory-data".utf8)
        let entries = [
            SyntheticVPKEntry(
                fileExtension: "bin",
                directory: "folder",
                stem: "chunked",
                crc32: crc32(chunkPreload + chunkPayload),
                preloadData: chunkPreload,
                archiveIndex: 0,
                offset: UInt32(chunkPrefix.count),
                length: UInt32(chunkPayload.count)
            ),
            SyntheticVPKEntry(
                fileExtension: "txt",
                directory: "folder",
                stem: "inline",
                crc32: crc32(inlinePayload),
                preloadData: Data(),
                archiveIndex: 0x7FFF,
                offset: 0,
                length: UInt32(inlinePayload.count)
            ),
        ]
        let tree = makeVPKTree(entries)
        var directoryFile = makeVPKHeader(
            version: 2,
            treeSize: tree.count,
            fileDataSectionSize: inlinePayload.count
        )
        directoryFile.append(tree)
        directoryFile.append(inlinePayload)
        let directoryURL = root.appendingPathComponent("synthetic_dir.vpk")
        try directoryFile.write(to: directoryURL, options: .atomic)

        var chunkFile = chunkPrefix
        chunkFile.append(chunkPayload)
        try chunkFile.write(
            to: root.appendingPathComponent("synthetic_000.vpk"),
            options: .atomic
        )

        let archive = try GMLuaVPKArchive(directoryFileURL: directoryURL)
        XCTAssertEqual(archive.version, 2)
        XCTAssertEqual(
            try archive.data(for: "FOLDER\\CHUNKED.BIN"),
            chunkPreload + chunkPayload
        )
        XCTAssertEqual(try archive.data(for: "folder/inline.txt"), inlinePayload)
    }

    func testVPKMaterialResolverPrependsMaterialsAndCachesDecodedPNG() throws {
#if os(Windows) || os(iOS) || os(macOS)
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let png = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAF0lEQVR42mP4z8DwHwgbGIC0g6CS8X8AOTAGIm/J6C0AAAAASUVORK5CYII="
        ))
        let entries = [
            SyntheticVPKEntry(
                fileExtension: "png",
                directory: "materials/synthetic",
                stem: "atlas",
                crc32: crc32(png),
                preloadData: Data(),
                archiveIndex: 0x7FFF,
                offset: 0,
                length: UInt32(png.count)
            ),
        ]
        let tree = makeVPKTree(entries)
        var directoryFile = makeVPKHeader(version: 1, treeSize: tree.count)
        directoryFile.append(tree)
        directoryFile.append(png)
        let directoryURL = root.appendingPathComponent("materials_dir.vpk")
        try directoryFile.write(to: directoryURL, options: .atomic)

        let archive = try GMLuaVPKArchive(directoryFileURL: directoryURL)
        let resolver = GMLuaVPKMaterialPixelResolver(archivesInPriorityOrder: [archive])
        XCTAssertEqual(
            try resolver.dimensions(
                materialPath: "SYNTHETIC\\ATLAS.PNG",
                encodedParameters: nil
            ),
            GMLuaImageDimensions(width: 2, height: 2)
        )
        XCTAssertNil(
            try resolver.dimensions(materialPath: "synthetic/not-an-image.vmt", encodedParameters: nil)
        )

        // The first lookup decoded and cached the complete image. Removing this
        // synthetic backing archive proves later palette samples do not reopen
        // or recopy the VPK payload.
        try FileManager.default.removeItem(at: directoryURL)
        XCTAssertEqual(
            try resolver.pixel(
                materialPath: "synthetic/atlas.png",
                encodedParameters: nil,
                x: 1,
                y: 0
            ),
            GMLuaRGBA8(red: 0, green: 255, blue: 0, alpha: 128)
        )
#else
        throw XCTSkip("the package image bridge is available on Windows and Apple platforms")
#endif
    }

    func testVPKRejectsChecksumMismatchAndV2FileDataSectionOverrun() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let badCRCBody = Data("payload".utf8)
        let badCRCEntries = [
            SyntheticVPKEntry(
                fileExtension: "dat",
                directory: "bad",
                stem: "crc",
                crc32: crc32(badCRCBody) ^ 0xFFFF_FFFF,
                preloadData: Data(),
                archiveIndex: 0x7FFF,
                offset: 0,
                length: UInt32(badCRCBody.count)
            ),
        ]
        let badCRCTree = makeVPKTree(badCRCEntries)
        var badCRCFile = makeVPKHeader(version: 1, treeSize: badCRCTree.count)
        badCRCFile.append(badCRCTree)
        badCRCFile.append(badCRCBody)
        let badCRCURL = root.appendingPathComponent("badcrc_dir.vpk")
        try badCRCFile.write(to: badCRCURL, options: .atomic)

        let badCRCArchive = try GMLuaVPKArchive(directoryFileURL: badCRCURL)
        XCTAssertThrowsError(try badCRCArchive.data(for: "bad/crc.dat")) { error in
            XCTAssertEqual(error as? GMLuaVPKError, .checksumMismatch("bad/crc.dat"))
        }

        // The entry points at bytes in the following MD5 section, not at the
        // declared VPK v2 File Data Section. A reader must reject the overrun
        // even if those bytes happen to satisfy the entry CRC.
        let md5Section = Data("not-file-data".utf8)
        let overrunEntries = [
            SyntheticVPKEntry(
                fileExtension: "dat",
                directory: "bad",
                stem: "section",
                crc32: crc32(md5Section),
                preloadData: Data(),
                archiveIndex: 0x7FFF,
                offset: 0,
                length: UInt32(md5Section.count)
            ),
        ]
        let overrunTree = makeVPKTree(overrunEntries)
        var overrunFile = makeVPKHeader(
            version: 2,
            treeSize: overrunTree.count,
            fileDataSectionSize: 0,
            archiveMD5SectionSize: md5Section.count
        )
        overrunFile.append(overrunTree)
        overrunFile.append(md5Section)
        let overrunURL = root.appendingPathComponent("overrun_dir.vpk")
        try overrunFile.write(to: overrunURL, options: .atomic)

        XCTAssertThrowsError(try GMLuaVPKArchive(directoryFileURL: overrunURL)) { error in
            guard case .malformedTree = error as? GMLuaVPKError else {
                return XCTFail("expected malformedTree, got \(error)")
            }
        }
    }

    func testInstalledGModVPKDiagnosticReadsDefaultDermaAtlasWithoutCopyingIt() throws {
        guard let path = ProcessInfo.processInfo.environment["GMOD_VPK_DIAGNOSTIC_PATH"],
              !path.isEmpty else {
            throw XCTSkip("set GMOD_VPK_DIAGNOSTIC_PATH to an installed garrysmod_dir.vpk")
        }
        let archive = try GMLuaVPKArchive(directoryFileURL: URL(fileURLWithPath: path))
        XCTAssertGreaterThan(archive.fileCount, 0)
        let logicalPath = "materials/gwenskin/GModDefault.png"
        XCTAssertTrue(archive.contains(logicalPath))
        let png = try XCTUnwrap(archive.data(for: logicalPath))
        XCTAssertTrue(png.starts(with: Data([0x89, 0x50, 0x4E, 0x47])))

#if os(Windows) || os(iOS) || os(macOS)
        let image = try GMLuaPlatformImageDecoder.decode(png)
        XCTAssertGreaterThan(image.width, 0)
        XCTAssertGreaterThan(image.height, 0)
#endif
    }
}

private struct SyntheticVPKEntry {
    let fileExtension: String
    let directory: String
    let stem: String
    let crc32: UInt32
    let preloadData: Data
    let archiveIndex: UInt16
    let offset: UInt32
    let length: UInt32
}

private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        "GMLuaPlatformImageAndVPKTests-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    return url
}

private func makeVPKHeader(
    version: UInt32,
    treeSize: Int,
    fileDataSectionSize: Int = 0,
    archiveMD5SectionSize: Int = 0,
    otherMD5SectionSize: Int = 0,
    signatureSectionSize: Int = 0
) -> Data {
    precondition(treeSize >= 0 && treeSize <= Int(UInt32.max))
    var result = Data()
    result.appendLittleEndian(UInt32(0x55AA_1234))
    result.appendLittleEndian(version)
    result.appendLittleEndian(UInt32(treeSize))
    if version == 2 {
        result.appendLittleEndian(UInt32(fileDataSectionSize))
        result.appendLittleEndian(UInt32(archiveMD5SectionSize))
        result.appendLittleEndian(UInt32(otherMD5SectionSize))
        result.appendLittleEndian(UInt32(signatureSectionSize))
    }
    return result
}

private func makeVPKTree(_ entries: [SyntheticVPKEntry]) -> Data {
    var result = Data()
    for fileExtension in Set(entries.map(\.fileExtension)).sorted() {
        result.appendCString(fileExtension)
        let extensionEntries = entries.filter { $0.fileExtension == fileExtension }
        for directory in Set(extensionEntries.map(\.directory)).sorted() {
            result.appendCString(directory)
            for entry in extensionEntries.filter({ $0.directory == directory })
                .sorted(by: { $0.stem < $1.stem }) {
                result.appendCString(entry.stem)
                result.appendLittleEndian(entry.crc32)
                result.appendLittleEndian(UInt16(entry.preloadData.count))
                result.appendLittleEndian(entry.archiveIndex)
                result.appendLittleEndian(entry.offset)
                result.appendLittleEndian(entry.length)
                result.appendLittleEndian(UInt16(0xFFFF))
                result.append(entry.preloadData)
            }
            result.append(0)
        }
        result.append(0)
    }
    result.append(0)
    return result
}

private func crc32(_ data: Data) -> UInt32 {
    var crc = UInt32.max
    for byte in data {
        crc ^= UInt32(byte)
        for _ in 0..<8 {
            let mask = UInt32(bitPattern: -Int32(crc & 1))
            crc = (crc >> 1) ^ (0xEDB8_8320 & mask)
        }
    }
    return ~crc
}

private extension Data {
    mutating func appendCString(_ value: String) {
        append(contentsOf: value.utf8)
        append(0)
    }

    mutating func appendLittleEndian(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
    }

    mutating func appendLittleEndian(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 24))
    }
}
