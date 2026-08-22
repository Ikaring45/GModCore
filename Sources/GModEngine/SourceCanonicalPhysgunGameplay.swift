import Foundation
import GModLua

/// Engine definition for Garry's Mod's native physgun. The definition exists
/// in the ordinary `weapons` registry so original Sandbox `Player:Give` and
/// selector Lua resolve the same class as any scripted weapon. Its actual
/// fixed-tick behavior remains engine-owned below; inherited weapon_base fire
/// callbacks are deliberately shadowed rather than firing pistol bullets.
public enum SourceCanonicalPhysgunWeaponDefinition {
    public static let className = "weapon_physgun"

    @discardableResult
    public static func install(
        into runtime: GMLuaRuntime,
        host: (any SourceCanonicalEntityLuaHost)? = nil
    ) throws -> Bool {
        guard runtime.realm == .server || runtime.realm == .client else {
            throw LuaError.runtime("weapon_physgun requires SERVER or CLIENT")
        }
        if runtime.realm == .server {
            try installPhysObjIsMoveableAlias(into: runtime)
        }
        guard case let .table(weapons) = runtime.state.getGlobal("weapons") else {
            throw LuaError.runtime("weapon_physgun requires the weapons library")
        }
        let getStored = try callable(
            named: "GetStored",
            in: weapons,
            runtime: runtime
        )
        let existing = try runtime.state.call(
            getStored,
            arguments: [.string(LuaString(className))]
        ).first ?? .nilValue
        if case .nilValue = existing {
            // Continue with native registration.
        } else {
            return false
        }

        let definition = LuaTable()
        let primary = LuaTable()
        let secondary = LuaTable()
        try set(.string("weapon_base"), named: "Base", in: definition, runtime: runtime)
        try set(.string("#GMOD_Physgun"), named: "PrintName", in: definition, runtime: runtime)
        try set(
            .string("weapons/weapon_physgun"),
            named: "Folder",
            in: definition,
            runtime: runtime
        )
        try set(.table(primary), named: "Primary", in: definition, runtime: runtime)
        try set(.table(secondary), named: "Secondary", in: definition, runtime: runtime)
        for table in [primary, secondary] {
            try set(.number(-1), named: "ClipSize", in: table, runtime: runtime)
            try set(.number(-1), named: "DefaultClip", in: table, runtime: runtime)
            try set(.string("none"), named: "Ammo", in: table, runtime: runtime)
        }
        try set(.boolean(true), named: "Automatic", in: primary, runtime: runtime)
        try set(.boolean(false), named: "Automatic", in: secondary, runtime: runtime)

        let hostBox = SourceCanonicalPhysgunWeakEntityHost(host)
        let registryBox = SourceCanonicalPhysgunWeakRegistry(runtime.entityRegistry)
        let initialize = LuaNativeFunctionBox(
            { arguments in
                guard let value = arguments.first,
                      let registry = registryBox.value,
                      let snapshot = registry.canonicalSnapshot(for: value),
                      snapshot.kind == .weapon,
                      snapshot.className == className else {
                    throw LuaError.runtime(
                        "weapon_physgun.Initialize requires its canonical Weapon"
                    )
                }
                if let host = hostBox.value {
                    _ = try host.updateCanonicalEntity(snapshot.identity) { candidate in
                        candidate.weaponHoldType = "physgun"
                    }
                }
                return []
            },
            debugName: "weapon_physgun.Initialize"
        )
        try set(
            .nativeFunction(initialize),
            named: "Initialize",
            in: definition,
            runtime: runtime
        )
        for method in ["PrimaryAttack", "SecondaryAttack", "Reload"] {
            let noOp = LuaNativeFunctionBox(
                { _ in [] },
                debugName: "weapon_physgun.\(method)"
            )
            try set(
                .nativeFunction(noOp),
                named: method,
                in: definition,
                runtime: runtime
            )
        }

        let register = try callable(named: "Register", in: weapons, runtime: runtime)
        _ = try runtime.state.call(
            register,
            arguments: [
                .table(definition),
                .string(LuaString(className)),
            ]
        )
        return true
    }

    /// The stock base gamemode's `OnPhysgunFreeze` uses the historical
    /// `PhysObj:IsMoveable` spelling. Source exposes the same motion-enabled
    /// state through both names; reuse the canonical full-body validated
    /// `IsMotionEnabled` implementation instead of introducing a second host
    /// query or a guessed result.
    private static func installPhysObjIsMoveableAlias(
        into runtime: GMLuaRuntime
    ) throws {
        guard let metatable = runtime.typeSystem?.metatable(named: "PhysObj") else {
            throw LuaError.runtime("weapon_physgun requires the PhysObj metatable")
        }
        let key = LuaValue.string("IsMoveable")
        let existing = try runtime.state.rawTableValue(for: key, in: metatable)
        switch existing {
        case .luaFunction, .nativeFunction:
            return
        case .nilValue:
            break
        default:
            throw LuaError.runtime(
                "PhysObj:IsMoveable is \(existing.typeName), expected function or nil"
            )
        }
        let motionEnabled = try runtime.state.rawTableValue(
            for: .string("IsMotionEnabled"),
            in: metatable
        )
        switch motionEnabled {
        case .luaFunction, .nativeFunction:
            try runtime.state.setRawTableValue(
                motionEnabled,
                for: key,
                in: metatable
            )
        default:
            throw LuaError.runtime(
                "PhysObj:IsMotionEnabled is \(motionEnabled.typeName), expected function"
            )
        }
    }

    private static func callable(
        named name: String,
        in table: LuaTable,
        runtime: GMLuaRuntime
    ) throws -> LuaValue {
        let value = try runtime.state.rawTableValue(
            for: .string(LuaString(name)),
            in: table
        )
        switch value {
        case .luaFunction, .nativeFunction:
            return value
        default:
            throw LuaError.runtime(
                "weapons.\(name) is \(value.typeName), expected function"
            )
        }
    }

    private static func set(
        _ value: LuaValue,
        named name: String,
        in table: LuaTable,
        runtime: GMLuaRuntime
    ) throws {
        try runtime.state.setRawTableValue(
            value,
            for: .string(LuaString(name)),
            in: table
        )
    }
}

public protocol SourceCanonicalPhysgunHost:
    SourceCanonicalEntityLuaHost,
    SourceCanonicalPhysicsObjectLuaHost
{}

extension GMLuaSourceRuntimeAdapter: SourceCanonicalPhysgunHost {}

public enum SourceCanonicalPhysgunEventKind: String, Equatable, Sendable {
    case pickup
    case move
    case freeze
    case freezeIntercepted
    case unfreeze
    case unfreezeRejected
    case drop
    case rejected
    case staleHoldCleared
}

