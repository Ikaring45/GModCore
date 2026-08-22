import Foundation

public struct SourceBSPPhysicsMaterialContext: Equatable, Sendable {
    public let brushIndex: Int
    public let brushSideIndex: Int
    public let planeIndex: Int
    public let textureInfoIndex: Int?
    public let textureName: String?
    public let isBevel: Bool
    public let contents: SourceContents
}

/// Independently attested seven-bit Source physics-material lookup.
///
/// BSP stores render texture references, not the resolved `surfaceproperties`
/// table index. Geometry remains usable when this resolver is absent; those
/// triangles deliberately report a nil query material instead of a guessed
/// fallback index.
public struct SourceBSPPhysicsMaterialAttestation: Sendable {
    public typealias Resolver = @Sendable (
        _ context: SourceBSPPhysicsMaterialContext
    ) -> Int?

    private let resolver: Resolver

    public init(_ resolver: @escaping Resolver) {
        self.resolver = resolver
    }

    fileprivate func materialIndex(
        for context: SourceBSPPhysicsMaterialContext
    ) -> Int? {
        resolver(context)
    }
}

public enum SourceBSPStaticPhysicsBridgeError:
    Error, Equatable, Sendable
{
    case invalidBSPByteSHA256(String)
    case emptyContentsMask
    case missingWorldModel
    case invalidWorldTreeReference(Int32)
    case noMatchingWorldBrushes
    case brushSideBudgetExceeded(brush: Int, actual: Int, limit: Int)
    case brushDoesNotFormClosedVolume(Int)
    case triangleBudgetExceeded(actual: Int, limit: Int)
    case displacementGeometry(SourceBSPDisplacementPhysicsGeometryError)
    case staticGeometry(SourceDeterministicPhysicsStaticSceneError)
}

public enum SourceBSPStaticPhysicsSkippedBrushReason:
    Equatable, Sendable
{
    /// No finite-volume intersection satisfies every Source collision plane.
    /// Such a brush cannot be entered by the BSP convex clipper either.
    case noClosedPlaneIntersection
    /// Plane intersections exist, but no polygonal boundary can be emitted.
    case noTriangulatableBoundary
}

public struct SourceBSPStaticPhysicsSkippedBrush: Equatable, Sendable {
    public let brushIndex: Int
    public let sideCount: Int
    public let contents: SourceContents
    public let reason: SourceBSPStaticPhysicsSkippedBrushReason
}

/// Bounded conversion policy. These limits protect iPad allocation without
/// changing geometry or supplying physical values.
public struct SourceBSPStaticPhysicsBridgeBudget: Equatable, Sendable {
    public let maximumBrushSides: Int
    public let maximumTriangles: Int

    public init(
        maximumBrushSides: Int = 128,
        maximumTriangles: Int = 1_000_000
    ) {
        precondition(maximumBrushSides >= 4)
        precondition(maximumTriangles > 0)
        self.maximumBrushSides = maximumBrushSides
        self.maximumTriangles = maximumTriangles
    }

    public static let iPadValidated = SourceBSPStaticPhysicsBridgeBudget()
}

/// Exact-byte identity plus immutable static geometry recovered from real BSP
/// collision brushes. No floor, terrain bounds, material, mass, or inertia is
/// synthesized by this value.
public struct SourceBSPAttestedStaticPhysicsAsset: Equatable, Sendable {
    public let bspSHA256: String
    public let bspVersion: Int32
    public let mapRevision: Int32
    public let contents: SourceContents
    public let includedBrushIndices: [Int]
    public let includedDisplacementFaceIndices: [Int]
    public let skippedBrushes: [SourceBSPStaticPhysicsSkippedBrush]
    public let geometry: SourceDeterministicPhysicsStaticGeometry
    public let brushTriangleCount: Int
    public let displacementTriangleCount: Int
    public let removedDisplacementTriangleCount: Int
    public let degenerateDisplacementTriangleCount: Int
    public let triangleCount: Int

