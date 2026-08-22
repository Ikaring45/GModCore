import Foundation

/// Geometry/provenance failures at the dynamic-entity trace boundary. A
/// malformed or incomplete asset never falls back to render bounds or a
/// synthetic AABB.
public enum GMLuaDynamicTraceGeometryError: Error, Equatable, Sendable,
    CustomStringConvertible
{
    case invalidStudioHitboxBounds(hitBox: Int32)
    case singularStudioHitboxTransform(hitBox: Int32)
    case invalidStudioHitboxSet(Int)
    case invalidStudioPhysicsBone(Int32)
    case unsupportedPhysicsShapeTopology(SourcePhysicsShapeTopology)
    case physicsShapeOutsideCollisionProperty
    case degenerateConvexPart(part: Int)

    public var description: String {
        switch self {
        case let .invalidStudioHitboxBounds(hitBox):
            return "Studio hitbox \(hitBox) has inverted bounds"
        case let .singularStudioHitboxTransform(hitBox):
            return "Studio hitbox \(hitBox) has a singular bone transform"
        case let .invalidStudioHitboxSet(index):
            return "Studio hitbox set \(index) is unavailable"
        case let .invalidStudioPhysicsBone(value):
            return "Studio physics bone \(value) does not fit trace_t"
        case let .unsupportedPhysicsShapeTopology(topology):
            return "dynamic hull trace requires convexParts, received \(topology)"
        case .physicsShapeOutsideCollisionProperty:
            return "attested physics shape exceeds its collision-property bounds"
        case let .degenerateConvexPart(part):
            return "physics convex part \(part) has no usable planes"
        }
    }
}

/// One model hitbox in its resolved world-space bone pose. `contents` comes
/// from the Studio bone record; hit group, hitbox index, and physics bone stay
/// distinct exactly as they do in `trace_t`.
public struct GMLuaDynamicStudioHitbox: Equatable, Sendable {
    public let minimum: SourceVector3
    public let maximum: SourceVector3
    public let boneToWorld: SourceStudioMatrix3x4
    public let contents: SourceContents
    public let surface: SourceTraceSurface
    public let hitBox: Int32
    public let hitGroup: Int32
    public let physicsBone: Int16

    public init(
        minimum: SourceVector3,
        maximum: SourceVector3,
        boneToWorld: SourceStudioMatrix3x4,
        contents: SourceContents,
        surface: SourceTraceSurface,
        hitBox: Int32,
        hitGroup: Int32,
        physicsBone: Int16
    ) throws {
        guard minimum.x <= maximum.x,
              minimum.y <= maximum.y,
              minimum.z <= maximum.z else {
            throw GMLuaDynamicTraceGeometryError
                .invalidStudioHitboxBounds(hitBox: hitBox)
        }
        guard DynamicTraceAffineTransform(boneToWorld) != nil else {
            throw GMLuaDynamicTraceGeometryError
                .singularStudioHitboxTransform(hitBox: hitBox)
        }
        self.minimum = minimum
        self.maximum = maximum
        self.boneToWorld = boneToWorld
        self.contents = contents
        self.surface = surface
        self.hitBox = hitBox
        self.hitGroup = hitGroup
        self.physicsBone = physicsBone
    }
}

/// Real VPhysics hull evidence for `util.TraceHull`. The collision property is
/// retained as broad-phase data, while the attested convex mesh remains the
/// narrow phase. This prevents a single bounds box from standing in for PHY.
public struct GMLuaDynamicHullCollision: Equatable, Sendable {
    public let transform: SourceEntityTransform
    public let collisionProperty: SourceCollisionProperty
    public let physicsShape: SourcePhysicsShapeSnapshot
    public let contents: SourceContents
    public let surface: SourceTraceSurface