public struct SourceCanonicalPhysgunEvent: Equatable, Sendable {
    public let kind: SourceCanonicalPhysgunEventKind
    public let player: SourceCanonicalEntityIdentity
    public let weapon: SourceCanonicalEntityIdentity
    public let entity: SourceCanonicalEntityIdentity
    public let bodyID: SourcePhysicsBodyID

    public init(
        kind: SourceCanonicalPhysgunEventKind,
        player: SourceCanonicalEntityIdentity,
        weapon: SourceCanonicalEntityIdentity,
        entity: SourceCanonicalEntityIdentity,
        bodyID: SourcePhysicsBodyID
    ) {
        self.kind = kind
        self.player = player
        self.weapon = weapon
        self.entity = entity
        self.bodyID = bodyID
    }
}

public enum SourceCanonicalPhysgunFailureStage: String, Equatable, Sendable {
    case trace
    case permission
    case pickupHook
    case freezeHook
    case reloadHook
    case unfreezeTrace
    case unfreezePermission
    case unfreezeMotion
    case unfreezeHook
    case motion
    case presentation
    case dropHook
}

public struct SourceCanonicalPhysgunFailure: Equatable, Sendable {
    public let stage: SourceCanonicalPhysgunFailureStage
    public let message: String

    public init(stage: SourceCanonicalPhysgunFailureStage, message: String) {
        self.stage = stage
        self.message = message
    }
}

public struct SourceCanonicalPhysgunTickReport: Equatable, Sendable {
    public let events: [SourceCanonicalPhysgunEvent]
    public let failures: [SourceCanonicalPhysgunFailure]

    public init(
        events: [SourceCanonicalPhysgunEvent] = [],
        failures: [SourceCanonicalPhysgunFailure] = []
    ) {
        self.events = events
        self.failures = failures
    }

    public static let idle = SourceCanonicalPhysgunTickReport()
}

/// Renderer-neutral CLIENT view of the local physgun. The enabled form is
/// produced only after resolving the replicated Player, Weapon, target and
/// complete target EHANDLE inside the CLIENT registry. A pending removal,
/// missing target, or serial mismatch therefore becomes a disabled frame
/// before the SERVER controller clears its private bookkeeping next tick.
public struct SourceCanonicalPhysgunClientPresentation:
    Equatable,
    Sendable
{
    public let player: SourceCanonicalEntityIdentity
    public let weapon: SourceCanonicalEntityIdentity
    public let enabled: Bool
    public let target: SourceCanonicalEntityIdentity?
    public let bodyID: SourcePhysicsBodyID?
    public let localGrabPoint: SourceVector3
    public let grabDistance: Float
    public let targetAngles: SourceQAngle
    public let sourceWeaponRevision: UInt64
    public let sourceTargetRevision: UInt64?

    public init(
        player: SourceCanonicalEntityIdentity,
        weapon: SourceCanonicalEntityIdentity,
        enabled: Bool,
        target: SourceCanonicalEntityIdentity?,
        bodyID: SourcePhysicsBodyID?,
        localGrabPoint: SourceVector3,
        grabDistance: Float,
        targetAngles: SourceQAngle,
        sourceWeaponRevision: UInt64,
        sourceTargetRevision: UInt64?
    ) {
        self.player = player
        self.weapon = weapon
        self.enabled = enabled
        self.target = target
        self.bodyID = bodyID
        self.localGrabPoint = localGrabPoint
        self.grabDistance = grabDistance
        self.targetAngles = targetAngles
        self.sourceWeaponRevision = sourceWeaponRevision
        self.sourceTargetRevision = sourceTargetRevision
    }
}

public struct SourceCanonicalPhysgunClientFrameReport: Equatable, Sendable {
    public let presentation: SourceCanonicalPhysgunClientPresentation
    /// `false` is the documented `GM:DrawPhysgunBeam` interception result.
    /// The host renderer may draw native effects only while this remains true.
    public let drawsDefaultEffects: Bool

    public init(
        presentation: SourceCanonicalPhysgunClientPresentation,
        drawsDefaultEffects: Bool
    ) {
        self.presentation = presentation
        self.drawsDefaultEffects = drawsDefaultEffects
    }
}

/// CLIENT-only presentation boundary for native physgun effects and the
/// documented `GM:DrawPhysgunBeam` hook. It reads no SERVER host or mutable
/// gameplay controller state.
public final class SourceCanonicalPhysgunClientPresentationController {
    private let runtime: GMLuaRuntime

    public init(runtime: GMLuaRuntime) {
        precondition(runtime.realm == .client)
        self.runtime = runtime
    }

    public func currentPresentation()
        -> SourceCanonicalPhysgunClientPresentation?
    {
        guard let registry = runtime.entityRegistry else { return nil }
        let playerValue = registry.localPlayer()
        guard let player = registry.canonicalSnapshot(for: playerValue),
              player.kind == .player,
              player.lifecycle == .spawned || player.lifecycle == .active,
              let weaponIdentity = player.weaponInventory.activeWeapon,
              let weapon = registry.canonicalSnapshot(
                  at: weaponIdentity.entryIndex
              ),
              weapon.identity == weaponIdentity,
              weapon.kind == .weapon,
              weapon.className ==
                SourceCanonicalPhysgunWeaponDefinition.className,
              weapon.lifecycle == .spawned || weapon.lifecycle == .active
        else { return nil }

        let hold = weapon.weaponRuntime.physgunHold
        guard hold.isActive,
              let targetIdentity = hold.target,
              let bodyID = hold.bodyID,
              bodyID.entityIdentity == targetIdentity,
              let target = registry.canonicalSnapshot(
                  at: targetIdentity.entryIndex
              ),
              target.identity == targetIdentity,
              target.kind == .propPhysics,
              target.lifecycle == .spawned || target.lifecycle == .active
        else {
            return SourceCanonicalPhysgunClientPresentation(
                player: player.identity,
                weapon: weapon.identity,
                enabled: false,
                target: nil,
                bodyID: nil,
                localGrabPoint: .zero,
                grabDistance: 0,
                targetAngles: .zero,
                sourceWeaponRevision: weapon.revision,
                sourceTargetRevision: nil
            )
        }
        return SourceCanonicalPhysgunClientPresentation(
            player: player.identity,
            weapon: weapon.identity,
            enabled: true,
            target: target.identity,
            bodyID: bodyID,
            localGrabPoint: hold.localGrabPoint,
            grabDistance: hold.grabDistance,
            targetAngles: hold.targetAngles,
            sourceWeaponRevision: weapon.revision,
            sourceTargetRevision: target.revision
        )
    }

