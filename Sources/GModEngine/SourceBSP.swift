import Foundation

// Binary layout references: Valve Source SDK 2013, commit
// c8f4c6351162fbff83bfa5a428d45d1e6eed3824, from
// https://github.com/ValveSoftware/source-sdk-2013.
// Paths below are repository-relative and do not depend on a developer host.
// src/public/bspfile.h
//   - lines 20-25: VBSP identity and Source BSP version 20
//   - lines 279-391: lump indices (including leaf face/brush tables), 64-entry
//     header, and compression metadata
//   - lines 441-517: models, vertices, planes, nodes, texinfo, and texdata
//   - lines 673-754: edges and version-1 faces
//   - lines 799-851: version-0 and version-1 leaves
//   - lines 878-893: brush sides and brushes
// src/public/mathlib/compressed_light_cube.h
//   - lines 17-21: six ColorRGBExp32 samples in a version-0 leaf
// src/public/mathlib/mathlib.h
//   - lines 989-994: ColorRGBExp32 byte layout
// src/public/tier1/lzmaDecoder.h
//   - lines 20-23: Source's little-endian "LZMA" payload identity
// src/public/cmodel.h
//   - lines 41-68: cmodel headnode, csurface_t, and centered Ray_t fields
//
// The SDK accepts MINBSPVERSION 19 through BSPVERSION 20, and installed GMod
// corpus verifies version 20. Version 21
// is available only through an explicit research policy until a lawful real
// corpus is checked; every typed lump remains gated by its own exact version.

public enum SourceBSPVersionPolicy: Sendable, Equatable {
    case verifiedSourceSDK2013
    case permitUnverifiedVersion21ForResearch
}

public enum SourceBSPError: Error, Sendable, Equatable, CustomStringConvertible {
    case truncatedHeader(actualByteCount: Int, requiredByteCount: Int)
    case invalidMagic(UInt32)
    case unsupportedVersion(Int32)
    case invalidLumpBounds(index: Int, offset: Int64, length: Int64, fileByteCount: Int)
    case lumpOverlapsHeader(index: Int, offset: Int64, length: Int64)
    case unsupportedCompressedLump(
        index: Int,
        declaredUncompressedSize: UInt32,
        hasLZMASignature: Bool
    )
    case unsupportedLumpVersion(index: Int, actual: Int32, supported: [Int32])
    case invalidRecordByteCount(index: Int, byteCount: Int, recordByteCount: Int)
    case invalidLumpIndex(Int)
    case invalidReference(context: String, index: Int64, availableCount: Int)
    case invalidReferenceRange(
        context: String,
        first: Int64,
        count: Int64,
        availableCount: Int
    )
    case invalidValue(context: String, value: Int64)
    case nonFiniteValue(context: String)
    case malformedEntityText(context: String)
    case cyclicNodeGraph(nodeIndex: Int)
    case missingWorldTree
    case unexpectedEnd(context: String)

    public var description: String {
        switch self {
        case let .truncatedHeader(actual, required):
            return "truncated BSP header: got \(actual) bytes, need \(required)"
        case let .invalidMagic(magic):
            return "invalid BSP magic 0x\(String(magic, radix: 16)); expected VBSP"
        case let .unsupportedVersion(version):
            return "unsupported BSP version \(version); SDK range is 19...20 (21 requires explicit research opt-in)"
        case let .invalidLumpBounds(index, offset, length, fileByteCount):
            return "BSP lump \(index) range \(offset)..<\(offset + length) is outside \(fileByteCount) bytes"
        case let .lumpOverlapsHeader(index, offset, length):
            return "BSP lump \(index) range \(offset)..<\(offset + length) overlaps the BSP header"
        case let .unsupportedCompressedLump(index, size, signature):
            let evidence = signature ? "LZMA signature" : "header compression metadata"
            return "BSP lump \(index) is compressed (\(evidence), declared size \(size)); LZMA is unsupported"
        case let .unsupportedLumpVersion(index, actual, supported):
            return "BSP lump \(index) version \(actual) is unsupported; supported versions: \(supported)"
        case let .invalidRecordByteCount(index, byteCount, recordByteCount):
            return "BSP lump \(index) has \(byteCount) bytes, not a multiple of \(recordByteCount)"
        case let .invalidLumpIndex(index):
            return "BSP lump index \(index) is outside 0..<64"
        case let .invalidReference(context, index, availableCount):
            return "BSP \(context) index \(index) is outside 0..<\(availableCount)"
        case let .invalidReferenceRange(context, first, count, availableCount):
            return "BSP \(context) range \(first)..<\(first + count) is outside 0..<\(availableCount)"
        case let .invalidValue(context, value):
            return "BSP \(context) has invalid value \(value)"
        case let .nonFiniteValue(context):
            return "BSP \(context) is non-finite"
        case let .malformedEntityText(context):
            return "malformed BSP entity text while reading \(context)"
        case let .cyclicNodeGraph(nodeIndex):
            return "BSP node graph contains a cycle through node \(nodeIndex)"
        case .missingWorldTree:
            return "BSP has no world model, node, or leaf to traverse"
        case let .unexpectedEnd(context):
            return "unexpected end of BSP data while reading \(context)"
        }
    }
}

public enum SourceBSPLumpKind: Int, CaseIterable, Sendable {
    case entities = 0
    case planes = 1
    case textureData = 2
    case vertices = 3
    case nodes = 5
    case textureInfo = 6
    case faces = 7
    case lighting = 8
    case leaves = 10
    case edges = 12
    case surfaceEdges = 13
    case models = 14
    case leafFaces = 16
    case leafBrushes = 17
    case brushes = 18
    case brushSides = 19
    case displacementInfo = 26
    case displacementVertices = 33
    case leafWaterData = 36
    case pakFile = 40
    case textureStringData = 43
    case textureStringTable = 44
    case displacementTriangles = 48
    case lightingHDR = 53
    case facesHDR = 58
}

public struct SourceBSPLumpDescriptor: Sendable, Equatable {
    public let index: Int
    public let fileOffset: Int
    public let fileLength: Int
    public let version: Int32
    public let uncompressedSize: UInt32

    public var isCompressed: Bool { uncompressedSize != 0 }
}

fileprivate final class SourceBSPStorage: @unchecked Sendable {
    let data: Data

    init(data: Data) {
        self.data = data
    }

    func slice(offset: Int, length: Int) -> Data {
        let start = data.index(data.startIndex, offsetBy: offset)
        let end = data.index(start, offsetBy: length)
        return data[start..<end]
    }
}

public struct SourceBSPLump: Sendable, Equatable {
    public let descriptor: SourceBSPLumpDescriptor

    private let storage: SourceBSPStorage

    /// A copy-on-write slice of the original BSP file. Keeping the shared
    /// backing storage here avoids eagerly copying every lump, including files
    /// whose descriptors intentionally or maliciously overlap.
    public var data: Data {
        storage.slice(offset: descriptor.fileOffset, length: descriptor.fileLength)
    }

    fileprivate init(descriptor: SourceBSPLumpDescriptor, storage: SourceBSPStorage) {
        self.descriptor = descriptor
        self.storage = storage
    }

    public static func == (lhs: SourceBSPLump, rhs: SourceBSPLump) -> Bool {
        lhs.descriptor == rhs.descriptor && lhs.data == rhs.data
    }

    /// Test-visible invariant for the allocation hardening above. This stays
    /// internal so backing-store identity is not part of the public BSP API.
    func _sharesBackingStorage(with other: SourceBSPLump) -> Bool {
        storage === other.storage
    }
}

public struct SourceBSPHeader: Sendable, Equatable {
    public let magic: UInt32
    public let version: Int32
    public let lumps: [SourceBSPLumpDescriptor]
    public let mapRevision: Int32
}

public struct SourceBSPVector3: Sendable, Equatable {
    public let x: Float
    public let y: Float
    public let z: Float
}

public struct SourceBSPShortVector3: Sendable, Equatable {
    public let x: Int16
    public let y: Int16
    public let z: Int16
}

public struct SourceBSPPlane: Sendable, Equatable {
    public let normal: SourceBSPVector3
    public let distance: Float
    public let type: Int32
}

public struct SourceBSPVertex: Sendable, Equatable {
    public let point: SourceBSPVector3
}

public struct SourceBSPEdge: Sendable, Equatable {
    public let firstVertex: UInt16
    public let secondVertex: UInt16
}

public struct SourceBSPNode: Sendable, Equatable {
    public let planeIndex: Int32
    public let children: [Int32]
    public let mins: SourceBSPShortVector3
    public let maxs: SourceBSPShortVector3
    public let firstFace: UInt16
    public let faceCount: UInt16
    public let area: Int16
}

public struct SourceBSPRGBExponent: Sendable, Equatable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8
    public let exponent: Int8

    /// Exact Source `TexLightToLinear`: Valve's `power2_n` lookup table stores
    /// `2^exponent / 255`, so each byte mantissa becomes linear light while
    /// HDR samples can truthfully remain above one.
    public var linearColor: SourceBSPVector3 {
        let scale = Float(pow(2.0, Double(exponent))) / 255
        return SourceBSPVector3(
            x: Float(red) * scale,
            y: Float(green) * scale,
            z: Float(blue) * scale
        )
    }
}

public struct SourceBSPLeaf: Sendable, Equatable {
    public let formatVersion: Int32
    public let contents: Int32
    public let cluster: Int16
    public let areaAndFlags: UInt16
    public let mins: SourceBSPShortVector3
    public let maxs: SourceBSPShortVector3
    public let firstLeafFace: UInt16
    public let leafFaceCount: UInt16
    public let firstLeafBrush: UInt16
    public let leafBrushCount: UInt16
    public let leafWaterDataID: Int16
    public let ambientLighting: [SourceBSPRGBExponent]?

    public var area: UInt16 { areaAndFlags & 0x01FF }
    public var flags: UInt8 { UInt8((areaAndFlags >> 9) & 0x007F) }
}

public struct SourceBSPBrush: Sendable, Equatable {
    public let firstSide: Int32
    public let sideCount: Int32
    public let contents: Int32
}

public struct SourceBSPBrushSide: Sendable, Equatable {
    public let planeIndex: UInt16
    public let textureInfoIndex: Int16
    public let displacementInfoIndex: Int16
    public let bevel: Int16
}

