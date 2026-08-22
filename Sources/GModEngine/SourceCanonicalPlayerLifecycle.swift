import Foundation

/// The final health damage carried from `CTakeDamageInfo` into the
/// authoritative Player lifecycle. Attacker, inflictor, and Weapon remain
/// complete EHANDLEs; an absent handle is not replaced with world or self.
public struct SourceCanonicalPlayerDamageRequest: Equatable, Sendable {
    public let damage: Float
    public let force: SourceVector3
    public let position: SourceVector3
    public let attacker: SourceCanonicalEntityIdentity?
    public let inflictor: SourceCanonicalEntityIdentity?
    public let weapon: SourceCanonicalEntityIdentity?

    public init(
        damage: Float,
        force: SourceVector3 = .zero,
        position: SourceVector3 = .zero,
        attacker: SourceCanonicalEntityIdentity? = nil,
        inflictor: SourceCanonicalEntityIdentity? = nil,
        weapon: SourceCanonicalEntityIdentity? = nil
    ) {
        self.damage = damage
        self.force = force
        self.position = position
        self.attacker = attacker
        self.inflictor = inflictor
        self.weapon = weapon
    }
}

/// Host-authored state required by `Player:Spawn`. The lifecycle core never
/// invents a map spawn, standing view offset, health, or move type. It does
/// own the Source reset boundary: every linear/angular/base/current/wish
/// velocity and transient water/ladder/duck state is cleared atomically.
public struct SourceCanonicalPlayerRespawnRequest: Equatable, Sendable {
    public let transform: SourceEntityTransform
    public let viewOffset: SourceVector3
    public let moveType: SourceMoveType
    public let health: Int32
    public let armor: Int32
    public let observerState: SourceCanonicalPlayerObserverState

    public init(
        transform: SourceEntityTransform,
        viewOffset: SourceVector3,
        moveType: SourceMoveType,
        health: Int32,
        armor: Int32,
        observerState: SourceCanonicalPlayerObserverState
    ) {
        self.transform = transform
        self.viewOffset = viewOffset
        self.moveType = moveType
        self.health = health
        self.armor = armor
        self.observerState = observerState
    }
}

public enum SourceCanonicalPlayerLifeState: Equatable, Sendable {
    case alive
    case dead
}

public enum SourceCanonicalPlayerDamageDisposition: Equatable, Sendable {
    case applied
    case killed
    case ignoredAlreadyDead
    case ignoredNotDamageable
    case ignoredNonPositiveDamage
}

public struct SourceCanonicalPlayerLifecycleSideEffectFailure:
    Equatable,
    Sendable
{
    public enum Operation: String, Equatable, Sendable {
        case dropWeapon
    }

    public let operation: Operation
    public let message: String

    public init(operation: Operation, message: String) {
        self.operation = operation
        self.message = message
    }
}

public struct SourceCanonicalPlayerDamageReport: Equatable, Sendable {
    public let disposition: SourceCanonicalPlayerDamageDisposition
    public let before: SourceCanonicalEntitySnapshot
    /// The last immutable authoritative snapshot after contained side effects.
    /// It can differ from `before` even when a drop callback failed because
    /// Source damage/death has already committed by that boundary.
    public let after: SourceCanonicalEntitySnapshot
    public let droppedWeapon: SourceCanonicalEntityIdentity?
    public let sideEffectFailures:
        [SourceCanonicalPlayerLifecycleSideEffectFailure]

    public init(
        disposition: SourceCanonicalPlayerDamageDisposition,
        before: SourceCanonicalEntitySnapshot,
        after: SourceCanonicalEntitySnapshot,
        droppedWeapon: SourceCanonicalEntityIdentity? = nil,
        sideEffectFailures:
            [SourceCanonicalPlayerLifecycleSideEffectFailure] = []
    ) {
        self.disposition = disposition
        self.before = before
        self.after = after
        self.droppedWeapon = droppedWeapon
        self.sideEffectFailures = sideEffectFailures
    }
}

