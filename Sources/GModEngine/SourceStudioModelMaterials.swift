import Foundation

// Source format references (definitions and lookup order only; independent parser):
// - Source SDK 2013 at c8f4c6351162fbff83bfa5a428d45d1e6eed3824,
//   `src/public/studio.h`: studiohdr_t material fields, mstudiotexture_t,
//   pCdtexture, pSkinref, and pTexture.
// - The same revision's `src/utils/vrad/vradstaticprops.cpp` constructs
//   candidates in authored CD-texture order as
//   `materials/` + cdtexture + texture name + `.vmt`, then fixes slashes.

public struct SourceStudioModelMaterialDecodeBudget: Sendable, Equatable {
    public let maximumTextures: Int
    public let maximumCDTextureDirectories: Int
    public let maximumSkinReferences: Int
    public let maximumSkinFamilies: Int
    public let maximumSkinEntries: Int
    public let maximumStringBytes: Int
    public let maximumTotalStringBytes: Int
    public let maximumResolvedCandidateBytes: Int

    public init(
        maximumTextures: Int,
        maximumCDTextureDirectories: Int,
        maximumSkinReferences: Int,
        maximumSkinFamilies: Int,
        maximumSkinEntries: Int,
        maximumStringBytes: Int,
        maximumTotalStringBytes: Int,
        maximumResolvedCandidateBytes: Int
    ) {
        self.maximumTextures = maximumTextures
        self.maximumCDTextureDirectories = maximumCDTextureDirectories
        self.maximumSkinReferences = maximumSkinReferences
        self.maximumSkinFamilies = maximumSkinFamilies
        self.maximumSkinEntries = maximumSkinEntries
        self.maximumStringBytes = maximumStringBytes
        self.maximumTotalStringBytes = maximumTotalStringBytes
        self.maximumResolvedCandidateBytes = maximumResolvedCandidateBytes
    }
}

public enum SourceStudioModelMaterialDecodeError: Error, Sendable, Equatable,
    CustomStringConvertible
{
    case invalidBudget(field: String, value: Int)
    case invalidCount(field: String, value: Int32)
    case countProductOverflow(field: String, lhs: Int, rhs: Int)
    case exceedsBudget(field: String, value: Int, cap: Int)
    case invalidOffset(field: String, value: Int32)
    case misalignedOffset(field: String, value: Int32, alignment: Int)
    case offsetOverflow(field: String, base: Int, offset: Int32)
    case outOfBounds(field: String, start: Int, byteCount: Int, length: Int)
    case unterminatedString(field: String, start: Int)
    case stringByteCountExceeded(field: String, value: Int, cap: Int)
    case stringIsNotUTF8(field: String, start: Int)
    case invalidSkinReference(
        family: Int,
        materialSlot: Int,
        value: Int16,
        textureCount: Int
    )
    case invalidSkinFamily(value: Int, available: Int)
    case invalidMeshMaterialIndex(value: Int32, skinReferenceCount: Int)

    public var description: String {
        switch self {
        case let .invalidBudget(field, value):
            return "invalid Studio material decode budget \(field)=\(value)"
        case let .invalidCount(field, value):
            return "invalid \(field) count \(value)"
        case let .countProductOverflow(field, lhs, rhs):
            return "\(field) count \(lhs) * \(rhs) overflows"
        case let .exceedsBudget(field, value, cap):
            return "\(field) \(value) exceeds decode cap \(cap)"
        case let .invalidOffset(field, value):
            return "invalid \(field) offset \(value)"
        case let .misalignedOffset(field, value, alignment):
            return "\(field) offset \(value) is not \(alignment)-byte aligned"
        case let .offsetOverflow(field, base, offset):
            return "\(field) base \(base) plus relative offset \(offset) overflows"
        case let .outOfBounds(field, start, byteCount, length):
            return "\(field) range \(start)..<\(start + byteCount) exceeds \(length) bytes"
        case let .unterminatedString(field, start):
            return "\(field) string at \(start) has no NUL terminator"
        case let .stringByteCountExceeded(field, value, cap):
            return "\(field) string is \(value) bytes; cap is \(cap)"
        case let .stringIsNotUTF8(field, start):
            return "\(field) string at \(start) is not UTF-8"
        case let .invalidSkinReference(family, materialSlot, value, textureCount):
            return "skin family \(family) material slot \(materialSlot) references texture \(value); texture count is \(textureCount)"
        case let .invalidSkinFamily(value, available):
            return "skin family \(value) is outside 0..<\(available)"
        case let .invalidMeshMaterialIndex(value, skinReferenceCount):
            return "mesh material index \(value) is outside 0..<\(skinReferenceCount)"
        }
    }
}