public struct SourceBSPModel: Sendable, Equatable {
    public let mins: SourceBSPVector3
    public let maxs: SourceBSPVector3
    public let origin: SourceBSPVector3
    public let headNode: Int32
    public let firstFace: Int32
    public let faceCount: Int32
}

public struct SourceBSPTextureData: Sendable, Equatable {
    public let reflectivity: SourceBSPVector3
    public let nameStringTableID: Int32
    public let width: Int32
    public let height: Int32
    public let viewWidth: Int32
    public let viewHeight: Int32
}

public struct SourceBSPTextureVector: Sendable, Equatable {
    public let x: Float
    public let y: Float
    public let z: Float
    public let offset: Float
}

public struct SourceBSPTextureInfo: Sendable, Equatable {
    public let textureVectors: [SourceBSPTextureVector]
    public let lightmapVectors: [SourceBSPTextureVector]
    public let flags: Int32
    public let textureDataIndex: Int32
}

public struct SourceBSPFace: Sendable, Equatable {
    public let planeIndex: UInt16
    public let side: UInt8
    public let isOnNode: UInt8
    public let firstSurfaceEdge: Int32
    public let surfaceEdgeCount: Int16
    public let textureInfoIndex: Int16
    public let displacementInfoIndex: Int16
    public let surfaceFogVolumeID: Int16
    public let lightStyles: [UInt8]
    public let lightOffset: Int32
    public let area: Float
    public let lightmapTextureMinsInLuxels: [Int32]
    public let lightmapTextureSizeInLuxels: [Int32]
    public let originalFace: Int32
    public let primitiveCountAndShadowFlag: UInt16
    public let firstPrimitiveID: UInt16
    public let smoothingGroups: UInt32

    public var primitiveCount: UInt16 { primitiveCountAndShadowFlag & 0x7FFF }
    public var dynamicShadowsEnabled: Bool { primitiveCountAndShadowFlag & 0x8000 == 0 }
}

public struct SourceBSPEntityKeyValue: Sendable, Equatable {
    public let key: String
    public let value: String
}

/// One half-edge neighbor entry from Source SDK 2013's
/// `CDispSubNeighbor`. The UInt16 sentinel `0xFFFF` means no neighbor.
public struct SourceBSPDisplacementSubNeighbor: Sendable, Equatable {
    public let neighborIndex: UInt16
    public let neighborOrientation: UInt8
    public let span: UInt8
    public let neighborSpan: UInt8

    public var isValid: Bool { neighborIndex != UInt16.max }
}

public struct SourceBSPDisplacementEdgeNeighbor: Sendable, Equatable {
    public let subNeighbors: [SourceBSPDisplacementSubNeighbor]
}

public struct SourceBSPDisplacementCornerNeighbor: Sendable, Equatable {
    public let neighborIndices: [UInt16]
    public let neighborCount: UInt8
}

/// Typed `ddispinfo_t` data. Counts are derived exactly from Source's
/// `(2^power + 1)^2` vertex grid and `2 * (2^power)^2` triangle grid.
public struct SourceBSPDisplacementInfo: Sendable, Equatable {
    public static let allowedVertexWordCount = 10

    public let startPosition: SourceBSPVector3
    public let firstVertex: Int32
    public let firstTriangle: Int32
    public let power: Int32
    public let minimumTessellation: Int32
    public let smoothingAngle: Float
    public let contents: Int32
    public let mapFaceIndex: UInt16
    public let lightmapAlphaStart: Int32
    public let lightmapSamplePositionStart: Int32
    public let edgeNeighbors: [SourceBSPDisplacementEdgeNeighbor]
    public let cornerNeighbors: [SourceBSPDisplacementCornerNeighbor]
    public let allowedVertexWords: [UInt32]

    public var sideLength: Int { (1 << Int(power)) + 1 }
    public var vertexCount: Int { sideLength * sideLength }
    public var triangleCount: Int {
        let cells = 1 << Int(power)
        return cells * cells * 2
    }

    /// Source keeps a full maximum-power bit field. A false bit affects
    /// crack-free LOD activation; it does not remove the full-resolution
    /// renderer vertex or create a hole.
    public func isVertexAllowed(_ index: Int) -> Bool {
        guard index >= 0, index < vertexCount else { return false }
        let word = index / 32
        let bit = UInt32(index % 32)
        guard allowedVertexWords.indices.contains(word) else { return false }
        return allowedVertexWords[word] & (UInt32(1) << bit) != 0
    }
}

public struct SourceBSPDisplacementVertex: Sendable, Equatable {
    /// Vector field as stored by VBSP. It is deliberately not normalized:
    /// VBSP can store a direct offset vector with `distance == 1` when
    /// snapping otherwise-unused vertices to the allowed triangulation.
    public let vector: SourceBSPVector3
    public let distance: Float
    public let alpha: Float
}

public struct SourceBSPDisplacementTriangleTags: OptionSet, Sendable, Equatable {
    public let rawValue: UInt16

    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let surface = Self(rawValue: 1 << 0)
    public static let walkable = Self(rawValue: 1 << 1)
    public static let buildable = Self(rawValue: 1 << 2)
    public static let surfaceProperty1 = Self(rawValue: 1 << 3)
    public static let surfaceProperty2 = Self(rawValue: 1 << 4)
    public static let remove = Self(rawValue: 1 << 5)
}

public struct SourceBSPDisplacementTriangle: Sendable, Equatable {
    public let tags: SourceBSPDisplacementTriangleTags
}

/// Source fog-volume water metadata (`dleafwaterdata_t`).
public struct SourceBSPLeafWaterData: Sendable, Equatable {
    public let surfaceZ: Float
    public let minimumZ: Float
    public let surfaceTextureInfoIndex: Int16
}

public struct SourceBSPParsedEntity: Sendable, Equatable {
    public let keyValues: [SourceBSPEntityKeyValue]

    public func value(forKey requestedKey: String) -> String? {
        keyValues.last {
            $0.key.caseInsensitiveCompare(requestedKey) == .orderedSame
        }?.value
    }
}

public struct SourceBSPEntityText: Sendable, Equatable {
    public let rawBytes: Data

    /// Strict UTF-8 view with one conventional terminal NUL removed.
    /// Invalid UTF-8 remains available through `rawBytes` and returns nil here.
    public var text: String? {
        var bytes = rawBytes
        if bytes.last == 0 {
            bytes.removeLast()
        }
        return String(data: bytes, encoding: .utf8)
    }

    /// Parses the quoted key/value blocks used by Source's entity lump. The
    /// result stays ordered because duplicate output keys are legal entities.
    public func parsedEntities() throws -> [SourceBSPParsedEntity] {
        guard let text else {
            throw SourceBSPError.malformedEntityText(context: "UTF-8 entity lump")
        }
        var parser = SourceBSPEntityTextParser(text)
        return try parser.parse()
    }

    public func worldspawnValue(forKey key: String) throws -> String? {
        try parsedEntities().first {
            $0.value(forKey: "classname")?.caseInsensitiveCompare("worldspawn") ==
                .orderedSame
        }?.value(forKey: key)
    }
}

/// A zero-copy typed view of one ColorRGBExp32 BSP lighting lump.
public struct SourceBSPLighting: Sendable, Equatable {
    private let encodedSamples: Data

    fileprivate init(encodedSamples: Data) {
        self.encodedSamples = encodedSamples
    }

    public var byteCount: Int { encodedSamples.count }
    public var sampleCount: Int { encodedSamples.count / 4 }
    public var isEmpty: Bool { encodedSamples.isEmpty }

    public func sample(at index: Int) -> SourceBSPRGBExponent? {
        guard index >= 0, index < sampleCount else { return nil }
        let offset = index * 4
        return SourceBSPRGBExponent(
            red: encodedSamples[encodedSamples.index(encodedSamples.startIndex, offsetBy: offset)],
            green: encodedSamples[
                encodedSamples.index(encodedSamples.startIndex, offsetBy: offset + 1)
            ],
            blue: encodedSamples[
                encodedSamples.index(encodedSamples.startIndex, offsetBy: offset + 2)
            ],
            exponent: Int8(bitPattern: encodedSamples[
                encodedSamples.index(encodedSamples.startIndex, offsetBy: offset + 3)
            ])
        )
    }
}

public enum SourceBSPLightingKind: Sendable, Equatable {
    case standardDynamicRange
    case highDynamicRange
}

public struct SourceBSPLightmapCoordinate: Sendable, Equatable {
    public let luxelS: Float
    public let luxelT: Float
    public let normalizedU: Float
    public let normalizedV: Float
}

/// The first static light style and non-bump sample plane for one BSP face.
/// Additional styles/bump planes remain addressable through `sample`.
public struct SourceBSPFaceLightmap: Sendable, Equatable {
    public let faceIndex: Int
    public let kind: SourceBSPLightingKind
    public let width: Int
    public let height: Int
    public let styleCount: Int
    public let bumpSampleCount: Int
    public let encodedByteOffset: Int

    private let lightmapVectors: [SourceBSPTextureVector]
    private let minsInLuxels: [Int32]
    private let lighting: SourceBSPLighting

    fileprivate init(
        faceIndex: Int,
        kind: SourceBSPLightingKind,
        width: Int,
        height: Int,
        styleCount: Int,
        bumpSampleCount: Int,
        encodedByteOffset: Int,
        lightmapVectors: [SourceBSPTextureVector],
        minsInLuxels: [Int32],
        lighting: SourceBSPLighting
    ) {
        self.faceIndex = faceIndex
        self.kind = kind
        self.width = width
        self.height = height
        self.styleCount = styleCount
        self.bumpSampleCount = bumpSampleCount
        self.encodedByteOffset = encodedByteOffset
        self.lightmapVectors = lightmapVectors
        self.minsInLuxels = minsInLuxels
        self.lighting = lighting
    }

    public func textureCoordinate(
        at point: SourceBSPVector3
    ) -> SourceBSPLightmapCoordinate {
        let s = point.x * lightmapVectors[0].x +
            point.y * lightmapVectors[0].y +
            point.z * lightmapVectors[0].z +
            lightmapVectors[0].offset - Float(minsInLuxels[0])
        let t = point.x * lightmapVectors[1].x +
            point.y * lightmapVectors[1].y +
            point.z * lightmapVectors[1].z +
            lightmapVectors[1].offset - Float(minsInLuxels[1])
        return SourceBSPLightmapCoordinate(
            luxelS: s,
            luxelT: t,
            normalizedU: (s + 0.5) / Float(width),
            normalizedV: (t + 0.5) / Float(height)
        )
    }

