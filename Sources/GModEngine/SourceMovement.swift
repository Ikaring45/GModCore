import Foundation

public struct SourceQAngle: Equatable, Hashable, Sendable {
    public var pitch: Float
    public var yaw: Float
    public var roll: Float

    public init(pitch: Float = 0, yaw: Float = 0, roll: Float = 0) {
        self.pitch = pitch
        self.yaw = yaw
        self.roll = roll
    }

    public static let zero = SourceQAngle()
}

/// Source SDK `AngleVectors` basis in Source coordinates (+X forward, +Y
/// left, +Z up). Retaining all three axes avoids reconstructing an arbitrary
/// camera-up vector near vertical pitch, where a look-at implementation can
/// otherwise snap between unrelated fallback axes.
public struct SourceAngleBasis: Equatable, Hashable, Sendable {
    public let forward: SourceVector3
    public let right: SourceVector3
    public let up: SourceVector3

    public init(
        forward: SourceVector3,
        right: SourceVector3,
        up: SourceVector3
    ) {
        self.forward = forward
        self.right = right
        self.up = up
    }
}

public extension SourceQAngle {
    /// Matches Source SDK 2013 `AngleVectors` expression order and handedness.
    var sourceBasis: SourceAngleBasis {
        let degreesToRadians = Float.pi / 180
        let pitchRadians = pitch * degreesToRadians
        let yawRadians = yaw * degreesToRadians
        let rollRadians = roll * degreesToRadians
        let sinePitch = sin(pitchRadians)
        let cosinePitch = cos(pitchRadians)
        let sineYaw = sin(yawRadians)
        let cosineYaw = cos(yawRadians)
        let sineRoll = sin(rollRadians)
        let cosineRoll = cos(rollRadians)
        return SourceAngleBasis(
            forward: SourceVector3(
                cosinePitch * cosineYaw,
                cosinePitch * sineYaw,
                -sinePitch
            ),
            right: SourceVector3(
                -sineRoll * sinePitch * cosineYaw + cosineRoll * sineYaw,
                -sineRoll * sinePitch * sineYaw - cosineRoll * cosineYaw,
                -sineRoll * cosinePitch
            ),
            up: SourceVector3(
                cosineRoll * sinePitch * cosineYaw + sineRoll * sineYaw,
                cosineRoll * sinePitch * sineYaw - sineRoll * cosineYaw,
                cosineRoll * cosinePitch
            )
        )
    }
}

/// `IN_*` bits from Source SDK 2013 `in_buttons.h`.
public struct SourceInputButtons: OptionSet, Equatable, Hashable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let attack = SourceInputButtons(rawValue: 1 << 0)
    public static let jump = SourceInputButtons(rawValue: 1 << 1)
    public static let duck = SourceInputButtons(rawValue: 1 << 2)
    public static let forward = SourceInputButtons(rawValue: 1 << 3)
    public static let back = SourceInputButtons(rawValue: 1 << 4)
    public static let use = SourceInputButtons(rawValue: 1 << 5)
    public static let cancel = SourceInputButtons(rawValue: 1 << 6)
    public static let left = SourceInputButtons(rawValue: 1 << 7)
    public static let right = SourceInputButtons(rawValue: 1 << 8)
    public static let moveLeft = SourceInputButtons(rawValue: 1 << 9)
    public static let moveRight = SourceInputButtons(rawValue: 1 << 10)
    public static let attack2 = SourceInputButtons(rawValue: 1 << 11)
    public static let run = SourceInputButtons(rawValue: 1 << 12)
    public static let reload = SourceInputButtons(rawValue: 1 << 13)
    public static let alternate1 = SourceInputButtons(rawValue: 1 << 14)
    public static let alternate2 = SourceInputButtons(rawValue: 1 << 15)
    public static let score = SourceInputButtons(rawValue: 1 << 16)
    public static let speed = SourceInputButtons(rawValue: 1 << 17)
    public static let walk = SourceInputButtons(rawValue: 1 << 18)
    public static let zoom = SourceInputButtons(rawValue: 1 << 19)
    public static let weapon1 = SourceInputButtons(rawValue: 1 << 20)
    public static let weapon2 = SourceInputButtons(rawValue: 1 << 21)
    public static let bullRush = SourceInputButtons(rawValue: 1 << 22)
    public static let grenade1 = SourceInputButtons(rawValue: 1 << 23)
    public static let grenade2 = SourceInputButtons(rawValue: 1 << 24)
    public static let attack3 = SourceInputButtons(rawValue: 1 << 25)
}

