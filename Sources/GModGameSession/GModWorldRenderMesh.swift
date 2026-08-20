import GModEngine

public struct GModWorldRenderVertex: Sendable, Equatable {
    public let position: SourceVector3
    public let normal: SourceVector3
    public let textureCoordinate: GModWorldTextureCoordinate

    public init(
        position: SourceVector3,
        normal: SourceVector3,
        textureCoordinate: GModWorldTextureCoordinate = .zero
    ) {
        self.position = position
        self.normal = normal
        self.textureCoordinate = textureCoordinate
    }
}

public struct GModWorldTextureCoordinate: Sendable, Equatable {
    public let u: Float
    public let v: Float

    public init(u: Float, v: Float) {
        self.u = u
        self.v = v
    }

    public static let zero = GModWorldTextureCoordinate(u: 0, v: 0)
}

public struct GModWorldMaterialRange: Sendable, Equatable {
    public let materialName: String?
    public let firstIndex: Int
    public let indexCount: Int

    public init(materialName: String?, firstIndex: Int, indexCount: Int) {
        self.materialName = materialName
        self.firstIndex = firstIndex
        self.indexCount = indexCount
    }
}

public struct GModWorldRenderMeshDiagnostics: Sendable, Equatable {
    public let sourceFaceCount: Int
    public let emittedFaceCount: Int
    public let degenerateFaceCount: Int
    public let displacementBaseFaceCount: Int
    public let skippedToolOrSkyFaceCount: Int

    public init(
        sourceFaceCount: Int,
        emittedFaceCount: Int,
        degenerateFaceCount: Int,
        displacementBaseFaceCount: Int,
        skippedToolOrSkyFaceCount: Int = 0
    ) {
        self.sourceFaceCount = sourceFaceCount
        self.emittedFaceCount = emittedFaceCount
        self.degenerateFaceCount = degenerateFaceCount
        self.displacementBaseFaceCount = displacementBaseFaceCount
        self.skippedToolOrSkyFaceCount = skippedToolOrSkyFaceCount
    }
}

/// A renderer-neutral triangulation of BSP model 0 in Source coordinates.
///
/// Each face keeps its own vertices so its plane normal remains exact. The
/// mesh deliberately emits the coarse base polygon for displacement faces.
/// Material names and base UVs are preserved for a host resolver, while
/// displacement vertices, lightmaps, and PVS remain separate milestones and
/// are not fabricated here.
public struct GModWorldRenderMesh: Sendable, Equatable {
    public let vertices: [GModWorldRenderVertex]
    public let indices: [UInt32]
    public let minimum: SourceVector3
    public let maximum: SourceVector3
    public let materialRanges: [GModWorldMaterialRange]
    public let diagnostics: GModWorldRenderMeshDiagnostics

    public init(
        vertices: [GModWorldRenderVertex],
        indices: [UInt32],
        minimum: SourceVector3,
        maximum: SourceVector3,
        materialRanges: [GModWorldMaterialRange] = [],
        diagnostics: GModWorldRenderMeshDiagnostics
    ) {
        self.vertices = vertices
        self.indices = indices
        self.minimum = minimum
        self.maximum = maximum
        self.materialRanges = materialRanges
        self.diagnostics = diagnostics
    }

    public var triangleCount: Int { indices.count / 3 }

