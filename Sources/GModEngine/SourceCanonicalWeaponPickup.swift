import Foundation
import GModLua

/// The engine path which asked an unowned world Weapon to enter a Player's
/// inventory. Natural touch and +use pickup remain permission-gated; the
/// explicit Player:PickupWeapon API follows Garry's Mod and bypasses that gate.
public enum SourceCanonicalWeaponPickupTrigger: String, Equatable, Sendable {
    case contact
    case use
    case forcedPlayerAPI
}

public enum SourceCanonicalWeaponPickupCallback: String, Equatable, Sendable {
    case playerUse = "PlayerUse"
    case playerCanPickupWeapon = "PlayerCanPickupWeapon"
    case weaponEquip = "WeaponEquip"
    case scriptedEquip = "WEAPON:Equip"
}

public struct SourceCanonicalWeaponPickupCallbackFailure:
    Error,
    Equatable,
    Sendable
{
    public let callback: SourceCanonicalWeaponPickupCallback
    public let message: String

    public init(
        callback: SourceCanonicalWeaponPickupCallback,
        message: String
    ) {
        self.callback = callback
        self.message = message
    }
}

public enum SourceCanonicalWeaponPickupDisposition: Equatable, Sendable {
    case pickedUp
    case deniedByPlayerUse
    case deniedByPlayerCanPickupWeapon
    case invalidPlayer
    case invalidWeapon
    case unavailableWeaponLifecycle(SourceCanonicalEntityLifecycle)
    case alreadyOwned(SourceCanonicalEntityIdentity)
    case duplicateWeaponClass(SourceCanonicalEntityIdentity)
    case missingWorldModel
    case invalidWorldModel(SourceEntityModelReference)
    case worldModelValidationUnavailable(SourceEntityModelReference)
    case staleRealmMirror(SourceCanonicalEntityIdentity)
    case permissionCallbackFailed(SourceCanonicalWeaponPickupCallback)
}

public struct SourceCanonicalWeaponPickupAttempt: Equatable, Sendable {
    public let player: SourceCanonicalEntityIdentity
    public let weapon: SourceCanonicalEntityIdentity
    public let trigger: SourceCanonicalWeaponPickupTrigger
    public let disposition: SourceCanonicalWeaponPickupDisposition
    public let callbackFailures: [SourceCanonicalWeaponPickupCallbackFailure]

    public init(
        player: SourceCanonicalEntityIdentity,
        weapon: SourceCanonicalEntityIdentity,
        trigger: SourceCanonicalWeaponPickupTrigger,
        disposition: SourceCanonicalWeaponPickupDisposition,
        callbackFailures: [SourceCanonicalWeaponPickupCallbackFailure] = []
    ) {
        self.player = player
        self.weapon = weapon
        self.trigger = trigger
        self.disposition = disposition
        self.callbackFailures = callbackFailures
    }
}

public struct SourceCanonicalWeaponPickupTickReport: Equatable, Sendable {
    public let attempts: [SourceCanonicalWeaponPickupAttempt]

    public init(attempts: [SourceCanonicalWeaponPickupAttempt] = []) {
        self.attempts = attempts
    }

    public static let idle = Self()
}

public enum SourceCanonicalWeaponPickupError:
    Error,
    Equatable,
    Sendable,
    CustomStringConvertible
{
    case serverRuntimeRequired(GMLuaRealm)
    case runtimeClosed
    case entityRegistryUnavailable
    case hookTableUnavailable(actualType: String)
    case hookCallUnavailable(actualType: String)
    case gamemodeUnavailable(actualType: String)
    case invalidPermissionResult(
        callback: SourceCanonicalWeaponPickupCallback,
        actualType: String
    )

    public var description: String {
        switch self {
        case let .serverRuntimeRequired(realm):
            return "canonical Weapon pickup requires SERVER, got \(realm.rawValue)"
        case .runtimeClosed:
            return "canonical Weapon pickup runtime is closed"
        case .entityRegistryUnavailable:
            return "canonical Weapon pickup requires the SERVER Entity registry"
        case let .hookTableUnavailable(actualType):
            return "canonical Weapon pickup global hook is \(actualType), expected table"
        case let .hookCallUnavailable(actualType):
            return "canonical Weapon pickup hook.Call is \(actualType), expected function"
        case let .gamemodeUnavailable(actualType):
            return "canonical Weapon pickup GAMEMODE is \(actualType), expected table"
        case let .invalidPermissionResult(callback, actualType):
            return "canonical Weapon pickup \(callback.rawValue) returned \(actualType), expected boolean or nil"
        }
    }
}

