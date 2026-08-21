import Foundation
import XCTest
import GModGameAssets

final class GarrysPADContentManifestTests: XCTestCase {
    func testDeflatedFullManifestAuthorizesExactIndexAndVerifiesSHA() throws {
        let payloads = playablePayloads()
        let fixture = try makePack(
            archivePayloads: payloads,
            declaredPayloads: payloads,
            deflateManifest: true
        )
        defer { try? FileManager.default.removeItem(at: fixture) }
        let pack = try GarrysPADContentPack(url: fixture)
        let manifest = try GarrysPADContentManifestValidator.loadAndValidateIndex(
            from: pack
        )
        XCTAssertEqual(manifest.schemaVersion, 1)
        XCTAssertEqual(manifest.format, "GarrysPADContentPack")
        XCTAssertEqual(manifest.profile, "Playground")
        XCTAssertEqual(manifest.source, "test-owned fixture")
        XCTAssertEqual(manifest.mountRoots, ["garrysmod"])
        XCTAssertEqual(manifest.fileCount, payloads.count)
        XCTAssertTrue(manifest.files.allSatisfy { $0.sha256.count == 64 })

        var observed: [GarrysPADContentVerificationProgress] = []
        try GarrysPADContentManifestValidator.verifyPayloads(
            in: pack,
            manifest: manifest,
            chunkByteCount: 3,
            progress: { observed.append($0) }
        )
        let final = try XCTUnwrap(observed.last)
        XCTAssertNil(final.currentPath)
        XCTAssertEqual(final.completedFileCount, payloads.count)
        XCTAssertEqual(final.completedByteCount, final.totalByteCount)
        XCTAssertTrue(zip(observed, observed.dropFirst()).allSatisfy {
            $0.completedByteCount <= $1.completedByteCount &&
                $0.completedFileCount <= $1.completedFileCount
        })
    }

    func testNestedAndHiddenUndeclaredEntriesAreRejected() throws {
        let declared = playablePayloads()
        for extraPath in [
            "garrysmod/html/nested/extra.txt",
            "garrysmod/html/.hidden",
        ] {
            var archive = declared
            archive[extraPath] = Data("unexpected".utf8)
            let fixture = try makePack(
                archivePayloads: archive,
                declaredPayloads: declared,
                deflateManifest: true
            )
            defer { try? FileManager.default.removeItem(at: fixture) }
            let pack = try GarrysPADContentPack(url: fixture)
            XCTAssertThrowsError(
                try GarrysPADContentManifestValidator.loadAndValidateIndex(from: pack),
                extraPath
            ) { error in
                XCTAssertTrue(String(describing: error).contains("undeclared entry"))
            }
        }
    }

    func testMissingCaseCollidingAndManifestAuthorizedHiddenPathsAreRejected() throws {
        var declared = playablePayloads()
        declared["garrysmod/html/missing.txt"] = Data("missing".utf8)
        let missingFixture = try makePack(
            archivePayloads: playablePayloads(),
            declaredPayloads: declared,
            deflateManifest: false
        )
        defer { try? FileManager.default.removeItem(at: missingFixture) }
        let missingPack = try GarrysPADContentPack(url: missingFixture)
        XCTAssertThrowsError(
            try GarrysPADContentManifestValidator.loadAndValidateIndex(from: missingPack)
        )

        var caseDeclared = playablePayloads()
        let original = caseDeclared["garrysmod/html/menu.html"]!
        caseDeclared["Garrysmod/html/menu.html"] = original
        let caseFixture = try makePack(
            archivePayloads: playablePayloads(),
            declaredPayloads: caseDeclared,
            deflateManifest: false
        )
        defer { try? FileManager.default.removeItem(at: caseFixture) }
        let casePack = try GarrysPADContentPack(url: caseFixture)
        XCTAssertThrowsError(
            try GarrysPADContentManifestValidator.loadAndValidateIndex(from: casePack)
        ) { error in
            XCTAssertTrue(String(describing: error).contains("case-colliding"))
        }

        var hiddenDeclared = playablePayloads()
        hiddenDeclared["garrysmod/.hidden"] = Data("declared hidden".utf8)
        let hiddenFixture = try makePack(
            archivePayloads: hiddenDeclared,
            declaredPayloads: hiddenDeclared,
            deflateManifest: false
        )
        defer { try? FileManager.default.removeItem(at: hiddenFixture) }
        let hiddenPack = try GarrysPADContentPack(url: hiddenFixture)
        XCTAssertThrowsError(
            try GarrysPADContentManifestValidator.loadAndValidateIndex(from: hiddenPack)
        ) { error in
            XCTAssertTrue(String(describing: error).contains("unsafe or unauthorized"))
        }
    }