    public func sample(
        style: Int = 0,
        bumpSample: Int = 0,
        x: Int,
        y: Int
    ) -> SourceBSPRGBExponent? {
        guard style >= 0, style < styleCount,
              bumpSample >= 0, bumpSample < bumpSampleCount,
              x >= 0, x < width,
              y >= 0, y < height else { return nil }
        let samplesPerPlane = width * height
        let relative = ((style * bumpSampleCount + bumpSample) * samplesPerPlane) +
            y * width + x
        return lighting.sample(at: encodedByteOffset / 4 + relative)
    }
}

public struct SourceBSP: Sendable, Equatable {
    public static let magic = UInt32(0x5053_4256) // little-endian bytes: V B S P
    public static let headerByteCount = 4 + 4 + 64 * 16 + 4

    public let header: SourceBSPHeader
    /// All 64 raw on-disk lumps. Unknown compressed lumps remain available as
    /// opaque bytes; typed access rejects compression until LZMA is implemented.
    public let lumps: [SourceBSPLump]
    public let entities: SourceBSPEntityText
    public let planes: [SourceBSPPlane]
    public let textureData: [SourceBSPTextureData]
    public let vertices: [SourceBSPVertex]
    public let nodes: [SourceBSPNode]
    public let textureInfo: [SourceBSPTextureInfo]
    public let faces: [SourceBSPFace]
    public let facesHDR: [SourceBSPFace]
    public let lighting: SourceBSPLighting
    public let lightingHDR: SourceBSPLighting
    public let leaves: [SourceBSPLeaf]
    public let edges: [SourceBSPEdge]
    public let surfaceEdges: [Int32]
    public let models: [SourceBSPModel]
    public let leafFaces: [UInt16]
    public let leafBrushes: [UInt16]
    public let brushes: [SourceBSPBrush]
    public let brushSides: [SourceBSPBrushSide]
    public let displacementInfo: [SourceBSPDisplacementInfo]
    public let displacementVertices: [SourceBSPDisplacementVertex]
    public let displacementTriangles: [SourceBSPDisplacementTriangle]
    public let leafWaterData: [SourceBSPLeafWaterData]
    /// Material names from LUMP_TEXDATA_STRING_DATA/TABLE, indexed by
    /// `SourceBSPTextureData.nameStringTableID`.
    public let textureNames: [String]