    public func runClientFrame() throws
        -> SourceCanonicalPhysgunClientFrameReport?
    {
        guard let presentation = currentPresentation(),
              let registry = runtime.entityRegistry else { return nil }
        let playerValue = registry.player(at: presentation.player.entryIndex)
        let weaponValue = registry.entity(at: presentation.weapon.entryIndex)
        guard registry.canonicalIdentity(for: playerValue) ==
                presentation.player,
              registry.canonicalIdentity(for: weaponValue) ==
                presentation.weapon else { return nil }
        let targetValue: LuaValue
        let physicsBone: Int
        let hitPosition: SourceVector3
        if presentation.enabled,
           let target = presentation.target,
           let bodyID = presentation.bodyID {
            let resolved = registry.entity(at: target.entryIndex)
            guard registry.canonicalIdentity(for: resolved) == target else {
                return nil
            }
            targetValue = resolved
            physicsBone = bodyID.solidIndex
            hitPosition = presentation.localGrabPoint
        } else {
            targetValue = registry.entity(at: -1)
            physicsBone = 0
            hitPosition = .zero
        }

        guard case let .table(hookLibrary) = runtime.state.getGlobal("hook")
        else {
            throw LuaError.runtime(
                "weapon_physgun CLIENT presentation requires hook table"
            )
        }
        let call = try runtime.state.rawTableValue(
            for: .string("Call"),
            in: hookLibrary
        )
        switch call {
        case .luaFunction, .nativeFunction:
            break
        default:
            throw LuaError.runtime(
                "hook.Call is \(call.typeName), expected function"
            )
        }
        let result = try runtime.state.call(
            call,
            arguments: [
                .string("DrawPhysgunBeam"),
                runtime.state.getGlobal("GAMEMODE"),
                playerValue,
                weaponValue,
                .boolean(presentation.enabled),
                targetValue,
                .number(Double(physicsBone)),
                try vector(hitPosition),
            ]
        ).first ?? .nilValue
        let drawsDefaultEffects: Bool
        if case let .boolean(value) = result, value == false {
            drawsDefaultEffects = false
        } else {
            drawsDefaultEffects = true
        }
        return SourceCanonicalPhysgunClientFrameReport(
            presentation: presentation,
            drawsDefaultEffects: drawsDefaultEffects
        )
    }

    private func vector(_ value: SourceVector3) throws -> LuaValue {
        let constructor = runtime.state.getGlobal("Vector")
        switch constructor {
        case .luaFunction, .nativeFunction:
            break
        default:
            throw LuaError.runtime(
                "Vector is \(constructor.typeName), expected function"
            )
        }
        return try runtime.state.call(
            constructor,
            arguments: [
                .number(Double(value.x)),
                .number(Double(value.y)),
                .number(Double(value.z)),
            ]
        ).first ?? .nilValue
    }
}

private final class SourceCanonicalPhysgunWeakEntityHost: @unchecked Sendable {
    weak var value: (any SourceCanonicalEntityLuaHost)?

    init(_ value: (any SourceCanonicalEntityLuaHost)?) {
        self.value = value
    }
}

private final class SourceCanonicalPhysgunWeakRegistry: @unchecked Sendable {
    weak var value: GMLuaEntityRegistry?

    init(_ value: GMLuaEntityRegistry?) {
        self.value = value
    }
}

/// First native physgun vertical slice. The held record carries complete
/// Player, Weapon, Entity, and physics-body identities. Every tick re-resolves
/// all four before queuing motion, so deferred removal or slot reuse clears the
/// hold instead of mutating a replacement body.
public final class SourceCanonicalPhysgunGameplayController {
    /// Source SDK `CGrabController::AttachEntity` configures shadow control at
    /// 1000 Source units/second and 360 degrees * 10/second respectively.
    public static let maximumLinearSpeed: Float = 1_000
    public static let maximumAngularSpeed: Float = 3_600
    /// Source's generic MAX_TRACE_LENGTH: diagonal of the +/-16384 world box.
    public static let maximumTraceLength: Float = 56_755.84
    /// Defaults attested by the bundled Sandbox utilities menu. Live ConVar
    /// replication is outside this controller; these values keep the native
    /// command path deterministic until that shared user-info surface exists.
    public static let distanceStep: Float = 10
    public static let rotationSensitivity: Float = 0.05
    public static let snapAngle: Float = 45
    public static let maximumGrabDistance: Float = 4_096
    public static let minimumGrabDistance: Float = 0

    private struct HeldBody {
        let player: SourceCanonicalEntityIdentity
        let weapon: SourceCanonicalEntityIdentity
        let entity: SourceCanonicalEntityIdentity
        let bodyID: SourcePhysicsBodyID
        var grabDistance: Float
        let localGrabPoint: SourceVector3
        var targetAngles: SourceQAngle
    }

    private struct TraceHit {
        let entity: SourceCanonicalEntitySnapshot
        let body: SourceCanonicalPhysicsObjectSnapshot
        let hitPosition: SourceVector3
    }

    private struct TargetedUnfreezeResult {
        let count: Int
        let events: [SourceCanonicalPhysgunEvent]
        let failures: [SourceCanonicalPhysgunFailure]

        static let none = TargetedUnfreezeResult(
            count: 0,
            events: [],
            failures: []
        )
    }

    private let runtime: GMLuaRuntime
    private weak var host: (any SourceCanonicalPhysgunHost)?
    private var heldByPlayer: [SourceCanonicalEntityIdentity: HeldBody] = [:]
    private var pendingPresentationClearByPlayer:
        [SourceCanonicalEntityIdentity: HeldBody] = [:]
    private var pendingUnfreezeResults:
        [SourceCanonicalEntityIdentity: [TargetedUnfreezeResult]] = [:]
    private var targetedPhysgunUnfreezeBridgeInstalled = false
    private lazy var targetedPhysgunUnfreezeFunction = LuaNativeFunctionBox(
        { [weak self] arguments in
            guard let self else {
                throw LuaError.runtime(
                    "Player:PhysgunUnfreeze controller is unavailable"
                )
            }
            guard let playerValue = arguments.first,
                  let registry = self.runtime.entityRegistry,
                  let playerIdentity = registry.canonicalIdentity(for: playerValue),
                  self.host?.canonicalSnapshot(for: playerIdentity)?.kind == .player else {
                throw LuaError.runtime(
                    "bad self to 'Player:PhysgunUnfreeze' (live Player expected)"
                )
            }
            let result = self.performTargetedUnfreeze(
                playerIdentity: playerIdentity,
                playerValue: playerValue
            )
            self.pendingUnfreezeResults[playerIdentity, default: []].append(result)
            return [.number(Double(result.count))]
        },
        debugName: "Player:PhysgunUnfreeze"
    )

    public init(runtime: GMLuaRuntime, host: any SourceCanonicalPhysgunHost) {
        precondition(runtime.realm == .server)
        self.runtime = runtime
        self.host = host
    }

    public func heldEntity(
        for player: SourceCanonicalEntityIdentity
    ) -> SourceCanonicalEntityIdentity? {
        heldByPlayer[player]?.entity
    }