    public static func build(from bsp: SourceBSP) throws -> Self {
        guard let world = bsp.models.first else {
            throw GModWorldRenderMeshError.missingWorldModel
        }
        guard world.firstFace >= 0, world.faceCount >= 0 else {
            throw GModWorldRenderMeshError.invalidWorldFaceRange(
                first: Int(world.firstFace),
                count: Int(world.faceCount),
                available: bsp.faces.count
            )
        }
        let firstFace = Int(world.firstFace)
        let faceCount = Int(world.faceCount)
        let (endFace, overflow) = firstFace.addingReportingOverflow(faceCount)
        guard !overflow, endFace <= bsp.faces.count else {
            throw GModWorldRenderMeshError.invalidWorldFaceRange(
                first: firstFace,
                count: faceCount,
                available: bsp.faces.count
            )
        }

        var vertices: [GModWorldRenderVertex] = []
        var materialIndices: [String: [UInt32]] = [:]
        var materialOrder: [String] = []
        var emittedFaces = 0
        var degenerateFaces = 0
        var displacementFaces = 0
        var skippedToolOrSkyFaces = 0
        var minimum = SourceVector3(
            Float.greatestFiniteMagnitude,
            Float.greatestFiniteMagnitude,
            Float.greatestFiniteMagnitude
        )
        var maximum = SourceVector3(
            -Float.greatestFiniteMagnitude,
            -Float.greatestFiniteMagnitude,
            -Float.greatestFiniteMagnitude
        )

        for faceIndex in firstFace..<endFace {
            let face = bsp.faces[faceIndex]
            if face.displacementInfoIndex >= 0 {
                displacementFaces += 1
            }
            guard face.firstSurfaceEdge >= 0, face.surfaceEdgeCount >= 0 else {
                throw GModWorldRenderMeshError.invalidSurfaceEdgeRange(
                    face: faceIndex,
                    first: Int(face.firstSurfaceEdge),
                    count: Int(face.surfaceEdgeCount),
                    available: bsp.surfaceEdges.count
                )
            }
            let firstSurfaceEdge = Int(face.firstSurfaceEdge)
            let surfaceEdgeCount = Int(face.surfaceEdgeCount)
            let (endSurfaceEdge, surfaceOverflow) = firstSurfaceEdge
                .addingReportingOverflow(surfaceEdgeCount)
            guard !surfaceOverflow, endSurfaceEdge <= bsp.surfaceEdges.count else {
                throw GModWorldRenderMeshError.invalidSurfaceEdgeRange(
                    face: faceIndex,
                    first: firstSurfaceEdge,
                    count: surfaceEdgeCount,
                    available: bsp.surfaceEdges.count
                )
            }
            guard surfaceEdgeCount >= 3 else {
                degenerateFaces += 1
                continue
            }

            let planeIndex = Int(face.planeIndex)
            guard planeIndex < bsp.planes.count else {
                throw GModWorldRenderMeshError.invalidPlaneIndex(
                    face: faceIndex,
                    index: planeIndex,
                    available: bsp.planes.count
                )
            }
            let sourceNormal = bsp.planes[planeIndex].normal
            let direction: Float = face.side == 0 ? 1 : -1
            let normal = SourceVector3(
                sourceNormal.x * direction,
                sourceNormal.y * direction,
                sourceNormal.z * direction
            )
            guard Self.isFinite(normal) else {
                throw GModWorldRenderMeshError.nonFinitePlane(face: faceIndex)
            }
            guard vertices.count <= Int(UInt32.max) - surfaceEdgeCount else {
                throw GModWorldRenderMeshError.indexCapacityExceeded
            }
            let baseIndex = UInt32(vertices.count)

            let material = try Self.material(for: face, in: bsp, faceIndex: faceIndex)
            if let info = material.info,
               Self.isToolOrSkySurface(flags: info.flags) {
                skippedToolOrSkyFaces += 1
                continue
            }
            let materialKey = material.name?.lowercased() ?? ""
            if materialIndices[materialKey] == nil {
                materialIndices[materialKey] = []
                materialOrder.append(materialKey)
            }

            for offset in firstSurfaceEdge..<endSurfaceEdge {
                let signedEdge = Int64(bsp.surfaceEdges[offset])
                let absoluteEdge = signedEdge >= 0 ? signedEdge : -signedEdge
                guard absoluteEdge < Int64(bsp.edges.count) else {
                    throw GModWorldRenderMeshError.invalidEdgeIndex(
                        face: faceIndex,
                        index: absoluteEdge,
                        available: bsp.edges.count
                    )
                }
                let edge = bsp.edges[Int(absoluteEdge)]
                let vertexIndex = signedEdge >= 0
                    ? Int(edge.firstVertex)
                    : Int(edge.secondVertex)
                guard vertexIndex < bsp.vertices.count else {
                    throw GModWorldRenderMeshError.invalidVertexIndex(
                        face: faceIndex,
                        index: vertexIndex,
                        available: bsp.vertices.count
                    )
                }
                let point = bsp.vertices[vertexIndex].point
                let position = SourceVector3(point.x, point.y, point.z)
                guard Self.isFinite(position) else {
                    throw GModWorldRenderMeshError.nonFiniteVertex(
                        face: faceIndex,
                        index: vertexIndex
                    )
                }
                let uv: GModWorldTextureCoordinate
                if let info = material.info,
                   let data = material.data,
                   data.width > 0,
                   data.height > 0 {
                    let s = position.x * info.textureVectors[0].x +
                        position.y * info.textureVectors[0].y +
                        position.z * info.textureVectors[0].z +
                        info.textureVectors[0].offset
                    let t = position.x * info.textureVectors[1].x +
                        position.y * info.textureVectors[1].y +
                        position.z * info.textureVectors[1].z +
                        info.textureVectors[1].offset
                    uv = GModWorldTextureCoordinate(
                        u: s / Float(data.width),
                        v: t / Float(data.height)
                    )
                    guard uv.u.isFinite, uv.v.isFinite else {
                        throw GModWorldRenderMeshError.nonFiniteTextureCoordinate(
                            face: faceIndex
                        )
                    }
                } else {
                    uv = .zero
                }
                vertices.append(
                    GModWorldRenderVertex(
                        position: position,
                        normal: normal,
                        textureCoordinate: uv
                    )
                )
                minimum.x = Swift.min(minimum.x, position.x)
                minimum.y = Swift.min(minimum.y, position.y)
                minimum.z = Swift.min(minimum.z, position.z)
                maximum.x = Swift.max(maximum.x, position.x)
                maximum.y = Swift.max(maximum.y, position.y)
                maximum.z = Swift.max(maximum.z, position.z)
            }

            for corner in 1..<(surfaceEdgeCount - 1) {
                materialIndices[materialKey, default: []].append(baseIndex)
                materialIndices[materialKey, default: []].append(
                    baseIndex + UInt32(corner)
                )
                materialIndices[materialKey, default: []].append(
                    baseIndex + UInt32(corner + 1)
                )
            }
            emittedFaces += 1
        }

        if vertices.isEmpty {
            minimum = .zero
            maximum = .zero
        }
        var indices: [UInt32] = []
        var materialRanges: [GModWorldMaterialRange] = []
        for key in materialOrder {
            let grouped = materialIndices[key] ?? []
            let firstIndex = indices.count
            indices.append(contentsOf: grouped)
            materialRanges.append(
                GModWorldMaterialRange(
                    materialName: key.isEmpty ? nil : key,
                    firstIndex: firstIndex,
                    indexCount: grouped.count
                )
            )
        }
        return Self(
            vertices: vertices,
            indices: indices,
            minimum: minimum,
            maximum: maximum,
            materialRanges: materialRanges,
            diagnostics: GModWorldRenderMeshDiagnostics(
                sourceFaceCount: faceCount,
                emittedFaceCount: emittedFaces,
                degenerateFaceCount: degenerateFaces,
                displacementBaseFaceCount: displacementFaces,
                skippedToolOrSkyFaceCount: skippedToolOrSkyFaces
            )
        )
    }

