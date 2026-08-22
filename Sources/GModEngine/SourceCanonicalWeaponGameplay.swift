import Foundation
import GModLua

public enum SourceCanonicalWeaponInvocation: String, Equatable, Sendable {
    case setupDataTables
    case initialize
    case equip
    case holster
    case deploy
    case think
    case tick
    case primaryAttack
    case secondaryAttack
    case reload
}

public struct SourceCanonicalWeaponInvocationRecord: Equatable, Sendable {
    public let weapon: SourceCanonicalEntityIdentity
    public let className: String
    public let invocation: SourceCanonicalWeaponInvocation

    public init(
        weapon: SourceCanonicalEntityIdentity,
        className: String,
        invocation: SourceCanonicalWeaponInvocation
    ) {
        self.weapon = weapon
        self.className = className
        self.invocation = invocation
    }
}

public struct SourceCanonicalWeaponInvocationFailure: Equatable, Sendable {
    public let weapon: SourceCanonicalEntityIdentity
    public let className: String
    public let invocation: SourceCanonicalWeaponInvocation
    public let message: String

    public init(
        weapon: SourceCanonicalEntityIdentity,
        className: String,
        invocation: SourceCanonicalWeaponInvocation,
        message: String
    ) {
        self.weapon = weapon
        self.className = className
        self.invocation = invocation
        self.message = message
    }
}

/// One SERVER ItemPostFrame-style pass over the canonical active Weapon. A
/// missing optional SWEP callback is not reported as an invocation; a present
/// callback that raises remains an explicit failure instead of being treated as
/// a successful weapon action.
public struct SourceCanonicalWeaponGameplayTickReport: Equatable, Sendable {
    public let newlyInitializedWeapons: [SourceCanonicalEntityIdentity]
    public let selectionTransitionCount: Int
    public let invocations: [SourceCanonicalWeaponInvocationRecord]
    public let failures: [SourceCanonicalWeaponInvocationFailure]

    public init(
        newlyInitializedWeapons: [SourceCanonicalEntityIdentity] = [],
        selectionTransitionCount: Int = 0,
        invocations: [SourceCanonicalWeaponInvocationRecord] = [],
        failures: [SourceCanonicalWeaponInvocationFailure] = []
    ) {
        self.newlyInitializedWeapons = newlyInitializedWeapons
        self.selectionTransitionCount = selectionTransitionCount
        self.invocations = invocations
        self.failures = failures
    }

    public static let idle = SourceCanonicalWeaponGameplayTickReport()
}

public typealias SourceCanonicalPlayerInfoResolver = (
    _ player: SourceCanonicalEntityIdentity,
    _ name: String
) -> String?

private final class SourceCanonicalWeaponWeakHost: @unchecked Sendable {
    weak var value: (any SourceCanonicalEntityLuaHost)?

    init(_ value: (any SourceCanonicalEntityLuaHost)?) {
        self.value = value
    }
}

private final class SourceCanonicalWeaponWeakRegistry: @unchecked Sendable {
    weak var value: GMLuaEntityRegistry?

    init(_ value: GMLuaEntityRegistry?) {
        self.value = value
    }
}

