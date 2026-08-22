import Foundation

public enum SourceBSPDetailedWorldCollisionProviderError:
    Error, Equatable, Sendable
{
    case assetDoesNotMatchBSP
    case invalidDisplacementFaceIndex(Int)
    case missingWorldIdentity
    case querySequenceExhausted
    case missingQueryResult
}

/// SDK-authenticated values stored in `CBaseTrace::dispFlags`.
///
/// These five bits match both Source SDK 2013 `trace.h`'s
/// `DISPSURF_FLAG_*` values and `bspfile.h`'s `DISPTRI_TAG_*` values. The
/// detailed world provider currently reports only ``surface``: it can attest
/// that a hit came from a real displacement triangle, while the deterministic
/// query result does not yet expose the exact triangle needed to retain its
/// walkable/buildable/surface-property tags.
public enum SourceDisplacementTraceFlags {
    public static let surface = SourceBSPDisplacementTriangleTags.surface.rawValue
    public static let walkable = SourceBSPDisplacementTriangleTags.walkable.rawValue
    public static let buildable = SourceBSPDisplacementTriangleTags.buildable.rawValue
    public static let surfaceProperty1 =
        SourceBSPDisplacementTriangleTags.surfaceProperty1.rawValue
    public static let surfaceProperty2 =
        SourceBSPDisplacementTriangleTags.surfaceProperty2.rawValue
}

