import Dispatch
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

    func testVPKReadsExternalChunkThroughBoundedRandomAccessSource() throws {
        let chunkPrefix = Data([0x11, 0x22, 0x33])
        let preload = Data("zip-".utf8)
        let payload = Data("range".utf8)
        let entries = [
            SyntheticVPKEntry(
                fileExtension: "dat",
                directory: "nested",
                stem: "asset",
                crc32: crc32(preload + payload),
                preloadData: preload,
                archiveIndex: 0,
                offset: UInt32(chunkPrefix.count),
                length: UInt32(payload.count)
            ),
        ]
        let tree = makeVPKTree(entries)
        var directoryFile = makeVPKHeader(
            version: 2,
            treeSize: tree.count,
            fileDataSectionSize: 0
        )
        directoryFile.append(tree)
        var chunkFile = chunkPrefix
        chunkFile.append(payload)
        let files: [String: Data] = [
            "content/synthetic_dir.vpk": directoryFile,
            "content/synthetic_000.vpk": chunkFile,
        ]
        let source = GMLuaVPKRandomAccessSource(
            byteCount: { path in
                files[path].map { UInt64($0.count) }
            },
            read: { path, offset, count in
                guard let data = files[path],
                      offset <= UInt64(data.count),
                      count >= 0,
                      UInt64(count) <= UInt64(data.count) - offset else {
                    throw GMLuaVPKError.truncatedData(path)
                }
                let start = Int(offset)
                return data.subdata(in: start..<(start + count))
            }
        )

        let archive = try GMLuaVPKArchive(
            directoryFilePath: "content/synthetic_dir.vpk",
            randomAccessSource: source
        )
        XCTAssertEqual(archive.version, 2)
        XCTAssertEqual(
            try archive.data(for: "NESTED\\ASSET.DAT"),
            preload + payload
        )
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

    func testSourceMaterialResolverExpandsPatchAndDecodesOnlyStaticBaseVTF() throws {
        let rgba: [UInt8] = [
            10, 20, 30, 40,
            50, 60, 70, 80,
        ]
        let files: [String: Data] = [
            "materials/synthetic/base.vmt": Data(
                "\"UnlitGeneric\" { \"$basetexture\" \"synthetic/atlas\" }".utf8
            ),
            "materials/synthetic/patched.vmt": Data(
                (
                    "\"Patch\" { \"include\" \"materials/synthetic/base.vmt\" " +
                        "\"replace\" { \"$basetexture\" \"synthetic/atlas\" } }"
                ).utf8
            ),
            "materials/synthetic/dynamic.vmt": Data(
                "\"screenspace_general\" { \"$basetexture\" \"_rt_fullframefb\" }".utf8
            ),
            "materials/synthetic/atlas.vtf": makeRGBA8888VTF(
                width: 2,
                height: 1,
                pixels: rgba
            ),
        ]
        let loads = SourceMaterialLoadRecorder()
        let resolver = GMLuaSourceMaterialResolver(
            maximumCachedEntryCount: 2,
            maximumCachedByteCount: 16
        ) { path in
            loads.record(path)
            return files[path.lowercased()]
        }

        let patched = try resolver.resolve(named: "SYNTHETIC\\PATCHED")
        XCTAssertEqual(patched.metadata.materialPath, "materials/SYNTHETIC/PATCHED.vmt")
        XCTAssertEqual(patched.metadata.shaderName, "UnlitGeneric")
        XCTAssertEqual(
            patched.metadata.baseTextureName,
            "materials/synthetic/atlas.vtf"
        )
        XCTAssertEqual(
            patched.metadata.dimensions,
            GMLuaImageDimensions(width: 2, height: 1)
        )
        XCTAssertFalse(patched.metadata.isError)
        XCTAssertEqual(patched.metadata.status, .resolved)
        XCTAssertEqual(patched.sourceTextureFormat, .rgba8888)
        XCTAssertEqual(patched.rgbaBytes, Data(rgba))
        XCTAssertEqual(
            patched.pixel(x: 1, y: 0),
            GMLuaRGBA8(red: 50, green: 60, blue: 70, alpha: 80)
        )

        _ = try resolver.resolve(named: "synthetic/patched")
        XCTAssertEqual(
            loads.count(for: "materials/SYNTHETIC/PATCHED.vmt"),
            1,
            "the second case-folded lookup must hit cache"
        )

        let dynamic = try resolver.resolve(named: "synthetic/dynamic")
        XCTAssertEqual(dynamic.metadata.shaderName, "screenspace_general")
        XCTAssertEqual(
            dynamic.metadata.baseTextureName,
            "materials/_rt_fullframefb.vtf"
        )
        XCTAssertEqual(dynamic.metadata.status, .baseTextureMissing)
        XCTAssertFalse(dynamic.metadata.isError)
        XCTAssertNil(dynamic.rgbaBytes)

        let missing = try resolver.resolve(named: "synthetic/missing")
        XCTAssertEqual(missing.metadata.status, .materialMissing)
        XCTAssertEqual(missing.metadata.shaderName, "shader_error")
        XCTAssertTrue(missing.metadata.isError)
        XCTAssertNil(missing.metadata.dimensions)
        XCTAssertLessThanOrEqual(resolver.cachedEntryCount, 2)
        XCTAssertLessThanOrEqual(resolver.cachedImageByteCount, 16)

        XCTAssertThrowsError(try resolver.resolve(named: "../escape")) { error in
            guard case GMLuaSourceMaterialError.unsafeLogicalPath = error else {
                return XCTFail("expected unsafeLogicalPath, got \(error)")
            }
        }
    }

    func testSourceMaterialResolverRetainsAuthoredVTFMipChainAndFlags() throws {
        let base = Array(repeating: UInt8(10), count: 4 * 4 * 4)
        let mip1 = Array(repeating: UInt8(20), count: 2 * 2 * 4)
        let mip2 = [UInt8(30), 31, 32, 255]
        let flags: SourceVTFTextureFlags = [.trilinear, .clampS, .anisotropic]
        let files: [String: Data] = [
            "materials/synthetic/mipped.vmt": Data(
                "\"LightmappedGeneric\" { \"$basetexture\" \"synthetic/mipped\" }".utf8
            ),
            "materials/synthetic/mipped.vtf": makeRGBA8888VTF(
                width: 4,
                height: 4,
                pixels: base,
                mipPixelsByLevel: [mip1, mip2],
                flags: flags
            ),
        ]
        let resolver = GMLuaSourceMaterialResolver { path in
            files[path.lowercased()]
        }

        let mipZero = try resolver.resolve(named: "synthetic/mipped")
        XCTAssertEqual(mipZero.mipImages.map(\.width), [4])
        XCTAssertEqual(mipZero.decodedByteCount, base.count)

        let material = try resolver.resolve(
            named: "synthetic/mipped",
            mipPolicy: .authoredChain
        )
        XCTAssertEqual(material.sourceTextureFlags, flags)
        XCTAssertEqual(material.mipImages.map(\.width), [4, 2, 1])
        XCTAssertEqual(material.mipImages.map(\.height), [4, 2, 1])
        XCTAssertEqual(material.mipImages.map(\.rgbaBytes), [
            Data(base), Data(mip1), Data(mip2),
        ])
        XCTAssertEqual(material.rgbaBytes, Data(base))
        XCTAssertEqual(material.decodedByteCount, base.count + mip1.count + mip2.count)
        XCTAssertEqual(resolver.cachedEntryCount, 2)
        XCTAssertEqual(
            resolver.cachedImageByteCount,
            base.count * 2 + mip1.count + mip2.count
        )
    }

    func testSourceMaterialCacheCannotPublishDelayedOldMountAfterSwap() throws {
        let materialPath = "materials/synthetic/epoch_race.vmt"
        let texturePath = "materials/synthetic/epoch_race.vtf"
        let material = Data(
            "\"UnlitGeneric\" { \"$basetexture\" \"synthetic/epoch_race\" }".utf8
        )
        let oldPixels = [UInt8](arrayLiteral: 255, 0, 0, 255)
        let newPixels = [UInt8](arrayLiteral: 0, 0, 255, 255)
        let source = DelayedSourceMaterialMount(
            files: [
                materialPath: material,
                texturePath: makeRGBA8888VTF(
                    width: 1,
                    height: 1,
                    pixels: oldPixels
                ),
            ],
            delayedPath: texturePath
        )
        let resolver = GMLuaSourceMaterialResolver(
            maximumCachedEntryCount: 1,
            maximumCachedByteCount: 64,
            contentEpochProvider: { source.contentEpoch },
            loader: { source.data(for: $0) }
        )
        let oldResolution = SourceMaterialAsyncResult()
        let workerFinished = DispatchSemaphore(value: 0)

        DispatchQueue(
            label: "GMLuaPlatformImageAndVPKTests.oldMountDecode"
        ).async {
            oldResolution.record(Result {
                try resolver.resolve(named: "synthetic/epoch_race")
            })
            workerFinished.signal()
        }
        guard source.delayedReadStarted.wait(timeout: .now() + 10) == .success
        else {
            source.releaseDelayedRead.signal()
            return XCTFail("old-map VTF decode did not reach its deterministic gate")
        }

        source.swap(to: [
            materialPath: material,
            texturePath: makeRGBA8888VTF(
                width: 1,
                height: 1,
                pixels: newPixels
            ),
        ])
        resolver.removeAllCachedMaterials()
        XCTAssertEqual(
            try resolver.resolve(named: "synthetic/epoch_race").rgbaBytes,
            Data(newPixels)
        )

        source.releaseDelayedRead.signal()
        guard workerFinished.wait(timeout: .now() + 10) == .success else {
            return XCTFail("delayed old-map decode did not finish")
        }
        XCTAssertEqual(
            try XCTUnwrap(oldResolution.value).get().rgbaBytes,
            Data(oldPixels)
        )
        XCTAssertEqual(
            try resolver.resolve(named: "synthetic/epoch_race").rgbaBytes,
            Data(newPixels),
            "the delayed old cache entry must be unreachable after the swap"
        )
        XCTAssertLessThanOrEqual(resolver.cachedEntryCount, 1)
        XCTAssertLessThanOrEqual(resolver.cachedImageByteCount, 64)
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

private final class SourceMaterialLoadRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]

    func record(_ path: String) {
        lock.lock()
        counts[path, default: 0] += 1
        lock.unlock()
    }

    func count(for path: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts[path] ?? 0
    }
}