    fileprivate init(
        bspSHA256: String,
        bspVersion: Int32,
        mapRevision: Int32,
        contents: SourceContents,
        includedBrushIndices: [Int],
        includedDisplacementFaceIndices: [Int],
        skippedBrushes: [SourceBSPStaticPhysicsSkippedBrush],
        geometry: SourceDeterministicPhysicsStaticGeometry,
        brushTriangleCount: Int,
        displacementTriangleCount: Int,
        removedDisplacementTriangleCount: Int,
        degenerateDisplacementTriangleCount: Int,
        triangleCount: Int
    ) {
        self.bspSHA256 = bspSHA256
        self.bspVersion = bspVersion
        self.mapRevision = mapRevision
        self.contents = contents
        self.includedBrushIndices = includedBrushIndices
        self.includedDisplacementFaceIndices =
            includedDisplacementFaceIndices
        self.skippedBrushes = skippedBrushes
        self.geometry = geometry
        self.brushTriangleCount = brushTriangleCount
        self.displacementTriangleCount = displacementTriangleCount
        self.removedDisplacementTriangleCount =
            removedDisplacementTriangleCount
        self.degenerateDisplacementTriangleCount =
            degenerateDisplacementTriangleCount
        self.triangleCount = triangleCount
    }

    /// Binds the immutable map scene to the current canonical worldspawn
    /// generation. It remains massless and is not returned as a dynamic body.
    public func makeStaticScene(
        worldIdentity: SourceCanonicalEntityIdentity,
        solidIndex: Int = 0,
        transform: SourceEntityTransform = .identity
    ) throws -> SourceDeterministicPhysicsStaticScene {
        let bodyID = try SourcePhysicsBodyID(
            entityIdentity: worldIdentity,
            solidIndex: solidIndex
        )
        return try SourceDeterministicPhysicsStaticScene(
            bodyID: bodyID,
            geometry: geometry,
            transform: transform,
            contents: contents
        )
    }
}

