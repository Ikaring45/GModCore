import Foundation

// Source format reference (definitions only; independent parser):
// - Source SDK 2013 at c8f4c6351162fbff83bfa5a428d45d1e6eed3824,
//   `src/public/studio.h`: v48 `studiohdr_t`, `STUDIO_VERSION`, and
//   `pszSurfaceProp()`.
//
// This decoder starts from an already validated immutable render payload. It
// deliberately publishes only fields whose v48 on-disk layout is public; it
// does not derive physics shapes, mass, contents, or fallback bounds.

public struct SourceStudioModelSpatialMetadataDecodeBudget: Sendable, Equatable {
    /// Maximum UTF-8 bytes before the required trailing NUL. Zero permits only
    /// the empty string.
    public let maximumSurfacePropertyBytes: Int

    public init(maximumSurfacePropertyBytes: Int) {
        self.maximumSurfacePropertyBytes = maximumSurfacePropertyBytes
    }
}

public enum SourceStudioModelSpatialMetadataDecodeError: Error, Sendable, Equatable,
    CustomStringConvertible
{
    case invalidBudget(field: String, value: Int)
    case outOfBounds(field: String, start: Int, byteCount: Int, length: Int)
    case nonFiniteFloat(field: String, offset: Int)
    case invalidBounds(field: String, minimum: SourceVector3, maximum: SourceVector3)
    case invalidOffset(field: String, value: Int32)
    case unterminatedString(field: String, start: Int)
    case stringByteCountExceeded(field: String, value: Int, cap: Int)
    case stringIsNotUTF8(field: String, start: Int)

    public var description: String {
        switch self {
        case let .invalidBudget(field, value):
            return "invalid Studio spatial metadata budget \(field)=\(value)"
        case let .outOfBounds(field, start, byteCount, length):
            return "\(field) range \(start)..<\(start + byteCount) exceeds \(length) bytes"
        case let .nonFiniteFloat(field, offset):
            return "\(field) contains a non-finite Float at byte \(offset)"
        case let .invalidBounds(field, minimum, maximum):
            return "\(field) minimum \(minimum) exceeds maximum \(maximum)"
        case let .invalidOffset(field, value):
            return "invalid \(field) offset \(value)"
        case let .unterminatedString(field, start):
            return "\(field) string at \(start) has no NUL terminator"
        case let .stringByteCountExceeded(field, value, cap):
            return "\(field) string is at least \(value) bytes; cap is \(cap)"
        case let .stringIsNotUTF8(field, start):
            return "\(field) string at \(start) is not UTF-8"
        }
    }
}

/// Immutable renderer/runtime-neutral snapshot of public v48 `studiohdr_t`
/// spatial metadata. The values remain in Source coordinates and units.
public struct SourceStudioModelSpatialMetadataSnapshot: Sendable, Equatable {
    public let checksum: Int32
    public let modelName: String
    public let eyePosition: SourceVector3
    public let illuminationPosition: SourceVector3
    public let hullMinimum: SourceVector3
    public let hullMaximum: SourceVector3
    public let viewBoundingBoxMinimum: SourceVector3
    public let viewBoundingBoxMaximum: SourceVector3
    public let flags: Int32
    public let surfaceProperty: String
}

public enum SourceStudioModelSpatialMetadataDecoder {
    public static func decode(
        _ payload: SourceStudioImmutableRenderPayload,
        budget: SourceStudioModelSpatialMetadataDecodeBudget
    ) throws -> SourceStudioModelSpatialMetadataSnapshot {
        guard budget.maximumSurfacePropertyBytes >= 0 else {
            throw SourceStudioModelSpatialMetadataDecodeError.invalidBudget(
                field: "maximumSurfacePropertyBytes",
                value: budget.maximumSurfacePropertyBytes
            )
        }

        let reader = SpatialMetadataReader(payload.mdlData)
        let eyePosition = try reader.vector(
            at: Layout.eyePosition,
            field: "studiohdr_t.eyeposition"
        )
        let illuminationPosition = try reader.vector(
            at: Layout.illuminationPosition,
            field: "studiohdr_t.illumposition"
        )
        let hullMinimum = try reader.vector(
            at: Layout.hullMinimum,
            field: "studiohdr_t.hull_min"
        )
        let hullMaximum = try reader.vector(
            at: Layout.hullMaximum,
            field: "studiohdr_t.hull_max"
        )
        try validateBounds(
            minimum: hullMinimum,
            maximum: hullMaximum,
            field: "studiohdr_t.hull"
        )
        let viewMinimum = try reader.vector(
            at: Layout.viewMinimum,
            field: "studiohdr_t.view_bbmin"
        )
        let viewMaximum = try reader.vector(
            at: Layout.viewMaximum,
            field: "studiohdr_t.view_bbmax"
        )
        try validateBounds(
            minimum: viewMinimum,
            maximum: viewMaximum,
            field: "studiohdr_t.view_bb"
        )
        let flags = try reader.int32(at: Layout.flags, field: "studiohdr_t.flags")
        let surfacePropertyOffset = try reader.int32(
            at: Layout.surfacePropertyIndex,
            field: "studiohdr_t.surfacepropindex"
        )
        let surfaceProperty = try reader.absoluteCString(
            offset: surfacePropertyOffset,
            maximumBytes: budget.maximumSurfacePropertyBytes,
            field: "studiohdr_t.surfaceprop"
        )

        return SourceStudioModelSpatialMetadataSnapshot(
            checksum: payload.model.header.checksum,
            modelName: payload.model.header.name,
            eyePosition: eyePosition,
            illuminationPosition: illuminationPosition,
            hullMinimum: hullMinimum,
            hullMaximum: hullMaximum,
            viewBoundingBoxMinimum: viewMinimum,
            viewBoundingBoxMaximum: viewMaximum,
            flags: flags,
            surfaceProperty: surfaceProperty
        )
    }
}

