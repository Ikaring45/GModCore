import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Incremental SHA-256 used while a multi-gigabyte content pack is verified.
/// The implementation keeps at most one 64-byte partial block in memory and
/// is shared by the Windows conformance host and Apple/Swift Playgrounds.
public struct GModContentSHA256: @unchecked Sendable {
    private static let initialState: [UInt32] = [
        0x6A09_E667, 0xBB67_AE85, 0x3C6E_F372, 0xA54F_F53A,
        0x510E_527F, 0x9B05_688C, 0x1F83_D9AB, 0x5BE0_CD19,
    ]

    private static let roundConstants: [UInt32] = [
        0x428A_2F98, 0x7137_4491, 0xB5C0_FBCF, 0xE9B5_DBA5,
        0x3956_C25B, 0x59F1_11F1, 0x923F_82A4, 0xAB1C_5ED5,
        0xD807_AA98, 0x1283_5B01, 0x2431_85BE, 0x550C_7DC3,
        0x72BE_5D74, 0x80DE_B1FE, 0x9BDC_06A7, 0xC19B_F174,
        0xE49B_69C1, 0xEFBE_4786, 0x0FC1_9DC6, 0x240C_A1CC,
        0x2DE9_2C6F, 0x4A74_84AA, 0x5CB0_A9DC, 0x76F9_88DA,
        0x983E_5152, 0xA831_C66D, 0xB003_27C8, 0xBF59_7FC7,
        0xC6E0_0BF3, 0xD5A7_9147, 0x06CA_6351, 0x1429_2967,
        0x27B7_0A85, 0x2E1B_2138, 0x4D2C_6DFC, 0x5338_0D13,
        0x650A_7354, 0x766A_0ABB, 0x81C2_C92E, 0x9272_2C85,
        0xA2BF_E8A1, 0xA81A_664B, 0xC24B_8B70, 0xC76C_51A3,
        0xD192_E819, 0xD699_0624, 0xF40E_3585, 0x106A_A070,
        0x19A4_C116, 0x1E37_6C08, 0x2748_774C, 0x34B0_BCB5,
        0x391C_0CB3, 0x4ED8_AA4A, 0x5B9C_CA4F, 0x682E_6FF3,
        0x748F_82EE, 0x78A5_636F, 0x84C8_7814, 0x8CC7_0208,
        0x90BE_FFFA, 0xA450_6CEB, 0xBEF9_A3F7, 0xC671_78F2,
    ]

    #if canImport(CryptoKit)
    private var appleHasher = CryptoKit.SHA256()
    #else
    private var state = initialState
    private var pending: [UInt8] = []
    private var byteCount: UInt64 = 0
    #endif

    public init() {
        #if !canImport(CryptoKit)
        pending.reserveCapacity(64)
        #endif
    }

    public mutating func update(_ data: Data) {
        #if canImport(CryptoKit)
        appleHasher.update(data: data)
        #else
        for byte in data {
            append(byte)
        }
        #endif
    }

    public mutating func update<S: Sequence>(_ bytes: S) where S.Element == UInt8 {
        #if canImport(CryptoKit)
        appleHasher.update(data: Data(bytes))
        #else
        for byte in bytes {
            append(byte)
        }
        #endif
    }

    /// Returns the digest without consuming this incremental hasher.
    public func hexadecimalDigest() -> String {
        #if canImport(CryptoKit)
        var copy = appleHasher
        return copy.finalize().map { String(format: "%02x", $0) }.joined()
        #else
        var copy = self
        let bitCount = copy.byteCount &* 8
        copy.pending.append(0x80)
        while copy.pending.count % 64 != 56 {
            copy.pending.append(0)
        }
        for shift in stride(from: 56, through: 0, by: -8) {
            copy.pending.append(UInt8(truncatingIfNeeded: bitCount >> UInt64(shift)))
        }
        var cursor = 0
        while cursor < copy.pending.count {
            copy.compress(Array(copy.pending[cursor..<cursor + 64]))
            cursor += 64
        }
        return copy.state.map { String(format: "%08x", $0) }.joined()
        #endif
    }

