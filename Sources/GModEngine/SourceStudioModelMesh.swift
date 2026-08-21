import Foundation

// Source format references (definitions only; this is an independent decoder):
// - Source SDK 2013 at c8f4c6351162fbff83bfa5a428d45d1e6eed3824
//   `src/public/studio.h`: studiohdr_t, mstudiobodyparts_t,
//   mstudiomodel_t, mstudiomesh_t, mstudiovertex_t, and vertexFileFixup_t.
// - The same revision's `src/public/optimize.h`:
//   OptimizedModel VTX v7 hierarchy and packed record layouts.
//
// This boundary decodes the root LOD only. That is the layout Source exposes
// before any lower-LOD selection. Material names, flex deltas, eyes, and
// special material operations remain explicit unsupported features instead of
// being approximated by renderer-specific substitutes.

public struct SourceStudioMeshDecodeBudget: Sendable, Equatable {
    public let maximumRootVertices: Int
    public let maximumBodyParts: Int
    public let maximumModels: Int
    public let maximumMeshes: Int
    public let maximumStripGroups: Int
    public let maximumDecodedVertices: Int
    public let maximumIndices: Int
    public let maximumStrips: Int
    public let maximumBoneStateChanges: Int

    public init(
        maximumRootVertices: Int,
        maximumBodyParts: Int,
        maximumModels: Int,
        maximumMeshes: Int,
        maximumStripGroups: Int,
        maximumDecodedVertices: Int,
        maximumIndices: Int,
        maximumStrips: Int,
        maximumBoneStateChanges: Int
    ) {
        self.maximumRootVertices = maximumRootVertices
        self.maximumBodyParts = maximumBodyParts
        self.maximumModels = maximumModels
        self.maximumMeshes = maximumMeshes
        self.maximumStripGroups = maximumStripGroups
        self.maximumDecodedVertices = maximumDecodedVertices
        self.maximumIndices = maximumIndices
        self.maximumStrips = maximumStrips
        self.maximumBoneStateChanges = maximumBoneStateChanges
    }
}

public enum SourceStudioMeshUnsupportedFeature: Sendable, Equatable {
    case vertexFlexes(bodyPart: Int, model: Int, mesh: Int, count: Int)
    case eyeballs(bodyPart: Int, model: Int, count: Int)
    case materialOperation(
        bodyPart: Int,
        model: Int,
        mesh: Int,
        type: Int32,
        parameter: Int32
    )
    case optimizedMeshFlags(bodyPart: Int, model: Int, mesh: Int, flags: UInt8)
    case flexedStripGroup(
        bodyPart: Int,
        model: Int,
        mesh: Int,
        stripGroup: Int,
        flags: UInt8
    )
}

public enum SourceStudioModelMeshDecodeError: Error, Sendable, Equatable,
    CustomStringConvertible
{
    case invalidBudget(field: String, value: Int)
    case invalidCount(field: String, value: Int32)
    case exceedsBudget(field: String, value: Int, cap: Int)
    case invalidOffset(field: String, value: Int32)
    case misalignedOffset(field: String, value: Int32, alignment: Int)
    case offsetOverflow(field: String, base: Int, offset: Int32)
    case outOfBounds(field: String, start: Int, byteCount: Int, length: Int)
    case unterminatedString(field: String, start: Int)
    case nonFiniteFloat(field: String, offset: Int)
    case hierarchyCountMismatch(field: String, mdl: Int, vtx: Int)
    case rootVertexCountMismatch(expected: Int, actual: Int)
    case invalidReference(field: String, value: Int, upperBound: Int)
    case invalidBoneCount(field: String, value: Int, maximum: Int)
    case invalidTopologyFlags(
        bodyPart: Int,
        model: Int,
        mesh: Int,
        stripGroup: Int,
        strip: Int,
        flags: UInt8
    )
    case unsupported(SourceStudioMeshUnsupportedFeature)

    public var description: String {
        switch self {
        case let .invalidBudget(field, value):
            return "invalid mesh decode budget \(field)=\(value)"
        case let .invalidCount(field, value):
            return "invalid \(field) count \(value)"
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
        case let .nonFiniteFloat(field, offset):
            return "\(field) contains a non-finite Float at byte \(offset)"
        case let .hierarchyCountMismatch(field, mdl, vtx):
            return "\(field) count differs between MDL (\(mdl)) and VTX (\(vtx))"
        case let .rootVertexCountMismatch(expected, actual):
            return "VVD root fixups produce \(actual) vertices; header declares \(expected)"
        case let .invalidReference(field, value, upperBound):
            return "\(field) reference \(value) is outside 0..<\(upperBound)"
        case let .invalidBoneCount(field, value, maximum):
            return "\(field) bone count \(value) exceeds \(maximum)"
        case let .invalidTopologyFlags(bodyPart, model, mesh, stripGroup, strip, flags):
            return "VTX topology flags \(flags) are invalid at \(bodyPart):\(model):\(mesh):\(stripGroup):\(strip)"
        case let .unsupported(feature):
            return "unsupported Studio mesh feature: \(feature)"
        }
    }
}

public struct SourceStudioTextureCoordinate: Sendable, Equatable, Hashable {
    public let u: Float
    public let v: Float

    public init(u: Float, v: Float) {
        self.u = u
        self.v = v
    }
}

public struct SourceStudioTangent: Sendable, Equatable, Hashable {
    public let x: Float
    public let y: Float
    public let z: Float
    public let w: Float

    public init(x: Float, y: Float, z: Float, w: Float) {
        self.x = x
        self.y = y
        self.z = z
        self.w = w
    }
}

public struct SourceStudioBoneInfluence: Sendable, Equatable, Hashable {
    public let boneIndex: Int
    public let weight: Float

    public init(boneIndex: Int, weight: Float) {
        self.boneIndex = boneIndex
        self.weight = weight
    }
}

/// The target-specific bone reference retained from VTX. `boneID` is signed
/// because the packed Source record uses `char`; it is deliberately not
/// reinterpreted as a canonical Studio bone when hardware skinning is active.
public struct SourceStudioOptimizedBoneReference: Sendable, Equatable, Hashable {
    public let weightSlot: Int
    public let boneID: Int8