    public init(
        data: Data,
        versionPolicy: SourceBSPVersionPolicy = .verifiedSourceSDK2013
    ) throws {
        guard data.count >= Self.headerByteCount else {
            throw SourceBSPError.truncatedHeader(
                actualByteCount: data.count,
                requiredByteCount: Self.headerByteCount
            )
        }

        var reader = SourceBSPByteReader(data: data)
        let parsedMagic = try reader.readUInt32(context: "header magic")
        guard parsedMagic == Self.magic else {
            throw SourceBSPError.invalidMagic(parsedMagic)
        }

        let parsedVersion = try reader.readInt32(context: "header version")
        let versionIsAllowed = (19...20).contains(parsedVersion) ||
            (parsedVersion == 21 && versionPolicy == .permitUnverifiedVersion21ForResearch)
        guard versionIsAllowed else {
            throw SourceBSPError.unsupportedVersion(parsedVersion)
        }

        var descriptors: [SourceBSPLumpDescriptor] = []
        descriptors.reserveCapacity(64)
        let fileByteCount64 = Int64(data.count)

        for index in 0..<64 {
            let signedOffset = try reader.readInt32(context: "lump \(index) offset")
            let signedLength = try reader.readInt32(context: "lump \(index) length")
            let lumpVersion = try reader.readInt32(context: "lump \(index) version")
            let uncompressedSize = try reader.readUInt32(
                context: "lump \(index) uncompressed size"
            )

            let offset64 = Int64(signedOffset)
            let length64 = Int64(signedLength)
            let (end64, overflowed) = offset64.addingReportingOverflow(length64)
            guard signedOffset >= 0,
                  signedLength >= 0,
                  !overflowed,
                  offset64 <= fileByteCount64,
                  end64 <= fileByteCount64 else {
                throw SourceBSPError.invalidLumpBounds(
                    index: index,
                    offset: offset64,
                    length: length64,
                    fileByteCount: data.count
                )
            }
            guard signedLength == 0 || offset64 >= Int64(Self.headerByteCount) else {
                throw SourceBSPError.lumpOverlapsHeader(
                    index: index,
                    offset: offset64,
                    length: length64
                )
            }

            descriptors.append(
                SourceBSPLumpDescriptor(
                    index: index,
                    fileOffset: Int(offset64),
                    fileLength: Int(length64),
                    version: lumpVersion,
                    uncompressedSize: uncompressedSize
                )
            )
        }

        let mapRevision = try reader.readInt32(context: "map revision")
        let parsedHeader = SourceBSPHeader(
            magic: parsedMagic,
            version: parsedVersion,
            lumps: descriptors,
            mapRevision: mapRevision
        )

        let storage = SourceBSPStorage(data: data)
        var parsedLumps: [SourceBSPLump] = []
        parsedLumps.reserveCapacity(64)
        for descriptor in descriptors {
            parsedLumps.append(SourceBSPLump(descriptor: descriptor, storage: storage))
        }

        header = parsedHeader
        lumps = parsedLumps

        let entityLump = parsedLumps[SourceBSPLumpKind.entities.rawValue]
        try Self.requireVersion(entityLump, supported: [0])
        entities = SourceBSPEntityText(rawBytes: entityLump.data)

        planes = try Self.parseRecords(
            parsedLumps[SourceBSPLumpKind.planes.rawValue],
            recordByteCount: 20,
            supportedVersions: [0]
        ) { cursor in
            SourceBSPPlane(
                normal: try Self.readVector3(&cursor, context: "plane normal"),
                distance: try cursor.readFloat32(context: "plane distance"),
                type: try cursor.readInt32(context: "plane type")
            )
        }

        textureData = try Self.parseRecords(
            parsedLumps[SourceBSPLumpKind.textureData.rawValue],
            recordByteCount: 32,
            supportedVersions: [0]
        ) { cursor in
            SourceBSPTextureData(
                reflectivity: try Self.readVector3(&cursor, context: "texdata reflectivity"),
                nameStringTableID: try cursor.readInt32(context: "texdata name string table ID"),
                width: try cursor.readInt32(context: "texdata width"),
                height: try cursor.readInt32(context: "texdata height"),
                viewWidth: try cursor.readInt32(context: "texdata view width"),
                viewHeight: try cursor.readInt32(context: "texdata view height")
            )
        }

        vertices = try Self.parseRecords(
            parsedLumps[SourceBSPLumpKind.vertices.rawValue],
            recordByteCount: 12,
            supportedVersions: [0]
        ) { cursor in
            SourceBSPVertex(point: try Self.readVector3(&cursor, context: "vertex"))
        }

        nodes = try Self.parseRecords(
            parsedLumps[SourceBSPLumpKind.nodes.rawValue],
            recordByteCount: 32,
            supportedVersions: [0]
        ) { cursor in
            let node = SourceBSPNode(
                planeIndex: try cursor.readInt32(context: "node plane index"),
                children: [
                    try cursor.readInt32(context: "node first child"),
                    try cursor.readInt32(context: "node second child")
                ],
                mins: try Self.readShortVector3(&cursor, context: "node mins"),
                maxs: try Self.readShortVector3(&cursor, context: "node maxs"),
                firstFace: try cursor.readUInt16(context: "node first face"),
                faceCount: try cursor.readUInt16(context: "node face count"),
                area: try cursor.readInt16(context: "node area")
            )
            try cursor.skip(2, context: "node alignment padding")
            return node
        }

        textureInfo = try Self.parseRecords(
            parsedLumps[SourceBSPLumpKind.textureInfo.rawValue],
            recordByteCount: 72,
            supportedVersions: [0]
        ) { cursor in
            SourceBSPTextureInfo(
                textureVectors: [
                    try Self.readTextureVector(&cursor, context: "texinfo texture S vector"),
                    try Self.readTextureVector(&cursor, context: "texinfo texture T vector")
                ],
                lightmapVectors: [
                    try Self.readTextureVector(&cursor, context: "texinfo lightmap S vector"),
                    try Self.readTextureVector(&cursor, context: "texinfo lightmap T vector")
                ],
                flags: try cursor.readInt32(context: "texinfo flags"),
                textureDataIndex: try cursor.readInt32(context: "texinfo texdata index")
            )
        }

        faces = try Self.parseFaces(
            parsedLumps[SourceBSPLumpKind.faces.rawValue],
            contextPrefix: "face"
        )
        facesHDR = try Self.parseFaces(
            parsedLumps[SourceBSPLumpKind.facesHDR.rawValue],
            contextPrefix: "HDR face"
        )
        lighting = try Self.parseLighting(
            parsedLumps[SourceBSPLumpKind.lighting.rawValue]
        )
        lightingHDR = try Self.parseLighting(
            parsedLumps[SourceBSPLumpKind.lightingHDR.rawValue]
        )

        leaves = try Self.parseLeaves(parsedLumps[SourceBSPLumpKind.leaves.rawValue])

        edges = try Self.parseRecords(
            parsedLumps[SourceBSPLumpKind.edges.rawValue],
            recordByteCount: 4,
            supportedVersions: [0]
        ) { cursor in
            SourceBSPEdge(
                firstVertex: try cursor.readUInt16(context: "edge first vertex"),
                secondVertex: try cursor.readUInt16(context: "edge second vertex")
            )
        }

        surfaceEdges = try Self.parseRecords(
            parsedLumps[SourceBSPLumpKind.surfaceEdges.rawValue],
            recordByteCount: 4,
            supportedVersions: [0]
        ) { cursor in
            try cursor.readInt32(context: "surface edge")
        }

        models = try Self.parseRecords(
            parsedLumps[SourceBSPLumpKind.models.rawValue],
            recordByteCount: 48,
            supportedVersions: [0]
        ) { cursor in
            SourceBSPModel(
                mins: try Self.readVector3(&cursor, context: "model mins"),
                maxs: try Self.readVector3(&cursor, context: "model maxs"),
                origin: try Self.readVector3(&cursor, context: "model origin"),
                headNode: try cursor.readInt32(context: "model head node"),
                firstFace: try cursor.readInt32(context: "model first face"),
                faceCount: try cursor.readInt32(context: "model face count")
            )
        }

        leafFaces = try Self.parseRecords(
            parsedLumps[SourceBSPLumpKind.leafFaces.rawValue],
            recordByteCount: 2,
            supportedVersions: [0]
        ) { cursor in
            try cursor.readUInt16(context: "leaf face index")
        }

        leafBrushes = try Self.parseRecords(
            parsedLumps[SourceBSPLumpKind.leafBrushes.rawValue],
            recordByteCount: 2,
            supportedVersions: [0]
        ) { cursor in
            try cursor.readUInt16(context: "leaf brush index")
        }

        brushes = try Self.parseRecords(
            parsedLumps[SourceBSPLumpKind.brushes.rawValue],
            recordByteCount: 12,
            supportedVersions: [0]
        ) { cursor in
            SourceBSPBrush(
                firstSide: try cursor.readInt32(context: "brush first side"),
                sideCount: try cursor.readInt32(context: "brush side count"),
                contents: try cursor.readInt32(context: "brush contents")
            )
        }

        brushSides = try Self.parseRecords(
            parsedLumps[SourceBSPLumpKind.brushSides.rawValue],
            recordByteCount: 8,
            supportedVersions: [0]
        ) { cursor in
            SourceBSPBrushSide(
                planeIndex: try cursor.readUInt16(context: "brush side plane index"),
                textureInfoIndex: try cursor.readInt16(context: "brush side texinfo index"),
                displacementInfoIndex: try cursor.readInt16(context: "brush side dispinfo index"),
                bevel: try cursor.readInt16(context: "brush side bevel")
            )
        }

        displacementInfo = try Self.parseRecords(
            parsedLumps[SourceBSPLumpKind.displacementInfo.rawValue],
            recordByteCount: 176,
            supportedVersions: [0]
        ) { cursor in
            let startPosition = try Self.readVector3(
                &cursor,
                context: "displacement start position"
            )
            let firstVertex = try cursor.readInt32(
                context: "displacement first vertex"
            )
            let firstTriangle = try cursor.readInt32(
                context: "displacement first triangle"
            )
            let power = try cursor.readInt32(context: "displacement power")
            let minimumTessellation = try cursor.readInt32(
                context: "displacement minimum tessellation"
            )
            let smoothingAngle = try cursor.readFloat32(
                context: "displacement smoothing angle"
            )
            let contents = try cursor.readInt32(
                context: "displacement contents"
            )
            let mapFaceIndex = try cursor.readUInt16(
                context: "displacement map face"
            )
            try cursor.skip(2, context: "displacement map face alignment")
            let lightmapAlphaStart = try cursor.readInt32(
                context: "displacement lightmap alpha start"
            )
            let lightmapSamplePositionStart = try cursor.readInt32(
                context: "displacement lightmap sample-position start"
            )

            var edgeNeighbors: [SourceBSPDisplacementEdgeNeighbor] = []
            edgeNeighbors.reserveCapacity(4)
            for edge in 0..<4 {
                var subNeighbors: [SourceBSPDisplacementSubNeighbor] = []
                subNeighbors.reserveCapacity(2)
                for subNeighbor in 0..<2 {
                    let prefix = "displacement edge \(edge) subneighbor \(subNeighbor)"
                    subNeighbors.append(SourceBSPDisplacementSubNeighbor(
                        neighborIndex: try cursor.readUInt16(
                            context: "\(prefix) index"
                        ),
                        neighborOrientation: try cursor.readUInt8(
                            context: "\(prefix) orientation"
                        ),
                        span: try cursor.readUInt8(context: "\(prefix) span"),
                        neighborSpan: try cursor.readUInt8(
                            context: "\(prefix) neighbor span"
                        )
                    ))
                    try cursor.skip(1, context: "\(prefix) alignment")
                }
                edgeNeighbors.append(SourceBSPDisplacementEdgeNeighbor(
                    subNeighbors: subNeighbors
                ))
            }

            var cornerNeighbors: [SourceBSPDisplacementCornerNeighbor] = []
            cornerNeighbors.reserveCapacity(4)
            for corner in 0..<4 {
                var neighborIndices: [UInt16] = []
                neighborIndices.reserveCapacity(4)
                for neighbor in 0..<4 {
                    neighborIndices.append(try cursor.readUInt16(
                        context: "displacement corner \(corner) neighbor \(neighbor)"
                    ))
                }
                let neighborCount = try cursor.readUInt8(
                    context: "displacement corner \(corner) neighbor count"
                )
                try cursor.skip(
                    1,
                    context: "displacement corner \(corner) alignment"
                )
                cornerNeighbors.append(SourceBSPDisplacementCornerNeighbor(
                    neighborIndices: neighborIndices,
                    neighborCount: neighborCount
                ))
            }

            var allowedVertexWords: [UInt32] = []
            allowedVertexWords.reserveCapacity(
                SourceBSPDisplacementInfo.allowedVertexWordCount
            )
            for word in 0..<SourceBSPDisplacementInfo.allowedVertexWordCount {
                allowedVertexWords.append(try cursor.readUInt32(
                    context: "displacement allowed-vertex word \(word)"
                ))
            }
            return SourceBSPDisplacementInfo(
                startPosition: startPosition,
                firstVertex: firstVertex,
                firstTriangle: firstTriangle,
                power: power,
                minimumTessellation: minimumTessellation,
                smoothingAngle: smoothingAngle,
                contents: contents,
                mapFaceIndex: mapFaceIndex,
                lightmapAlphaStart: lightmapAlphaStart,
                lightmapSamplePositionStart: lightmapSamplePositionStart,
                edgeNeighbors: edgeNeighbors,
                cornerNeighbors: cornerNeighbors,
                allowedVertexWords: allowedVertexWords
            )
        }

        displacementVertices = try Self.parseRecords(
            parsedLumps[SourceBSPLumpKind.displacementVertices.rawValue],
            recordByteCount: 20,
            supportedVersions: [0]
        ) { cursor in
            SourceBSPDisplacementVertex(
                vector: try Self.readVector3(
                    &cursor,
                    context: "displacement vertex vector"
                ),
                distance: try cursor.readFloat32(
                    context: "displacement vertex distance"
                ),
                alpha: try cursor.readFloat32(
                    context: "displacement vertex alpha"
                )
            )
        }

        displacementTriangles = try Self.parseRecords(
            parsedLumps[SourceBSPLumpKind.displacementTriangles.rawValue],
            recordByteCount: 2,
            supportedVersions: [0]
        ) { cursor in
            SourceBSPDisplacementTriangle(
                tags: SourceBSPDisplacementTriangleTags(
                    rawValue: try cursor.readUInt16(
                        context: "displacement triangle tags"
                    )
                )
            )
        }

        leafWaterData = try Self.parseRecords(
            parsedLumps[SourceBSPLumpKind.leafWaterData.rawValue],
            recordByteCount: 12,
            supportedVersions: [0]
        ) { cursor in
            let result = SourceBSPLeafWaterData(
                surfaceZ: try cursor.readFloat32(
                    context: "leaf-water surface Z"
                ),
                minimumZ: try cursor.readFloat32(
                    context: "leaf-water minimum Z"
                ),
                surfaceTextureInfoIndex: try cursor.readInt16(
                    context: "leaf-water surface texinfo"
                )
            )
            try cursor.skip(2, context: "leaf-water alignment")
            return result
        }

        let textureStringDataLump =
            parsedLumps[SourceBSPLumpKind.textureStringData.rawValue]
        try Self.requireVersion(textureStringDataLump, supported: [0])
        let textureStringBytes = textureStringDataLump.data
        let textureStringOffsets = try Self.parseRecords(
            parsedLumps[SourceBSPLumpKind.textureStringTable.rawValue],
            recordByteCount: 4,
            supportedVersions: [0]
        ) { cursor in
            try cursor.readInt32(context: "texdata string offset")
        }
        textureNames = try textureStringOffsets.enumerated().map { index, rawOffset in
            guard rawOffset >= 0 else {
                throw SourceBSPError.invalidValue(
                    context: "texdata string table \(index) offset",
                    value: Int64(rawOffset)
                )
            }
            let offset = Int(rawOffset)
            guard offset < textureStringBytes.count else {
                throw SourceBSPError.invalidReference(
                    context: "texdata string table \(index) byte",
                    index: Int64(rawOffset),
                    availableCount: textureStringBytes.count
                )
            }
            let start = textureStringBytes.index(
                textureStringBytes.startIndex,
                offsetBy: offset
            )
            guard let terminator = textureStringBytes[start...]
                .firstIndex(of: 0) else {
                throw SourceBSPError.unexpectedEnd(
                    context: "texdata string table \(index) name"
                )
            }
            let encoded = textureStringBytes.subdata(in: start..<terminator)
            guard let name = String(data: encoded, encoding: .utf8) else {
                throw SourceBSPError.invalidValue(
                    context: "texdata string table \(index) UTF-8",
                    value: Int64(rawOffset)
                )
            }
            return name
        }

        try Self.validateReferences(
            planes: planes,
            textureData: textureData,
            vertices: vertices,
            nodes: nodes,
            textureInfo: textureInfo,
            faces: faces,
            leaves: leaves,
            edges: edges,
            surfaceEdges: surfaceEdges,
            models: models,
            leafFaces: leafFaces,
            leafBrushes: leafBrushes,
            brushes: brushes,
            brushSides: brushSides,
            displacementInfo: displacementInfo,
            displacementVertices: displacementVertices,
            displacementTriangles: displacementTriangles,
            leafWaterData: leafWaterData
        )

        if !facesHDR.isEmpty {
            guard facesHDR.count == faces.count else {
                throw SourceBSPError.invalidValue(
                    context: "HDR face count (expected \(faces.count))",
                    value: Int64(facesHDR.count)
                )
            }
            try Self.validateFaceReferences(
                facesHDR,
                contextPrefix: "HDR face",
                planes: planes,
                textureInfo: textureInfo,
                surfaceEdges: surfaceEdges
            )
        }
        try Self.validateLightmapReferences(
            faces: faces,
            contextPrefix: "face",
            textureInfo: textureInfo,
            lighting: lighting
        )
        if !facesHDR.isEmpty || !lightingHDR.isEmpty {
            try Self.validateLightmapReferences(
                faces: facesHDR.isEmpty ? faces : facesHDR,
                contextPrefix: "HDR face",
                textureInfo: textureInfo,
                lighting: lightingHDR
            )
        }

        if !textureNames.isEmpty {
            for (index, data) in textureData.enumerated() {
                guard data.nameStringTableID >= 0,
                      Int(data.nameStringTableID) < textureNames.count else {
                    throw SourceBSPError.invalidReference(
                        context: "texdata \(index) material name",
                        index: Int64(data.nameStringTableID),
                        availableCount: textureNames.count
                    )
                }
            }
        }
    }