public struct SourceStudioModelTextureSnapshot: Sendable, Equatable {
    public let index: Int
    public let name: String
    public let flags: Int32
    public let usedCount: Int32
}

public struct SourceStudioModelSkinFamilySnapshot: Sendable, Equatable {
    public let index: Int
    /// Texture-table indices in mesh-material-slot order.
    public let textureIndices: [Int]
}

public struct SourceStudioResolvedModelMaterialSnapshot: Sendable, Equatable {
    public let meshMaterialIndex: Int
    public let skinFamilyIndex: Int
    public let textureIndex: Int
    public let textureName: String
    /// Ordered logical VMT candidates only. No filesystem read is performed.
    public let cdTextureCandidates: [String]
}

/// Immutable MDL material/skin lookup table. It intentionally contains no
/// filesystem, VMT, VTF, GLua, or renderer references.
public struct SourceStudioModelMaterialTableSnapshot: Sendable, Equatable {
    public let checksum: Int32
    public let modelName: String
    public let textures: [SourceStudioModelTextureSnapshot]
    public let cdTextureDirectories: [String]
    public let skinReferenceCount: Int
    public let skinFamilies: [SourceStudioModelSkinFamilySnapshot]

    public func resolve(
        meshMaterialIndex: Int32,
        skinFamilyIndex: Int
    ) throws -> SourceStudioResolvedModelMaterialSnapshot {
        guard skinFamilyIndex >= 0, skinFamilyIndex < skinFamilies.count else {
            throw SourceStudioModelMaterialDecodeError.invalidSkinFamily(
                value: skinFamilyIndex,
                available: skinFamilies.count
            )
        }
        guard meshMaterialIndex >= 0,
              meshMaterialIndex < Int32(skinReferenceCount) else {
            throw SourceStudioModelMaterialDecodeError.invalidMeshMaterialIndex(
                value: meshMaterialIndex,
                skinReferenceCount: skinReferenceCount
            )
        }
        let materialSlot = Int(meshMaterialIndex)
        let textureIndex = skinFamilies[skinFamilyIndex].textureIndices[materialSlot]
        let texture = textures[textureIndex]
        let fixedTextureName = Self.fixedSlashes(texture.name)
        let candidates = cdTextureDirectories.map { directory in
            "materials/" + Self.fixedSlashes(directory) + fixedTextureName + ".vmt"
        }
        return SourceStudioResolvedModelMaterialSnapshot(
            meshMaterialIndex: materialSlot,
            skinFamilyIndex: skinFamilyIndex,
            textureIndex: textureIndex,
            textureName: texture.name,
            cdTextureCandidates: candidates
        )
    }

    private static func fixedSlashes(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "/")
    }
}

