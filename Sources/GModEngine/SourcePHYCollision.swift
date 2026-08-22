import Foundation

// Source format references (definitions only; this is an independent parser):
// - Source SDK 2013 at c8f4c6351162fbff83bfa5a428d45d1e6eed3824
//   `src/public/phyfile.h`: phyheader_t.
// - The same revision's `src/utils/vbsp/ivp.cpp`: DumpCollideToPHY writes
//   phyheader_t, then one Int32 byte count plus CollideWrite bytes per solid,
//   followed by a NUL-terminated VPhysics KeyValues buffer.
// - The same revision's `src/public/vphysics_interface.h`: CollideWrite,
//   UnserializeCollide, and VCollideLoad keep the serialized CPhysCollide
//   representation behind the VPhysics interface.
//
// The pinned public SDK does not define the internal CollideWrite layout.
// Consequently this decoder publishes only the format that the fixed source
// fully specifies: the PHY envelope and bounded serialized-solid frames. It
// does not infer convexes, mass, inertia, or prop validity from opaque bytes.

public struct SourcePHYCollisionDecodeBudget: Sendable, Equatable {
    public let maximumFileBytes: Int
    public let maximumSolids: Int
    public let maximumBytesPerSolid: Int
    public let maximumTotalSolidBytes: Int
    /// Includes the required trailing NUL byte.
    public let maximumKeyValuesBytes: Int

    public init(
        maximumFileBytes: Int,
        maximumSolids: Int,
        maximumBytesPerSolid: Int,
        maximumTotalSolidBytes: Int,
        maximumKeyValuesBytes: Int
    ) {
        self.maximumFileBytes = maximumFileBytes
        self.maximumSolids = maximumSolids
        self.maximumBytesPerSolid = maximumBytesPerSolid
        self.maximumTotalSolidBytes = maximumTotalSolidBytes
        self.maximumKeyValuesBytes = maximumKeyValuesBytes
    }
}

public struct SourcePHYHeaderSnapshot: Sendable, Equatable {
    public let headerByteCount: Int
    public let identifier: Int32
    public let solidCount: Int
    public let sourceModelChecksum: Int32
}

/// A size-delimited block produced by IPhysicsCollision::CollideWrite.
///
/// `serializedPayload` is deliberately not named or exposed as convex
/// geometry. The pinned public interface supplies no stable record layout for
/// interpreting these bytes without a real VPhysics-compatible decoder.
public struct SourcePHYSerializedSolidSnapshot: Sendable, Equatable {
    public let index: Int
    public let payloadOffset: Int
    public let serializedByteCount: Int
    public let serializedPayload: Data
}

public struct SourcePHYKeyValuesBytesSnapshot: Sendable, Equatable {
    /// Raw bytes before the required final NUL. No lossy string decoding is
    /// performed because the fixed SDK contract is a `char *`, not UTF-8.
    public let bytes: Data
    public let nullTerminatedByteCount: Int
}

public enum SourcePHYGeometryDecodeAvailability: Sendable, Equatable {
    /// The outer PHY framing is known, but the serialized CPhysCollide layout
    /// is not part of the pinned public SDK contract. Callers must not treat
    /// this envelope as decoded collision geometry or `util.IsValidProp` proof.
    case unsupportedOpaqueCollideWriteSerialization
}

/// Immutable, bounded decoding of the publicly specified PHY container.
/// Collision geometry remains explicitly unavailable.
public struct SourcePHYCollisionEnvelopeSnapshot: Sendable, Equatable {
    public let header: SourcePHYHeaderSnapshot
    public let serializedSolids: [SourcePHYSerializedSolidSnapshot]
    public let keyValues: SourcePHYKeyValuesBytesSnapshot
    public let geometryAvailability: SourcePHYGeometryDecodeAvailability
}

