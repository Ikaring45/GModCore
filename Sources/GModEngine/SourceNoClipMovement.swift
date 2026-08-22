import Foundation

/// Source SDK 2013 movevars consumed by `CGameMovement::FullNoClipMove`.
/// Defaults are the replicated values declared by `movevars_shared.cpp`.
public struct SourceNoClipMovementParameters: Equatable, Sendable {
    public var frameTime: Float
    public var speedFactor: Float
    public var maximumAcceleration: Float
    public var maximumSpeed: Float
    public var friction: Float

    public init(
        frameTime: Float = SourceGlobalVars.intervalPerTick,
        speedFactor: Float = 5,
        maximumAcceleration: Float = 5,
        maximumSpeed: Float = 320,
        friction: Float = 4
    ) {
        self.frameTime = frameTime
        self.speedFactor = speedFactor
        self.maximumAcceleration = maximumAcceleration
        self.maximumSpeed = maximumSpeed
        self.friction = friction
    }
}

public extension SourceGameMovement {
    /// Equation-compatible `CGameMovement::FullNoClipMove`.
    ///
    /// This path deliberately performs no trace: `MOVETYPE_NOCLIP` advances
    /// the absolute origin after acceleration/friction and can pass through
    /// BSP or dynamic entities. Source computes the speed cap before the
    /// `IN_SPEED` half-factor, which is preserved here.
    static func fullNoClipMove(
        move: inout SourceMoveData,
        command: SourceUserCommand,
        parameters: SourceNoClipMovementParameters = SourceNoClipMovementParameters()
    ) {
        var factor = parameters.speedFactor
        let maximumWishSpeed = parameters.maximumSpeed * factor
        if command.buttons.contains(.speed) {
            factor /= 2
        }

        let basis = command.viewAngles.sourceBasis
        let forwardMove = command.forwardMove * factor
        let sideMove = command.sideMove * factor
        var wishVelocity = basis.forward * forwardMove + basis.right * sideMove
        wishVelocity.z += command.upMove * factor

        var wishDirection = wishVelocity
        var wishSpeed = wishDirection.length
        if wishSpeed > 0 {
            wishDirection = wishDirection / wishSpeed
        }
        if wishSpeed > maximumWishSpeed {
            wishVelocity *= maximumWishSpeed / wishSpeed
            wishSpeed = maximumWishSpeed
        }

        if parameters.maximumAcceleration > 0 {
            let movementParameters = SourceMovementParameters(
                frameTime: parameters.frameTime,
                friction: parameters.friction
            )
            accelerate(
                move: &move,
                wishDirection: wishDirection,
                wishSpeed: wishSpeed,
                acceleration: parameters.maximumAcceleration,
                parameters: movementParameters
            )

            let speed = move.velocity.length
            if speed < 1 {
                move.velocity = .zero
                return
            }

            let control = max(speed, maximumWishSpeed / 4)
            let drop = control * parameters.friction * move.surfaceFriction *
                parameters.frameTime
            let newSpeed = max(0, speed - drop) / speed
            move.velocity *= newSpeed
        } else {
            move.velocity = wishVelocity
        }

        move.origin += move.velocity * parameters.frameTime
        if parameters.maximumAcceleration < 0 {
            move.velocity = .zero
        }
    }
}
