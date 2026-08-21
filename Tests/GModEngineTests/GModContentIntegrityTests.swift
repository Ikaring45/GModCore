import Foundation
import XCTest
@testable import GModGameAssets

final class GModContentIntegrityTests: XCTestCase {
    func testSHA256KnownVectorsAndIncrementalChunks() {
        let empty = GModContentSHA256()
        XCTAssertEqual(
            empty.hexadecimalDigest(),
            "e3b0c44298fc1c149afbf4c8996fb924" +
                "27ae41e4649b934ca495991b7852b855"
        )

        var abc = GModContentSHA256()
        abc.update(Data("a".utf8))
        abc.update(Data("b".utf8))
        abc.update(Data("c".utf8))
        XCTAssertEqual(
            abc.hexadecimalDigest(),
            "ba7816bf8f01cfea414140de5dae2223" +
                "b00361a396177a9cb410ff61f20015ad"
        )
        XCTAssertEqual(
            abc.hexadecimalDigest(),
            "ba7816bf8f01cfea414140de5dae2223" +
                "b00361a396177a9cb410ff61f20015ad",
            "reading the digest must not consume incremental state"
        )
    }

    func testRawDeflateStoredFixedAndDynamicKnownVectors() throws {
        XCTAssertEqual(
            try decode(hex: "010300fcff616263", expected: 3),
            Data("abc".utf8)
        )
        XCTAssertEqual(
            try decode(hex: "cb48cdc9c90700", expected: 5),
            Data("hello".utf8)
        )

        let phrase = "dynamic huffman manifest vector. "
        let expected = Data(String(repeating: phrase, count: 300).utf8)
        let compressed =
            "eddabb0d80300c05c05532013b45f988140e120424b66708daeb5d59f6f315a" +
            "eefcc314adaefde23cf14798edeae959e56d6716ea92ad007f3602fe4839c740" +
            "e9c453cc0245ca4622aa6622aa6622aa6622aa6622aa6622aa6622aa6622aa6" +
            "622aa6622aa6622aa6622aa6622aa6e2f8f569f601"
        XCTAssertEqual(
            try decode(hex: compressed, expected: UInt64(expected.count)),
            expected
        )
    }

    func testRawDeflateRejectsMalformedTreesDistanceTrailingDataAndBombs() throws {
        XCTAssertThrowsError(try GModRawDeflate.decode(
            Data([0x07]),
            expectedByteCount: 0,
            maximumCompressedByteCount: 16,
            maximumDecodedByteCount: 16
        ))
        XCTAssertThrowsError(try GModRawDeflate.decode(
            dynamicHeader(codeLengthLengths: [1, 1, 1, 1]),
            expectedByteCount: 0,
            maximumCompressedByteCount: 16,
            maximumDecodedByteCount: 16
        )) { error in
            XCTAssertEqual(error as? GModRawDeflateError, .invalidHuffmanTree)
        }
        XCTAssertThrowsError(try GModRawDeflate.decode(
            dynamicHeader(codeLengthLengths: [2, 0, 0, 0]),
            expectedByteCount: 0,
            maximumCompressedByteCount: 16,
            maximumDecodedByteCount: 16
        )) { error in
            XCTAssertEqual(error as? GModRawDeflateError, .invalidHuffmanTree)
        }
        XCTAssertThrowsError(try GModRawDeflate.decode(
            Data([0x03, 0x02]),
            expectedByteCount: 3,
            maximumCompressedByteCount: 16,
            maximumDecodedByteCount: 16
        )) { error in
            XCTAssertEqual(error as? GModRawDeflateError, .invalidDistance(1))
        }
        XCTAssertThrowsError(try GModRawDeflate.decode(
            try data(hex: "cb48cdc9c9070000"),
            expectedByteCount: 5,
            maximumCompressedByteCount: 16,
            maximumDecodedByteCount: 16
        )) { error in
            XCTAssertEqual(error as? GModRawDeflateError, .trailingData)
        }

        let dynamicBomb = try data(hex:
            "eddabb0d80300c05c05532013b45f988140e120424b66708daeb5d59f6f315a" +
            "eefcc314adaefde23cf14798edeae959e56d6716ea92ad007f3602fe4839c740" +
            "e9c453cc0245ca4622aa6622aa6622aa6622aa6622aa6622aa6622aa6622aa6" +
            "622aa6622aa6622aa6622aa6622aa6e2f8f569f601"
        )
        XCTAssertThrowsError(try GModRawDeflate.decode(
            dynamicBomb,
            expectedByteCount: 1,
            maximumCompressedByteCount: 1_024,
            maximumDecodedByteCount: 100
        )) { error in
            guard case .decodedOutputTooLarge = error as? GModRawDeflateError else {
                return XCTFail("unexpected bomb rejection: \(error)")
            }
        }
        XCTAssertThrowsError(try GModRawDeflate.decode(
            Data(repeating: 0, count: 17),
            expectedByteCount: 0,
            maximumCompressedByteCount: 16,
            maximumDecodedByteCount: 16
        )) { error in
            XCTAssertEqual(
                error as? GModRawDeflateError,
                .compressedInputTooLarge(17)
            )
        }
    }