    public func textureName(forTextureDataIndex index: Int) -> String? {
        guard textureData.indices.contains(index) else { return nil }
        let tableIndex = Int(textureData[index].nameStringTableID)
        guard textureNames.indices.contains(tableIndex) else { return nil }
        return textureNames[tableIndex]
    }

    public func worldspawnValue(forKey key: String) throws -> String? {
        try entities.worldspawnValue(forKey: key)
    }

    public func displacement(
        forFaceAt faceIndex: Int
    ) -> SourceBSPDisplacementInfo? {
        guard faces.indices.contains(faceIndex) else { return nil }
        let index = faces[faceIndex].displacementInfoIndex
        guard index >= 0, displacementInfo.indices.contains(Int(index)) else {
            return nil
        }
        return displacementInfo[Int(index)]
    }

    /// Returns the face's statically baked lightmap contract without copying
    /// the global lighting lump. HDR is preferred only when both the HDR face
    /// and lighting lumps are present; otherwise the ordinary pair is used.
    public func lightmap(
        forFaceAt faceIndex: Int,
        preferHighDynamicRange: Bool = true
    ) -> SourceBSPFaceLightmap? {
        let useHDR = preferHighDynamicRange &&
            !facesHDR.isEmpty &&
            !lightingHDR.isEmpty
        let selectedFaces = useHDR ? facesHDR : faces
        let selectedLighting = useHDR ? lightingHDR : lighting
        guard selectedFaces.indices.contains(faceIndex),
              !selectedLighting.isEmpty else { return nil }
        let face = selectedFaces[faceIndex]
        guard face.lightOffset >= 0,
              face.textureInfoIndex >= 0,
              face.lightmapTextureSizeInLuxels.count == 2,
              face.lightmapTextureMinsInLuxels.count == 2 else { return nil }
        let info = textureInfo[Int(face.textureInfoIndex)]
        let styleCount = face.lightStyles.prefix { $0 != 255 }.count
        guard styleCount > 0 else { return nil }
        let width = Int(face.lightmapTextureSizeInLuxels[0]) + 1
        let height = Int(face.lightmapTextureSizeInLuxels[1]) + 1
        guard width > 0, height > 0 else { return nil }
        let bumpSampleCount = UInt32(bitPattern: info.flags) & 0x0800 == 0 ? 1 : 4
        return SourceBSPFaceLightmap(
            faceIndex: faceIndex,
            kind: useHDR ? .highDynamicRange : .standardDynamicRange,
            width: width,
            height: height,
            styleCount: styleCount,
            bumpSampleCount: bumpSampleCount,
            encodedByteOffset: Int(face.lightOffset),
            lightmapVectors: info.lightmapVectors,
            minsInLuxels: face.lightmapTextureMinsInLuxels,
            lighting: selectedLighting
        )
    }

    public func lump(at index: Int) throws -> SourceBSPLump {
        guard lumps.indices.contains(index) else {
            throw SourceBSPError.invalidLumpIndex(index)
        }
        return lumps[index]
    }

    public func lump(_ kind: SourceBSPLumpKind) -> SourceBSPLump {
        lumps[kind.rawValue]
    }

    /// Walks `dnode_t::children` exactly as Source encodes it: child zero is
    /// the front half-space and a negative child is `-(leaf + 1)`.
    public func leafIndex(
        containing point: SourceVector3,
        headNode: Int32? = nil
    ) throws -> Int {
        var child = try resolvedHeadNode(headNode)
        var visitedNodes = Set<Int>()

        while child >= 0 {
            let nodeIndex = Int(child)
            guard nodes.indices.contains(nodeIndex) else {
                throw SourceBSPError.invalidReference(
                    context: "head/node child",
                    index: Int64(child),
                    availableCount: nodes.count
                )
            }
            guard visitedNodes.insert(nodeIndex).inserted else {
                throw SourceBSPError.cyclicNodeGraph(nodeIndex: nodeIndex)
            }

            let node = nodes[nodeIndex]
            let plane = planes[Int(node.planeIndex)]
            let distance = Self.vector(plane.normal).dot(point) - plane.distance
            child = node.children[distance >= 0 ? 0 : 1]
        }

        let leafIndex64 = -1 - Int64(child)
        guard leafIndex64 >= 0,
              leafIndex64 < Int64(leaves.count) else {
            throw SourceBSPError.invalidReference(
                context: "node leaf child",
                index: leafIndex64,
                availableCount: leaves.count
            )
        }
        return Int(leafIndex64)
    }

    /// Source point contents are the leaf's precomputed OR of brush contents.
    /// As in `SourceCollisionWorld.pointContents`, a matching mask selects the
    /// complete contents value rather than truncating it to the mask bits.
    public func worldPointContents(
        at point: SourceVector3,
        mask: SourceContents = SourceMasks.all,
        headNode: Int32? = nil
    ) throws -> SourceContents {
        let index = try leafIndex(containing: point, headNode: headNode)
        let contents = SourceContents(rawValue: UInt32(bitPattern: leaves[index].contents))
        guard contents.rawValue & mask.rawValue != 0 else { return .empty }
        return contents
    }

    /// Converts every parsed BSP brush into the existing deterministic convex
    /// collision core. World-tree traces below normally use only brushes
    /// referenced by leaves crossed by the sweep.
    public func collisionWorld(
        mask: SourceContents = SourceMasks.all
    ) -> SourceCollisionWorld {
        let selected = brushes.indices.filter { index in
            UInt32(bitPattern: brushes[index].contents) & mask.rawValue != 0
        }
        return collisionWorld(brushIndices: selected)
    }

    /// Traverses the BSP node tree as a broad phase, de-duplicates brushes in
    /// first-leaf order (the role of Source's brush checkcount), then delegates
    /// narrow-phase clipping to `SourceCollisionWorld`.
    public func traceWorld(
        _ ray: SourceRay,
        mask: SourceContents = SourceMasks.all,
        tolerance: Float = SourceCollisionConstants.distanceEpsilon,
        headNode: Int32? = nil
    ) throws -> SourceGameTrace {
        let indices = try brushIndicesIntersected(by: ray, headNode: headNode).filter { index in
            UInt32(bitPattern: brushes[index].contents) & mask.rawValue != 0
        }
        return collisionWorld(brushIndices: indices).trace(
            ray,
            mask: mask,
            tolerance: tolerance
        )
    }

    private func resolvedHeadNode(_ requested: Int32?) throws -> Int32 {
        if let requested { return requested }
        if let model = models.first { return model.headNode }
        if !nodes.isEmpty { return 0 }
        if !leaves.isEmpty { return -1 }
        throw SourceBSPError.missingWorldTree
    }

    private func brushIndicesIntersected(
        by ray: SourceRay,
        headNode: Int32?
    ) throws -> [Int] {
        let root = try resolvedHeadNode(headNode)
        var pending: [Int32] = [root]
        var visitedNodes = Set<Int>()
        var visitedLeaves = Set<Int>()
        var visitedBrushes = Set<Int>()
        var result: [Int] = []

        while let child = pending.popLast() {
            if child < 0 {
                let leafIndex64 = -1 - Int64(child)
                guard leafIndex64 >= 0,
                      leafIndex64 < Int64(leaves.count) else {
                    throw SourceBSPError.invalidReference(
                        context: "node leaf child",
                        index: leafIndex64,
                        availableCount: leaves.count
                    )
                }
                let leafIndex = Int(leafIndex64)
                guard visitedLeaves.insert(leafIndex).inserted else { continue }
                let leaf = leaves[leafIndex]
                let first = Int(leaf.firstLeafBrush)
                let end = first + Int(leaf.leafBrushCount)
                for tableIndex in first..<end {
                    let brushIndex = Int(leafBrushes[tableIndex])
                    if visitedBrushes.insert(brushIndex).inserted {
                        result.append(brushIndex)
                    }
                }
                continue
            }

            let nodeIndex = Int(child)
            guard nodes.indices.contains(nodeIndex) else {
                throw SourceBSPError.invalidReference(
                    context: "head/node child",
                    index: Int64(child),
                    availableCount: nodes.count
                )
            }
            guard visitedNodes.insert(nodeIndex).inserted else { continue }

            let node = nodes[nodeIndex]
            let plane = planes[Int(node.planeIndex)]
            let normal = Self.vector(plane.normal)
            let startDistance = normal.dot(ray.start) - plane.distance
            let endDistance = normal.dot(ray.start + ray.delta) - plane.distance
            let extentOffset = abs(normal.x) * ray.extents.x +
                abs(normal.y) * ray.extents.y +
                abs(normal.z) * ray.extents.z

            if startDistance > extentOffset, endDistance > extentOffset {
                pending.append(node.children[0])
            } else if startDistance < -extentOffset, endDistance < -extentOffset {
                pending.append(node.children[1])
            } else {
                // Stack the far child first so the near child is processed
                // first, preserving Source's start-to-end brush check order.
                let nearSide = startDistance >= 0 ? 0 : 1
                pending.append(node.children[1 - nearSide])
                pending.append(node.children[nearSide])
            }
        }
        return result
    }

    private func collisionWorld(brushIndices: [Int]) -> SourceCollisionWorld {
        SourceCollisionWorld(
            primitives: brushIndices.map { .convexBrush(convexBrush(at: $0)) }
        )
    }

