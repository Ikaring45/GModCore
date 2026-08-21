import Foundation

/// Source `CONTENTS_*` bits from `bspflags.h`.
public struct SourceContents: OptionSet, Equatable, Hashable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let empty = SourceContents([])
    public static let solid = SourceContents(rawValue: 0x0000_0001)
    public static let window = SourceContents(rawValue: 0x0000_0002)
    public static let auxiliary = SourceContents(rawValue: 0x0000_0004)
    public static let grate = SourceContents(rawValue: 0x0000_0008)
    public static let slime = SourceContents(rawValue: 0x0000_0010)
    public static let water = SourceContents(rawValue: 0x0000_0020)
    public static let blockLineOfSight = SourceContents(rawValue: 0x0000_0040)
    public static let opaque = SourceContents(rawValue: 0x0000_0080)
    public static let testFogVolume = SourceContents(rawValue: 0x0000_0100)
    public static let unused = SourceContents(rawValue: 0x0000_0200)
    public static let unused6 = SourceContents(rawValue: 0x0000_0400)
    public static let team1 = SourceContents(rawValue: 0x0000_0800)
    public static let team2 = SourceContents(rawValue: 0x0000_1000)
    public static let ignoreNoDrawOpaque = SourceContents(rawValue: 0x0000_2000)
    public static let moveable = SourceContents(rawValue: 0x0000_4000)
    public static let areaPortal = SourceContents(rawValue: 0x0000_8000)
    public static let playerClip = SourceContents(rawValue: 0x0001_0000)
    public static let monsterClip = SourceContents(rawValue: 0x0002_0000)
    public static let current0 = SourceContents(rawValue: 0x0004_0000)
    public static let current90 = SourceContents(rawValue: 0x0008_0000)
    public static let current180 = SourceContents(rawValue: 0x0010_0000)
    public static let current270 = SourceContents(rawValue: 0x0020_0000)
    public static let currentUp = SourceContents(rawValue: 0x0040_0000)
    public static let currentDown = SourceContents(rawValue: 0x0080_0000)
    public static let origin = SourceContents(rawValue: 0x0100_0000)
    public static let monster = SourceContents(rawValue: 0x0200_0000)
    public static let debris = SourceContents(rawValue: 0x0400_0000)
    public static let detail = SourceContents(rawValue: 0x0800_0000)
    public static let translucent = SourceContents(rawValue: 0x1000_0000)
    public static let ladder = SourceContents(rawValue: 0x2000_0000)
    public static let hitbox = SourceContents(rawValue: 0x4000_0000)
}

/// Source `MASK_*` combinations from `bspflags.h`.
public enum SourceMasks {
    public static let all = SourceContents(rawValue: UInt32.max)

    public static let solid: SourceContents = [
        .solid, .moveable, .window, .monster, .grate,
    ]
    public static let playerSolid: SourceContents = [
        .solid, .moveable, .playerClip, .window, .monster, .grate,
    ]
    public static let npcSolid: SourceContents = [
        .solid, .moveable, .monsterClip, .window, .monster, .grate,
    ]
    public static let water: SourceContents = [.water, .moveable, .slime]
    public static let opaque: SourceContents = [.solid, .moveable, .opaque]
    public static let opaqueAndNPCs: SourceContents = [
        .solid, .moveable, .opaque, .monster,
    ]
    public static let blockLineOfSight: SourceContents = [
        .solid, .moveable, .blockLineOfSight,
    ]
    public static let blockLineOfSightAndNPCs: SourceContents = [
        .solid, .moveable, .blockLineOfSight, .monster,
    ]
    public static let visible: SourceContents = [
        .solid, .moveable, .opaque, .ignoreNoDrawOpaque,
    ]
    public static let visibleAndNPCs: SourceContents = [
        .solid, .moveable, .opaque, .monster, .ignoreNoDrawOpaque,
    ]
    public static let shot: SourceContents = [
        .solid, .moveable, .monster, .window, .debris, .hitbox,
    ]
    public static let shotHull: SourceContents = [
        .solid, .moveable, .monster, .window, .debris, .grate,
    ]
    public static let shotPortal: SourceContents = [
        .solid, .moveable, .window, .monster,
    ]
    public static let solidBrushOnly: SourceContents = [
        .solid, .moveable, .window, .grate,
    ]
    public static let playerSolidBrushOnly: SourceContents = [
        .solid, .moveable, .window, .playerClip, .grate,
    ]
    public static let npcSolidBrushOnly: SourceContents = [
        .solid, .moveable, .window, .monsterClip, .grate,
    ]
    public static let npcWorldStatic: SourceContents = [
        .solid, .window, .monsterClip, .grate,
    ]
    public static let splitAreaPortal: SourceContents = [.water, .slime]
    public static let current: SourceContents = [
        .current0, .current90, .current180, .current270, .currentUp, .currentDown,
    ]
    public static let deadSolid: SourceContents = [
        .solid, .playerClip, .window, .grate,
    ]
}

