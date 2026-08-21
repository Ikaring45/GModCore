import Foundation
import GModEngine
import GModGameAssets

public struct GModWorldRenderVertex: Sendable, Equatable {
    public let position: SourceVector3
    public let normal: SourceVector3
    public let textureCoordinate: GModWorldTextureCoordinate
    public let lightmapCoordinate: GModWorldTextureCoordinate?

    public init(
        position: SourceVector3,
        normal: SourceVector3,
        textureCoordinate: GModWorldTextureCoordinate = .zero,
        lightmapCoordinate: GModWorldTextureCoordinate? = nil
    ) {
        self.position = position
        self.normal = normal
        self.textureCoordinate = textureCoordinate
        self.lightmapCoordinate = lightmapCoordinate
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

public struct GModWorldWaterSurface: Sendable, Equatable, Hashable {
    public let surfaceZ: Float
    public let minimumZ: Float
    public let sourceTextureInfoIndex: Int

    public init(
        surfaceZ: Float,
        minimumZ: Float,
        sourceTextureInfoIndex: Int
    ) {
        self.surfaceZ = surfaceZ
        self.minimumZ = minimumZ
        self.sourceTextureInfoIndex = sourceTextureInfoIndex
    }
}

/// The Source view in which a material range is rendered. 3D sky geometry is
/// authored around `sky_camera` at miniature scale and is not ordinary world
/// geometry even though both live in BSP model zero.
public enum GModWorldRenderLayer: String, Sendable, Equatable, Hashable {
    case world
    case sky3D
    case sky2D
}

private struct GModWorldMaterialBucketKey: Hashable {
    let material: String
    let renderLayer: GModWorldRenderLayer
}

private struct GModWorldSky3DContext {
    let origin: SourceVector3
    let scale: Float
    let area: UInt16
    let cluster: Int16
    let faceIndices: Set<Int>

    func transform(_ position: SourceVector3) -> SourceVector3 {
        (position - origin) * scale
    }
}

/// Real BSP `sky_camera` metadata and the area used to separate its miniature
/// geometry from the ordinary world. Source renders this geometry as
/// `(position - origin) * scale` before the normal world pass.
public struct GModWorldSky3D: Sendable, Equatable {
    public let origin: SourceVector3
    public let scale: Float
    public let area: UInt16
    public let cluster: Int16
    public let sourceFaceCount: Int

    public init(
        origin: SourceVector3,
        scale: Float,
        area: UInt16,
        cluster: Int16,
        sourceFaceCount: Int
    ) {
        self.origin = origin
        self.scale = scale
        self.area = area
        self.cluster = cluster
        self.sourceFaceCount = sourceFaceCount
    }
}

/// Result of Source's `IsSkyboxVisibleFromPoint` leaf flags. A 3D sky pass
/// still begins with the 2D cubemap background; SKY2D suppresses only the 3D
/// miniature world.
public enum GModWorldSkyboxVisibility: Sendable, Equatable {
    case notVisible
    case sky3D
    case sky2D
}

public struct GModWorldSkyVisibilityPlane: Sendable, Equatable {
    public let normal: SourceVector3
    public let distance: Float

    public init(normal: SourceVector3, distance: Float) {
        self.normal = normal
        self.distance = distance
    }
}

public struct GModWorldSkyVisibilityNode: Sendable, Equatable {
    public let planeIndex: Int
    public let frontChild: Int32
    public let backChild: Int32

    public init(planeIndex: Int, frontChild: Int32, backChild: Int32) {
        self.planeIndex = planeIndex
        self.frontChild = frontChild
        self.backChild = backChild
    }
}

/// Compact immutable BSP traversal retained for per-frame sky visibility.
/// Valve stores LEAF_FLAGS_SKY=0x01 and LEAF_FLAGS_SKY2D=0x04 in each leaf;
/// checking only for a `sky_camera` would draw its miniature world everywhere.
public struct GModWorldSkyVisibility: Sendable, Equatable {
    public let headNode: Int32
    public let planes: [GModWorldSkyVisibilityPlane]
    public let nodes: [GModWorldSkyVisibilityNode]
    public let leafFlags: [UInt8]

    public init(
        headNode: Int32,
        planes: [GModWorldSkyVisibilityPlane],
        nodes: [GModWorldSkyVisibilityNode],
        leafFlags: [UInt8]
    ) {
        self.headNode = headNode
        self.planes = planes
        self.nodes = nodes
        self.leafFlags = leafFlags
    }

    public func visibility(
        at point: SourceVector3
    ) -> GModWorldSkyboxVisibility {
        guard let flags = flags(at: point) else { return .notVisible }
        if flags & 0x01 != 0 { return .sky3D }
        if flags & 0x04 != 0 { return .sky2D }
        return .notVisible
    }

    public func flags(at point: SourceVector3) -> UInt8? {
        var child = headNode
        var remainingSteps = nodes.count + 1
        while child >= 0, remainingSteps > 0 {
            remainingSteps -= 1
            let nodeIndex = Int(child)
            guard nodes.indices.contains(nodeIndex) else { return nil }
            let node = nodes[nodeIndex]
            guard planes.indices.contains(node.planeIndex) else { return nil }
            let plane = planes[node.planeIndex]
            let distance = plane.normal.dot(point) - plane.distance
            child = distance >= 0 ? node.frontChild : node.backChild
        }
        guard child < 0, remainingSteps > 0 else { return nil }
        let leafIndex64 = -1 - Int64(child)
        guard leafIndex64 >= 0,
              leafIndex64 < Int64(leafFlags.count) else { return nil }
        return leafFlags[Int(leafIndex64)]
    }
}

/// Reader for Source LUMP_VISIBILITY PVS rows. Offsets are relative to the
/// start of dvis_t and zero bytes use Source's `(0, runLength)` RLE encoding.
struct GModSourcePotentialVisibility: Sendable, Equatable {
    let clusterCount: Int
    private let bytes: [UInt8]
    private let pvsOffsets: [Int]

    init?(data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { return nil }
        func int32(at offset: Int) -> Int32? {
            guard offset >= 0, offset + 4 <= bytes.count else { return nil }
            let raw = UInt32(bytes[offset]) |
                UInt32(bytes[offset + 1]) << 8 |
                UInt32(bytes[offset + 2]) << 16 |
                UInt32(bytes[offset + 3]) << 24
            return Int32(bitPattern: raw)
        }
        guard let rawCount = int32(at: 0), rawCount > 0,
              let clusterCount = Int(exactly: rawCount) else { return nil }
        let tableBytes = clusterCount.multipliedReportingOverflow(by: 8)
        let tableEnd = 4.addingReportingOverflow(tableBytes.partialValue)
        guard !tableBytes.overflow, !tableEnd.overflow,
              tableEnd.partialValue <= bytes.count else { return nil }
        var offsets: [Int] = []
        offsets.reserveCapacity(clusterCount)
        for cluster in 0..<clusterCount {
            guard let rawOffset = int32(at: 4 + cluster * 8), rawOffset >= 0,
                  let offset = Int(exactly: rawOffset), offset < bytes.count else {
                return nil
            }
            offsets.append(offset)
        }
        self.clusterCount = clusterCount
        self.bytes = bytes
        pvsOffsets = offsets
    }

    func visibleClusters(from cluster: Int) -> Set<Int>? {
        guard pvsOffsets.indices.contains(cluster) else { return nil }
        let rowByteCount = (clusterCount + 7) / 8
        var row: [UInt8] = []
        row.reserveCapacity(rowByteCount)
        var cursor = pvsOffsets[cluster]
        while row.count < rowByteCount {
            guard cursor < bytes.count else { return nil }
            let value = bytes[cursor]
            cursor += 1
            if value != 0 {
                row.append(value)
                continue
            }
            guard cursor < bytes.count else { return nil }
            let runLength = Int(bytes[cursor])
            cursor += 1
            guard runLength > 0, runLength <= rowByteCount - row.count else {
                return nil
            }
            row.append(contentsOf: repeatElement(0, count: runLength))
        }
        var visible = Set<Int>()
        for target in 0..<clusterCount where
            row[target >> 3] & (1 << UInt8(target & 7)) != 0 {
            visible.insert(target)
        }
        return visible
    }
}

public struct GModWorldMaterialRange: Sendable, Equatable {
    public let materialName: String?
    public let firstIndex: Int
    public let indexCount: Int
    /// Exact BSP texdata names represented by this resolver-facing range.
    /// Generated `maps/<map>/..._<x>_<y>_<z>` cubemap variants can share one
    /// base material here while the original names remain diagnosable.
    public let sourceMaterialNames: [String]
    public let waterSurface: GModWorldWaterSurface?
    public let renderLayer: GModWorldRenderLayer

    public init(
        materialName: String?,
        firstIndex: Int,
        indexCount: Int,
        sourceMaterialNames: [String] = [],
        waterSurface: GModWorldWaterSurface? = nil,
        renderLayer: GModWorldRenderLayer = .world
    ) {
        self.materialName = materialName
        self.firstIndex = firstIndex
        self.indexCount = indexCount
        self.sourceMaterialNames = sourceMaterialNames
        self.waterSurface = waterSurface
        self.renderLayer = renderLayer
    }
}

public struct GModWorldSkybox: Sendable, Equatable {
    public let name: String
    public let sourceSkySurfaceCount: Int
    public let materialNames: [String]

    public init(name: String, sourceSkySurfaceCount: Int, materialNames: [String]) {
        self.name = name
        self.sourceSkySurfaceCount = sourceSkySurfaceCount
        self.materialNames = materialNames
    }
}

public struct GModWorldLightmapAtlas: Sendable, Equatable {
    public let width: Int
    public let height: Int
    /// Native little-endian RGBA16Float texels containing Source linear light.
    public let linearRGBA16Float: Data
    /// A white texel reserved for surfaces without a baked lightmap.
    public let unlitTextureCoordinate: GModWorldTextureCoordinate
    public let clampedChannelCount: Int

    public init(
        width: Int,
        height: Int,
        linearRGBA16Float: Data,
        unlitTextureCoordinate: GModWorldTextureCoordinate,
        clampedChannelCount: Int
    ) {
        self.width = width
        self.height = height
        self.linearRGBA16Float = linearRGBA16Float
        self.unlitTextureCoordinate = unlitTextureCoordinate
        self.clampedChannelCount = clampedChannelCount
    }
}

public enum GModWorldLightmapAtlasStatus: Sendable, Equatable {
    case unavailableNoLightmaps
    case built(width: Int, height: Int, byteCount: Int)
    case capacityExceeded(
        requiredWidth: Int,
        requiredHeight: Int,
        requiredByteCount: Int,
        maximumWidth: Int,
        maximumHeight: Int,
        maximumByteCount: Int
    )
}

public struct GModWorldRenderMeshDiagnostics: Sendable, Equatable {
    public let sourceFaceCount: Int
    public let emittedFaceCount: Int
    public let degenerateFaceCount: Int
    public let displacementBaseFaceCount: Int
    public let skippedToolOrSkyFaceCount: Int
    public let skySurfaceFaceCount: Int
    public let skippedToolFaceCount: Int
    public let cubemapBaseFallbackFaceCount: Int
    /// Unique generated `maps/<map>/..._<x>_<y>_<z>` source names.
    public let cubemapBaseFallbackMaterialCount: Int
    /// Unique base material names actually handed to the authorized resolver.
    public let cubemapBaseFallbackTargetMaterialCount: Int
    public let lightmappedFaceCount: Int
    public let unlightmappedFaceCount: Int
    public let lightmapAtlasStatus: GModWorldLightmapAtlasStatus
    public let ignoredAdditionalLightStyleFaceCount: Int
    public let ignoredBumpLightFaceCount: Int
    public let emittedDisplacementVertexCount: Int
    public let emittedDisplacementTriangleCount: Int
    public let removedDisplacementTriangleCount: Int
    public let maximumDisplacementOffsetFromBase: Float
    public let displacementCollisionIsBrushOnly: Bool
    public let waterSurfaceFaceCount: Int
    public let waterBelowSurfaceFaceCount: Int

    public init(
        sourceFaceCount: Int,
        emittedFaceCount: Int,
        degenerateFaceCount: Int,
        displacementBaseFaceCount: Int,
        skippedToolOrSkyFaceCount: Int = 0,
        skySurfaceFaceCount: Int = 0,
        skippedToolFaceCount: Int = 0,
        cubemapBaseFallbackFaceCount: Int = 0,
        cubemapBaseFallbackMaterialCount: Int = 0,
        cubemapBaseFallbackTargetMaterialCount: Int = 0,
        lightmappedFaceCount: Int = 0,
        unlightmappedFaceCount: Int = 0,
        lightmapAtlasStatus: GModWorldLightmapAtlasStatus = .unavailableNoLightmaps,
        ignoredAdditionalLightStyleFaceCount: Int = 0,
        ignoredBumpLightFaceCount: Int = 0,
        emittedDisplacementVertexCount: Int = 0,
        emittedDisplacementTriangleCount: Int = 0,
        removedDisplacementTriangleCount: Int = 0,
        maximumDisplacementOffsetFromBase: Float = 0,
        displacementCollisionIsBrushOnly: Bool = true,
        waterSurfaceFaceCount: Int = 0,
        waterBelowSurfaceFaceCount: Int = 0
    ) {
        self.sourceFaceCount = sourceFaceCount
        self.emittedFaceCount = emittedFaceCount
        self.degenerateFaceCount = degenerateFaceCount
        self.displacementBaseFaceCount = displacementBaseFaceCount
        self.skippedToolOrSkyFaceCount = skippedToolOrSkyFaceCount
        self.skySurfaceFaceCount = skySurfaceFaceCount
        self.skippedToolFaceCount = skippedToolFaceCount
        self.cubemapBaseFallbackFaceCount = cubemapBaseFallbackFaceCount
        self.cubemapBaseFallbackMaterialCount = cubemapBaseFallbackMaterialCount
        self.cubemapBaseFallbackTargetMaterialCount =
            cubemapBaseFallbackTargetMaterialCount
        self.lightmappedFaceCount = lightmappedFaceCount
        self.unlightmappedFaceCount = unlightmappedFaceCount
        self.lightmapAtlasStatus = lightmapAtlasStatus
        self.ignoredAdditionalLightStyleFaceCount =
            ignoredAdditionalLightStyleFaceCount
        self.ignoredBumpLightFaceCount = ignoredBumpLightFaceCount
        self.emittedDisplacementVertexCount = emittedDisplacementVertexCount
        self.emittedDisplacementTriangleCount = emittedDisplacementTriangleCount
        self.removedDisplacementTriangleCount = removedDisplacementTriangleCount
        self.maximumDisplacementOffsetFromBase = maximumDisplacementOffsetFromBase
        self.displacementCollisionIsBrushOnly = displacementCollisionIsBrushOnly
        self.waterSurfaceFaceCount = waterSurfaceFaceCount
        self.waterBelowSurfaceFaceCount = waterBelowSurfaceFaceCount
    }
}

struct GModWorldRenderMeshAllocationEstimate: Sendable, Equatable {
    let worldVertexCount: Int
    let worldIndexCount: Int
    let displacementVertexCount: Int
    let displacementIndexCount: Int
    let worldVertexWorkingByteCount: UInt64
    let worldIndexWorkingByteCount: UInt64
    let displacementVertexWorkingByteCount: UInt64
    let displacementIndexWorkingByteCount: UInt64
}

/// A renderer-neutral triangulation of BSP model 0 in Source coordinates.
///
/// Each ordinary face keeps its own vertices so its plane normal remains
/// exact. Displacement faces expand Source's real oriented power grid, vector
/// field, recursive triangle topology, base UVs, and displacement lightmap UVs.
/// Material names, Source base UVs, bounded per-face lightmap coordinates, and
/// a capped first-style/base-bump atlas are preserved for a host renderer.
/// Displacement collision, additional styles/bump planes, and PVS remain
/// separate milestones and are not fabricated here.
public struct GModWorldRenderMesh: Sendable, Equatable {
    public let vertices: [GModWorldRenderVertex]
    public let indices: [UInt32]
    public let minimum: SourceVector3
    public let maximum: SourceVector3
    public let materialRanges: [GModWorldMaterialRange]
    public let skybox: GModWorldSkybox?
    public let sky3D: GModWorldSky3D?
    public let skyVisibility: GModWorldSkyVisibility?
    public let lightmapAtlas: GModWorldLightmapAtlas?
    public let diagnostics: GModWorldRenderMeshDiagnostics

    public init(
        vertices: [GModWorldRenderVertex],
        indices: [UInt32],
        minimum: SourceVector3,
        maximum: SourceVector3,
        materialRanges: [GModWorldMaterialRange] = [],
        skybox: GModWorldSkybox? = nil,
        sky3D: GModWorldSky3D? = nil,
        skyVisibility: GModWorldSkyVisibility? = nil,
        lightmapAtlas: GModWorldLightmapAtlas? = nil,
        diagnostics: GModWorldRenderMeshDiagnostics
    ) {
        self.vertices = vertices
        self.indices = indices
        self.minimum = minimum
        self.maximum = maximum
        self.materialRanges = materialRanges
        self.skybox = skybox
        self.sky3D = sky3D
        self.skyVisibility = skyVisibility
        self.lightmapAtlas = lightmapAtlas
        self.diagnostics = diagnostics
    }

    public var triangleCount: Int { indices.count / 3 }

    public static func build(
        from bsp: SourceBSP,
        allocationPolicy: GModMapAllocationPolicy = .iPadValidated
    ) throws -> Self {
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

        let skyName = try bsp.worldspawnValue(forKey: "skyname")
            .flatMap(Self.normalizedSkyName)
        let sky3DContext = try Self.sky3DContext(in: bsp)
        let skyVisibility = Self.skyVisibility(in: bsp)
        let allocationEstimate = try Self.allocationEstimate(
            from: bsp,
            firstFace: firstFace,
            endFace: endFace,
            includesSkybox: skyName != nil,
            policy: allocationPolicy
        )

        var vertices: [GModWorldRenderVertex] = []
        vertices.reserveCapacity(allocationEstimate.worldVertexCount)
        var materialIndices: [GModWorldMaterialBucketKey: [UInt32]] = [:]
        var materialOrder: [GModWorldMaterialBucketKey] = []
        var sourceMaterialNames: [GModWorldMaterialBucketKey: Set<String>] = [:]
        var resolverMaterialNames: [GModWorldMaterialBucketKey: String] = [:]
        var waterSurfaces: [GModWorldMaterialBucketKey: GModWorldWaterSurface] = [:]
        var pendingLightmapCoordinates: [PendingLightmapCoordinate?] = []
        pendingLightmapCoordinates.reserveCapacity(
            allocationEstimate.worldVertexCount
        )
        var lightmapLayout = LightmapAtlasLayout()
        var emittedFaces = 0
        var degenerateFaces = 0
        var displacementFaces = 0
        var skySurfaceFaces = 0
        var skippedToolFaces = 0
        var cubemapBaseFallbackFaces = 0
        var cubemapBaseFallbackMaterials = Set<String>()
        var cubemapBaseFallbackTargetMaterials = Set<String>()
        var lightmappedFaces = 0
        var unlightmappedFaces = 0
        var ignoredAdditionalLightStyleFaces = 0
        var ignoredBumpLightFaces = 0
        var emittedDisplacementVertices = 0
        var emittedDisplacementTriangles = 0
        var removedDisplacementTriangles = 0
        var maximumDisplacementOffset: Float = 0
        var waterSurfaceFaces = 0
        var waterBelowSurfaceFaces = 0
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
            let renderLayer: GModWorldRenderLayer =
                sky3DContext?.faceIndices.contains(faceIndex) == true
                    ? .sky3D
                    : .world
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
            let basePoints = try Self.facePoints(
                faceIndex: faceIndex,
                firstSurfaceEdge: firstSurfaceEdge,
                endSurfaceEdge: endSurfaceEdge,
                in: bsp
            )
            let displacement = bsp.displacement(forFaceAt: faceIndex)
            let requiredVertexCount = displacement?.vertexCount ?? surfaceEdgeCount
            guard vertices.count <= Int(UInt32.max) - requiredVertexCount else {
                throw GModWorldRenderMeshError.indexCapacityExceeded
            }
            let baseIndex = UInt32(vertices.count)

            let material = try Self.material(for: face, in: bsp, faceIndex: faceIndex)
            if let info = material.info, Self.isSkySurface(flags: info.flags) {
                skySurfaceFaces += 1
                continue
            }
            if let info = material.info, Self.isToolSurface(flags: info.flags) {
                skippedToolFaces += 1
                continue
            }
            let sourceMaterialName = material.name?.replacingOccurrences(
                of: "\\",
                with: "/"
            )
            let fallbackMaterialName = sourceMaterialName.flatMap(
                Self.cubemapBaseMaterialName
            )
            if let fallbackMaterialName {
                cubemapBaseFallbackFaces += 1
                cubemapBaseFallbackTargetMaterials.insert(
                    fallbackMaterialName.lowercased()
                )
                if let sourceMaterialName {
                    cubemapBaseFallbackMaterials.insert(sourceMaterialName.lowercased())
                }
            }
            let resolverMaterialKey = (fallbackMaterialName ?? sourceMaterialName)?
                .lowercased() ?? ""
            let matchedWaterSurface = Self.waterSurface(
                for: basePoints,
                textureInfoIndex: Int(face.textureInfoIndex),
                materialInfo: material.info,
                in: bsp
            )
            let bucketMaterial: String
            if let matchedWaterSurface {
                bucketMaterial = resolverMaterialKey + "\u{1F}water:" +
                    String(matchedWaterSurface.surfaceZ.bitPattern) + ":" +
                    String(matchedWaterSurface.minimumZ.bitPattern)
                waterSurfaceFaces += 1
                if Int(face.textureInfoIndex) !=
                    matchedWaterSurface.sourceTextureInfoIndex {
                    waterBelowSurfaceFaces += 1
                }
            } else {
                bucketMaterial = resolverMaterialKey
            }
            let materialKey = GModWorldMaterialBucketKey(
                material: bucketMaterial,
                renderLayer: renderLayer
            )
            if let matchedWaterSurface {
                waterSurfaces[materialKey] = matchedWaterSurface
            }
            resolverMaterialNames[materialKey] = resolverMaterialKey
            if materialIndices[materialKey] == nil {
                materialIndices[materialKey] = []
                materialOrder.append(materialKey)
            }
            if let sourceMaterialName {
                sourceMaterialNames[materialKey, default: []].insert(sourceMaterialName)
            }
            let faceLightmap = bsp.lightmap(forFaceAt: faceIndex)
            let lightmapPlacement: LightmapAtlasPlacement?
            if let faceLightmap {
                lightmappedFaces += 1
                if faceLightmap.styleCount > 1 {
                    ignoredAdditionalLightStyleFaces += 1
                }
                if faceLightmap.bumpSampleCount > 1 {
                    ignoredBumpLightFaces += 1
                }
                lightmapPlacement = lightmapLayout.append(
                    faceIndex: faceIndex,
                    lightmap: faceLightmap
                )
            } else {
                unlightmappedFaces += 1
                lightmapPlacement = nil
            }

            if let displacement {
                let geometry = try Self.generateDisplacementGeometry(
                    faceIndex: faceIndex,
                    basePoints: basePoints,
                    faceNormal: normal,
                    materialInfo: material.info,
                    materialData: material.data,
                    lightmap: faceLightmap,
                    displacement: displacement,
                    bsp: bsp
                )
                for vertex in geometry.vertices {
                    if let lightmapUV = vertex.lightmapCoordinate,
                       let lightmapPlacement {
                        pendingLightmapCoordinates.append(PendingLightmapCoordinate(
                            local: lightmapUV,
                            placement: lightmapPlacement
                        ))
                    } else {
                        pendingLightmapCoordinates.append(nil)
                    }
                    let emittedVertex: GModWorldRenderVertex
                    if renderLayer == .sky3D, let sky3DContext {
                        emittedVertex = GModWorldRenderVertex(
                            position: sky3DContext.transform(vertex.position),
                            normal: vertex.normal,
                            textureCoordinate: vertex.textureCoordinate,
                            lightmapCoordinate: vertex.lightmapCoordinate
                        )
                    } else {
                        emittedVertex = vertex
                    }
                    vertices.append(emittedVertex)
                    minimum.x = Swift.min(minimum.x, emittedVertex.position.x)
                    minimum.y = Swift.min(minimum.y, emittedVertex.position.y)
                    minimum.z = Swift.min(minimum.z, emittedVertex.position.z)
                    maximum.x = Swift.max(maximum.x, emittedVertex.position.x)
                    maximum.y = Swift.max(maximum.y, emittedVertex.position.y)
                    maximum.z = Swift.max(maximum.z, emittedVertex.position.z)
                }
                for index in geometry.localIndices {
                    materialIndices[materialKey, default: []].append(baseIndex + index)
                }
                emittedDisplacementVertices += geometry.vertices.count
                emittedDisplacementTriangles += geometry.localIndices.count / 3
                removedDisplacementTriangles += geometry.removedTriangleCount
                maximumDisplacementOffset = Swift.max(
                    maximumDisplacementOffset,
                    geometry.maximumOffsetFromBase
                )
            } else {
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
                let lightmapUV: GModWorldTextureCoordinate?
                if let coordinate = faceLightmap?.textureCoordinate(at: point) {
                    guard coordinate.normalizedU.isFinite,
                          coordinate.normalizedV.isFinite else {
                        throw GModWorldRenderMeshError.nonFiniteLightmapCoordinate(
                            face: faceIndex
                        )
                    }
                    lightmapUV = GModWorldTextureCoordinate(
                        u: coordinate.normalizedU,
                        v: coordinate.normalizedV
                    )
                } else {
                    lightmapUV = nil
                }
                if let lightmapUV, let lightmapPlacement {
                    pendingLightmapCoordinates.append(PendingLightmapCoordinate(
                        local: lightmapUV,
                        placement: lightmapPlacement
                    ))
                } else {
                    pendingLightmapCoordinates.append(nil)
                }
                let emittedPosition = renderLayer == .sky3D
                    ? sky3DContext?.transform(position) ?? position
                    : position
                vertices.append(
                    GModWorldRenderVertex(
                        position: emittedPosition,
                        normal: normal,
                        textureCoordinate: uv,
                        lightmapCoordinate: lightmapUV
                    )
                )
                minimum.x = Swift.min(minimum.x, emittedPosition.x)
                minimum.y = Swift.min(minimum.y, emittedPosition.y)
                minimum.z = Swift.min(minimum.z, emittedPosition.z)
                maximum.x = Swift.max(maximum.x, emittedPosition.x)
                maximum.y = Swift.max(maximum.y, emittedPosition.y)
                maximum.z = Swift.max(maximum.z, emittedPosition.z)
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
            }
            emittedFaces += 1
        }

        if emittedFaces == 0 {
            minimum = .zero
            maximum = .zero
        }

        let skybox: GModWorldSkybox?
        if let skyName, skySurfaceFaces > 0 {
            var names: [String] = []
            names.reserveCapacity(6)
            for face in Self.skyboxFaces(named: skyName) {
                guard vertices.count <= Int(UInt32.max) - 4 else {
                    throw GModWorldRenderMeshError.indexCapacityExceeded
                }
                let baseIndex = UInt32(vertices.count)
                let materialKey = GModWorldMaterialBucketKey(
                    material: face.materialName.lowercased(),
                    renderLayer: .sky2D
                )
                if materialIndices[materialKey] == nil {
                    materialIndices[materialKey] = []
                    materialOrder.append(materialKey)
                }
                sourceMaterialNames[materialKey, default: []].insert(face.materialName)
                names.append(face.materialName)
                for corner in face.corners {
                    pendingLightmapCoordinates.append(nil)
                    vertices.append(
                        GModWorldRenderVertex(
                            position: corner.position,
                            normal: face.normal,
                            textureCoordinate: corner.textureCoordinate
                        )
                    )
                }
                materialIndices[materialKey, default: []].append(contentsOf: [
                    baseIndex,
                    baseIndex + 2,
                    baseIndex + 1,
                    baseIndex,
                    baseIndex + 3,
                    baseIndex + 2,
                ])
            }
            skybox = GModWorldSkybox(
                name: skyName,
                sourceSkySurfaceCount: skySurfaceFaces,
                materialNames: names
            )
        } else {
            skybox = nil
        }

        let lightmapResult = Self.makeLightmapAtlas(
            from: lightmapLayout,
            allocationPolicy: allocationPolicy
        )
        let lightmapAtlas = lightmapResult.atlas
        if let lightmapAtlas {
            precondition(pendingLightmapCoordinates.count == vertices.count)
            vertices = zip(vertices, pendingLightmapCoordinates).map { vertex, pending in
                let atlasCoordinate: GModWorldTextureCoordinate?
                if let pending {
                    atlasCoordinate = GModWorldTextureCoordinate(
                        u: (
                            Float(pending.placement.contentX) +
                                pending.local.u * Float(pending.placement.width)
                        ) / Float(lightmapAtlas.width),
                        v: (
                            Float(pending.placement.contentY) +
                                pending.local.v * Float(pending.placement.height)
                        ) / Float(lightmapAtlas.height)
                    )
                } else {
                    atlasCoordinate = nil
                }
                return GModWorldRenderVertex(
                    position: vertex.position,
                    normal: vertex.normal,
                    textureCoordinate: vertex.textureCoordinate,
                    lightmapCoordinate: atlasCoordinate
                )
            }
        } else {
            vertices = vertices.map {
                GModWorldRenderVertex(
                    position: $0.position,
                    normal: $0.normal,
                    textureCoordinate: $0.textureCoordinate,
                    lightmapCoordinate: nil
                )
            }
        }

        var indices: [UInt32] = []
        indices.reserveCapacity(allocationEstimate.worldIndexCount)
        var materialRanges: [GModWorldMaterialRange] = []
        for key in materialOrder {
            let grouped = materialIndices[key] ?? []
            let firstIndex = indices.count
            indices.append(contentsOf: grouped)
            materialRanges.append(
                GModWorldMaterialRange(
                    materialName: (resolverMaterialNames[key] ?? key.material).isEmpty
                        ? nil
                        : (resolverMaterialNames[key] ?? key.material),
                    firstIndex: firstIndex,
                    indexCount: grouped.count,
                    sourceMaterialNames: sourceMaterialNames[key, default: []].sorted {
                        $0.lowercased() < $1.lowercased()
                    },
                    waterSurface: waterSurfaces[key],
                    renderLayer: key.renderLayer
                )
            )
        }
        let sky3D = sky3DContext.map {
            GModWorldSky3D(
                origin: $0.origin,
                scale: $0.scale,
                area: $0.area,
                cluster: $0.cluster,
                sourceFaceCount: $0.faceIndices.count
            )
        }
        return Self(
            vertices: vertices,
            indices: indices,
            minimum: minimum,
            maximum: maximum,
            materialRanges: materialRanges,
            skybox: skybox,
            sky3D: sky3D,
            skyVisibility: skyVisibility,
            lightmapAtlas: lightmapAtlas,
            diagnostics: GModWorldRenderMeshDiagnostics(
                sourceFaceCount: faceCount,
                emittedFaceCount: emittedFaces,
                degenerateFaceCount: degenerateFaces,
                displacementBaseFaceCount: displacementFaces,
                skippedToolOrSkyFaceCount: skySurfaceFaces + skippedToolFaces,
                skySurfaceFaceCount: skySurfaceFaces,
                skippedToolFaceCount: skippedToolFaces,
                cubemapBaseFallbackFaceCount: cubemapBaseFallbackFaces,
                cubemapBaseFallbackMaterialCount: cubemapBaseFallbackMaterials.count,
                cubemapBaseFallbackTargetMaterialCount:
                    cubemapBaseFallbackTargetMaterials.count,
                lightmappedFaceCount: lightmappedFaces,
                unlightmappedFaceCount: unlightmappedFaces,
                lightmapAtlasStatus: lightmapResult.status,
                ignoredAdditionalLightStyleFaceCount:
                    ignoredAdditionalLightStyleFaces,
                ignoredBumpLightFaceCount: ignoredBumpLightFaces,
                emittedDisplacementVertexCount: emittedDisplacementVertices,
                emittedDisplacementTriangleCount: emittedDisplacementTriangles,
                removedDisplacementTriangleCount: removedDisplacementTriangles,
                maximumDisplacementOffsetFromBase: maximumDisplacementOffset,
                displacementCollisionIsBrushOnly: true,
                waterSurfaceFaceCount: waterSurfaceFaces,
                waterBelowSurfaceFaceCount: waterBelowSurfaceFaces
            )
        )
    }

    static func allocationEstimate(
        from bsp: SourceBSP,
        allocationPolicy: GModMapAllocationPolicy = .iPadValidated
    ) throws -> GModWorldRenderMeshAllocationEstimate {
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
        let includesSkybox = try bsp.worldspawnValue(forKey: "skyname")
            .flatMap(Self.normalizedSkyName) != nil
        return try allocationEstimate(
            from: bsp,
            firstFace: firstFace,
            endFace: endFace,
            includesSkybox: includesSkybox,
            policy: allocationPolicy
        )
    }

    private static func allocationEstimate(
        from bsp: SourceBSP,
        firstFace: Int,
        endFace: Int,
        includesSkybox: Bool,
        policy: GModMapAllocationPolicy
    ) throws -> GModWorldRenderMeshAllocationEstimate {
        var worldVertexCount: UInt64 = 0
        var worldIndexCount: UInt64 = 0
        var displacementVertexCount: UInt64 = 0
        var displacementIndexCount: UInt64 = 0

        for faceIndex in firstFace..<endFace {
            let face = bsp.faces[faceIndex]
            guard face.surfaceEdgeCount >= 3 else { continue }
            let surfaceEdgeCount = UInt64(face.surfaceEdgeCount)
            if let displacement = bsp.displacement(forFaceAt: faceIndex) {
                let vertices = UInt64(displacement.vertexCount)
                let indices = try allocationProduct(
                    UInt64(displacement.triangleCount),
                    3,
                    resource: .displacementIndexWorkingBytes,
                    policy: policy
                )
                try allocationAdd(
                    vertices,
                    to: &worldVertexCount,
                    resource: .worldVertexWorkingBytes,
                    policy: policy
                )
                try allocationAdd(
                    indices,
                    to: &worldIndexCount,
                    resource: .worldIndexWorkingBytes,
                    policy: policy
                )
                try allocationAdd(
                    vertices,
                    to: &displacementVertexCount,
                    resource: .displacementVertexWorkingBytes,
                    policy: policy
                )
                try allocationAdd(
                    indices,
                    to: &displacementIndexCount,
                    resource: .displacementIndexWorkingBytes,
                    policy: policy
                )
            } else {
                let triangleCount = surfaceEdgeCount - 2
                let indices = try allocationProduct(
                    triangleCount,
                    3,
                    resource: .worldIndexWorkingBytes,
                    policy: policy
                )
                try allocationAdd(
                    surfaceEdgeCount,
                    to: &worldVertexCount,
                    resource: .worldVertexWorkingBytes,
                    policy: policy
                )
                try allocationAdd(
                    indices,
                    to: &worldIndexCount,
                    resource: .worldIndexWorkingBytes,
                    policy: policy
                )
            }
        }

        // A named Source sky adds six quads. Counting it even when a malformed
        // map has no sky-marked face is conservative and keeps preflight ahead
        // of every possible sky allocation.
        if includesSkybox {
            try allocationAdd(
                24,
                to: &worldVertexCount,
                resource: .worldVertexWorkingBytes,
                policy: policy
            )
            try allocationAdd(
                36,
                to: &worldIndexCount,
                resource: .worldIndexWorkingBytes,
                policy: policy
            )
        }

        // Peak world construction retains the original/remapped vertex arrays
        // plus one pending lightmap coordinate, and grouped/final index arrays.
        let worldVertexWorkingStride =
            MemoryLayout<GModWorldRenderVertex>.stride * 2 +
            MemoryLayout<PendingLightmapCoordinate?>.stride
        let worldIndexWorkingStride = MemoryLayout<UInt32>.stride * 2

        // One displacement face temporarily retains generated render vertices,
        // positions, UVs, optional lightmap UVs, accumulated normals/counts,
        // plus generated and filtered index arrays. Total-map counts are a
        // deliberately conservative upper bound over that per-face lifetime.
        let displacementVertexWorkingStride =
            MemoryLayout<GModWorldRenderVertex>.stride +
            MemoryLayout<SourceVector3>.stride * 2 +
            MemoryLayout<GModWorldTextureCoordinate>.stride +
            MemoryLayout<GModWorldTextureCoordinate?>.stride +
            MemoryLayout<Int>.stride
        let displacementIndexWorkingStride = MemoryLayout<UInt32>.stride * 2

        let worldVertexBytes = try allocationBytes(
            count: worldVertexCount,
            stride: worldVertexWorkingStride,
            resource: .worldVertexWorkingBytes,
            policy: policy
        )
        let worldIndexBytes = try allocationBytes(
            count: worldIndexCount,
            stride: worldIndexWorkingStride,
            resource: .worldIndexWorkingBytes,
            policy: policy
        )
        let displacementVertexBytes = try allocationBytes(
            count: displacementVertexCount,
            stride: displacementVertexWorkingStride,
            resource: .displacementVertexWorkingBytes,
            policy: policy
        )
        let displacementIndexBytes = try allocationBytes(
            count: displacementIndexCount,
            stride: displacementIndexWorkingStride,
            resource: .displacementIndexWorkingBytes,
            policy: policy
        )

        guard let worldVertices = Int(exactly: worldVertexCount),
              let worldIndices = Int(exactly: worldIndexCount),
              let displacementVertices = Int(exactly: displacementVertexCount),
              let displacementIndices = Int(exactly: displacementIndexCount) else {
            throw GModMapAllocationPolicyError(
                resource: .worldVertexWorkingBytes,
                requestedByteCount: UInt64.max,
                maximumByteCount: policy.maximumWorldVertexWorkingByteCount
            )
        }
        return GModWorldRenderMeshAllocationEstimate(
            worldVertexCount: worldVertices,
            worldIndexCount: worldIndices,
            displacementVertexCount: displacementVertices,
            displacementIndexCount: displacementIndices,
            worldVertexWorkingByteCount: worldVertexBytes,
            worldIndexWorkingByteCount: worldIndexBytes,
            displacementVertexWorkingByteCount: displacementVertexBytes,
            displacementIndexWorkingByteCount: displacementIndexBytes
        )
    }

    private static func allocationAdd(
        _ value: UInt64,
        to total: inout UInt64,
        resource: GModMapAllocationResource,
        policy: GModMapAllocationPolicy
    ) throws {
        let addition = total.addingReportingOverflow(value)
        guard !addition.overflow else {
            throw GModMapAllocationPolicyError(
                resource: resource,
                requestedByteCount: UInt64.max,
                maximumByteCount: policy.maximumByteCount(for: resource)
            )
        }
        total = addition.partialValue
    }

    private static func allocationProduct(
        _ lhs: UInt64,
        _ rhs: UInt64,
        resource: GModMapAllocationResource,
        policy: GModMapAllocationPolicy
    ) throws -> UInt64 {
        let product = lhs.multipliedReportingOverflow(by: rhs)
        guard !product.overflow else {
            throw GModMapAllocationPolicyError(
                resource: resource,
                requestedByteCount: UInt64.max,
                maximumByteCount: policy.maximumByteCount(for: resource)
            )
        }
        return product.partialValue
    }

    private static func allocationBytes(
        count: UInt64,
        stride: Int,
        resource: GModMapAllocationResource,
        policy: GModMapAllocationPolicy
    ) throws -> UInt64 {
        let requested = try allocationProduct(
            count,
            UInt64(stride),
            resource: resource,
            policy: policy
        )
        try policy.validate(resource, requestedByteCount: requested)
        return requested
    }

    private struct LightmapAtlasPlacement {
        let contentX: Int
        let contentY: Int
        let width: Int
        let height: Int
    }

    private struct PendingLightmapCoordinate {
        let local: GModWorldTextureCoordinate
        let placement: LightmapAtlasPlacement
    }

    private struct LightmapAtlasEntry {
        let faceIndex: Int
        let lightmap: SourceBSPFaceLightmap
        let placement: LightmapAtlasPlacement
    }

    private struct LightmapAtlasLayout {
        static let width = 2_048
        static let maximumHeight = 4_096

        // The first 3x3 block is a filtered white fallback for unlightmapped
        // surfaces. Every real face also receives a one-texel duplicated gutter.
        private var cursorX = 3
        private var cursorY = 0
        private var shelfHeight = 3
        private(set) var requiredWidth = width
        private(set) var requiredHeight = 3
        private(set) var hasUnplaceableWidth = false
        private(set) var entries: [LightmapAtlasEntry] = []

        mutating func append(
            faceIndex: Int,
            lightmap: SourceBSPFaceLightmap
        ) -> LightmapAtlasPlacement? {
            let expandedWidth = lightmap.width + 2
            let expandedHeight = lightmap.height + 2
            guard expandedWidth <= Self.width else {
                requiredWidth = Swift.max(requiredWidth, expandedWidth)
                hasUnplaceableWidth = true
                return nil
            }
            if cursorX + expandedWidth > Self.width {
                cursorY += shelfHeight
                cursorX = 0
                shelfHeight = 0
            }
            let placement = LightmapAtlasPlacement(
                contentX: cursorX + 1,
                contentY: cursorY + 1,
                width: lightmap.width,
                height: lightmap.height
            )
            entries.append(LightmapAtlasEntry(
                faceIndex: faceIndex,
                lightmap: lightmap,
                placement: placement
            ))
            cursorX += expandedWidth
            shelfHeight = Swift.max(shelfHeight, expandedHeight)
            requiredHeight = Swift.max(requiredHeight, cursorY + shelfHeight)
            return placement
        }
    }

    private struct LightmapAtlasResult {
        let atlas: GModWorldLightmapAtlas?
        let status: GModWorldLightmapAtlasStatus
    }

    private static func makeLightmapAtlas(
        from layout: LightmapAtlasLayout,
        allocationPolicy: GModMapAllocationPolicy
    ) -> LightmapAtlasResult {
        guard !layout.entries.isEmpty else {
            return LightmapAtlasResult(
                atlas: nil,
                status: .unavailableNoLightmaps
            )
        }
        let requiredWidth = layout.requiredWidth
        let requiredHeight = layout.requiredHeight
        let pixelCount = requiredWidth.multipliedReportingOverflow(
            by: requiredHeight
        )
        let requiredBytes = pixelCount.partialValue.multipliedReportingOverflow(by: 8)
        let byteCount = pixelCount.overflow || requiredBytes.overflow
            ? Int.max
            : requiredBytes.partialValue
        let maximumByteCount = Int(
            Swift.min(
                UInt64(Int.max),
                allocationPolicy.maximumLightmapAtlasByteCount
            )
        )
        let isWithinAllocationPolicy = (try? allocationPolicy.validate(
            .lightmapAtlasBytes,
            requestedByteCount: UInt64(byteCount)
        )) != nil
        guard !layout.hasUnplaceableWidth,
              requiredWidth <= LightmapAtlasLayout.width,
              requiredHeight <= LightmapAtlasLayout.maximumHeight,
              isWithinAllocationPolicy else {
            return LightmapAtlasResult(
                atlas: nil,
                status: .capacityExceeded(
                    requiredWidth: requiredWidth,
                    requiredHeight: requiredHeight,
                    requiredByteCount: byteCount,
                    maximumWidth: LightmapAtlasLayout.width,
                    maximumHeight: LightmapAtlasLayout.maximumHeight,
                    maximumByteCount: maximumByteCount
                )
            )
        }

        let width = LightmapAtlasLayout.width
        let height = requiredHeight
        var bytes = Data(count: width * height * 8)
        var clampedChannelCount = 0
        bytes.withUnsafeMutableBytes { rawBytes in
            let texels = rawBytes.bindMemory(to: UInt16.self)
            let one = Float16(1).bitPattern.littleEndian

            func halfBits(_ value: Float) -> UInt16 {
                let bounded: Float
                if !value.isFinite {
                    bounded = value.sign == .minus ? 0 : 65_504
                    clampedChannelCount += 1
                } else if value < 0 {
                    bounded = 0
                    clampedChannelCount += 1
                } else if value > 65_504 {
                    bounded = 65_504
                    clampedChannelCount += 1
                } else {
                    bounded = value
                }
                return Float16(bounded).bitPattern.littleEndian
            }

            func write(
                x: Int,
                y: Int,
                red: Float,
                green: Float,
                blue: Float
            ) {
                let component = (y * width + x) * 4
                texels[component] = halfBits(red)
                texels[component + 1] = halfBits(green)
                texels[component + 2] = halfBits(blue)
                texels[component + 3] = one
            }

            for y in 0..<3 {
                for x in 0..<3 {
                    write(x: x, y: y, red: 1, green: 1, blue: 1)
                }
            }
            for entry in layout.entries {
                let placement = entry.placement
                for expandedY in 0..<(placement.height + 2) {
                    let sampleY = Swift.min(
                        placement.height - 1,
                        Swift.max(0, expandedY - 1)
                    )
                    for expandedX in 0..<(placement.width + 2) {
                        let sampleX = Swift.min(
                            placement.width - 1,
                            Swift.max(0, expandedX - 1)
                        )
                        guard let sample = entry.lightmap.sample(
                            x: sampleX,
                            y: sampleY
                        ) else { continue }
                        let color = sample.linearColor
                        write(
                            x: placement.contentX + expandedX - 1,
                            y: placement.contentY + expandedY - 1,
                            red: color.x,
                            green: color.y,
                            blue: color.z
                        )
                    }
                }
            }
        }
        let atlas = GModWorldLightmapAtlas(
            width: width,
            height: height,
            linearRGBA16Float: bytes,
            unlitTextureCoordinate: GModWorldTextureCoordinate(
                u: 1.5 / Float(width),
                v: 1.5 / Float(height)
            ),
            clampedChannelCount: clampedChannelCount
        )
        return LightmapAtlasResult(
            atlas: atlas,
            status: .built(width: width, height: height, byteCount: bytes.count)
        )
    }

    private static func isFinite(_ value: SourceVector3) -> Bool {
        value.x.isFinite && value.y.isFinite && value.z.isFinite
    }

    private static func isSkySurface(flags: Int32) -> Bool {
        let sky2D: UInt32 = 0x0002
        let sky: UInt32 = 0x0004
        return UInt32(bitPattern: flags) & (sky2D | sky) != 0
    }

    private static func isToolSurface(flags: Int32) -> Bool {
        // Public Source SDK SURF_* flags. These faces participate in BSP
        // visibility/collision but are not ordinary world polygons.
        let trigger: UInt32 = 0x0040
        let noDraw: UInt32 = 0x0080
        let hint: UInt32 = 0x0100
        let skip: UInt32 = 0x0200
        let excluded = trigger | noDraw | hint | skip
        return UInt32(bitPattern: flags) & excluded != 0
    }

    /// Finds the real miniature 3D-sky area from `sky_camera`. Source changes
    /// the visible area and origin for this pass; model-zero membership alone
    /// is therefore insufficient and was the reason sky terrain leaked into
    /// the ordinary world. Full per-frame PVS remains a separate renderer
    /// milestone, while area membership is exact and available at build time.
    private static func sky3DContext(
        in bsp: SourceBSP
    ) throws -> GModWorldSky3DContext? {
        let entities = try bsp.entities.parsedEntities()
        guard let entity = entities.first(where: {
            $0.value(forKey: "classname")?
                .caseInsensitiveCompare("sky_camera") == .orderedSame
        }), let originText = entity.value(forKey: "origin"),
           let scaleText = entity.value(forKey: "scale"),
           let origin = sourceVector(from: originText),
           let scale = Float(
               scaleText.trimmingCharacters(in: .whitespacesAndNewlines)
           ), scale.isFinite, scale > 0 else {
            return nil
        }
        let leafIndex = try bsp.leafIndex(containing: origin)
        guard bsp.leaves.indices.contains(leafIndex) else { return nil }
        let cameraLeaf = bsp.leaves[leafIndex]
        let visibility: GModSourcePotentialVisibility?
        let visibilityLumpIndex = 4
        if bsp.lumps.indices.contains(visibilityLumpIndex),
           !bsp.lumps[visibilityLumpIndex].descriptor.isCompressed {
            visibility = GModSourcePotentialVisibility(
                data: bsp.lumps[visibilityLumpIndex].data
            )
        } else {
            visibility = nil
        }
        let visibleClusters = cameraLeaf.cluster >= 0
            ? visibility?.visibleClusters(from: Int(cameraLeaf.cluster))
            : nil
        var faceIndices = Set<Int>()
        for leaf in bsp.leaves where leaf.area == cameraLeaf.area {
            if let visibleClusters {
                guard leaf.cluster >= 0,
                      visibleClusters.contains(Int(leaf.cluster)) else {
                    continue
                }
            }
            let first = Int(leaf.firstLeafFace)
            let count = Int(leaf.leafFaceCount)
            let (end, overflow) = first.addingReportingOverflow(count)
            guard !overflow, first >= 0, end <= bsp.leafFaces.count else {
                continue
            }
            for index in first..<end {
                faceIndices.insert(Int(bsp.leafFaces[index]))
            }
        }
        guard !faceIndices.isEmpty else { return nil }
        return GModWorldSky3DContext(
            origin: origin,
            scale: scale,
            area: cameraLeaf.area,
            cluster: cameraLeaf.cluster,
            faceIndices: faceIndices
        )
    }

    private static func skyVisibility(
        in bsp: SourceBSP
    ) -> GModWorldSkyVisibility? {
        guard let world = bsp.models.first,
              !bsp.leaves.isEmpty else { return nil }
        return GModWorldSkyVisibility(
            headNode: world.headNode,
            planes: bsp.planes.map {
                GModWorldSkyVisibilityPlane(
                    normal: SourceVector3(
                        $0.normal.x,
                        $0.normal.y,
                        $0.normal.z
                    ),
                    distance: $0.distance
                )
            },
            nodes: bsp.nodes.map {
                GModWorldSkyVisibilityNode(
                    planeIndex: Int($0.planeIndex),
                    frontChild: $0.children[0],
                    backChild: $0.children[1]
                )
            },
            leafFlags: bsp.leaves.map(\.flags)
        )
    }

    private static func sourceVector(from value: String) -> SourceVector3? {
        let components = value.split(whereSeparator: { $0.isWhitespace })
        guard components.count == 3,
              let x = Float(components[0]),
              let y = Float(components[1]),
              let z = Float(components[2]) else { return nil }
        let vector = SourceVector3(x, y, z)
        return isFinite(vector) ? vector : nil
    }

    private static func normalizedSkyName(_ value: String) -> String? {
        var normalized = value
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if normalized.hasPrefix("skybox/") {
            normalized.removeFirst("skybox/".count)
        }
        if normalized.hasSuffix(".vmt") {
            normalized.removeLast(".vmt".count)
        }
        let components = normalized.split(separator: "/", omittingEmptySubsequences: false)
        guard !normalized.isEmpty,
              !normalized.hasPrefix("/"),
              !normalized.contains(":"),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            return nil
        }
        return normalized
    }

