import Foundation

public enum SourceBSPDisplacementPhysicsGeometryError:
    Error, Equatable, Sendable
{
    case missingWorldModel
    case invalidWorldFaceRange(first: Int, count: Int, available: Int)
    case invalidBaseFace(face: Int, vertexCount: Int)
    case triangleBudgetExceeded(actual: Int, limit: Int)
    case staticGeometry(SourceDeterministicPhysicsStaticSceneError)
}

/// One real worldspawn displacement retained as an open static triangle mesh.
/// Material is deliberately unresolved: a BSP texinfo reference does not by
/// itself attest the seven-bit VPhysics surface-property index.
public struct SourceBSPDisplacementPhysicsMesh: Equatable, Sendable {
    public let faceIndex: Int
    public let displacementInfoIndex: Int
    public let contents: SourceContents
    public let vertices: [SourceVector3]
    public let triangles: [SourceDeterministicPhysicsStaticTriangle]
    public let removedTriangleCount: Int
    public let degenerateTriangleCount: Int

    public init(
        faceIndex: Int,
        displacementInfoIndex: Int,
        contents: SourceContents,
        vertices: [SourceVector3],
        triangles: [SourceDeterministicPhysicsStaticTriangle],
        removedTriangleCount: Int,
        degenerateTriangleCount: Int
    ) {
        self.faceIndex = faceIndex
        self.displacementInfoIndex = displacementInfoIndex
        self.contents = contents
        self.vertices = vertices
        self.triangles = triangles
        self.removedTriangleCount = removedTriangleCount
        self.degenerateTriangleCount = degenerateTriangleCount
    }
}

public struct SourceBSPDisplacementPhysicsGeometry: Equatable, Sendable {
    public let meshes: [SourceBSPDisplacementPhysicsMesh]
    public let triangleCount: Int
    public let removedTriangleCount: Int
    public let degenerateTriangleCount: Int

    public init(meshes: [SourceBSPDisplacementPhysicsMesh]) {
        self.meshes = meshes
        triangleCount = meshes.reduce(0) { $0 + $1.triangles.count }
        removedTriangleCount = meshes.reduce(0) {
            $0 + $1.removedTriangleCount
        }
        degenerateTriangleCount = meshes.reduce(0) {
            $0 + $1.degenerateTriangleCount
        }
    }
}

/// Shared full-resolution Source displacement topology. The renderer and
/// static physics scene use this one implementation so their terrain cannot
/// disagree at cell diagonals or recursive power boundaries.
public enum SourceBSPDisplacementTopology {
    /// Exact `DispCommon_GenerateTriIndices` recursion from Source SDK 2013.
    /// Children are lower-left, lower-right, upper-left, upper-right; each
    /// power-one leaf fans eight triangles around its center.
    public static func triangleIndices(power: Int) -> [UInt32] {
        precondition((2 ... 4).contains(power))
        let sideLength = (1 << power) + 1
        let winding = [
            (0, 1), (0, 0), (1, 0), (2, 0), (2, 1),
            (2, 2), (1, 2), (0, 2), (0, 1),
        ]
        let children = [
            ((0, 0), (1, 1)),
            ((1, 0), (2, 1)),
            ((0, 1), (1, 2)),
            ((1, 1), (2, 2)),
        ]
        func coordinate(
            _ lower: (Int, Int),
            _ upper: (Int, Int),
            _ selector: (Int, Int)
        ) -> (Int, Int) {
            func component(
                _ lower: Int,
                _ upper: Int,
                _ selector: Int
            ) -> Int {
                switch selector {
                case 0: return lower
                case 1: return (lower + upper) >> 1
                default: return upper
                }
            }
            return (
                component(lower.0, upper.0, selector.0),
                component(lower.1, upper.1, selector.1)
            )
        }

        var indices: [UInt32] = []
        indices.reserveCapacity((1 << power) * (1 << power) * 6)
        func generate(
            lower: (Int, Int),
            upper: (Int, Int),
            remainingPower: Int
        ) {
            if remainingPower == 1 {
                let center = coordinate(lower, upper, (1, 1))
                var previous = coordinate(lower, upper, winding[0])
                for selector in winding.dropFirst() {
                    let current = coordinate(lower, upper, selector)
                    for vertex in [current, previous, center] {
                        indices.append(UInt32(
                            vertex.1 * sideLength + vertex.0
                        ))
                    }
                    previous = current
                }
                return
            }
            for child in children {
                generate(
                    lower: coordinate(lower, upper, child.0),
                    upper: coordinate(lower, upper, child.1),
                    remainingPower: remainingPower - 1
                )
            }
        }
        let extent = 1 << power
        generate(
            lower: (0, 0),
            upper: (extent, extent),
            remainingPower: power
        )
        return indices
    }
}

