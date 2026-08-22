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
    case duckTransition
    case duckJump
    case verticalMove
    case waterJump
    case waterCurrent
    case dynamicWaterVolume
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

/// Numeric water levels shared by `CBasePlayer` and `IMoveHelper` in Source
/// SDK 2013. Keeping this in the authoritative movement state makes water
/// entry and exit part of the canonical Player snapshot.
public enum SourcePlayerWaterLevel: UInt8, CaseIterable, Equatable, Sendable {
    case notInWater = 0
    case feet = 1
    case waist = 2
    case eyes = 3

    public var isSwimming: Bool {
        rawValue > Self.feet.rawValue
    }
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
                ? "Source player hull is all-solid in the world"
                : "Source player hull starts solid in the world"
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
    /// Source SDK 2013 `movevars_shared.cpp` declares `sv_stepsize` with the
    /// replicated default `18`; `CBasePlayer::SharedSpawn` copies it into the
    /// canonical per-player step size used by `StepMove` and `StayOnGround`.
    public static let sourceSDKDefaultStepSize: Float = 18

    public var movement: SourceMovementParameters
    public var maximumSpeed: Float
    /// `WaterMove` uses the separately carried `m_flClientMaxSpeed` for jump
    /// and upward-look intent. It defaults to the ordinary maximum when the
    /// host does not author a distinct client limit.
    public var clientMaximumSpeed: Float
    public var jumpHeight: Float
    public var stepSize: Float
    /// Standing `CBasePlayer::GetViewOffset().z` sampled by `CheckWater`.
    public var standingViewOffsetZ: Float
    /// Ducking `CBasePlayer::GetViewOffset().z` sampled by `CheckWater`.
    public var duckViewOffsetZ: Float
    /// Source `sv_noclipspeed`, `sv_noclipaccelerate`, `sv_maxspeed`, and
    /// `sv_friction` values consumed only by `MOVETYPE_NOCLIP`.
    public var noClipMovement: SourceNoClipMovementParameters

    public init(
        movement: SourceMovementParameters = SourceMovementParameters(),
        maximumSpeed: Float = 320,
        clientMaximumSpeed: Float? = nil,
        jumpHeight: Float = 21,
        stepSize: Float = 18,
        standingViewOffsetZ: Float = 64,
        duckViewOffsetZ: Float = 28,
        noClipMovement: SourceNoClipMovementParameters? = nil
    ) {
        self.movement = movement
        self.maximumSpeed = maximumSpeed
        self.clientMaximumSpeed = clientMaximumSpeed ?? maximumSpeed
        self.jumpHeight = jumpHeight
        self.stepSize = stepSize
        self.standingViewOffsetZ = standingViewOffsetZ
        self.duckViewOffsetZ = duckViewOffsetZ
        self.noClipMovement = noClipMovement ?? SourceNoClipMovementParameters(
            frameTime: movement.frameTime,
            friction: movement.friction
        )
    }
}

/// Persistent value state for one world-only walking player. `movement` stays
/// in Source Float precision and can be used directly by SourceGameMovement.
public struct SourceWorldWalkState: Equatable, Sendable {
    public var movement: SourceMoveData
    public var viewAngles: SourceQAngle
    public var moveType: SourceMoveType
    public var waterLevel: SourcePlayerWaterLevel
    /// Fully-ducked `FL_DUCKING`/`m_bDucked` state. Timed eye interpolation
    /// and duck-jump timers are deliberately not represented by this slice.
    public var isDucked: Bool
    /// Canonical local eye offset selected by the standing or duck view hull.
    public var viewOffset: SourceVector3
    /// Last world ladder plane selected by `CGameMovement::LadderMove`.
    /// Source retains this vector on the player and uses its negation for the
    /// next contact trace while `MOVETYPE_LADDER` is active.
    public var ladderNormal: SourceVector3