/// SERVER-owned pickup coordinator. Candidate selection is intentionally an
/// input: contact pairs must come from authoritative collision and +use targets
/// from an authoritative trace, never from render bounds or a guessed radius.
public final class SourceCanonicalWeaponPickupController: @unchecked Sendable {
    private let runtime: GMLuaRuntime
    private weak var host: (any SourceCanonicalEntityLuaHost)?

    public init(
        runtime: GMLuaRuntime,
        host: any SourceCanonicalEntityLuaHost
    ) {
        precondition(runtime.realm == .server)
        self.runtime = runtime
        self.host = host
    }

    /// Processes authoritative fixed-tick contact pairs and an optional +use
    /// target. Contact order is normalized by the complete packed EHANDLE so
    /// replay does not depend on broadphase collection order. A +use target is
    /// attempted only on Source's KeyPressed edge.
    public func runServerTick(
        playerIdentity: SourceCanonicalEntityIdentity,
        contactCandidates: [SourceCanonicalEntityIdentity],
        useTarget: SourceCanonicalEntityIdentity?
    ) throws -> SourceCanonicalWeaponPickupTickReport {
        let registry = try requiredRegistry()
        let playerValue = registry.player(at: playerIdentity.entryIndex)
        guard registry.canonicalIdentity(for: playerValue) == playerIdentity else {
            return .idle
        }
        let buttons = registry.playerInputButtonState(for: playerValue) ?? (
            current: SourceInputButtons(),
            previous: SourceInputButtons()
        )
        let pressedUse = buttons.current.contains(.use) &&
            !buttons.previous.contains(.use)

        var requests: [(
            SourceCanonicalEntityIdentity,
            SourceCanonicalWeaponPickupTrigger
        )] = []
        if pressedUse, let useTarget {
            requests.append((useTarget, .use))
        }
        let contacts = Array(Set(contactCandidates)).sorted {
            $0.handle.rawValue < $1.handle.rawValue
        }
        for contact in contacts where !requests.contains(where: {
            $0.0 == contact
        }) {
            requests.append((contact, .contact))
        }

        var attempts: [SourceCanonicalWeaponPickupAttempt] = []
        attempts.reserveCapacity(requests.count)
        for (weapon, trigger) in requests {
            attempts.append(try attemptPickup(
                playerIdentity: playerIdentity,
                weaponIdentity: weapon,
                trigger: trigger
            ))
        }
        return SourceCanonicalWeaponPickupTickReport(attempts: attempts)
    }