/// Recovers worldspawn displacement vertices directly from VBSP data. No LOD,
/// smoothing, collision thickness, or fallback plane is invented here.
public enum SourceBSPDisplacementPhysicsGeometryBuilder {
    public static func build(
        bsp: SourceBSP,
        contentsMask: SourceContents = SourceMasks.solidBrushOnly,
        maximumTriangles: Int = 1_000_000
    ) throws -> SourceBSPDisplacementPhysicsGeometry {
        guard let world = bsp.models.first else {
            throw SourceBSPDisplacementPhysicsGeometryError.missingWorldModel
        }
        let firstFace = Int(world.firstFace)
        let faceCount = Int(world.faceCount)
        guard firstFace >= 0,
              faceCount >= 0,
              firstFace <= bsp.faces.count,
              faceCount <= bsp.faces.count - firstFace else {
            throw SourceBSPDisplacementPhysicsGeometryError
                .invalidWorldFaceRange(
                    first: firstFace,
                    count: faceCount,
                    available: bsp.faces.count
                )
        }

        var meshes: [SourceBSPDisplacementPhysicsMesh] = []
        var totalTriangles = 0
        for faceIndex in firstFace ..< firstFace + faceCount {
            let face = bsp.faces[faceIndex]
            let displacementIndex = Int(face.displacementInfoIndex)
            guard displacementIndex >= 0 else { continue }
            let displacement = bsp.displacementInfo[displacementIndex]
            let contents = SourceContents(
                rawValue: UInt32(bitPattern: displacement.contents)
            )
            guard !contents.intersection(contentsMask).isEmpty else { continue }

            let basePoints = try facePoints(faceIndex: faceIndex, bsp: bsp)
            guard basePoints.count == 4 else {
                throw SourceBSPDisplacementPhysicsGeometryError
                    .invalidBaseFace(
                        face: faceIndex,
                        vertexCount: basePoints.count
                    )
            }
            let start = vector(displacement.startPosition)
            let startCorner = basePoints.indices.min { lhs, rhs in
                (basePoints[lhs] - start).lengthSquared <
                    (basePoints[rhs] - start).lengthSquared
            } ?? 0
            let corners = (0 ..< 4).map {
                basePoints[(startCorner + $0) & 3]
            }
            let sideLength = displacement.sideLength
            let denominator = Float(sideLength - 1)
            let firstVertex = Int(displacement.firstVertex)
            var vertices: [SourceVector3] = []
            vertices.reserveCapacity(displacement.vertexCount)
            for y in 0 ..< sideLength {
                let vertical = Float(y) / denominator
                let left = lerp(corners[0], corners[1], vertical)
                let right = lerp(corners[3], corners[2], vertical)
                for x in 0 ..< sideLength {
                    let horizontal = Float(x) / denominator
                    let flatPoint = lerp(left, right, horizontal)
                    let localIndex = y * sideLength + x
                    let source = bsp.displacementVertices[
                        firstVertex + localIndex
                    ]
                    // VBSP may store a direct offset vector with distance one;
                    // normalizing it would change the compiled terrain.
                    vertices.append(
                        flatPoint + vector(source.vector) * source.distance
                    )
                }
            }

            let generated = SourceBSPDisplacementTopology.triangleIndices(
                power: Int(displacement.power)
            )
            let firstTriangle = Int(displacement.firstTriangle)
            var triangles: [SourceDeterministicPhysicsStaticTriangle] = []
            triangles.reserveCapacity(displacement.triangleCount)
            var removed = 0
            var degenerate = 0
            for triangleIndex in 0 ..< displacement.triangleCount {
                if bsp.displacementTriangles[firstTriangle + triangleIndex]
                    .tags.contains(.remove) {
                    removed += 1
                    continue
                }
                let offset = triangleIndex * 3
                let first = Int(generated[offset])
                let second = Int(generated[offset + 1])
                let third = Int(generated[offset + 2])
                let normal = cross(
                    vertices[second] - vertices[first],
                    vertices[third] - vertices[first]
                )
                guard normal.lengthSquared > 1e-20 else {
                    degenerate += 1
                    continue
                }
                do {
                    triangles.append(
                        try SourceDeterministicPhysicsStaticTriangle(
                            first: first,
                            second: second,
                            third: third,
                            materialIndex: nil
                        )
                    )
                } catch let error as SourceDeterministicPhysicsStaticSceneError {
                    throw SourceBSPDisplacementPhysicsGeometryError
                        .staticGeometry(error)
                }
            }
            guard !triangles.isEmpty else { continue }
            totalTriangles += triangles.count
            guard totalTriangles <= maximumTriangles else {
                throw SourceBSPDisplacementPhysicsGeometryError
                    .triangleBudgetExceeded(
                        actual: totalTriangles,
                        limit: maximumTriangles
                    )
            }
            meshes.append(SourceBSPDisplacementPhysicsMesh(
                faceIndex: faceIndex,
                displacementInfoIndex: displacementIndex,
                contents: contents,
                vertices: vertices,
                triangles: triangles,
                removedTriangleCount: removed,
                degenerateTriangleCount: degenerate
            ))
        }
        return SourceBSPDisplacementPhysicsGeometry(meshes: meshes)
    }

    private static func facePoints(
        faceIndex: Int,
        bsp: SourceBSP
    ) throws -> [SourceVector3] {
        let face = bsp.faces[faceIndex]
        let first = Int(face.firstSurfaceEdge)
        let count = Int(face.surfaceEdgeCount)
        var result: [SourceVector3] = []
        result.reserveCapacity(count)
        for offset in first ..< first + count {
            let signedEdge = Int64(bsp.surfaceEdges[offset])
            let absoluteEdge = signedEdge >= 0 ? signedEdge : -signedEdge
            let edge = bsp.edges[Int(absoluteEdge)]
            let vertexIndex = signedEdge >= 0
                ? Int(edge.firstVertex)
                : Int(edge.secondVertex)
            result.append(vector(bsp.vertices[vertexIndex].point))
        }
        return result
    }

    private static func vector(_ value: SourceBSPVector3) -> SourceVector3 {
        SourceVector3(value.x, value.y, value.z)
    }

    private static func lerp(
        _ start: SourceVector3,
        _ end: SourceVector3,
        _ fraction: Float
    ) -> SourceVector3 {
        start + (end - start) * fraction
    }

    private static func cross(
        _ lhs: SourceVector3,
        _ rhs: SourceVector3
    ) -> SourceVector3 {
        SourceVector3(
            lhs.y * rhs.z - lhs.z * rhs.y,
            lhs.z * rhs.x - lhs.x * rhs.z,
            lhs.x * rhs.y - lhs.y * rhs.x
        )
    }
}