    func testSameSizeTamperWithValidZIPCRCIsCaughtByManifestSHA256() throws {
        let declared = playablePayloads()
        var tampered = declared
        tampered["garrysmod/html/menu.html"] = Data("<html>evil</html>".utf8)
        XCTAssertEqual(
            tampered["garrysmod/html/menu.html"]!.count,
            declared["garrysmod/html/menu.html"]!.count
        )
        let fixture = try makePack(
            archivePayloads: tampered,
            declaredPayloads: declared,
            deflateManifest: true
        )
        defer { try? FileManager.default.removeItem(at: fixture) }
        let pack = try GarrysPADContentPack(url: fixture)
        let manifest = try GarrysPADContentManifestValidator.loadAndValidateIndex(
            from: pack
        )
        XCTAssertThrowsError(try GarrysPADContentManifestValidator.verifyPayloads(
            in: pack,
            manifest: manifest
        )) { error in
            guard case let .hashMismatch(path, _, _) =
                error as? GarrysPADContentManifestError else {
                return XCTFail("unexpected same-size tamper result: \(error)")
            }
            XCTAssertEqual(path, "garrysmod/html/menu.html")
        }
    }

    func testStreamingVerificationCancellationStopsAtRealByteBoundary() throws {
        let payloads = playablePayloads()
        let fixture = try makePack(
            archivePayloads: payloads,
            declaredPayloads: payloads,
            deflateManifest: false
        )
        defer { try? FileManager.default.removeItem(at: fixture) }
        let pack = try GarrysPADContentPack(url: fixture)
        let manifest = try GarrysPADContentManifestValidator.loadAndValidateIndex(
            from: pack
        )
        var cancel = false
        var lastProgress: GarrysPADContentVerificationProgress?
        XCTAssertThrowsError(try GarrysPADContentManifestValidator.verifyPayloads(
            in: pack,
            manifest: manifest,
            chunkByteCount: 2,
            shouldCancel: { cancel },
            progress: {
                lastProgress = $0
                if $0.completedByteCount >= 2 { cancel = true }
            }
        )) { error in
            XCTAssertTrue(error is CancellationError)
        }
        let stopped = try XCTUnwrap(lastProgress)
        XCTAssertGreaterThanOrEqual(stopped.completedByteCount, 2)
        XCTAssertLessThan(stopped.completedByteCount, stopped.totalByteCount)
        XCTAssertLessThan(stopped.completedFileCount, stopped.totalFileCount)
    }

    func testConfiguredLegacyPackDeflatedManifestValidatesExactIndex() throws {
        guard let path = ProcessInfo.processInfo.environment[
            "GMOD_CONTENT_PACK_DIAGNOSTIC_PATH"
        ], !path.isEmpty else {
            throw XCTSkip("GMOD_CONTENT_PACK_DIAGNOSTIC_PATH is not configured")
        }
        let pack = try GarrysPADContentPack(url: URL(fileURLWithPath: path))
        let root = try XCTUnwrap(
            pack.entry(for: GarrysPADContentPack.rootManifestPath)
        )
        XCTAssertEqual(root.compressionMethod, 8)
        let manifest = try GarrysPADContentManifestValidator.loadAndValidateIndex(
            from: pack
        )
        XCTAssertEqual(manifest.fileCount, 2_641)
        XCTAssertEqual(manifest.byteCount, 4_875_469_640)
        XCTAssertEqual(manifest.profile, "Playable")
        let corePaths = Set([
            "garrysmod/maps/gm_construct.bsp",
            "garrysmod/maps/gm_flatgrass.bsp",
            "garrysmod/html/img/bg.jpg",
            "garrysmod/html/menu.html",
        ])
        var finalProgress: GarrysPADContentVerificationProgress?
        try GarrysPADContentManifestValidator.verifyPayloads(
            in: pack,
            manifest: manifest,
            paths: corePaths,
            progress: { finalProgress = $0 }
        )
        XCTAssertEqual(finalProgress?.completedFileCount, corePaths.count)
        XCTAssertEqual(finalProgress?.completedByteCount, 84_179_465)
        XCTAssertEqual(
            finalProgress?.completedByteCount,
            finalProgress?.totalByteCount
        )
    }

    private func playablePayloads() -> [String: Data] {
        [
            "garrysmod/maps/gm_construct.bsp": Data("VBSPconstruct".utf8),
            "garrysmod/maps/gm_flatgrass.bsp": Data("VBSPflatgrass".utf8),
            "garrysmod/html/img/bg.jpg": Data([0xFF, 0xD8, 0xFF, 0xD9]),
            "garrysmod/html/menu.html": Data("<html>safe</html>".utf8),
        ]
    }