    /// Source's generated cubemap material path is
    /// `maps/<map>/<base>_<x>_<y>_<z>`. The current authorized ZIP/VPK resolver
    /// cannot mount LUMP_PAKFILE, but it can resolve every stock base material;
    /// retaining the exact source names in diagnostics makes this fallback
    /// explicit instead of silently drawing a blue solid range.
    private static func cubemapBaseMaterialName(_ value: String) -> String? {
        let normalized = value.replacingOccurrences(of: "\\", with: "/")
        var components = normalized.split(separator: "/").map(String.init)
        guard components.count >= 3,
              components[0].caseInsensitiveCompare("maps") == .orderedSame else {
            return nil
        }
        var fileName = components.removeLast()
        for _ in 0..<3 {
            guard let separator = fileName.lastIndex(of: "_") else { return nil }
            let coordinate = fileName[fileName.index(after: separator)...]
            guard Int32(coordinate) != nil else { return nil }
            fileName.removeSubrange(separator...)
        }
        guard !fileName.isEmpty else { return nil }
        // Remove `maps/<map>` and preserve any base-material subdirectories.
        components.removeFirst(2)
        components.append(fileName)
        return components.joined(separator: "/")
    }

    private struct SkyboxCorner {
        let position: SourceVector3
        let textureCoordinate: GModWorldTextureCoordinate
    }

