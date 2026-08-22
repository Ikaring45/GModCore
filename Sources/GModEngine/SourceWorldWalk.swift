import Foundation

/// World-collision boundary used by the minimum standing-player movement slice.
/// It deliberately has no Lua Entity identity: callers receive value-semantic
/// Source traces, and this milestone accepts only BSP world hits.
public protocol SourceWorldWalkCollisionProvider: Sendable {
    func traceWorldWalk(
        _ ray: SourceRay,
        mask: SourceContents
    ) throws -> SourceGameTrace

    func worldWalkPointContents(
        at point: SourceVector3,
        mask: SourceContents
    ) throws -> SourceContents
}

/// Lane-confined BSP adapter for one authoritative or predicted movement
/// stream. `SourceBSP` remains immutable; the reusable trace workspace belongs
/// to this provider, not the BSP asset. Construct one provider per simulation
/// lane rather than sharing a provider between SERVER and CLIENT prediction.
public final class SourceBSPWorldWalkCollisionProvider:
    SourceWorldWalkCollisionProvider, @unchecked Sendable
{
    public let bsp: SourceBSP
    public let tolerance: Float
    private let workspace: SourceBSPTraceWorkspace

    public init(
        bsp: SourceBSP,
        tolerance: Float = SourceCollisionConstants.distanceEpsilon,
        workspace: SourceBSPTraceWorkspace = SourceBSPTraceWorkspace()
    ) {
        self.bsp = bsp
        self.tolerance = tolerance
        self.workspace = workspace
    }

    public func traceWorldWalk(
        _ ray: SourceRay,
        mask: SourceContents
    ) throws -> SourceGameTrace {
        try bsp.traceWorld(
            ray,
            mask: mask,
            tolerance: tolerance,
            workspace: workspace
        )
    }

    public func worldWalkPointContents(
        at point: SourceVector3,
        mask: SourceContents
    ) throws -> SourceContents {
        try bsp.worldPointContents(at: point, mask: mask)
    }
}

/// Capabilities intentionally outside the world-only standing-hull slice.
/// Keeping this public prevents a host from presenting the solver as complete
/// Source/GMod player movement.
public enum SourceWorldWalkUnsupportedFeature: String, CaseIterable, Equatable, Sendable {
    case stepUp
    case jump
    case duck
    case verticalMove
    case water
    case ladder
    case displacementCollision
    case dynamicEntityCollision
    case movingGround
    case vPhysics
    case stuckRecovery
    case surfaceProperties
    case deadPlayer
    case nonWalkMoveType
}

/// Value-only classification for capability misses that a host may reject
/// transactionally while continuing the surrounding SERVER/CLIENT clock.
/// It deliberately excludes malformed state, configuration, and trace errors.
public enum SourceWorldWalkUnsupportedReason: Equatable, Sendable {
    case feature(SourceWorldWalkUnsupportedFeature)
    case dynamicEntityCollision(entityIndex: Int)
}

extension SourceWorldWalkUnsupportedReason: CustomStringConvertible {
    public var description: String {
        switch self {
        case let .feature(feature):
            return "unsupported Source world-walk feature \(feature.rawValue)"
        case let .dynamicEntityCollision(entityIndex):
            return "unsupported Source dynamic-entity collision at index \(entityIndex)"
        }
    }
}