public struct SourceCanonicalPlayerSpawnReport: Equatable, Sendable {
    public let before: SourceCanonicalEntitySnapshot
    public let after: SourceCanonicalEntitySnapshot

    public init(
        before: SourceCanonicalEntitySnapshot,
        after: SourceCanonicalEntitySnapshot
    ) {
        self.before = before
        self.after = after
    }
}

public enum SourceCanonicalPlayerLifecycleError:
    Error,
    Equatable,
    Sendable,
    CustomStringConvertible
{
    case unavailableEntity(SourceCanonicalEntityIdentity)
    case playerRequired(SourceCanonicalEntityIdentity)
    case inconsistentHealthAndAlive(
        identity: SourceCanonicalEntityIdentity,
        health: Int32,
        isAlive: Bool
    )
    case nonFiniteDamage
    case invalidRespawnTransform
    case invalidRespawnViewOffset
    case nonPositiveRespawnHealth(Int32)
    case invalidRespawnArmor(Int32, maximum: Int32)
    case respawnStateUnavailable

    public var description: String {
        switch self {
        case let .unavailableEntity(identity):
            return "canonical Player EHANDLE \(identity.handle.rawValue) is unavailable"
        case let .playerRequired(identity):
            return "canonical Entity EHANDLE \(identity.handle.rawValue) is not a Player"
        case let .inconsistentHealthAndAlive(identity, health, isAlive):
            return "canonical Player EHANDLE \(identity.handle.rawValue) has health \(health) and isAlive \(isAlive)"
        case .nonFiniteDamage:
            return "CTakeDamageInfo damage must be finite"
        case .invalidRespawnTransform:
            return "canonical Player respawn transform must be finite"
        case .invalidRespawnViewOffset:
            return "canonical Player respawn view offset must be finite"
        case let .nonPositiveRespawnHealth(health):
            return "canonical Player respawn health must be positive, got \(health)"
        case let .invalidRespawnArmor(armor, maximum):
            return "canonical Player respawn armor \(armor) is outside 0...\(maximum)"
        case .respawnStateUnavailable:
            return "Player:Spawn requires a host-authored respawn state"
        }
    }
}

public typealias SourceCanonicalPlayerWeaponDrop = (
    _ player: SourceCanonicalEntityIdentity,
    _ weapon: SourceCanonicalEntityIdentity
) throws -> Void

public typealias SourceCanonicalPlayerRespawnResolver = (
    _ player: SourceCanonicalEntitySnapshot
) throws -> SourceCanonicalPlayerRespawnRequest

/// SERVER-authoritative Player damage/death/respawn state machine. It mutates
/// only the canonical Entity host, so the ordinary entity journal publishes
/// one full-EHANDLE immutable snapshot to CLIENT. Lua and render state never
/// become a second owner of health or life state.
public final class SourceCanonicalPlayerLifecycleController {
    private weak var host: (any SourceCanonicalEntityLuaHost)?
    private let dropWeapon: SourceCanonicalPlayerWeaponDrop?
    private let respawnResolver: SourceCanonicalPlayerRespawnResolver?

    public init(
        host: any SourceCanonicalEntityLuaHost,
        dropWeapon: SourceCanonicalPlayerWeaponDrop? = nil,
        respawnResolver: SourceCanonicalPlayerRespawnResolver? = nil
    ) {
        self.host = host
        self.dropWeapon = dropWeapon
        self.respawnResolver = respawnResolver
    }

    public static func lifeState(
        of player: SourceCanonicalEntitySnapshot
    ) throws -> SourceCanonicalPlayerLifeState {
        guard player.kind == .player else {
            throw SourceCanonicalPlayerLifecycleError.playerRequired(
                player.identity
            )
        }
        switch (player.combat.health > 0, player.motion.isAlive) {
        case (true, true): return .alive
        case (false, false): return .dead
        default:
            throw SourceCanonicalPlayerLifecycleError
                .inconsistentHealthAndAlive(
                    identity: player.identity,
                    health: player.combat.health,
                    isAlive: player.motion.isAlive
                )
        }
    }