    private func makePack(
        archivePayloads: [String: Data],
        declaredPayloads: [String: Data],
        deflateManifest: Bool
    ) throws -> URL {
        let files: [[String: Any]] = declaredPayloads.keys.sorted().map { path in
            var hasher = GModContentSHA256()
            hasher.update(declaredPayloads[path]!)
            return [
                "path": path,
                "byteCount": declaredPayloads[path]!.count,
                "sha256": hasher.hexadecimalDigest(),
            ]
        }
        let manifest = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1,
            "format": "GarrysPADContentPack",
            "profile": "Playground",
            "createdAtUTC": "2026-08-21T00:00:00Z",
            "source": "test-owned fixture",
            "mountRoots": ["garrysmod"],
            "excludedRoots": ["garrysmod/addons"],
            "optionalCompleteBaseFamilies": [],
            "fileCount": files.count,
            "byteCount": declaredPayloads.values.reduce(0) { $0 + $1.count },
            "files": files,
        ], options: [.sortedKeys])

        var entries = archivePayloads.map { TestZIPEntry(
            path: $0.key,
            decoded: $0.value,
            encoded: $0.value,
            method: 0
        ) }
        entries.append(TestZIPEntry(
            path: "GarrysPADContentManifest.json",
            decoded: manifest,
            encoded: deflateManifest ? rawStoredDeflate(manifest) : manifest,
            method: deflateManifest ? 8 : 0
        ))
        return try writeZIP(entries)
    }

    private func rawStoredDeflate(_ data: Data) -> Data {
        var result = Data()
        var cursor = 0
        while cursor < data.count || data.isEmpty && cursor == 0 {
            let count = min(65_535, data.count - cursor)
            let isFinal = cursor + count == data.count
            result.append(isFinal ? 0x01 : 0x00)
            result.appendManifestLE(UInt16(count))
            result.appendManifestLE(~UInt16(count))
            if count > 0 { result.append(data[cursor..<cursor + count]) }
            cursor += count
            if data.isEmpty { break }
        }
        return result
    }

    private func writeZIP(_ entries: [TestZIPEntry]) throws -> URL {
        struct Central {
            let entry: TestZIPEntry
            let name: Data
            let localOffset: UInt32
        }
        var archive = Data()
        var central: [Central] = []
        for entry in entries.sorted(by: { $0.path < $1.path }) {
            let name = Data(entry.path.utf8)
            let offset = UInt32(archive.count)
            archive.appendManifestLE(UInt32(0x0403_4B50))
            archive.appendManifestLE(UInt16(20)); archive.appendManifestLE(UInt16(0x0800))
            archive.appendManifestLE(entry.method)
            archive.appendManifestLE(UInt16(0)); archive.appendManifestLE(UInt16(0))
            archive.appendManifestLE(entry.decoded.manifestCRC32)
            archive.appendManifestLE(UInt32(entry.encoded.count))
            archive.appendManifestLE(UInt32(entry.decoded.count))
            archive.appendManifestLE(UInt16(name.count)); archive.appendManifestLE(UInt16(0))
            archive.append(name); archive.append(entry.encoded)
            central.append(Central(entry: entry, name: name, localOffset: offset))
        }
        let centralOffset = UInt32(archive.count)
        for item in central {
            archive.appendManifestLE(UInt32(0x0201_4B50))
            archive.appendManifestLE(UInt16(20)); archive.appendManifestLE(UInt16(20))
            archive.appendManifestLE(UInt16(0x0800)); archive.appendManifestLE(item.entry.method)
            archive.appendManifestLE(UInt16(0)); archive.appendManifestLE(UInt16(0))
            archive.appendManifestLE(item.entry.decoded.manifestCRC32)
            archive.appendManifestLE(UInt32(item.entry.encoded.count))
            archive.appendManifestLE(UInt32(item.entry.decoded.count))
            archive.appendManifestLE(UInt16(item.name.count)); archive.appendManifestLE(UInt16(0))
            archive.appendManifestLE(UInt16(0)); archive.appendManifestLE(UInt16(0))
            archive.appendManifestLE(UInt16(0)); archive.appendManifestLE(UInt32(0))
            archive.appendManifestLE(item.localOffset); archive.append(item.name)
        }
        let centralSize = UInt32(archive.count) - centralOffset
        archive.appendManifestLE(UInt32(0x0605_4B50))
        archive.appendManifestLE(UInt16(0)); archive.appendManifestLE(UInt16(0))
        archive.appendManifestLE(UInt16(central.count))
        archive.appendManifestLE(UInt16(central.count))
        archive.appendManifestLE(centralSize); archive.appendManifestLE(centralOffset)
        archive.appendManifestLE(UInt16(0))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "GarrysPAD_Content_Manifest_\(UUID().uuidString).zip"
        )
        try archive.write(to: url, options: .atomic)
        return url
    }
}

private struct TestZIPEntry {
    let path: String
    let decoded: Data
    let encoded: Data
    let method: UInt16
}

private extension Data {
    mutating func appendManifestLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }

    var manifestCRC32: UInt32 {
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
