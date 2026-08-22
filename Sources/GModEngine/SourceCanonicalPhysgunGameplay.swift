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
    case motion
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

    private struct HeldBody {
        let player: SourceCanonicalEntityIdentity
        let weapon: SourceCanonicalEntityIdentity
        let entity: SourceCanonicalEntityIdentity
        let bodyID: SourcePhysicsBodyID
        let grabDistance: Float
        let localGrabPoint: SourceVector3
        let targetAngles: SourceQAngle
    }

    private struct TraceHit {
        let entity: SourceCanonicalEntitySnapshot
        let body: SourceCanonicalPhysicsObjectSnapshot
        let hitPosition: SourceVector3
    }

    private let runtime: GMLuaRuntime
    private weak var host: (any SourceCanonicalPhysgunHost)?
    private var heldByPlayer: [SourceCanonicalEntityIdentity: HeldBody] = [:]

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
        playerIdentity: SourceCanonicalEntityIdentity
    ) -> SourceCanonicalPhysgunTickReport {
        guard let host,
              let registry = runtime.entityRegistry,
              let player = host.canonicalSnapshot(for: playerIdentity),
              player.kind == .player,
              player.lifecycle == .active else {
            heldByPlayer.removeValue(forKey: playerIdentity)
            return .idle
        }
        let playerValue = registry.player(at: player.identity.entryIndex)
        guard registry.canonicalIdentity(for: playerValue) == player.identity else {
            heldByPlayer.removeValue(forKey: playerIdentity)
            return .idle
        }
        let buttons = registry.playerInputButtonState(for: playerValue) ?? (
            current: SourceInputButtons(),
            previous: SourceInputButtons()
        )

        var events: [SourceCanonicalPhysgunEvent] = []
        var failures: [SourceCanonicalPhysgunFailure] = []
        let activeWeapon = player.weaponInventory.activeWeapon.flatMap {
            host.canonicalSnapshot(for: $0)
        }

        if let held = heldByPlayer[player.identity] {
            guard let activeWeapon,
                  activeWeapon.identity == held.weapon,
                  activeWeapon.className == SourceCanonicalPhysgunWeaponDefinition.className,
                  buttons.current.contains(.attack) else {
                heldByPlayer.removeValue(forKey: player.identity)
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
                events.append(event(.staleHoldCleared, held: held))
                return SourceCanonicalPhysgunTickReport(events: events)
            }
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
            return .idle
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
        let distance = (traceHit.hitPosition - eye).length
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
            failures.append(SourceCanonicalPhysgunFailure(
                stage: .motion,
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
        let end = eye + player.transform.angles.sourceBasis.forward * Self.maximumTraceLength
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