public enum SourceWorldWalkError: Error, Equatable, Sendable,
    CustomStringConvertible
{
    case unsupported(SourceWorldWalkUnsupportedFeature)
    case unsupportedDynamicEntity(Int)
    case nonFinite(String)
    case invalidConfiguration(String)
    case embeddedInWorld(allSolid: Bool)
    case hitMissingWorldIdentity
    case inconsistentTrace(String)

    /// The complete, explicit subset that a playable host can represent as a
    /// non-fatal movement rejection. Every other error remains an invariant
    /// failure and must escape the host boundary.
    public var recoverableUnsupportedReason: SourceWorldWalkUnsupportedReason? {
        switch self {
        case let .unsupported(feature):
            return .feature(feature)
        case let .unsupportedDynamicEntity(index):
            return .dynamicEntityCollision(entityIndex: index)
        case .nonFinite, .invalidConfiguration, .embeddedInWorld,
             .hitMissingWorldIdentity, .inconsistentTrace:
            return nil
        }
    }

    public var description: String {
        switch self {
        case let .unsupported(feature):
            return "Source world walk does not implement \(feature.rawValue)"
        case let .unsupportedDynamicEntity(index):
            return "Source world walk does not implement dynamic entity collision at index \(index)"
        case let .nonFinite(field):
            return "Source world walk received a non-finite \(field)"
        case let .invalidConfiguration(field):
            return "Source world walk has invalid configuration field \(field)"
        case let .embeddedInWorld(allSolid):
            return allSolid
                ? "Source standing hull is all-solid in the world"
                : "Source standing hull starts solid in the world"
        case .hitMissingWorldIdentity:
            return "Source world walk trace hit without an Entity(0) identity"
        case let .inconsistentTrace(field):
            return "Source world walk provider returned an inconsistent \(field)"
        }
    }
}

/// Tunables already represented by the equation-compatible movement core plus
/// the per-player maximum speed supplied by the host/gamemode.
public struct SourceWorldWalkConfiguration: Equatable, Sendable {
    public var movement: SourceMovementParameters
    public var maximumSpeed: Float
    public var jumpHeight: Float

    public init(
        movement: SourceMovementParameters = SourceMovementParameters(),
        maximumSpeed: Float = 320,
        jumpHeight: Float = 21
    ) {
        self.movement = movement
        self.maximumSpeed = maximumSpeed
        self.jumpHeight = jumpHeight
    }
}

/// Persistent value state for one world-only walking player. `movement` stays
/// in Source Float precision and can be used directly by SourceGameMovement.
public struct SourceWorldWalkState: Equatable, Sendable {
    public var movement: SourceMoveData
    public var viewAngles: SourceQAngle
    public var moveType: SourceMoveType

    public init(
        movement: SourceMoveData = SourceMoveData(),
        viewAngles: SourceQAngle = .zero,
        moveType: SourceMoveType = .walk
    ) {
        self.movement = movement
        self.viewAngles = viewAngles
        self.moveType = moveType
    }

    public init(
        origin: SourceVector3,
        velocity: SourceVector3 = .zero,
        viewAngles: SourceQAngle = .zero,
        isOnGround: Bool = false
    ) {
        movement = SourceMoveData(
            origin: origin,
            velocity: velocity,
            isOnGround: isOnGround
        )
        self.viewAngles = viewAngles
        moveType = .walk
    }

    public var origin: SourceVector3 {
        get { movement.origin }
        set { movement.origin = newValue }
    }

    public var velocity: SourceVector3 {
        get { movement.velocity }
        set { movement.velocity = newValue }
    }

    public var isOnGround: Bool {
        get { movement.isOnGround }
        set { movement.isOnGround = newValue }
    }
}

/// Per-command diagnostics. They are value-only so render and prediction
/// layers never retain a provider, BSP, or realm-local userdata.
public struct SourceWorldWalkTick: Equatable, Sendable {
    public let commandNumber: Int32
    public let state: SourceWorldWalkState
    public let bumpCount: Int
    public let collisionCount: Int
    public let didSnapToGround: Bool

    public init(
        commandNumber: Int32,
        state: SourceWorldWalkState,
        bumpCount: Int,
        collisionCount: Int,
        didSnapToGround: Bool
    ) {
        self.commandNumber = commandNumber
        self.state = state
        self.bumpCount = bumpCount
        self.collisionCount = collisionCount
        self.didSnapToGround = didSnapToGround
    }
}

/// Minimum honest Source-style walking loop for a standing player against BSP
/// world brushes. It composes the existing Float movement equations with hull
/// traces, ground categorization, and four-bump plane clipping.
///
/// The input state is never mutated. Every provider call and validation must
/// succeed before the returned state becomes observable, so trace failures and
/// unsupported content cannot leak a partially advanced player.
public struct SourceWorldWalkSolver: Sendable {
    public static let standingHullMins = SourceVector3(-16, -16, 0)
    public static let standingHullMaxs = SourceVector3(16, 16, 72)
    public static let playerMask = SourceMasks.playerSolidBrushOnly
    public static let groundProbeDistance: Float = 2
    public static let groundSnapUpDistance: Float = 2
    public static let groundSnapDownDistance: Float = 18
    public static let walkableNormalZ: Float = 0.7
    public static let maximumBumps = 4
    public static let maximumClipPlanes = 5