public enum SourceStudioModelMaterialDecoder {
    public static func decode(
        _ payload: SourceStudioImmutableRenderPayload,
        budget: SourceStudioModelMaterialDecodeBudget
    ) throws -> SourceStudioModelMaterialTableSnapshot {
        try validate(budget: budget)
        let reader = MaterialReader(payload.mdlData)
        var totalStringBytes = 0

        let textureCount = try cappedCount(
            reader: reader,
            offset: 204,
            field: "studiohdr_t.numtextures",
            cap: budget.maximumTextures
        )
        let textureTableOffset = try reader.int32(
            at: 208,
            field: "studiohdr_t.textureindex"
        )
        let textureTable = try reader.absoluteTable(
            offset: textureTableOffset,
            count: textureCount,
            stride: Layout.texture,
            alignment: 4,
            field: "studiohdr_t.textures"
        )
        var textures: [SourceStudioModelTextureSnapshot] = []
        textures.reserveCapacity(textureCount)
        for index in 0..<textureCount {
            let base = textureTable + index * Layout.texture
            let prefix = "texture[\(index)]"
            let decoded = try reader.relativeCString(
                base: base,
                offset: reader.int32(at: base, field: "\(prefix).sznameindex"),
                maximumBytes: budget.maximumStringBytes,
                field: "\(prefix).name"
            )
            totalStringBytes = try addingStringBytes(
                decoded.byteCount,
                current: totalStringBytes,
                cap: budget.maximumTotalStringBytes,
                field: "Studio material strings"
            )
            textures.append(SourceStudioModelTextureSnapshot(
                index: index,
                name: decoded.value,
                flags: try reader.int32(at: base + 4, field: "\(prefix).flags"),
                usedCount: try reader.int32(at: base + 8, field: "\(prefix).used")
            ))
        }

        let directoryCount = try cappedCount(
            reader: reader,
            offset: 212,
            field: "studiohdr_t.numcdtextures",
            cap: budget.maximumCDTextureDirectories
        )
        let directoryTableOffset = try reader.int32(
            at: 216,
            field: "studiohdr_t.cdtextureindex"
        )
        let directoryTable = try reader.absoluteTable(
            offset: directoryTableOffset,
            count: directoryCount,
            stride: Layout.offset,
            alignment: 4,
            field: "studiohdr_t.cdtextures"
        )
        var directories: [String] = []
        directories.reserveCapacity(directoryCount)
        for index in 0..<directoryCount {
            let field = "cdtexture[\(index)]"
            let absoluteOffset = try reader.int32(
                at: directoryTable + index * Layout.offset,
                field: "\(field).offset"
            )
            let decoded = try reader.absoluteCString(
                offset: absoluteOffset,
                maximumBytes: budget.maximumStringBytes,
                field: field
            )
            totalStringBytes = try addingStringBytes(
                decoded.byteCount,
                current: totalStringBytes,
                cap: budget.maximumTotalStringBytes,
                field: "Studio material strings"
            )
            directories.append(decoded.value)
        }

        let skinReferenceCount = try cappedCount(
            reader: reader,
            offset: 220,
            field: "studiohdr_t.numskinref",
            cap: budget.maximumSkinReferences
        )
        let skinFamilyCount = try cappedCount(
            reader: reader,
            offset: 224,
            field: "studiohdr_t.numskinfamilies",
            cap: budget.maximumSkinFamilies
        )
        let (skinEntryCount, overflow) = skinReferenceCount.multipliedReportingOverflow(
            by: skinFamilyCount
        )
        guard !overflow else {
            throw SourceStudioModelMaterialDecodeError.countProductOverflow(
                field: "studiohdr_t.skinrefs",
                lhs: skinReferenceCount,
                rhs: skinFamilyCount
            )
        }
        guard skinEntryCount <= budget.maximumSkinEntries else {
            throw SourceStudioModelMaterialDecodeError.exceedsBudget(
                field: "skin entries",
                value: skinEntryCount,
                cap: budget.maximumSkinEntries
            )
        }
        let skinTable = try reader.absoluteTable(
            offset: reader.int32(at: 228, field: "studiohdr_t.skinindex"),
            count: skinEntryCount,
            stride: Layout.skinReference,
            alignment: 2,
            field: "studiohdr_t.skinrefs"
        )
        var families: [SourceStudioModelSkinFamilySnapshot] = []
        families.reserveCapacity(skinFamilyCount)
        for familyIndex in 0..<skinFamilyCount {
            var textureIndices: [Int] = []
            textureIndices.reserveCapacity(skinReferenceCount)
            for materialSlot in 0..<skinReferenceCount {
                let tableIndex = familyIndex * skinReferenceCount + materialSlot
                let value = try reader.int16(
                    at: skinTable + tableIndex * Layout.skinReference,
                    field: "skin[\(familyIndex)][\(materialSlot)]"
                )
                guard value >= 0, Int(value) < textureCount else {
                    throw SourceStudioModelMaterialDecodeError.invalidSkinReference(
                        family: familyIndex,
                        materialSlot: materialSlot,
                        value: value,
                        textureCount: textureCount
                    )
                }
                textureIndices.append(Int(value))
            }
            families.append(SourceStudioModelSkinFamilySnapshot(
                index: familyIndex,
                textureIndices: textureIndices
            ))
        }

        try validateCandidateBudgets(
            textures: textures,
            directories: directories,
            cap: budget.maximumResolvedCandidateBytes
        )
        return SourceStudioModelMaterialTableSnapshot(
            checksum: payload.model.header.checksum,
            modelName: payload.model.header.name,
            textures: textures,
            cdTextureDirectories: directories,
            skinReferenceCount: skinReferenceCount,
            skinFamilies: families
        )
    }
}