public enum SourcePHYCollisionDecodeError: Error, Sendable, Equatable,
    CustomStringConvertible
{
    case invalidBudget(field: String, value: Int)
    case fileExceedsBudget(actual: Int, cap: Int)
    case truncated(field: String, requiredEnd: Int, actualByteCount: Int)
    case invalidHeaderByteCount(expected: Int32, actual: Int32)
    case unsupportedIdentifier(Int32)
    case checksumMismatch(expected: Int32, actual: Int32)
    case invalidSolidCount(Int32)
    case solidCountExceedsBudget(actual: Int, cap: Int)
    case invalidSolidByteCount(solid: Int, value: Int32)
    case solidExceedsBudget(solid: Int, actual: Int, cap: Int)
    case totalSolidBytesExceedBudget(actual: Int, cap: Int)
    case keyValuesExceedBudget(actual: Int, cap: Int)
    case missingKeyValuesTerminator
    case embeddedKeyValuesTerminator(offset: Int)

    public var description: String {
        switch self {
        case let .invalidBudget(field, value):
            return "invalid PHY decode budget \(field)=\(value)"
        case let .fileExceedsBudget(actual, cap):
            return "PHY file size \(actual) exceeds decode cap \(cap)"
        case let .truncated(field, requiredEnd, actualByteCount):
            return "truncated \(field): needs byte \(requiredEnd), has \(actualByteCount)"
        case let .invalidHeaderByteCount(expected, actual):
            return "PHY header size \(actual) does not match phyheader_t size \(expected)"
        case let .unsupportedIdentifier(identifier):
            return "unsupported PHY identifier \(identifier)"
        case let .checksumMismatch(expected, actual):
            return "PHY checksum \(actual) does not match source model checksum \(expected)"
        case let .invalidSolidCount(value):
            return "invalid PHY solid count \(value)"
        case let .solidCountExceedsBudget(actual, cap):
            return "PHY solid count \(actual) exceeds decode cap \(cap)"
        case let .invalidSolidByteCount(solid, value):
            return "PHY solid \(solid) has invalid serialized byte count \(value)"
        case let .solidExceedsBudget(solid, actual, cap):
            return "PHY solid \(solid) size \(actual) exceeds decode cap \(cap)"
        case let .totalSolidBytesExceedBudget(actual, cap):
            return "PHY serialized solid bytes \(actual) exceed decode cap \(cap)"
        case let .keyValuesExceedBudget(actual, cap):
            return "PHY KeyValues bytes \(actual) exceed decode cap \(cap)"
        case .missingKeyValuesTerminator:
            return "PHY VPhysics KeyValues buffer is not NUL-terminated"
        case let .embeddedKeyValuesTerminator(offset):
            return "PHY VPhysics KeyValues buffer contains an early NUL at byte \(offset)"
        }
    }
}

public enum SourcePHYCollisionDecoder {
    private static let headerByteCount = 16
    private static let supportedIdentifier: Int32 = 0

    /// Decodes only the PHY framing fixed by the pinned Source SDK.
    ///
    /// The returned serialized solids still require a separately evidenced
    /// VPhysics-compatible geometry decoder. This method never claims that a
    /// framed payload is usable prop collision.
    public static func decodeEnvelope(
        _ data: Data,
        expectedSourceModelChecksum: Int32,
        budget: SourcePHYCollisionDecodeBudget
    ) throws -> SourcePHYCollisionEnvelopeSnapshot {
        try validate(budget: budget)
        guard data.count <= budget.maximumFileBytes else {
            throw SourcePHYCollisionDecodeError.fileExceedsBudget(
                actual: data.count,
                cap: budget.maximumFileBytes
            )
        }

        let reader = SourcePHYByteReader(data: data)
        try reader.require(
            start: 0,
            byteCount: headerByteCount,
            field: "phyheader_t"
        )
        let declaredHeaderBytes = try reader.int32(
            at: 0,
            field: "phyheader_t.size"
        )
        guard declaredHeaderBytes == Int32(headerByteCount) else {
            throw SourcePHYCollisionDecodeError.invalidHeaderByteCount(
                expected: Int32(headerByteCount),
                actual: declaredHeaderBytes
            )
        }
        let identifier = try reader.int32(at: 4, field: "phyheader_t.id")
        guard identifier == supportedIdentifier else {
            throw SourcePHYCollisionDecodeError.unsupportedIdentifier(identifier)
        }
        let declaredSolidCount = try reader.int32(
            at: 8,
            field: "phyheader_t.solidCount"
        )
        guard declaredSolidCount > 0 else {
            throw SourcePHYCollisionDecodeError.invalidSolidCount(declaredSolidCount)
        }
        let solidCount = Int(declaredSolidCount)
        guard solidCount <= budget.maximumSolids else {
            throw SourcePHYCollisionDecodeError.solidCountExceedsBudget(
                actual: solidCount,
                cap: budget.maximumSolids
            )
        }
        let checksum = try reader.int32(at: 12, field: "phyheader_t.checkSum")
        guard checksum == expectedSourceModelChecksum else {
            throw SourcePHYCollisionDecodeError.checksumMismatch(
                expected: expectedSourceModelChecksum,
                actual: checksum
            )
        }

        var cursor = headerByteCount
        var totalSolidBytes = 0
        var solids: [SourcePHYSerializedSolidSnapshot] = []
        solids.reserveCapacity(solidCount)
        for index in 0..<solidCount {
            let declaredByteCount = try reader.int32(
                at: cursor,
                field: "solid[\(index)].byteCount"
            )
            cursor = try reader.checkedEnd(
                start: cursor,
                byteCount: MemoryLayout<Int32>.size,
                field: "solid[\(index)].byteCount"
            )
            guard declaredByteCount > 0 else {
                throw SourcePHYCollisionDecodeError.invalidSolidByteCount(
                    solid: index,
                    value: declaredByteCount
                )
            }
            let byteCount = Int(declaredByteCount)
            guard byteCount <= budget.maximumBytesPerSolid else {
                throw SourcePHYCollisionDecodeError.solidExceedsBudget(
                    solid: index,
                    actual: byteCount,
                    cap: budget.maximumBytesPerSolid
                )
            }
            let (nextTotal, totalOverflow) = totalSolidBytes.addingReportingOverflow(byteCount)
            guard !totalOverflow, nextTotal <= budget.maximumTotalSolidBytes else {
                throw SourcePHYCollisionDecodeError.totalSolidBytesExceedBudget(
                    actual: totalOverflow ? Int.max : nextTotal,
                    cap: budget.maximumTotalSolidBytes
                )
            }
            let payloadEnd = try reader.checkedEnd(
                start: cursor,
                byteCount: byteCount,
                field: "solid[\(index)].CollideWrite payload"
            )
            try reader.require(
                start: cursor,
                byteCount: byteCount,
                field: "solid[\(index)].CollideWrite payload"
            )
            solids.append(SourcePHYSerializedSolidSnapshot(
                index: index,
                payloadOffset: cursor,
                serializedByteCount: byteCount,
                serializedPayload: Data(data[cursor..<payloadEnd])
            ))
            cursor = payloadEnd
            totalSolidBytes = nextTotal
        }

        let keyValuesByteCount = data.count - cursor
        guard keyValuesByteCount <= budget.maximumKeyValuesBytes else {
            throw SourcePHYCollisionDecodeError.keyValuesExceedBudget(
                actual: keyValuesByteCount,
                cap: budget.maximumKeyValuesBytes
            )
        }
        guard keyValuesByteCount > 0, data[data.count - 1] == 0 else {
            throw SourcePHYCollisionDecodeError.missingKeyValuesTerminator
        }
        if keyValuesByteCount > 1 {
            for offset in cursor..<(data.count - 1) where data[offset] == 0 {
                throw SourcePHYCollisionDecodeError.embeddedKeyValuesTerminator(offset: offset)
            }
        }

        return SourcePHYCollisionEnvelopeSnapshot(
            header: SourcePHYHeaderSnapshot(
                headerByteCount: Int(declaredHeaderBytes),
                identifier: identifier,
                solidCount: solidCount,
                sourceModelChecksum: checksum
            ),
            serializedSolids: solids,
            keyValues: SourcePHYKeyValuesBytesSnapshot(
                bytes: Data(data[cursor..<(data.count - 1)]),
                nullTerminatedByteCount: keyValuesByteCount
            ),
            geometryAvailability: .unsupportedOpaqueCollideWriteSerialization
        )
    }