    public static let unsupportedFeatures: [SourceWorldWalkUnsupportedFeature] = [
        .stepUp,
        .duck,
        .verticalMove,
        .water,
        .ladder,
        .dynamicEntityCollision,
        .movingGround,
        .vPhysics,
        .stuckRecovery,
        .surfaceProperties,
        .deadPlayer,
        .nonWalkMoveType,
    ]

    private static let unsupportedContentsMask: SourceContents = [
        .water, .slime, .ladder,
    ]
    private static let nonJumpUpwardVelocity: Float = 140

    public let configuration: SourceWorldWalkConfiguration
    private let collisionProvider: any SourceWorldWalkCollisionProvider

    public init(
        collisionProvider: any SourceWorldWalkCollisionProvider,
        configuration: SourceWorldWalkConfiguration = SourceWorldWalkConfiguration()
    ) {
        self.collisionProvider = collisionProvider
        self.configuration = configuration
    }

    public func simulate(
        state: SourceWorldWalkState,
        command: SourceUserCommand
    ) throws -> SourceWorldWalkTick {
        try validate(configuration: configuration)
        try validate(state: state)
        try validate(command: command)
        try rejectUnsupportedState(state, command: command)

        // Work only on this copy. Nothing outside this function can observe it
        // if a later trace or capability check throws.
        var next = state
        next.viewAngles = command.viewAngles
        next.movement.outputWishVelocity = .zero

        let initialWaterLevel = try environmentLevel(at: next.origin)
        _ = try categorizeGround(move: &next.movement)

        var diagnostics = MovementDiagnostics()
        if initialWaterLevel >= 2 {
            try waterMove(
                move: &next.movement,
                command: command,
                diagnostics: &diagnostics
            )
            _ = try environmentLevel(at: next.origin)
            try validate(state: next)
            return SourceWorldWalkTick(
                commandNumber: command.commandNumber,
                state: next,
                bumpCount: diagnostics.bumpCount,
                collisionCount: diagnostics.collisionCount,
                didSnapToGround: false
            )
        }

        // CGameMovement applies a ground jump before the split gravity step.
        // The SDK's default jump height is 21 Source units; deriving the
        // impulse keeps custom gravity values coherent.
        if command.buttons.contains(.jump), next.isOnGround {
            next.velocity.z = sqrt(
                2 * configuration.movement.gravity * configuration.jumpHeight
            )
            next.isOnGround = false
        }

        SourceGameMovement.startGravity(
            move: &next.movement,
            parameters: configuration.movement
        )

        if next.isOnGround {
            next.velocity.z = 0
            SourceGameMovement.friction(
                move: &next.movement,
                parameters: configuration.movement
            )
        }

        SourceGameMovement.checkVelocity(
            move: &next.movement,
            parameters: configuration.movement
        )

        if next.isOnGround {
            try groundMove(
                move: &next.movement,
                command: command,
                diagnostics: &diagnostics
            )
        } else {
            try airMove(
                move: &next.movement,
                command: command,
                diagnostics: &diagnostics
            )
        }

        _ = try categorizeGround(move: &next.movement)
        SourceGameMovement.checkVelocity(
            move: &next.movement,
            parameters: configuration.movement
        )
        SourceGameMovement.finishGravity(
            move: &next.movement,
            parameters: configuration.movement
        )
        if next.isOnGround {
            next.velocity.z = 0
        }

        _ = try environmentLevel(at: next.origin)
        try validate(state: next)

        return SourceWorldWalkTick(
            commandNumber: command.commandNumber,
            state: next,
            bumpCount: diagnostics.bumpCount,
            collisionCount: diagnostics.collisionCount,
            didSnapToGround: diagnostics.didSnapToGround
        )
    }