    private struct SkyboxFace {
        let materialName: String
        let normal: SourceVector3
        let corners: [SkyboxCorner]
    }

    private static func skyboxFaces(named skyName: String) -> [SkyboxFace] {
        let extent: Float = 1_024
        let specifications: [(
            suffix: String,
            direction: SourceVector3,
            right: SourceVector3,
            down: SourceVector3
        )] = [
            ("rt", SourceVector3(0, -1, 0), SourceVector3(-1, 0, 0), SourceVector3(0, 0, -1)),
            ("bk", SourceVector3(-1, 0, 0), SourceVector3(0, 1, 0), SourceVector3(0, 0, -1)),
            ("lf", SourceVector3(0, 1, 0), SourceVector3(1, 0, 0), SourceVector3(0, 0, -1)),
            ("ft", SourceVector3(1, 0, 0), SourceVector3(0, -1, 0), SourceVector3(0, 0, -1)),
            ("up", SourceVector3(0, 0, 1), SourceVector3(0, -1, 0), SourceVector3(1, 0, 0)),
            ("dn", SourceVector3(0, 0, -1), SourceVector3(0, -1, 0), SourceVector3(-1, 0, 0)),
        ]
        let textureCorners: [GModWorldTextureCoordinate] = [
            GModWorldTextureCoordinate(u: 0, v: 0),
            GModWorldTextureCoordinate(u: 1, v: 0),
            GModWorldTextureCoordinate(u: 1, v: 1),
            GModWorldTextureCoordinate(u: 0, v: 1),
        ]
        return specifications.map { specification in
            let corners = textureCorners.map { coordinate -> SkyboxCorner in
                let horizontal = coordinate.u * 2 - 1
                let vertical = coordinate.v * 2 - 1
                return SkyboxCorner(
                    position: SourceVector3(
                        (specification.direction.x + specification.right.x * horizontal +
                            specification.down.x * vertical) * extent,
                        (specification.direction.y + specification.right.y * horizontal +
                            specification.down.y * vertical) * extent,
                        (specification.direction.z + specification.right.z * horizontal +
                            specification.down.z * vertical) * extent
                    ),
                    textureCoordinate: coordinate
                )
            }
            return SkyboxFace(
                materialName: "skybox/\(skyName)\(specification.suffix)",
                normal: SourceVector3(
                    -specification.direction.x,
                    -specification.direction.y,
                    -specification.direction.z
                ),
                corners: corners
            )
        }
    }