    func testLegacyMethodEightRootManifestIsDecodedButOtherEntriesRemainStoredOnly()
        throws
    {
        let manifest = try data(hex:
            "7b22666f726d6174223a22476172727973504144436f6e74656e745061636b22" +
            "2c22736368656d6156657273696f6e223a317d"
        )
        let compressed = try data(hex:
            "ab564acb2fca4d2c51b252724f2c2aaa2c0e707471cecf2b49cd2b09484cce" +
            "56d2512a4ece48cd4d0c4b2d2acecccf53b232ac0500"
        )
        let url = try makeSingleEntryZIP(
            path: "GarrysPADContentManifest.json",
            decoded: manifest,
            encoded: compressed,
            method: 8
        )
        defer { try? FileManager.default.removeItem(at: url) }
        let pack = try GarrysPADContentPack(
            url: url,
            requirePlayableContent: false
        )
        XCTAssertEqual(
            try pack.data(
                for: GarrysPADContentPack.rootManifestPath,
                maximumByteCount: 1_024
            ),
            manifest
        )

        let otherURL = try makeSingleEntryZIP(
            path: "garrysmod/html/menu.html",
            decoded: manifest,
            encoded: compressed,
            method: 8
        )
        defer { try? FileManager.default.removeItem(at: otherURL) }
        let other = try GarrysPADContentPack(
            url: otherURL,
            requirePlayableContent: false
        )
        XCTAssertThrowsError(try other.data(for: "garrysmod/html/menu.html")) {
            XCTAssertEqual(
                $0 as? GarrysPADContentPackError,
                .unsupportedCompression(
                    path: "garrysmod/html/menu.html",
                    method: 8
                )
            )
        }
    }

    func testStoredEntryStreamingHashesChunksChecksCRCAndCancels() throws {
        let payload = Data((0..<100).map(UInt8.init))
        let url = try makeSingleEntryZIP(
            path: "garrysmod/data.bin",
            decoded: payload,
            encoded: payload,
            method: 0
        )
        defer { try? FileManager.default.removeItem(at: url) }
        let pack = try GarrysPADContentPack(
            url: url,
            requirePlayableContent: false
        )
        var hasher = GModContentSHA256()
        var completions: [UInt64] = []
        try pack.streamVerifiedData(
            for: "garrysmod/data.bin",
            chunkByteCount: 17
        ) { chunk, completed in
            XCTAssertLessThanOrEqual(chunk.count, 17)
            hasher.update(chunk)
            completions.append(completed)
        }
        XCTAssertEqual(completions.last, 100)
        XCTAssertEqual(
            hasher.hexadecimalDigest(),
            "bce0aff19cf5aa6a7469a30d61d04e43" +
                "76e4bbf6381052ee9e7f33925c954d52"
        )

        var cancelled = false
        XCTAssertThrowsError(try pack.streamVerifiedData(
            for: "garrysmod/data.bin",
            chunkByteCount: 17,
            shouldCancel: { cancelled }
        ) { _, _ in
            cancelled = true
        }) { error in
            XCTAssertTrue(error is CancellationError)
        }

        var archive = try Data(contentsOf: url)
        let payloadStart = 30 + Data("garrysmod/data.bin".utf8).count
        archive[payloadStart + 50] ^= 0x01
        try archive.write(to: url, options: .atomic)
        XCTAssertThrowsError(try pack.streamVerifiedData(
            for: "garrysmod/data.bin",
            chunkByteCount: 17
        ) { _, _ in }) { error in
            XCTAssertEqual(
                error as? GarrysPADContentPackError,
                .checksumMismatch("garrysmod/data.bin")
            )
        }
    }