    public func runServerTick(
        playerIdentity: SourceCanonicalEntityIdentity,
        command: SourceUserCommand
    ) -> SourceCanonicalPhysgunTickReport {
        var failures: [SourceCanonicalPhysgunFailure] = []
        guard let host else {
            if let held = heldByPlayer.removeValue(forKey: playerIdentity) {
                pendingPresentationClearByPlayer[playerIdentity] = held
            }
            return .idle
        }
        retryPendingPresentationClear(
            for: playerIdentity,
            host: host,
            failures: &failures
        )
        guard let registry = runtime.entityRegistry,
              let player = host.canonicalSnapshot(for: playerIdentity),
              player.kind == .player,
              player.lifecycle == .active else {
            if let held = heldByPlayer.removeValue(forKey: playerIdentity) {
                requestPresentationClear(
                    for: held,
                    host: host,
                    failures: &failures
                )
            }
            return SourceCanonicalPhysgunTickReport(failures: failures)
        }
        let playerValue = registry.player(at: player.identity.entryIndex)
        guard registry.canonicalIdentity(for: playerValue) == player.identity else {
            if let held = heldByPlayer.removeValue(forKey: playerIdentity) {
                requestPresentationClear(
                    for: held,
                    host: host,
                    failures: &failures
                )
            }
            return SourceCanonicalPhysgunTickReport(failures: failures)
        }
        let buttons = registry.playerInputButtonState(for: playerValue) ?? (
            current: SourceInputButtons(),
            previous: SourceInputButtons()
        )

        var events: [SourceCanonicalPhysgunEvent] = []
        let activeWeapon = player.weaponInventory.activeWeapon.flatMap {
            host.canonicalSnapshot(for: $0)
        }

        if let activeWeapon,
           activeWeapon.kind == .weapon,
           activeWeapon.className == SourceCanonicalPhysgunWeaponDefinition.className,
           buttons.current.contains(.reload),
           !buttons.previous.contains(.reload) {
            let report = runReloadHook(
                player: player,
                playerValue: playerValue,
                weapon: activeWeapon,
                registry: registry
            )
            events.append(contentsOf: report.events)
            failures.append(contentsOf: report.failures)
        }

        if var held = heldByPlayer[player.identity] {
            guard let activeWeapon,
                  activeWeapon.identity == held.weapon,
                  activeWeapon.className == SourceCanonicalPhysgunWeaponDefinition.className,
                  buttons.current.contains(.attack) else {
                heldByPlayer.removeValue(forKey: player.identity)
                requestPresentationClear(
                    for: held,
                    host: host,
                    failures: &failures
                )
                if let entity = host.canonicalSnapshot(for: held.entity),
                   entity.lifecycle == .spawned || entity.lifecycle == .active {
                    dispatchDropHook(
                        playerValue: playerValue,
                        held: held,
                        registry: registry,
                        failures: &failures
                    )
                    events.append(event(.drop, held: held))
                } else {
                    events.append(event(.staleHoldCleared, held: held))
                }
                return SourceCanonicalPhysgunTickReport(
                    events: events,
                    failures: failures
                )
            }
            guard let entity = host.canonicalSnapshot(for: held.entity),
                  entity.kind == .propPhysics,
                  entity.lifecycle == .spawned || entity.lifecycle == .active,
                  let body = host.canonicalPhysicsObject(for: held.bodyID),
                  body.bodyID.entityIdentity == held.entity else {
                heldByPlayer.removeValue(forKey: player.identity)
                requestPresentationClear(
                    for: held,
                    host: host,
                    failures: &failures
                )
                events.append(event(.staleHoldCleared, held: held))
                return SourceCanonicalPhysgunTickReport(
                    events: events,
                    failures: failures
                )
            }
            if buttons.current.contains(.attack2),
               !buttons.previous.contains(.attack2) {
                let entityValue = registry.entity(at: held.entity.entryIndex)
                let weaponValue = registry.entity(at: held.weapon.entryIndex)
                guard registry.canonicalIdentity(for: entityValue) == held.entity,
                      registry.canonicalIdentity(for: weaponValue) == held.weapon else {
                    heldByPlayer.removeValue(forKey: player.identity)
                    requestPresentationClear(
                        for: held,
                        host: host,
                        failures: &failures
                    )
                    events.append(event(.staleHoldCleared, held: held))
                    return SourceCanonicalPhysgunTickReport(
                        events: events,
                        failures: failures
                    )
                }
                do {
                    let gamemodeRan = try dispatchFreezeHook(
                        playerValue: playerValue,
                        weaponValue: weaponValue,
                        entityValue: entityValue,
                        held: held
                    )
                    heldByPlayer.removeValue(forKey: player.identity)
                    requestPresentationClear(
                        for: held,
                        host: host,
                        failures: &failures
                    )
                    events.append(event(
                        gamemodeRan ? .freeze : .freezeIntercepted,
                        held: held
                    ))
                    dispatchDropHook(
                        playerValue: playerValue,
                        held: held,
                        registry: registry,
                        failures: &failures
                    )
                    events.append(event(.drop, held: held))
                } catch {
                    failures.append(SourceCanonicalPhysgunFailure(
                        stage: .freezeHook,
                        message: GMLuaRuntime.describe(error)
                    ))
                }
                return SourceCanonicalPhysgunTickReport(
                    events: events,
                    failures: failures
                )
            }
            applyControlInput(
                to: &held,
                buttons: buttons.current,
                command: command
            )
            heldByPlayer[player.identity] = held
            do {
                try queueMotion(
                    held: held,
                    player: player,
                    body: body,
                    host: host
                )
                events.append(event(.move, held: held))
            } catch {
                failures.append(SourceCanonicalPhysgunFailure(
                    stage: .motion,
                    message: GMLuaRuntime.describe(error)
                ))
            }
            do {
                try publishPresentation(for: held, host: host)
            } catch {
                failures.append(SourceCanonicalPhysgunFailure(
                    stage: .presentation,
                    message: GMLuaRuntime.describe(error)
                ))
            }
            return SourceCanonicalPhysgunTickReport(
                events: events,
                failures: failures
            )
        }

        guard let activeWeapon,
              activeWeapon.kind == .weapon,
              activeWeapon.className == SourceCanonicalPhysgunWeaponDefinition.className,
              buttons.current.contains(.attack),
              !buttons.previous.contains(.attack) else {
            return SourceCanonicalPhysgunTickReport(
                events: events,
                failures: failures
            )
        }
        let weaponValue = registry.entity(at: activeWeapon.identity.entryIndex)
        guard registry.canonicalIdentity(for: weaponValue) == activeWeapon.identity else {
            return .idle
        }

        let traceHit: TraceHit
        do {
            guard let hit = try trace(
                player: player,
                playerValue: playerValue,
                weaponValue: weaponValue,
                registry: registry,
                host: host
            ) else { return .idle }
            traceHit = hit
        } catch {
            failures.append(SourceCanonicalPhysgunFailure(
                stage: .trace,
                message: GMLuaRuntime.describe(error)
            ))
            return SourceCanonicalPhysgunTickReport(failures: failures)
        }

        let allowed: Bool
        do {
            let entityValue = registry.entity(at: traceHit.entity.identity.entryIndex)
            guard registry.canonicalIdentity(for: entityValue) == traceHit.entity.identity else {
                return .idle
            }
            allowed = try permission(
                playerValue: playerValue,
                entityValue: entityValue
            )
        } catch {
            failures.append(SourceCanonicalPhysgunFailure(
                stage: .permission,
                message: GMLuaRuntime.describe(error)
            ))
            return SourceCanonicalPhysgunTickReport(failures: failures)
        }

        let eye = player.transform.origin + player.viewOffset
        let distance = min(
            max(
                (traceHit.hitPosition - eye).length,
                Self.minimumGrabDistance
            ),
            Self.maximumGrabDistance
        )
        let held = HeldBody(
            player: player.identity,
            weapon: activeWeapon.identity,
            entity: traceHit.entity.identity,
            bodyID: traceHit.body.bodyID,
            grabDistance: distance,
            localGrabPoint: traceHit.body.transform.inverseTransformPointToLocal(
                traceHit.hitPosition
            ),
            targetAngles: traceHit.body.transform.angles
        )
        guard allowed else {
            events.append(event(.rejected, held: held))
            return SourceCanonicalPhysgunTickReport(events: events)
        }

        heldByPlayer[player.identity] = held
        do {
            try queueMotion(
                held: held,
                player: player,
                body: traceHit.body,
                host: host
            )
        } catch {
            heldByPlayer.removeValue(forKey: player.identity)
            requestPresentationClear(
                for: held,
                host: host,
                failures: &failures
            )
            failures.append(SourceCanonicalPhysgunFailure(
                stage: .motion,
                message: GMLuaRuntime.describe(error)
            ))
            return SourceCanonicalPhysgunTickReport(failures: failures)
        }
        do {
            try publishPresentation(for: held, host: host)
        } catch {
            heldByPlayer.removeValue(forKey: player.identity)
            requestPresentationClear(
                for: held,
                host: host,
                failures: &failures
            )
            failures.append(SourceCanonicalPhysgunFailure(
                stage: .presentation,
                message: GMLuaRuntime.describe(error)
            ))
            return SourceCanonicalPhysgunTickReport(failures: failures)
        }
        events.append(event(.pickup, held: held))
        let entityValue = registry.entity(at: held.entity.entryIndex)
        if let message = runtime.dispatchContainedHostHook(
            named: "OnPhysgunPickup",
            arguments: [playerValue, entityValue]
        ) {
            failures.append(SourceCanonicalPhysgunFailure(
                stage: .pickupHook,
                message: message
            ))
        }
        return SourceCanonicalPhysgunTickReport(
            events: events,
            failures: failures
        )
    }