    public init(
        movement: SourceMoveData = SourceMoveData(),
        viewAngles: SourceQAngle = .zero,
        moveType: SourceMoveType = .walk,
        waterLevel: SourcePlayerWaterLevel = .notInWater,
        isDucked: Bool = false,
        viewOffset: SourceVector3 = SourceVector3(0, 0, 64),
        ladderNormal: SourceVector3 = .zero
    ) {
        self.movement = movement
        self.viewAngles = viewAngles
        self.moveType = moveType
        self.waterLevel = waterLevel
        self.isDucked = isDucked
        self.viewOffset = viewOffset
        self.ladderNormal = ladderNormal
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
        waterLevel = .notInWater
        isDucked = false
        viewOffset = SourceVector3(0, 0, 64)
        ladderNormal = .zero
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
    /// Positive `m_outStepHeight` equivalent accumulated by `StepMove`.
    public let stepHeight: Float

    public init(
        commandNumber: Int32,
        state: SourceWorldWalkState,
        bumpCount: Int,
        collisionCount: Int,
        didSnapToGround: Bool,
        stepHeight: Float = 0
    ) {
        self.commandNumber = commandNumber
        self.state = state
        self.bumpCount = bumpCount
        self.collisionCount = collisionCount
        self.didSnapToGround = didSnapToGround
        self.stepHeight = stepHeight
    }
}

/// Minimum honest Source-style standing/duck walking loop against BSP world
/// brushes. It composes the existing Float movement equations with hull traces,
/// ground categorization, and four-bump plane clipping.
///
/// The input state is never mutated. Every provider call and validation must
/// succeed before the returned state becomes observable, so trace failures and
/// unsupported content cannot leak a partially advanced player.
public struct SourceWorldWalkSolver: Sendable {
    /// Fixed Source SDK 2013 `hl2mp_gamerules.cpp` `g_HL2MPViewVectors`.
    /// Garry's Mod inherits these ordinary HL2MP player hull endpoints.
    public static let standingHullMins = SourceVector3(-16, -16, 0)
    public static let standingHullMaxs = SourceVector3(16, 16, 72)
    public static let duckHullMins = SourceVector3(-16, -16, 0)
    public static let duckHullMaxs = SourceVector3(16, 16, 36)
    public static let playerMask = SourceMasks.playerSolidBrushOnly
    public static let ladderMask = SourceMasks.playerSolid
    public static let groundProbeDistance: Float = 2
    public static let groundSnapUpDistance: Float = 2
    public static let groundSnapDownDistance =
        SourceWorldWalkConfiguration.sourceSDKDefaultStepSize
    public static let walkableNormalZ: Float = 0.7
    public static let maximumBumps = 4
    public static let maximumClipPlanes = 5
    /// Fixed Source SDK 2013 `CGameMovement` ladder contract.
    public static let ladderDistance: Float = 2
    public static let maximumClimbSpeed: Float = 200
    public static let ladderJumpOffSpeed: Float = 270

    public static let unsupportedFeatures: [SourceWorldWalkUnsupportedFeature] = [
        .duckTransition,
        .duckJump,
        .verticalMove,
        .waterJump,
        .waterCurrent,
        .dynamicWaterVolume,
        .dynamicEntityCollision,
        .movingGround,
        .vPhysics,
        .stuckRecovery,
        .surfaceProperties,
        .deadPlayer,
        .nonWalkMoveType,
    ]

    private static let nonJumpUpwardVelocity: Float = 140
    private static let waterSinkSpeed: Float = 60
    private static let waterJumpSpeed: Float = 100
    private static let slimeJumpSpeed: Float = 80
    private static let waterWishSpeedScale: Float = 0.8
    private static let waterMinimumSpeed: Float = 0.1
    private static let duckSpeedScale: Float = 0.333_333_33

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
        try rejectUnsupportedState(state)

        // Work only on this copy. Nothing outside this function can observe it
        // if a later trace or capability check throws.
        var next = state
        next.viewAngles = command.viewAngles
        next.movement.outputWishVelocity = .zero

        var activeHull = playerHull(isDucked: next.isDucked)
        var initialWater = try waterEnvironment(
            at: next.origin,
            hull: activeHull,
            viewOffset: next.viewOffset
        )
        next.waterLevel = initialWater.level
        _ = try categorizeGround(move: &next.movement, hull: activeHull)

        if command.buttons.contains(.jump),
           (next.isDucked || command.buttons.contains(.duck)),
           !initialWater.level.isSwimming {
            throw SourceWorldWalkError.unsupported(.duckJump)
        }

        // `Duck()` calls `HandleDuckingSpeedCrop` before either FinishDuck or
        // FinishUnDuck. Preserve that order: a player who began this command
        // fully ducked and grounded receives the SDK's exact one-third input
        // crop, including the command that successfully stands up.
        var movementCommand = command
        if next.isDucked, next.isOnGround {
            movementCommand.forwardMove *= Self.duckSpeedScale
            movementCommand.sideMove *= Self.duckSpeedScale
            movementCommand.upMove *= Self.duckSpeedScale
        }

        // This bounded slice commits the fully-ducked endpoints immediately.
        // It models CanUnduck/FinishDuck/FinishUnDuck, while the SDK's 0.4 s
        // and 0.2 s spline eye transitions remain an explicit capability miss.
        if try updateDuckState(
            state: &next,
            wantsDuck: command.buttons.contains(.duck)
        ) {
            activeHull = playerHull(isDucked: next.isDucked)
            _ = try categorizeGround(move: &next.movement, hull: activeHull)
            initialWater = try waterEnvironment(
                at: next.origin,
                hull: activeHull,
                viewOffset: next.viewOffset
            )
            next.waterLevel = initialWater.level
        }