    private func convexBrush(at brushIndex: Int) -> SourceConvexBrush {
        let brush = brushes[brushIndex]
        let start = Int(brush.firstSide)
        let end = start + Int(brush.sideCount)
        let sides = brushSides[start..<end]
        let convertedPlanes = sides.map { side in
            let plane = planes[Int(side.planeIndex)]
            return SourcePlane(
                normal: Self.vector(plane.normal),
                distance: plane.distance,
                type: UInt8(truncatingIfNeeded: plane.type)
            )
        }
        let firstSurface: SourceTraceSurface
        if let firstRealSide = sides.first(where: { $0.bevel == 0 }) {
            firstSurface = surface(for: firstRealSide)
        } else {
            firstSurface = SourceTraceSurface()
        }
        let planeSurfaces: [SourceTraceSurface] = sides.map { side in
            // Bevels are collision-only planes; preserve the first real side's
            // metadata if one becomes the entering clip plane.
            side.bevel == 0 ? surface(for: side) : firstSurface
        }
        return SourceConvexBrush(
            planes: convertedPlanes,
            contents: SourceContents(rawValue: UInt32(bitPattern: brush.contents)),
            surface: firstSurface,
            entityHandle: SourceBaseHandle(entryIndex: 0, serialNumber: 0),
            planeSurfaces: planeSurfaces
        )
    }

    private func surface(for side: SourceBSPBrushSide) -> SourceTraceSurface {
        guard side.textureInfoIndex >= 0 else { return SourceTraceSurface() }
        let info = textureInfo[Int(side.textureInfoIndex)]
        return SourceTraceSurface(flags: UInt16(truncatingIfNeeded: info.flags))
    }

    private static func vector(_ value: SourceBSPVector3) -> SourceVector3 {
        SourceVector3(value.x, value.y, value.z)
    }

    private static func validateReferences(
        planes: [SourceBSPPlane],
        textureData: [SourceBSPTextureData],
        vertices: [SourceBSPVertex],
        nodes: [SourceBSPNode],
        textureInfo: [SourceBSPTextureInfo],
        faces: [SourceBSPFace],
        leaves: [SourceBSPLeaf],
        edges: [SourceBSPEdge],
        surfaceEdges: [Int32],
        models: [SourceBSPModel],
        leafFaces: [UInt16],
        leafBrushes: [UInt16],
        brushes: [SourceBSPBrush],
        brushSides: [SourceBSPBrushSide],
        displacementInfo: [SourceBSPDisplacementInfo],
        displacementVertices: [SourceBSPDisplacementVertex],
        displacementTriangles: [SourceBSPDisplacementTriangle],
        leafWaterData: [SourceBSPLeafWaterData]
    ) throws {
        func requireIndex(_ index: Int64, count: Int, context: String) throws {
            guard index >= 0, index < Int64(count) else {
                throw SourceBSPError.invalidReference(
                    context: context,
                    index: index,
                    availableCount: count
                )
            }
        }

        func requireOptionalIndex(_ index: Int64, count: Int, context: String) throws {
            if index == -1 { return }
            try requireIndex(index, count: count, context: context)
        }

        func requireRange(
            first: Int64,
            count requestedCount: Int64,
            availableCount: Int,
            context: String
        ) throws {
            let (end, overflowed) = first.addingReportingOverflow(requestedCount)
            guard first >= 0,
                  requestedCount >= 0,
                  !overflowed,
                  end <= Int64(availableCount) else {
                throw SourceBSPError.invalidReferenceRange(
                    context: context,
                    first: first,
                    count: requestedCount,
                    availableCount: availableCount
                )
            }
        }

        func requireChild(_ child: Int32, context: String) throws {
            if child >= 0 {
                try requireIndex(Int64(child), count: nodes.count, context: context)
            } else {
                let leafIndex = -1 - Int64(child)
                try requireIndex(leafIndex, count: leaves.count, context: context)
            }
        }

        for (index, info) in textureInfo.enumerated() {
            try requireIndex(
                Int64(info.textureDataIndex),
                count: textureData.count,
                context: "texinfo \(index) texdata"
            )
        }

        for (index, edge) in edges.enumerated() {
            try requireIndex(
                Int64(edge.firstVertex),
                count: vertices.count,
                context: "edge \(index) first vertex"
            )
            try requireIndex(
                Int64(edge.secondVertex),
                count: vertices.count,
                context: "edge \(index) second vertex"
            )
        }

        for (index, surfaceEdge) in surfaceEdges.enumerated() {
            let edgeIndex = surfaceEdge >= 0 ? Int64(surfaceEdge) : -Int64(surfaceEdge)
            try requireIndex(
                edgeIndex,
                count: edges.count,
                context: "surface edge \(index) edge"
            )
        }

        for (index, face) in faces.enumerated() {
            try requireIndex(
                Int64(face.planeIndex),
                count: planes.count,
                context: "face \(index) plane"
            )
            try requireOptionalIndex(
                Int64(face.textureInfoIndex),
                count: textureInfo.count,
                context: "face \(index) texinfo"
            )
            try requireRange(
                first: Int64(face.firstSurfaceEdge),
                count: Int64(face.surfaceEdgeCount),
                availableCount: surfaceEdges.count,
                context: "face \(index) surface edges"
            )
            try requireOptionalIndex(
                Int64(face.displacementInfoIndex),
                count: displacementInfo.count,
                context: "face \(index) displacement"
            )
            if face.displacementInfoIndex >= 0 {
                let displacement = displacementInfo[Int(face.displacementInfoIndex)]
                guard Int(displacement.mapFaceIndex) == index else {
                    throw SourceBSPError.invalidReference(
                        context: "face \(index) reciprocal displacement map face",
                        index: Int64(displacement.mapFaceIndex),
                        availableCount: faces.count
                    )
                }
                guard face.surfaceEdgeCount == 4 else {
                    throw SourceBSPError.invalidValue(
                        context: "face \(index) displacement base edge count",
                        value: Int64(face.surfaceEdgeCount)
                    )
                }
            }
        }

        for (index, node) in nodes.enumerated() {
            try requireIndex(
                Int64(node.planeIndex),
                count: planes.count,
                context: "node \(index) plane"
            )
            try requireRange(
                first: Int64(node.firstFace),
                count: Int64(node.faceCount),
                availableCount: faces.count,
                context: "node \(index) faces"
            )
            for (side, child) in node.children.enumerated() {
                try requireChild(child, context: "node \(index) child \(side)")
            }
        }

        for (index, model) in models.enumerated() {
            try requireChild(model.headNode, context: "model \(index) head node")
            try requireRange(
                first: Int64(model.firstFace),
                count: Int64(model.faceCount),
                availableCount: faces.count,
                context: "model \(index) faces"
            )
        }

        for (index, leaf) in leaves.enumerated() {
            try requireRange(
                first: Int64(leaf.firstLeafFace),
                count: Int64(leaf.leafFaceCount),
                availableCount: leafFaces.count,
                context: "leaf \(index) face table"
            )
            try requireRange(
                first: Int64(leaf.firstLeafBrush),
                count: Int64(leaf.leafBrushCount),
                availableCount: leafBrushes.count,
                context: "leaf \(index) brush table"
            )
            try requireOptionalIndex(
                Int64(leaf.leafWaterDataID),
                count: leafWaterData.count,
                context: "leaf \(index) water data"
            )
        }

        for (index, faceIndex) in leafFaces.enumerated() {
            try requireIndex(
                Int64(faceIndex),
                count: faces.count,
                context: "leaf face table entry \(index)"
            )
        }

        for (index, brushIndex) in leafBrushes.enumerated() {
            try requireIndex(
                Int64(brushIndex),
                count: brushes.count,
                context: "leaf brush table entry \(index)"
            )
        }

        for (index, brush) in brushes.enumerated() {
            guard brush.sideCount > 0 else {
                throw SourceBSPError.invalidValue(
                    context: "brush \(index) side count",
                    value: Int64(brush.sideCount)
                )
            }
            try requireRange(
                first: Int64(brush.firstSide),
                count: Int64(brush.sideCount),
                availableCount: brushSides.count,
                context: "brush \(index) sides"
            )
        }

        for (index, side) in brushSides.enumerated() {
            try requireIndex(
                Int64(side.planeIndex),
                count: planes.count,
                context: "brush side \(index) plane"
            )
            try requireOptionalIndex(
                Int64(side.textureInfoIndex),
                count: textureInfo.count,
                context: "brush side \(index) texinfo"
            )
        }

        for (index, info) in displacementInfo.enumerated() {
            guard (2...4).contains(info.power) else {
                throw SourceBSPError.invalidValue(
                    context: "displacement \(index) power",
                    value: Int64(info.power)
                )
            }
            guard info.startPosition.x.isFinite,
                  info.startPosition.y.isFinite,
                  info.startPosition.z.isFinite,
                  info.smoothingAngle.isFinite else {
                throw SourceBSPError.nonFiniteValue(
                    context: "displacement \(index) geometry"
                )
            }
            try requireRange(
                first: Int64(info.firstVertex),
                count: Int64(info.vertexCount),
                availableCount: displacementVertices.count,
                context: "displacement \(index) vertices"
            )
            try requireRange(
                first: Int64(info.firstTriangle),
                count: Int64(info.triangleCount),
                availableCount: displacementTriangles.count,
                context: "displacement \(index) triangles"
            )
            try requireIndex(
                Int64(info.mapFaceIndex),
                count: faces.count,
                context: "displacement \(index) map face"
            )
            let mapFace = faces[Int(info.mapFaceIndex)]
            guard mapFace.displacementInfoIndex == Int16(index) else {
                throw SourceBSPError.invalidReference(
                    context: "displacement \(index) reciprocal face displacement",
                    index: Int64(mapFace.displacementInfoIndex),
                    availableCount: displacementInfo.count
                )
            }
            for (edge, neighbor) in info.edgeNeighbors.enumerated() {
                for (subIndex, subNeighbor) in neighbor.subNeighbors.enumerated()
                    where subNeighbor.isValid {
                    try requireIndex(
                        Int64(subNeighbor.neighborIndex),
                        count: displacementInfo.count,
                        context: "displacement \(index) edge \(edge) subneighbor \(subIndex)"
                    )
                    guard subNeighbor.neighborOrientation <= 3,
                          subNeighbor.span <= 2,
                          subNeighbor.neighborSpan <= 2 else {
                        throw SourceBSPError.invalidValue(
                            context: "displacement \(index) edge-neighbor orientation/span",
                            value: Int64(subNeighbor.neighborOrientation)
                        )
                    }
                }
            }
            for (corner, neighbor) in info.cornerNeighbors.enumerated() {
                guard neighbor.neighborCount <= 4 else {
                    throw SourceBSPError.invalidValue(
                        context: "displacement \(index) corner \(corner) neighbor count",
                        value: Int64(neighbor.neighborCount)
                    )
                }
                for slot in 0..<Int(neighbor.neighborCount) {
                    try requireIndex(
                        Int64(neighbor.neighborIndices[slot]),
                        count: displacementInfo.count,
                        context: "displacement \(index) corner \(corner) neighbor \(slot)"
                    )
                }
            }
        }

        for (index, vertex) in displacementVertices.enumerated() {
            guard vertex.vector.x.isFinite,
                  vertex.vector.y.isFinite,
                  vertex.vector.z.isFinite,
                  vertex.distance.isFinite,
                  vertex.alpha.isFinite else {
                throw SourceBSPError.nonFiniteValue(
                    context: "displacement vertex \(index)"
                )
            }
        }

        for (index, water) in leafWaterData.enumerated() {
            guard water.surfaceZ.isFinite, water.minimumZ.isFinite else {
                throw SourceBSPError.nonFiniteValue(
                    context: "leaf-water data \(index)"
                )
            }
            guard water.minimumZ <= water.surfaceZ else {
                throw SourceBSPError.invalidValue(
                    context: "leaf-water data \(index) minimum Z exceeds surface Z",
                    value: 1
                )
            }
            try requireIndex(
                Int64(water.surfaceTextureInfoIndex),
                count: textureInfo.count,
                context: "leaf-water data \(index) surface texinfo"
            )
        }

        // Malicious or corrupt node cycles would otherwise make point lookup
        // and recursive hull traversal non-terminating. Validate all nodes,
        // including disconnected submodel trees, with an iterative tri-color
        // walk to avoid consuming the Swift call stack.
        var state = Array(repeating: UInt8(0), count: nodes.count)
        for root in nodes.indices where state[root] == 0 {
            state[root] = 1
            var stack: [(node: Int, nextChild: Int)] = [(root, 0)]
            while let frame = stack.popLast() {
                if frame.nextChild >= 2 {
                    state[frame.node] = 2
                    continue
                }

                stack.append((frame.node, frame.nextChild + 1))
                let child = nodes[frame.node].children[frame.nextChild]
                guard child >= 0 else { continue }
                let childIndex = Int(child)
                if state[childIndex] == 1 {
                    throw SourceBSPError.cyclicNodeGraph(nodeIndex: childIndex)
                }
                if state[childIndex] == 0 {
                    state[childIndex] = 1
                    stack.append((childIndex, 0))
                }
            }
        }
    }