    public init(weightSlot: Int, boneID: Int8) {
        self.weightSlot = weightSlot
        self.boneID = boneID
    }
}

public struct SourceStudioMeshVertexSnapshot: Sendable, Equatable {
    public let stripGroupVertexIndex: Int
    public let originalMeshVertexIndex: Int
    /// Index into the root-LOD vertex array after Source VVD fixups.
    public let rootLODVertexIndex: Int
    /// Index into the raw on-disk VVD vertex block.
    public let sourceVVDVertexIndex: Int
    public let position: SourceVector3
    public let normal: SourceVector3
    public let textureCoordinate: SourceStudioTextureCoordinate
    public let tangent: SourceStudioTangent?
    public let boneInfluences: [SourceStudioBoneInfluence]
    public let optimizedBoneReferences: [SourceStudioOptimizedBoneReference]
}

public struct SourceStudioMeshRange: Sendable, Equatable, Hashable {
    public let offset: Int
    public let count: Int

    public init(offset: Int, count: Int) {
        self.offset = offset
        self.count = count
    }
}

public enum SourceStudioMeshTopology: UInt8, Sendable, Equatable {
    case triangleList = 0x01
    case triangleStrip = 0x02
}

public struct SourceStudioBoneStateChangeSnapshot: Sendable, Equatable {
    public let hardwareBoneIndex: Int32
    public let newStudioBoneIndex: Int32
}

public struct SourceStudioStripSnapshot: Sendable, Equatable {
    public let index: Int
    public let topology: SourceStudioMeshTopology
    public let indexRange: SourceStudioMeshRange
    public let vertexRange: SourceStudioMeshRange
    public let boneCount: Int
    public let boneStateChanges: [SourceStudioBoneStateChangeSnapshot]
}

public struct SourceStudioStripGroupSnapshot: Sendable, Equatable {
    public let index: Int
    public let flags: UInt8
    public let vertices: [SourceStudioMeshVertexSnapshot]
    /// Raw VTX indices. Each value indexes `vertices`; strip ranges select
    /// deterministic subranges without changing the file's topology.
    public let indices: [UInt16]
    public let strips: [SourceStudioStripSnapshot]
}

public struct SourceStudioMeshSnapshot: Sendable, Equatable {
    public let index: Int
    public let materialIndex: Int32
    public let meshID: Int32
    public let center: SourceVector3
    public let rootLODVertexCount: Int
    public let stripGroups: [SourceStudioStripGroupSnapshot]
}

public struct SourceStudioSubmodelSnapshot: Sendable, Equatable {
    public let index: Int
    public let name: String
    public let type: Int32
    public let boundingRadius: Float
    public let rootLODVertexCount: Int
    public let meshes: [SourceStudioMeshSnapshot]
}

public struct SourceStudioBodyPartMeshSnapshot: Sendable, Equatable {
    public let index: Int
    public let name: String
    public let modelSelectionBase: Int32
    public let models: [SourceStudioSubmodelSnapshot]
}

/// Renderer-neutral, immutable root-LOD geometry. Hierarchy indices are kept
/// explicitly so model/bodygroup selection can remain Source-owned later.
public struct SourceStudioModelMeshSnapshot: Sendable, Equatable {
    public let checksum: Int32
    public let modelName: String
    public let lodIndex: Int
    public let bodyParts: [SourceStudioBodyPartMeshSnapshot]
}

public enum SourceStudioModelMeshDecoder {
    public static func decodeRootLOD(
        _ payload: SourceStudioImmutableRenderPayload,
        budget: SourceStudioMeshDecodeBudget
    ) throws -> SourceStudioModelMeshSnapshot {
        try validate(budget: budget)

        let mdl = MeshReader(payload.mdlData)
        let vvd = MeshReader(payload.vvdData)
        let vtx = MeshReader(payload.vtxData)
        var accounting = DecodeAccounting()

        let rootVertexCount = try requireBudget(
            payload.vvdHeader.lodVertexCounts[0],
            current: 0,
            cap: budget.maximumRootVertices,
            field: "VVD root vertices"
        )
        let rootToSource = try rootVertexMapping(
            reader: vvd,
            header: payload.vvdHeader,
            rootVertexCount: rootVertexCount
        )

        let mdlBodyPartCount = try mdl.count(at: 232, field: "studiohdr_t.numbodyparts")
        let vtxBodyPartCount = payload.vtxHeader.bodyPartCount
        guard mdlBodyPartCount == vtxBodyPartCount else {
            throw SourceStudioModelMeshDecodeError.hierarchyCountMismatch(
                field: "body parts",
                mdl: mdlBodyPartCount,
                vtx: vtxBodyPartCount
            )
        }
        accounting.bodyParts = try requireBudget(
            mdlBodyPartCount,
            current: accounting.bodyParts,
            cap: budget.maximumBodyParts,
            field: "body parts"
        )

        let mdlBodyPartBase = try mdl.table(
            base: 0,
            relativeOffset: mdl.int32(at: 236, field: "studiohdr_t.bodypartindex"),
            count: mdlBodyPartCount,
            stride: Layout.mdlBodyPart,
            field: "studiohdr_t.bodyparts"
        )
        let vtxBodyPartBase = try vtx.table(
            base: 0,
            relativeOffset: vtx.int32(at: 32, field: "FileHeader_t.bodyPartOffset"),
            count: vtxBodyPartCount,
            stride: Layout.vtxBodyPart,
            field: "FileHeader_t.bodyParts"
        )

        var bodyParts: [SourceStudioBodyPartMeshSnapshot] = []
        bodyParts.reserveCapacity(mdlBodyPartCount)
        for bodyPartIndex in 0..<mdlBodyPartCount {
            let mdlBody = mdlBodyPartBase + bodyPartIndex * Layout.mdlBodyPart
            let vtxBody = vtxBodyPartBase + bodyPartIndex * Layout.vtxBodyPart
            let prefix = "bodyPart[\(bodyPartIndex)]"
            let bodyName = try mdl.relativeCString(
                base: mdlBody,
                relativeOffset: mdl.int32(at: mdlBody, field: "\(prefix).sznameindex"),
                field: "\(prefix).name"
            )
            let mdlModelCount = try mdl.count(at: mdlBody + 4, field: "\(prefix).nummodels")
            let vtxModelCount = try vtx.count(at: vtxBody, field: "\(prefix).vtx.numModels")
            guard mdlModelCount == vtxModelCount else {
                throw SourceStudioModelMeshDecodeError.hierarchyCountMismatch(
                    field: "\(prefix).models",
                    mdl: mdlModelCount,
                    vtx: vtxModelCount
                )
            }
            accounting.models = try requireBudget(
                mdlModelCount,
                current: accounting.models,
                cap: budget.maximumModels,
                field: "models"
            )
            let mdlModelBase = try mdl.table(
                base: mdlBody,
                relativeOffset: mdl.int32(at: mdlBody + 12, field: "\(prefix).modelindex"),
                count: mdlModelCount,
                stride: Layout.mdlModel,
                field: "\(prefix).models"
            )
            let vtxModelBase = try vtx.table(
                base: vtxBody,
                relativeOffset: vtx.int32(at: vtxBody + 4, field: "\(prefix).vtx.modelOffset"),
                count: vtxModelCount,
                stride: Layout.vtxModel,
                field: "\(prefix).vtx.models"
            )

            var models: [SourceStudioSubmodelSnapshot] = []
            models.reserveCapacity(mdlModelCount)
            for modelIndex in 0..<mdlModelCount {
                models.append(try decodeModel(
                    bodyPartIndex: bodyPartIndex,
                    modelIndex: modelIndex,
                    mdlBase: mdlModelBase + modelIndex * Layout.mdlModel,
                    vtxBase: vtxModelBase + modelIndex * Layout.vtxModel,
                    payload: payload,
                    mdl: mdl,
                    vvd: vvd,
                    vtx: vtx,
                    rootToSource: rootToSource,
                    budget: budget,
                    accounting: &accounting
                ))
            }
            bodyParts.append(SourceStudioBodyPartMeshSnapshot(
                index: bodyPartIndex,
                name: bodyName,
                modelSelectionBase: try mdl.int32(at: mdlBody + 8, field: "\(prefix).base"),
                models: models
            ))
        }

        return SourceStudioModelMeshSnapshot(
            checksum: payload.model.header.checksum,
            modelName: payload.model.header.name,
            lodIndex: 0,
            bodyParts: bodyParts
        )
    }
}