        // Source PlayerMove categorizes the player and runs Duck before the
        // movement-type switch. LadderMove also runs here but returns false
        // immediately for MOVETYPE_NOCLIP. FullNoClipMove then advances the
        // origin without a displacement trace, gravity, or post-move
        // categorization. Keep that exact boundary: pre-move water/ground and
        // any duck endpoint traces above are observable, while noclip motion
        // itself never clips against the BSP.
        if next.moveType == .noClip {
            SourceGameMovement.fullNoClipMove(
                move: &next.movement,
                command: movementCommand,
                parameters: configuration.noClipMovement
            )
            try validate(state: next)
            return SourceWorldWalkTick(
                commandNumber: command.commandNumber,
                state: next,
                bumpCount: 0,
                collisionCount: 0,
                didSnapToGround: false
            )
        }

        var diagnostics = MovementDiagnostics()

        // Source SDK 2013 PlayerMove calls LadderMove after its initial
        // categorization and before dispatching the resulting move type. A
        // jump can therefore find a ladder and switch straight back to WALK
        // in this same command with a 270-unit normal impulse.
        let hasLadderContact = try ladderMove(
            state: &next,
            command: movementCommand,
            hull: activeHull
        )
        if !hasLadderContact, next.moveType == .ladder {
            next.moveType = .walk
        }
        if next.moveType == .ladder {
            try slideMove(
                move: &next.movement,
                hull: activeHull,
                diagnostics: &diagnostics
            )
            next.waterLevel = try waterEnvironment(
                at: next.origin,
                hull: activeHull,
                viewOffset: next.viewOffset
            ).level
            try validate(state: next)
            return SourceWorldWalkTick(
                commandNumber: command.commandNumber,
                state: next,
                bumpCount: diagnostics.bumpCount,
                collisionCount: diagnostics.collisionCount,
                didSnapToGround: false,
                stepHeight: diagnostics.stepHeight
            )
        }

        if initialWater.level.isSwimming {
            // Base `CheckJumpButton` detaches from ground and authors the
            // initial swim-up velocity before `WaterMove` adds jump intent.
            if movementCommand.buttons.contains(.jump) {
                next.isOnGround = false
                if initialWater.waterType == .water {
                    next.velocity.z = Self.waterJumpSpeed
                } else if initialWater.waterType == .slime {
                    next.velocity.z = Self.slimeJumpSpeed
                }
            }
            try waterMove(
                move: &next.movement,
                command: movementCommand,
                hull: activeHull,
                diagnostics: &diagnostics
            )
            _ = try categorizeGround(move: &next.movement, hull: activeHull)
            next.waterLevel = try waterEnvironment(
                at: next.origin,
                hull: activeHull,
                viewOffset: next.viewOffset
            ).level
            SourceGameMovement.checkVelocity(
                move: &next.movement,
                parameters: configuration.movement
            )
            if next.isOnGround {
                next.velocity.z = 0
            }
            try validate(state: next)
            return SourceWorldWalkTick(
                commandNumber: command.commandNumber,
                state: next,
                bumpCount: diagnostics.bumpCount,
                collisionCount: diagnostics.collisionCount,
                didSnapToGround: diagnostics.didSnapToGround,
                stepHeight: diagnostics.stepHeight
            )
        }

        // `m_flUpMove` belongs to WaterMove (and ladder movement). Keeping it
        // an explicit miss on ordinary WALK prevents noclip-like vertical
        // movement from leaking into the bounded solver.
        if movementCommand.upMove != 0 {
            throw SourceWorldWalkError.unsupported(.verticalMove)
        }

        // CGameMovement applies a ground jump before the split gravity step.
        // The SDK's default jump height is 21 Source units; deriving the
        // impulse keeps custom gravity values coherent.
        if movementCommand.buttons.contains(.jump), next.isOnGround {
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
                command: movementCommand,
                hull: activeHull,
                diagnostics: &diagnostics
            )
        } else {
            try airMove(
                move: &next.movement,
                command: movementCommand,
                hull: activeHull,
                diagnostics: &diagnostics
            )
        }

        _ = try categorizeGround(move: &next.movement, hull: activeHull)
        SourceGameMovement.checkVelocity(
            move: &next.movement,
            parameters: configuration.movement
        )
        let finalWater = try waterEnvironment(
            at: next.origin,
            hull: activeHull,
            viewOffset: next.viewOffset
        )
        next.waterLevel = finalWater.level
        if !finalWater.level.isSwimming {
            SourceGameMovement.finishGravity(
                move: &next.movement,
                parameters: configuration.movement
            )
        }
        if next.isOnGround {
            next.velocity.z = 0
        }