    private static func requireVersion(
        _ lump: SourceBSPLump,
        supported: [Int32]
    ) throws {
        try requireUncompressed(lump)
        guard !lump.data.isEmpty else { return }
        guard supported.contains(lump.descriptor.version) else {
            throw SourceBSPError.unsupportedLumpVersion(
                index: lump.descriptor.index,
                actual: lump.descriptor.version,
                supported: supported
            )
        }
    }

    private static func parseFaces(
        _ lump: SourceBSPLump,
        contextPrefix: String
    ) throws -> [SourceBSPFace] {
        return try parseRecords(
            lump,
            recordByteCount: 56,
            supportedVersions: [1]
        ) { cursor in
            var styles: [UInt8] = []
            styles.reserveCapacity(4)
            let planeIndex = try cursor.readUInt16(
                context: "\(contextPrefix) plane index"
            )
            let side = try cursor.readUInt8(context: "\(contextPrefix) side")
            let isOnNode = try cursor.readUInt8(
                context: "\(contextPrefix) on-node flag"
            )
            let firstSurfaceEdge = try cursor.readInt32(
                context: "\(contextPrefix) first surface edge"
            )
            let surfaceEdgeCount = try cursor.readInt16(
                context: "\(contextPrefix) surface edge count"
            )
            let textureInfoIndex = try cursor.readInt16(
                context: "\(contextPrefix) texinfo index"
            )
            let displacementInfoIndex = try cursor.readInt16(
                context: "\(contextPrefix) dispinfo index"
            )
            let surfaceFogVolumeID = try cursor.readInt16(
                context: "\(contextPrefix) fog volume ID"
            )
            for styleIndex in 0..<4 {
                styles.append(
                    try cursor.readUInt8(
                        context: "\(contextPrefix) light style \(styleIndex)"
                    )
                )
            }
            return SourceBSPFace(
                planeIndex: planeIndex,
                side: side,
                isOnNode: isOnNode,
                firstSurfaceEdge: firstSurfaceEdge,
                surfaceEdgeCount: surfaceEdgeCount,
                textureInfoIndex: textureInfoIndex,
                displacementInfoIndex: displacementInfoIndex,
                surfaceFogVolumeID: surfaceFogVolumeID,
                lightStyles: styles,
                lightOffset: try cursor.readInt32(
                    context: "\(contextPrefix) light offset"
                ),
                area: try cursor.readFloat32(context: "\(contextPrefix) area"),
                lightmapTextureMinsInLuxels: [
                    try cursor.readInt32(
                        context: "\(contextPrefix) lightmap minimum S"
                    ),
                    try cursor.readInt32(
                        context: "\(contextPrefix) lightmap minimum T"
                    )
                ],
                lightmapTextureSizeInLuxels: [
                    try cursor.readInt32(
                        context: "\(contextPrefix) lightmap size S"
                    ),
                    try cursor.readInt32(
                        context: "\(contextPrefix) lightmap size T"
                    )
                ],
                originalFace: try cursor.readInt32(
                    context: "\(contextPrefix) original face"
                ),
                primitiveCountAndShadowFlag: try cursor.readUInt16(
                    context: "\(contextPrefix) primitive count and shadow flag"
                ),
                firstPrimitiveID: try cursor.readUInt16(
                    context: "\(contextPrefix) first primitive ID"
                ),
                smoothingGroups: try cursor.readUInt32(
                    context: "\(contextPrefix) smoothing groups"
                )
            )
        }
    }

    private static func parseLighting(
        _ lump: SourceBSPLump
    ) throws -> SourceBSPLighting {
        try requireVersion(lump, supported: [1])
        guard lump.data.count.isMultiple(of: 4) else {
            throw SourceBSPError.invalidRecordByteCount(
                index: lump.descriptor.index,
                byteCount: lump.data.count,
                recordByteCount: 4
            )
        }
        return SourceBSPLighting(encodedSamples: lump.data)
    }

    private static func validateFaceReferences(
        _ faces: [SourceBSPFace],
        contextPrefix: String,
        planes: [SourceBSPPlane],
        textureInfo: [SourceBSPTextureInfo],
        surfaceEdges: [Int32]
    ) throws {
        for (index, face) in faces.enumerated() {
            guard Int(face.planeIndex) < planes.count else {
                throw SourceBSPError.invalidReference(
                    context: "\(contextPrefix) \(index) plane",
                    index: Int64(face.planeIndex),
                    availableCount: planes.count
                )
            }
            if face.textureInfoIndex != -1 {
                guard face.textureInfoIndex >= 0,
                      Int(face.textureInfoIndex) < textureInfo.count else {
                    throw SourceBSPError.invalidReference(
                        context: "\(contextPrefix) \(index) texinfo",
                        index: Int64(face.textureInfoIndex),
                        availableCount: textureInfo.count
                    )
                }
            }
            let first = Int64(face.firstSurfaceEdge)
            let count = Int64(face.surfaceEdgeCount)
            let (end, overflow) = first.addingReportingOverflow(count)
            guard first >= 0,
                  count >= 0,
                  !overflow,
                  end <= Int64(surfaceEdges.count) else {
                throw SourceBSPError.invalidReferenceRange(
                    context: "\(contextPrefix) \(index) surface edges",
                    first: first,
                    count: count,
                    availableCount: surfaceEdges.count
                )
            }
        }
    }

    private static func validateLightmapReferences(
        faces: [SourceBSPFace],
        contextPrefix: String,
        textureInfo: [SourceBSPTextureInfo],
        lighting: SourceBSPLighting
    ) throws {
        for (index, face) in faces.enumerated() where face.lightOffset != -1 {
            guard face.lightOffset >= 0,
                  face.lightOffset.isMultiple(of: 4) else {
                throw SourceBSPError.invalidValue(
                    context: "\(contextPrefix) \(index) light offset",
                    value: Int64(face.lightOffset)
                )
            }
            guard face.textureInfoIndex >= 0,
                  Int(face.textureInfoIndex) < textureInfo.count else {
                throw SourceBSPError.invalidReference(
                    context: "\(contextPrefix) \(index) lightmap texinfo",
                    index: Int64(face.textureInfoIndex),
                    availableCount: textureInfo.count
                )
            }
            guard face.lightmapTextureSizeInLuxels.count == 2,
                  face.lightmapTextureSizeInLuxels[0] >= 0,
                  face.lightmapTextureSizeInLuxels[1] >= 0 else {
                throw SourceBSPError.invalidValue(
                    context: "\(contextPrefix) \(index) lightmap size",
                    value: Int64(face.lightmapTextureSizeInLuxels.first ?? -1)
                )
            }
            let styleCount = Int64(face.lightStyles.prefix { $0 != 255 }.count)
            guard styleCount > 0 else {
                throw SourceBSPError.invalidValue(
                    context: "\(contextPrefix) \(index) light style count",
                    value: styleCount
                )
            }
            let width = Int64(face.lightmapTextureSizeInLuxels[0]) + 1
            let height = Int64(face.lightmapTextureSizeInLuxels[1]) + 1
            let info = textureInfo[Int(face.textureInfoIndex)]
            let bumpCount: Int64 = UInt32(bitPattern: info.flags) & 0x0800 == 0 ? 1 : 4
            let samples = width.multipliedReportingOverflow(by: height)
            let styledSamples = samples.partialValue.multipliedReportingOverflow(
                by: styleCount
            )
            let allSamples = styledSamples.partialValue.multipliedReportingOverflow(
                by: bumpCount
            )
            let bytes = allSamples.partialValue.multipliedReportingOverflow(by: 4)
            let first = Int64(face.lightOffset)
            let end = first.addingReportingOverflow(bytes.partialValue)
            guard !samples.overflow,
                  !styledSamples.overflow,
                  !allSamples.overflow,
                  !bytes.overflow,
                  !end.overflow,
                  end.partialValue <= Int64(lighting.byteCount) else {
                throw SourceBSPError.invalidReferenceRange(
                    context: "\(contextPrefix) \(index) lightmap bytes",
                    first: first,
                    count: bytes.partialValue,
                    availableCount: lighting.byteCount
                )
            }
        }
    }