    private func groundMove(
        move: inout SourceMoveData,
        command: SourceUserCommand,
        diagnostics: inout MovementDiagnostics
    ) throws {
        let wish = try wishMove(command: command)
        move.velocity.z = 0
        SourceGameMovement.accelerate(
            move: &move,
            wishDirection: wish.direction,
            wishSpeed: wish.speed,
            parameters: configuration.movement
        )
        move.velocity.z = 0
        move.outputWishVelocity += wish.direction * wish.speed

        // Source WalkMove stops before tracing at sub-unit speed. Retaining
        // that cutoff also avoids noisy zero-length hull work while idle.
        guard move.velocity.length >= 1 else {
            move.velocity = .zero
            try stayOnGround(move: &move, diagnostics: &diagnostics)
            return
        }

        try slideMove(move: &move, diagnostics: &diagnostics)
        try stayOnGround(move: &move, diagnostics: &diagnostics)
    }

    private func airMove(
        move: inout SourceMoveData,
        command: SourceUserCommand,
        diagnostics: inout MovementDiagnostics
    ) throws {
        let wish = try wishMove(command: command)
        SourceGameMovement.airAccelerate(
            move: &move,
            wishDirection: wish.direction,
            wishSpeed: wish.speed,
            parameters: configuration.movement
        )
        try slideMove(move: &move, diagnostics: &diagnostics)
    }

    /// A bounded world-brush water path. It intentionally omits currents,
    /// water-jumps, and dynamic volumes, but it keeps ordinary map water from
    /// becoming a permanent input rejection on iPad.
    private func waterMove(
        move: inout SourceMoveData,
        command: SourceUserCommand,
        diagnostics: inout MovementDiagnostics
    ) throws {
        let basis = try viewBasis(for: command.viewAngles, flatten: false)
        var wishVelocity = basis.forward * command.forwardMove +
            basis.right * command.sideMove
        if command.buttons.contains(.jump) {
            wishVelocity.z += configuration.maximumSpeed
        } else if command.forwardMove == 0, command.sideMove == 0 {
            wishVelocity.z -= 60
        }
        try requireFinite(
            wishVelocity,
            includingLengthSquared: true,
            field: "water wish velocity"
        )

        let rawWishSpeed = wishVelocity.length
        let maximumWaterSpeed = configuration.maximumSpeed * Float(0.8)
        let wishSpeed = min(rawWishSpeed, maximumWaterSpeed)
        let wishDirection = rawWishSpeed > 0 ? wishVelocity / rawWishSpeed : .zero

        let speed = move.velocity.length
        if speed > 0 {
            let retained = max(
                Float(0),
                Float(1) - configuration.movement.friction *
                    configuration.movement.frameTime
            )
            move.velocity *= retained
        }
        SourceGameMovement.accelerate(
            move: &move,
            wishDirection: wishDirection,
            wishSpeed: wishSpeed,
            parameters: configuration.movement
        )
        move.outputWishVelocity += wishDirection * wishSpeed
        move.isOnGround = false
        try slideMove(move: &move, diagnostics: &diagnostics)
    }

    private func slideMove(
        move: inout SourceMoveData,
        diagnostics: inout MovementDiagnostics
    ) throws {
        var timeLeft = configuration.movement.frameTime
        var planes: [SourceVector3] = []
        var originalVelocity = move.velocity
        let primalVelocity = move.velocity
        var allFraction: Float = 0

        for _ in 0 ..< Self.maximumBumps {
            guard move.velocity.length != 0 else { break }
            diagnostics.bumpCount += 1

            let end = move.origin + move.velocity * timeLeft
            let trace = try traceHull(start: move.origin, end: end)
            allFraction += trace.fraction

            if trace.fraction > 0 {
                move.origin = trace.endPosition
                originalVelocity = move.velocity
                planes.removeAll(keepingCapacity: true)
            }

            if trace.fraction == 1 {
                break
            }

            diagnostics.collisionCount += 1
            timeLeft -= timeLeft * trace.fraction

            guard planes.count < Self.maximumClipPlanes else {
                move.velocity = .zero
                break
            }
            planes.append(trace.plane.normal)

            var acceptedVelocity: SourceVector3?
            for (planeIndex, plane) in planes.enumerated() {
                let clipped = clipVelocity(originalVelocity, against: plane)
                var entersAnotherPlane = false
                for (otherIndex, otherPlane) in planes.enumerated()
                    where otherIndex != planeIndex {
                    if clipped.dot(otherPlane) < 0 {
                        entersAnotherPlane = true
                        break
                    }
                }
                if !entersAnotherPlane {
                    acceptedVelocity = clipped
                    break
                }
            }

            if let acceptedVelocity {
                move.velocity = acceptedVelocity
            } else if planes.count == 2 {
                let crease = cross(planes[0], planes[1])
                let creaseLength = crease.length
                guard creaseLength > 0 else {
                    move.velocity = .zero
                    break
                }
                let direction = crease / creaseLength
                move.velocity = direction * direction.dot(move.velocity)
            } else {
                move.velocity = .zero
                break
            }

            if move.velocity.dot(primalVelocity) <= 0 {
                move.velocity = .zero
                break
            }
        }

        if allFraction == 0 {
            move.velocity = .zero
        }
    }