    public init(
        transform: SourceEntityTransform,
        collisionProperty: SourceCollisionProperty,
        physicsShape: SourcePhysicsShapeSnapshot,
        contents: SourceContents,
        surface: SourceTraceSurface
    ) throws {
        guard physicsShape.topology == .convexParts else {
            throw GMLuaDynamicTraceGeometryError
                .unsupportedPhysicsShapeTopology(physicsShape.topology)
        }
        let epsilon = SourceCollisionConstants.distanceEpsilon
        for part in physicsShape.parts {
            for vertex in part.vertices {
                guard vertex.x >= collisionProperty.mins.x - epsilon,
                      vertex.y >= collisionProperty.mins.y - epsilon,
                      vertex.z >= collisionProperty.mins.z - epsilon,
                      vertex.x <= collisionProperty.maxs.x + epsilon,
                      vertex.y <= collisionProperty.maxs.y + epsilon,
                      vertex.z <= collisionProperty.maxs.z + epsilon else {
                    throw GMLuaDynamicTraceGeometryError
                        .physicsShapeOutsideCollisionProperty
                }
            }
        }
        self.transform = transform
        self.collisionProperty = collisionProperty
        self.physicsShape = physicsShape
        self.contents = contents
        self.surface = surface
    }
}

/// Immutable collision input for one complete canonical EHANDLE generation.
/// Line and hull geometry are intentionally independent optional fields.
public struct GMLuaDynamicTraceCandidate: Equatable, Sendable {
    public let identity: SourceCanonicalEntityIdentity
    public let className: String
    public let collisionGroup: Int32
    public let studioHitboxes: [GMLuaDynamicStudioHitbox]
    public let hullCollision: GMLuaDynamicHullCollision?

    public init(
        identity: SourceCanonicalEntityIdentity,
        className: String,
        collisionGroup: Int32,
        studioHitboxes: [GMLuaDynamicStudioHitbox] = [],
        hullCollision: GMLuaDynamicHullCollision? = nil
    ) {
        self.identity = identity
        self.className = className
        self.collisionGroup = collisionGroup
        self.studioHitboxes = studioHitboxes
        self.hullCollision = hullCollision
    }

    /// Resolves the parsed MDL's compiled default pose. Animated entities must
    /// supply their evaluated bone matrices instead; this helper is suitable
    /// for static props whose canonical pose is the compiled pose.
    public static func defaultPoseStudioHitboxes(
        model: SourceStudioModel,
        hitboxSet index: Int = 0,
        entityTransform: SourceEntityTransform
    ) throws -> [GMLuaDynamicStudioHitbox] {
        guard model.hitboxSets.indices.contains(index) else {
            throw GMLuaDynamicTraceGeometryError.invalidStudioHitboxSet(index)
        }
        let worldBones = model.defaultBoneToWorld(
            rootTransform: SourceStudioMatrix3x4(entityTransform)
        )
        return try model.hitboxSets[index].hitboxes.enumerated().map {
            hitBoxIndex, hitbox in
            let boneIndex = Int(hitbox.bone)
            let bone = model.bones[boneIndex]
            guard let physicsBone = Int16(exactly: bone.physicsBone) else {
                throw GMLuaDynamicTraceGeometryError
                    .invalidStudioPhysicsBone(bone.physicsBone)
            }
            return try GMLuaDynamicStudioHitbox(
                minimum: hitbox.minimum,
                maximum: hitbox.maximum,
                boneToWorld: worldBones[boneIndex],
                contents: SourceContents(
                    rawValue: UInt32(bitPattern: bone.contents)
                ),
                surface: SourceTraceSurface(name: bone.surfaceProperty),
                hitBox: Int32(hitBoxIndex),
                hitGroup: hitbox.group,
                physicsBone: physicsBone
            )
        }
    }
}

/// Supplies immutable dynamic candidates and the host's attested collision
/// group policy. The utility bridge evaluates realm-local Lua filters after
/// this policy, so no Lua object crosses the provider boundary.
public protocol GMLuaDynamicTraceCandidateProvider: Sendable {
    var isDynamicTraceReady: Bool { get }
    func dynamicTraceCandidates(
        for request: GMLuaTraceRequest
    ) throws -> [GMLuaDynamicTraceCandidate]
    func shouldCollide(
        queryCollisionGroup: Int32,
        candidateCollisionGroup: Int32
    ) -> Bool
}

