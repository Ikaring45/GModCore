import Foundation
import GModLua

/// Host-normalized manipulation requested while the stock physgun is holding
/// an object. The values are already Source units/degrees: translating a mouse
/// wheel, `+use` movement, touch gesture, sensitivity ConVar, or snap setting
/// remains the input host's job rather than being guessed by the engine core.
public struct SourceCanonicalPhysgunManipulationInput: Equatable, Sendable {
    public let distanceDeltaSourceUnits: Float
    public let rotationDelta: SourceQAngle

    public init(
        distanceDeltaSourceUnits: Float = 0,
        rotationDelta: SourceQAngle = .zero
    ) {
        self.distanceDeltaSourceUnits = distanceDeltaSourceUnits
        self.rotationDelta = rotationDelta
    }

    public static let idle = SourceCanonicalPhysgunManipulationInput()

    var isFinite: Bool {
        distanceDeltaSourceUnits.isFinite &&
            rotationDelta.pitch.isFinite &&
            rotationDelta.yaw.isFinite &&
            rotationDelta.roll.isFinite
    }

    var changesDistance: Bool { distanceDeltaSourceUnits != 0 }

    var changesRotation: Bool {
        rotationDelta.pitch != 0 ||
            rotationDelta.yaw != 0 ||
            rotationDelta.roll != 0
    }
}

/// Read-only evidence for the exact body currently owned by a physgun hold.
/// All entity references retain their complete EHANDLE generations.
public struct SourceCanonicalPhysgunHeldSnapshot: Equatable, Sendable {
    public let player: SourceCanonicalEntityIdentity
    public let weapon: SourceCanonicalEntityIdentity
    public let entity: SourceCanonicalEntityIdentity
    public let bodyID: SourcePhysicsBodyID
    public let grabDistance: Float
    public let localGrabPoint: SourceVector3
    public let targetAngles: SourceQAngle

    public init(
        player: SourceCanonicalEntityIdentity,
        weapon: SourceCanonicalEntityIdentity,
        entity: SourceCanonicalEntityIdentity,
        bodyID: SourcePhysicsBodyID,
        grabDistance: Float,
        localGrabPoint: SourceVector3,
        targetAngles: SourceQAngle
    ) {
        self.player = player
        self.weapon = weapon
        self.entity = entity
        self.bodyID = bodyID
        self.grabDistance = grabDistance
        self.localGrabPoint = localGrabPoint
        self.targetAngles = targetAngles
    }
}

public enum SourceCanonicalPhysgunDisplayEventPhase:
    String,
    Equatable,
    Sendable
{
    case active
    case inactive
}

/// Immutable SERVER-to-CLIENT presentation state carried by the existing
/// gameplay-event FIFO. `localHitPosition` intentionally matches the stock
/// `GM:DrawPhysgunBeam` contract: it is relative to the selected PhysObj, not
/// an unversioned world-space point.
public struct SourceCanonicalPhysgunDisplayEvent: Equatable, Sendable {
    public let phase: SourceCanonicalPhysgunDisplayEventPhase
    public let player: SourceCanonicalEntityIdentity
    public let weapon: SourceCanonicalEntityIdentity
    public let entity: SourceCanonicalEntityIdentity
    public let bodyID: SourcePhysicsBodyID
    public let localHitPosition: SourceVector3

    public init(
        phase: SourceCanonicalPhysgunDisplayEventPhase,
        player: SourceCanonicalEntityIdentity,
        weapon: SourceCanonicalEntityIdentity,
        entity: SourceCanonicalEntityIdentity,
        bodyID: SourcePhysicsBodyID,
        localHitPosition: SourceVector3
    ) {
        self.phase = phase
        self.player = player
        self.weapon = weapon
        self.entity = entity
        self.bodyID = bodyID
        self.localHitPosition = localHitPosition
    }

    var isStructurallyValid: Bool {
        bodyID.entityIdentity == entity &&
            localHitPosition.x.isFinite &&
            localHitPosition.y.isFinite &&
            localHitPosition.z.isFinite
    }

    func matchesHold(of other: Self) -> Bool {
        player == other.player &&
            weapon == other.weapon &&
            entity == other.entity &&
            bodyID == other.bodyID
    }
}