    #if !canImport(CryptoKit)
    private mutating func compress(_ block: [UInt8]) {
        precondition(block.count == 64)
        var words = Array(repeating: UInt32(0), count: 64)
        for index in 0..<16 {
            let offset = index * 4
            words[index] = UInt32(block[offset]) << 24 |
                UInt32(block[offset + 1]) << 16 |
                UInt32(block[offset + 2]) << 8 |
                UInt32(block[offset + 3])
        }
        for index in 16..<64 {
            let x = words[index - 15]
            let y = words[index - 2]
            let sigma0 = rotateRight(x, by: 7) ^ rotateRight(x, by: 18) ^ (x >> 3)
            let sigma1 = rotateRight(y, by: 17) ^ rotateRight(y, by: 19) ^ (y >> 10)
            words[index] = words[index - 16] &+ sigma0 &+
                words[index - 7] &+ sigma1
        }

        var a = state[0]
        var b = state[1]
        var c = state[2]
        var d = state[3]
        var e = state[4]
        var f = state[5]
        var g = state[6]
        var h = state[7]
        for index in 0..<64 {
            let sum1 = rotateRight(e, by: 6) ^ rotateRight(e, by: 11) ^
                rotateRight(e, by: 25)
            let choice = (e & f) ^ (~e & g)
            let temporary1 = h &+ sum1 &+ choice &+
                Self.roundConstants[index] &+ words[index]
            let sum0 = rotateRight(a, by: 2) ^ rotateRight(a, by: 13) ^
                rotateRight(a, by: 22)
            let majority = (a & b) ^ (a & c) ^ (b & c)
            let temporary2 = sum0 &+ majority
            h = g
            g = f
            f = e
            e = d &+ temporary1
            d = c
            c = b
            b = a
            a = temporary1 &+ temporary2
        }
        state[0] &+= a
        state[1] &+= b
        state[2] &+= c
        state[3] &+= d
        state[4] &+= e
        state[5] &+= f
        state[6] &+= g
        state[7] &+= h
    }

    private mutating func append(_ byte: UInt8) {
        byteCount &+= 1
        pending.append(byte)
        if pending.count == 64 {
            compress(pending)
            pending.removeAll(keepingCapacity: true)
        }
    }

    private func rotateRight(_ value: UInt32, by count: UInt32) -> UInt32 {
        (value >> count) | (value << (32 - count))
    }
    #endif
}

enum GModRawDeflateError: Error, Equatable, CustomStringConvertible {
    case compressedInputTooLarge(UInt64)
    case decodedOutputTooLarge(UInt64)
    case truncated
    case invalidBlockType
    case invalidStoredBlock
    case invalidHuffmanTree
    case invalidSymbol(Int)
    case invalidDistance(Int)
    case missingEndOfBlock
    case trailingData
    case sizeMismatch(expected: UInt64, actual: UInt64)

    var description: String {
        switch self {
        case let .compressedInputTooLarge(count):
            return "compressed DEFLATE input exceeds its bound (\(count) bytes)"
        case let .decodedOutputTooLarge(count):
            return "decoded DEFLATE output exceeds its bound (\(count) bytes)"
        case .truncated: return "truncated DEFLATE stream"
        case .invalidBlockType: return "reserved DEFLATE block type"
        case .invalidStoredBlock: return "invalid stored DEFLATE block"
        case .invalidHuffmanTree: return "invalid DEFLATE Huffman tree"
        case let .invalidSymbol(symbol): return "invalid DEFLATE symbol \(symbol)"
        case let .invalidDistance(distance): return "invalid DEFLATE distance \(distance)"
        case .missingEndOfBlock: return "DEFLATE block has no end marker"
        case .trailingData: return "DEFLATE stream has trailing bytes"
        case let .sizeMismatch(expected, actual):
            return "DEFLATE size mismatch (expected \(expected), got \(actual))"
        }
    }
}