private extension SourceStudioModelMaterialDecoder {
    enum Layout {
        // v48 on-disk mstudiotexture_t: four Int32 fields, two serialized
        // 32-bit pointer slots, and ten unused Int32 values.
        static let texture = 64
        static let offset = 4
        static let skinReference = 2
    }

    static func validate(budget: SourceStudioModelMaterialDecodeBudget) throws {
        let fields = [
            ("maximumTextures", budget.maximumTextures),
            ("maximumCDTextureDirectories", budget.maximumCDTextureDirectories),
            ("maximumSkinReferences", budget.maximumSkinReferences),
            ("maximumSkinFamilies", budget.maximumSkinFamilies),
            ("maximumSkinEntries", budget.maximumSkinEntries),
            ("maximumStringBytes", budget.maximumStringBytes),
            ("maximumTotalStringBytes", budget.maximumTotalStringBytes),
            ("maximumResolvedCandidateBytes", budget.maximumResolvedCandidateBytes)
        ]
        if let invalid = fields.first(where: { $0.1 < 0 }) {
            throw SourceStudioModelMaterialDecodeError.invalidBudget(
                field: invalid.0,
                value: invalid.1
            )
        }
    }

    static func cappedCount(
        reader: MaterialReader,
        offset: Int,
        field: String,
        cap: Int
    ) throws -> Int {
        let value = try reader.count(at: offset, field: field)
        guard value <= cap else {
            throw SourceStudioModelMaterialDecodeError.exceedsBudget(
                field: field,
                value: value,
                cap: cap
            )
        }
        return value
    }

    static func addingStringBytes(
        _ amount: Int,
        current: Int,
        cap: Int,
        field: String
    ) throws -> Int {
        let (next, overflow) = current.addingReportingOverflow(amount)
        guard !overflow, next <= cap else {
            throw SourceStudioModelMaterialDecodeError.exceedsBudget(
                field: field,
                value: overflow ? Int.max : next,
                cap: cap
            )
        }
        return next
    }

    static func validateCandidateBudgets(
        textures: [SourceStudioModelTextureSnapshot],
        directories: [String],
        cap: Int
    ) throws {
        guard !textures.isEmpty, !directories.isEmpty else { return }
        let prefixBytes = "materials/".utf8.count
        let suffixBytes = ".vmt".utf8.count
        var directoryBytes = 0
        for directory in directories {
            let (next, overflow) = directoryBytes.addingReportingOverflow(
                directory.utf8.count
            )
            guard !overflow else {
                throw SourceStudioModelMaterialDecodeError.exceedsBudget(
                    field: "resolved candidate bytes",
                    value: Int.max,
                    cap: cap
                )
            }
            directoryBytes = next
        }
        for texture in textures {
            let fixedComponents = [prefixBytes, texture.name.utf8.count, suffixBytes]
            var fixedBytes = 0
            for component in fixedComponents {
                let (next, overflow) = fixedBytes.addingReportingOverflow(component)
                guard !overflow else {
                    throw SourceStudioModelMaterialDecodeError.exceedsBudget(
                        field: "texture[\(texture.index)] candidate bytes",
                        value: Int.max,
                        cap: cap
                    )
                }
                fixedBytes = next
            }
            let (repeatedBytes, multiplyOverflow) = fixedBytes.multipliedReportingOverflow(
                by: directories.count
            )
            let (total, addOverflow) = repeatedBytes.addingReportingOverflow(directoryBytes)
            guard !multiplyOverflow, !addOverflow, total <= cap else {
                throw SourceStudioModelMaterialDecodeError.exceedsBudget(
                    field: "texture[\(texture.index)] candidate bytes",
                    value: multiplyOverflow || addOverflow ? Int.max : total,
                    cap: cap
                )
            }
        }
    }
}

