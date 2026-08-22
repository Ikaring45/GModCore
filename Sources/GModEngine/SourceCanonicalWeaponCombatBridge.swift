import Foundation
import GModLua

/// One engine-owned framebuffer capture requested by Source's `jpeg` console
/// command. Rendering remains asynchronous: gameplay records the request in
/// exact order and exposes it for the app renderer's safe frame boundary.
public struct SourceCanonicalCameraCaptureRequest: Equatable, Sendable {
    public let sequence: UInt64
    public let requestedAt: Double

    public init(sequence: UInt64, requestedAt: Double) {
        self.sequence = sequence
        self.requestedAt = requestedAt
    }
}

public final class SourceCanonicalCameraCaptureRequestState:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var nextSequence: UInt64 = 1
    private var storage: [SourceCanonicalCameraCaptureRequest] = []

    public init() {}

    public var pending: [SourceCanonicalCameraCaptureRequest] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    public func drain() -> [SourceCanonicalCameraCaptureRequest] {
        lock.lock()
        let result = storage
        storage.removeAll(keepingCapacity: true)
        lock.unlock()
        return result
    }

    fileprivate func enqueue(requestedAt: Double) throws {
        lock.lock()
        defer { lock.unlock() }
        guard nextSequence != UInt64.max else {
            throw LuaError.runtime("jpeg capture request sequence exhausted")
        }
        storage.append(SourceCanonicalCameraCaptureRequest(
            sequence: nextSequence,
            requestedAt: requestedAt
        ))
        nextSequence += 1
    }
}

private final class SourceCanonicalWeaponCombatWeakHost: @unchecked Sendable {
    weak var value: (any SourceCanonicalEntityLuaHost)?

    init(_ value: (any SourceCanonicalEntityLuaHost)?) {
        self.value = value
    }
}

private final class SourceCanonicalWeaponCombatWeakRegistry:
    @unchecked Sendable
{
    weak var value: GMLuaEntityRegistry?

    init(_ value: GMLuaEntityRegistry?) {
        self.value = value
    }
}

private final class SourceCanonicalDamageInfoValue: @unchecked Sendable {
    var damage: Float = 0
    var force: SourceVector3 = .zero
    var position: SourceVector3 = .zero
    var attacker: SourceCanonicalEntityIdentity?
    var inflictor: SourceCanonicalEntityIdentity?
    var weapon: SourceCanonicalEntityIdentity?
}

private final class SourceCanonicalViewModelValue: @unchecked Sendable {
    let player: SourceCanonicalEntityIdentity
    var lastLookupName = ""

    init(player: SourceCanonicalEntityIdentity) {
        self.player = player
    }
}

private final class SourceCanonicalUserCommandValue: @unchecked Sendable {
    let player: SourceCanonicalEntityIdentity

    init(player: SourceCanonicalEntityIdentity) {
        self.player = player
    }
}

/// Native combat and animation state required by stock scripted weapons. The
/// bridge only projects canonical snapshots; authoritative mutations always
/// pass through `SourceCanonicalEntityLuaHost` and therefore enter the normal
/// SERVER replication journal.
public enum SourceCanonicalWeaponCombatBridge {
    public static let sourceFixedFrameTime = 0.015