/// A deliberately bounded raw-RFC1951 decoder for the root JSON manifest.
/// Payload entries remain stored/range-readable; this decoder is never used to
/// expand an arbitrary multi-gigabyte entry in memory.
enum GModRawDeflate {
    static func decode(
        _ compressed: Data,
        expectedByteCount: UInt64,
        maximumCompressedByteCount: UInt64,
        maximumDecodedByteCount: UInt64
    ) throws -> Data {
        guard UInt64(compressed.count) <= maximumCompressedByteCount else {
            throw GModRawDeflateError.compressedInputTooLarge(UInt64(compressed.count))
        }
        guard expectedByteCount <= maximumDecodedByteCount,
              expectedByteCount <= UInt64(Int.max) else {
            throw GModRawDeflateError.decodedOutputTooLarge(expectedByteCount)
        }
        let outputLimit = min(expectedByteCount, maximumDecodedByteCount)
        var reader = BitReader(bytes: Array(compressed))
        var output: [UInt8] = []
        output.reserveCapacity(Int(expectedByteCount))
        var isFinal = false
        while !isFinal {
            isFinal = try reader.readBits(1) == 1
            switch try reader.readBits(2) {
            case 0:
                try decodeStored(reader: &reader, output: &output,
                                 maximum: outputLimit)
            case 1:
                try decodeHuffman(
                    reader: &reader,
                    literalLengths: fixedLiteralLengths,
                    distanceLengths: Array(repeating: 5, count: 32),
                    output: &output,
                    maximum: outputLimit
                )
            case 2:
                let trees = try dynamicTrees(reader: &reader)
                try decodeHuffman(
                    reader: &reader,
                    literalLengths: trees.literal,
                    distanceLengths: trees.distance,
                    output: &output,
                    maximum: outputLimit
                )
            default:
                throw GModRawDeflateError.invalidBlockType
            }
        }
        guard reader.consumedByteCount == compressed.count else {
            throw GModRawDeflateError.trailingData
        }
        guard UInt64(output.count) == expectedByteCount else {
            throw GModRawDeflateError.sizeMismatch(
                expected: expectedByteCount,
                actual: UInt64(output.count)
            )
        }
        return Data(output)
    }

    private static let fixedLiteralLengths: [UInt8] = {
        var result = Array(repeating: UInt8(0), count: 288)
        for index in 0...143 { result[index] = 8 }
        for index in 144...255 { result[index] = 9 }
        for index in 256...279 { result[index] = 7 }
        for index in 280...287 { result[index] = 8 }
        return result
    }()

    private static let codeLengthOrder = [
        16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15,
    ]
    private static let lengthBases = [
        3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
        35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258,
    ]
    private static let lengthExtraBits = [
        0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
        3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0,
    ]
    private static let distanceBases = [
        1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129,
        193, 257, 385, 513, 769, 1_025, 1_537, 2_049, 3_073,
        4_097, 6_145, 8_193, 12_289, 16_385, 24_577,
    ]
    private static let distanceExtraBits = [
        0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6,
        6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13,
    ]

    private static func decodeStored(
        reader: inout BitReader,
        output: inout [UInt8],
        maximum: UInt64
    ) throws {
        reader.alignToByte()
        let count = Int(try reader.readBits(16))
        let complement = Int(try reader.readBits(16))
        guard (count ^ 0xFFFF) == complement else {
            throw GModRawDeflateError.invalidStoredBlock
        }
        try appendBounded(count: count, current: output.count, maximum: maximum)
        for _ in 0..<count { output.append(UInt8(try reader.readBits(8))) }
    }