    private func trace(
        player: SourceCanonicalEntitySnapshot,
        playerValue: LuaValue,
        weaponValue: LuaValue,
        registry: GMLuaEntityRegistry,
        host: any SourceCanonicalPhysgunHost
    ) throws -> TraceHit? {
        guard let typeSystem = runtime.typeSystem else {
            throw LuaError.runtime("weapon_physgun trace requires the GLua type system")
        }
        guard case let .table(util) = runtime.state.getGlobal("util") else {
            throw LuaError.runtime("weapon_physgun trace requires util")
        }
        let traceLine = try runtime.state.rawTableValue(
            for: .string("TraceLine"),
            in: util
        )
        switch traceLine {
        case .luaFunction, .nativeFunction:
            break
        default:
            throw LuaError.runtime(
                "util.TraceLine is \(traceLine.typeName), expected function"
            )
        }
        let eye = player.transform.origin + player.viewOffset
        let end = eye +
            player.transform.angles.sourceBasis.forward *
                Self.maximumGrabDistance
        let filter = LuaTable()
        try runtime.state.setRawTableValue(
            playerValue,
            for: .number(1),
            in: filter
        )
        try runtime.state.setRawTableValue(
            weaponValue,
            for: .number(2),
            in: filter
        )
        let configuration = LuaTable()
        try runtime.state.setRawTableValue(
            try vector(eye, typeSystem: typeSystem),
            for: .string("start"),
            in: configuration
        )
        try runtime.state.setRawTableValue(
            try vector(end, typeSystem: typeSystem),
            for: .string("endpos"),
            in: configuration
        )
        let mask = SourceMasks.shot.union(.grate)
        try runtime.state.setRawTableValue(
            .number(Double(Int32(bitPattern: mask.rawValue))),
            for: .string("mask"),
            in: configuration
        )
        try runtime.state.setRawTableValue(
            .table(filter),
            for: .string("filter"),
            in: configuration
        )
        let value = try runtime.state.call(
            traceLine,
            arguments: [.table(configuration)]
        ).first ?? .nilValue
        guard case let .table(result) = value else {
            throw LuaError.runtime(
                "util.TraceLine returned \(value.typeName), expected table"
            )
        }
        guard try boolean(named: "Hit", in: result) else { return nil }
        let entityValue = try runtime.state.rawTableValue(
            for: .string("Entity"),
            in: result
        )
        guard let identity = registry.canonicalIdentity(for: entityValue),
              let entity = host.canonicalSnapshot(for: identity),
              entity.kind == .propPhysics,
              entity.lifecycle == .spawned || entity.lifecycle == .active else {
            return nil
        }
        let physicsBone = try integer(named: "PhysicsBone", in: result)
        guard physicsBone >= 0,
              let bodyID = try? SourcePhysicsBodyID(
                  entityIdentity: entity.identity,
                  solidIndex: physicsBone
              ),
              let body = host.canonicalPhysicsObject(for: bodyID),
              body.motionType == .dynamicBody else {
            return nil
        }
        let hitValue = try runtime.state.rawTableValue(
            for: .string("HitPos"),
            in: result
        )
        let components = try GMLuaVectorAngle.networkVectorComponents(
            from: hitValue,
            function: "weapon_physgun HitPos"
        )
        let hitPosition = SourceVector3(
            Float(components.0),
            Float(components.1),
            Float(components.2)
        )
        guard hitPosition.x.isFinite,
              hitPosition.y.isFinite,
              hitPosition.z.isFinite else {
            throw LuaError.runtime("weapon_physgun trace returned non-finite HitPos")
        }
        return TraceHit(entity: entity, body: body, hitPosition: hitPosition)
    }

    private func permission(
        playerValue: LuaValue,
        entityValue: LuaValue
    ) throws -> Bool {
        guard case let .table(hook) = runtime.state.getGlobal("hook") else {
            throw LuaError.runtime("weapon_physgun requires hook table")
        }
        let call = try runtime.state.rawTableValue(for: .string("Call"), in: hook)
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
        let result = try runtime.state.call(
            call,
            arguments: [
                .string("PhysgunPickup"),
                gamemode,
                playerValue,
                entityValue,
            ]
        ).first ?? .nilValue
        switch result {
        case let .boolean(value):
            return value
        case .nilValue:
            return false
        default:
            throw LuaError.runtime(
                "PhysgunPickup returned \(result.typeName), expected boolean or nil"
            )
        }
    }