private extension SourceStudioModelMeshDecoder {
    enum Layout {
        static let studioVertex = 48
        static let tangent = 16
        static let fixup = 12
        static let mdlBodyPart = 16
        static let mdlModel = 148
        static let mdlMesh = 116
        static let vtxBodyPart = 8
        static let vtxModel = 8
        static let vtxModelLOD = 12
        static let vtxMesh = 9
        static let vtxStripGroup = 25
        static let vtxVertex = 9
        static let vtxStrip = 27
        static let vtxBoneStateChange = 8
    }

    struct DecodeAccounting {
        var bodyParts = 0
        var models = 0
        var meshes = 0
        var stripGroups = 0
        var vertices = 0
        var indices = 0
        var strips = 0
        var boneStateChanges = 0

    }

    static func validate(budget: SourceStudioMeshDecodeBudget) throws {
        let fields = [
            ("maximumRootVertices", budget.maximumRootVertices),
            ("maximumBodyParts", budget.maximumBodyParts),
            ("maximumModels", budget.maximumModels),
            ("maximumMeshes", budget.maximumMeshes),
            ("maximumStripGroups", budget.maximumStripGroups),
            ("maximumDecodedVertices", budget.maximumDecodedVertices),
            ("maximumIndices", budget.maximumIndices),
            ("maximumStrips", budget.maximumStrips),
            ("maximumBoneStateChanges", budget.maximumBoneStateChanges)
        ]
        if let invalid = fields.first(where: { $0.1 < 0 }) {
            throw SourceStudioModelMeshDecodeError.invalidBudget(
                field: invalid.0,
                value: invalid.1
            )
        }
    }

    static func requireBudget(
        _ amount: Int,
        current: Int,
        cap: Int,
        field: String
    ) throws -> Int {
        let (next, overflow) = current.addingReportingOverflow(amount)
        guard amount >= 0, !overflow, next <= cap else {
            throw SourceStudioModelMeshDecodeError.exceedsBudget(
                field: field,
                value: overflow ? Int.max : next,
                cap: cap
            )
        }
        return next
    }

    static func rootVertexMapping(
        reader: MeshReader,
        header: SourceStudioVVDHeader,
        rootVertexCount: Int
    ) throws -> [Int] {
        guard header.fixupCount > 0 else { return Array(0..<rootVertexCount) }
        var mapping: [Int] = []
        mapping.reserveCapacity(rootVertexCount)
        for index in 0..<header.fixupCount {
            let base = header.fixupTableStart + index * Layout.fixup
            let lod = try reader.int32(at: base, field: "vertexFileFixup_t[\(index)].lod")
            let source = try reader.count(
                at: base + 4,
                field: "vertexFileFixup_t[\(index)].sourceVertexID"
            )
            let count = try reader.count(
                at: base + 8,
                field: "vertexFileFixup_t[\(index)].numVertexes"
            )
            if lod >= 0 {
                let end = try reader.checkedEnd(
                    start: source,
                    count: count,
                    field: "vertexFileFixup_t[\(index)].vertices"
                )
                guard end <= rootVertexCount else {
                    throw SourceStudioModelMeshDecodeError.invalidReference(
                        field: "vertexFileFixup_t[\(index)].source vertices",
                        value: end,
                        upperBound: rootVertexCount + 1
                    )
                }
                mapping.append(contentsOf: source..<end)
            }
        }
        guard mapping.count == rootVertexCount else {
            throw SourceStudioModelMeshDecodeError.rootVertexCountMismatch(
                expected: rootVertexCount,
                actual: mapping.count
            )
        }
        return mapping
    }