    @discardableResult
    public func takeDamageInfo(
        _ request: SourceCanonicalPlayerDamageRequest,
        player identity: SourceCanonicalEntityIdentity
    ) throws -> SourceCanonicalPlayerDamageReport {
        guard request.damage.isFinite else {
            throw SourceCanonicalPlayerLifecycleError.nonFiniteDamage
        }
        let before = try requiredPlayer(identity)
        let lifeState = try Self.lifeState(of: before)
        guard lifeState == .alive else {
            return SourceCanonicalPlayerDamageReport(
                disposition: .ignoredAlreadyDead,
                before: before,
                after: before
            )
        }
        guard before.combat.takeDamageMode != 0 else {
            return SourceCanonicalPlayerDamageReport(
                disposition: .ignoredNotDamageable,
                before: before,
                after: before
            )
        }
        guard request.damage > 0 else {
            return SourceCanonicalPlayerDamageReport(
                disposition: .ignoredNonPositiveDamage,
                before: before,
                after: before
            )
        }

        let remaining = Double(before.combat.health) - Double(request.damage)
        let bounded = min(
            Double(Int32.max),
            max(Double(Int32.min), remaining)
        )
        let nextHealth = Int32(bounded.rounded(.towardZero))
        let killed = nextHealth <= 0
        let committed = try requiredHost().updateCanonicalEntity(identity) {
            state in
            state.combat.health = nextHealth
            state.motion.isAlive = !killed
        }
        guard killed else {
            return SourceCanonicalPlayerDamageReport(
                disposition: .applied,
                before: before,
                after: committed
            )
        }
        return runDeathSideEffects(before: before, committed: committed)
    }

    /// Implements the engine kill transition without fabricating attacker or
    /// inflictor identities. Repeated Kill calls are idempotent and do not
    /// invoke the death/drop boundary twice.
    @discardableResult
    public func kill(
        player identity: SourceCanonicalEntityIdentity
    ) throws -> SourceCanonicalPlayerDamageReport {
        let before = try requiredPlayer(identity)
        guard try Self.lifeState(of: before) == .alive else {
            return SourceCanonicalPlayerDamageReport(
                disposition: .ignoredAlreadyDead,
                before: before,
                after: before
            )
        }
        let committed = try requiredHost().updateCanonicalEntity(identity) {
            state in
            state.combat.health = 0
            state.motion.isAlive = false
        }
        return runDeathSideEffects(before: before, committed: committed)
    }

    @discardableResult
    public func spawn(
        player identity: SourceCanonicalEntityIdentity
    ) throws -> SourceCanonicalPlayerSpawnReport {
        let before = try requiredPlayer(identity)
        guard let respawnResolver else {
            throw SourceCanonicalPlayerLifecycleError
                .respawnStateUnavailable
        }
        return try spawn(
            player: identity,
            request: respawnResolver(before)
        )
    }

    @discardableResult
    public func spawn(
        player identity: SourceCanonicalEntityIdentity,
        request: SourceCanonicalPlayerRespawnRequest
    ) throws -> SourceCanonicalPlayerSpawnReport {
        let before = try requiredPlayer(identity)
        try validate(request, maximumArmor: before.combat
            .playerSpawnSettings?.maximumArmor)
        let after = try requiredHost().updateCanonicalEntity(identity) {
            state in
            state.transform = request.transform
            state.viewOffset = request.viewOffset
            state.moveType = request.moveType
            state.motion.linearVelocity = .zero
            state.motion.angularVelocity = .zero
            state.motion.baseVelocity = .zero
            state.motion.waterCurrentBaseVelocity = .zero
            state.motion.outputWishVelocity = .zero
            state.motion.isOnGround = false
            state.motion.waterJumpTime = 0
            state.motion.waterLevel = .notInWater
            state.motion.isDucked = false
            state.motion.ladderNormal = .zero
            state.motion.isAlive = true
            state.motion.playerObserverState = request.observerState
            state.combat.health = request.health
            guard var spawnSettings = state.combat.playerSpawnSettings else {
                throw SourceCanonicalPlayerLifecycleError
                    .playerRequired(identity)
            }
            spawnSettings.armor = request.armor
            state.combat.playerSpawnSettings = spawnSettings
        }
        return SourceCanonicalPlayerSpawnReport(before: before, after: after)
    }