/// Converts parsed BSP convex-brush half-spaces into immutable world geometry.
/// Every output vertex is an intersection of three real brush planes. A face
/// carries a material only when an independent resolver attests it.
public enum SourceBSPStaticPhysicsBridge {
    public static func build(
        bsp: SourceBSP,
        bspSHA256: String,
        contentsMask: SourceContents = SourceMasks.solidBrushOnly,
        materialAttestation: SourceBSPPhysicsMaterialAttestation? = nil,
        budget: SourceBSPStaticPhysicsBridgeBudget = .iPadValidated
    ) throws -> SourceBSPAttestedStaticPhysicsAsset {
        guard isCanonicalSHA256(bspSHA256) else {
            throw SourceBSPStaticPhysicsBridgeError
                .invalidBSPByteSHA256(bspSHA256)
        }
        guard !contentsMask.isEmpty else {
            throw SourceBSPStaticPhysicsBridgeError.emptyContentsMask
        }

        var includedBrushIndices: [Int] = []
        var skippedBrushes: [SourceBSPStaticPhysicsSkippedBrush] = []
        var parts: [SourceDeterministicPhysicsStaticMeshPart] = []
        var totalTriangleCount = 0
        includedBrushIndices.reserveCapacity(bsp.brushes.count)
        parts.reserveCapacity(bsp.brushes.count + bsp.displacementInfo.count)

        // Only leaves reachable from model zero's headnode are worldspawn.
        // Other BSP models share the global leaf/brush tables, but traceWorld
        // never visits them without their separate model headnode.
        let worldBrushIndices = try worldBrushIndices(in: bsp)

        for brushIndex in worldBrushIndices {
            let brush = bsp.brushes[brushIndex]
            let contents = SourceContents(
                rawValue: UInt32(bitPattern: brush.contents)
            )
            guard !contents.intersection(contentsMask).isEmpty else { continue }
            let sideCount = Int(brush.sideCount)
            guard sideCount <= budget.maximumBrushSides else {
                throw SourceBSPStaticPhysicsBridgeError
                    .brushSideBudgetExceeded(
                        brush: brushIndex,
                        actual: sideCount,
                        limit: budget.maximumBrushSides
                    )
            }
            let firstSide = Int(brush.firstSide)
            let sideRange = firstSide ..< firstSide + sideCount
            let sides = Array(bsp.brushSides[sideRange])
            let vertices = intersections(
                sides: sides,
                planes: bsp.planes
            )
            guard vertices.count >= 4 else {
                skippedBrushes.append(SourceBSPStaticPhysicsSkippedBrush(
                    brushIndex: brushIndex,
                    sideCount: sideCount,
                    contents: contents,
                    reason: .noClosedPlaneIntersection
                ))
                continue
            }

            let firstRealSideIndex = sides.firstIndex { $0.bevel == 0 }
            var triangles: [SourceDeterministicPhysicsStaticTriangle] = []
            for localSideIndex in sides.indices {
                let side = sides[localSideIndex]
                let plane = bsp.planes[Int(side.planeIndex)]
                let normal = vector(plane.normal)
                let ordered = orderedFaceVertexIndices(
                    vertices: vertices,
                    normal: normal,
                    distance: plane.distance
                )
                // Redundant bevel planes may touch only an edge or vertex and
                // therefore do not contribute a polygon to the closed hull.
                guard ordered.count >= 3 else { continue }

                let effectiveLocalIndex = side.bevel == 0
                    ? localSideIndex
                    : (firstRealSideIndex ?? localSideIndex)
                let effectiveSide = sides[effectiveLocalIndex]
                let context = materialContext(
                    bsp: bsp,
                    brushIndex: brushIndex,
                    globalSideIndex: firstSide + localSideIndex,
                    sourceSide: side,
                    effectiveSide: effectiveSide,
                    contents: contents
                )
                let materialIndex = materialAttestation?.materialIndex(
                    for: context
                )

                for index in 1 ..< ordered.count - 1 {
                    do {
                        triangles.append(try SourceDeterministicPhysicsStaticTriangle(
                            first: ordered[0],
                            second: ordered[index],
                            third: ordered[index + 1],
                            materialIndex: materialIndex
                        ))
                    } catch let error as SourceDeterministicPhysicsStaticSceneError {
                        throw SourceBSPStaticPhysicsBridgeError
                            .staticGeometry(error)
                    }
                }
            }
            guard !triangles.isEmpty else {
                skippedBrushes.append(SourceBSPStaticPhysicsSkippedBrush(
                    brushIndex: brushIndex,
                    sideCount: sideCount,
                    contents: contents,
                    reason: .noTriangulatableBoundary
                ))
                continue
            }

            totalTriangleCount += triangles.count
            guard totalTriangleCount <= budget.maximumTriangles else {
                throw SourceBSPStaticPhysicsBridgeError
                    .triangleBudgetExceeded(
                        actual: totalTriangleCount,
                        limit: budget.maximumTriangles
                    )
            }
            do {
                parts.append(try SourceDeterministicPhysicsStaticMeshPart(
                    vertices: vertices,
                    triangles: triangles,
                    partIndex: brushIndex
                ))
            } catch let error as SourceDeterministicPhysicsStaticSceneError {
                throw SourceBSPStaticPhysicsBridgeError.staticGeometry(error)
            }
            includedBrushIndices.append(brushIndex)
        }

        let brushTriangleCount = totalTriangleCount
        let remainingTriangleBudget = budget.maximumTriangles -
            totalTriangleCount
        let displacementGeometry: SourceBSPDisplacementPhysicsGeometry
        do {
            displacementGeometry = try
                SourceBSPDisplacementPhysicsGeometryBuilder.build(
                    bsp: bsp,
                    contentsMask: contentsMask,
                    maximumTriangles: remainingTriangleBudget
                )
        } catch let error as SourceBSPDisplacementPhysicsGeometryError {
            if case let .triangleBudgetExceeded(actual, _) = error {
                throw SourceBSPStaticPhysicsBridgeError
                    .triangleBudgetExceeded(
                        actual: brushTriangleCount + actual,
                        limit: budget.maximumTriangles
                    )
            }
            throw SourceBSPStaticPhysicsBridgeError
                .displacementGeometry(error)
        }
        for mesh in displacementGeometry.meshes {
            do {
                parts.append(try SourceDeterministicPhysicsStaticMeshPart(
                    vertices: mesh.vertices,
                    triangles: mesh.triangles,
                    topology: .openTriangleMesh,
                    partIndex: parts.count
                ))
            } catch let error as SourceDeterministicPhysicsStaticSceneError {
                throw SourceBSPStaticPhysicsBridgeError.staticGeometry(error)
            }
        }
        totalTriangleCount += displacementGeometry.triangleCount

        guard !parts.isEmpty else {
            throw SourceBSPStaticPhysicsBridgeError.noMatchingWorldBrushes
        }
        let geometry: SourceDeterministicPhysicsStaticGeometry
        do {
            geometry = try SourceDeterministicPhysicsStaticGeometry(parts: parts)
        } catch let error as SourceDeterministicPhysicsStaticSceneError {
            throw SourceBSPStaticPhysicsBridgeError.staticGeometry(error)
        }
        return SourceBSPAttestedStaticPhysicsAsset(
            bspSHA256: bspSHA256,
            bspVersion: bsp.header.version,
            mapRevision: bsp.header.mapRevision,
            contents: contentsMask,
            includedBrushIndices: includedBrushIndices,
            includedDisplacementFaceIndices:
                displacementGeometry.meshes.map(\.faceIndex),
            skippedBrushes: skippedBrushes,
            geometry: geometry,
            brushTriangleCount: brushTriangleCount,
            displacementTriangleCount: displacementGeometry.triangleCount,
            removedDisplacementTriangleCount:
                displacementGeometry.removedTriangleCount,
            degenerateDisplacementTriangleCount:
                displacementGeometry.degenerateTriangleCount,
            triangleCount: totalTriangleCount
        )
    }