    static func decodeModel(
        bodyPartIndex: Int,
        modelIndex: Int,
        mdlBase: Int,
        vtxBase: Int,
        payload: SourceStudioImmutableRenderPayload,
        mdl: MeshReader,
        vvd: MeshReader,
        vtx: MeshReader,
        rootToSource: [Int],
        budget: SourceStudioMeshDecodeBudget,
        accounting: inout DecodeAccounting
    ) throws -> SourceStudioSubmodelSnapshot {
        let prefix = "bodyPart[\(bodyPartIndex)].model[\(modelIndex)]"
        let modelName = try mdl.fixedCString(
            at: mdlBase,
            byteCount: 64,
            field: "\(prefix).name"
        )
        let mdlMeshCount = try mdl.count(at: mdlBase + 72, field: "\(prefix).nummeshes")
        let modelVertexCount = try mdl.count(at: mdlBase + 80, field: "\(prefix).numvertices")
        let modelVertexByteOffset = try mdl.int32(at: mdlBase + 84, field: "\(prefix).vertexindex")
        let modelTangentByteOffset = try mdl.int32(at: mdlBase + 88, field: "\(prefix).tangentsindex")
        let eyeballCount = try mdl.count(at: mdlBase + 100, field: "\(prefix).numeyeballs")
        if eyeballCount > 0 {
            throw SourceStudioModelMeshDecodeError.unsupported(.eyeballs(
                bodyPart: bodyPartIndex,
                model: modelIndex,
                count: eyeballCount
            ))
        }
        guard modelVertexByteOffset >= 0 else {
            throw SourceStudioModelMeshDecodeError.invalidOffset(
                field: "\(prefix).vertexindex",
                value: modelVertexByteOffset
            )
        }
        guard modelVertexByteOffset % Int32(Layout.studioVertex) == 0 else {
            throw SourceStudioModelMeshDecodeError.misalignedOffset(
                field: "\(prefix).vertexindex",
                value: modelVertexByteOffset,
                alignment: Layout.studioVertex
            )
        }
        guard modelTangentByteOffset >= 0 else {
            throw SourceStudioModelMeshDecodeError.invalidOffset(
                field: "\(prefix).tangentsindex",
                value: modelTangentByteOffset
            )
        }
        guard modelTangentByteOffset % Int32(Layout.tangent) == 0 else {
            throw SourceStudioModelMeshDecodeError.misalignedOffset(
                field: "\(prefix).tangentsindex",
                value: modelTangentByteOffset,
                alignment: Layout.tangent
            )
        }

        let vtxLODCount = try vtx.count(at: vtxBase, field: "\(prefix).vtx.numLODs")
        guard vtxLODCount == payload.vtxHeader.lodCount else {
            throw SourceStudioModelMeshDecodeError.hierarchyCountMismatch(
                field: "\(prefix).LODs",
                mdl: payload.vtxHeader.lodCount,
                vtx: vtxLODCount
            )
        }
        let lodBase = try vtx.table(
            base: vtxBase,
            relativeOffset: vtx.int32(at: vtxBase + 4, field: "\(prefix).vtx.lodOffset"),
            count: vtxLODCount,
            stride: Layout.vtxModelLOD,
            field: "\(prefix).vtx.LODs"
        )
        let vtxMeshCount = try vtx.count(at: lodBase, field: "\(prefix).vtx.LOD[0].numMeshes")
        guard mdlMeshCount == vtxMeshCount else {
            throw SourceStudioModelMeshDecodeError.hierarchyCountMismatch(
                field: "\(prefix).meshes",
                mdl: mdlMeshCount,
                vtx: vtxMeshCount
            )
        }
        accounting.meshes = try requireBudget(
            mdlMeshCount,
            current: accounting.meshes,
            cap: budget.maximumMeshes,
            field: "meshes"
        )
        let mdlMeshBase = try mdl.table(
            base: mdlBase,
            relativeOffset: mdl.int32(at: mdlBase + 76, field: "\(prefix).meshindex"),
            count: mdlMeshCount,
            stride: Layout.mdlMesh,
            field: "\(prefix).meshes"
        )
        let vtxMeshBase = try vtx.table(
            base: lodBase,
            relativeOffset: vtx.int32(at: lodBase + 4, field: "\(prefix).vtx.LOD[0].meshOffset"),
            count: vtxMeshCount,
            stride: Layout.vtxMesh,
            field: "\(prefix).vtx.LOD[0].meshes"
        )

        var meshes: [SourceStudioMeshSnapshot] = []
        meshes.reserveCapacity(mdlMeshCount)
        for meshIndex in 0..<mdlMeshCount {
            meshes.append(try decodeMesh(
                bodyPartIndex: bodyPartIndex,
                modelIndex: modelIndex,
                meshIndex: meshIndex,
                mdlModelBase: mdlBase,
                mdlBase: mdlMeshBase + meshIndex * Layout.mdlMesh,
                vtxBase: vtxMeshBase + meshIndex * Layout.vtxMesh,
                modelVertexCount: modelVertexCount,
                modelVertexStart: Int(modelVertexByteOffset) / Layout.studioVertex,
                modelTangentStart: Int(modelTangentByteOffset) / Layout.tangent,
                payload: payload,
                mdl: mdl,
                vvd: vvd,
                vtx: vtx,
                rootToSource: rootToSource,
                budget: budget,
                accounting: &accounting
            ))
        }

        return SourceStudioSubmodelSnapshot(
            index: modelIndex,
            name: modelName,
            type: try mdl.int32(at: mdlBase + 64, field: "\(prefix).type"),
            boundingRadius: try mdl.float(at: mdlBase + 68, field: "\(prefix).boundingradius"),
            rootLODVertexCount: modelVertexCount,
            meshes: meshes
        )
    }