    private func stayOnGround(
        move: inout SourceMoveData,
        diagnostics: inout MovementDiagnostics
    ) throws {
        let originalOrigin = move.origin
        let upward = try traceHull(
            start: originalOrigin,
            end: originalOrigin + SourceVector3(0, 0, Self.groundSnapUpDistance)
        )
        let downward = try traceHull(
            start: upward.endPosition,
            end: originalOrigin - SourceVector3(0, 0, Self.groundSnapDownDistance)
        )

        guard downward.fraction > 0,
              downward.fraction < 1,
              downward.plane.normal.z >= Self.walkableNormalZ else {
            return
        }

        let verticalDelta = abs(originalOrigin.z - downward.endPosition.z)
        let networkResolutionThreshold =
            SourceNetworkEncodingConstants.coordinateResolution * Float(0.5)
        if verticalDelta > networkResolutionThreshold {
            move.origin = downward.endPosition
            diagnostics.didSnapToGround = true
        }
    }

    @discardableResult
    private func categorizeGround(
        move: inout SourceMoveData
    ) throws -> SourceGameTrace? {
        // CGameMovement::CategorizePosition clears any previous surface's
        // friction before determining the current ground. Surface properties
        // are outside this slice, so world ground retains the neutral value.
        move.surfaceFriction = 1
        if move.velocity.z > Self.nonJumpUpwardVelocity {
            move.isOnGround = false
            return nil
        }

        let trace = try traceHull(
            start: move.origin,
            end: move.origin - SourceVector3(0, 0, Self.groundProbeDistance)
        )
        move.isOnGround = trace.didHit &&
            trace.plane.normal.z >= Self.walkableNormalZ
        return trace
    }

    private func traceHull(
        start: SourceVector3,
        end: SourceVector3
    ) throws -> SourceGameTrace {
        let delta = end - start
        let centerOffset = (Self.standingHullMins + Self.standingHullMaxs) * Float(0.5)
        try requireFinite(start, field: "trace start")
        try requireFinite(end, field: "trace end")
        try requireFinite(delta, includingLengthSquared: true, field: "trace delta")
        try requireFinite(
            start + centerOffset,
            includingLengthSquared: false,
            field: "centered trace start"
        )
        try requireFinite(
            end + centerOffset,
            includingLengthSquared: false,
            field: "centered trace end"
        )
        let ray = SourceRay(
            start: start,
            end: end,
            mins: Self.standingHullMins,
            maxs: Self.standingHullMaxs
        )
        let trace = try collisionProvider.traceWorldWalk(
            ray,
            mask: Self.playerMask
        )
        try validate(trace: trace, ray: ray)
        return trace
    }