private final class SourceMaterialAsyncResult: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Result<GMLuaResolvedSourceMaterial, Error>?

    func record(_ result: Result<GMLuaResolvedSourceMaterial, Error>) {
        lock.lock()
        storage = result
        lock.unlock()
    }

    var value: Result<GMLuaResolvedSourceMaterial, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private final class DelayedSourceMaterialMount: @unchecked Sendable {
    let delayedReadStarted = DispatchSemaphore(value: 0)
    let releaseDelayedRead = DispatchSemaphore(value: 0)

    private let lock = NSLock()
    private let delayedPath: String
    private var files: [String: Data]
    private var epochStorage: UInt64 = 1
    private var shouldDelay = true

    init(files: [String: Data], delayedPath: String) {
        self.files = Dictionary(
            uniqueKeysWithValues: files.map { ($0.key.lowercased(), $0.value) }
        )
        self.delayedPath = delayedPath.lowercased()
    }

    var contentEpoch: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return epochStorage
    }

    func data(for logicalPath: String) -> Data? {
        let key = logicalPath.lowercased()
        lock.lock()
        let result = files[key]
        let delayThisRead = key == delayedPath && shouldDelay
        if delayThisRead {
            shouldDelay = false
        }
        lock.unlock()

        if delayThisRead {
            delayedReadStarted.signal()
            releaseDelayedRead.wait()
        }
        return result
    }

    func swap(to replacement: [String: Data]) {
        lock.lock()
        precondition(epochStorage < UInt64.max)
        files = Dictionary(
            uniqueKeysWithValues: replacement.map {
                ($0.key.lowercased(), $0.value)
            }
        )
        epochStorage += 1
        lock.unlock()
    }
}