    static func decodeMesh(
        bodyPartIndex: Int,
        modelIndex: Int,
        meshIndex: Int,
        mdlModelBase: Int,
        mdlBase: Int,
        vtxBase: Int,
        modelVertexCount: Int,
        modelVertexStart: Int,
        modelTangentStart: Int,
        payload: SourceStudioImmutableRenderPayload,
        mdl: MeshReader,
        vvd: MeshReader,
        vtx: MeshReader,
        rootToSource: [Int],
        budget: SourceStudioMeshDecodeBudget,
        accounting: inout DecodeAccounting
    ) throws -> SourceStudioMeshSnapshot {
        let prefix = "bodyPart[\(bodyPartIndex)].model[\(modelIndex)].mesh[\(meshIndex)]"
        let modelBackOffset = try mdl.int32(at: mdlBase + 4, field: "\(prefix).modelindex")
        let modelBack = try mdl.relative(base: mdlBase, offset: modelBackOffset, field: "\(prefix).modelindex")
        guard modelBack == mdlModelBase else {
            throw SourceStudioModelMeshDecodeError.invalidReference(
                field: "\(prefix).modelindex",
                value: modelBack,
                upperBound: mdl.length
            )
        }
        let meshVertexCount = try mdl.count(at: mdlBase + 8, field: "\(prefix).numvertices")
        let meshVertexOffset = try mdl.count(at: mdlBase + 12, field: "\(prefix).vertexoffset")
        let meshVertexEnd = try mdl.checkedEnd(
            start: meshVertexOffset,
            count: meshVertexCount,
            field: "\(prefix).vertices"
        )
        guard meshVertexEnd <= modelVertexCount else {
            throw SourceStudioModelMeshDecodeError.invalidReference(
                field: "\(prefix).vertices",
                value: meshVertexEnd,
                upperBound: modelVertexCount + 1
            )
        }
        let flexCount = try mdl.count(at: mdlBase + 16, field: "\(prefix).numflexes")
        if flexCount > 0 {
            throw SourceStudioModelMeshDecodeError.unsupported(.vertexFlexes(
                bodyPart: bodyPartIndex,
                model: modelIndex,
                mesh: meshIndex,
                count: flexCount
            ))
        }
        let materialType = try mdl.int32(at: mdlBase + 24, field: "\(prefix).materialtype")
        let materialParameter = try mdl.int32(at: mdlBase + 28, field: "\(prefix).materialparam")
        if materialType != 0 || materialParameter != 0 {
            throw SourceStudioModelMeshDecodeError.unsupported(.materialOperation(
                bodyPart: bodyPartIndex,
                model: modelIndex,
                mesh: meshIndex,
                type: materialType,
                parameter: materialParameter
            ))
        }

        let stripGroupCount = try vtx.count(at: vtxBase, field: "\(prefix).vtx.numStripGroups")
        let meshFlags = try vtx.uint8(at: vtxBase + 8, field: "\(prefix).vtx.flags")
        if meshFlags != 0 {
            throw SourceStudioModelMeshDecodeError.unsupported(.optimizedMeshFlags(
                bodyPart: bodyPartIndex,
                model: modelIndex,
                mesh: meshIndex,
                flags: meshFlags
            ))
        }
        accounting.stripGroups = try requireBudget(
            stripGroupCount,
            current: accounting.stripGroups,
            cap: budget.maximumStripGroups,
            field: "strip groups"
        )
        let stripGroupBase = try vtx.table(
            base: vtxBase,
            relativeOffset: vtx.int32(at: vtxBase + 4, field: "\(prefix).vtx.stripGroupOffset"),
            count: stripGroupCount,
            stride: Layout.vtxStripGroup,
            field: "\(prefix).vtx.stripGroups"
        )
        var groups: [SourceStudioStripGroupSnapshot] = []
        groups.reserveCapacity(stripGroupCount)
        for groupIndex in 0..<stripGroupCount {
            groups.append(try decodeStripGroup(
                bodyPartIndex: bodyPartIndex,
                modelIndex: modelIndex,
                meshIndex: meshIndex,
                groupIndex: groupIndex,
                vtxBase: stripGroupBase + groupIndex * Layout.vtxStripGroup,
                meshVertexCount: meshVertexCount,
                rootVertexStart: modelVertexStart + meshVertexOffset,
                rootTangentStart: modelTangentStart + meshVertexOffset,
                payload: payload,
                vvd: vvd,
                vtx: vtx,
                rootToSource: rootToSource,
                budget: budget,
                accounting: &accounting
            ))
        }
        return SourceStudioMeshSnapshot(
            index: meshIndex,
            materialIndex: try mdl.int32(at: mdlBase, field: "\(prefix).material"),
            meshID: try mdl.int32(at: mdlBase + 32, field: "\(prefix).meshid"),
            center: try mdl.vector(at: mdlBase + 36, field: "\(prefix).center"),
            rootLODVertexCount: meshVertexCount,
            stripGroups: groups
        )
    }