    private struct GeneratedDisplacementGeometry {
        let vertices: [GModWorldRenderVertex]
        let localIndices: [UInt32]
        let maximumOffsetFromBase: Float
        let removedTriangleCount: Int
    }

    private static func waterSurface(
        for points: [SourceBSPVector3],
        textureInfoIndex: Int,
        materialInfo: SourceBSPTextureInfo?,
        in bsp: SourceBSP
    ) -> GModWorldWaterSurface? {
        guard let materialInfo,
              UInt32(bitPattern: materialInfo.flags) & 0x0008 != 0,
              !points.isEmpty else { return nil }
        let averageZ = points.reduce(Float(0)) { $0 + $1.z } / Float(points.count)
        guard let nearest = bsp.leafWaterData.min(by: {
            abs($0.surfaceZ - averageZ) < abs($1.surfaceZ - averageZ)
        }), abs(nearest.surfaceZ - averageZ) <= 0.25 else { return nil }
        let water = bsp.leafWaterData.first {
            $0.surfaceTextureInfoIndex == Int16(textureInfoIndex) &&
                abs($0.surfaceZ - averageZ) <= 0.25
        } ?? nearest
        return GModWorldWaterSurface(
            surfaceZ: water.surfaceZ,
            minimumZ: water.minimumZ,
            sourceTextureInfoIndex: Int(water.surfaceTextureInfoIndex)
        )
    }