public enum SourceCollisionConstants {
    /// `DIST_EPSILON` from Source SDK 2013 `coordsize.h`. Source backs a
    /// reported impact away from the mathematical plane by 1/32 unit.
    public static let distanceEpsilon: Float = 0.03125
}

/// Source `Ray_t` layout expressed without platform SIMD dependencies.
public struct SourceRay: Equatable, Sendable {
    /// Starting point centered within `extents`.
    public let start: SourceVector3
    /// Direction and length of the sweep.
    public let delta: SourceVector3
    /// Add to `start` to recover the caller's uncentered origin.
    public let startOffset: SourceVector3
    /// Half-size of the swept axis-aligned box.
    public let extents: SourceVector3
    public let isRay: Bool
    public let isSwept: Bool

    public init(start: SourceVector3, end: SourceVector3) {
        self.start = start
        delta = end - start
        startOffset = .zero
        extents = .zero
        isRay = true
        isSwept = delta.lengthSquared != 0
    }

    public init(
        start: SourceVector3,
        end: SourceVector3,
        mins: SourceVector3,
        maxs: SourceVector3
    ) {
        precondition(mins.x <= maxs.x && mins.y <= maxs.y && mins.z <= maxs.z)
        delta = end - start
        isSwept = delta.lengthSquared != 0

        let halfExtents = (maxs - mins) * Float(0.5)
        extents = halfExtents
        isRay = halfExtents.lengthSquared < Float(0.000_001)

        let centerOffset = (mins + maxs) * Float(0.5)
        self.start = start + centerOffset
        startOffset = -centerOffset
    }

    public var actualStart: SourceVector3 { start + startOffset }
    public var actualEnd: SourceVector3 { start + delta + startOffset }

    /// Direction exposed as `Normal` by GMod's util.Trace* result tables.
    public var normalizedDelta: SourceVector3 {
        let magnitude = delta.length
        guard magnitude != 0 else { return .zero }
        return delta / magnitude
    }
}

public struct SourcePlane: Equatable, Sendable {
    public var normal: SourceVector3
    public var distance: Float
    public var type: UInt8
    public var signBits: UInt8

    public init(
        normal: SourceVector3 = .zero,
        distance: Float = 0,
        type: UInt8 = 0
    ) {
        self.normal = normal
        self.distance = distance
        self.type = type
        var bits: UInt8 = 0
        if normal.x < 0 { bits |= 1 }
        if normal.y < 0 { bits |= 2 }
        if normal.z < 0 { bits |= 4 }
        signBits = bits
    }
}

/// `csurface_t`-shaped trace metadata.
public struct SourceTraceSurface: Equatable, Sendable {
    public var name: String
    public var surfaceProperties: Int16
    public var flags: UInt16

    public init(
        name: String = "**empty**",
        surfaceProperties: Int16 = 0,
        flags: UInt16 = 0
    ) {
        self.name = name
        self.surfaceProperties = surfaceProperties
        self.flags = flags
    }
}