public struct SourceCanonicalPhysgunClientDisplayItem: Equatable, Sendable {
    public let player: SourceCanonicalEntityIdentity
    public let weapon: SourceCanonicalEntityIdentity
    public let entity: SourceCanonicalEntityIdentity
    public let bodyID: SourcePhysicsBodyID
    public let localHitPosition: SourceVector3
    public let worldHitPosition: SourceVector3
    /// `false` means CLIENT Lua returned false from `DrawPhysgunBeam` and owns
    /// all effects for this item. `true` requests the engine default effects.
    public let drawsDefaultEffects: Bool
}

public enum SourceCanonicalPhysgunClientDisplayFailureStage:
    String,
    Equatable,
    Sendable
{
    case event
    case hook
}

public struct SourceCanonicalPhysgunClientDisplayFailure: Equatable, Sendable {
    public let player: SourceCanonicalEntityIdentity
    public let stage: SourceCanonicalPhysgunClientDisplayFailureStage
    public let message: String
}

public struct SourceCanonicalPhysgunClientDisplaySnapshot: Equatable, Sendable {
    public let transportSequence: UInt64?
    public let items: [SourceCanonicalPhysgunClientDisplayItem]
    public let failures: [SourceCanonicalPhysgunClientDisplayFailure]

    public init(
        transportSequence: UInt64? = nil,
        items: [SourceCanonicalPhysgunClientDisplayItem] = [],
        failures: [SourceCanonicalPhysgunClientDisplayFailure] = []
    ) {
        self.transportSequence = transportSequence
        self.items = items
        self.failures = failures
    }

    public static let empty = SourceCanonicalPhysgunClientDisplaySnapshot()
}