/// Lane-owned detailed world collision.
///
/// Brush collision continues through `SourceBSP.traceWorld`, preserving its
/// first-leaf ordering, StartSolid merge, and 1/32-unit impact epsilon. Real
/// displacement meshes are queried independently through the deterministic
/// open-triangle SAT path, then merged at the closest fraction. The immutable
/// BSP and geometry may be shared, but this provider (workspace, query FIFO,
/// and physics environments) must belong to exactly one SERVER, CLIENT, or
/// player-movement lane.
public final class SourceBSPDetailedWorldCollisionProvider:
    GMLuaTraceProvider, SourceWorldWalkCollisionProvider, @unchecked Sendable
{
    private struct DisplacementGroup {
        let contents: SourceContents
        let environment: SourceDeterministicPhysicsEnvironment
    }

    public let bsp: SourceBSP
    public let tolerance: Float
    public let worldIdentity: SourceCanonicalEntityIdentity?

    private let brushWorkspace: SourceBSPTraceWorkspace
    private let displacementGroups: [DisplacementGroup]
    private var nextQuerySequence: UInt64 = 1

    public init(
        bsp: SourceBSP,
        staticPhysicsAsset: SourceBSPAttestedStaticPhysicsAsset,
        worldIdentity: SourceCanonicalEntityIdentity? = nil,
        tolerance: Float = SourceCollisionConstants.distanceEpsilon,
        brushWorkspace: SourceBSPTraceWorkspace = SourceBSPTraceWorkspace()
    ) throws {
        guard staticPhysicsAsset.bspVersion == bsp.header.version,
              staticPhysicsAsset.mapRevision == bsp.header.mapRevision,
              staticPhysicsAsset.geometry.parts.count ==
                staticPhysicsAsset.includedBrushIndices.count +
                staticPhysicsAsset.includedDisplacementFaceIndices.count else {
            throw SourceBSPDetailedWorldCollisionProviderError
                .assetDoesNotMatchBSP
        }

        let placeholderWorld = SourceCanonicalEntityIdentity(
            handle: SourceBaseHandle(entryIndex: 0, serialNumber: 0)
        )
        let worldBodyID = try SourcePhysicsBodyID(
            entityIdentity: worldIdentity ?? placeholderWorld,
            solidIndex: 0
        )
        let firstDisplacementPart =
            staticPhysicsAsset.includedBrushIndices.count
        var partsByContents: [SourceContents: [SourceDeterministicPhysicsStaticMeshPart]] = [:]
        for (offset, faceIndex) in
            staticPhysicsAsset.includedDisplacementFaceIndices.enumerated()
        {
            guard bsp.faces.indices.contains(faceIndex) else {
                throw SourceBSPDetailedWorldCollisionProviderError
                    .invalidDisplacementFaceIndex(faceIndex)
            }
            let displacementIndex = Int(
                bsp.faces[faceIndex].displacementInfoIndex
            )
            guard bsp.displacementInfo.indices.contains(displacementIndex) else {
                throw SourceBSPDetailedWorldCollisionProviderError
                    .invalidDisplacementFaceIndex(faceIndex)
            }
            let contents = SourceContents(rawValue: UInt32(bitPattern:
                bsp.displacementInfo[displacementIndex].contents
            ))
            let part = staticPhysicsAsset.geometry.parts[
                firstDisplacementPart + offset
            ]
            guard part.topology == .openTriangleMesh else {
                throw SourceBSPDetailedWorldCollisionProviderError
                    .assetDoesNotMatchBSP
            }
            partsByContents[contents, default: []].append(part)
        }

        var groups: [DisplacementGroup] = []
        groups.reserveCapacity(partsByContents.count)
        for contents in partsByContents.keys.sorted(by: {
            $0.rawValue < $1.rawValue
        }) {
            let geometry = try SourceDeterministicPhysicsStaticGeometry(
                parts: partsByContents[contents]!
            )
            let scene = try SourceDeterministicPhysicsStaticScene(
                bodyID: worldBodyID,
                geometry: geometry,
                contents: contents
            )
            groups.append(DisplacementGroup(
                contents: contents,
                environment: SourceDeterministicPhysicsEnvironment(
                    staticCollisionScene: scene
                )
            ))
        }

        self.bsp = bsp
        self.tolerance = tolerance
        self.worldIdentity = worldIdentity
        self.brushWorkspace = brushWorkspace
        displacementGroups = groups
    }

    public var isWorldReady: Bool { true }

    public func traceWorld(
        _ request: GMLuaTraceRequest
    ) throws -> SourceGameTrace {
        try trace(
            request.ray,
            kind: request.kind,
            mask: request.mask,
            collisionGroup: request.collisionGroup,
            worldIdentity: request.worldIdentity
        )
    }

    public func traceWorldWalk(
        _ ray: SourceRay,
        mask: SourceContents
    ) throws -> SourceGameTrace {
        guard let worldIdentity else {
            throw SourceBSPDetailedWorldCollisionProviderError
                .missingWorldIdentity
        }
        return try trace(
            ray,
            kind: ray.isRay ? .line : .hull,
            mask: mask,
            collisionGroup: 0,
            worldIdentity: worldIdentity
        )
    }

    /// Point contents deliberately remains the BSP leaf/brush result. An open
    /// displacement surface has no enclosed volume and therefore must not
    /// manufacture point contents above or below the terrain.
    public func worldWalkPointContents(
        at point: SourceVector3,
        mask: SourceContents
    ) throws -> SourceContents {
        try bsp.worldPointContents(at: point, mask: mask)
    }

    private func trace(
        _ ray: SourceRay,
        kind: GMLuaTraceKind,
        mask: SourceContents,
        collisionGroup: Int32,
        worldIdentity: SourceCanonicalEntityIdentity
    ) throws -> SourceGameTrace {
        var result = try bsp.traceWorld(
            ray,
            mask: mask,
            tolerance: tolerance,
            workspace: brushWorkspace
        )
        if result.didHit {
            result.entityHandle = worldIdentity.handle
        } else {
            result.entityHandle = nil
        }

        guard !displacementGroups.isEmpty, !mask.isEmpty else {
            return result
        }
        guard nextQuerySequence < UInt64.max else {
            throw SourceBSPDetailedWorldCollisionProviderError
                .querySequenceExhausted
        }
        let sequence = nextQuerySequence
        nextQuerySequence += 1
        let geometry: SourcePhysicsQueryGeometry
        switch kind {
        case .line:
            geometry = .lineSegment(
                start: ray.actualStart,
                end: ray.actualEnd
            )
        case .hull:
            let centerOffset = -ray.startOffset
            geometry = .sweptHull(
                start: ray.actualStart,
                end: ray.actualEnd,
                minimums: centerOffset - ray.extents,
                maximums: centerOffset + ray.extents
            )
        }

        for group in displacementGroups
        where !group.contents.intersection(mask).isEmpty {
            let query = try SourcePhysicsQueryCommand(
                queryID: sequence,
                geometry: geometry,
                contentsMask: mask.rawValue,
                collisionGroup: collisionGroup,
                scope: .staticOnly,
                ignoredEntities: []
            )
            let snapshot = try group.environment.execute(
                SourcePhysicsCommandBatch(commands: [
                    SourcePhysicsCommand(
                        sequence: sequence,
                        payload: .query(query)
                    ),
                ])
            )
            guard let queryResult = snapshot.queryResults.first else {
                throw SourceBSPDetailedWorldCollisionProviderError
                    .missingQueryResult
            }
            guard let hit = queryResult.hit else { continue }
            let candidate = displacementTrace(
                hit: hit,
                ray: ray,
                contents: group.contents,
                worldIdentity: worldIdentity
            )
            merge(candidate, into: &result)
        }
        return result
    }

    private func displacementTrace(
        hit: SourcePhysicsQueryHitSnapshot,
        ray: SourceRay,
        contents: SourceContents,
        worldIdentity: SourceCanonicalEntityIdentity
    ) -> SourceGameTrace {
        var trace = SourceGameTrace(ray: ray)
        trace.fraction = hit.fraction
        trace.endPosition = ray.actualStart + ray.delta * hit.fraction
        trace.plane = SourcePlane(
            normal: hit.normal,
            distance: hit.normal.dot(hit.position)
        )
        trace.contents = contents
        trace.displacementFlags = SourceDisplacementTraceFlags.surface
        trace.startSolid = hit.startedSolid
        trace.allSolid = hit.allSolid
        trace.entityHandle = worldIdentity.handle
        return trace
    }

    /// Mirrors `SourceCollisionWorld`'s deterministic merge contract. Brush
    /// results are evaluated first, so exact ties retain their Source BSP
    /// plane/surface metadata.
    private func merge(
        _ candidate: SourceGameTrace,
        into result: inout SourceGameTrace
    ) {
        guard candidate.didHit else { return }
        if candidate.startSolid {
            if !result.startSolid {
                result = candidate
            } else {
                result.allSolid = result.allSolid || candidate.allSolid
                result.fractionLeftSolid = max(
                    result.fractionLeftSolid,
                    candidate.fractionLeftSolid
                )
                result.contents.formUnion(candidate.contents)
            }
        } else if !result.startSolid && candidate.fraction < result.fraction {
            result = candidate
        }
    }
}