    public static func install(
        into runtime: GMLuaRuntime,
        host: (any SourceCanonicalEntityLuaHost)? = nil
    ) throws {
        guard runtime.realm != .menu,
              let typeSystem = runtime.typeSystem,
              let registry = runtime.entityRegistry,
              let entityMetatable = typeSystem.metatable(named: "Entity"),
              let playerMetatable = typeSystem.metatable(named: "Player"),
              let weaponMetatable = typeSystem.metatable(named: "Weapon"),
              let damageMetatable = typeSystem.metatable(
                named: "CTakeDamageInfo"
              ),
              let commandMetatable = typeSystem.metatable(named: "CUserCmd")
        else {
            throw LuaError.runtime(
                "canonical Weapon combat requires game native metatables"
            )
        }
        if runtime.realm == .server, host == nil {
            throw LuaError.runtime(
                "canonical Weapon combat SERVER requires an authoritative host"
            )
        }

        let state = runtime.state
        let realm = runtime.realm
        let hostBox = SourceCanonicalWeaponCombatWeakHost(host)
        let registryBox = SourceCanonicalWeaponCombatWeakRegistry(registry)

        func native(
            _ name: String,
            _ body: @escaping LuaNativeFunction
        ) -> LuaValue {
            .nativeFunction(LuaNativeFunctionBox(body, debugName: name))
        }

        func setMethod(
            _ debugName: String,
            on metatable: LuaTable,
            body: @escaping LuaNativeFunction
        ) throws {
            let name = debugName.split(separator: ":").last
                .map(String.init) ?? debugName
            try state.setRawTableValue(
                native(debugName, body),
                for: .string(LuaString(name)),
                in: metatable
            )
        }

        func snapshot(
            _ value: LuaValue?,
            function: String,
            kind: SourceCanonicalEntityKind? = nil
        ) throws -> SourceCanonicalEntitySnapshot {
            guard let value,
                  let result = registryBox.value?.canonicalSnapshot(for: value),
                  kind == nil || result.kind == kind else {
                throw LuaError.runtime(
                    "bad self to '\(function)' (live canonical Entity expected)"
                )
            }
            return result
        }

        func requiredHost(
            _ function: String
        ) throws -> any SourceCanonicalEntityLuaHost {
            guard realm == .server, let host = hostBox.value else {
                throw LuaError.runtime("\(function) requires SERVER authority")
            }
            return host
        }

        func number(
            _ arguments: [LuaValue],
            index: Int,
            function: String
        ) throws -> Double {
            guard arguments.indices.contains(index),
                  case let .number(value) = arguments[index],
                  value.isFinite else {
                throw LuaError.runtime(
                    "bad argument #\(index) to '\(function)' (finite number expected)"
                )
            }
            return value
        }

        func int32(
            _ arguments: [LuaValue],
            index: Int,
            function: String
        ) throws -> Int32 {
            let raw = try number(
                arguments,
                index: index,
                function: function
            )
            guard raw.rounded(.towardZero) == raw,
                  let value = Int32(exactly: raw) else {
                throw LuaError.runtime(
                    "bad argument #\(index) to '\(function)' (32-bit integer expected)"
                )
            }
            return value
        }

        func sourceFloat(
            _ arguments: [LuaValue],
            index: Int,
            function: String
        ) throws -> Float {
            let raw = try number(
                arguments,
                index: index,
                function: function
            )
            guard abs(raw) <= Double(Float.greatestFiniteMagnitude) else {
                throw LuaError.runtime(
                    "bad argument #\(index) to '\(function)' (Source Float expected)"
                )
            }
            return Float(raw)
        }

        func string(
            _ arguments: [LuaValue],
            index: Int,
            function: String
        ) throws -> String {
            guard arguments.indices.contains(index),
                  case let .string(value) = arguments[index] else {
                throw LuaError.runtime(
                    "bad argument #\(index) to '\(function)' (string expected)"
                )
            }
            return value.utf8String
        }

        func vector(
            _ value: SourceVector3
        ) throws -> LuaValue {
            try GMLuaVectorAngle.makeNetworkVector(
                Double(value.x),
                Double(value.y),
                Double(value.z),
                typeSystem: typeSystem
            )
        }

        func sourceVector(
            _ value: LuaValue,
            function: String
        ) throws -> SourceVector3 {
            let components = try GMLuaVectorAngle.networkVectorComponents(
                from: value,
                function: function
            )
            let limit = Double(Float.greatestFiniteMagnitude)
            guard components.0.isFinite, components.1.isFinite,
                  components.2.isFinite,
                  abs(components.0) <= limit,
                  abs(components.1) <= limit,
                  abs(components.2) <= limit else {
                throw LuaError.runtime("\(function) Vector exceeds Source Float range")
            }
            return SourceVector3(
                Float(components.0),
                Float(components.1),
                Float(components.2)
            )
        }

        func activeWeapon(
            for player: SourceCanonicalEntityIdentity,
            function: String
        ) throws -> SourceCanonicalEntitySnapshot {
            guard let host = hostBox.value,
                  let playerSnapshot = host.canonicalSnapshot(for: player),
                  let weaponIdentity = playerSnapshot.weaponInventory
                    .activeWeapon,
                  let weapon = host.canonicalSnapshot(for: weaponIdentity),
                  weapon.kind == .weapon else {
                throw LuaError.runtime(
                    "\(function) Player has no live canonical active Weapon"
                )
            }
            return weapon
        }

        func viewModelPayload(
            _ value: LuaValue?,
            function: String
        ) throws -> SourceCanonicalViewModelValue {
            guard let value,
                  let object = GMLuaTypeSystem.typedObject(from: value),
                  object.metaName == "Entity",
                  object.isValid,
                  let payload = object.payload as? SourceCanonicalViewModelValue
            else {
                throw LuaError.runtime(
                    "bad self to '\(function)' (Player view model expected)"
                )
            }
            return payload
        }

        func damageInfo(
            _ value: LuaValue?,
            function: String
        ) throws -> SourceCanonicalDamageInfoValue {
            guard let value,
                  let object = GMLuaTypeSystem.typedObject(from: value),
                  object.metaName == "CTakeDamageInfo",
                  object.isValid,
                  let payload = object.payload as? SourceCanonicalDamageInfoValue
            else {
                throw LuaError.runtime(
                    "bad self to '\(function)' (CTakeDamageInfo expected)"
                )
            }
            return payload
        }

        func entityIdentity(
            _ value: LuaValue,
            function: String
        ) throws -> SourceCanonicalEntityIdentity {
            guard let identity = registryBox.value?.canonicalIdentity(for: value)
            else {
                throw LuaError.runtime(
                    "bad Entity argument to '\(function)'"
                )
            }
            return identity
        }

        func commandPayload(
            _ value: LuaValue?,
            function: String
        ) throws -> SourceCanonicalUserCommandValue {
            guard let value,
                  let object = GMLuaTypeSystem.typedObject(from: value),
                  object.metaName == "CUserCmd",
                  object.isValid,
                  let payload = object.payload as? SourceCanonicalUserCommandValue
            else {
                throw LuaError.runtime(
                    "bad self to '\(function)' (CUserCmd expected)"
                )
            }
            return payload
        }

        // The stock files capture these ConVars while being loaded. Install
        // the engine defaults before `lua/includes/init.lua` reaches them.
        func ensureConVar(_ name: String, defaultValue: String) throws {
            let get = state.getGlobal("GetConVar")
            let current = try state.call(
                get,
                arguments: [.string(LuaString(name))]
            ).first ?? .nilValue
            guard case .nilValue = current else { return }
            let create = state.getGlobal("CreateConVar")
            _ = try state.call(create, arguments: [
                .string(LuaString(name)),
                .string(LuaString(defaultValue)),
                .number(0),
                .string(LuaString("Source scripted weapon runtime")),
            ])
        }
        try ensureConVar("phys_pushscale", defaultValue: "1")
        try ensureConVar("sv_defaultdeployspeed", defaultValue: "4")

        if realm == .client {
            guard let dispatcher = runtime.consoleCommandDispatcher else {
                throw LuaError.runtime(
                    "gmod_camera jpeg command requires the console dispatcher"
                )
            }
            let captures = SourceCanonicalCameraCaptureRequestState()
            runtime.cameraCaptureRequests = captures
            try dispatcher.registerEngineCommand("jpeg") { _ in
                try captures.enqueue(
                    requestedAt: runtime.timerScheduler?.currentTime ?? 0
                )
                return .handled
            }
        }

        state.setGlobal(
            "FrameTime",
            value: native("FrameTime") { _ in
                [.number(sourceFixedFrameTime)]
            }
        )

        try setMethod("Entity:IsNPC", on: entityMetatable) { _ in
            // NPC is not yet a canonical Entity kind. Returning false is the
            // exact answer for every currently representable entity.
            [.boolean(false)]
        }
        for (name, component) in [
            ("GetForward", 0), ("GetRight", 1), ("GetUp", 2),
        ] {
            try setMethod("Entity:\(name)", on: entityMetatable) { arguments in
                let entity = try snapshot(
                    arguments.first,
                    function: "Entity:\(name)"
                )
                let basis = entity.transform.angles.sourceBasis
                let value = component == 0
                    ? basis.forward
                    : (component == 1 ? basis.right : basis.up)
                return [try vector(value)]
            }
        }

        try setMethod("Entity:Health", on: entityMetatable) { arguments in
            [.number(Double(try snapshot(
                arguments.first,
                function: "Entity:Health"
            ).combat.health))]
        }
        try setMethod("Entity:GetMaxHealth", on: entityMetatable) { arguments in
            [.number(Double(try snapshot(
                arguments.first,
                function: "Entity:GetMaxHealth"
            ).combat.maximumHealth))]
        }
        try setMethod(
            "Entity:GetInternalVariable",
            on: entityMetatable
        ) { arguments in
            let entity = try snapshot(
                arguments.first,
                function: "Entity:GetInternalVariable"
            )
            let name = try string(
                arguments,
                index: 1,
                function: "Entity:GetInternalVariable"
            )
            guard name == "m_takedamage" else { return [.nilValue] }
            return [.number(Double(entity.combat.takeDamageMode))]
        }
        if realm == .server {
            try setMethod("Entity:SetHealth", on: entityMetatable) { arguments in
                let entity = try snapshot(
                    arguments.first,
                    function: "Entity:SetHealth"
                )
                let health = try int32(
                    arguments,
                    index: 1,
                    function: "Entity:SetHealth"
                )
                _ = try requiredHost("Entity:SetHealth")
                    .updateCanonicalEntity(entity.identity) {
                        $0.combat.health = health
                        if entity.kind == .player {
                            $0.motion.isAlive = health > 0
                        }
                    }
                return []
            }
        }

        try setMethod("Player:IsBot", on: playerMetatable) { arguments in
            [.boolean(try snapshot(
                arguments.first,
                function: "Player:IsBot",
                kind: .player
            ).combat.isBot)]
        }
        try setMethod(
            "Player:LagCompensation",
            on: playerMetatable
        ) { arguments in
            let player = try snapshot(
                arguments.first,
                function: "Player:LagCompensation",
                kind: .player
            )
            guard arguments.indices.contains(1),
                  case let .boolean(enabled) = arguments[1] else {
                throw LuaError.runtime(
                    "bad argument #1 to 'Player:LagCompensation' (boolean expected)"
                )
            }
            _ = try requiredHost("Player:LagCompensation")
                .updateCanonicalEntity(player.identity) {
                    $0.combat.isLagCompensationEnabled = enabled
                }
            return []
        }

        try setMethod("Player:GetViewModel", on: playerMetatable) { arguments in
            let player = try snapshot(
                arguments.first,
                function: "Player:GetViewModel",
                kind: .player
            )
            _ = try activeWeapon(
                for: player.identity,
                function: "Player:GetViewModel"
            )
            return [try typeSystem.makeObject(
                metaName: "Entity",
                payload: SourceCanonicalViewModelValue(player: player.identity)
            )]
        }

        try setMethod("Entity:LookupSequence", on: entityMetatable) { arguments in
            let viewModel = try viewModelPayload(
                arguments.first,
                function: "Entity:LookupSequence"
            )
            let name = try string(
                arguments,
                index: 1,
                function: "Entity:LookupSequence"
            )
            guard !name.isEmpty, !name.contains("\0") else {
                throw LuaError.runtime(
                    "bad argument #1 to 'Entity:LookupSequence' (sequence name expected)"
                )
            }
            viewModel.lastLookupName = name
            // A missing decoded ViewModel reports Source's invalid sequence;
            // the requested name is retained only to bind the following
            // SendViewModelMatchingSequence transaction.
            return [.number(-1)]
        }
        try setMethod(
            "Entity:SendViewModelMatchingSequence",
            on: entityMetatable
        ) { arguments in
            let viewModel = try viewModelPayload(
                arguments.first,
                function: "Entity:SendViewModelMatchingSequence"
            )
            let sequence = try int32(
                arguments,
                index: 1,
                function: "Entity:SendViewModelMatchingSequence"
            )
            let weapon = try activeWeapon(
                for: viewModel.player,
                function: "Entity:SendViewModelMatchingSequence"
            )
            _ = try requiredHost("Entity:SendViewModelMatchingSequence")
                .updateCanonicalEntity(weapon.identity) {
                    $0.weaponRuntime.animationSequence = sequence
                    $0.weaponRuntime.animationSequenceName =
                        viewModel.lastLookupName
                }
            return []
        }
        try setMethod("Entity:GetSequence", on: entityMetatable) { arguments in
            let viewModel = try viewModelPayload(
                arguments.first,
                function: "Entity:GetSequence"
            )
            let weapon = try activeWeapon(
                for: viewModel.player,
                function: "Entity:GetSequence"
            )
            return [.number(Double(weapon.weaponRuntime.animationSequence))]
        }
        try setMethod("Entity:GetPlaybackRate", on: entityMetatable) { arguments in
            let viewModel = try viewModelPayload(
                arguments.first,
                function: "Entity:GetPlaybackRate"
            )
            let weapon = try activeWeapon(
                for: viewModel.player,
                function: "Entity:GetPlaybackRate"
            )
            return [.number(Double(
                weapon.weaponRuntime.animationPlaybackRate
            ))]
        }
        try setMethod("Entity:SetPlaybackRate", on: entityMetatable) { arguments in
            let viewModel = try viewModelPayload(
                arguments.first,
                function: "Entity:SetPlaybackRate"
            )
            let rate = try sourceFloat(
                arguments,
                index: 1,
                function: "Entity:SetPlaybackRate"
            )
            guard rate >= 0 else {
                throw LuaError.runtime(
                    "Entity:SetPlaybackRate requires a nonnegative rate"
                )
            }
            let weapon = try activeWeapon(
                for: viewModel.player,
                function: "Entity:SetPlaybackRate"
            )
            _ = try requiredHost("Entity:SetPlaybackRate")
                .updateCanonicalEntity(weapon.identity) {
                    $0.weaponRuntime.animationPlaybackRate = rate
                }
            return []
        }
        try setMethod("Entity:SequenceDuration", on: entityMetatable) { arguments in
            let viewModel = try viewModelPayload(
                arguments.first,
                function: "Entity:SequenceDuration"
            )
            let weapon = try activeWeapon(
                for: viewModel.player,
                function: "Entity:SequenceDuration"
            )
            return [.number(Double(
                weapon.weaponRuntime.animationSequenceDuration
            ))]
        }

        try setMethod("Weapon:GetSequenceName", on: weaponMetatable) { arguments in
            let weapon = try snapshot(
                arguments.first,
                function: "Weapon:GetSequenceName",
                kind: .weapon
            )
            let sequence = try int32(
                arguments,
                index: 1,
                function: "Weapon:GetSequenceName"
            )
            let name = sequence == weapon.weaponRuntime.animationSequence
                ? weapon.weaponRuntime.animationSequenceName
                : ""
            return [.string(LuaString(name))]
        }
        try setMethod("Weapon:SequenceDuration", on: weaponMetatable) { arguments in
            let weapon = try snapshot(
                arguments.first,
                function: "Weapon:SequenceDuration",
                kind: .weapon
            )
            return [.number(Double(
                weapon.weaponRuntime.animationSequenceDuration
            ))]
        }

        for (getter, setter, keyPath) in [
            ("Clip1", "SetClip1", \SourceCanonicalWeaponRuntimeState.clip1),
            ("Clip2", "SetClip2", \SourceCanonicalWeaponRuntimeState.clip2),
        ] {
            try setMethod("Weapon:\(getter)", on: weaponMetatable) { arguments in
                let weapon = try snapshot(
                    arguments.first,
                    function: "Weapon:\(getter)",
                    kind: .weapon
                )
                return [.number(Double(weapon.weaponRuntime[keyPath: keyPath]))]
            }
            try setMethod("Weapon:\(setter)", on: weaponMetatable) { arguments in
                let weapon = try snapshot(
                    arguments.first,
                    function: "Weapon:\(setter)",
                    kind: .weapon
                )
                let value = try int32(
                    arguments,
                    index: 1,
                    function: "Weapon:\(setter)"
                )
                _ = try requiredHost("Weapon:\(setter)")
                    .updateCanonicalEntity(weapon.identity) {
                        $0.weaponRuntime[keyPath: keyPath] = value
                    }
                return []
            }
        }

        for (getter, setter, keyPath) in [
            (
                "GetNextPrimaryFire",
                "SetNextPrimaryFire",
                \SourceCanonicalWeaponRuntimeState.nextPrimaryFire
            ),
            (
                "GetNextSecondaryFire",
                "SetNextSecondaryFire",
                \SourceCanonicalWeaponRuntimeState.nextSecondaryFire
            ),
        ] {
            try setMethod("Weapon:\(getter)", on: weaponMetatable) { arguments in
                let weapon = try snapshot(
                    arguments.first,
                    function: "Weapon:\(getter)",
                    kind: .weapon
                )
                return [.number(Double(weapon.weaponRuntime[keyPath: keyPath]))]
            }
            try setMethod("Weapon:\(setter)", on: weaponMetatable) { arguments in
                let weapon = try snapshot(
                    arguments.first,
                    function: "Weapon:\(setter)",
                    kind: .weapon
                )
                let value = try sourceFloat(
                    arguments,
                    index: 1,
                    function: "Weapon:\(setter)"
                )
                _ = try requiredHost("Weapon:\(setter)")
                    .updateCanonicalEntity(weapon.identity) {
                        $0.weaponRuntime[keyPath: keyPath] = value
                    }
                return []
            }
        }

        try setMethod(
            "Player:GetCurrentCommand",
            on: playerMetatable
        ) { arguments in
            let player = try snapshot(
                arguments.first,
                function: "Player:GetCurrentCommand",
                kind: .player
            )
            return [try typeSystem.makeObject(
                metaName: "CUserCmd",
                payload: SourceCanonicalUserCommandValue(player: player.identity)
            )]
        }
        try setMethod("CUserCmd:KeyDown", on: commandMetatable) { arguments in
            let command = try commandPayload(
                arguments.first,
                function: "CUserCmd:KeyDown"
            )
            let raw = try int32(
                arguments,
                index: 1,
                function: "CUserCmd:KeyDown"
            )
            let playerValue = registry.entity(at: command.player.entryIndex)
            let buttons = registry.playerInputButtonState(for: playerValue)?
                .current ?? SourceInputButtons()
            return [.boolean(buttons.contains(SourceInputButtons(
                rawValue: UInt32(bitPattern: raw)
            )))]
        }
        for name in ["GetMouseX", "GetMouseY"] {
            try setMethod("CUserCmd:\(name)", on: commandMetatable) { arguments in
                _ = try commandPayload(
                    arguments.first,
                    function: "CUserCmd:\(name)"
                )
                // Touch look is angular input, not a fabricated mouse delta.
                return [.number(0)]
            }
        }

        state.setGlobal(
            "DamageInfo",
            value: native("DamageInfo") { _ in
                [try typeSystem.makeObject(
                    metaName: "CTakeDamageInfo",
                    payload: SourceCanonicalDamageInfoValue()
                )]
            }
        )
        try setMethod("CTakeDamageInfo:SetDamage", on: damageMetatable) {
            arguments in
            let info = try damageInfo(
                arguments.first,
                function: "CTakeDamageInfo:SetDamage"
            )
            info.damage = try sourceFloat(
                arguments,
                index: 1,
                function: "CTakeDamageInfo:SetDamage"
            )
            return []
        }
        try setMethod("CTakeDamageInfo:GetDamage", on: damageMetatable) {
            arguments in
            [.number(Double(try damageInfo(
                arguments.first,
                function: "CTakeDamageInfo:GetDamage"
            ).damage))]
        }
        for (method, field) in [
            ("SetDamageForce", "force"), ("SetDamagePosition", "position"),
        ] {
            try setMethod("CTakeDamageInfo:\(method)", on: damageMetatable) {
                arguments in
                let info = try damageInfo(
                    arguments.first,
                    function: "CTakeDamageInfo:\(method)"
                )
                guard arguments.indices.contains(1) else {
                    throw LuaError.runtime(
                        "bad argument #1 to 'CTakeDamageInfo:\(method)' (Vector expected)"
                    )
                }
                let value = try sourceVector(
                    arguments[1],
                    function: "CTakeDamageInfo:\(method)"
                )
                if field == "force" { info.force = value }
                else { info.position = value }
                return []
            }
        }
        for (method, field) in [
            ("SetAttacker", "attacker"),
            ("SetInflictor", "inflictor"),
            ("SetWeapon", "weapon"),
        ] {
            try setMethod("CTakeDamageInfo:\(method)", on: damageMetatable) {
                arguments in
                let info = try damageInfo(
                    arguments.first,
                    function: "CTakeDamageInfo:\(method)"
                )
                guard arguments.indices.contains(1) else {
                    throw LuaError.runtime(
                        "bad argument #1 to 'CTakeDamageInfo:\(method)' (Entity expected)"
                    )
                }
                let identity = try entityIdentity(
                    arguments[1],
                    function: "CTakeDamageInfo:\(method)"
                )
                switch field {
                case "attacker": info.attacker = identity
                case "inflictor": info.inflictor = identity
                default: info.weapon = identity
                }
                return []
            }
        }
        if realm == .server {
            try setMethod(
                "Entity:TakeDamageInfo",
                on: entityMetatable
            ) { arguments in
                let entity = try snapshot(
                    arguments.first,
                    function: "Entity:TakeDamageInfo"
                )
                guard arguments.indices.contains(1) else {
                    throw LuaError.runtime(
                        "bad argument #1 to 'Entity:TakeDamageInfo' (CTakeDamageInfo expected)"
                    )
                }
                let info = try damageInfo(
                    arguments[1],
                    function: "Entity:TakeDamageInfo"
                )
                guard entity.combat.takeDamageMode != 0 else {
                    return [.number(0)]
                }
                let remaining = Double(entity.combat.health) -
                    Double(info.damage)
                let bounded = min(
                    Double(Int32.max),
                    max(Double(Int32.min), remaining)
                )
                let health = Int32(bounded.rounded(.towardZero))
                _ = try requiredHost("Entity:TakeDamageInfo")
                    .updateCanonicalEntity(entity.identity) {
                        $0.combat.health = health
                        if entity.kind == .player {
                            $0.motion.isAlive = health > 0
                        }
                    }
                return [.number(1)]
            }
        }

        // Host-event suppression is real process state even though no gib
        // emitter exists yet. Validate full EHANDLEs rather than accepting an
        // arbitrary userdata and silently discarding the request.
        let suppression = SourceCanonicalHostEventSuppressionValue()
        state.setGlobal(
            "SuppressHostEvents",
            value: native("SuppressHostEvents") { arguments in
                guard let value = arguments.first else {
                    throw LuaError.runtime(
                        "bad argument #1 to 'SuppressHostEvents' (Entity expected)"
                    )
                }
                if let object = GMLuaTypeSystem.typedObject(from: value),
                   !object.isValid {
                    suppression.identity = nil
                    return []
                }
                suppression.identity = try entityIdentity(
                    value,
                    function: "SuppressHostEvents"
                )
                return []
            }
        )
    }
}

private final class SourceCanonicalHostEventSuppressionValue:
    @unchecked Sendable
{
    var identity: SourceCanonicalEntityIdentity?
}