/// Value-semantic `CBaseTrace`/`CGameTrace` compatibility result.
public struct SourceGameTrace: Equatable, Sendable {
    public var startPosition: SourceVector3
    public var endPosition: SourceVector3
    public var plane: SourcePlane
    public var fraction: Float
    public var contents: SourceContents
    public var displacementFlags: UInt16
    public var allSolid: Bool
    public var startSolid: Bool

    public var fractionLeftSolid: Float
    public var surface: SourceTraceSurface
    public var hitGroup: Int32
    public var physicsBone: Int16
    public var entityHandle: SourceBaseHandle?
    public var hitBox: Int32

    public init(ray: SourceRay) {
        startPosition = ray.actualStart
        endPosition = ray.actualEnd
        plane = SourcePlane()
        fraction = 1
        contents = .empty
        displacementFlags = 0
        allSolid = false
        startSolid = false
        fractionLeftSolid = 0
        surface = SourceTraceSurface()
        hitGroup = 0
        physicsBone = 0
        entityHandle = nil
        hitBox = -1
    }

    public var didHit: Bool {
        fraction < 1 || allSolid || startSolid
    }

    public var didHitWorld: Bool {
        didHit && entityHandle?.entryIndex == 0
    }

    public var didHitNonWorldEntity: Bool {
        didHit && entityHandle != nil && entityHandle?.entryIndex != 0
    }
}

public struct SourceAABBCollider: Equatable, Sendable {
    public let mins: SourceVector3
    public let maxs: SourceVector3
    public let contents: SourceContents
    public let surface: SourceTraceSurface
    public let entityHandle: SourceBaseHandle?

    public init(
        mins: SourceVector3,
        maxs: SourceVector3,
        contents: SourceContents = .solid,
        surface: SourceTraceSurface = SourceTraceSurface(),
        entityHandle: SourceBaseHandle? = nil
    ) {
        precondition(mins.x <= maxs.x && mins.y <= maxs.y && mins.z <= maxs.z)
        self.mins = mins
        self.maxs = maxs
        self.contents = contents
        self.surface = surface
        self.entityHandle = entityHandle
    }

    fileprivate var planes: [SourcePlane] {
        [
            SourcePlane(normal: SourceVector3(1, 0, 0), distance: maxs.x, type: 0),
            SourcePlane(normal: SourceVector3(-1, 0, 0), distance: -mins.x, type: 0),
            SourcePlane(normal: SourceVector3(0, 1, 0), distance: maxs.y, type: 1),
            SourcePlane(normal: SourceVector3(0, -1, 0), distance: -mins.y, type: 1),
            SourcePlane(normal: SourceVector3(0, 0, 1), distance: maxs.z, type: 2),
            SourcePlane(normal: SourceVector3(0, 0, -1), distance: -mins.z, type: 2),
        ]
    }
}

/// Convex BSP brush. Plane normals point out of the solid; points satisfying
/// `dot(normal, point) <= distance` for every plane are inside.
public struct SourceConvexBrush: Equatable, Sendable {
    public let planes: [SourcePlane]
    public let contents: SourceContents
    public let surface: SourceTraceSurface
    public let entityHandle: SourceBaseHandle?
    /// Optional metadata parallel to `planes`. When supplied, the convex
    /// clipper attaches the surface belonging to the exact entering plane
    /// instead of inferring it later from floating-point plane equality.
    public let planeSurfaces: [SourceTraceSurface]?

    public init(
        planes: [SourcePlane],
        contents: SourceContents = .solid,
        surface: SourceTraceSurface = SourceTraceSurface(),
        entityHandle: SourceBaseHandle? = nil,
        planeSurfaces: [SourceTraceSurface]? = nil
    ) {
        precondition(!planes.isEmpty, "A Source convex brush needs at least one plane")
        precondition(
            planeSurfaces == nil || planeSurfaces?.count == planes.count,
            "Source convex-brush plane surfaces must parallel its planes"
        )
        self.planes = planes
        self.contents = contents
        self.surface = surface
        self.entityHandle = entityHandle
        self.planeSurfaces = planeSurfaces
    }
}

public enum SourceCollisionPrimitive: Equatable, Sendable {
    case axisAlignedBox(SourceAABBCollider)
    case convexBrush(SourceConvexBrush)