    private func validate(trace: SourceGameTrace, ray: SourceRay) throws {
        for (name, value) in [
            ("trace StartPos.x", trace.startPosition.x),
            ("trace StartPos.y", trace.startPosition.y),
            ("trace StartPos.z", trace.startPosition.z),
            ("trace HitPos.x", trace.endPosition.x),
            ("trace HitPos.y", trace.endPosition.y),
            ("trace HitPos.z", trace.endPosition.z),
            ("trace HitNormal.x", trace.plane.normal.x),
            ("trace HitNormal.y", trace.plane.normal.y),
            ("trace HitNormal.z", trace.plane.normal.z),
            ("trace plane distance", trace.plane.distance),
            ("trace Fraction", trace.fraction),
            ("trace FractionLeftSolid", trace.fractionLeftSolid),
        ] where !value.isFinite {
            throw SourceWorldWalkError.nonFinite(name)
        }

        guard trace.fraction >= 0, trace.fraction <= 1 else {
            throw SourceWorldWalkError.inconsistentTrace("Fraction")
        }
        guard trace.fractionLeftSolid >= 0, trace.fractionLeftSolid <= 1 else {
            throw SourceWorldWalkError.inconsistentTrace("FractionLeftSolid")
        }
        if trace.startSolid || trace.allSolid {
            throw SourceWorldWalkError.embeddedInWorld(allSolid: trace.allSolid)
        }

        guard nearlyEqual(trace.startPosition, ray.actualStart) else {
            throw SourceWorldWalkError.inconsistentTrace("StartPos")
        }
        let expectedEnd = ray.actualStart + ray.delta * trace.fraction
        try requireFinite(
            expectedEnd,
            includingLengthSquared: false,
            field: "expected trace HitPos"
        )
        let resultDelta = trace.endPosition - trace.startPosition
        try requireFinite(
            resultDelta,
            includingLengthSquared: true,
            field: "trace result delta"
        )
        guard nearlyEqual(trace.endPosition, expectedEnd) else {
            throw SourceWorldWalkError.inconsistentTrace("HitPos")
        }

        if trace.didHit {
            guard let handle = trace.entityHandle else {
                throw SourceWorldWalkError.hitMissingWorldIdentity
            }
            guard handle.entryIndex == 0 else {
                throw SourceWorldWalkError.unsupportedDynamicEntity(handle.entryIndex)
            }
        } else if trace.entityHandle != nil {
            throw SourceWorldWalkError.inconsistentTrace("miss Entity identity")
        }

        if trace.didHit {
            let normalLengthSquared = trace.plane.normal.lengthSquared
            guard normalLengthSquared.isFinite else {
                throw SourceWorldWalkError.nonFinite("trace HitNormal lengthSquared")
            }
            guard abs(normalLengthSquared - 1) <= Float(0.001) else {
                throw SourceWorldWalkError.inconsistentTrace("non-unit hit plane normal")
            }
        }
    }

    private func environmentLevel(at origin: SourceVector3) throws -> Int {
        var waterLevel = 0
        for (index, height) in [Float(1), Float(36), Float(71)].enumerated() {
            let contents = try collisionProvider.worldWalkPointContents(
                at: origin + SourceVector3(0, 0, height),
                mask: Self.unsupportedContentsMask
            )
            if !contents.intersection([.water, .slime]).isEmpty {
                waterLevel = index + 1
            }
            if contents.contains(.ladder) {
                throw SourceWorldWalkError.unsupported(.ladder)
            }
        }
        return waterLevel
    }

    private func wishMove(
        command: SourceUserCommand
    ) throws -> (direction: SourceVector3, speed: Float) {
        let basis = try horizontalBasis(for: command.viewAngles)
        let wishVelocity = basis.forward * command.forwardMove +
            basis.right * command.sideMove
        try requireFinite(
            wishVelocity,
            includingLengthSquared: true,
            field: "command wish velocity"
        )
        let rawSpeed = wishVelocity.length
        guard rawSpeed.isFinite else {
            throw SourceWorldWalkError.nonFinite("command wish speed")
        }
        guard rawSpeed > 0 else { return (.zero, 0) }
        return (
            wishVelocity / rawSpeed,
            min(rawSpeed, configuration.maximumSpeed)
        )
    }

    private func horizontalBasis(
        for angles: SourceQAngle
    ) throws -> (forward: SourceVector3, right: SourceVector3) {
        try viewBasis(for: angles, flatten: true)
    }