    private func decode(hex: String, expected: UInt64) throws -> Data {
        try GModRawDeflate.decode(
            try data(hex: hex),
            expectedByteCount: expected,
            maximumCompressedByteCount: 1_024 * 1_024,
            maximumDecodedByteCount: 1_024 * 1_024
        )
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

    private func dynamicHeader(codeLengthLengths: [UInt32]) -> Data {
        precondition(codeLengthLengths.count == 4)
        var writer = TestBitWriter()
        writer.append(1, count: 1)
        writer.append(2, count: 2)
        writer.append(0, count: 5)
        writer.append(0, count: 5)
        writer.append(0, count: 4)
        for length in codeLengthLengths { writer.append(length, count: 3) }
        return writer.data
    }

    private func makeSingleEntryZIP(
        path: String,
        decoded: Data,
        encoded: Data,
        method: UInt16
    ) throws -> URL {
        let name = Data(path.utf8)
        var archive = Data()
        archive.appendIntegrityLE(UInt32(0x0403_4B50))
        archive.appendIntegrityLE(UInt16(20))
        archive.appendIntegrityLE(UInt16(0x0800))
        archive.appendIntegrityLE(method)
        archive.appendIntegrityLE(UInt16(0)); archive.appendIntegrityLE(UInt16(0))
        archive.appendIntegrityLE(decoded.integrityCRC32)
        archive.appendIntegrityLE(UInt32(encoded.count))
        archive.appendIntegrityLE(UInt32(decoded.count))
        archive.appendIntegrityLE(UInt16(name.count)); archive.appendIntegrityLE(UInt16(0))
        archive.append(name); archive.append(encoded)
        let centralOffset = UInt32(archive.count)
        archive.appendIntegrityLE(UInt32(0x0201_4B50))
        archive.appendIntegrityLE(UInt16(20)); archive.appendIntegrityLE(UInt16(20))
        archive.appendIntegrityLE(UInt16(0x0800)); archive.appendIntegrityLE(method)
        archive.appendIntegrityLE(UInt16(0)); archive.appendIntegrityLE(UInt16(0))
        archive.appendIntegrityLE(decoded.integrityCRC32)
        archive.appendIntegrityLE(UInt32(encoded.count))
        archive.appendIntegrityLE(UInt32(decoded.count))
        archive.appendIntegrityLE(UInt16(name.count)); archive.appendIntegrityLE(UInt16(0))
        archive.appendIntegrityLE(UInt16(0)); archive.appendIntegrityLE(UInt16(0))
        archive.appendIntegrityLE(UInt16(0)); archive.appendIntegrityLE(UInt32(0))
        archive.appendIntegrityLE(UInt32(0)); archive.append(name)
        let centralSize = UInt32(archive.count) - centralOffset
        archive.appendIntegrityLE(UInt32(0x0605_4B50))
        archive.appendIntegrityLE(UInt16(0)); archive.appendIntegrityLE(UInt16(0))
        archive.appendIntegrityLE(UInt16(1)); archive.appendIntegrityLE(UInt16(1))
        archive.appendIntegrityLE(centralSize); archive.appendIntegrityLE(centralOffset)
        archive.appendIntegrityLE(UInt16(0))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "GarrysPAD_Content_Integrity_\(UUID().uuidString).zip"
        )
        try archive.write(to: url, options: .atomic)
        return url
    }
}

private struct TestBitWriter {
    private var bytes: [UInt8] = []
    private var bitCount = 0

    mutating func append(_ value: UInt32, count: Int) {
        for index in 0..<count {
            if bitCount.isMultiple(of: 8) { bytes.append(0) }
            if ((value >> UInt32(index)) & 1) != 0 {
                bytes[bytes.count - 1] |= UInt8(1 << UInt8(bitCount % 8))
            }
            bitCount += 1
        }
    }

    var data: Data { Data(bytes) }
}

private extension Data {
    mutating func appendIntegrityLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }

    var integrityCRC32: UInt32 {
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