public struct SourceEntityGroundContact: Equatable, Sendable {
    public var entityIndex: Int32
    public var minimumHeight: Float
    public var maximumHeight: Float

    public init(
        entityIndex: Int32,
        minimumHeight: Float,
        maximumHeight: Float
    ) {
        self.entityIndex = entityIndex
        self.minimumHeight = minimumHeight
        self.maximumHeight = maximumHeight
    }
}

/// Field-for-field gameplay payload of Source 1 `CUserCmd`.
public struct SourceUserCommand: Equatable, Sendable {
    public var commandNumber: Int32
    public var tickCount: Int32
    public var viewAngles: SourceQAngle
    public var forwardMove: Float
    public var sideMove: Float
    public var upMove: Float
    public var buttons: SourceInputButtons
    public var impulse: UInt8
    public var weaponSelect: Int32
    public var weaponSubtype: Int32
    public var randomSeed: Int32
    public var serverRandomSeed: Int32
    public var mouseDX: Int16
    public var mouseDY: Int16
    public var hasBeenPredicted: Bool
    public var entityGroundContacts: [SourceEntityGroundContact]

    public init(
        commandNumber: Int32 = 0,
        tickCount: Int32 = 0,
        viewAngles: SourceQAngle = .zero,
        forwardMove: Float = 0,
        sideMove: Float = 0,
        upMove: Float = 0,
        buttons: SourceInputButtons = [],
        impulse: UInt8 = 0,
        weaponSelect: Int32 = 0,
        weaponSubtype: Int32 = 0,
        randomSeed: Int32 = 0,
        serverRandomSeed: Int32 = 0,
        mouseDX: Int16 = 0,
        mouseDY: Int16 = 0,
        hasBeenPredicted: Bool = false,
        entityGroundContacts: [SourceEntityGroundContact] = []
    ) {
        self.commandNumber = commandNumber
        self.tickCount = tickCount
        self.viewAngles = viewAngles
        self.forwardMove = forwardMove
        self.sideMove = sideMove
        self.upMove = upMove
        self.buttons = buttons
        self.impulse = impulse
        self.weaponSelect = weaponSelect
        self.weaponSubtype = weaponSubtype
        self.randomSeed = randomSeed
        self.serverRandomSeed = serverRandomSeed
        self.mouseDX = mouseDX
        self.mouseDY = mouseDY
        self.hasBeenPredicted = hasBeenPredicted
        self.entityGroundContacts = entityGroundContacts
    }

    /// Source's `MakeInert` leaves command identity, weapon selection, random
    /// seeds, mouse deltas, and prediction bookkeeping intact.
    public mutating func makeInert() {
        viewAngles = .zero
        forwardMove = 0
        sideMove = 0
        upMove = 0
        buttons = []
        impulse = 0
    }
}

/// Numeric `MoveType_t` values from Source SDK 2013 `const.h`.
public enum SourceMoveType: UInt8, CaseIterable, Equatable, Sendable {
    case none = 0
    case isometric = 1
    case walk = 2
    case step = 3
    case fly = 4
    case flyGravity = 5
    case vPhysics = 6
    case push = 7
    case noClip = 8
    case ladder = 9
    case observer = 10
    case custom = 11
}

/// State consumed by the equation-compatible movement primitives below.
public struct SourceMoveData: Equatable, Sendable {
    public var origin: SourceVector3
    public var velocity: SourceVector3
    public var baseVelocity: SourceVector3
    public var outputWishVelocity: SourceVector3
    public var isOnGround: Bool
    public var entityGravity: Float
    public var surfaceFriction: Float
    public var waterJumpTime: Float
    public var isDead: Bool