    private static func intersections(
        sides: [SourceBSPBrushSide],
        planes: [SourceBSPPlane]
    ) -> [SourceVector3] {
        let equations = sides.map { side in planes[Int(side.planeIndex)] }
        var vertices: [SourceVector3] = []
        for first in 0 ..< equations.count {
            for second in first + 1 ..< equations.count {
                for third in second + 1 ..< equations.count {
                    guard let point = intersection(
                        equations[first],
                        equations[second],
                        equations[third]
                    ), isInside(point, equations: equations),
                    !vertices.contains(where: {
                        ($0 - point).lengthSquared <= vertexMergeDistanceSquared
                    }) else { continue }
                    vertices.append(point)
                }
            }
        }
        return vertices
    }

    private static func worldBrushIndices(in bsp: SourceBSP) throws -> [Int] {
        guard let worldModel = bsp.models.first else {
            throw SourceBSPStaticPhysicsBridgeError.missingWorldModel
        }
        var pending = [worldModel.headNode]
        var visitedNodes = Set<Int>()
        var visitedLeaves = Set<Int>()
        var visitedBrushes = Set<Int>()
        var result: [Int] = []

        while let child = pending.popLast() {
            if child < 0 {
                let leafIndex64 = -1 - Int64(child)
                guard leafIndex64 >= 0,
                      leafIndex64 < Int64(bsp.leaves.count) else {
                    throw SourceBSPStaticPhysicsBridgeError
                        .invalidWorldTreeReference(child)
                }
                let leafIndex = Int(leafIndex64)
                guard visitedLeaves.insert(leafIndex).inserted else { continue }
                let leaf = bsp.leaves[leafIndex]
                let first = Int(leaf.firstLeafBrush)
                let end = first + Int(leaf.leafBrushCount)
                for tableIndex in first ..< end {
                    let brushIndex = Int(bsp.leafBrushes[tableIndex])
                    if visitedBrushes.insert(brushIndex).inserted {
                        result.append(brushIndex)
                    }
                }
                continue
            }

            let nodeIndex = Int(child)
            guard bsp.nodes.indices.contains(nodeIndex) else {
                throw SourceBSPStaticPhysicsBridgeError
                    .invalidWorldTreeReference(child)
            }
            guard visitedNodes.insert(nodeIndex).inserted else { continue }
            let node = bsp.nodes[nodeIndex]
            // LIFO: push back first so front/child zero is visited first.
            pending.append(node.children[1])
            pending.append(node.children[0])
        }
        return result
    }

    private static func intersection(
        _ first: SourceBSPPlane,
        _ second: SourceBSPPlane,
        _ third: SourceBSPPlane
    ) -> SourceVector3? {
        let firstNormal = DoubleVector(first.normal)
        let secondNormal = DoubleVector(second.normal)
        let thirdNormal = DoubleVector(third.normal)
        let secondCrossThird = secondNormal.cross(thirdNormal)
        let denominator = firstNormal.dot(secondCrossThird)
        guard abs(denominator) > 1e-10 else { return nil }
        let value = (
            secondCrossThird * Double(first.distance) +
                thirdNormal.cross(firstNormal) * Double(second.distance) +
                firstNormal.cross(secondNormal) * Double(third.distance)
        ) / denominator
        guard value.x.isFinite, value.y.isFinite, value.z.isFinite,
              abs(value.x) <= Double(Float.greatestFiniteMagnitude),
              abs(value.y) <= Double(Float.greatestFiniteMagnitude),
              abs(value.z) <= Double(Float.greatestFiniteMagnitude) else {
            return nil
        }
        return SourceVector3(Float(value.x), Float(value.y), Float(value.z))
    }

    private static func isInside(
        _ point: SourceVector3,
        equations: [SourceBSPPlane]
    ) -> Bool {
        equations.allSatisfy { plane in
            vector(plane.normal).dot(point) <=
                plane.distance + SourceCollisionConstants.distanceEpsilon
        }
    }