    /// Attempts to move the exact existing world Weapon EHANDLE into the
    /// Player inventory. The Weapon's clips, NetworkVars, cooldowns, model,
    /// transform, and creation identity are not reconstructed or replaced.
    public func attemptPickup(
        playerIdentity: SourceCanonicalEntityIdentity,
        weaponIdentity: SourceCanonicalEntityIdentity,
        trigger: SourceCanonicalWeaponPickupTrigger
    ) throws -> SourceCanonicalWeaponPickupAttempt {
        guard runtime.realm == .server else {
            throw SourceCanonicalWeaponPickupError
                .serverRuntimeRequired(runtime.realm)
        }
        guard !runtime.isClosed else {
            throw SourceCanonicalWeaponPickupError.runtimeClosed
        }
        guard let host else {
            return attempt(
                playerIdentity,
                weaponIdentity,
                trigger,
                .invalidPlayer
            )
        }
        guard let player = host.canonicalSnapshot(for: playerIdentity),
              player.kind == .player,
              player.lifecycle == .spawned || player.lifecycle == .active else {
            return attempt(
                playerIdentity,
                weaponIdentity,
                trigger,
                .invalidPlayer
            )
        }
        guard let weapon = host.canonicalSnapshot(for: weaponIdentity),
              weapon.kind == .weapon else {
            return attempt(
                playerIdentity,
                weaponIdentity,
                trigger,
                .invalidWeapon
            )
        }
        guard weapon.lifecycle == .spawned || weapon.lifecycle == .active else {
            return attempt(
                playerIdentity,
                weaponIdentity,
                trigger,
                .unavailableWeaponLifecycle(weapon.lifecycle)
            )
        }

        let registry = try requiredRegistry()
        let playerValue = registry.player(at: player.identity.entryIndex)
        let weaponValue = registry.entity(at: weapon.identity.entryIndex)
        guard registry.canonicalIdentity(for: playerValue) == player.identity else {
            return attempt(
                playerIdentity,
                weaponIdentity,
                trigger,
                .staleRealmMirror(player.identity)
            )
        }
        guard registry.canonicalIdentity(for: weaponValue) == weapon.identity else {
            return attempt(
                playerIdentity,
                weaponIdentity,
                trigger,
                .staleRealmMirror(weapon.identity)
            )
        }

        if let owner = registry.canonicalEntitySnapshots.first(where: {
            $0.kind == .player &&
                $0.weaponInventory.weapon(identity: weapon.identity) != nil
        }) {
            return attempt(
                playerIdentity,
                weaponIdentity,
                trigger,
                .alreadyOwned(owner.identity)
            )
        }
        guard let model = weapon.model else {
            return attempt(
                playerIdentity,
                weaponIdentity,
                trigger,
                .missingWorldModel
            )
        }
        switch host.validateCanonicalModel(model, for: .weapon) {
        case .valid:
            break
        case .invalid:
            return attempt(
                playerIdentity,
                weaponIdentity,
                trigger,
                .invalidWorldModel(model)
            )
        case .unavailable:
            return attempt(
                playerIdentity,
                weaponIdentity,
                trigger,
                .worldModelValidationUnavailable(model)
            )
        }

        if trigger == .use {
            let usePermission = permission(
                callback: .playerUse,
                player: playerValue,
                weapon: weaponValue
            )
            switch usePermission {
            case .success(false):
                return attempt(
                    playerIdentity,
                    weaponIdentity,
                    trigger,
                    .deniedByPlayerUse
                )
            case .success(true):
                break
            case let .failure(failure):
                return attempt(
                    playerIdentity,
                    weaponIdentity,
                    trigger,
                    .permissionCallbackFailed(.playerUse),
                    failures: [failure]
                )
            }
        }
        if trigger != .forcedPlayerAPI {
            let pickupPermission = permission(
                callback: .playerCanPickupWeapon,
                player: playerValue,
                weapon: weaponValue
            )
            switch pickupPermission {
            case .success(false):
                return attempt(
                    playerIdentity,
                    weaponIdentity,
                    trigger,
                    .deniedByPlayerCanPickupWeapon
                )
            case .success(true):
                break
            case let .failure(failure):
                return attempt(
                    playerIdentity,
                    weaponIdentity,
                    trigger,
                    .permissionCallbackFailed(.playerCanPickupWeapon),
                    failures: [failure]
                )
            }
        }

        // Permission hooks are allowed to mutate game state. Resolve both full
        // handles and the class collision again before committing ownership.
        guard let currentPlayer = host.canonicalSnapshot(for: player.identity),
              currentPlayer.kind == .player,
              let currentWeapon = host.canonicalSnapshot(for: weapon.identity),
              currentWeapon.kind == .weapon,
              currentWeapon.lifecycle == .spawned ||
                currentWeapon.lifecycle == .active else {
            return attempt(
                playerIdentity,
                weaponIdentity,
                trigger,
                .invalidWeapon
            )
        }
        if let duplicate = currentPlayer.weaponInventory.weapon(
            className: currentWeapon.className
        ) {
            return attempt(
                playerIdentity,
                weaponIdentity,
                trigger,
                .duplicateWeaponClass(duplicate.identity)
            )
        }

        var callbackFailures: [SourceCanonicalWeaponPickupCallbackFailure] = []
        // Garry's Mod exposes the world Weapon to WeaponEquip before its owner
        // becomes observable. This is also where Sandbox detaches spawn undo.
        if let failure = invokeHook(
            callback: .weaponEquip,
            arguments: [weaponValue, playerValue]
        ) {
            callbackFailures.append(failure)
        }

        _ = try host.updateCanonicalEntity(player.identity) { candidate in
            let inserted = candidate.weaponInventory.insert(
                SourceCanonicalWeaponRecord(
                    identity: currentWeapon.identity,
                    className: currentWeapon.className
                )
            )
            guard inserted else {
                throw SourceCanonicalEntityError.invalidWeaponInventory(
                    "pickup lost unique Weapon class or EHANDLE during transaction"
                )
            }
            if candidate.weaponInventory.activeWeapon == nil {
                guard candidate.weaponInventory.select(
                    className: currentWeapon.className
                ) else {
                    throw SourceCanonicalEntityError.invalidWeaponInventory(
                        "picked-up Weapon could not become the empty inventory's active item"
                    )
                }
            }
        }

        // Scripted Equip observes the canonical owner. A Lua failure is
        // reported but does not roll back the already completed engine pickup,
        // matching the engine/Lua error boundary used by ItemPostFrame.
        if let failure = invokeScriptedEquip(
            weaponValue: weaponValue,
            playerValue: playerValue,
            registry: registry
        ) {
            callbackFailures.append(failure)
        }
        return attempt(
            playerIdentity,
            weaponIdentity,
            trigger,
            .pickedUp,
            failures: callbackFailures
        )
    }