    private func viewBasis(
        for angles: SourceQAngle,
        flatten: Bool
    ) throws -> (forward: SourceVector3, right: SourceVector3) {
        let degreesToRadians = Float.pi / Float(180)
        let pitch = angles.pitch * degreesToRadians
        let yaw = angles.yaw * degreesToRadians
        let roll = angles.roll * degreesToRadians
        for (name, value) in [("pitch", pitch), ("yaw", yaw), ("roll", roll)]
            where !value.isFinite {
            throw SourceWorldWalkError.nonFinite("command \(name) radians")
        }

        let sinePitch = sin(pitch)
        let cosinePitch = cos(pitch)
        let sineYaw = sin(yaw)
        let cosineYaw = cos(yaw)
        let sineRoll = sin(roll)
        let cosineRoll = cos(roll)

        var forward = SourceVector3(
            cosinePitch * cosineYaw,
            cosinePitch * sineYaw,
            -sinePitch
        )
        var right = SourceVector3(
            -sineRoll * sinePitch * cosineYaw + cosineRoll * sineYaw,
            -sineRoll * sinePitch * sineYaw - cosineRoll * cosineYaw,
            -sineRoll * cosinePitch
        )
        if flatten {
            forward.z = 0
            right.z = 0
        }
        try requireFinite(
            forward,
            includingLengthSquared: true,
            field: "command forward basis"
        )
        try requireFinite(
            right,
            includingLengthSquared: true,
            field: "command right basis"
        )
        let forwardLength = forward.length
        let rightLength = right.length
        if forwardLength > 0 { forward = forward / forwardLength }
        if rightLength > 0 { right = right / rightLength }
        return (forward, right)
    }

    private func clipVelocity(
        _ velocity: SourceVector3,
        against normal: SourceVector3
    ) -> SourceVector3 {
        let backoff = velocity.dot(normal)
        var clipped = velocity - normal * backoff
        let adjustment = clipped.dot(normal)
        if adjustment < 0 {
            clipped -= normal * adjustment
        }
        return clipped
    }

    private func cross(_ lhs: SourceVector3, _ rhs: SourceVector3) -> SourceVector3 {
        SourceVector3(
            lhs.y * rhs.z - lhs.z * rhs.y,
            lhs.z * rhs.x - lhs.x * rhs.z,
            lhs.x * rhs.y - lhs.y * rhs.x
        )
    }

    private func validate(configuration: SourceWorldWalkConfiguration) throws {
        let parameters = configuration.movement
        for (name, value) in [
            ("frameTime", parameters.frameTime),
            ("gravity", parameters.gravity),
            ("maximumVelocity", parameters.maximumVelocity),
            ("friction", parameters.friction),
            ("stopSpeed", parameters.stopSpeed),
            ("acceleration", parameters.acceleration),
            ("airAcceleration", parameters.airAcceleration),
            ("airSpeedCap", parameters.airSpeedCap),
            ("maximumSpeed", configuration.maximumSpeed),
            ("jumpHeight", configuration.jumpHeight),
        ] {
            guard value.isFinite else {
                throw SourceWorldWalkError.nonFinite("configuration \(name)")
            }
            guard value >= 0 else {
                throw SourceWorldWalkError.invalidConfiguration(name)
            }
        }
        guard parameters.frameTime > 0,
              parameters.maximumVelocity > 0 else {
            throw SourceWorldWalkError.invalidConfiguration("frameTime/maximumVelocity")
        }
        for (name, value) in [
            ("gravity per tick", parameters.gravity * parameters.frameTime),
            ("friction per tick", parameters.friction * parameters.frameTime),
            (
                "ground acceleration per tick",
                parameters.acceleration * parameters.frameTime * configuration.maximumSpeed
            ),
            (
                "air acceleration per tick",
                parameters.airAcceleration * parameters.frameTime * configuration.maximumSpeed
            ),
            ("maximum displacement per tick", parameters.maximumVelocity * parameters.frameTime),
            ("jump impulse squared", 2 * parameters.gravity * configuration.jumpHeight),
        ] where !value.isFinite {
            throw SourceWorldWalkError.nonFinite("configuration \(name)")
        }
    }