    private static func orderedFaceVertexIndices(
        vertices: [SourceVector3],
        normal rawNormal: SourceVector3,
        distance: Float
    ) -> [Int] {
        let normal = normalized(rawNormal)
        guard normal.lengthSquared > 0 else { return [] }
        let tolerance = SourceCollisionConstants.distanceEpsilon
        let indices = vertices.indices.filter {
            abs(vertices[$0].dot(rawNormal) - distance) <= tolerance
        }
        guard indices.count >= 3 else { return [] }
        let center = indices.reduce(SourceVector3.zero) {
            $0 + vertices[$1]
        } / Float(indices.count)
        let reference = abs(normal.z) < 0.9
            ? SourceVector3(0, 0, 1)
            : SourceVector3(0, 1, 0)
        let tangent = normalized(cross(reference, normal))
        let bitangent = cross(normal, tangent)
        return indices.sorted { lhs, rhs in
            let lhsOffset = vertices[lhs] - center
            let rhsOffset = vertices[rhs] - center
            let lhsAngle = atan2(
                Double(lhsOffset.dot(bitangent)),
                Double(lhsOffset.dot(tangent))
            )
            let rhsAngle = atan2(
                Double(rhsOffset.dot(bitangent)),
                Double(rhsOffset.dot(tangent))
            )
            if lhsAngle != rhsAngle { return lhsAngle < rhsAngle }
            return lhs < rhs
        }
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

    private static func materialContext(
        bsp: SourceBSP,
        brushIndex: Int,
        globalSideIndex: Int,
        sourceSide: SourceBSPBrushSide,
        effectiveSide: SourceBSPBrushSide,
        contents: SourceContents
    ) -> SourceBSPPhysicsMaterialContext {
        let textureInfoIndex = effectiveSide.textureInfoIndex >= 0
            ? Int(effectiveSide.textureInfoIndex)
            : nil
        let textureName: String?
        if let textureInfoIndex {
            let textureDataIndex = Int(
                bsp.textureInfo[textureInfoIndex].textureDataIndex
            )
            textureName = bsp.textureName(
                forTextureDataIndex: textureDataIndex
            )
        } else {
            textureName = nil
        }
        return SourceBSPPhysicsMaterialContext(
            brushIndex: brushIndex,
            brushSideIndex: globalSideIndex,
            planeIndex: Int(sourceSide.planeIndex),
            textureInfoIndex: textureInfoIndex,
            textureName: textureName,
            isBevel: sourceSide.bevel != 0,
            contents: contents
        )
    }

    private static func isCanonicalSHA256(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return bytes.count == 64 && bytes.allSatisfy {
            (0x30 ... 0x39).contains($0) || (0x61 ... 0x66).contains($0)
        }
    }

    private static func vector(_ value: SourceBSPVector3) -> SourceVector3 {
        SourceVector3(value.x, value.y, value.z)
    }

    private static func normalized(_ value: SourceVector3) -> SourceVector3 {
        guard value.lengthSquared.isFinite, value.lengthSquared > 1e-20 else {
            return .zero
        }
        return value / value.length
    }

    private static let vertexMergeDistanceSquared =
        (SourceCollisionConstants.distanceEpsilon * 0.25) *
        (SourceCollisionConstants.distanceEpsilon * 0.25)
}

private struct DoubleVector {
    let x: Double
    let y: Double
    let z: Double

    init(_ value: SourceBSPVector3) {
        x = Double(value.x)
        y = Double(value.y)
        z = Double(value.z)
    }

    init(_ x: Double, _ y: Double, _ z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    static func + (lhs: DoubleVector, rhs: DoubleVector) -> DoubleVector {
        DoubleVector(lhs.x + rhs.x, lhs.y + rhs.y, lhs.z + rhs.z)
    }

    static func * (lhs: DoubleVector, rhs: Double) -> DoubleVector {
        DoubleVector(lhs.x * rhs, lhs.y * rhs, lhs.z * rhs)
    }

    static func / (lhs: DoubleVector, rhs: Double) -> DoubleVector {
        DoubleVector(lhs.x / rhs, lhs.y / rhs, lhs.z / rhs)
    }

    func dot(_ other: DoubleVector) -> Double {
        x * other.x + y * other.y + z * other.z
    }

    func cross(_ other: DoubleVector) -> DoubleVector {
        DoubleVector(
            y * other.z - z * other.y,
            z * other.x - x * other.z,
            x * other.y - y * other.x
        )
    }
}