    private static func validate(budget: SourcePHYCollisionDecodeBudget) throws {
        let fields = [
            ("maximumFileBytes", budget.maximumFileBytes),
            ("maximumSolids", budget.maximumSolids),
            ("maximumBytesPerSolid", budget.maximumBytesPerSolid),
            ("maximumTotalSolidBytes", budget.maximumTotalSolidBytes),
            ("maximumKeyValuesBytes", budget.maximumKeyValuesBytes)
        ]
        if let invalid = fields.first(where: { $0.1 <= 0 }) {
            throw SourcePHYCollisionDecodeError.invalidBudget(
                field: invalid.0,
                value: invalid.1
            )
        }
    }
}

private struct SourcePHYByteReader {
    let data: Data

    func int32(at offset: Int, field: String) throws -> Int32 {
        Int32(bitPattern: try uint32(at: offset, field: field))
    }

    func uint32(at offset: Int, field: String) throws -> UInt32 {
        try require(start: offset, byteCount: MemoryLayout<UInt32>.size, field: field)
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            UInt32(raw[offset])
                | (UInt32(raw[offset + 1]) << 8)
                | (UInt32(raw[offset + 2]) << 16)
                | (UInt32(raw[offset + 3]) << 24)
        }
    }

    func checkedEnd(start: Int, byteCount: Int, field: String) throws -> Int {
        let (end, overflow) = start.addingReportingOverflow(byteCount)
        guard start >= 0, byteCount >= 0, !overflow else {
            throw SourcePHYCollisionDecodeError.truncated(
                field: field,
                requiredEnd: Int.max,
                actualByteCount: data.count
            )
        }
        return end
    }

    func require(start: Int, byteCount: Int, field: String) throws {
        let end = try checkedEnd(start: start, byteCount: byteCount, field: field)
        guard end <= data.count else {
            throw SourcePHYCollisionDecodeError.truncated(
                field: field,
                requiredEnd: end,
                actualByteCount: data.count
            )
        }
    }
}
