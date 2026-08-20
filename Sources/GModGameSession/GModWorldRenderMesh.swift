import GModEngine

public struct GModWorldRenderVertex: Sendable, Equatable {
    public let position: SourceVector3
    public let normal: SourceVector3

    public init(position: SourceVector3, normal: SourceVector3) {
        self.position = position
        self.normal = normal
    }
}

public struct GModWorldRenderMeshDiagnostics: Sendable, Equatable {
    public let sourceFaceCount: Int
    public let emittedFaceCount: Int
    public let degenerateFaceCount: Int
    public let displacementBaseFaceCount: Int

    public init(
        sourceFaceCount: Int,
        emittedFaceCount: Int,
        degenerateFaceCount: Int,
        displacementBaseFaceCount: Int
    ) {
        self.sourceFaceCount = sourceFaceCount
        self.emittedFaceCount = emittedFaceCount
        self.degenerateFaceCount = degenerateFaceCount
        self.displacementBaseFaceCount = displacementBaseFaceCount
    }
}

/// A renderer-neutral triangulation of BSP model 0 in Source coordinates.
///
/// Each face keeps its own vertices so its plane normal remains exact. The
/// mesh deliberately emits the coarse base polygon for displacement faces;
/// displacement vertices, lightmaps, PVS, VMT, and VTF data are separate
/// compatibility milestones and are not fabricated here.
public struct GModWorldRenderMesh: Sendable, Equatable {
    public let vertices: [GModWorldRenderVertex]
    public let indices: [UInt32]
    public let minimum: SourceVector3
    public let maximum: SourceVector3
    public let diagnostics: GModWorldRenderMeshDiagnostics

    public init(
        vertices: [GModWorldRenderVertex],
        indices: [UInt32],
        minimum: SourceVector3,
        maximum: SourceVector3,
        diagnostics: GModWorldRenderMeshDiagnostics
    ) {
        self.vertices = vertices
        self.indices = indices
        self.minimum = minimum
        self.maximum = maximum
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
        var indices: [UInt32] = []
        var emittedFaces = 0
        var degenerateFaces = 0
        var displacementFaces = 0
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
                vertices.append(
                    GModWorldRenderVertex(position: position, normal: normal)
                )
                minimum.x = Swift.min(minimum.x, position.x)
                minimum.y = Swift.min(minimum.y, position.y)
                minimum.z = Swift.min(minimum.z, position.z)
                maximum.x = Swift.max(maximum.x, position.x)
                maximum.y = Swift.max(maximum.y, position.y)
                maximum.z = Swift.max(maximum.z, position.z)
            }

            for corner in 1..<(surfaceEdgeCount - 1) {
                indices.append(baseIndex)
                indices.append(baseIndex + UInt32(corner))
                indices.append(baseIndex + UInt32(corner + 1))
            }
            emittedFaces += 1
        }

        if vertices.isEmpty {
            minimum = .zero
            maximum = .zero
        }
        return Self(
            vertices: vertices,
            indices: indices,
            minimum: minimum,
            maximum: maximum,
            diagnostics: GModWorldRenderMeshDiagnostics(
                sourceFaceCount: faceCount,
                emittedFaceCount: emittedFaces,
                degenerateFaceCount: degenerateFaces,
                displacementBaseFaceCount: displacementFaces
            )
        )
    }

    private static func isFinite(_ value: SourceVector3) -> Bool {
        value.x.isFinite && value.y.isFinite && value.z.isFinite
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
        case .indexCapacityExceeded:
            return "world mesh exceeds UInt32 index capacity"
        }
    }
}
