/// Validated entity-local collision bounds used by Source's collision-property
/// helpers. These values must come from an authoritative solid/physics asset;
/// this type deliberately provides no default or model-render-bounds fallback.
public struct SourceCollisionProperty: Equatable, Sendable {
    public enum ValidationError: Error, Equatable, Sendable {
        case nonFiniteBounds
        case invertedBounds
        case nonFiniteTransform
        case nonFinitePoint
    }

    public let mins: SourceVector3
    public let maxs: SourceVector3

    public init(mins: SourceVector3, maxs: SourceVector3) throws {
        guard Self.isFinite(mins), Self.isFinite(maxs) else {
            throw ValidationError.nonFiniteBounds
        }
        guard mins.x <= maxs.x,
              mins.y <= maxs.y,
              mins.z <= maxs.z else {
            throw ValidationError.invertedBounds
        }
        self.mins = mins
        self.maxs = maxs
    }

    /// Mirrors `CCollisionProperty::CalcNearestPoint`: transform the query into
    /// collision space, clamp it to the local AABB, then transform it back.
    /// This is not a closest-point query against decoded PHY convexes.
    public func nearestPoint(
        to worldPoint: SourceVector3,
        transform: SourceEntityTransform
    ) throws -> SourceVector3 {
        try Self.validate(transform: transform, point: worldPoint)
        let local = transform.inverseTransformPointToLocal(worldPoint)
        let clamped = SourceVector3(
            min(max(local.x, mins.x), maxs.x),
            min(max(local.y, mins.y), maxs.y),
            min(max(local.z, mins.z), maxs.z)
        )
        return transform.transformPointFromLocal(clamped)
    }

    /// Axis-aligned bounds enclosing this oriented collision box in world
    /// space. All eight corners are transformed so rotations are preserved.
    public func worldAxisAlignedBounds(
        transform: SourceEntityTransform
    ) throws -> (mins: SourceVector3, maxs: SourceVector3) {
        try Self.validate(transform: transform)
        var worldMins = SourceVector3(
            Float.greatestFiniteMagnitude,
            Float.greatestFiniteMagnitude,
            Float.greatestFiniteMagnitude
        )
        var worldMaxs = SourceVector3(
            -Float.greatestFiniteMagnitude,
            -Float.greatestFiniteMagnitude,
            -Float.greatestFiniteMagnitude
        )
        for x in [mins.x, maxs.x] {
            for y in [mins.y, maxs.y] {
                for z in [mins.z, maxs.z] {
                    let point = transform.transformPointFromLocal(
                        SourceVector3(x, y, z)
                    )
                    worldMins.x = min(worldMins.x, point.x)
                    worldMins.y = min(worldMins.y, point.y)
                    worldMins.z = min(worldMins.z, point.z)
                    worldMaxs.x = max(worldMaxs.x, point.x)
                    worldMaxs.y = max(worldMaxs.y, point.y)
                    worldMaxs.z = max(worldMaxs.z, point.z)
                }
            }
        }
        return (worldMins, worldMaxs)
    }

    private static func validate(
        transform: SourceEntityTransform,
        point: SourceVector3? = nil
    ) throws {
        guard isFinite(transform.origin),
              transform.angles.pitch.isFinite,
              transform.angles.yaw.isFinite,
              transform.angles.roll.isFinite else {
            throw ValidationError.nonFiniteTransform
        }
        if let point, !isFinite(point) {
            throw ValidationError.nonFinitePoint
        }
    }

    private static func isFinite(_ vector: SourceVector3) -> Bool {
        vector.x.isFinite && vector.y.isFinite && vector.z.isFinite
    }
}