    fileprivate var contents: SourceContents {
        switch self {
        case let .axisAlignedBox(value): return value.contents
        case let .convexBrush(value): return value.contents
        }
    }

    fileprivate var surface: SourceTraceSurface {
        switch self {
        case let .axisAlignedBox(value): return value.surface
        case let .convexBrush(value): return value.surface
        }
    }

    fileprivate var entityHandle: SourceBaseHandle? {
        switch self {
        case let .axisAlignedBox(value): return value.entityHandle
        case let .convexBrush(value): return value.entityHandle
        }
    }

    fileprivate var planes: [SourcePlane] {
        switch self {
        case let .axisAlignedBox(value): return value.planes
        case let .convexBrush(value): return value.planes
        }
    }
}

/// Deterministic collision core for BSP convex brushes and dynamic AABBs.
/// Broadphase acceleration can be added behind this contract without changing
/// `Ray_t` or `trace_t`-observable results.
public struct SourceCollisionWorld: Equatable, Sendable {
    public private(set) var primitives: [SourceCollisionPrimitive]

    public init(primitives: [SourceCollisionPrimitive] = []) {
        self.primitives = primitives
    }

    public mutating func add(_ primitive: SourceCollisionPrimitive) {
        primitives.append(primitive)
    }

    public mutating func addAxisAlignedBox(_ collider: SourceAABBCollider) {
        add(.axisAlignedBox(collider))
    }

    public mutating func addConvexBrush(_ brush: SourceConvexBrush) {
        add(.convexBrush(brush))
    }

    public func pointContents(
        at point: SourceVector3,
        mask: SourceContents = SourceMasks.all
    ) -> SourceContents {
        var result = SourceContents.empty
        for primitive in primitives {
            guard intersects(primitive.contents, mask),
                  contains(point, in: primitive.planes, extents: .zero) else {
                continue
            }
            result.formUnion(primitive.contents)
        }
        return result
    }

    public func trace(
        _ ray: SourceRay,
        mask: SourceContents = SourceMasks.all,
        tolerance: Float = SourceCollisionConstants.distanceEpsilon,
        shouldHitEntity: ((SourceBaseHandle?) -> Bool)? = nil
    ) -> SourceGameTrace {
        traceCandidates(
            ray,
            primitiveIndices: primitives.indices,
            mask: mask,
            tolerance: tolerance,
            shouldHitEntity: shouldHitEntity
        )
    }

    /// Traces an ordered broad-phase selection without copying its collision
    /// primitives into a temporary world. The indices remain caller ordered:
    /// first-hit tie behavior and start-solid merging therefore match `trace`.
    ///
    /// This is internal because candidate indices are meaningful only to the
    /// immutable world that produced them. `SourceBSP` uses brush indices as a
    /// one-to-one primitive index after building its world once at load time.
    func trace(
        _ ray: SourceRay,
        candidatePrimitiveIndices: [Int],
        mask: SourceContents = SourceMasks.all,
        tolerance: Float = SourceCollisionConstants.distanceEpsilon,
        shouldHitEntity: ((SourceBaseHandle?) -> Bool)? = nil
    ) -> SourceGameTrace {
        traceCandidates(
            ray,
            primitiveIndices: candidatePrimitiveIndices,
            mask: mask,
            tolerance: tolerance,
            shouldHitEntity: shouldHitEntity
        )
    }

    private func traceCandidates<Indices: Sequence>(
        _ ray: SourceRay,
        primitiveIndices: Indices,
        mask: SourceContents,
        tolerance: Float,
        shouldHitEntity: ((SourceBaseHandle?) -> Bool)?
    ) -> SourceGameTrace where Indices.Element == Int {
        var result = SourceGameTrace(ray: ray)

        for primitiveIndex in primitiveIndices {
            let primitive = primitives[primitiveIndex]
            guard intersects(primitive.contents, mask) else { continue }
            if let shouldHitEntity, !shouldHitEntity(primitive.entityHandle) { continue }

            let candidate = trace(ray, against: primitive, tolerance: tolerance)
            guard candidate.didHit else { continue }
            merge(candidate, into: &result)
        }

        return result
    }