/// CLIENT-owned reducer for generation-bound physgun display events. Active
/// state is not shared with SERVER Lua. Each render projection re-resolves the
/// Player, Weapon, target, and body generation against canonical CLIENT
/// snapshots, so undo/removal and slot reuse fail closed.
public final class SourceCanonicalPhysgunClientDisplayState:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var activeByPlayer:
        [SourceCanonicalEntityIdentity: SourceCanonicalPhysgunDisplayEvent] = [:]
    private var lastTransportSequenceStorage: UInt64?

    public init() {}

    public var activeHolds: [SourceCanonicalPhysgunDisplayEvent] {
        lock.lock()
        defer { lock.unlock() }
        return activeByPlayer.values.sorted {
            $0.player.handle.rawValue < $1.player.handle.rawValue
        }
    }

    public var lastTransportSequence: UInt64? {
        lock.lock()
        defer { lock.unlock() }
        return lastTransportSequenceStorage
    }

    func receive(
        _ event: SourceCanonicalPhysgunDisplayEvent,
        transportSequence: UInt64
    ) {
        lock.lock()
        defer { lock.unlock() }
        if let lastTransportSequenceStorage,
           transportSequence <= lastTransportSequenceStorage {
            return
        }
        lastTransportSequenceStorage = transportSequence
        guard event.isStructurallyValid else { return }
        switch event.phase {
        case .active:
            activeByPlayer[event.player] = event
        case .inactive:
            guard let current = activeByPlayer[event.player],
                  event.matchesHold(of: current) else { return }
            activeByPlayer.removeValue(forKey: event.player)
        }
    }

    public func renderSnapshot(
        in runtime: GMLuaRuntime,
        canonicalEntities: [SourceCanonicalEntitySnapshot]
    ) -> SourceCanonicalPhysgunClientDisplaySnapshot {
        lock.lock()
        let events = activeByPlayer.values.sorted {
            $0.player.handle.rawValue < $1.player.handle.rawValue
        }
        let sequence = lastTransportSequenceStorage
        lock.unlock()

        let entities = Dictionary(
            uniqueKeysWithValues: canonicalEntities.map { ($0.identity, $0) }
        )
        var items: [SourceCanonicalPhysgunClientDisplayItem] = []
        var failures: [SourceCanonicalPhysgunClientDisplayFailure] = []
        for event in events {
            guard event.isStructurallyValid else {
                failures.append(.init(
                    player: event.player,
                    stage: .event,
                    message: "physgun display event is structurally invalid"
                ))
                continue
            }
            guard event.bodyID.solidIndex == 0 else {
                failures.append(.init(
                    player: event.player,
                    stage: .event,
                    message: "physgun CLIENT display requires a replicated " +
                        "PhysObj transform for solid index " +
                        String(event.bodyID.solidIndex)
                ))
                continue
            }
            guard let player = entities[event.player],
                  player.kind == .player,
                  player.lifecycle == .active,
                  let weapon = entities[event.weapon],
                  weapon.kind == .weapon,
                  weapon.className == SourceCanonicalPhysgunWeaponDefinition.className,
                  weapon.lifecycle == .spawned || weapon.lifecycle == .active,
                  player.weaponInventory.activeWeapon == weapon.identity,
                  let target = entities[event.entity],
                  target.kind == .propPhysics,
                  target.lifecycle == .spawned || target.lifecycle == .active else {
                // Lifecycle convergence is expected during stock undo/removal.
                // A recycled entry with a different serial never reaches here.
                continue
            }
            do {
                let drawsDefaultEffects = try Self.dispatchDrawHook(
                    runtime: runtime,
                    event: event
                )
                items.append(SourceCanonicalPhysgunClientDisplayItem(
                    player: player.identity,
                    weapon: weapon.identity,
                    entity: target.identity,
                    bodyID: event.bodyID,
                    localHitPosition: event.localHitPosition,
                    worldHitPosition: target.transform.transformPointFromLocal(
                        event.localHitPosition
                    ),
                    drawsDefaultEffects: drawsDefaultEffects
                ))
            } catch {
                failures.append(SourceCanonicalPhysgunClientDisplayFailure(
                    player: event.player,
                    stage: .hook,
                    message: GMLuaRuntime.describe(error)
                ))
            }
        }
        return SourceCanonicalPhysgunClientDisplaySnapshot(
            transportSequence: sequence,
            items: items,
            failures: failures
        )
    }

    private static func dispatchDrawHook(
        runtime: GMLuaRuntime,
        event: SourceCanonicalPhysgunDisplayEvent
    ) throws -> Bool {
        guard runtime.realm == .client,
              let registry = runtime.entityRegistry,
              let typeSystem = runtime.typeSystem else {
            throw LuaError.runtime(
                "DrawPhysgunBeam requires the live CLIENT entity/type system"
            )
        }
        let playerValue = registry.player(at: event.player.entryIndex)
        let weaponValue = registry.entity(at: event.weapon.entryIndex)
        let entityValue = registry.entity(at: event.entity.entryIndex)
        guard registry.canonicalIdentity(for: playerValue) == event.player,
              registry.canonicalIdentity(for: weaponValue) == event.weapon,
              registry.canonicalIdentity(for: entityValue) == event.entity else {
            throw LuaError.runtime(
                "DrawPhysgunBeam rejected a stale CLIENT EHANDLE"
            )
        }
        guard case let .table(hook) = runtime.state.getGlobal("hook") else {
            throw LuaError.runtime("DrawPhysgunBeam requires hook table")
        }
        let call = try runtime.state.rawTableValue(
            for: .string("Call"),
            in: hook
        )
        switch call {
        case .luaFunction, .nativeFunction:
            break
        default:
            throw LuaError.runtime(
                "hook.Call is \(call.typeName), expected function"
            )
        }
        let gamemode = runtime.state.getGlobal("GAMEMODE")
        guard case .table = gamemode else {
            throw LuaError.runtime(
                "GAMEMODE is \(gamemode.typeName), expected table"
            )
        }
        let localHitPosition = try GMLuaVectorAngle.makeNetworkVector(
            Double(event.localHitPosition.x),
            Double(event.localHitPosition.y),
            Double(event.localHitPosition.z),
            typeSystem: typeSystem
        )
        let result = try runtime.state.call(
            call,
            arguments: [
                .string("DrawPhysgunBeam"),
                gamemode,
                playerValue,
                weaponValue,
                .boolean(true),
                entityValue,
                .number(Double(event.bodyID.solidIndex)),
                localHitPosition,
            ]
        ).first ?? .nilValue
        if case .boolean(false) = result { return false }
        return true
    }
}