/// Immutable composition of the existing BSP provider and a live canonical
/// candidate source. Existing world-only providers remain valid and unchanged.
public final class GMLuaCompositeTraceProvider: GMLuaTraceProvider,
    GMLuaDynamicTraceCandidateProvider, @unchecked Sendable
{
    private let worldProvider: any GMLuaTraceProvider
    private let dynamicProvider: any GMLuaDynamicTraceCandidateProvider

    public init(
        world: any GMLuaTraceProvider,
        dynamic: any GMLuaDynamicTraceCandidateProvider
    ) {
        worldProvider = world
        dynamicProvider = dynamic
    }

    public var isWorldReady: Bool { worldProvider.isWorldReady }
    public var isDynamicTraceReady: Bool {
        dynamicProvider.isDynamicTraceReady
    }

    public func traceWorld(
        _ request: GMLuaTraceRequest
    ) throws -> SourceGameTrace {
        try worldProvider.traceWorld(request)
    }

    public func dynamicTraceCandidates(
        for request: GMLuaTraceRequest
    ) throws -> [GMLuaDynamicTraceCandidate] {
        try dynamicProvider.dynamicTraceCandidates(for: request)
    }

    public func shouldCollide(
        queryCollisionGroup: Int32,
        candidateCollisionGroup: Int32
    ) -> Bool {
        dynamicProvider.shouldCollide(
            queryCollisionGroup: queryCollisionGroup,
            candidateCollisionGroup: candidateCollisionGroup
        )
    }
}

/// Closure-backed live candidate source used by a session/adapter integration.
/// The collision policy is required; no equality rule or Source game-rules
/// matrix is guessed by this layer.
public struct GMLuaClosureDynamicTraceCandidateProvider:
    GMLuaDynamicTraceCandidateProvider, Sendable
{
    private let readiness: @Sendable () -> Bool
    private let candidates: @Sendable (
        GMLuaTraceRequest
    ) throws -> [GMLuaDynamicTraceCandidate]
    private let collisionPolicy: @Sendable (Int32, Int32) -> Bool

    public init(
        isReady: @escaping @Sendable () -> Bool,
        candidates: @escaping @Sendable (
            GMLuaTraceRequest
        ) throws -> [GMLuaDynamicTraceCandidate],
        shouldCollide: @escaping @Sendable (Int32, Int32) -> Bool
    ) {
        readiness = isReady
        self.candidates = candidates
        collisionPolicy = shouldCollide
    }

    public var isDynamicTraceReady: Bool { readiness() }

    public func dynamicTraceCandidates(
        for request: GMLuaTraceRequest
    ) throws -> [GMLuaDynamicTraceCandidate] {
        try candidates(request)
    }

    public func shouldCollide(
        queryCollisionGroup: Int32,
        candidateCollisionGroup: Int32
    ) -> Bool {
        collisionPolicy(queryCollisionGroup, candidateCollisionGroup)
    }
}

/// Narrow-phase implementation shared by SERVER and CLIENT trace bridges.
/// Candidate order is external; the bridge sorts by full EHANDLE and performs
/// Source's strict-less-than merge with the world result.
public enum GMLuaDynamicTraceEngine {
    public static func trace(
        _ request: GMLuaTraceRequest,
        candidate: GMLuaDynamicTraceCandidate,
        tolerance: Float = SourceCollisionConstants.distanceEpsilon
    ) throws -> SourceGameTrace {
        switch request.kind {
        case .line:
            return try traceLine(
                request,
                candidate: candidate,
                tolerance: tolerance
            )
        case .hull:
            return try traceHull(
                request,
                candidate: candidate,
                tolerance: tolerance
            )
        }
    }

    private static func traceLine(
        _ request: GMLuaTraceRequest,
        candidate: GMLuaDynamicTraceCandidate,
        tolerance: Float
    ) throws -> SourceGameTrace {
        var result = SourceGameTrace(ray: request.ray)
        for hitbox in candidate.studioHitboxes {
            guard !hitbox.contents.intersection(request.mask).isEmpty,
                  let affine = DynamicTraceAffineTransform(hitbox.boneToWorld)
            else { continue }
            let localRay = SourceRay(
                start: affine.inversePoint(request.ray.actualStart),
                end: affine.inversePoint(request.ray.actualEnd)
            )
            let collider = SourceAABBCollider(
                mins: hitbox.minimum,
                maxs: hitbox.maximum,
                contents: hitbox.contents,
                surface: hitbox.surface,
                entityHandle: candidate.identity.handle
            )
            let local = SourceCollisionWorld().trace(
                localRay,
                against: .axisAlignedBox(collider),
                tolerance: tolerance
            )
            guard local.didHit else { continue }
            var world = local
            world.startPosition = affine.transformPoint(local.startPosition)
            world.endPosition = affine.transformPoint(local.endPosition)
            world.plane = affine.transformPlane(local.plane)
            world.hitBox = hitbox.hitBox
            world.hitGroup = hitbox.hitGroup
            world.physicsBone = hitbox.physicsBone
            merge(world, into: &result)
        }
        return result
    }