    private func runDeathSideEffects(
        before: SourceCanonicalEntitySnapshot,
        committed: SourceCanonicalEntitySnapshot
    ) -> SourceCanonicalPlayerDamageReport {
        guard committed.combat.playerSpawnSettings?
            .shouldDropWeaponOnDeath == true,
              let weapon = committed.weaponInventory.activeWeapon else {
            return SourceCanonicalPlayerDamageReport(
                disposition: .killed,
                before: before,
                after: committed
            )
        }
        guard let dropWeapon else {
            return SourceCanonicalPlayerDamageReport(
                disposition: .killed,
                before: before,
                after: committed,
                sideEffectFailures: [.init(
                    operation: .dropWeapon,
                    message: "canonical Player weapon-drop host is unavailable"
                )]
            )
        }
        do {
            try dropWeapon(committed.identity, weapon)
            let final = host?.canonicalSnapshot(for: committed.identity) ??
                committed
            return SourceCanonicalPlayerDamageReport(
                disposition: .killed,
                before: before,
                after: final,
                droppedWeapon: weapon
            )
        } catch {
            return SourceCanonicalPlayerDamageReport(
                disposition: .killed,
                before: before,
                after: committed,
                sideEffectFailures: [.init(
                    operation: .dropWeapon,
                    message: String(describing: error)
                )]
            )
        }
    }

    private func requiredHost() throws -> any SourceCanonicalEntityLuaHost {
        guard let host else {
            throw SourceCanonicalPlayerLifecycleError
                .respawnStateUnavailable
        }
        return host
    }

    private func requiredPlayer(
        _ identity: SourceCanonicalEntityIdentity
    ) throws -> SourceCanonicalEntitySnapshot {
        guard let snapshot = host?.canonicalSnapshot(for: identity) else {
            throw SourceCanonicalPlayerLifecycleError
                .unavailableEntity(identity)
        }
        guard snapshot.kind == .player else {
            throw SourceCanonicalPlayerLifecycleError
                .playerRequired(identity)
        }
        return snapshot
    }

    private func validate(
        _ request: SourceCanonicalPlayerRespawnRequest,
        maximumArmor: Int32?
    ) throws {
        guard Self.isFinite(request.transform.origin),
              request.transform.angles.pitch.isFinite,
              request.transform.angles.yaw.isFinite,
              request.transform.angles.roll.isFinite else {
            throw SourceCanonicalPlayerLifecycleError
                .invalidRespawnTransform
        }
        guard Self.isFinite(request.viewOffset) else {
            throw SourceCanonicalPlayerLifecycleError
                .invalidRespawnViewOffset
        }
        guard request.health > 0 else {
            throw SourceCanonicalPlayerLifecycleError
                .nonPositiveRespawnHealth(request.health)
        }
        guard let maximumArmor,
              request.armor >= 0,
              request.armor <= maximumArmor else {
            throw SourceCanonicalPlayerLifecycleError.invalidRespawnArmor(
                request.armor,
                maximum: maximumArmor ?? 0
            )
        }
    }

    private static func isFinite(_ vector: SourceVector3) -> Bool {
        vector.x.isFinite && vector.y.isFinite && vector.z.isFinite
    }
}