private extension SourceStudioModelSpatialMetadataDecoder {
    enum Layout {
        // v48 studiohdr_t begins with 3 Int32 values, name[64], and length.
        // The six Vectors are consecutive and `surfacepropindex` is relative
        // to the header base (the start of this MDL payload).
        static let eyePosition = 80
        static let illuminationPosition = 92
        static let hullMinimum = 104
        static let hullMaximum = 116
        static let viewMinimum = 128
        static let viewMaximum = 140
        static let flags = 152
        static let surfacePropertyIndex = 308
    }

    static func validateBounds(
        minimum: SourceVector3,
        maximum: SourceVector3,
        field: String
    ) throws {
        guard minimum.x <= maximum.x,
              minimum.y <= maximum.y,
              minimum.z <= maximum.z else {
            throw SourceStudioModelSpatialMetadataDecodeError.invalidBounds(
                field: field,
                minimum: minimum,
                maximum: maximum
            )
        }
    }
}

private struct SpatialMetadataReader {
    let data: Data
    var length: Int { data.count }

    init(_ data: Data) {
        self.data = data
    }

    func uint32(at offset: Int, field: String) throws -> UInt32 {
        try require(start: offset, byteCount: 4, field: field)
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            UInt32(raw[offset])
                | (UInt32(raw[offset + 1]) << 8)
                | (UInt32(raw[offset + 2]) << 16)
                | (UInt32(raw[offset + 3]) << 24)
        }
    }

    func int32(at offset: Int, field: String) throws -> Int32 {
        Int32(bitPattern: try uint32(at: offset, field: field))
    }

    func float(at offset: Int, field: String) throws -> Float {
        let value = Float(bitPattern: try uint32(at: offset, field: field))
        guard value.isFinite else {
            throw SourceStudioModelSpatialMetadataDecodeError.nonFiniteFloat(
                field: field,
                offset: offset
            )
        }
        return value
    }

    func vector(at offset: Int, field: String) throws -> SourceVector3 {
        SourceVector3(
            try float(at: offset, field: "\(field).x"),
            try float(at: offset + 4, field: "\(field).y"),
            try float(at: offset + 8, field: "\(field).z")
        )
    }

    func absoluteCString(
        offset: Int32,
        maximumBytes: Int,
        field: String
    ) throws -> String {
        guard offset > 0 else {
            throw SourceStudioModelSpatialMetadataDecodeError.invalidOffset(
                field: field,
                value: offset
            )
        }
        let start = Int(offset)
        guard start < length else {
            throw SourceStudioModelSpatialMetadataDecodeError.outOfBounds(
                field: field,
                start: start,
                byteCount: 1,
                length: length
            )
        }

        let available = length - start
        let maximumSearchBytes = maximumBytes == Int.max ? Int.max : maximumBytes + 1
        let searchByteCount = min(available, maximumSearchBytes)
        let searchEnd = start + searchByteCount
        guard let end = data[start..<searchEnd].firstIndex(of: 0) else {
            if available <= maximumBytes {
                throw SourceStudioModelSpatialMetadataDecodeError.unterminatedString(
                    field: field,
                    start: start
                )
            }
            throw SourceStudioModelSpatialMetadataDecodeError.stringByteCountExceeded(
                field: field,
                value: maximumSearchBytes,
                cap: maximumBytes
            )
        }
        guard let value = String(data: data[start..<end], encoding: .utf8) else {
            throw SourceStudioModelSpatialMetadataDecodeError.stringIsNotUTF8(
                field: field,
                start: start
            )
        }
        return value
    }

    private func require(start: Int, byteCount: Int, field: String) throws {
        let (end, overflow) = start.addingReportingOverflow(byteCount)
        guard start >= 0, byteCount >= 0, !overflow, end <= length else {
            throw SourceStudioModelSpatialMetadataDecodeError.outOfBounds(
                field: field,
                start: start,
                byteCount: byteCount,
                length: length
            )
        }
    }
}