    private func validate(state: SourceWorldWalkState) throws {
        let move = state.movement
        for (name, value) in [
            ("state origin.x", move.origin.x),
            ("state origin.y", move.origin.y),
            ("state origin.z", move.origin.z),
            ("state velocity.x", move.velocity.x),
            ("state velocity.y", move.velocity.y),
            ("state velocity.z", move.velocity.z),
            ("state baseVelocity.x", move.baseVelocity.x),
            ("state baseVelocity.y", move.baseVelocity.y),
            ("state baseVelocity.z", move.baseVelocity.z),
            ("state outputWishVelocity.x", move.outputWishVelocity.x),
            ("state outputWishVelocity.y", move.outputWishVelocity.y),
            ("state outputWishVelocity.z", move.outputWishVelocity.z),
            ("state entityGravity", move.entityGravity),
            ("state surfaceFriction", move.surfaceFriction),
            ("state waterJumpTime", move.waterJumpTime),
            ("state view pitch", state.viewAngles.pitch),
            ("state view yaw", state.viewAngles.yaw),
            ("state view roll", state.viewAngles.roll),
        ] where !value.isFinite {
            throw SourceWorldWalkError.nonFinite(name)
        }
        guard move.surfaceFriction >= 0 else {
            throw SourceWorldWalkError.invalidConfiguration("surfaceFriction")
        }
        try requireFinite(
            move.velocity,
            includingLengthSquared: true,
            field: "state velocity"
        )
        try requireFinite(
            move.baseVelocity,
            includingLengthSquared: true,
            field: "state baseVelocity"
        )
        try requireFinite(
            move.outputWishVelocity,
            includingLengthSquared: true,
            field: "state outputWishVelocity"
        )
        let centeredOrigin = move.origin + SourceVector3(0, 0, 36)
        try requireFinite(
            centeredOrigin,
            includingLengthSquared: false,
            field: "state centered origin"
        )
    }

    private func validate(command: SourceUserCommand) throws {
        for (name, value) in [
            ("command forwardMove", command.forwardMove),
            ("command sideMove", command.sideMove),
            ("command upMove", command.upMove),
            ("command view pitch", command.viewAngles.pitch),
            ("command view yaw", command.viewAngles.yaw),
            ("command view roll", command.viewAngles.roll),
        ] where !value.isFinite {
            throw SourceWorldWalkError.nonFinite(name)
        }
    }

    private func rejectUnsupportedState(
        _ state: SourceWorldWalkState,
        command: SourceUserCommand
    ) throws {
        guard state.moveType == .walk else {
            let feature: SourceWorldWalkUnsupportedFeature =
                state.moveType == .vPhysics ? .vPhysics : .nonWalkMoveType
            throw SourceWorldWalkError.unsupported(feature)
        }
        if state.movement.isDead {
            throw SourceWorldWalkError.unsupported(.deadPlayer)
        }
        if command.buttons.contains(.duck) {
            throw SourceWorldWalkError.unsupported(.duck)
        }
        if command.upMove != 0 {
            throw SourceWorldWalkError.unsupported(.verticalMove)
        }
        if state.movement.waterJumpTime != 0 {
            throw SourceWorldWalkError.unsupported(.water)
        }
        if state.movement.baseVelocity != .zero {
            throw SourceWorldWalkError.unsupported(.movingGround)
        }
    }

    private func requireFinite(
        _ vector: SourceVector3,
        includingLengthSquared: Bool = false,
        field: String
    ) throws {
        guard vector.x.isFinite, vector.y.isFinite, vector.z.isFinite else {
            throw SourceWorldWalkError.nonFinite(field)
        }
        if includingLengthSquared, !vector.lengthSquared.isFinite {
            throw SourceWorldWalkError.nonFinite("\(field) lengthSquared")
        }
    }

    private func nearlyEqual(
        _ lhs: SourceVector3,
        _ rhs: SourceVector3,
        tolerance: Float = Float(0.000_1)
    ) -> Bool {
        abs(lhs.x - rhs.x) <= tolerance &&
            abs(lhs.y - rhs.y) <= tolerance &&
            abs(lhs.z - rhs.z) <= tolerance
    }

    private struct MovementDiagnostics {
        var bumpCount = 0
        var collisionCount = 0
        var didSnapToGround = false
    }
}