    private static func traceHull(
        _ request: GMLuaTraceRequest,
        candidate: GMLuaDynamicTraceCandidate,
        tolerance: Float
    ) throws -> SourceGameTrace {
        var result = SourceGameTrace(ray: request.ray)
        guard let hull = candidate.hullCollision,
              !hull.contents.intersection(request.mask).isEmpty else {
            return result
        }
        let bounds = try hull.collisionProperty.worldAxisAlignedBounds(
            transform: hull.transform
        )
        guard sweptBounds(of: request.ray).intersects(
            minimum: bounds.mins,
            maximum: bounds.maxs
        ) else { return result }

        for (partIndex, part) in hull.physicsShape.parts.enumerated() {
            let planes = try convexPlanes(
                for: part,
                partIndex: partIndex,
                transform: hull.transform
            )
            let brush = SourceConvexBrush(
                planes: planes,
                contents: hull.contents,
                surface: hull.surface,
                entityHandle: candidate.identity.handle
            )
            let partTrace = SourceCollisionWorld().trace(
                request.ray,
                against: .convexBrush(brush),
                tolerance: tolerance
            )
            guard partTrace.didHit else { continue }
            merge(partTrace, into: &result)
        }
        return result
    }

    /// Same merge ordering as `SourceCollisionWorld`: first candidate wins an
    /// exact fraction tie, while start-solid results merge contents/leave time.
    static func merge(
        _ candidate: SourceGameTrace,
        into result: inout SourceGameTrace
    ) {
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
        } else if !result.startSolid, candidate.fraction < result.fraction {
            result = candidate
        }
    }

    private static func convexPlanes(
        for part: SourcePhysicsMeshPartSnapshot,
        partIndex: Int,
        transform: SourceEntityTransform
    ) throws -> [SourcePlane] {
        let vertices = part.vertices.map(transform.transformPointFromLocal)
        var centroid = SourceVector3.zero
        for vertex in vertices { centroid += vertex }
        centroid = centroid / Float(vertices.count)

        var planes: [SourcePlane] = []
        planes.reserveCapacity(part.triangles.count)
        for triangle in part.triangles {
            let first = vertices[triangle.first]
            let second = vertices[triangle.second]
            let third = vertices[triangle.third]
            var normal = dynamicCross(second - first, third - first)
            let length = normal.length
            guard length.isFinite, length > 0 else { continue }
            normal = normal / length
            var distance = normal.dot(first)
            if normal.dot(centroid) > distance {
                normal = -normal
                distance = -distance
            }
            guard !planes.contains(where: {
                abs($0.normal.dot(normal) - 1) <= 0.000_1 &&
                    abs($0.distance - distance) <= 0.001
            }) else { continue }
            planes.append(SourcePlane(normal: normal, distance: distance))
        }
        guard !planes.isEmpty else {
            throw GMLuaDynamicTraceGeometryError
                .degenerateConvexPart(part: partIndex)
        }
        return planes
    }

    private struct DynamicSweptBounds {
        let minimum: SourceVector3
        let maximum: SourceVector3

        func intersects(
            minimum otherMinimum: SourceVector3,
            maximum otherMaximum: SourceVector3
        ) -> Bool {
            minimum.x <= otherMaximum.x && maximum.x >= otherMinimum.x &&
                minimum.y <= otherMaximum.y && maximum.y >= otherMinimum.y &&
                minimum.z <= otherMaximum.z && maximum.z >= otherMinimum.z
        }
    }

    private static func sweptBounds(of ray: SourceRay) -> DynamicSweptBounds {
        let end = ray.start + ray.delta
        return DynamicSweptBounds(
            minimum: SourceVector3(
                min(ray.start.x, end.x) - ray.extents.x,
                min(ray.start.y, end.y) - ray.extents.y,
                min(ray.start.z, end.z) - ray.extents.z
            ),
            maximum: SourceVector3(
                max(ray.start.x, end.x) + ray.extents.x,
                max(ray.start.y, end.y) + ray.extents.y,
                max(ray.start.z, end.z) + ray.extents.z
            )
        )
    }
}