    static func decodeStripGroup(
        bodyPartIndex: Int,
        modelIndex: Int,
        meshIndex: Int,
        groupIndex: Int,
        vtxBase: Int,
        meshVertexCount: Int,
        rootVertexStart: Int,
        rootTangentStart: Int,
        payload: SourceStudioImmutableRenderPayload,
        vvd: MeshReader,
        vtx: MeshReader,
        rootToSource: [Int],
        budget: SourceStudioMeshDecodeBudget,
        accounting: inout DecodeAccounting
    ) throws -> SourceStudioStripGroupSnapshot {
        let prefix = "bodyPart[\(bodyPartIndex)].model[\(modelIndex)].mesh[\(meshIndex)].stripGroup[\(groupIndex)]"
        let vertexCount = try vtx.count(at: vtxBase, field: "\(prefix).numVerts")
        let indexCount = try vtx.count(at: vtxBase + 8, field: "\(prefix).numIndices")
        let stripCount = try vtx.count(at: vtxBase + 16, field: "\(prefix).numStrips")
        let flags = try vtx.uint8(at: vtxBase + 24, field: "\(prefix).flags")
        if flags & 0x05 != 0 {
            throw SourceStudioModelMeshDecodeError.unsupported(.flexedStripGroup(
                bodyPart: bodyPartIndex,
                model: modelIndex,
                mesh: meshIndex,
                stripGroup: groupIndex,
                flags: flags
            ))
        }
        if flags & ~UInt8(0x07) != 0 {
            throw SourceStudioModelMeshDecodeError.unsupported(.flexedStripGroup(
                bodyPart: bodyPartIndex,
                model: modelIndex,
                mesh: meshIndex,
                stripGroup: groupIndex,
                flags: flags
            ))
        }
        accounting.vertices = try requireBudget(
            vertexCount,
            current: accounting.vertices,
            cap: budget.maximumDecodedVertices,
            field: "decoded vertices"
        )
        accounting.indices = try requireBudget(
            indexCount,
            current: accounting.indices,
            cap: budget.maximumIndices,
            field: "indices"
        )
        accounting.strips = try requireBudget(
            stripCount,
            current: accounting.strips,
            cap: budget.maximumStrips,
            field: "strips"
        )
        let vertexBase = try vtx.table(
            base: vtxBase,
            relativeOffset: vtx.int32(at: vtxBase + 4, field: "\(prefix).vertOffset"),
            count: vertexCount,
            stride: Layout.vtxVertex,
            field: "\(prefix).vertices"
        )
        let indexBase = try vtx.table(
            base: vtxBase,
            relativeOffset: vtx.int32(at: vtxBase + 12, field: "\(prefix).indexOffset"),
            count: indexCount,
            stride: MemoryLayout<UInt16>.size,
            field: "\(prefix).indices"
        )
        let stripBase = try vtx.table(
            base: vtxBase,
            relativeOffset: vtx.int32(at: vtxBase + 20, field: "\(prefix).stripOffset"),
            count: stripCount,
            stride: Layout.vtxStrip,
            field: "\(prefix).strips"
        )

        var vertices: [SourceStudioMeshVertexSnapshot] = []
        vertices.reserveCapacity(vertexCount)
        for vertexIndex in 0..<vertexCount {
            let base = vertexBase + vertexIndex * Layout.vtxVertex
            let originalMeshVertex = Int(try vtx.uint16(
                at: base + 4,
                field: "\(prefix).vertex[\(vertexIndex)].origMeshVertID"
            ))
            guard originalMeshVertex < meshVertexCount else {
                throw SourceStudioModelMeshDecodeError.invalidReference(
                    field: "\(prefix).vertex[\(vertexIndex)].origMeshVertID",
                    value: originalMeshVertex,
                    upperBound: meshVertexCount
                )
            }
            let rootVertexIndex = rootVertexStart + originalMeshVertex
            let rootTangentIndex = rootTangentStart + originalMeshVertex
            guard rootVertexIndex >= 0, rootVertexIndex < rootToSource.count else {
                throw SourceStudioModelMeshDecodeError.invalidReference(
                    field: "\(prefix).vertex[\(vertexIndex)].rootLODVertex",
                    value: rootVertexIndex,
                    upperBound: rootToSource.count
                )
            }
            guard rootTangentIndex >= 0, rootTangentIndex < rootToSource.count else {
                throw SourceStudioModelMeshDecodeError.invalidReference(
                    field: "\(prefix).vertex[\(vertexIndex)].rootLODTangent",
                    value: rootTangentIndex,
                    upperBound: rootToSource.count
                )
            }
            let sourceVertexIndex = rootToSource[rootVertexIndex]
            let sourceTangentIndex = rootToSource[rootTangentIndex]
            let sourceVertexBase = payload.vvdHeader.vertexDataStart
                + sourceVertexIndex * Layout.studioVertex
            let canonicalBoneCount = Int(try vvd.uint8(
                at: sourceVertexBase + 15,
                field: "VVD.vertex[\(sourceVertexIndex)].boneWeights.numbones"
            ))
            guard canonicalBoneCount <= 3 else {
                throw SourceStudioModelMeshDecodeError.invalidBoneCount(
                    field: "VVD.vertex[\(sourceVertexIndex)]",
                    value: canonicalBoneCount,
                    maximum: 3
                )
            }
            var influences: [SourceStudioBoneInfluence] = []
            influences.reserveCapacity(canonicalBoneCount)
            for influenceIndex in 0..<canonicalBoneCount {
                let boneIndex = Int(try vvd.uint8(
                    at: sourceVertexBase + 12 + influenceIndex,
                    field: "VVD.vertex[\(sourceVertexIndex)].bone[\(influenceIndex)]"
                ))
                guard boneIndex < payload.model.bones.count else {
                    throw SourceStudioModelMeshDecodeError.invalidReference(
                        field: "VVD.vertex[\(sourceVertexIndex)].bone[\(influenceIndex)]",
                        value: boneIndex,
                        upperBound: payload.model.bones.count
                    )
                }
                influences.append(SourceStudioBoneInfluence(
                    boneIndex: boneIndex,
                    weight: try vvd.float(
                        at: sourceVertexBase + influenceIndex * 4,
                        field: "VVD.vertex[\(sourceVertexIndex)].weight[\(influenceIndex)]"
                    )
                ))
            }

            let optimizedBoneCount = Int(try vtx.uint8(
                at: base + 3,
                field: "\(prefix).vertex[\(vertexIndex)].numBones"
            ))
            guard optimizedBoneCount <= payload.vtxHeader.maximumBonesPerVertex,
                  optimizedBoneCount <= 3 else {
                throw SourceStudioModelMeshDecodeError.invalidBoneCount(
                    field: "\(prefix).vertex[\(vertexIndex)]",
                    value: optimizedBoneCount,
                    maximum: min(payload.vtxHeader.maximumBonesPerVertex, 3)
                )
            }
            var optimizedBones: [SourceStudioOptimizedBoneReference] = []
            optimizedBones.reserveCapacity(optimizedBoneCount)
            for optimizedIndex in 0..<optimizedBoneCount {
                let weightSlot = Int(try vtx.uint8(
                    at: base + optimizedIndex,
                    field: "\(prefix).vertex[\(vertexIndex)].boneWeightIndex[\(optimizedIndex)]"
                ))
                guard weightSlot < canonicalBoneCount else {
                    throw SourceStudioModelMeshDecodeError.invalidReference(
                        field: "\(prefix).vertex[\(vertexIndex)].boneWeightIndex[\(optimizedIndex)]",
                        value: weightSlot,
                        upperBound: canonicalBoneCount
                    )
                }
                optimizedBones.append(SourceStudioOptimizedBoneReference(
                    weightSlot: weightSlot,
                    boneID: try vtx.int8(
                        at: base + 6 + optimizedIndex,
                        field: "\(prefix).vertex[\(vertexIndex)].boneID[\(optimizedIndex)]"
                    )
                ))
            }
            let tangent: SourceStudioTangent?
            if let tangentStart = payload.vvdHeader.tangentDataStart {
                let tangentBase = tangentStart + sourceTangentIndex * Layout.tangent
                tangent = SourceStudioTangent(
                    x: try vvd.float(at: tangentBase, field: "VVD.tangent[\(sourceTangentIndex)].x"),
                    y: try vvd.float(at: tangentBase + 4, field: "VVD.tangent[\(sourceTangentIndex)].y"),
                    z: try vvd.float(at: tangentBase + 8, field: "VVD.tangent[\(sourceTangentIndex)].z"),
                    w: try vvd.float(at: tangentBase + 12, field: "VVD.tangent[\(sourceTangentIndex)].w")
                )
            } else {
                tangent = nil
            }
            vertices.append(SourceStudioMeshVertexSnapshot(
                stripGroupVertexIndex: vertexIndex,
                originalMeshVertexIndex: originalMeshVertex,
                rootLODVertexIndex: rootVertexIndex,
                sourceVVDVertexIndex: sourceVertexIndex,
                position: try vvd.vector(
                    at: sourceVertexBase + 16,
                    field: "VVD.vertex[\(sourceVertexIndex)].position"
                ),
                normal: try vvd.vector(
                    at: sourceVertexBase + 28,
                    field: "VVD.vertex[\(sourceVertexIndex)].normal"
                ),
                textureCoordinate: SourceStudioTextureCoordinate(
                    u: try vvd.float(
                        at: sourceVertexBase + 40,
                        field: "VVD.vertex[\(sourceVertexIndex)].texcoord.u"
                    ),
                    v: try vvd.float(
                        at: sourceVertexBase + 44,
                        field: "VVD.vertex[\(sourceVertexIndex)].texcoord.v"
                    )
                ),
                tangent: tangent,
                boneInfluences: influences,
                optimizedBoneReferences: optimizedBones
            ))
        }

        var indices: [UInt16] = []
        indices.reserveCapacity(indexCount)
        for index in 0..<indexCount {
            let value = try vtx.uint16(
                at: indexBase + index * 2,
                field: "\(prefix).index[\(index)]"
            )
            guard Int(value) < vertexCount else {
                throw SourceStudioModelMeshDecodeError.invalidReference(
                    field: "\(prefix).index[\(index)]",
                    value: Int(value),
                    upperBound: vertexCount
                )
            }
            indices.append(value)
        }

        var strips: [SourceStudioStripSnapshot] = []
        strips.reserveCapacity(stripCount)
        for stripIndex in 0..<stripCount {
            strips.append(try decodeStrip(
                bodyPartIndex: bodyPartIndex,
                modelIndex: modelIndex,
                meshIndex: meshIndex,
                groupIndex: groupIndex,
                stripIndex: stripIndex,
                base: stripBase + stripIndex * Layout.vtxStrip,
                groupVertexCount: vertexCount,
                groupIndexCount: indexCount,
                maximumBonesPerStrip: payload.vtxHeader.maximumBonesPerStrip,
                studioBoneCount: payload.model.bones.count,
                vtx: vtx,
                budget: budget,
                accounting: &accounting
            ))
        }
        return SourceStudioStripGroupSnapshot(
            index: groupIndex,
            flags: flags,
            vertices: vertices,
            indices: indices,
            strips: strips
        )
    }

