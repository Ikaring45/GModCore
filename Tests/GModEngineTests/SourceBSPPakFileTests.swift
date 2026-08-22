import Foundation
import XCTest
import GModEngine
import GModGameAssets
import GModLua

final class SourceBSPPakFileTests: XCTestCase {
    func testEmptyLumpIsAnEmptyReadOnlyRoot() throws {
        let pak = try SourceBSPPakFileSystem(archiveData: Data())
        XCTAssertTrue(pak.entries.isEmpty)
        XCTAssertTrue(pak.directoryExists(at: ""))
        XCTAssertEqual(try pak.listDirectory(at: ""), [])
        XCTAssertFalse(pak.fileExists(at: "materials/missing.vmt"))
    }

    func testBundledFlatgrassPakFixtureIndexesAndChecksRealAssetIntegrity() throws {
        let bsp = try SourceBSP(
            data: GModGameAssets.data(for: .flatgrass, kind: .bsp)
        )
        XCTAssertEqual(
            bsp.lump(.pakFile).descriptor.fileLength,
            41_601_660,
            "fixture changed; re-audit the real map pak before updating"
        )

        let pak = try SourceBSPPakFileSystem(bsp: bsp)
        XCTAssertEqual(pak.entries.count, 25)
        XCTAssertEqual(
            pak.entries.reduce(UInt64(0)) { $0 + $1.uncompressedByteCount },
            41_596_902
        )
        XCTAssertTrue(pak.entries.allSatisfy { $0.compression == .stored })

        let path = "materials/maps/gm_flatgrass/concrete/" +
            "concretefloor028c_0_96_-12032.vmt"
        XCTAssertTrue(pak.contains(path.uppercased()))
        let data = try XCTUnwrap(pak.data(for: path.uppercased()))
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains(
            "materials/CONCRETE/CONCRETEFLOOR028C.vmt"
        ))
        XCTAssertTrue(text.contains("maps/gm_flatgrass/c0_96_-12032"))
    }

    func testBundledConstructPakFixtureRetainsMaterialsAndPropLighting() throws {
        let bsp = try SourceBSP(
            data: GModGameAssets.data(for: .construct, kind: .bsp)
        )
        XCTAssertEqual(
            bsp.lump(.pakFile).descriptor.fileLength,
            3_784_681,
            "fixture changed; re-audit the real map pak before updating"
        )

        let pak = try SourceBSPPakFileSystem(bsp: bsp)
        XCTAssertEqual(pak.entries.count, 599)
        XCTAssertEqual(pak.entries.filter { $0.path.hasSuffix(".vmt") }.count, 179)
        XCTAssertEqual(pak.entries.filter { $0.path.hasSuffix(".vtf") }.count, 56)
        XCTAssertEqual(pak.entries.filter { $0.path.hasSuffix(".vhv") }.count, 364)
        let lighting = try XCTUnwrap(
            pak.entries.first { $0.path.hasSuffix(".vhv") }
        )
        XCTAssertEqual(
            UInt64(try pak.readFile(at: lighting.path.uppercased()).count),
            lighting.uncompressedByteCount
        )
    }

    func testStoredFixedAndDynamicDeflateMountAtSourcePriority() throws {
        let fixed = try data(hex: "cb48cdc9c90700")
        let storedBlockDecoded = Data("raw stored block".utf8)
        let storedBlock = rawStoredDeflate(storedBlockDecoded)
        let phrase = "dynamic huffman manifest vector. "
        let dynamicDecoded = Data(String(repeating: phrase, count: 300).utf8)
        let dynamicEncoded = try data(hex:
            "eddabb0d80300c05c05532013b45f988140e120424b66708daeb5d59f6f315a" +
            "eefcc314adaefde23cf14798edeae959e56d6716ea92ad007f3602fe4839c740" +
            "e9c453cc0245ca4622aa6622aa6622aa6622aa6622aa6622aa6622aa6622aa6" +
            "622aa6622aa6622aa6622aa6622aa6e2f8f569f601"
        )
        let archive = makeZIP([
            TestPakEntry(
                path: "materials/Test/Mixed.VMT",
                decoded: Data("map-local".utf8)
            ),
            TestPakEntry(
                path: "scripts/hello.txt",
                decoded: Data("hello".utf8),
                encoded: fixed,
                method: 8
            ),
            TestPakEntry(
                path: "scripts/stored-block.txt",
                decoded: storedBlockDecoded,
                encoded: storedBlock,
                method: 8
            ),
            TestPakEntry(
                path: "scripts/dynamic.txt",
                decoded: dynamicDecoded,
                encoded: dynamicEncoded,
                method: 8
            ),
            TestPakEntry(
                path: "materials/空.vmt",
                decoded: Data("utf8-name".utf8),
                flags: 0x0800
            ),
        ])
        let pak = try SourceBSPPakFileSystem(archiveData: archive)

        XCTAssertEqual(try pak.readFile(at: "SCRIPTS/HELLO.TXT"), Data("hello".utf8))
        XCTAssertEqual(
            try pak.readFile(at: "scripts/stored-block.txt"),
            storedBlockDecoded
        )
        XCTAssertEqual(try pak.readFile(at: "scripts/dynamic.txt"), dynamicDecoded)
        XCTAssertEqual(
            try pak.readFile(at: "materials/空.vmt"),
            Data("utf8-name".utf8)
        )
        XCTAssertTrue(pak.directoryExists(at: "MATERIALS/test"))
        XCTAssertEqual(try pak.listDirectory(at: ""), [
            LuaVirtualFileSystemEntry(name: "materials", isDirectory: true),
            LuaVirtualFileSystemEntry(name: "scripts", isDirectory: true),
        ])

        let base = try LuaMemoryFileSystem(initialFiles: [
            "materials/Test/Mixed.VMT": Data("base".utf8),
        ])
        let mounted = GMLuaMountedFileSystem(mounts: [
            try pak.makeSourcePriorityMount(),
            try GMLuaFileMount(
                name: "base-content",
                priority: 0,
                fileSystem: base
            ),
        ])
        XCTAssertEqual(
            try mounted.readFile(at: "materials/test/mixed.vmt"),
            Data("map-local".utf8),
            "SDK map pakfiles must override ordinary GAME content"
        )

        let sourceBase = try SourceMemoryFileProvider(utf8Files: [
            "materials/Test/Mixed.VMT": "base",
        ])
        let sourceFiles = SourceSearchPathFileSystem()
        _ = try sourceFiles.addSearchPath(
            provider: sourceBase,
            name: "base-content",
            pathIDs: ["GAME"],
            add: .tail
        )
        _ = try sourceFiles.addSearchPath(
            provider: pak.makeSourceFileProvider(),
            name: "map-pak",
            pathIDs: ["GAME"],
            kind: .mapPackFile,
            add: .head
        )
        XCTAssertEqual(
            try sourceFiles.readFile("materials/test/mixed.vmt"),
            Data("map-local".utf8)
        )
        XCTAssertEqual(
            try sourceFiles.readFile(
                "materials/test/mixed.vmt",
                filter: .cullPack
            ),
            Data("base".utf8)
        )
        XCTAssertEqual(
            try sourceFiles.resolveFile("materials/test/mixed.vmt")?.kind,
            .mapPackFile
        )

        XCTAssertThrowsError(try pak.writeFile(Data(), at: "new.txt")) { error in
            guard case GMLuaFileSystemError.readOnly("new.txt") = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertThrowsError(try pak.readFile(at: "../escape.txt")) { error in
            guard case GMLuaFileSystemError.invalidPath("../escape.txt") = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        XCTAssertThrowsError(
            try pak.data(for: "scripts/hello.txt", maximumByteCount: 4)
        ) { error in
            XCTAssertEqual(
                error as? SourceBSPPakFileError,
                .requestedSizeTooLarge(
                    path: "scripts/hello.txt",
                    byteCount: 5,
                    maximum: 4
                )
            )
        }
    }

    func testMalformedPathsDuplicatesFlagsMethodsAndLimitsFailAtIndexing() throws {
        XCTAssertThrowsError(try SourceBSPPakFileSystem(
            archiveData: makeZIP([
                TestPakEntry(path: "../escape.txt", decoded: Data("x".utf8)),
            ])
        )) { error in
            XCTAssertEqual(
                error as? SourceBSPPakFileError,
                .invalidPath("../escape.txt")
            )
        }

        XCTAssertThrowsError(try SourceBSPPakFileSystem(
            archiveData: makeZIP([
                TestPakEntry(
                    path: "descriptor.bin",
                    decoded: Data("x".utf8),
                    flags: 0x0008
                ),
            ])
        )) { error in
            XCTAssertEqual(
                error as? SourceBSPPakFileError,
                .unsupportedFlags(path: "descriptor.bin", flags: 0x0008)
            )
        }

        XCTAssertThrowsError(try SourceBSPPakFileSystem(
            archiveData: makeZIP([
                TestPakEntry(path: "材料.vmt", decoded: Data("x".utf8)),
            ])
        )) { error in
            guard case let SourceBSPPakFileError.invalidArchive(reason) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(reason.contains("lacks the ZIP UTF-8 flag"))
        }

        XCTAssertThrowsError(try SourceBSPPakFileSystem(
            archiveData: makeZIP([
                TestPakEntry(path: "materials/A.vmt", decoded: Data("a".utf8)),
                TestPakEntry(path: "MATERIALS/a.VMT", decoded: Data("b".utf8)),
            ])
        )) { error in
            XCTAssertEqual(
                error as? SourceBSPPakFileError,
                .duplicatePath("MATERIALS/a.VMT")
            )
        }

        XCTAssertThrowsError(try SourceBSPPakFileSystem(
            archiveData: makeZIP([
                TestPakEntry(
                    path: "encrypted.bin",
                    decoded: Data("x".utf8),
                    flags: 1
                ),
            ])
        )) { error in
            XCTAssertEqual(
                error as? SourceBSPPakFileError,
                .unsupportedFlags(path: "encrypted.bin", flags: 1)
            )
        }

        XCTAssertThrowsError(try SourceBSPPakFileSystem(
            archiveData: makeZIP([
                TestPakEntry(
                    path: "method.bin",
                    decoded: Data("x".utf8),
                    method: 14
                ),
            ])
        )) { error in
            XCTAssertEqual(
                error as? SourceBSPPakFileError,
                .unsupportedCompression(path: "method.bin", method: 14)
            )
        }

        let twoEntries = makeZIP([
            TestPakEntry(path: "a", decoded: Data("1234".utf8)),
            TestPakEntry(path: "b", decoded: Data("5678".utf8)),
        ])
        XCTAssertThrowsError(try SourceBSPPakFileSystem(
            archiveData: twoEntries,
            limits: SourceBSPPakFileLimits(maximumEntryCount: 1)
        )) { error in
            XCTAssertEqual(
                error as? SourceBSPPakFileError,
                .tooManyEntries(actual: 2, maximum: 1)
            )
        }
        XCTAssertThrowsError(try SourceBSPPakFileSystem(
            archiveData: twoEntries,
            limits: SourceBSPPakFileLimits(
                maximumEntryByteCount: 3,
                maximumTotalByteCount: 8
            )
        )) { error in
            XCTAssertEqual(
                error as? SourceBSPPakFileError,
                .entryTooLarge(path: "a", byteCount: 4, maximum: 3)
            )
        }
        XCTAssertThrowsError(try SourceBSPPakFileSystem(
            archiveData: twoEntries,
            limits: SourceBSPPakFileLimits(maximumTotalByteCount: 7)
        )) { error in
            XCTAssertEqual(
                error as? SourceBSPPakFileError,
                .totalSizeTooLarge(byteCount: 8, maximum: 7)
            )
        }

        XCTAssertThrowsError(try SourceBSPPakFileSystem(
            archiveData: makeZIP([
                TestPakEntry(path: "123456789", decoded: Data()),
            ]),
            limits: SourceBSPPakFileLimits(maximumPathByteCount: 8)
        )) { error in
            XCTAssertEqual(
                error as? SourceBSPPakFileError,
                .pathTooLong(actual: 9, maximum: 8)
            )
        }
        XCTAssertThrowsError(try SourceBSPPakFileSystem(
            archiveData: makeZIP([
                TestPakEntry(path: "a/b/c", decoded: Data()),
            ]),
            limits: SourceBSPPakFileLimits(maximumPathComponentCount: 2)
        )) { error in
            XCTAssertEqual(
                error as? SourceBSPPakFileError,
                .tooManyPathComponents(actual: 3, maximum: 2)
            )
        }
        XCTAssertThrowsError(try SourceBSPPakFileSystem(
            archiveData: makeZIP([
                TestPakEntry(path: "aa/bb/cc/file", decoded: Data()),
            ]),
            limits: SourceBSPPakFileLimits(maximumIndexPathByteCount: 20)
        )) { error in
            XCTAssertEqual(
                error as? SourceBSPPakFileError,
                .indexTooLarge(byteCount: 28, maximum: 20)
            )
        }
        XCTAssertThrowsError(try SourceBSPPakFileSystem(
            archiveData: makeZIP([
                TestPakEntry(
                    path: "large-input.bin",
                    decoded: Data(),
                    encoded: Data(repeating: 0, count: 64),
                    method: 8
                ),
            ]),
            limits: SourceBSPPakFileLimits(
                maximumCompressedEntryByteCount: 32
            )
        )) { error in
            XCTAssertEqual(
                error as? SourceBSPPakFileError,
                .compressedEntryTooLarge(
                    path: "large-input.bin",
                    byteCount: 64,
                    maximum: 32
                )
            )
        }

        let workBounded = try SourceBSPPakFileSystem(archiveData: makeZIP([
            TestPakEntry(
                path: "large-input.bin",
                decoded: Data(),
                encoded: Data(repeating: 0, count: 64),
                method: 8
            ),
        ]))
        XCTAssertThrowsError(try workBounded.data(
            for: "large-input.bin",
            maximumByteCount: 1,
            maximumCompressedByteCount: 32
        )) { error in
            XCTAssertEqual(
                error as? SourceBSPPakFileError,
                .requestedCompressedSizeTooLarge(
                    path: "large-input.bin",
                    byteCount: 64,
                    maximum: 32
                )
            )
        }
    }

    func testCentralLocalMismatchCRCAndMalformedDeflateNeverReturnBytes() throws {
        XCTAssertThrowsError(try SourceBSPPakFileSystem(
            archiveData: makeZIP([
                TestPakEntry(
                    path: "central.txt",
                    decoded: Data("x".utf8),
                    localPath: "different.txt"
                ),
            ])
        )) { error in
            guard case let SourceBSPPakFileError.invalidArchive(reason) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(reason.contains("names differ"))
        }

        let badCRC = try SourceBSPPakFileSystem(archiveData: makeZIP([
            TestPakEntry(
                path: "bad-crc.txt",
                decoded: Data("payload".utf8),
                crc32: 0
            ),
        ]))
        XCTAssertThrowsError(try badCRC.readFile(at: "bad-crc.txt")) { error in
            XCTAssertEqual(
                error as? SourceBSPPakFileError,
                .checksumMismatch("bad-crc.txt")
            )
        }

        let malformedDeflate = try SourceBSPPakFileSystem(archiveData: makeZIP([
            TestPakEntry(
                path: "bad-deflate.txt",
                decoded: Data("hello".utf8),
                encoded: Data([0xFF, 0xFF, 0xFF]),
                method: 8
            ),
        ]))
        XCTAssertThrowsError(try malformedDeflate.readFile(at: "bad-deflate.txt")) {
            error in
            guard case let SourceBSPPakFileError.decodeFailed(path, _) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(path, "bad-deflate.txt")
        }

        let badDeflatedCRC = try SourceBSPPakFileSystem(archiveData: makeZIP([
            TestPakEntry(
                path: "bad-deflated-crc.txt",
                decoded: Data("hello".utf8),
                encoded: try data(hex: "cb48cdc9c90700"),
                method: 8,
                crc32: 0
            ),
        ]))
        XCTAssertThrowsError(
            try badDeflatedCRC.readFile(at: "bad-deflated-crc.txt")
        ) { error in
            XCTAssertEqual(
                error as? SourceBSPPakFileError,
                .checksumMismatch("bad-deflated-crc.txt")
            )
        }
    }

    private func data(hex: String) throws -> Data {
        guard hex.count.isMultiple(of: 2) else {
            throw NSError(domain: "hex", code: 1)
        }
        var result = Data()
        var cursor = hex.startIndex
        while cursor < hex.endIndex {
            let end = hex.index(cursor, offsetBy: 2)
            guard let byte = UInt8(hex[cursor..<end], radix: 16) else {
                throw NSError(domain: "hex", code: 2)
            }
            result.append(byte)
            cursor = end
        }
        return result
    }

    private func rawStoredDeflate(_ decoded: Data) -> Data {
        precondition(decoded.count <= Int(UInt16.max))
        let count = UInt16(decoded.count)
        var result = Data([0x01])
        result.appendPakLE(count)
        result.appendPakLE(~count)
        result.append(decoded)
        return result
    }

    private func makeZIP(_ entries: [TestPakEntry]) -> Data {
        struct IndexedEntry {
            let entry: TestPakEntry
            let localOffset: UInt32
            let crc32: UInt32
        }

        var archive = Data()
        var indexed: [IndexedEntry] = []
        for entry in entries {
            let localOffset = UInt32(archive.count)
            let localName = Data((entry.localPath ?? entry.path).utf8)
            let crc = entry.crc32 ?? entry.decoded.pakTestCRC32
            archive.appendPakLE(UInt32(0x0403_4B50))
            archive.appendPakLE(UInt16(20))
            archive.appendPakLE(entry.flags)
            archive.appendPakLE(entry.method)
            archive.appendPakLE(UInt16(0))
            archive.appendPakLE(UInt16(0))
            archive.appendPakLE(crc)
            archive.appendPakLE(UInt32(entry.encoded.count))
            archive.appendPakLE(UInt32(entry.decoded.count))
            archive.appendPakLE(UInt16(localName.count))
            archive.appendPakLE(UInt16(0))
            archive.append(localName)
            archive.append(entry.encoded)
            indexed.append(IndexedEntry(
                entry: entry,
                localOffset: localOffset,
                crc32: crc
            ))
        }

        let centralOffset = UInt32(archive.count)
        for item in indexed {
            let name = Data(item.entry.path.utf8)
            archive.appendPakLE(UInt32(0x0201_4B50))
            archive.appendPakLE(UInt16(20))
            archive.appendPakLE(UInt16(20))
            archive.appendPakLE(item.entry.flags)
            archive.appendPakLE(item.entry.method)
            archive.appendPakLE(UInt16(0))
            archive.appendPakLE(UInt16(0))
            archive.appendPakLE(item.crc32)
            archive.appendPakLE(UInt32(item.entry.encoded.count))
            archive.appendPakLE(UInt32(item.entry.decoded.count))
            archive.appendPakLE(UInt16(name.count))
            archive.appendPakLE(UInt16(0))
            archive.appendPakLE(UInt16(0))
            archive.appendPakLE(UInt16(0))
            archive.appendPakLE(UInt16(0))
            archive.appendPakLE(UInt32(0))
            archive.appendPakLE(item.localOffset)
            archive.append(name)
        }
        let centralByteCount = UInt32(archive.count) - centralOffset
        archive.appendPakLE(UInt32(0x0605_4B50))
        archive.appendPakLE(UInt16(0))
        archive.appendPakLE(UInt16(0))
        archive.appendPakLE(UInt16(entries.count))
        archive.appendPakLE(UInt16(entries.count))
        archive.appendPakLE(centralByteCount)
        archive.appendPakLE(centralOffset)
        archive.appendPakLE(UInt16(0))
        return archive
    }
}

private struct TestPakEntry {
    let path: String
    let decoded: Data
    let encoded: Data
    let method: UInt16
    let flags: UInt16
    let localPath: String?
    let crc32: UInt32?

    init(
        path: String,
        decoded: Data,
        encoded: Data? = nil,
        method: UInt16 = 0,
        flags: UInt16 = 0,
        localPath: String? = nil,
        crc32: UInt32? = nil
    ) {
        self.path = path
        self.decoded = decoded
        self.encoded = encoded ?? decoded
        self.method = method
        self.flags = flags
        self.localPath = localPath
        self.crc32 = crc32
    }
}

private extension Data {
    mutating func appendPakLE(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
    }

    mutating func appendPakLE(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 24))
    }

    var pakTestCRC32: UInt32 {
        var crc = UInt32.max
        for byte in self {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
            }
        }
        return ~crc
    }
}
