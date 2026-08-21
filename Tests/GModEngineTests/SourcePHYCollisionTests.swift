import Foundation
import Testing
@testable import GModEngine

@Suite("Bounded Source PHY collision envelope decoding")
struct SourcePHYCollisionTests {
    private let checksum: Int32 = 0x1020_3040

    @Test("fixed SDK framing decodes without claiming CollideWrite geometry")
    func decodesKnownEnvelopeOnly() throws {
        let first = Data([0xA1, 0xB2, 0xC3, 0xD4, 0xE5])
        let second = Data([0x10, 0x20, 0x30])
        let keyValues = Data("solid { \"index\" \"0\" }\n".utf8)
        let data = makePHY(solids: [first, second], keyValues: keyValues)

        let snapshot = try SourcePHYCollisionDecoder.decodeEnvelope(
            data,
            expectedSourceModelChecksum: checksum,
            budget: standardBudget()
        )

        #expect(snapshot.header == SourcePHYHeaderSnapshot(
            headerByteCount: 16,
            identifier: 0,
            solidCount: 2,
            sourceModelChecksum: checksum
        ))
        #expect(snapshot.serializedSolids.map(\.index) == [0, 1])
        #expect(snapshot.serializedSolids.map(\.payloadOffset) == [20, 29])
        #expect(snapshot.serializedSolids.map(\.serializedByteCount) == [5, 3])
        #expect(snapshot.serializedSolids.map(\.serializedPayload) == [first, second])
        #expect(snapshot.keyValues.bytes == keyValues)
        #expect(snapshot.keyValues.nullTerminatedByteCount == keyValues.count + 1)
        #expect(snapshot.geometryAvailability == .unsupportedOpaqueCollideWriteSerialization)
    }

    @Test("header contract rejects truncation, unknown identifier, and checksum mismatch")
    func rejectsUnsupportedHeaders() throws {
        #expect(throws: SourcePHYCollisionDecodeError.truncated(
            field: "phyheader_t",
            requiredEnd: 16,
            actualByteCount: 15
        )) {
            _ = try SourcePHYCollisionDecoder.decodeEnvelope(
                Data(repeating: 0, count: 15),
                expectedSourceModelChecksum: checksum,
                budget: standardBudget()
            )
        }

        let unknownIdentifier = makePHY(solids: [Data([1])], identifier: 7)
        #expect(throws: SourcePHYCollisionDecodeError.unsupportedIdentifier(7)) {
            _ = try SourcePHYCollisionDecoder.decodeEnvelope(
                unknownIdentifier,
                expectedSourceModelChecksum: checksum,
                budget: standardBudget()
            )
        }

        let mismatch = makePHY(solids: [Data([1])], checksum: 99)
        #expect(throws: SourcePHYCollisionDecodeError.checksumMismatch(
            expected: checksum,
            actual: 99
        )) {
            _ = try SourcePHYCollisionDecoder.decodeEnvelope(
                mismatch,
                expectedSourceModelChecksum: checksum,
                budget: standardBudget()
            )
        }
    }

    @Test("solid count is capped before allocation")
    func capsSolidCountBeforeAllocation() throws {
        var data = Data()
        appendInt32(16, to: &data)
        appendInt32(0, to: &data)
        appendInt32(Int32.max, to: &data)
        appendInt32(checksum, to: &data)

        #expect(throws: SourcePHYCollisionDecodeError.solidCountExceedsBudget(
            actual: Int(Int32.max),
            cap: 4
        )) {
            _ = try SourcePHYCollisionDecoder.decodeEnvelope(
                data,
                expectedSourceModelChecksum: checksum,
                budget: standardBudget()
            )
        }
    }

    @Test("solid byte counts are positive, individually bounded, and fully present")
    func validatesEachSolidFrame() throws {
        var zeroLength = makePHY(solids: [Data([1])])
        replaceInt32(at: 16, with: 0, in: &zeroLength)
        #expect(throws: SourcePHYCollisionDecodeError.invalidSolidByteCount(
            solid: 0,
            value: 0
        )) {
            _ = try SourcePHYCollisionDecoder.decodeEnvelope(
                zeroLength,
                expectedSourceModelChecksum: checksum,
                budget: standardBudget()
            )
        }

        var oversized = makePHY(solids: [Data([1])])
        replaceInt32(at: 16, with: 65, in: &oversized)
        #expect(throws: SourcePHYCollisionDecodeError.solidExceedsBudget(
            solid: 0,
            actual: 65,
            cap: 64
        )) {
            _ = try SourcePHYCollisionDecoder.decodeEnvelope(
                oversized,
                expectedSourceModelChecksum: checksum,
                budget: standardBudget()
            )
        }

        var truncated = makePHY(solids: [Data([1])])
        replaceInt32(at: 16, with: 4, in: &truncated)
        #expect(throws: SourcePHYCollisionDecodeError.truncated(
            field: "solid[0].CollideWrite payload",
            requiredEnd: 24,
            actualByteCount: truncated.count
        )) {
            _ = try SourcePHYCollisionDecoder.decodeEnvelope(
                truncated,
                expectedSourceModelChecksum: checksum,
                budget: standardBudget()
            )
        }
    }

    @Test("aggregate solid bytes and complete file bytes have independent caps")
    func enforcesAggregateBudgets() throws {
        let data = makePHY(solids: [Data(repeating: 1, count: 40), Data(repeating: 2, count: 40)])
        let aggregateBudget = SourcePHYCollisionDecodeBudget(
            maximumFileBytes: 256,
            maximumSolids: 4,
            maximumBytesPerSolid: 64,
            maximumTotalSolidBytes: 70,
            maximumKeyValuesBytes: 64
        )
        #expect(throws: SourcePHYCollisionDecodeError.totalSolidBytesExceedBudget(
            actual: 80,
            cap: 70
        )) {
            _ = try SourcePHYCollisionDecoder.decodeEnvelope(
                data,
                expectedSourceModelChecksum: checksum,
                budget: aggregateBudget
            )
        }

        let fileBudget = SourcePHYCollisionDecodeBudget(
            maximumFileBytes: data.count - 1,
            maximumSolids: 4,
            maximumBytesPerSolid: 64,
            maximumTotalSolidBytes: 128,
            maximumKeyValuesBytes: 64
        )
        #expect(throws: SourcePHYCollisionDecodeError.fileExceedsBudget(
            actual: data.count,
            cap: data.count - 1
        )) {
            _ = try SourcePHYCollisionDecoder.decodeEnvelope(
                data,
                expectedSourceModelChecksum: checksum,
                budget: fileBudget
            )
        }
    }

    @Test("KeyValues tail must be bounded and have exactly one final NUL")
    func validatesKeyValuesTail() throws {
        var unterminated = makePHY(solids: [Data([1])])
        unterminated.removeLast()
        #expect(throws: SourcePHYCollisionDecodeError.missingKeyValuesTerminator) {
            _ = try SourcePHYCollisionDecoder.decodeEnvelope(
                unterminated,
                expectedSourceModelChecksum: checksum,
                budget: standardBudget()
            )
        }

        var embedded = makePHY(
            solids: [Data([1])],
            keyValues: Data([0x61, 0, 0x62])
        )
        let earlyNULOffset = embedded.count - 3
        #expect(throws: SourcePHYCollisionDecodeError.embeddedKeyValuesTerminator(
            offset: earlyNULOffset
        )) {
            _ = try SourcePHYCollisionDecoder.decodeEnvelope(
                embedded,
                expectedSourceModelChecksum: checksum,
                budget: standardBudget()
            )
        }

        embedded = makePHY(solids: [Data([1])], keyValues: Data(repeating: 0x61, count: 64))
        #expect(throws: SourcePHYCollisionDecodeError.keyValuesExceedBudget(
            actual: 65,
            cap: 64
        )) {
            _ = try SourcePHYCollisionDecoder.decodeEnvelope(
                embedded,
                expectedSourceModelChecksum: checksum,
                budget: standardBudget()
            )
        }
    }

    @Test("invalid policy is rejected before interpreting file bytes")
    func rejectsInvalidBudget() throws {
        let invalid = SourcePHYCollisionDecodeBudget(
            maximumFileBytes: 256,
            maximumSolids: 0,
            maximumBytesPerSolid: 64,
            maximumTotalSolidBytes: 128,
            maximumKeyValuesBytes: 64
        )
        #expect(throws: SourcePHYCollisionDecodeError.invalidBudget(
            field: "maximumSolids",
            value: 0
        )) {
            _ = try SourcePHYCollisionDecoder.decodeEnvelope(
                Data(),
                expectedSourceModelChecksum: checksum,
                budget: invalid
            )
        }
    }
}

private extension SourcePHYCollisionTests {
    func standardBudget() -> SourcePHYCollisionDecodeBudget {
        SourcePHYCollisionDecodeBudget(
            maximumFileBytes: 256,
            maximumSolids: 4,
            maximumBytesPerSolid: 64,
            maximumTotalSolidBytes: 128,
            maximumKeyValuesBytes: 64
        )
    }

    func makePHY(
        solids: [Data],
        keyValues: Data = Data(),
        identifier: Int32 = 0,
        checksum: Int32? = nil
    ) -> Data {
        var data = Data()
        appendInt32(16, to: &data)
        appendInt32(identifier, to: &data)
        appendInt32(Int32(solids.count), to: &data)
        appendInt32(checksum ?? self.checksum, to: &data)
        for solid in solids {
            appendInt32(Int32(solid.count), to: &data)
            data.append(solid)
        }
        data.append(keyValues)
        data.append(0)
        return data
    }

    func appendInt32(_ value: Int32, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    func replaceInt32(at offset: Int, with value: Int32, in data: inout Data) {
        var bytes = Data()
        appendInt32(value, to: &bytes)
        data.replaceSubrange(offset..<(offset + 4), with: bytes)
    }
}