private func makeRGBA8888VTF(
    width: Int,
    height: Int,
    pixels: [UInt8],
    mipPixelsByLevel: [[UInt8]] = [],
    flags: SourceVTFTextureFlags = []
) -> Data {
    precondition(width > 0 && height > 0 && pixels.count == width * height * 4)
    for (offset, mip) in mipPixelsByLevel.enumerated() {
        let level = offset + 1
        precondition(
            mip.count == max(1, width >> level) * max(1, height >> level) * 4
        )
    }
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
    bytes.replaceSubrange(0..<4, with: [0x56, 0x54, 0x46, 0x00])
    write(UInt32(7), at: 4)
    write(UInt32(2), at: 8)
    write(UInt32(80), at: 12)
    write(UInt16(width), at: 16)
    write(UInt16(height), at: 18)
    write(flags.rawValue, at: 20)
    write(UInt16(1), at: 24)
    write(Float(1).bitPattern, at: 48)
    write(UInt32(bitPattern: SourceVTFImageFormat.rgba8888.rawValue), at: 52)
    bytes[56] = UInt8(1 + mipPixelsByLevel.count)
    write(UInt32(bitPattern: SourceVTFImageFormat.unknown.rawValue), at: 57)
    write(UInt16(1), at: 63)
    for mip in mipPixelsByLevel.reversed() {
        bytes.append(contentsOf: mip)
    }
    bytes.append(contentsOf: pixels)
    return Data(bytes)
}