/// Installs the engine-owned ownership, Player info, drop, aim, and the Entity
/// NetworkVar surface required by original scripted weapons. Ownership is
/// derived from the canonical Player inventory, keeping Creator and Owner as
/// distinct Source concepts without a realm-local mirror.
public enum SourceCanonicalWeaponGameplayBridge {
    public static func install(
        into runtime: GMLuaRuntime,
        host: (any SourceCanonicalEntityLuaHost)? = nil,
        playerInfoResolver: SourceCanonicalPlayerInfoResolver? = nil,
        playerRespawnResolver: SourceCanonicalPlayerRespawnResolver? = nil
    ) throws {
        guard let typeSystem = runtime.typeSystem else {
            throw LuaError.runtime("canonical Weapon gameplay requires the GLua type system")
        }
        guard let registry = runtime.entityRegistry else {
            throw LuaError.runtime("canonical Weapon gameplay requires the Entity registry")
        }
        guard let entityMetatable = typeSystem.metatable(named: "Entity"),
              let playerMetatable = typeSystem.metatable(named: "Player") else {
            throw LuaError.runtime("canonical Weapon gameplay requires Entity/Player metatables")
        }

        let state = runtime.state
        let realm = runtime.realm
        let hostBox = SourceCanonicalWeaponWeakHost(host)
        let registryBox = SourceCanonicalWeaponWeakRegistry(registry)
        let nullValue = state.getGlobal("NULL")

        func native(
            _ name: String,
            _ body: @escaping LuaNativeFunction
        ) -> LuaValue {
            .nativeFunction(LuaNativeFunctionBox(body, debugName: name))
        }

        func isNil(_ value: LuaValue) -> Bool {
            if case .nilValue = value { return true }
            return false
        }

        func requiredSnapshot(
            _ value: LuaValue?,
            function: String,
            kind: SourceCanonicalEntityKind? = nil
        ) throws -> SourceCanonicalEntitySnapshot {
            guard let value,
                  let snapshot = registryBox.value?.canonicalSnapshot(for: value),
                  kind == nil || snapshot.kind == kind else {
                throw LuaError.runtime(
                    "bad self to '\(function)' (canonical \(kind?.rawValue ?? "Entity") expected)"
                )
            }
            return snapshot
        }

        func requiredString(
            _ arguments: [LuaValue],
            index: Int,
            function: String
        ) throws -> String {
            guard arguments.indices.contains(index),
                  case let .string(value) = arguments[index] else {
                throw LuaError.runtime(
                    "bad argument #\(index) to '\(function)' (UTF-8 string expected)"
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

        func ownerValue(
            for weapon: SourceCanonicalEntitySnapshot
        ) -> LuaValue {
            guard let registry = registryBox.value else { return nullValue }
            for player in registry.canonicalEntitySnapshots where player.kind == .player {
                guard player.weaponInventory.weapon(identity: weapon.identity) != nil else {
                    continue
                }
                let value = registry.entity(at: player.identity.entryIndex)
                if registry.canonicalIdentity(for: value) == player.identity {
                    return value
                }
            }
            return nullValue
        }

        try state.setRawTableValue(
            native("Entity:GetOwner") { arguments in
                let snapshot = try requiredSnapshot(
                    arguments.first,
                    function: "Entity:GetOwner"
                )
                guard snapshot.kind == .weapon else { return [nullValue] }
                return [ownerValue(for: snapshot)]
            },
            for: .string("GetOwner"),
            in: entityMetatable
        )

        try state.setRawTableValue(
            native("Player:EyePos") { arguments in
                let player = try requiredSnapshot(
                    arguments.first,
                    function: "Player:EyePos",
                    kind: .player
                )
                return [try vector(player.transform.origin + player.viewOffset)]
            },
            for: .string("EyePos"),
            in: playerMetatable
        )
        try state.setRawTableValue(
            native("Player:GetAimVector") { arguments in
                let player = try requiredSnapshot(
                    arguments.first,
                    function: "Player:GetAimVector",
                    kind: .player
                )
                return [try vector(player.transform.angles.sourceBasis.forward)]
            },
            for: .string("GetAimVector"),
            in: playerMetatable
        )
        try state.setRawTableValue(
            native("Player:GetInfo") { arguments in
                let player = try requiredSnapshot(
                    arguments.first,
                    function: "Player:GetInfo",
                    kind: .player
                )
                let name = try requiredString(
                    arguments,
                    index: 1,
                    function: "Player:GetInfo"
                )
                return [.string(LuaString(
                    playerInfoResolver?(player.identity, name) ?? ""
                ))]
            },
            for: .string("GetInfo"),
            in: playerMetatable
        )
        try state.setRawTableValue(
            native("Player:GetInfoNum") { arguments in
                let player = try requiredSnapshot(
                    arguments.first,
                    function: "Player:GetInfoNum",
                    kind: .player
                )
                let name = try requiredString(
                    arguments,
                    index: 1,
                    function: "Player:GetInfoNum"
                )
                let defaultValue: Double
                if arguments.indices.contains(2),
                   case let .number(number) = arguments[2], number.isFinite {
                    defaultValue = number
                } else {
                    defaultValue = 0
                }
                guard let raw = playerInfoResolver?(player.identity, name),
                      let number = Double(raw), number.isFinite else {
                    return [.number(defaultValue)]
                }
                return [.number(number)]
            },
            for: .string("GetInfoNum"),
            in: playerMetatable
        )

        try state.setRawTableValue(
            native("Entity:NetworkVar") { arguments in
                _ = try requiredSnapshot(
                    arguments.first,
                    function: "Entity:NetworkVar",
                    kind: .weapon
                )
                let typeName = try requiredString(
                    arguments,
                    index: 1,
                    function: "Entity:NetworkVar"
                )
                guard ["Entity", "Float", "Int"].contains(typeName) else {
                    throw LuaError.runtime(
                        "Entity:NetworkVar type '\(typeName)' is not implemented; canonical Entity, Float, or Int expected"
                    )
                }
                guard arguments.indices.contains(2),
                      case let .number(rawSlot) = arguments[2],
                      rawSlot.isFinite,
                      rawSlot.rounded(.towardZero) == rawSlot,
                      rawSlot >= 0, rawSlot < 32 else {
                    throw LuaError.runtime(
                        "bad argument #2 to 'Entity:NetworkVar' (slot 0..31 expected)"
                    )
                }
                let slot = Int(rawSlot)
                let name = try requiredString(
                    arguments,
                    index: 3,
                    function: "Entity:NetworkVar"
                )
                guard !name.isEmpty,
                      name.unicodeScalars.allSatisfy({
                        CharacterSet.alphanumerics.contains($0) || $0 == "_"
                      }) else {
                    throw LuaError.runtime(
                        "bad argument #3 to 'Entity:NetworkVar' (identifier expected)"
                    )
                }
                if arguments.indices.contains(4),
                   case .nilValue = arguments[4] {
                    // A literal nil is identical to omitting extended metadata.
                } else if arguments.indices.contains(4) {
                    throw LuaError.runtime(
                        "Entity:NetworkVar extended metadata is not implemented"
                    )
                }
                guard let registry = registryBox.value,
                      let table = registry.luaTable(for: arguments[0]) else {
                    throw LuaError.runtime("Entity:NetworkVar Weapon table is unavailable")
                }
                let getter = native("Entity:Get\(name)") { getterArguments in
                    let current = try requiredSnapshot(
                        getterArguments.first,
                        function: "Entity:Get\(name)",
                        kind: .weapon
                    )
                    switch typeName {
                    case "Float":
                        let value = current.weaponRuntime.floatNetworkVariables
                            .indices.contains(slot)
                            ? current.weaponRuntime.floatNetworkVariables[slot]
                            : nil
                        return [.number(Double(value ?? 0))]
                    case "Int":
                        let value = current.weaponRuntime.intNetworkVariables
                            .indices.contains(slot)
                            ? current.weaponRuntime.intNetworkVariables[slot]
                            : nil
                        return [.number(Double(value ?? 0))]
                    case "Entity":
                        guard current.weaponEntityNetworkVariables.indices
                            .contains(slot),
                              let identity = current
                                .weaponEntityNetworkVariables[slot],
                              let currentRegistry = registryBox.value else {
                            return [nullValue]
                        }
                        let value = currentRegistry.entity(
                            at: identity.entryIndex
                        )
                        guard currentRegistry.canonicalIdentity(for: value)
                            == identity else { return [nullValue] }
                        return [value]
                    default:
                        preconditionFailure("validated NetworkVar type")
                    }
                }
                let setter = native("Entity:Set\(name)") { setterArguments in
                    guard realm == .server, let host = hostBox.value else {
                        throw LuaError.runtime("Entity:Set\(name) requires SERVER authority")
                    }
                    let current = try requiredSnapshot(
                        setterArguments.first,
                        function: "Entity:Set\(name)",
                        kind: .weapon
                    )
                    guard setterArguments.indices.contains(1) else {
                        throw LuaError.runtime(
                            "bad argument #1 to 'Set\(name)' (\(typeName) expected)"
                        )
                    }
                    switch typeName {
                    case "Float":
                        guard case let .number(raw) = setterArguments[1],
                              raw.isFinite,
                              abs(raw) <= Double(Float.greatestFiniteMagnitude)
                        else {
                            throw LuaError.runtime(
                                "bad argument #1 to 'Set\(name)' (finite Source Float expected)"
                            )
                        }
                        _ = try host.updateCanonicalEntity(current.identity) {
                            if $0.weaponRuntime.floatNetworkVariables.count
                                <= slot {
                                $0.weaponRuntime.floatNetworkVariables.append(
                                    contentsOf: Array<Float?>(
                                        repeating: nil,
                                        count: slot + 1 - $0.weaponRuntime
                                            .floatNetworkVariables.count
                                    )
                                )
                            }
                            $0.weaponRuntime.floatNetworkVariables[slot] =
                                Float(raw)
                        }
                    case "Int":
                        guard case let .number(raw) = setterArguments[1],
                              raw.isFinite,
                              raw.rounded(.towardZero) == raw,
                              let value = Int32(exactly: raw) else {
                            throw LuaError.runtime(
                                "bad argument #1 to 'Set\(name)' (32-bit integer expected)"
                            )
                        }
                        _ = try host.updateCanonicalEntity(current.identity) {
                            if $0.weaponRuntime.intNetworkVariables.count
                                <= slot {
                                $0.weaponRuntime.intNetworkVariables.append(
                                    contentsOf: Array<Int32?>(
                                        repeating: nil,
                                        count: slot + 1 - $0.weaponRuntime
                                            .intNetworkVariables.count
                                    )
                                )
                            }
                            $0.weaponRuntime.intNetworkVariables[slot] = value
                        }
                    case "Entity":
                        let identity: SourceCanonicalEntityIdentity?
                        if isNil(setterArguments[1]) {
                            identity = nil
                        } else if let currentRegistry = registryBox.value,
                                  let resolved = currentRegistry
                                    .canonicalIdentity(for: setterArguments[1]) {
                            identity = resolved
                        } else if let object = GMLuaTypeSystem.typedObject(
                            from: setterArguments[1]
                        ), !object.isValid {
                            identity = nil
                        } else {
                            throw LuaError.runtime(
                                "bad argument #1 to 'Set\(name)' (canonical Entity expected)"
                            )
                        }
                        _ = try host.updateCanonicalEntity(current.identity) {
                            if $0.weaponEntityNetworkVariables.count <= slot {
                                $0.weaponEntityNetworkVariables.append(
                                    contentsOf: Array<SourceCanonicalEntityIdentity?>(
                                        repeating: nil,
                                        count: slot + 1 - $0
                                            .weaponEntityNetworkVariables.count
                                    )
                                )
                            }
                            $0.weaponEntityNetworkVariables[slot] = identity
                        }
                    default:
                        preconditionFailure("validated NetworkVar type")
                    }
                    return []
                }
                try state.setRawTableValue(
                    getter,
                    for: .string(LuaString("Get\(name)")),
                    in: table
                )
                try state.setRawTableValue(
                    setter,
                    for: .string(LuaString("Set\(name)")),
                    in: table
                )
                // Re-declaring the same accessor pair is idempotent. Values
                // remain in the authoritative type-specific slot arrays.
                return []
            },
            for: .string("NetworkVar"),
            in: entityMetatable
        )

        try state.setRawTableValue(
            native("Player:DropWeapon") { arguments in
                guard realm == .server, let host = hostBox.value else {
                    throw LuaError.runtime("Player:DropWeapon requires SERVER authority")
                }
                let player = try requiredSnapshot(
                    arguments.first,
                    function: "Player:DropWeapon",
                    kind: .player
                )
                guard arguments.indices.contains(1),
                      let registry = registryBox.value,
                      let weaponIdentity = registry.canonicalIdentity(
                        for: arguments[1]
                      ),
                      let record = player.weaponInventory.weapon(
                        identity: weaponIdentity
                      ),
                      let weapon = host.canonicalSnapshot(for: weaponIdentity),
                      weapon.kind == .weapon else { return [] }

                let target: SourceVector3
                if arguments.indices.contains(2),
                   !isNil(arguments[2]) {
                    target = try sourceVector(
                        arguments[2],
                        function: "Player:DropWeapon target"
                    )
                } else {
                    target = player.transform.origin + player.viewOffset
                }
                let velocity: SourceVector3
                if arguments.indices.contains(3),
                   !isNil(arguments[3]) {
                    velocity = try sourceVector(
                        arguments[3],
                        function: "Player:DropWeapon velocity"
                    )
                } else {
                    velocity = player.motion.linearVelocity
                }

                _ = try host.updateCanonicalEntity(weapon.identity) { candidate in
                    candidate.transform.origin = target
                    candidate.transform.angles = player.transform.angles
                    candidate.motion.linearVelocity = velocity
                }
                _ = try host.updateCanonicalEntity(player.identity) { candidate in
                    guard candidate.weaponInventory.remove(
                        identity: weaponIdentity
                    ) != nil else {
                        throw SourceCanonicalEntityError.invalidWeaponInventory(
                            "DropWeapon lost owned EHANDLE during transaction"
                        )
                    }
                }

                if let table = registry.luaTable(for: arguments[1]) {
                    let onDrop = try state.rawTableValue(
                        for: .string("OnDrop"),
                        in: table
                    )
                    switch onDrop {
                    case .nilValue:
                        break
                    case .luaFunction, .nativeFunction:
                        _ = try state.call(onDrop, arguments: [arguments[1]])
                    default:
                        throw LuaError.runtime(
                            "\(record.className).OnDrop is not callable"
                        )
                    }
                }
                return []
            },
            for: .string("DropWeapon"),
            in: playerMetatable
        )

        try SourceCanonicalWeaponCombatBridge.install(
            into: runtime,
            host: host
        )
        if runtime.realm == .server, let host {
            try SourceCanonicalPlayerLifecycleGLuaBridge.install(
                into: runtime,
                host: host,
                respawnResolver: playerRespawnResolver
            )
        }
        try SourceCanonicalWeaponReloadBridge.install(
            into: runtime,
            host: host
        )
        runtime.fireBulletsBridge = try
            SourceCanonicalFireBulletsGLuaBridge.install(
                into: runtime,
                host: host
            )
    }
}

/// Resolves original `weapons.Get` tables into canonical Weapon userdata and
/// runs their SERVER lifecycle/actions from host input. This controller owns
/// only dispatch bookkeeping; inventory, active selection, NetworkVar values,
/// and drop placement remain canonical engine state.
public final class SourceCanonicalWeaponGameplayController {
    private let runtime: GMLuaRuntime
    private weak var host: (any SourceCanonicalEntityLuaHost)?
    private var initialized: Set<SourceCanonicalEntityIdentity> = []
    private var permanentlyFailed: Set<SourceCanonicalEntityIdentity> = []
    private var activeWeaponByPlayer:
        [SourceCanonicalEntityIdentity: SourceCanonicalEntityIdentity] = [:]

    public init(
        runtime: GMLuaRuntime,
        host: any SourceCanonicalEntityLuaHost
    ) {
        precondition(runtime.realm == .server)
        self.runtime = runtime
        self.host = host
    }

    /// Dispatches the same native `Player:DropWeapon` surface used by SERVER
    /// Lua for the current full-EHANDLE active Weapon. This keeps touch hosts
    /// out of Lua internals while preserving the original callback path.
    @discardableResult
    public func dropActiveWeapon(
        playerIdentity: SourceCanonicalEntityIdentity
    ) throws -> Bool {
        guard let host,
              let player = host.canonicalSnapshot(for: playerIdentity),
              player.kind == .player,
              let weaponIdentity = player.weaponInventory.activeWeapon,
              let weapon = host.canonicalSnapshot(for: weaponIdentity),
              weapon.kind == .weapon,
              let registry = runtime.entityRegistry,
              let typeSystem = runtime.typeSystem,
              let playerMetatable = typeSystem.metatable(named: "Player") else {
            return false
        }
        let playerValue = registry.entity(at: player.identity.entryIndex)
        let weaponValue = registry.entity(at: weapon.identity.entryIndex)
        guard registry.canonicalIdentity(for: playerValue) == player.identity,
              registry.canonicalIdentity(for: weaponValue) == weapon.identity else {
            return false
        }
        let drop = try runtime.state.rawTableValue(
            for: .string("DropWeapon"),
            in: playerMetatable
        )
        _ = try runtime.state.call(
            drop,
            arguments: [playerValue, weaponValue]
        )
        return true
    }

    public func runServerTick(
        playerIdentity: SourceCanonicalEntityIdentity
    ) -> SourceCanonicalWeaponGameplayTickReport {
        guard let host,
              let registry = runtime.entityRegistry,
              let player = host.canonicalSnapshot(for: playerIdentity),
              player.kind == .player else {
            return .idle
        }

        var newlyInitialized: [SourceCanonicalEntityIdentity] = []
        var invocations: [SourceCanonicalWeaponInvocationRecord] = []
        var failures: [SourceCanonicalWeaponInvocationFailure] = []

        func record(
            _ weapon: SourceCanonicalEntitySnapshot,
            _ invocation: SourceCanonicalWeaponInvocation
        ) {
            invocations.append(SourceCanonicalWeaponInvocationRecord(
                weapon: weapon.identity,
                className: weapon.className,
                invocation: invocation
            ))
        }
        func recordFailure(
            _ weapon: SourceCanonicalEntitySnapshot,
            _ invocation: SourceCanonicalWeaponInvocation,
            _ error: Error
        ) {
            failures.append(SourceCanonicalWeaponInvocationFailure(
                weapon: weapon.identity,
                className: weapon.className,
                invocation: invocation,
                message: GMLuaRuntime.describe(error)
            ))
        }

        func weaponValue(
            _ weapon: SourceCanonicalEntitySnapshot
        ) -> LuaValue? {
            let value = registry.entity(at: weapon.identity.entryIndex)
            guard registry.canonicalIdentity(for: value) == weapon.identity else {
                return nil
            }
            return value
        }

        func call(
            _ invocation: SourceCanonicalWeaponInvocation,
            on weapon: SourceCanonicalEntitySnapshot,
            arguments: [LuaValue] = []
        ) throws -> Bool {
            guard let value = weaponValue(weapon),
                  let table = registry.luaTable(for: value) else {
                throw LuaError.runtime(
                    "\(weapon.className) canonical Weapon userdata is unavailable"
                )
            }
            let method = try runtime.state.rawTableValue(
                for: .string(LuaString(invocation.luaMethodName)),
                in: table
            )
            switch method {
            case .nilValue:
                return false
            case .luaFunction, .nativeFunction:
                record(weapon, invocation)
                _ = try runtime.state.call(method, arguments: [value] + arguments)
                return true
            default:
                throw LuaError.runtime(
                    "\(weapon.className).\(invocation.luaMethodName) is not callable"
                )
            }
        }

        func initializeWeapon(
            _ weapon: SourceCanonicalEntitySnapshot,
            playerValue: LuaValue
        ) {
            guard !initialized.contains(weapon.identity),
                  !permanentlyFailed.contains(weapon.identity) else { return }
            guard let value = weaponValue(weapon) else {
                permanentlyFailed.insert(weapon.identity)
                recordFailure(
                    weapon,
                    .initialize,
                    LuaError.runtime("canonical Weapon userdata is unavailable")
                )
                return
            }
            do {
                guard case let .table(weapons) = runtime.state.getGlobal("weapons") else {
                    throw LuaError.runtime("weapons library is unavailable")
                }
                let get = try runtime.state.rawTableValue(
                    for: .string("Get"),
                    in: weapons
                )
                let resolved = try runtime.state.call(
                    get,
                    arguments: [.string(LuaString(weapon.className))]
                ).first ?? .nilValue
                guard case let .table(table) = resolved else {
                    throw LuaError.runtime(
                        "weapons.Get('\(weapon.className)') returned \(resolved.typeName)"
                    )
                }
                // Assign only the SWEP-authored third-person model accepted by
                // the canonical filesystem/Studio validator. Missing or
                // unavailable assets remain an explicit no-model state.
                if weapon.model == nil,
                   let definition = try? runtime
                       .scriptedWeaponRenderDefinition(
                           className: weapon.className,
                           resolvedTable: table
                       ),
                   let worldModel = definition.worldModel,
                   host.validateCanonicalModel(
                       worldModel,
                       for: .weapon
                   ) == .valid {
                    _ = try host.updateCanonicalEntity(
                        weapon.identity
                    ) { candidate in
                        if candidate.model == nil {
                            candidate.model = worldModel
                        }
                    }
                }
                guard registry.replaceLuaTable(for: value, with: table) else {
                    throw LuaError.runtime("canonical Weapon table replacement failed")
                }
                let primaryClip = try defaultClip(
                    named: "Primary",
                    in: table
                )
                let secondaryClip = try defaultClip(
                    named: "Secondary",
                    in: table
                )
                _ = try host.updateCanonicalEntity(weapon.identity) {
                    $0.weaponRuntime.clip1 = primaryClip
                    $0.weaponRuntime.clip2 = secondaryClip
                }
                _ = try call(.setupDataTables, on: weapon)
                _ = try call(.initialize, on: weapon)
                _ = try call(.equip, on: weapon, arguments: [playerValue])
                initialized.insert(weapon.identity)
                newlyInitialized.append(weapon.identity)
            } catch {
                permanentlyFailed.insert(weapon.identity)
                let phase = invocations.last(where: {
                    $0.weapon == weapon.identity
                })?.invocation ?? .initialize
                recordFailure(weapon, phase, error)
            }
        }

        let playerValue = registry.entity(at: player.identity.entryIndex)
        guard registry.canonicalIdentity(for: playerValue) == player.identity else {
            return .idle
        }
        for record in player.weaponInventory.weapons {
            guard let weapon = host.canonicalSnapshot(for: record.identity),
                  weapon.kind == .weapon else { continue }
            initializeWeapon(weapon, playerValue: playerValue)
        }

        let previousActive = activeWeaponByPlayer[player.identity]
        let currentActive = player.weaponInventory.activeWeapon
        var transitionCount = 0
        if previousActive != currentActive {
            if let previousActive,
               let oldWeapon = host.canonicalSnapshot(for: previousActive),
               initialized.contains(previousActive) {
                do {
                    let newValue = currentActive.flatMap {
                        host.canonicalSnapshot(for: $0)
                    }.flatMap(weaponValue)
                    _ = try call(
                        .holster,
                        on: oldWeapon,
                        arguments: newValue.map { [$0] } ?? []
                    )
                } catch {
                    recordFailure(oldWeapon, .holster, error)
                }
            }
            if let currentActive,
               let newWeapon = host.canonicalSnapshot(for: currentActive),
               initialized.contains(currentActive) {
                do {
                    _ = try call(.deploy, on: newWeapon)
                } catch {
                    recordFailure(newWeapon, .deploy, error)
                }
            }
            if let currentActive {
                activeWeaponByPlayer[player.identity] = currentActive
            } else {
                activeWeaponByPlayer.removeValue(forKey: player.identity)
            }
            transitionCount = 1
        }

        guard let currentActive,
              let activeWeapon = host.canonicalSnapshot(for: currentActive),
              initialized.contains(currentActive) else {
            return SourceCanonicalWeaponGameplayTickReport(
                newlyInitializedWeapons: newlyInitialized,
                selectionTransitionCount: transitionCount,
                invocations: invocations,
                failures: failures
            )
        }

        do {
            _ = try call(.think, on: activeWeapon)
        } catch {
            recordFailure(activeWeapon, .think, error)
        }
        do {
            _ = try call(.tick, on: activeWeapon)
        } catch {
            recordFailure(activeWeapon, .tick, error)
        }

        let buttons = registry.playerInputButtonState(for: playerValue) ?? (
            current: SourceInputButtons(),
            previous: SourceInputButtons()
        )
        let current = buttons.current
        let previous = buttons.previous
        let actionInputs: [(
            SourceCanonicalWeaponInvocation,
            SourceInputButtons,
            Bool
        )] = [
            (.primaryAttack, .attack, automatic(
                named: "Primary",
                on: activeWeapon,
                registry: registry
            )),
            (.secondaryAttack, .attack2, automatic(
                named: "Secondary",
                on: activeWeapon,
                registry: registry
            )),
            (.reload, .reload, false),
        ]
        for (invocation, button, isAutomatic) in actionInputs {
            let isDown = current.contains(button)
            let wasDown = previous.contains(button)
            guard isDown && (isAutomatic || !wasDown) else { continue }
            guard let currentWeapon = host.canonicalSnapshot(
                for: activeWeapon.identity
            ) else { continue }
            let currentTime = Float(runtime.timerScheduler?.currentTime ?? 0)
            if invocation == .primaryAttack,
               currentTime < currentWeapon.weaponRuntime.nextPrimaryFire {
                continue
            }
            if invocation == .secondaryAttack,
               currentTime < currentWeapon.weaponRuntime.nextSecondaryFire {
                continue
            }
            if invocation == .reload,
               currentTime < max(
                   currentWeapon.weaponRuntime.nextPrimaryFire,
                   currentWeapon.weaponRuntime.nextSecondaryFire
               ) {
                continue
            }
            do {
                _ = try call(invocation, on: currentWeapon)
            } catch {
                recordFailure(currentWeapon, invocation, error)
            }
        }

        return SourceCanonicalWeaponGameplayTickReport(
            newlyInitializedWeapons: newlyInitialized,
            selectionTransitionCount: transitionCount,
            invocations: invocations,
            failures: failures
        )
    }

    private func automatic(
        named name: String,
        on weapon: SourceCanonicalEntitySnapshot,
        registry: GMLuaEntityRegistry
    ) -> Bool {
        let value = registry.entity(at: weapon.identity.entryIndex)
        guard registry.canonicalIdentity(for: value) == weapon.identity,
              let weaponTable = registry.luaTable(for: value) else {
            return false
        }
        do {
            guard case let .table(actionTable) = try runtime.state.rawTableValue(
                for: .string(LuaString(name)),
                in: weaponTable
            ), case let .boolean(automatic) = try runtime.state.rawTableValue(
                for: .string("Automatic"),
                in: actionTable
            ) else { return false }
            return automatic
        } catch {
            return false
        }
    }

    private func defaultClip(
        named action: String,
        in weaponTable: LuaTable
    ) throws -> Int32 {
        guard case let .table(actionTable) = try runtime.state.rawTableValue(
            for: .string(LuaString(action)),
            in: weaponTable
        ) else {
            throw LuaError.runtime(
                "canonical Weapon \(action) definition is unavailable"
            )
        }
        let raw = try runtime.state.rawTableValue(
            for: .string("DefaultClip"),
            in: actionTable
        )
        guard case let .number(number) = raw,
              number.isFinite,
              number.rounded(.towardZero) == number,
              let value = Int32(exactly: number) else {
            throw LuaError.runtime(
                "canonical Weapon \(action).DefaultClip must be a 32-bit integer"
            )
        }
        return value
    }
}

private extension SourceCanonicalWeaponInvocation {
    var luaMethodName: String {
        switch self {
        case .setupDataTables: return "SetupDataTables"
        case .initialize: return "Initialize"
        case .equip: return "Equip"
        case .holster: return "Holster"
        case .deploy: return "Deploy"
        case .think: return "Think"
        case .tick: return "Tick"
        case .primaryAttack: return "PrimaryAttack"
        case .secondaryAttack: return "SecondaryAttack"
        case .reload: return "Reload"
        }
    }
}
