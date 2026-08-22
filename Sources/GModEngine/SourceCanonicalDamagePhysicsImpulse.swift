import Foundation

/// Typed outcome of routing one canonical damage impulse into VPhysics.
///
/// Ignored outcomes are deliberate Source entity/body decisions, not silent
/// success. In particular, a missing attested body is never replaced with a
/// guessed mass, inertia, shape, or fallback AABB.
public enum SourceCanonicalDamagePhysicsImpulseResult: Equatable, Sendable {
    case enqueued(SourcePhysicsBodyID)
    case ignoredEntityKind(
        identity: SourceCanonicalEntityIdentity,
        kind: SourceCanonicalEntityKind
    )
    case inactiveTarget(
        identity: SourceCanonicalEntityIdentity,
        lifecycle: SourceCanonicalEntityLifecycle
    )
    case ignoredNonVPhysicsProp(SourceCanonicalEntityIdentity)
    case noPhysicsBody(SourceCanonicalEntityIdentity)
    case ignoredNonDynamicBody(
        bodyID: SourcePhysicsBodyID,
        motionType: SourcePhysicsMotionType
    )
    case ignoredMotionDisabled(SourcePhysicsBodyID)
    case ignoredZeroImpulse(SourcePhysicsBodyID)
}

public enum SourceCanonicalDamagePhysicsImpulseError:
    Error,
    Equatable,
    Sendable,
    CustomStringConvertible
{
    case nonFiniteImpulse
    case nonFinitePosition
    case bodyIdentityMismatch(
        expected: SourceCanonicalEntityIdentity,
        received: SourceCanonicalEntityIdentity
    )

    public var description: String {
        switch self {
        case .nonFiniteImpulse:
            return "canonical damage impulse must be finite"
        case .nonFinitePosition:
            return "canonical damage position must be finite"
        case let .bodyIdentityMismatch(expected, received):
            return "canonical damage target EHANDLE \(expected.handle.rawValue) " +
                "resolved physics body EHANDLE \(received.handle.rawValue)"
        }
    }
}

/// Source SDK 2013's default HL2 ammo-force table and bullet force formula.
/// Values absent from that table fail closed instead of borrowing another
/// ammo type or deriving force from damage/target mass.
public enum SourceCanonicalBulletDamageForceError:
    Error,
    Equatable,
    Sendable,
    CustomStringConvertible
{
    case unavailableAmmoForce(String)
    case nonFiniteDirection
    case zeroDirection
    case invalidForceScale(Float)
    case invalidPhysicsPushScale(Float)
    case nonFiniteResult

    public var description: String {
        switch self {
        case let .unavailableAmmoForce(name):
            return "Source SDK damage force is unavailable for ammo type '\(name)'"
        case .nonFiniteDirection:
            return "bullet damage-force direction must be finite"
        case .zeroDirection:
            return "bullet damage-force direction must be nonzero"
        case let .invalidForceScale(value):
            return "bullet Force scale must be finite and nonnegative, got \(value)"
        case let .invalidPhysicsPushScale(value):
            return "phys_pushscale must be finite, got \(value)"
        case .nonFiniteResult:
            return "bullet damage-force impulse exceeds the Source Float range"
        }
    }
}

/// Reproduces `CalculateBulletDamageForce` without inventing ammo data.
public enum SourceCanonicalBulletDamageForce {
    public static func impulse(
        ammoTypeName: String,
        direction: SourceVector3,
        forceScale: Float,
        physicsPushScale: Float
    ) throws -> SourceVector3 {
        guard Self.isFinite(direction) else {
            throw SourceCanonicalBulletDamageForceError.nonFiniteDirection
        }
        let lengthSquared = direction.lengthSquared
        guard lengthSquared.isFinite else {
            throw SourceCanonicalBulletDamageForceError.nonFiniteDirection
        }
        guard lengthSquared > 0 else {
            throw SourceCanonicalBulletDamageForceError.zeroDirection
        }
        guard forceScale.isFinite, forceScale >= 0 else {
            throw SourceCanonicalBulletDamageForceError
                .invalidForceScale(forceScale)
        }
        guard physicsPushScale.isFinite else {
            throw SourceCanonicalBulletDamageForceError
                .invalidPhysicsPushScale(physicsPushScale)
        }

        // A zero scale has an exact zero result independent of the ammo
        // magnitude. This does not guess a missing catalog entry.
        guard forceScale != 0, physicsPushScale != 0 else { return .zero }
        let magnitude = try sourceSDKImpulseMagnitude(
            ammoTypeName: ammoTypeName
        )
        guard magnitude != 0 else { return .zero }
        let inverseLength = 1 / sqrt(lengthSquared)
        let result = direction * inverseLength * magnitude *
            physicsPushScale * forceScale
        guard isFinite(result), result.lengthSquared.isFinite else {
            throw SourceCanonicalBulletDamageForceError.nonFiniteResult
        }
        return result
    }