private struct DynamicTraceAffineTransform {
    let matrix: SourceStudioMatrix3x4
    let i00: Float
    let i01: Float
    let i02: Float
    let i10: Float
    let i11: Float
    let i12: Float
    let i20: Float
    let i21: Float
    let i22: Float

    init?(_ matrix: SourceStudioMatrix3x4) {
        let determinant = matrix.m00 * (
            matrix.m11 * matrix.m22 - matrix.m12 * matrix.m21
        ) - matrix.m01 * (
            matrix.m10 * matrix.m22 - matrix.m12 * matrix.m20
        ) + matrix.m02 * (
            matrix.m10 * matrix.m21 - matrix.m11 * matrix.m20
        )
        guard determinant.isFinite, abs(determinant) > 0.000_001 else {
            return nil
        }
        let inverse = 1 / determinant
        i00 = (matrix.m11 * matrix.m22 - matrix.m12 * matrix.m21) * inverse
        i01 = (matrix.m02 * matrix.m21 - matrix.m01 * matrix.m22) * inverse
        i02 = (matrix.m01 * matrix.m12 - matrix.m02 * matrix.m11) * inverse
        i10 = (matrix.m12 * matrix.m20 - matrix.m10 * matrix.m22) * inverse
        i11 = (matrix.m00 * matrix.m22 - matrix.m02 * matrix.m20) * inverse
        i12 = (matrix.m02 * matrix.m10 - matrix.m00 * matrix.m12) * inverse
        i20 = (matrix.m10 * matrix.m21 - matrix.m11 * matrix.m20) * inverse
        i21 = (matrix.m01 * matrix.m20 - matrix.m00 * matrix.m21) * inverse
        i22 = (matrix.m00 * matrix.m11 - matrix.m01 * matrix.m10) * inverse
        self.matrix = matrix
    }

    func inversePoint(_ value: SourceVector3) -> SourceVector3 {
        let translated = value - matrix.position
        return SourceVector3(
            i00 * translated.x + i01 * translated.y + i02 * translated.z,
            i10 * translated.x + i11 * translated.y + i12 * translated.z,
            i20 * translated.x + i21 * translated.y + i22 * translated.z
        )
    }

    func transformPoint(_ value: SourceVector3) -> SourceVector3 {
        matrix.transformPoint(value)
    }

    func transformPlane(_ plane: SourcePlane) -> SourcePlane {
        let unnormalized = SourceVector3(
            i00 * plane.normal.x + i10 * plane.normal.y + i20 * plane.normal.z,
            i01 * plane.normal.x + i11 * plane.normal.y + i21 * plane.normal.z,
            i02 * plane.normal.x + i12 * plane.normal.y + i22 * plane.normal.z
        )
        let length = unnormalized.length
        guard length.isFinite, length > 0 else { return SourcePlane() }
        let normal = unnormalized / length
        let distance = (
            plane.distance + unnormalized.dot(matrix.position)
        ) / length
        return SourcePlane(normal: normal, distance: distance, type: plane.type)
    }
}

private extension SourceStudioMatrix3x4 {
    init(_ transform: SourceEntityTransform) {
        let basis = transform.angles.sourceBasis
        self.init(
            basis.forward.x, -basis.right.x, basis.up.x, transform.origin.x,
            basis.forward.y, -basis.right.y, basis.up.y, transform.origin.y,
            basis.forward.z, -basis.right.z, basis.up.z, transform.origin.z
        )
    }
}

private func dynamicCross(
    _ lhs: SourceVector3,
    _ rhs: SourceVector3
) -> SourceVector3 {
    SourceVector3(
        lhs.y * rhs.z - lhs.z * rhs.y,
        lhs.z * rhs.x - lhs.x * rhs.z,
        lhs.x * rhs.y - lhs.y * rhs.x
    )
}