    private static func dynamicTrees(reader: inout BitReader) throws
        -> (literal: [UInt8], distance: [UInt8])
    {
        let literalCount = Int(try reader.readBits(5)) + 257
        let distanceCount = Int(try reader.readBits(5)) + 1
        let codeLengthCount = Int(try reader.readBits(4)) + 4
        guard literalCount <= 286, distanceCount <= 32 else {
            throw GModRawDeflateError.invalidHuffmanTree
        }
        var codeLengthLengths = Array(repeating: UInt8(0), count: 19)
        for index in 0..<codeLengthCount {
            codeLengthLengths[codeLengthOrder[index]] = UInt8(try reader.readBits(3))
        }
        let codeLengthTree = try Huffman(lengths: codeLengthLengths, kind: .codeLength)
        let total = literalCount + distanceCount
        var lengths: [UInt8] = []
        lengths.reserveCapacity(total)
        while lengths.count < total {
            let symbol = try codeLengthTree.decode(reader: &reader)
            switch symbol {
            case 0...15:
                lengths.append(UInt8(symbol))
            case 16:
                guard let previous = lengths.last else {
                    throw GModRawDeflateError.invalidHuffmanTree
                }
                let count = Int(try reader.readBits(2)) + 3
                guard lengths.count + count <= total else {
                    throw GModRawDeflateError.invalidHuffmanTree
                }
                lengths.append(contentsOf: repeatElement(previous, count: count))
            case 17:
                let count = Int(try reader.readBits(3)) + 3
                guard lengths.count + count <= total else {
                    throw GModRawDeflateError.invalidHuffmanTree
                }
                lengths.append(contentsOf: repeatElement(UInt8(0), count: count))
            case 18:
                let count = Int(try reader.readBits(7)) + 11
                guard lengths.count + count <= total else {
                    throw GModRawDeflateError.invalidHuffmanTree
                }
                lengths.append(contentsOf: repeatElement(UInt8(0), count: count))
            default:
                throw GModRawDeflateError.invalidSymbol(symbol)
            }
        }
        let literal = Array(lengths[..<literalCount])
        let distance = Array(lengths[literalCount...])
        guard literal.count > 256, literal[256] != 0 else {
            throw GModRawDeflateError.missingEndOfBlock
        }
        _ = try Huffman(lengths: literal, kind: .literalLength)
        if distance.contains(where: { $0 != 0 }) {
            _ = try Huffman(lengths: distance, kind: .distance)
        }
        return (literal, distance)
    }

    private static func decodeHuffman(
        reader: inout BitReader,
        literalLengths: [UInt8],
        distanceLengths: [UInt8],
        output: inout [UInt8],
        maximum: UInt64
    ) throws {
        let literalTree = try Huffman(lengths: literalLengths, kind: .literalLength)
        let distanceTree = distanceLengths.contains(where: { $0 != 0 })
            ? try Huffman(lengths: distanceLengths, kind: .distance)
            : nil
        while true {
            let symbol = try literalTree.decode(reader: &reader)
            switch symbol {
            case 0...255:
                try appendBounded(count: 1, current: output.count, maximum: maximum)
                output.append(UInt8(symbol))
            case 256:
                return
            case 257...285:
                let index = symbol - 257
                let length = lengthBases[index] +
                    Int(try reader.readBits(lengthExtraBits[index]))
                guard let distanceTree else {
                    throw GModRawDeflateError.invalidHuffmanTree
                }
                let distanceSymbol = try distanceTree.decode(reader: &reader)
                guard distanceSymbol >= 0, distanceSymbol < distanceBases.count else {
                    throw GModRawDeflateError.invalidSymbol(distanceSymbol)
                }
                let distance = distanceBases[distanceSymbol] +
                    Int(try reader.readBits(distanceExtraBits[distanceSymbol]))
                guard distance > 0, distance <= output.count else {
                    throw GModRawDeflateError.invalidDistance(distance)
                }
                try appendBounded(count: length, current: output.count, maximum: maximum)
                for _ in 0..<length {
                    output.append(output[output.count - distance])
                }
            default:
                throw GModRawDeflateError.invalidSymbol(symbol)
            }
        }
    }