    private func requiredRegistry() throws -> GMLuaEntityRegistry {
        guard let registry = runtime.entityRegistry else {
            throw SourceCanonicalWeaponPickupError.entityRegistryUnavailable
        }
        return registry
    }

    private func permission(
        callback: SourceCanonicalWeaponPickupCallback,
        player: LuaValue,
        weapon: LuaValue
    ) -> Result<Bool, SourceCanonicalWeaponPickupCallbackFailure> {
        do {
            let values = try callHook(
                named: callback.rawValue,
                arguments: [player, weapon]
            )
            switch values.first ?? .nilValue {
            case let .boolean(allowed):
                return .success(allowed)
            case .nilValue:
                return .success(true)
            default:
                throw SourceCanonicalWeaponPickupError
                    .invalidPermissionResult(
                        callback: callback,
                        actualType: (values.first ?? .nilValue).typeName
                    )
            }
        } catch {
            return .failure(SourceCanonicalWeaponPickupCallbackFailure(
                callback: callback,
                message: GMLuaRuntime.describe(error)
            ))
        }
    }

    private func invokeHook(
        callback: SourceCanonicalWeaponPickupCallback,
        arguments: [LuaValue]
    ) -> SourceCanonicalWeaponPickupCallbackFailure? {
        do {
            _ = try callHook(named: callback.rawValue, arguments: arguments)
            return nil
        } catch {
            return SourceCanonicalWeaponPickupCallbackFailure(
                callback: callback,
                message: GMLuaRuntime.describe(error)
            )
        }
    }

    private func callHook(
        named name: String,
        arguments: [LuaValue]
    ) throws -> [LuaValue] {
        let state = runtime.state
        let rawHook = state.getGlobal("hook")
        guard case let .table(hook) = rawHook else {
            throw SourceCanonicalWeaponPickupError
                .hookTableUnavailable(actualType: rawHook.typeName)
        }
        let call = try state.rawTableValue(for: .string("Call"), in: hook)
        switch call {
        case .luaFunction, .nativeFunction:
            break
        default:
            throw SourceCanonicalWeaponPickupError
                .hookCallUnavailable(actualType: call.typeName)
        }
        let gamemode = state.getGlobal("GAMEMODE")
        guard case .table = gamemode else {
            throw SourceCanonicalWeaponPickupError
                .gamemodeUnavailable(actualType: gamemode.typeName)
        }
        return try state.call(
            call,
            arguments: [.string(LuaString(name)), gamemode] + arguments
        )
    }