        try validate(state: next)

        return SourceWorldWalkTick(
            commandNumber: command.commandNumber,
            state: next,
            bumpCount: diagnostics.bumpCount,
            collisionCount: diagnostics.collisionCount,
            didSnapToGround: diagnostics.didSnapToGround,
            stepHeight: diagnostics.stepHeight
        )
    }

    /// Fully-ducked endpoints from Source SDK 2013 `FinishDuck`,
    /// `CanUnduck`, and `FinishUnDuck`. The ordinary ground transition keeps
    /// the feet fixed; the airborne transition keeps the hull top fixed by
    /// shifting the origin by the exact standing/duck size delta.
    @discardableResult
    private func updateDuckState(
        state: inout SourceWorldWalkState,
        wantsDuck: Bool
    ) throws -> Bool {
        guard wantsDuck != state.isDucked else { return false }

        let standing = playerHull(isDucked: false)
        let duck = playerHull(isDucked: true)
        let standingSize = standing.maxs - standing.mins
        let duckSize = duck.maxs - duck.mins
        let hullSizeDelta = standingSize - duckSize

        if wantsDuck {
            if state.isOnGround {
                state.origin -= duck.mins - standing.mins
            } else {
                state.origin += hullSizeDelta
            }
            state.isDucked = true
            state.viewOffset = SourceVector3(0, 0, configuration.duckViewOffsetZ)
            return true
        }

        var standingOrigin = state.origin
        if state.isOnGround {
            standingOrigin += duck.mins - standing.mins
        } else {
            standingOrigin -= hullSizeDelta
        }

        // CanUnduck temporarily selects the standing hull and traces from the
        // current crouched origin to its candidate standing origin. A ceiling
        // therefore leaves the player fully ducked without partially changing
        // origin, hull, or view offset.
        let trace = try traceHull(
            start: state.origin,
            end: standingOrigin,
            hull: standing,
            allowEmbedded: true
        )
        guard !trace.startSolid, trace.fraction == 1 else { return false }

        state.origin = standingOrigin
        state.isDucked = false
        state.viewOffset = SourceVector3(0, 0, configuration.standingViewOffsetZ)
        return true
    }

    private func playerHull(isDucked: Bool) -> PlayerHull {
        if isDucked {
            return PlayerHull(mins: Self.duckHullMins, maxs: Self.duckHullMaxs)
        }
        return PlayerHull(mins: Self.standingHullMins, maxs: Self.standingHullMaxs)
    }

    /// The world-brush `CONTENTS_LADDER` portion of Source SDK 2013
    /// `CGameMovement::LadderMove`. Surface-property `climbable` and dynamic
    /// physprop ladders remain outside this world-only collision boundary.
    /// All state changes remain confined to the caller-owned transaction copy.
    private func ladderMove(
        state: inout SourceWorldWalkState,
        command: SourceUserCommand,
        hull: PlayerHull
    ) throws -> Bool {
        let basis = try viewBasis(for: command.viewAngles, flatten: false)
        let wishDirection: SourceVector3
        if state.moveType == .ladder {
            wishDirection = -state.ladderNormal
        } else {
            guard command.forwardMove != 0 || command.sideMove != 0 else {
                return false
            }
            let wishVelocity = basis.forward * command.forwardMove +
                basis.right * command.sideMove
            try requireFinite(
                wishVelocity,
                includingLengthSquared: true,
                field: "ladder wish velocity"
            )
            let wishLength = wishVelocity.length
            guard wishLength.isFinite else {
                throw SourceWorldWalkError.nonFinite("ladder wish speed")
            }
            guard wishLength > 0 else { return false }
            wishDirection = wishVelocity / wishLength
        }
        try requireFinite(
            wishDirection,
            includingLengthSquared: true,
            field: "ladder wish direction"
        )

        let trace = try traceHull(
            start: state.origin,
            end: state.origin + wishDirection * Self.ladderDistance,
            mask: Self.ladderMask,
            hull: hull
        )
        guard trace.fraction < 1, trace.contents.contains(.ladder) else {
            return false
        }

        state.moveType = .ladder
        state.ladderNormal = trace.plane.normal

        let floorContents = try collisionProvider.worldWalkPointContents(
            at: state.origin + SourceVector3(0, 0, hull.mins.z - 1),
            mask: SourceMasks.all
        )
        let onFloor = floorContents == .solid || state.isOnGround

        var forwardSpeed: Float = 0
        var rightSpeed: Float = 0
        if command.buttons.contains(.back) {
            forwardSpeed -= Self.maximumClimbSpeed
        }
        if command.buttons.contains(.forward) {
            forwardSpeed += Self.maximumClimbSpeed
        }
        if command.buttons.contains(.moveLeft) {
            rightSpeed -= Self.maximumClimbSpeed
        }
        if command.buttons.contains(.moveRight) {
            rightSpeed += Self.maximumClimbSpeed
        }

        if command.buttons.contains(.jump) {
            state.moveType = .walk
            state.velocity = trace.plane.normal * Self.ladderJumpOffSpeed
            return true
        }

        guard forwardSpeed != 0 || rightSpeed != 0 else {
            state.velocity = .zero
            return true
        }

        let intendedVelocity = basis.forward * forwardSpeed +
            basis.right * rightSpeed
        let verticalAxis = SourceVector3(0, 0, 1)
        var perpendicular = cross(verticalAxis, trace.plane.normal)
        let perpendicularLength = perpendicular.length
        if perpendicularLength > 0 {
            perpendicular = perpendicular / perpendicularLength
        }
        let normalSpeed = intendedVelocity.dot(trace.plane.normal)
        let intoFace = trace.plane.normal * normalSpeed
        let lateral = intendedVelocity - intoFace
        let ladderUp = cross(trace.plane.normal, perpendicular)
        state.velocity = lateral - ladderUp * normalSpeed
        if onFloor, normalSpeed > 0 {
            state.velocity += trace.plane.normal * Self.maximumClimbSpeed
        }
        try requireFinite(
            state.velocity,
            includingLengthSquared: true,
            field: "ladder velocity"
        )
        return true
    }

    private func groundMove(
        move: inout SourceMoveData,
        command: SourceUserCommand,
        hull: PlayerHull,
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
            try stayOnGround(move: &move, hull: hull, diagnostics: &diagnostics)
            return
        }

        let destination = move.origin +
            move.velocity * configuration.movement.frameTime
        let directTrace = try traceHull(
            start: move.origin,
            end: destination,
            hull: hull
        )
        if directTrace.fraction == 1 {
            move.origin = directTrace.endPosition
            diagnostics.bumpCount += 1
            try stayOnGround(move: &move, hull: hull, diagnostics: &diagnostics)
            return
        }

        try stepMove(
            move: &move,
            destination: destination,
            directTrace: directTrace,
            hull: hull,
            diagnostics: &diagnostics
        )
        try stayOnGround(move: &move, hull: hull, diagnostics: &diagnostics)
    }

    /// Source SDK 2013 `CGameMovement::StepMove`: evaluate the ordinary and
    /// raised slides as value transactions, then commit the branch that moved
    /// farther horizontally. Equal distances select the raised branch.
    private func stepMove(
        move: inout SourceMoveData,
        destination: SourceVector3,
        directTrace: SourceGameTrace,
        hull: PlayerHull,
        diagnostics: inout MovementDiagnostics
    ) throws {
        let original = move

        var downMove = original
        var downDiagnostics = MovementDiagnostics()
        try slideMove(
            move: &downMove,
            hull: hull,
            diagnostics: &downDiagnostics,
            firstDestination: destination,
            firstTrace: directTrace
        )

        var upMove = original
        var upDiagnostics = MovementDiagnostics()
        let stepDistance = configuration.stepSize +
            SourceCollisionConstants.distanceEpsilon
        let upwardTrace = try traceHull(
            start: upMove.origin,
            end: upMove.origin + SourceVector3(0, 0, stepDistance),
            hull: hull,
            allowEmbedded: true
        )
        if !upwardTrace.startSolid, !upwardTrace.allSolid {
            upMove.origin = upwardTrace.endPosition
        }

        try slideMove(move: &upMove, hull: hull, diagnostics: &upDiagnostics)

        let downwardTrace = try traceHull(
            start: upMove.origin,
            end: upMove.origin - SourceVector3(0, 0, stepDistance),
            hull: hull,
            allowEmbedded: true
        )
        if downwardTrace.plane.normal.z < Self.walkableNormalZ {
            let height = downMove.origin.z - original.origin.z
            if height > 0 { downDiagnostics.stepHeight += height }
            move = downMove
            diagnostics.absorb(downDiagnostics)
            return
        }

        if !downwardTrace.startSolid, !downwardTrace.allSolid {
            upMove.origin = downwardTrace.endPosition
        }

        let downDelta = downMove.origin - original.origin
        let upDelta = upMove.origin - original.origin
        let downDistanceSquared = downDelta.x * downDelta.x +
            downDelta.y * downDelta.y
        let upDistanceSquared = upDelta.x * upDelta.x +
            upDelta.y * upDelta.y

        if downDistanceSquared > upDistanceSquared {
            let height = downMove.origin.z - original.origin.z
            if height > 0 { downDiagnostics.stepHeight += height }
            move = downMove
            diagnostics.absorb(downDiagnostics)
        } else {
            // Source retains the ordinary slide's vertical velocity even
            // when the raised transaction wins.
            upMove.velocity.z = downMove.velocity.z
            let height = upMove.origin.z - original.origin.z
            if height > 0 { upDiagnostics.stepHeight += height }
            move = upMove
            diagnostics.absorb(upDiagnostics)
        }
    }

    private func airMove(
        move: inout SourceMoveData,
        command: SourceUserCommand,
        hull: PlayerHull,
        diagnostics: inout MovementDiagnostics
    ) throws {
        let wish = try wishMove(command: command)
        SourceGameMovement.airAccelerate(
            move: &move,
            wishDirection: wish.direction,
            wishSpeed: wish.speed,
            parameters: configuration.movement
        )
        try slideMove(move: &move, hull: hull, diagnostics: &diagnostics)
    }

    /// Source SDK 2013 `CGameMovement::WaterMove`, bounded to BSP world
    /// collision. Water-jump ledge probing, currents, and dynamic volumes stay
    /// explicit capability misses rather than being approximated.
    private func waterMove(
        move: inout SourceMoveData,
        command: SourceUserCommand,
        hull: PlayerHull,
        diagnostics: inout MovementDiagnostics
    ) throws {
        let basis = try viewBasis(for: command.viewAngles, flatten: false)
        var wishVelocity = basis.forward * command.forwardMove +
            basis.right * command.sideMove
        if command.buttons.contains(.jump) {
            wishVelocity.z += configuration.clientMaximumSpeed
        } else if command.forwardMove == 0,
                  command.sideMove == 0,
                  command.upMove == 0 {
            wishVelocity.z -= Self.waterSinkSpeed
        } else {
            let upwardMovement = min(
                max(command.forwardMove * basis.forward.z * Float(2), 0),
                configuration.clientMaximumSpeed
            )
            wishVelocity.z += command.upMove + upwardMovement
        }
        try requireFinite(
            wishVelocity,
            includingLengthSquared: true,
            field: "water wish velocity"
        )

        let rawWishSpeed = wishVelocity.length
        let cappedWishSpeed = min(rawWishSpeed, configuration.maximumSpeed)
        let wishSpeed = cappedWishSpeed * Self.waterWishSpeedScale
        let wishDirection = rawWishSpeed > 0 ? wishVelocity / rawWishSpeed : .zero

        let speed = move.velocity.length
        let newSpeed: Float
        if speed > 0 {
            var candidate = speed - configuration.movement.frameTime * speed *
                configuration.movement.friction * move.surfaceFriction
            if candidate < Self.waterMinimumSpeed { candidate = 0 }
            newSpeed = candidate
            move.velocity *= candidate / speed
        } else {
            newSpeed = 0
        }

        // WaterMove predates the general Accelerate helper: its `addspeed`
        // compares against total post-friction speed, not the wish-direction
        // dot product. Preserve that operation order and output delta.
        if wishSpeed >= Self.waterMinimumSpeed {
            let addSpeed = wishSpeed - newSpeed
            if addSpeed > 0 {
                var accelerationSpeed = configuration.movement.acceleration *
                    wishSpeed * configuration.movement.frameTime *
                    move.surfaceFriction
                if accelerationSpeed > addSpeed { accelerationSpeed = addSpeed }
                let addedVelocity = wishDirection * accelerationSpeed
                move.velocity += addedVelocity
                move.outputWishVelocity += addedVelocity
            }
        }

        let destination = move.origin +
            move.velocity * configuration.movement.frameTime
        let directTrace = try traceHull(
            start: move.origin,
            end: destination,
            hull: hull
        )
        if directTrace.fraction == 1 {
            // WaterMove first reaches the intended point, then presses down
            // from one unit above the configured step height.
            let downwardStart = destination + SourceVector3(
                0,
                0,
                configuration.stepSize + Float(1)
            )
            let downwardTrace = try traceHull(
                start: downwardStart,
                end: destination,
                hull: hull,
                allowEmbedded: true
            )
            diagnostics.bumpCount += 1
            if !downwardTrace.startSolid, !downwardTrace.allSolid {
                diagnostics.bumpCount += 1
                diagnostics.stepHeight +=
                    downwardTrace.endPosition.z - move.origin.z
                move.origin = downwardTrace.endPosition
                return
            }

            try slideMove(
                move: &move,
                hull: hull,
                diagnostics: &diagnostics,
                firstDestination: destination,
                firstTrace: directTrace
            )
            return
        }

        if !move.isOnGround {
            try slideMove(
                move: &move,
                hull: hull,
                diagnostics: &diagnostics,
                firstDestination: destination,
                firstTrace: directTrace
            )
            return
        }

        try stepMove(
            move: &move,
            destination: destination,
            directTrace: directTrace,
            hull: hull,
            diagnostics: &diagnostics
        )
    }

    private func slideMove(
        move: inout SourceMoveData,
        hull: PlayerHull,
        diagnostics: inout MovementDiagnostics,
        firstDestination: SourceVector3? = nil,
        firstTrace: SourceGameTrace? = nil
    ) throws {
        var timeLeft = configuration.movement.frameTime
        var planes: [SourceVector3] = []
        var originalVelocity = move.velocity
        let primalVelocity = move.velocity
        var allFraction: Float = 0

        for bumpIndex in 0 ..< Self.maximumBumps {
            guard move.velocity.length != 0 else { break }
            diagnostics.bumpCount += 1

            let end = move.origin + move.velocity * timeLeft
            let trace: SourceGameTrace
            if bumpIndex == 0,
               let firstDestination,
               let firstTrace,
               end == firstDestination {
                trace = firstTrace
            } else {
                trace = try traceHull(
                    start: move.origin,
                    end: end,
                    hull: hull
                )
            }
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
        hull: PlayerHull,
        diagnostics: inout MovementDiagnostics
    ) throws {
        let originalOrigin = move.origin
        let upward = try traceHull(
            start: originalOrigin,
            end: originalOrigin + SourceVector3(0, 0, Self.groundSnapUpDistance),
            hull: hull
        )
        let downward = try traceHull(
            start: upward.endPosition,
            end: originalOrigin - SourceVector3(0, 0, configuration.stepSize),
            hull: hull
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
        move: inout SourceMoveData,
        hull: PlayerHull
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
            end: move.origin - SourceVector3(0, 0, Self.groundProbeDistance),
            hull: hull
        )
        move.isOnGround = trace.didHit &&
            trace.plane.normal.z >= Self.walkableNormalZ
        return trace
    }

    private func traceHull(
        start: SourceVector3,
        end: SourceVector3,
        mask: SourceContents = Self.playerMask,
        hull: PlayerHull,
        allowEmbedded: Bool = false
    ) throws -> SourceGameTrace {
        let delta = end - start
        let centerOffset = (hull.mins + hull.maxs) * Float(0.5)
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
            mins: hull.mins,
            maxs: hull.maxs
        )
        let trace = try collisionProvider.traceWorldWalk(
            ray,
            mask: mask
        )
        try validate(trace: trace, ray: ray, allowEmbedded: allowEmbedded)
        return trace
    }

    private func validate(
        trace: SourceGameTrace,
        ray: SourceRay,
        allowEmbedded: Bool = false
    ) throws {
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
        if !allowEmbedded, trace.startSolid || trace.allSolid {
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

        if trace.didHit,
           !(allowEmbedded && (trace.startSolid || trace.allSolid)) {
            let normalLengthSquared = trace.plane.normal.lengthSquared
            guard normalLengthSquared.isFinite else {
                throw SourceWorldWalkError.nonFinite("trace HitNormal lengthSquared")
            }
            guard abs(normalLengthSquared - 1) <= Float(0.001) else {
                throw SourceWorldWalkError.inconsistentTrace("non-unit hit plane normal")
            }
        }
    }

    /// Source SDK 2013 `CheckWater`: feet must be wet before waist is sampled,
    /// and waist must be wet before the active standing/duck eye is sampled.
    /// The provider is world-only, so dynamic `func_water_analog` entities are
    /// deliberately absent from this result.
    private func waterEnvironment(
        at origin: SourceVector3,
        hull: PlayerHull,
        viewOffset: SourceVector3
    ) throws -> WaterEnvironment {
        let center = (hull.mins + hull.maxs) * Float(0.5)
        let feetPoint = SourceVector3(
            origin.x + center.x,
            origin.y + center.y,
            origin.z + hull.mins.z + Float(1)
        )
        let feetContents = try collisionProvider.worldWalkPointContents(
            at: feetPoint,
            mask: SourceMasks.water
        )
        guard !feetContents.intersection(SourceMasks.water).isEmpty else {
            return WaterEnvironment(level: .notInWater, waterType: .empty)
        }

        var level = SourcePlayerWaterLevel.feet
        var lastContents = feetContents
        let waistPoint = SourceVector3(
            feetPoint.x,
            feetPoint.y,
            origin.z + center.z
        )
        let waistContents = try collisionProvider.worldWalkPointContents(
            at: waistPoint,
            mask: SourceMasks.water
        )
        if !waistContents.intersection(SourceMasks.water).isEmpty {
            level = .waist
            lastContents = waistContents
            let eyeContents = try collisionProvider.worldWalkPointContents(
                at: SourceVector3(
                    feetPoint.x,
                    feetPoint.y,
                    origin.z + viewOffset.z
                ),
                mask: SourceMasks.water
            )
            if !eyeContents.intersection(SourceMasks.water).isEmpty {
                level = .eyes
                lastContents = eyeContents
            }
        }

        // Source applies brush currents through base velocity. This bounded
        // solver rejects them transactionally until that persistent path is
        // connected instead of silently dropping authored map motion.
        if !lastContents.intersection(SourceMasks.current).isEmpty {
            throw SourceWorldWalkError.unsupported(.waterCurrent)
        }
        // The BSP/provider returns the complete leaf OptionSet. Source stores
        // the sampled liquid kind for CheckJumpButton, so normalize away
        // unrelated leaf flags while preserving slime's distinct 80 u/s path.
        let waterType: SourceContents
        if feetContents.contains(.slime) {
            waterType = .slime
        } else if feetContents.contains(.water) {
            waterType = .water
        } else {
            waterType = feetContents
        }
        return WaterEnvironment(level: level, waterType: waterType)
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
            ("clientMaximumSpeed", configuration.clientMaximumSpeed),
            ("jumpHeight", configuration.jumpHeight),
            ("stepSize", configuration.stepSize),
            ("standingViewOffsetZ", configuration.standingViewOffsetZ),
            ("duckViewOffsetZ", configuration.duckViewOffsetZ),
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
            ("noClip frameTime", configuration.noClipMovement.frameTime),
            ("noClip speedFactor", configuration.noClipMovement.speedFactor),
            (
                "noClip maximumAcceleration",
                configuration.noClipMovement.maximumAcceleration
            ),
            ("noClip maximumSpeed", configuration.noClipMovement.maximumSpeed),
            ("noClip friction", configuration.noClipMovement.friction),
        ] where !value.isFinite {
            throw SourceWorldWalkError.nonFinite("configuration \(name)")
        }
        guard configuration.noClipMovement.frameTime > 0 else {
            throw SourceWorldWalkError.invalidConfiguration("noClip frameTime")
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
            (
                "step trace distance",
                configuration.stepSize + SourceCollisionConstants.distanceEpsilon
            ),
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
            ("state viewOffset.x", state.viewOffset.x),
            ("state viewOffset.y", state.viewOffset.y),
            ("state viewOffset.z", state.viewOffset.z),
            ("state ladderNormal.x", state.ladderNormal.x),
            ("state ladderNormal.y", state.ladderNormal.y),
            ("state ladderNormal.z", state.ladderNormal.z),
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
        try requireFinite(
            state.ladderNormal,
            includingLengthSquared: true,
            field: "state ladderNormal"
        )
        if state.moveType == .ladder {
            guard abs(state.ladderNormal.lengthSquared - 1) <= Float(0.001) else {
                throw SourceWorldWalkError.inconsistentTrace("state ladder normal")
            }
        }
        let hull = playerHull(isDucked: state.isDucked)
        let centeredOrigin = move.origin + (hull.mins + hull.maxs) * Float(0.5)
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

    private func rejectUnsupportedState(_ state: SourceWorldWalkState) throws {
        guard state.moveType == .walk ||
            state.moveType == .ladder ||
            state.moveType == .noClip else {
            let feature: SourceWorldWalkUnsupportedFeature =
                state.moveType == .vPhysics ? .vPhysics : .nonWalkMoveType
            throw SourceWorldWalkError.unsupported(feature)
        }
        if state.movement.isDead {
            throw SourceWorldWalkError.unsupported(.deadPlayer)
        }
        if state.movement.waterJumpTime != 0 {
            throw SourceWorldWalkError.unsupported(.waterJump)
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
        var stepHeight: Float = 0

        mutating func absorb(_ other: Self) {
            bumpCount += other.bumpCount
            collisionCount += other.collisionCount
            didSnapToGround = didSnapToGround || other.didSnapToGround
            stepHeight += other.stepHeight
        }
    }

    private struct WaterEnvironment {
        let level: SourcePlayerWaterLevel
        let waterType: SourceContents
    }

    private struct PlayerHull {
        let mins: SourceVector3
        let maxs: SourceVector3
    }
}