    private func merge(
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
        } else if !result.startSolid && candidate.fraction < result.fraction {
            result = candidate
        }
    }

    public func trace(
        _ ray: SourceRay,
        against primitive: SourceCollisionPrimitive,
        tolerance: Float = SourceCollisionConstants.distanceEpsilon
    ) -> SourceGameTrace {
        switch primitive {
        case let .axisAlignedBox(collider):
            return trace(ray, against: collider, tolerance: tolerance)
        case .convexBrush:
            return traceConvexBrush(ray, against: primitive, tolerance: tolerance)
        }
    }

    /// Source's `IntersectRayWithBox` has deliberately distinct start-solid
    /// bookkeeping from the BSP convex-brush clipper. In particular, `t2` is
    /// returned without clamping, `startpos` becomes the leaving point, and a
    /// synthetic +X plane at the original centered start is reported.
    private func trace(
        _ ray: SourceRay,
        against collider: SourceAABBCollider,
        tolerance: Float
    ) -> SourceGameTrace {
        var result = SourceGameTrace(ray: ray)
        let mins = collider.mins - ray.extents
        let maxs = collider.maxs + ray.extents

        var enterFraction: Float = -1
        var leaveFraction: Float = 1
        var hitSide = -1
        var startsSolid = true

        // The face order is part of the Source result when multiple faces tie:
        // mins X/Y/Z first, followed by maxs X/Y/Z.
        for side in 0 ..< 6 {
            let axis = side % 3
            let startDistance: Float
            let endDistance: Float
            if side >= 3 {
                startDistance = ray.start[axis] - maxs[axis]
                endDistance = startDistance + ray.delta[axis]
            } else {
                startDistance = -ray.start[axis] + mins[axis]
                endDistance = startDistance - ray.delta[axis]
            }

            if startDistance > 0, endDistance > 0 {
                return result
            }
            if startDistance <= 0, endDistance <= 0 {
                continue
            }

            if startDistance > 0 {
                startsSolid = false
            }

            if startDistance > endDistance {
                var fraction = startDistance - tolerance
                if fraction < 0 { fraction = 0 }
                fraction /= startDistance - endDistance
                if fraction > enterFraction {
                    enterFraction = fraction
                    hitSide = side
                }
            } else {
                let fraction = (startDistance + tolerance) /
                    (startDistance - endDistance)
                if fraction < leaveFraction {
                    leaveFraction = fraction
                }
            }
        }

        guard startsSolid ||
                (enterFraction < leaveFraction && enterFraction >= 0) else {
            return result
        }

        result.startSolid = startsSolid
        if enterFraction < leaveFraction, enterFraction >= 0 {
            result.fraction = enterFraction
            result.endPosition = ray.start + ray.delta * enterFraction + ray.startOffset

            var normal = SourceVector3.zero
            if hitSide >= 3 {
                let axis = hitSide - 3
                normal[axis] = 1
                result.plane = SourcePlane(
                    normal: normal,
                    distance: maxs[axis],
                    type: UInt8(axis)
                )
            } else {
                normal[hitSide] = -1
                result.plane = SourcePlane(
                    normal: normal,
                    distance: -mins[hitSide],
                    type: UInt8(hitSide)
                )
            }
            applyMetadata(of: .axisAlignedBox(collider), to: &result)
            return result
        }

        if startsSolid {
            result.allSolid = leaveFraction <= 0 || leaveFraction >= 1
            result.fraction = 0
            result.fractionLeftSolid = leaveFraction
            result.endPosition = ray.actualStart
            result.plane = SourcePlane(
                normal: SourceVector3(1, 0, 0),
                distance: ray.start.x,
                type: 0
            )
            result.startPosition = ray.start + ray.delta * leaveFraction + ray.startOffset
            applyMetadata(of: .axisAlignedBox(collider), to: &result)
        }
        return result
    }

    private func traceConvexBrush(
        _ ray: SourceRay,
        against primitive: SourceCollisionPrimitive,
        tolerance: Float
    ) -> SourceGameTrace {
        var result = SourceGameTrace(ray: ray)
        let planes = primitive.planes

        let centeredStart = ray.start
        let centeredEnd = ray.start + ray.delta
        var startsOutside = false
        var endsOutside = false
        var enterFraction = -Float.greatestFiniteMagnitude
        var leaveFraction = Float(1)
        var enteringPlane = SourcePlane()
        var enteringPlaneIndex: Int?

        for (planeIndex, plane) in planes.enumerated() {
            let expandedDistance = plane.distance + supportDistance(
                extents: ray.extents,
                normal: plane.normal
            )
            let startDistance = plane.normal.dot(centeredStart) - expandedDistance
            let endDistance = plane.normal.dot(centeredEnd) - expandedDistance

            if startDistance > 0 { startsOutside = true }
            if endDistance > 0 { endsOutside = true }

            if startDistance > 0 && endDistance > 0 {
                return result
            }
            if startDistance <= 0 && endDistance <= 0 {
                continue
            }

            if startDistance > endDistance {
                var numerator = startDistance - tolerance
                if numerator < 0 { numerator = 0 }
                let fraction = numerator / (startDistance - endDistance)
                if fraction > enterFraction {
                    enterFraction = fraction
                    enteringPlaneIndex = planeIndex
                    switch primitive {
                    case .axisAlignedBox:
                        // IntersectRayWithBox clips against the explicitly
                        // expanded box and returns that clipping plane.
                        enteringPlane = SourcePlane(
                            normal: plane.normal,
                            distance: expandedDistance,
                            type: plane.type
                        )
                    case .convexBrush:
                        // BSP traces retain the source brush plane while using
                        // hull support only for the fraction calculation.
                        enteringPlane = plane
                    }
                }
            } else {
                let fraction = (startDistance + tolerance) /
                    (startDistance - endDistance)
                if fraction < leaveFraction {
                    leaveFraction = fraction
                }
            }
        }

        if !startsOutside {
            result.startSolid = true
            result.allSolid = !endsOutside
            result.fraction = 0
            result.endPosition = ray.actualStart
            result.fractionLeftSolid = result.allSolid
                ? (ray.isSwept ? 1 : 0)
                : clampedUnit(leaveFraction)
            applyMetadata(of: primitive, to: &result)
            return result
        }

        guard enterFraction < leaveFraction,
              enterFraction >= 0,
              enterFraction <= 1 else {
            return result
        }

        result.fraction = enterFraction
        result.endPosition = ray.actualStart + ray.delta * enterFraction
        result.plane = enteringPlane
        applyMetadata(of: primitive, to: &result)
        if case let .convexBrush(brush) = primitive,
           let enteringPlaneIndex,
           let planeSurfaces = brush.planeSurfaces {
            result.surface = planeSurfaces[enteringPlaneIndex]
        }
        return result
    }

    private func contains(
        _ point: SourceVector3,
        in planes: [SourcePlane],
        extents: SourceVector3
    ) -> Bool {
        for plane in planes {
            let expandedDistance = plane.distance + supportDistance(
                extents: extents,
                normal: plane.normal
            )
            if plane.normal.dot(point) > expandedDistance { return false }
        }
        return true
    }

    private func supportDistance(
        extents: SourceVector3,
        normal: SourceVector3
    ) -> Float {
        abs(normal.x) * extents.x +
            abs(normal.y) * extents.y +
            abs(normal.z) * extents.z
    }

    private func intersects(_ lhs: SourceContents, _ rhs: SourceContents) -> Bool {
        (lhs.rawValue & rhs.rawValue) != 0
    }

    private func clampedUnit(_ value: Float) -> Float {
        min(max(value, 0), 1)
    }

    private func applyMetadata(
        of primitive: SourceCollisionPrimitive,
        to trace: inout SourceGameTrace
    ) {
        trace.contents = primitive.contents
        trace.surface = primitive.surface
        trace.entityHandle = primitive.entityHandle
    }
}