    private static func isFinite(_ value: SourceVector3) -> Bool {
        value.x.isFinite && value.y.isFinite && value.z.isFinite
    }

    private static func isToolOrSkySurface(flags: Int32) -> Bool {
        // Public Source SDK SURF_* flags. These faces participate in BSP
        // visibility/collision but are not ordinary world polygons.
        let sky2D: UInt32 = 0x0002
        let sky: UInt32 = 0x0004
        let trigger: UInt32 = 0x0040
        let noDraw: UInt32 = 0x0080
        let hint: UInt32 = 0x0100
        let skip: UInt32 = 0x0200
        let excluded = sky2D | sky | trigger | noDraw | hint | skip
        return UInt32(bitPattern: flags) & excluded != 0
    }

    private static func material(
        for face: SourceBSPFace,
        in bsp: SourceBSP,
        faceIndex: Int
    ) throws -> (name: String?, info: SourceBSPTextureInfo?, data: SourceBSPTextureData?) {
        guard face.textureInfoIndex >= 0 else { return (nil, nil, nil) }
        let infoIndex = Int(face.textureInfoIndex)
        guard bsp.textureInfo.indices.contains(infoIndex) else {
            throw GModWorldRenderMeshError.invalidTextureInfoIndex(
                face: faceIndex,
                index: infoIndex,
                available: bsp.textureInfo.count
            )
        }
        let info = bsp.textureInfo[infoIndex]
        let dataIndex = Int(info.textureDataIndex)
        guard bsp.textureData.indices.contains(dataIndex) else {
            throw GModWorldRenderMeshError.invalidTextureDataIndex(
                face: faceIndex,
                index: dataIndex,
                available: bsp.textureData.count
            )
        }
        let data = bsp.textureData[dataIndex]
        guard data.width > 0, data.height > 0 else {
            throw GModWorldRenderMeshError.invalidTextureDimensions(
                face: faceIndex,
                width: Int(data.width),
                height: Int(data.height)
            )
        }
        return (bsp.textureName(forTextureDataIndex: dataIndex), info, data)
    }
}