    static func decodeStrip(
        bodyPartIndex: Int,
        modelIndex: Int,
        meshIndex: Int,
        groupIndex: Int,
        stripIndex: Int,
        base: Int,
        groupVertexCount: Int,
        groupIndexCount: Int,
        maximumBonesPerStrip: Int,
        studioBoneCount: Int,
        vtx: MeshReader,
        budget: SourceStudioMeshDecodeBudget,
        accounting: inout DecodeAccounting
    ) throws -> SourceStudioStripSnapshot {
        let prefix = "bodyPart[\(bodyPartIndex)].model[\(modelIndex)].mesh[\(meshIndex)].stripGroup[\(groupIndex)].strip[\(stripIndex)]"
        let indexCount = try vtx.count(at: base, field: "\(prefix).numIndices")
        let indexOffset = try vtx.count(at: base + 4, field: "\(prefix).indexOffset")
        let vertexCount = try vtx.count(at: base + 8, field: "\(prefix).numVerts")
        let vertexOffset = try vtx.count(at: base + 12, field: "\(prefix).vertOffset")
        let indexEnd = try vtx.checkedEnd(
            start: indexOffset,
            count: indexCount,
            field: "\(prefix).indices"
        )
        guard indexEnd <= groupIndexCount else {
            throw SourceStudioModelMeshDecodeError.invalidReference(
                field: "\(prefix).indices",
                value: indexEnd,
                upperBound: groupIndexCount + 1
            )
        }
        let vertexEnd = try vtx.checkedEnd(
            start: vertexOffset,
            count: vertexCount,
            field: "\(prefix).vertices"
        )
        guard vertexEnd <= groupVertexCount else {
            throw SourceStudioModelMeshDecodeError.invalidReference(
                field: "\(prefix).vertices",
                value: vertexEnd,
                upperBound: groupVertexCount + 1
            )
        }
        let flags = try vtx.uint8(at: base + 18, field: "\(prefix).flags")
        guard let topology = SourceStudioMeshTopology(rawValue: flags), flags == topology.rawValue else {
            throw SourceStudioModelMeshDecodeError.invalidTopologyFlags(
                bodyPart: bodyPartIndex,
                model: modelIndex,
                mesh: meshIndex,
                stripGroup: groupIndex,
                strip: stripIndex,
                flags: flags
            )
        }
        let boneCount = Int(try vtx.int16(at: base + 16, field: "\(prefix).numBones"))
        guard boneCount >= 0, boneCount <= maximumBonesPerStrip else {
            throw SourceStudioModelMeshDecodeError.invalidBoneCount(
                field: prefix,
                value: boneCount,
                maximum: maximumBonesPerStrip
            )
        }
        let changeCount = try vtx.count(at: base + 19, field: "\(prefix).numBoneStateChanges")
        accounting.boneStateChanges = try requireBudget(
            changeCount,
            current: accounting.boneStateChanges,
            cap: budget.maximumBoneStateChanges,
            field: "bone state changes"
        )
        let changeBase = try vtx.table(
            base: base,
            relativeOffset: vtx.int32(at: base + 23, field: "\(prefix).boneStateChangeOffset"),
            count: changeCount,
            stride: Layout.vtxBoneStateChange,
            field: "\(prefix).boneStateChanges"
        )
        var changes: [SourceStudioBoneStateChangeSnapshot] = []
        changes.reserveCapacity(changeCount)
        for index in 0..<changeCount {
            let record = changeBase + index * Layout.vtxBoneStateChange
            let hardwareBoneIndex = try vtx.int32(
                at: record,
                field: "\(prefix).boneStateChange[\(index)].hardwareID"
            )
            guard hardwareBoneIndex >= 0,
                  hardwareBoneIndex < Int32(maximumBonesPerStrip) else {
                throw SourceStudioModelMeshDecodeError.invalidReference(
                    field: "\(prefix).boneStateChange[\(index)].hardwareID",
                    value: Int(hardwareBoneIndex),
                    upperBound: maximumBonesPerStrip
                )
            }
            let newStudioBoneIndex = try vtx.int32(
                at: record + 4,
                field: "\(prefix).boneStateChange[\(index)].newBoneID"
            )
            guard newStudioBoneIndex >= 0,
                  newStudioBoneIndex < Int32(studioBoneCount) else {
                throw SourceStudioModelMeshDecodeError.invalidReference(
                    field: "\(prefix).boneStateChange[\(index)].newBoneID",
                    value: Int(newStudioBoneIndex),
                    upperBound: studioBoneCount
                )
            }
            changes.append(SourceStudioBoneStateChangeSnapshot(
                hardwareBoneIndex: hardwareBoneIndex,
                newStudioBoneIndex: newStudioBoneIndex
            ))
        }
        return SourceStudioStripSnapshot(
            index: stripIndex,
            topology: topology,
            indexRange: SourceStudioMeshRange(offset: indexOffset, count: indexCount),
            vertexRange: SourceStudioMeshRange(offset: vertexOffset, count: vertexCount),
            boneCount: boneCount,
            boneStateChanges: changes
        )
    }

}