    private func runReloadHook(
        player: SourceCanonicalEntitySnapshot,
        playerValue: LuaValue,
        weapon: SourceCanonicalEntitySnapshot,
        registry: GMLuaEntityRegistry
    ) -> SourceCanonicalPhysgunTickReport {
        pendingUnfreezeResults[player.identity] = []
        var events: [SourceCanonicalPhysgunEvent] = []
        var failures: [SourceCanonicalPhysgunFailure] = []
        do {
            let weaponValue = registry.entity(at: weapon.identity.entryIndex)
            guard registry.canonicalIdentity(for: weaponValue) == weapon.identity else {
                pendingUnfreezeResults.removeValue(forKey: player.identity)
                return .idle
            }
            guard case let .table(hook) = runtime.state.getGlobal("hook") else {
                throw LuaError.runtime("weapon_physgun reload requires hook table")
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
            // Stock weapon_physgun routes the edge through this hook. A
            // non-nil addon result suppresses the gamemode fallback inside
            // hook.Call; therefore the native Player:PhysgunUnfreeze bridge
            // below is never entered on a rejected reload.
            _ = try runtime.state.call(
                call,
                arguments: [
                    .string("OnPhysgunReload"),
                    gamemode,
                    weaponValue,
                    playerValue,
                ]
            )
        } catch {
            failures.append(SourceCanonicalPhysgunFailure(
                stage: .reloadHook,
                message: GMLuaRuntime.describe(error)
            ))
        }
        for result in pendingUnfreezeResults.removeValue(
            forKey: player.identity
        ) ?? [] {
            events.append(contentsOf: result.events)
            failures.append(contentsOf: result.failures)
        }
        return SourceCanonicalPhysgunTickReport(
            events: events,
            failures: failures
        )
    }

    /// Replaces only stock Lua's `Player:PhysgunUnfreeze` body after gamemode
    /// startup. The public hook route remains Lua-owned; this bridge narrows
    /// the currently supported behavior to the one body under the sight line.
    /// Double-reload/all-object and constraint-graph expansion remain
    /// deliberately unsupported until their complete Source contracts exist.
    public func installTargetedPhysgunUnfreezeBridge() throws {
        guard !targetedPhysgunUnfreezeBridgeInstalled else { return }
        guard let playerMetatable = runtime.typeSystem?.metatable(named: "Player") else {
            throw LuaError.runtime(
                "weapon_physgun reload requires the Player metatable"
            )
        }
        let key = LuaValue.string("PhysgunUnfreeze")
        let existing = try runtime.state.rawTableValue(for: key, in: playerMetatable)
        if case let .nativeFunction(function) = existing,
           function === targetedPhysgunUnfreezeFunction {
            targetedPhysgunUnfreezeBridgeInstalled = true
            return
        }
        switch existing {
        case .luaFunction, .nativeFunction:
            try runtime.state.setRawTableValue(
                .nativeFunction(targetedPhysgunUnfreezeFunction),
                for: key,
                in: playerMetatable
            )
            targetedPhysgunUnfreezeBridgeInstalled = true
        default:
            throw LuaError.runtime(
                "Player:PhysgunUnfreeze is \(existing.typeName), expected function"
            )
        }
    }

    private func performTargetedUnfreeze(
        playerIdentity: SourceCanonicalEntityIdentity,
        playerValue: LuaValue
    ) -> TargetedUnfreezeResult {
        guard let host,
              let registry = runtime.entityRegistry,
              let player = host.canonicalSnapshot(for: playerIdentity),
              player.kind == .player,
              player.lifecycle == .active,
              let weaponIdentity = player.weaponInventory.activeWeapon,
              let weapon = host.canonicalSnapshot(for: weaponIdentity),
              weapon.kind == .weapon,
              weapon.className == SourceCanonicalPhysgunWeaponDefinition.className else {
            return .none
        }
        let weaponValue = registry.entity(at: weapon.identity.entryIndex)
        guard registry.canonicalIdentity(for: weaponValue) == weapon.identity else {
            return .none
        }

        let hit: TraceHit
        do {
            guard let traced = try trace(
                player: player,
                playerValue: playerValue,
                weaponValue: weaponValue,
                registry: registry,
                host: host
            ) else { return .none }
            hit = traced
        } catch {
            return targetedUnfreezeFailure(.unfreezeTrace, error)
        }
        guard !hit.body.isMotionEnabled else { return .none }

        let entityValue = registry.entity(at: hit.entity.identity.entryIndex)
        guard registry.canonicalIdentity(for: entityValue) == hit.entity.identity else {
            return .none
        }
        let physicsValue: LuaValue
        do {
            physicsValue = try physicsObjectValue(
                entityValue: entityValue,
                bodyID: hit.body.bodyID
            )
            guard try isTrackedFrozenBody(
                playerValue: playerValue,
                entityIdentity: hit.entity.identity,
                physicsValue: physicsValue,
                registry: registry
            ) else { return .none }
        } catch {
            return targetedUnfreezeFailure(.unfreezePermission, error)
        }

        let allowed: Bool
        do {
            allowed = try canPlayerUnfreeze(
                playerValue: playerValue,
                entityValue: entityValue,
                physicsValue: physicsValue
            )
        } catch {
            return targetedUnfreezeFailure(.unfreezePermission, error)
        }
        guard allowed else {
            return TargetedUnfreezeResult(
                count: 0,
                events: [event(.unfreezeRejected, player: player, weapon: weapon, hit: hit)],
                failures: []
            )
        }

        do {
            for mutation in [
                SourcePhysicsBodyMutation.setMotionEnabled(true),
                .wake,
            ] {
                try host.enqueueCanonicalPhysicsObjectMutation(
                    SourcePhysicsBodyMutationCommand(
                        bodyID: hit.body.bodyID,
                        mutation: mutation
                    )
                )
            }
        } catch {
            return targetedUnfreezeFailure(.unfreezeMotion, error)
        }
        var failures: [SourceCanonicalPhysgunFailure] = []
        if let message = runtime.dispatchContainedHostHook(
            named: "PlayerUnfrozeObject",
            arguments: [playerValue, entityValue, physicsValue]
        ) {
            failures.append(SourceCanonicalPhysgunFailure(
                stage: .unfreezeHook,
                message: message
            ))
        }
        return TargetedUnfreezeResult(
            count: 1,
            events: [event(.unfreeze, player: player, weapon: weapon, hit: hit)],
            failures: failures
        )
    }

    private func targetedUnfreezeFailure(
        _ stage: SourceCanonicalPhysgunFailureStage,
        _ error: Error
    ) -> TargetedUnfreezeResult {
        TargetedUnfreezeResult(
            count: 0,
            events: [],
            failures: [SourceCanonicalPhysgunFailure(
                stage: stage,
                message: GMLuaRuntime.describe(error)
            )]
        )
    }

    /// Applies the same command-local inputs exposed to Lua's CUserCmd. Garry's
    /// Mod mouse-wheel steps and E+W/S share one distance path. Rotation
    /// consumes real mouse deltas only while Use is held, and Shift snaps the
    /// result to the bundled default `gm_snapangles` grid.
    private func applyControlInput(
        to held: inout HeldBody,
        buttons: SourceInputButtons,
        command: SourceUserCommand
    ) {
        var distanceSteps = Float(command.mouseWheel)
        if buttons.contains(.use) {
            if buttons.contains(.forward) { distanceSteps += 1 }
            if buttons.contains(.back) { distanceSteps -= 1 }
        }
        if distanceSteps != 0 {
            held.grabDistance = min(
                max(
                    held.grabDistance + distanceSteps * Self.distanceStep,
                    Self.minimumGrabDistance
                ),
                Self.maximumGrabDistance
            )
        }

        guard buttons.contains(.use),
              command.mouseDX != 0 || command.mouseDY != 0 else { return }
        held.targetAngles.pitch = normalizedAngle(
            held.targetAngles.pitch +
                Float(command.mouseDY) * Self.rotationSensitivity
        )
        held.targetAngles.yaw = normalizedAngle(
            held.targetAngles.yaw +
                Float(command.mouseDX) * Self.rotationSensitivity
        )
        held.targetAngles.roll = normalizedAngle(held.targetAngles.roll)
        if buttons.contains(.speed) {
            held.targetAngles = SourceQAngle(
                pitch: snappedAngle(held.targetAngles.pitch),
                yaw: snappedAngle(held.targetAngles.yaw),
                roll: snappedAngle(held.targetAngles.roll)
            )
        }
    }

    private func snappedAngle(_ angle: Float) -> Float {
        normalizedAngle(
            (normalizedAngle(angle) / Self.snapAngle).rounded() *
                Self.snapAngle
        )
    }

    private func publishPresentation(
        for held: HeldBody,
        host: any SourceCanonicalPhysgunHost
    ) throws {
        let desired = SourceCanonicalPhysgunHoldState(
            target: held.entity,
            bodyID: held.bodyID,
            localGrabPoint: held.localGrabPoint,
            grabDistance: held.grabDistance,
            targetAngles: held.targetAngles
        )
        if host.canonicalSnapshot(for: held.weapon)?
            .weaponRuntime.physgunHold == desired {
            return
        }
        _ = try host.updateCanonicalEntity(held.weapon) { state in
            state.weaponRuntime.physgunHold = desired
        }
    }

    private func clearPresentation(
        for held: HeldBody,
        host: any SourceCanonicalPhysgunHost
    ) throws {
        guard let weapon = host.canonicalSnapshot(for: held.weapon) else {
            return
        }
        let current = weapon.weaponRuntime.physgunHold
        guard current.target == held.entity,
              current.bodyID == held.bodyID else { return }
        _ = try host.updateCanonicalEntity(held.weapon) { state in
            let current = state.weaponRuntime.physgunHold
            guard current.target == held.entity,
                  current.bodyID == held.bodyID else { return }
            state.weaponRuntime.physgunHold = .inactive
        }
    }

    private func requestPresentationClear(
        for held: HeldBody,
        host: any SourceCanonicalPhysgunHost,
        failures: inout [SourceCanonicalPhysgunFailure]
    ) {
        do {
            try clearPresentation(for: held, host: host)
            pendingPresentationClearByPlayer.removeValue(
                forKey: held.player
            )
        } catch {
            pendingPresentationClearByPlayer[held.player] = held
            failures.append(SourceCanonicalPhysgunFailure(
                stage: .presentation,
                message: GMLuaRuntime.describe(error)
            ))
        }
    }

    private func retryPendingPresentationClear(
        for player: SourceCanonicalEntityIdentity,
        host: any SourceCanonicalPhysgunHost,
        failures: inout [SourceCanonicalPhysgunFailure]
    ) {
        guard let held = pendingPresentationClearByPlayer[player] else {
            return
        }
        requestPresentationClear(
            for: held,
            host: host,
            failures: &failures
        )
    }

    private func queueMotion(
        held: HeldBody,
        player: SourceCanonicalEntitySnapshot,
        body: SourceCanonicalPhysicsObjectSnapshot,
        host: any SourceCanonicalPhysgunHost
    ) throws {
        let eye = player.transform.origin + player.viewOffset
        let targetGrabPoint = eye +
            player.transform.angles.sourceBasis.forward * held.grabDistance
        let currentGrabOffset = body.transform.transformDirectionFromLocal(
            held.localGrabPoint
        )
        let targetOrigin = targetGrabPoint - currentGrabOffset
        let delta = targetOrigin - body.transform.origin
        let desiredLinear = clamped(
            delta / SourcePhysicsContract.fixedTimeStepSeconds,
            maximumLength: Self.maximumLinearSpeed
        )
        let angularDelta = SourceVector3(
            normalizedAngle(held.targetAngles.pitch - body.transform.angles.pitch),
            normalizedAngle(held.targetAngles.yaw - body.transform.angles.yaw),
            normalizedAngle(held.targetAngles.roll - body.transform.angles.roll)
        )
        let desiredAngular = clamped(
            angularDelta / SourcePhysicsContract.fixedTimeStepSeconds,
            maximumLength: Self.maximumAngularSpeed
        )
        for mutation in [
            SourcePhysicsBodyMutation.setMotionEnabled(true),
            .wake,
            .setLinearVelocity(desiredLinear),
            .setAngularVelocity(desiredAngular),
        ] {
            try host.enqueueCanonicalPhysicsObjectMutation(
                SourcePhysicsBodyMutationCommand(
                    bodyID: held.bodyID,
                    mutation: mutation
                )
            )
        }
    }

    private func dispatchDropHook(
        playerValue: LuaValue,
        held: HeldBody,
        registry: GMLuaEntityRegistry,
        failures: inout [SourceCanonicalPhysgunFailure]
    ) {
        let entityValue = registry.entity(at: held.entity.entryIndex)
        guard registry.canonicalIdentity(for: entityValue) == held.entity else {
            return
        }
        if let message = runtime.dispatchContainedHostHook(
            named: "PhysgunDrop",
            arguments: [playerValue, entityValue]
        ) {
            failures.append(SourceCanonicalPhysgunFailure(
                stage: .dropHook,
                message: message
            ))
        }
    }

    /// Dispatches the stock engine freeze callback with its documented
    /// `(weapon, physobj, entity, player)` order. `hook.Call` returns non-nil
    /// when an addon intercepted the callback, so that path must not be
    /// reported as the base gamemode having frozen the body. In either case
    /// the physgun releases its hold; any actual motion-state change remains a
    /// SERVER FIFO mutation performed by the callback's `EnableMotion` call.
    private func dispatchFreezeHook(
        playerValue: LuaValue,
        weaponValue: LuaValue,
        entityValue: LuaValue,
        held: HeldBody
    ) throws -> Bool {
        let physicsValue = try physicsObjectValue(
            entityValue: entityValue,
            bodyID: held.bodyID
        )

        guard case let .table(hook) = runtime.state.getGlobal("hook") else {
            throw LuaError.runtime("weapon_physgun freeze requires hook table")
        }
        let call = try runtime.state.rawTableValue(for: .string("Call"), in: hook)
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
        let result = try runtime.state.call(
            call,
            arguments: [
                .string("OnPhysgunFreeze"),
                gamemode,
                weaponValue,
                physicsValue,
                entityValue,
                playerValue,
            ]
        ).first ?? .nilValue
        if case .nilValue = result {
            return true
        }
        return false
    }

    private func physicsObjectValue(
        entityValue: LuaValue,
        bodyID: SourcePhysicsBodyID
    ) throws -> LuaValue {
        guard let entityMetatable = runtime.typeSystem?.metatable(named: "Entity") else {
            throw LuaError.runtime(
                "weapon_physgun requires the Entity metatable"
            )
        }
        let getPhysicsObject = try runtime.state.rawTableValue(
            for: .string("GetPhysicsObjectNum"),
            in: entityMetatable
        )
        switch getPhysicsObject {
        case .luaFunction, .nativeFunction:
            break
        default:
            throw LuaError.runtime(
                "Entity:GetPhysicsObjectNum is \(getPhysicsObject.typeName), expected function"
            )
        }
        let value = try runtime.state.call(
            getPhysicsObject,
            arguments: [
                entityValue,
                .number(Double(bodyID.solidIndex)),
            ]
        ).first ?? .nilValue
        guard let object = GMLuaTypeSystem.typedObject(from: value),
              object.metaName == "PhysObj",
              object.isValid else {
            throw LuaError.runtime(
                "Entity:GetPhysicsObjectNum did not return the live canonical PhysObj"
            )
        }
        return value
    }

    private func isTrackedFrozenBody(
        playerValue: LuaValue,
        entityIdentity: SourceCanonicalEntityIdentity,
        physicsValue: LuaValue,
        registry: GMLuaEntityRegistry
    ) throws -> Bool {
        guard let playerTable = registry.luaTable(for: playerValue) else {
            throw LuaError.runtime(
                "Player:PhysgunUnfreeze requires the live Player table"
            )
        }
        let stored = try runtime.state.rawTableValue(
            for: .string("FrozenPhysicsObjects"),
            in: playerTable
        )
        guard case let .table(frozenObjects) = stored else { return false }
        for (_, entryValue) in try runtime.state.rawTablePairs(in: frozenObjects) {
            guard case let .table(entry) = entryValue else { continue }
            let entityValue = try runtime.state.rawTableValue(
                for: .string("ent"),
                in: entry
            )
            let storedPhysicsValue = try runtime.state.rawTableValue(
                for: .string("phys"),
                in: entry
            )
            if registry.canonicalIdentity(for: entityValue) == entityIdentity,
               sameLuaReference(storedPhysicsValue, physicsValue) {
                return true
            }
        }
        return false
    }

    private func sameLuaReference(_ lhs: LuaValue, _ rhs: LuaValue) -> Bool {
        switch (lhs, rhs) {
        case let (.userdata(left), .userdata(right)):
            return left === right
        case let (.table(left), .table(right)):
            return left === right
        default:
            return false
        }
    }

    private func canPlayerUnfreeze(
        playerValue: LuaValue,
        entityValue: LuaValue,
        physicsValue: LuaValue
    ) throws -> Bool {
        guard case let .table(hook) = runtime.state.getGlobal("hook") else {
            throw LuaError.runtime(
                "Player:PhysgunUnfreeze requires hook table"
            )
        }
        let call = try runtime.state.rawTableValue(for: .string("Call"), in: hook)
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
        let result = try runtime.state.call(
            call,
            arguments: [
                .string("CanPlayerUnfreeze"),
                gamemode,
                playerValue,
                entityValue,
                physicsValue,
            ]
        ).first ?? .nilValue
        switch result {
        case let .boolean(value):
            return value
        case .nilValue:
            return false
        default:
            throw LuaError.runtime(
                "CanPlayerUnfreeze returned \(result.typeName), expected boolean or nil"
            )
        }
    }

    private func event(
        _ kind: SourceCanonicalPhysgunEventKind,
        held: HeldBody
    ) -> SourceCanonicalPhysgunEvent {
        SourceCanonicalPhysgunEvent(
            kind: kind,
            player: held.player,
            weapon: held.weapon,
            entity: held.entity,
            bodyID: held.bodyID
        )
    }

    private func event(
        _ kind: SourceCanonicalPhysgunEventKind,
        player: SourceCanonicalEntitySnapshot,
        weapon: SourceCanonicalEntitySnapshot,
        hit: TraceHit
    ) -> SourceCanonicalPhysgunEvent {
        SourceCanonicalPhysgunEvent(
            kind: kind,
            player: player.identity,
            weapon: weapon.identity,
            entity: hit.entity.identity,
            bodyID: hit.body.bodyID
        )
    }

    private func boolean(named name: String, in table: LuaTable) throws -> Bool {
        let value = try runtime.state.rawTableValue(
            for: .string(LuaString(name)),
            in: table
        )
        guard case let .boolean(result) = value else {
            throw LuaError.runtime(
                "weapon_physgun trace field \(name) is \(value.typeName), expected boolean"
            )
        }
        return result
    }

    private func integer(named name: String, in table: LuaTable) throws -> Int {
        let value = try runtime.state.rawTableValue(
            for: .string(LuaString(name)),
            in: table
        )
        guard case let .number(number) = value,
              number.isFinite,
              number.rounded(.towardZero) == number,
              let result = Int(exactly: number) else {
            throw LuaError.runtime(
                "weapon_physgun trace field \(name) is not an integer"
            )
        }
        return result
    }

    private func vector(
        _ value: SourceVector3,
        typeSystem: GMLuaTypeSystem
    ) throws -> LuaValue {
        try GMLuaVectorAngle.makeNetworkVector(
            Double(value.x),
            Double(value.y),
            Double(value.z),
            typeSystem: typeSystem
        )
    }

    private func clamped(
        _ value: SourceVector3,
        maximumLength: Float
    ) -> SourceVector3 {
        let length = value.length
        guard length.isFinite, length > maximumLength, length > 0 else {
            return value
        }
        return value * (maximumLength / length)
    }

    private func normalizedAngle(_ value: Float) -> Float {
        var result = value.truncatingRemainder(dividingBy: 360)
        if result > 180 { result -= 360 }
        if result < -180 { result += 360 }
        return result
    }
}