public enum GModWorldRenderMeshError: Error, Sendable, Equatable,
    CustomStringConvertible
{
    case missingWorldModel
    case invalidWorldFaceRange(first: Int, count: Int, available: Int)
    case invalidSurfaceEdgeRange(face: Int, first: Int, count: Int, available: Int)
    case invalidPlaneIndex(face: Int, index: Int, available: Int)
    case invalidEdgeIndex(face: Int, index: Int64, available: Int)
    case invalidVertexIndex(face: Int, index: Int, available: Int)
    case nonFinitePlane(face: Int)
    case nonFiniteVertex(face: Int, index: Int)
    case nonFiniteTextureCoordinate(face: Int)
    case invalidTextureInfoIndex(face: Int, index: Int, available: Int)
    case invalidTextureDataIndex(face: Int, index: Int, available: Int)
    case invalidTextureDimensions(face: Int, width: Int, height: Int)
    case indexCapacityExceeded

    public var description: String {
        switch self {
        case .missingWorldModel:
            return "BSP has no world model"
        case let .invalidWorldFaceRange(first, count, available):
            return "world face range \(first)..<\(first + count) is outside 0..<\(available)"
        case let .invalidSurfaceEdgeRange(face, first, count, available):
            return "face \(face) surface-edge range \(first)..<\(first + count) is outside 0..<\(available)"
        case let .invalidPlaneIndex(face, index, available):
            return "face \(face) plane \(index) is outside 0..<\(available)"
        case let .invalidEdgeIndex(face, index, available):
            return "face \(face) edge \(index) is outside 0..<\(available)"
        case let .invalidVertexIndex(face, index, available):
            return "face \(face) vertex \(index) is outside 0..<\(available)"
        case let .nonFinitePlane(face):
            return "face \(face) has a non-finite plane normal"
        case let .nonFiniteVertex(face, index):
            return "face \(face) vertex \(index) is non-finite"
        case let .nonFiniteTextureCoordinate(face):
            return "face \(face) has a non-finite texture coordinate"
        case let .invalidTextureInfoIndex(face, index, available):
            return "face \(face) texinfo \(index) is outside 0..<\(available)"
        case let .invalidTextureDataIndex(face, index, available):
            return "face \(face) texdata \(index) is outside 0..<\(available)"
        case let .invalidTextureDimensions(face, width, height):
            return "face \(face) texture dimensions \(width)x\(height) are invalid"
        case .indexCapacityExceeded:
            return "world mesh exceeds UInt32 index capacity"
        }
    }
}