    private static func sourceSDKImpulseMagnitude(
        ammoTypeName: String
    ) throws -> Float {
        switch ammoTypeName.lowercased() {
        case "ar2", "alyxgun", "pistol", "smg1":
            return bulletImpulse(grains: 200, feetPerSecond: 1_225)
        case "357":
            return bulletImpulse(grains: 800, feetPerSecond: 5_000)
        case "xbowbolt":
            return bulletImpulse(grains: 800, feetPerSecond: 8_000)
        case "buckshot":
            return bulletImpulse(grains: 400, feetPerSecond: 1_200)
        case "sniperround":
            return bulletImpulse(grains: 650, feetPerSecond: 6_000)
        case "sniperpenetratedround":
            return bulletImpulse(grains: 150, feetPerSecond: 6_000)
        case "gaussenergy":
            return bulletImpulse(grains: 650, feetPerSecond: 8_000)
        case "combinecannon":
            return 1.5 * 750 * 12
        case "airboatgun":
            return bulletImpulse(grains: 10, feetPerSecond: 600)
        case "striderminigun", "striderminigundirect":
            return 1 * 750 * 12
        case "helicoptergun":
            return bulletImpulse(grains: 400, feetPerSecond: 1_225)
        case "combineheavycannon":
            return 10 * 750 * 12
        case "ar2altfire", "rpg_round", "smg1_grenade", "grenade",
             "thumper", "gravity", "battery":
            return 0
        default:
            throw SourceCanonicalBulletDamageForceError
                .unavailableAmmoForce(ammoTypeName)
        }
    }

    /// Exact macro order from HL2's `BULLET_IMPULSE` definition.
    private static func bulletImpulse(
        grains: Float,
        feetPerSecond: Float
    ) -> Float {
        let pounds = 0.002_285 * grains / 16
        let kilograms = pounds * (1 / 2.2)
        return feetPerSecond * 12 * kilograms * 3.5
    }

    private static func isFinite(_ vector: SourceVector3) -> Bool {
        vector.x.isFinite && vector.y.isFinite && vector.z.isFinite
    }
}

/// Queues exactly one VPhysics offset impulse for the next authoritative
/// physics step. The host re-resolves the complete body ID when enqueueing, so
/// removal, rollback, or an edict slot's next generation cannot redirect it.
public enum SourceCanonicalDamagePhysicsImpulse {
    @discardableResult
    public static func enqueue(
        target: SourceCanonicalEntitySnapshot,
        impulse: SourceVector3,
        worldPosition: SourceVector3,
        physicsHost: any SourceCanonicalPhysicsObjectLuaHost
    ) throws -> SourceCanonicalDamagePhysicsImpulseResult {
        guard isFinite(impulse) else {
            throw SourceCanonicalDamagePhysicsImpulseError.nonFiniteImpulse
        }
        guard isFinite(worldPosition) else {
            throw SourceCanonicalDamagePhysicsImpulseError.nonFinitePosition
        }
        guard target.kind == .propPhysics else {
            return .ignoredEntityKind(
                identity: target.identity,
                kind: target.kind
            )
        }
        guard target.lifecycle == .spawned || target.lifecycle == .active else {
            return .inactiveTarget(
                identity: target.identity,
                lifecycle: target.lifecycle
            )
        }
        guard target.solidType == .vPhysics,
              target.moveType == .vPhysics,
              !target.isNotSolid else {
            return .ignoredNonVPhysicsProp(target.identity)
        }
        guard let body = physicsHost.primaryCanonicalPhysicsObject(
            for: target.identity
        ) else {
            return .noPhysicsBody(target.identity)
        }
        guard body.bodyID.entityIdentity == target.identity else {
            throw SourceCanonicalDamagePhysicsImpulseError.bodyIdentityMismatch(
                expected: target.identity,
                received: body.bodyID.entityIdentity
            )
        }
        guard body.motionType == .dynamicBody else {
            return .ignoredNonDynamicBody(
                bodyID: body.bodyID,
                motionType: body.motionType
            )
        }
        guard body.isMotionEnabled else {
            return .ignoredMotionDisabled(body.bodyID)
        }
        guard impulse.lengthSquared > 0 else {
            return .ignoredZeroImpulse(body.bodyID)
        }
        let command = try SourcePhysicsBodyMutationCommand(
            bodyID: body.bodyID,
            mutation: .applyForceOffset(
                force: impulse,
                worldPosition: worldPosition
            )
        )
        try physicsHost.enqueueCanonicalPhysicsObjectMutation(command)
        return .enqueued(body.bodyID)
    }

    private static func isFinite(_ vector: SourceVector3) -> Bool {
        vector.x.isFinite && vector.y.isFinite && vector.z.isFinite
    }
}