private struct MaterialReader {
    struct DecodedString {
        let value: String
        let byteCount: Int
    }

    let data: Data
    var length: Int { data.count }

    init(_ data: Data) {
        self.data = data
    }

    func uint16(at offset: Int, field: String) throws -> UInt16 {
        try require(start: offset, byteCount: 2, field: field)
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            UInt16(raw[offset]) | (UInt16(raw[offset + 1]) << 8)
        }
    }

    func int16(at offset: Int, field: String) throws -> Int16 {
        Int16(bitPattern: try uint16(at: offset, field: field))
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

    func count(at offset: Int, field: String) throws -> Int {
        let value = try int32(at: offset, field: field)
        guard value >= 0 else {
            throw SourceStudioModelMaterialDecodeError.invalidCount(
                field: field,
                value: value
            )
        }
        return Int(value)
    }

    func absoluteTable(
        offset: Int32,
        count: Int,
        stride: Int,
        alignment: Int,
        field: String
    ) throws -> Int {
        if count == 0 { return 0 }
        guard offset > 0 else {
            throw SourceStudioModelMaterialDecodeError.invalidOffset(
                field: field,
                value: offset
            )
        }
        guard offset % Int32(alignment) == 0 else {
            throw SourceStudioModelMaterialDecodeError.misalignedOffset(
                field: field,
                value: offset,
                alignment: alignment
            )
        }
        let (byteCount, overflow) = count.multipliedReportingOverflow(by: stride)
        guard !overflow else {
            throw SourceStudioModelMaterialDecodeError.countProductOverflow(
                field: field,
                lhs: count,
                rhs: stride
            )
        }
        let start = Int(offset)
        try require(start: start, byteCount: byteCount, field: field)
        return start
    }

    func relativeCString(
        base: Int,
        offset: Int32,
        maximumBytes: Int,
        field: String
    ) throws -> DecodedString {
        guard offset != 0 else {
            throw SourceStudioModelMaterialDecodeError.invalidOffset(
                field: field,
                value: offset
            )
        }
        let (start, overflow) = base.addingReportingOverflow(Int(offset))
        guard !overflow else {
            throw SourceStudioModelMaterialDecodeError.offsetOverflow(
                field: field,
                base: base,
                offset: offset
            )
        }
        return try cString(start: start, maximumBytes: maximumBytes, field: field)
    }

    func absoluteCString(
        offset: Int32,
        maximumBytes: Int,
        field: String
    ) throws -> DecodedString {
        guard offset > 0 else {
            throw SourceStudioModelMaterialDecodeError.invalidOffset(
                field: field,
                value: offset
            )
        }
        return try cString(start: Int(offset), maximumBytes: maximumBytes, field: field)
    }

    private func cString(
        start: Int,
        maximumBytes: Int,
        field: String
    ) throws -> DecodedString {
        guard start >= 0, start < length else {
            throw SourceStudioModelMaterialDecodeError.outOfBounds(
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
                throw SourceStudioModelMaterialDecodeError.unterminatedString(
                    field: field,
                    start: start
                )
            }
            throw SourceStudioModelMaterialDecodeError.stringByteCountExceeded(
                field: field,
                value: maximumSearchBytes,
                cap: maximumBytes
            )
        }
        let byteCount = end - start
        guard let value = String(data: data[start..<end], encoding: .utf8) else {
            throw SourceStudioModelMaterialDecodeError.stringIsNotUTF8(
                field: field,
                start: start
            )
        }
        return DecodedString(value: value, byteCount: byteCount)
    }

    private func require(start: Int, byteCount: Int, field: String) throws {
        let (end, overflow) = start.addingReportingOverflow(byteCount)
        guard start >= 0, byteCount >= 0, !overflow, end <= length else {
            throw SourceStudioModelMaterialDecodeError.outOfBounds(
                field: field,
                start: start,
                byteCount: byteCount,
                length: length
            )
        }
    }
}