    public init(
        origin: SourceVector3 = .zero,
        velocity: SourceVector3 = .zero,
        baseVelocity: SourceVector3 = .zero,
        outputWishVelocity: SourceVector3 = .zero,
        isOnGround: Bool = false,
        entityGravity: Float = 0,
        surfaceFriction: Float = 1,
        waterJumpTime: Float = 0,
        isDead: Bool = false
    ) {
        self.origin = origin
        self.velocity = velocity
        self.baseVelocity = baseVelocity
        self.outputWishVelocity = outputWishVelocity
        self.isOnGround = isOnGround
        self.entityGravity = entityGravity
        self.surfaceFriction = surfaceFriction
        self.waterJumpTime = waterJumpTime
        self.isDead = isDead
    }
}

public struct SourceMovementParameters: Equatable, Sendable {
    public var frameTime: Float
    public var gravity: Float
    public var maximumVelocity: Float
    public var friction: Float
    public var stopSpeed: Float
    public var acceleration: Float
    public var airAcceleration: Float
    public var airSpeedCap: Float

    public init(
        frameTime: Float = SourceGlobalVars.intervalPerTick,
        gravity: Float = 800,
        maximumVelocity: Float = 3500,
        friction: Float = 4,
        stopSpeed: Float = 100,
        acceleration: Float = 10,
        airAcceleration: Float = 10,
        airSpeedCap: Float = 30
    ) {
        self.frameTime = frameTime
        self.gravity = gravity
        self.maximumVelocity = maximumVelocity
        self.friction = friction
        self.stopSpeed = stopSpeed
        self.acceleration = acceleration
        self.airAcceleration = airAcceleration
        self.airSpeedCap = airSpeedCap
    }
}

public enum SourceMovementFeature: String, CaseIterable, Equatable, Sendable {
    case gravitySplit
    case friction
    case groundAcceleration
    case airAcceleration
    case stepMove
    case waterMove
    case vPhysics
}

public enum SourceMovementFeatureStatus: Equatable, Sendable {
    case equationCompatible
    case unimplemented
}

public enum SourceMovementError: Error, Equatable {
    case unimplemented(SourceMovementFeature)
}

/// Independently authored server/client movement compatibility math, with
/// operation order cross-checked against Source SDK 2013 `gamemovement.cpp`.
/// All intermediates remain `Float` where prediction determinism requires it.
public enum SourceGameMovement {
    public static func status(
        of feature: SourceMovementFeature
    ) -> SourceMovementFeatureStatus {
        switch feature {
        case .gravitySplit, .friction, .groundAcceleration, .airAcceleration:
            return .equationCompatible
        case .stepMove, .waterMove, .vPhysics:
            return .unimplemented
        }
    }

    public static func requireImplemented(_ feature: SourceMovementFeature) throws {
        guard status(of: feature) == .equationCompatible else {
            throw SourceMovementError.unimplemented(feature)
        }
    }

    /// `CGameMovement::StartGravity` including vertical base-velocity transfer.
    public static func startGravity(
        move: inout SourceMoveData,
        parameters: SourceMovementParameters
    ) {
        let entityGravity: Float = move.entityGravity != 0 ? move.entityGravity : 1
        move.velocity.z -= entityGravity * parameters.gravity * Float(0.5) * parameters.frameTime
        move.velocity.z += move.baseVelocity.z * parameters.frameTime
        move.baseVelocity.z = 0
        checkVelocity(move: &move, parameters: parameters)
    }

    /// `CGameMovement::FinishGravity`. Water-jump state suppresses this half.
    public static func finishGravity(
        move: inout SourceMoveData,
        parameters: SourceMovementParameters
    ) {
        guard move.waterJumpTime == 0 else { return }
        let entityGravity: Float = move.entityGravity != 0 ? move.entityGravity : 1
        move.velocity.z -= entityGravity * parameters.gravity * parameters.frameTime * Float(0.5)
        checkVelocity(move: &move, parameters: parameters)
    }