private struct MeshReader {
    let data: Data
    var length: Int { data.count }

    init(_ data: Data) {
        self.data = data
    }

    func uint8(at offset: Int, field: String) throws -> UInt8 {
        try require(start: offset, byteCount: 1, field: field)
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in raw[offset] }
    }

    func int8(at offset: Int, field: String) throws -> Int8 {
        Int8(bitPattern: try uint8(at: offset, field: field))
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

    func float(at offset: Int, field: String) throws -> Float {
        let value = Float(bitPattern: try uint32(at: offset, field: field))
        guard value.isFinite else {
            throw SourceStudioModelMeshDecodeError.nonFiniteFloat(
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

    func count(at offset: Int, field: String) throws -> Int {
        let raw = try int32(at: offset, field: field)
        guard raw >= 0 else {
            throw SourceStudioModelMeshDecodeError.invalidCount(field: field, value: raw)
        }
        return Int(raw)
    }

    func fixedCString(at offset: Int, byteCount: Int, field: String) throws -> String {
        try require(start: offset, byteCount: byteCount, field: field)
        let end = try firstNUL(in: offset..<(offset + byteCount), field: field)
        return String(decoding: data[offset..<end], as: UTF8.self)
    }

    func relativeCString(
        base: Int,
        relativeOffset: Int32,
        field: String
    ) throws -> String {
        guard relativeOffset != 0 else {
            throw SourceStudioModelMeshDecodeError.invalidOffset(
                field: field,
                value: relativeOffset
            )
        }
        let start = try relative(base: base, offset: relativeOffset, field: field)
        guard start >= 0, start < length else {
            throw SourceStudioModelMeshDecodeError.outOfBounds(
                field: field,
                start: start,
                byteCount: 1,
                length: length
            )
        }
        let end = try firstNUL(in: start..<length, field: field)
        return String(decoding: data[start..<end], as: UTF8.self)
    }

    func table(
        base: Int,
        relativeOffset: Int32,
        count: Int,
        stride: Int,
        field: String
    ) throws -> Int {
        guard count >= 0, stride > 0 else {
            throw SourceStudioModelMeshDecodeError.invalidCount(
                field: field,
                value: Int32(clamping: count)
            )
        }
        if count == 0 { return base }
        guard relativeOffset != 0 else {
            throw SourceStudioModelMeshDecodeError.invalidOffset(
                field: field,
                value: relativeOffset
            )
        }
        let start = try relative(base: base, offset: relativeOffset, field: field)
        let (byteCount, overflow) = count.multipliedReportingOverflow(by: stride)
        guard !overflow else {
            throw SourceStudioModelMeshDecodeError.outOfBounds(
                field: field,
                start: start,
                byteCount: Int.max,
                length: length
            )
        }
        try require(start: start, byteCount: byteCount, field: field)
        return start
    }

    func relative(base: Int, offset: Int32, field: String) throws -> Int {
        let (result, overflow) = base.addingReportingOverflow(Int(offset))
        guard !overflow else {
            throw SourceStudioModelMeshDecodeError.offsetOverflow(
                field: field,
                base: base,
                offset: offset
            )
        }
        return result
    }

    func checkedEnd(start: Int, count: Int, field: String) throws -> Int {
        let (end, overflow) = start.addingReportingOverflow(count)
        guard start >= 0, count >= 0, !overflow else {
            throw SourceStudioModelMeshDecodeError.outOfBounds(
                field: field,
                start: start,
                byteCount: count,
                length: length
            )
        }
        return end
    }

    private func firstNUL(
        in range: Range<Int>,
        field: String
    ) throws -> Int {
        for index in range where data[index] == 0 { return index }
        throw SourceStudioModelMeshDecodeError.unterminatedString(
            field: field,
            start: range.lowerBound
        )
    }

    private func require(start: Int, byteCount: Int, field: String) throws {
        let (end, overflow) = start.addingReportingOverflow(byteCount)
        guard start >= 0, byteCount >= 0, !overflow, end <= length else {
            throw SourceStudioModelMeshDecodeError.outOfBounds(
                field: field,
                start: start,
                byteCount: byteCount,
                length: length
            )
        }
    }
}