    private static func facePoints(
        faceIndex: Int,
        firstSurfaceEdge: Int,
        endSurfaceEdge: Int,
        in bsp: SourceBSP
    ) throws -> [SourceBSPVector3] {
        var result: [SourceBSPVector3] = []
        result.reserveCapacity(endSurfaceEdge - firstSurfaceEdge)
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
            guard bsp.vertices.indices.contains(vertexIndex) else {
                throw GModWorldRenderMeshError.invalidVertexIndex(
                    face: faceIndex,
                    index: vertexIndex,
                    available: bsp.vertices.count
                )
            }
            let point = bsp.vertices[vertexIndex].point
            guard point.x.isFinite, point.y.isFinite, point.z.isFinite else {
                throw GModWorldRenderMeshError.nonFiniteVertex(
                    face: faceIndex,
                    index: vertexIndex
                )
            }
            result.append(point)
        }
        return result
    }

    private static func generateDisplacementGeometry(
        faceIndex: Int,
        basePoints: [SourceBSPVector3],
        faceNormal: SourceVector3,
        materialInfo: SourceBSPTextureInfo?,
        materialData: SourceBSPTextureData?,
        lightmap: SourceBSPFaceLightmap?,
        displacement: SourceBSPDisplacementInfo,
        bsp: SourceBSP
    ) throws -> GeneratedDisplacementGeometry {
        guard basePoints.count == 4 else {
            throw GModWorldRenderMeshError.invalidDisplacementBaseFace(
                face: faceIndex,
                vertexCount: basePoints.count
            )
        }
        let start = SourceVector3(
            displacement.startPosition.x,
            displacement.startPosition.y,
            displacement.startPosition.z
        )
        let startCorner = basePoints.indices.min { lhs, rhs in
            let lhsPoint = SourceVector3(
                basePoints[lhs].x,
                basePoints[lhs].y,
                basePoints[lhs].z
            )
            let rhsPoint = SourceVector3(
                basePoints[rhs].x,
                basePoints[rhs].y,
                basePoints[rhs].z
            )
            return (lhsPoint - start).lengthSquared <
                (rhsPoint - start).lengthSquared
        } ?? 0
        let corners = (0..<4).map { offset -> SourceVector3 in
            let point = basePoints[(startCorner + offset) & 3]
            return SourceVector3(point.x, point.y, point.z)
        }

        let sideLength = displacement.sideLength
        let denominator = Float(sideLength - 1)
        let firstVertex = Int(displacement.firstVertex)
        var positions: [SourceVector3] = []
        var textureCoordinates: [GModWorldTextureCoordinate] = []
        var lightmapCoordinates: [GModWorldTextureCoordinate?] = []
        positions.reserveCapacity(displacement.vertexCount)
        textureCoordinates.reserveCapacity(displacement.vertexCount)
        lightmapCoordinates.reserveCapacity(displacement.vertexCount)
        var maximumOffset: Float = 0

        for y in 0..<sideLength {
            let vertical = Float(y) / denominator
            let left = lerp(corners[0], corners[1], vertical)
            let right = lerp(corners[3], corners[2], vertical)
            for x in 0..<sideLength {
                let horizontal = Float(x) / denominator
                let flatPoint = lerp(left, right, horizontal)
                let localIndex = y * sideLength + x
                let sourceVertex = bsp.displacementVertices[firstVertex + localIndex]
                let field = SourceVector3(
                    sourceVertex.vector.x,
                    sourceVertex.vector.y,
                    sourceVertex.vector.z
                )
                // Never normalize this field. VBSP's SnapRemainingVertsToSurface
                // stores direct offsets here with distance one.
                let offset = field * sourceVertex.distance
                let position = flatPoint + offset
                guard isFinite(position) else {
                    throw GModWorldRenderMeshError.nonFiniteDisplacementVertex(
                        face: faceIndex,
                        index: localIndex
                    )
                }
                positions.append(position)
                maximumOffset = Swift.max(maximumOffset, offset.length)

                let uv = try textureCoordinate(
                    at: flatPoint,
                    faceIndex: faceIndex,
                    info: materialInfo,
                    data: materialData
                )
                textureCoordinates.append(uv)

                if let lightmap {
                    // SDK CalcLuxelCoords interpolates the oriented surface
                    // corners (0.5 .. size+0.5); it does not project displaced
                    // positions through texinfo lightmap vectors.
                    let luxelS = 0.5 + horizontal * Float(lightmap.width - 1)
                    let luxelT = 0.5 + vertical * Float(lightmap.height - 1)
                    lightmapCoordinates.append(GModWorldTextureCoordinate(
                        u: luxelS / Float(lightmap.width),
                        v: luxelT / Float(lightmap.height)
                    ))
                } else {
                    lightmapCoordinates.append(nil)
                }
            }
        }

        let generatedIndices = displacementTriangleIndices(
            power: Int(displacement.power)
        )
        let firstTriangle = Int(displacement.firstTriangle)
        var localIndices: [UInt32] = []
        localIndices.reserveCapacity(generatedIndices.count)
        var removedTriangleCount = 0
        for triangle in 0..<displacement.triangleCount {
            if bsp.displacementTriangles[firstTriangle + triangle]
                .tags.contains(.remove) {
                removedTriangleCount += 1
                continue
            }
            let first = triangle * 3
            localIndices.append(contentsOf: generatedIndices[first..<(first + 3)])
        }

        var normalSums = Array(repeating: SourceVector3.zero, count: positions.count)
        var normalCounts = Array(repeating: 0, count: positions.count)
        for triangle in stride(from: 0, to: localIndices.count, by: 3) {
            let i0 = Int(localIndices[triangle])
            let i1 = Int(localIndices[triangle + 1])
            let i2 = Int(localIndices[triangle + 2])
            let cross = cross(positions[i1] - positions[i0], positions[i2] - positions[i0])
            let length = cross.length
            guard length.isFinite, length > Float.ulpOfOne else { continue }
            let normal = cross / length
            normalSums[i0] += normal
            normalSums[i1] += normal
            normalSums[i2] += normal
            normalCounts[i0] += 1
            normalCounts[i1] += 1
            normalCounts[i2] += 1
        }

        let vertices = positions.indices.map { index -> GModWorldRenderVertex in
            let normal = normalCounts[index] == 0
                ? faceNormal
                : normalSums[index] / Float(normalCounts[index])
            return GModWorldRenderVertex(
                position: positions[index],
                normal: normal,
                textureCoordinate: textureCoordinates[index],
                lightmapCoordinate: lightmapCoordinates[index]
            )
        }
        return GeneratedDisplacementGeometry(
            vertices: vertices,
            localIndices: localIndices,
            maximumOffsetFromBase: maximumOffset,
            removedTriangleCount: removedTriangleCount
        )
    }

    /// Exact `DispCommon_GenerateTriIndices` recursion from Source SDK 2013.
    /// Children are lower-left, lower-right, upper-left, upper-right; each
    /// power-one leaf fans eight triangles around its center.
    static func displacementTriangleIndices(power: Int) -> [UInt32] {
        precondition((2...4).contains(power))
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
            func component(_ lower: Int, _ upper: Int, _ selector: Int) -> Int {
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
                        indices.append(UInt32(vertex.1 * sideLength + vertex.0))
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
        generate(lower: (0, 0), upper: (extent, extent), remainingPower: power)
        return indices
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

    private static func textureCoordinate(
        at position: SourceVector3,
        faceIndex: Int,
        info: SourceBSPTextureInfo?,
        data: SourceBSPTextureData?
    ) throws -> GModWorldTextureCoordinate {
        guard let info, let data, data.width > 0, data.height > 0 else {
            return .zero
        }
        let s = position.x * info.textureVectors[0].x +
            position.y * info.textureVectors[0].y +
            position.z * info.textureVectors[0].z +
            info.textureVectors[0].offset
        let t = position.x * info.textureVectors[1].x +
            position.y * info.textureVectors[1].y +
            position.z * info.textureVectors[1].z +
            info.textureVectors[1].offset
        let result = GModWorldTextureCoordinate(
            u: s / Float(data.width),
            v: t / Float(data.height)
        )
        guard result.u.isFinite, result.v.isFinite else {
            throw GModWorldRenderMeshError.nonFiniteTextureCoordinate(
                face: faceIndex
            )
        }
        return result
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
    case invalidDisplacementBaseFace(face: Int, vertexCount: Int)
    case nonFinitePlane(face: Int)
    case nonFiniteVertex(face: Int, index: Int)
    case nonFiniteDisplacementVertex(face: Int, index: Int)
    case nonFiniteTextureCoordinate(face: Int)
    case nonFiniteLightmapCoordinate(face: Int)
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
        case let .invalidDisplacementBaseFace(face, vertexCount):
            return "face \(face) displacement base has \(vertexCount) vertices; expected 4"
        case let .nonFinitePlane(face):
            return "face \(face) has a non-finite plane normal"
        case let .nonFiniteVertex(face, index):
            return "face \(face) vertex \(index) is non-finite"
        case let .nonFiniteDisplacementVertex(face, index):
            return "face \(face) displacement vertex \(index) is non-finite"
        case let .nonFiniteTextureCoordinate(face):
            return "face \(face) has a non-finite texture coordinate"
        case let .nonFiniteLightmapCoordinate(face):
            return "face \(face) has a non-finite lightmap coordinate"
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