    private static func parseRecords<Value>(
        _ lump: SourceBSPLump,
        recordByteCount: Int,
        supportedVersions: [Int32],
        parse: (inout SourceBSPByteReader) throws -> Value
    ) throws -> [Value] {
        try requireVersion(lump, supported: supportedVersions)
        guard !lump.data.isEmpty else { return [] }
        guard lump.data.count % recordByteCount == 0 else {
            throw SourceBSPError.invalidRecordByteCount(
                index: lump.descriptor.index,
                byteCount: lump.data.count,
                recordByteCount: recordByteCount
            )
        }

        let recordCount = lump.data.count / recordByteCount
        var result: [Value] = []
        result.reserveCapacity(recordCount)
        var cursor = SourceBSPByteReader(data: lump.data)
        for _ in 0..<recordCount {
            result.append(try parse(&cursor))
        }
        return result
    }

    private static func parseLeaves(_ lump: SourceBSPLump) throws -> [SourceBSPLeaf] {
        try requireUncompressed(lump)
        guard !lump.data.isEmpty else { return [] }
        let recordByteCount: Int
        switch lump.descriptor.version {
        case 0: recordByteCount = 56
        case 1: recordByteCount = 32
        default:
            throw SourceBSPError.unsupportedLumpVersion(
                index: lump.descriptor.index,
                actual: lump.descriptor.version,
                supported: [0, 1]
            )
        }

        return try parseRecords(
            lump,
            recordByteCount: recordByteCount,
            supportedVersions: [0, 1]
        ) { cursor in
            let contents = try cursor.readInt32(context: "leaf contents")
            let cluster = try cursor.readInt16(context: "leaf cluster")
            let areaAndFlags = try cursor.readUInt16(context: "leaf area and flags")
            let mins = try readShortVector3(&cursor, context: "leaf mins")
            let maxs = try readShortVector3(&cursor, context: "leaf maxs")
            let firstLeafFace = try cursor.readUInt16(context: "leaf first face")
            let leafFaceCount = try cursor.readUInt16(context: "leaf face count")
            let firstLeafBrush = try cursor.readUInt16(context: "leaf first brush")
            let leafBrushCount = try cursor.readUInt16(context: "leaf brush count")
            let leafWaterDataID = try cursor.readInt16(context: "leaf water data ID")

            var ambientLighting: [SourceBSPRGBExponent]?
            if lump.descriptor.version == 0 {
                var samples: [SourceBSPRGBExponent] = []
                samples.reserveCapacity(6)
                for sampleIndex in 0..<6 {
                    samples.append(
                        SourceBSPRGBExponent(
                            red: try cursor.readUInt8(context: "leaf ambient \(sampleIndex) red"),
                            green: try cursor.readUInt8(context: "leaf ambient \(sampleIndex) green"),
                            blue: try cursor.readUInt8(context: "leaf ambient \(sampleIndex) blue"),
                            exponent: try cursor.readInt8(
                                context: "leaf ambient \(sampleIndex) exponent"
                            )
                        )
                    )
                }
                ambientLighting = samples
            } else {
                ambientLighting = nil
            }
            try cursor.skip(2, context: "leaf alignment padding")

            return SourceBSPLeaf(
                formatVersion: lump.descriptor.version,
                contents: contents,
                cluster: cluster,
                areaAndFlags: areaAndFlags,
                mins: mins,
                maxs: maxs,
                firstLeafFace: firstLeafFace,
                leafFaceCount: leafFaceCount,
                firstLeafBrush: firstLeafBrush,
                leafBrushCount: leafBrushCount,
                leafWaterDataID: leafWaterDataID,
                ambientLighting: ambientLighting
            )
        }
    }

    private static func requireUncompressed(_ lump: SourceBSPLump) throws {
        guard lump.descriptor.isCompressed else { return }
        let hasLZMASignature = lump.data.count >= 4 &&
            lump.data.prefix(4).elementsEqual([0x4C, 0x5A, 0x4D, 0x41])
        throw SourceBSPError.unsupportedCompressedLump(
            index: lump.descriptor.index,
            declaredUncompressedSize: lump.descriptor.uncompressedSize,
            hasLZMASignature: hasLZMASignature
        )
    }

    private static func readVector3(
        _ reader: inout SourceBSPByteReader,
        context: String
    ) throws -> SourceBSPVector3 {
        SourceBSPVector3(
            x: try reader.readFloat32(context: "\(context) X"),
            y: try reader.readFloat32(context: "\(context) Y"),
            z: try reader.readFloat32(context: "\(context) Z")
        )
    }

    private static func readShortVector3(
        _ reader: inout SourceBSPByteReader,
        context: String
    ) throws -> SourceBSPShortVector3 {
        SourceBSPShortVector3(
            x: try reader.readInt16(context: "\(context) X"),
            y: try reader.readInt16(context: "\(context) Y"),
            z: try reader.readInt16(context: "\(context) Z")
        )
    }

    private static func readTextureVector(
        _ reader: inout SourceBSPByteReader,
        context: String
    ) throws -> SourceBSPTextureVector {
        SourceBSPTextureVector(
            x: try reader.readFloat32(context: "\(context) X"),
            y: try reader.readFloat32(context: "\(context) Y"),
            z: try reader.readFloat32(context: "\(context) Z"),
            offset: try reader.readFloat32(context: "\(context) offset")
        )
    }
}

private struct SourceBSPByteReader {
    let data: Data
    private(set) var offset = 0

    mutating func readUInt8(context: String) throws -> UInt8 {
        guard offset < data.count else {
            throw SourceBSPError.unexpectedEnd(context: context)
        }
        let value = data[data.index(data.startIndex, offsetBy: offset)]
        offset += 1
        return value
    }

    mutating func readInt8(context: String) throws -> Int8 {
        Int8(bitPattern: try readUInt8(context: context))
    }

    mutating func readUInt16(context: String) throws -> UInt16 {
        let byte0 = UInt16(try readUInt8(context: context))
        let byte1 = UInt16(try readUInt8(context: context))
        return byte0 | (byte1 << 8)
    }

    mutating func readInt16(context: String) throws -> Int16 {
        Int16(bitPattern: try readUInt16(context: context))
    }

    mutating func readUInt32(context: String) throws -> UInt32 {
        let byte0 = UInt32(try readUInt8(context: context))
        let byte1 = UInt32(try readUInt8(context: context))
        let byte2 = UInt32(try readUInt8(context: context))
        let byte3 = UInt32(try readUInt8(context: context))
        return byte0 | (byte1 << 8) | (byte2 << 16) | (byte3 << 24)
    }

    mutating func readInt32(context: String) throws -> Int32 {
        Int32(bitPattern: try readUInt32(context: context))
    }

    mutating func readFloat32(context: String) throws -> Float {
        Float(bitPattern: try readUInt32(context: context))
    }

    mutating func skip(_ byteCount: Int, context: String) throws {
        guard byteCount >= 0, offset <= data.count - byteCount else {
            throw SourceBSPError.unexpectedEnd(context: context)
        }
        offset += byteCount
    }
}

private struct SourceBSPEntityTextParser {
    private enum Token: Equatable {
        case open
        case close
        case string(String)
    }

    private let source: String
    private var index: String.Index

    init(_ source: String) {
        self.source = source
        index = source.startIndex
    }

    mutating func parse() throws -> [SourceBSPParsedEntity] {
        var result: [SourceBSPParsedEntity] = []
        while let token = try nextToken() {
            guard token == .open else {
                throw SourceBSPError.malformedEntityText(
                    context: "entity opening brace"
                )
            }
            var pairs: [SourceBSPEntityKeyValue] = []
            while true {
                guard let keyToken = try nextToken() else {
                    throw SourceBSPError.malformedEntityText(
                        context: "entity closing brace"
                    )
                }
                if keyToken == .close { break }
                guard case let .string(key) = keyToken,
                      case let .string(value)? = try nextToken() else {
                    throw SourceBSPError.malformedEntityText(
                        context: "entity key/value pair"
                    )
                }
                pairs.append(SourceBSPEntityKeyValue(key: key, value: value))
            }
            result.append(SourceBSPParsedEntity(keyValues: pairs))
        }
        return result
    }

    private mutating func nextToken() throws -> Token? {
        skipTrivia()
        guard index < source.endIndex else { return nil }
        let character = source[index]
        if character == "{" {
            source.formIndex(after: &index)
            return .open
        }
        if character == "}" {
            source.formIndex(after: &index)
            return .close
        }
        guard character == "\"" else {
            throw SourceBSPError.malformedEntityText(context: "quoted token")
        }
        source.formIndex(after: &index)
        var value = ""
        while index < source.endIndex {
            let current = source[index]
            source.formIndex(after: &index)
            if current == "\"" { return .string(value) }
            if current == "\\" {
                guard index < source.endIndex else {
                    throw SourceBSPError.malformedEntityText(
                        context: "quoted escape"
                    )
                }
                let escaped = source[index]
                source.formIndex(after: &index)
                switch escaped {
                case "n": value.append("\n")
                case "r": value.append("\r")
                case "t": value.append("\t")
                default: value.append(escaped)
                }
            } else {
                value.append(current)
            }
        }
        throw SourceBSPError.malformedEntityText(context: "quoted token terminator")
    }

    private mutating func skipTrivia() {
        while index < source.endIndex {
            if source[index].isWhitespace || source[index] == "\0" {
                source.formIndex(after: &index)
                continue
            }
            let next = source.index(after: index)
            if source[index] == "/",
               next < source.endIndex,
               source[next] == "/" {
                index = source.index(after: next)
                while index < source.endIndex,
                      source[index] != "\n",
                      source[index] != "\r" {
                    source.formIndex(after: &index)
                }
                continue
            }
            break
        }
    }
}