    /// `CGameMovement::CheckVelocity`. Source's `IS_NAN` bit test also catches
    /// infinities, so all non-finite origin/velocity components are reset.
    /// Velocity is then bounded independently per axis by `sv_maxvelocity`.
    public static func checkVelocity(
        move: inout SourceMoveData,
        parameters: SourceMovementParameters
    ) {
        for axis in 0 ..< 3 {
            if !move.velocity[axis].isFinite {
                move.velocity[axis] = 0
            }
            if !move.origin[axis].isFinite {
                move.origin[axis] = 0
            }

            if move.velocity[axis] > parameters.maximumVelocity {
                move.velocity[axis] = parameters.maximumVelocity
            } else if move.velocity[axis] < -parameters.maximumVelocity {
                move.velocity[axis] = -parameters.maximumVelocity
            }
        }
    }

    /// `CGameMovement::Friction`; Source computes speed from the full velocity
    /// vector and scales all components when grounded.
    public static func friction(
        move: inout SourceMoveData,
        parameters: SourceMovementParameters
    ) {
        guard move.waterJumpTime == 0 else { return }

        let speed = move.velocity.length
        guard speed >= Float(0.1) else { return }

        var drop: Float = 0
        if move.isOnGround {
            let friction = parameters.friction * move.surfaceFriction
            let control = speed < parameters.stopSpeed ? parameters.stopSpeed : speed
            drop += control * friction * parameters.frameTime
        }

        var newSpeed = speed - drop
        if newSpeed < 0 { newSpeed = 0 }

        if newSpeed != speed {
            newSpeed /= speed
            move.velocity *= newSpeed
        }

        move.outputWishVelocity -= (Float(1) - newSpeed) * move.velocity
    }

    /// `CGameMovement::Accelerate`. The caller supplies Source-normalized
    /// `wishDirection`, as the original function does not normalize it itself.
    public static func accelerate(
        move: inout SourceMoveData,
        wishDirection: SourceVector3,
        wishSpeed: Float,
        acceleration: Float? = nil,
        parameters: SourceMovementParameters
    ) {
        // Base CGameMovement::CanAccelerate rejects dead and water-jumping
        // players before evaluating the acceleration equation.
        guard !move.isDead, move.waterJumpTime == 0 else { return }

        let currentSpeed = move.velocity.dot(wishDirection)
        let addSpeed = wishSpeed - currentSpeed
        guard addSpeed > 0 else { return }

        let accelerationValue = acceleration ?? parameters.acceleration
        var accelerationSpeed = accelerationValue * parameters.frameTime * wishSpeed *
            move.surfaceFriction
        if accelerationSpeed > addSpeed { accelerationSpeed = addSpeed }

        move.velocity += wishDirection * accelerationSpeed
    }

    /// `CGameMovement::AirAccelerate`. The 30-unit wish-speed cap applies only
    /// to `addSpeed`; the acceleration term intentionally uses uncapped
    /// `wishSpeed`, preserving the well-known Source air-acceleration behavior.
    public static func airAccelerate(
        move: inout SourceMoveData,
        wishDirection: SourceVector3,
        wishSpeed: Float,
        acceleration: Float? = nil,
        parameters: SourceMovementParameters
    ) {
        guard !move.isDead, move.waterJumpTime == 0 else { return }

        var cappedWishSpeed = wishSpeed
        if cappedWishSpeed > parameters.airSpeedCap {
            cappedWishSpeed = parameters.airSpeedCap
        }

        let currentSpeed = move.velocity.dot(wishDirection)
        let addSpeed = cappedWishSpeed - currentSpeed
        guard addSpeed > 0 else { return }

        let accelerationValue = acceleration ?? parameters.airAcceleration
        var accelerationSpeed = accelerationValue * wishSpeed * parameters.frameTime *
            move.surfaceFriction
        if accelerationSpeed > addSpeed { accelerationSpeed = addSpeed }

        let addedVelocity = wishDirection * accelerationSpeed
        move.velocity += addedVelocity
        move.outputWishVelocity += addedVelocity
    }
}