    private static func appendBounded(count: Int, current: Int, maximum: UInt64) throws {
        guard count >= 0 else { throw GModRawDeflateError.decodedOutputTooLarge(.max) }
        let (next, overflow) = UInt64(current).addingReportingOverflow(UInt64(count))
        guard !overflow, next <= maximum, next <= UInt64(Int.max) else {
            throw GModRawDeflateError.decodedOutputTooLarge(next)
        }
    }

    private struct BitReader {
        let bytes: [UInt8]
        var bitOffset = 0

        var consumedByteCount: Int { (bitOffset + 7) / 8 }

        mutating func readBits(_ count: Int) throws -> UInt32 {
            guard count >= 0, count <= 24,
                  bitOffset <= bytes.count * 8 - count else {
                throw GModRawDeflateError.truncated
            }
            var result: UInt32 = 0
            for index in 0..<count {
                let absolute = bitOffset + index
                let bit = (bytes[absolute / 8] >> UInt8(absolute % 8)) & 1
                result |= UInt32(bit) << UInt32(index)
            }
            bitOffset += count
            return result
        }

        mutating func alignToByte() {
            bitOffset = (bitOffset + 7) & ~7
        }
    }

    private struct Huffman {
        enum Kind { case codeLength, literalLength, distance }
        let symbolsByLengthAndCode: [[Int: Int]]
        let maximumLength: Int

        init(lengths: [UInt8], kind: Kind) throws {
            var counts = Array(repeating: 0, count: 16)
            for length in lengths {
                guard length <= 15 else { throw GModRawDeflateError.invalidHuffmanTree }
                if length > 0 { counts[Int(length)] += 1 }
            }
            let used = counts.dropFirst().reduce(0, +)
            guard used > 0 else { throw GModRawDeflateError.invalidHuffmanTree }
            var left = 1
            var maximumLength = 0
            for bits in 1...15 {
                left = (left << 1) - counts[bits]
                guard left >= 0 else { throw GModRawDeflateError.invalidHuffmanTree }
                if counts[bits] > 0 { maximumLength = bits }
            }
            if left > 0 {
                // RFC1951 permits the single-symbol literal/distance alphabet;
                // code-length alphabets and all other incomplete trees are bad.
                guard kind != .codeLength, used == 1, maximumLength == 1 else {
                    throw GModRawDeflateError.invalidHuffmanTree
                }
            }

            var nextCode = Array(repeating: 0, count: 16)
            var code = 0
            for bits in 1...15 {
                code = (code + counts[bits - 1]) << 1
                nextCode[bits] = code
            }
            var tables = Array(repeating: [Int: Int](), count: 16)
            for (symbol, rawLength) in lengths.enumerated() where rawLength > 0 {
                let length = Int(rawLength)
                let canonical = nextCode[length]
                nextCode[length] += 1
                let transmitted = Self.reverseBits(canonical, count: length)
                guard tables[length][transmitted] == nil else {
                    throw GModRawDeflateError.invalidHuffmanTree
                }
                tables[length][transmitted] = symbol
            }
            symbolsByLengthAndCode = tables
            self.maximumLength = maximumLength
        }

        func decode(reader: inout BitReader) throws -> Int {
            var code = 0
            for length in 1...maximumLength {
                code |= Int(try reader.readBits(1)) << (length - 1)
                if let symbol = symbolsByLengthAndCode[length][code] {
                    return symbol
                }
            }
            throw GModRawDeflateError.invalidHuffmanTree
        }

        private static func reverseBits(_ value: Int, count: Int) -> Int {
            var source = value
            var result = 0
            for _ in 0..<count {
                result = (result << 1) | (source & 1)
                source >>= 1
            }
            return result
        }
    }
}