    private func invokeScriptedEquip(
        weaponValue: LuaValue,
        playerValue: LuaValue,
        registry: GMLuaEntityRegistry
    ) -> SourceCanonicalWeaponPickupCallbackFailure? {
        do {
            guard let table = registry.luaTable(for: weaponValue) else {
                throw LuaError.runtime(
                    "picked-up canonical Weapon userdata has no scripted table"
                )
            }
            let equip = try runtime.state.rawTableValue(
                for: .string("Equip"),
                in: table
            )
            switch equip {
            case .nilValue:
                return nil
            case .luaFunction, .nativeFunction:
                _ = try runtime.state.call(
                    equip,
                    arguments: [weaponValue, playerValue]
                )
                return nil
            default:
                throw LuaError.runtime(
                    "picked-up Weapon Equip is \(equip.typeName), expected function"
                )
            }
        } catch {
            return SourceCanonicalWeaponPickupCallbackFailure(
                callback: .scriptedEquip,
                message: GMLuaRuntime.describe(error)
            )
        }
    }

    private func attempt(
        _ player: SourceCanonicalEntityIdentity,
        _ weapon: SourceCanonicalEntityIdentity,
        _ trigger: SourceCanonicalWeaponPickupTrigger,
        _ disposition: SourceCanonicalWeaponPickupDisposition,
        failures: [SourceCanonicalWeaponPickupCallbackFailure] = []
    ) -> SourceCanonicalWeaponPickupAttempt {
        SourceCanonicalWeaponPickupAttempt(
            player: player,
            weapon: weapon,
            trigger: trigger,
            disposition: disposition,
            callbackFailures: failures
        )
    }
}

private final class SourceCanonicalWeaponPickupWeakController:
    @unchecked Sendable
{
    weak var value: SourceCanonicalWeaponPickupController?

    init(_ value: SourceCanonicalWeaponPickupController) {
        self.value = value
    }
}

/// Native Player:PickupWeapon surface. `ammoOnly` requires the Source ammo
/// transfer path and deliberately returns false until such a transfer exists;
/// it never deletes the world Weapon or fabricates ammunition.
public enum SourceCanonicalWeaponPickupGLuaBridge {
    public static func install(
        into runtime: GMLuaRuntime,
        controller: SourceCanonicalWeaponPickupController
    ) throws {
        guard runtime.realm == .server else {
            throw SourceCanonicalWeaponPickupError
                .serverRuntimeRequired(runtime.realm)
        }
        guard let typeSystem = runtime.typeSystem,
              let playerMetatable = typeSystem.metatable(named: "Player"),
              let registry = runtime.entityRegistry else {
            throw LuaError.runtime(
                "Player:PickupWeapon requires Player userdata and Entity registry"
            )
        }
        let box = SourceCanonicalWeaponPickupWeakController(controller)
        let function = LuaValue.nativeFunction(LuaNativeFunctionBox(
            { arguments in
                guard let controller = box.value else {
                    throw LuaError.runtime(
                        "Player:PickupWeapon lost its SERVER controller"
                    )
                }
                guard arguments.indices.contains(0),
                      let player = registry.canonicalSnapshot(for: arguments[0]),
                      player.kind == .player else {
                    throw LuaError.runtime(
                        "bad self to 'PickupWeapon' (canonical Player expected)"
                    )
                }
                guard arguments.indices.contains(1),
                      let weapon = registry.canonicalSnapshot(for: arguments[1]),
                      weapon.kind == .weapon else {
                    throw LuaError.runtime(
                        "bad argument #1 to 'PickupWeapon' (canonical Weapon expected)"
                    )
                }
                let ammoOnly: Bool
                if arguments.indices.contains(2) {
                    switch arguments[2] {
                    case let .boolean(value): ammoOnly = value
                    case .nilValue: ammoOnly = false
                    default:
                        throw LuaError.runtime(
                            "bad argument #2 to 'PickupWeapon' (boolean expected)"
                        )
                    }
                } else {
                    ammoOnly = false
                }
                guard !ammoOnly else { return [.boolean(false)] }
                let result = try controller.attemptPickup(
                    playerIdentity: player.identity,
                    weaponIdentity: weapon.identity,
                    trigger: .forcedPlayerAPI
                )
                return [.boolean(result.disposition == .pickedUp)]
            },
            debugName: "Player:PickupWeapon"
        ))
        try runtime.state.setRawTableValue(
            function,
            for: .string("PickupWeapon"),
            in: playerMetatable
        )
    }
}
