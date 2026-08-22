import Foundation
import GModLua

struct SourceCanonicalWeaponReloadChannel: Equatable, Sendable {
    let clipSize: Int32
    let ammoType: SourceCanonicalDefaultAmmoType?
}

struct SourceCanonicalWeaponReloadPlan: Equatable, Sendable {
    struct Consumption: Equatable, Sendable {
        let ammoType: SourceCanonicalDefaultAmmoType
        let count: Int32
    }

    let primaryClip: Int32
    let secondaryClip: Int32
    let consumptions: [Consumption]

    var didReload: Bool { !consumptions.isEmpty }

    static func make(
        primary: SourceCanonicalWeaponReloadChannel,
        secondary: SourceCanonicalWeaponReloadChannel,
        currentPrimaryClip: Int32,
        currentSecondaryClip: Int32,
        reserveAmmo: SourceCanonicalPlayerAmmoState
    ) throws -> SourceCanonicalWeaponReloadPlan {
        var available = Dictionary(
            uniqueKeysWithValues: reserveAmmo.entries.map {
                ($0.typeID, $0.count)
            }
        )
        var consumptionsByType: [Int32: Int32] = [:]

        func refill(
            channel: SourceCanonicalWeaponReloadChannel,
            currentClip: Int32,
            name: String
        ) throws -> Int32 {
            guard channel.clipSize > 0 else { return currentClip }
            guard currentClip >= 0 else {
                throw LuaError.runtime(
                    "Weapon:\(name) has negative clip state for a clip-backed weapon"
                )
            }
            guard currentClip < channel.clipSize,
                  let ammoType = channel.ammoType else { return currentClip }
            let reserve = available[ammoType.id] ?? 0
            let added = min(channel.clipSize - currentClip, reserve)
            guard added > 0 else { return currentClip }
            available[ammoType.id] = reserve - added
            consumptionsByType[ammoType.id, default: 0] += added
            return currentClip + added
        }

        let primaryClip = try refill(
            channel: primary,
            currentClip: currentPrimaryClip,
            name: "DefaultReload primary"
        )
        let secondaryClip = try refill(
            channel: secondary,
            currentClip: currentSecondaryClip,
            name: "DefaultReload secondary"
        )
        let consumptions = SourceCanonicalDefaultAmmoCatalog.all.compactMap {
            ammoType -> Consumption? in
            guard let count = consumptionsByType[ammoType.id], count > 0 else {
                return nil
            }
            return Consumption(ammoType: ammoType, count: count)
        }
        return SourceCanonicalWeaponReloadPlan(
            primaryClip: primaryClip,
            secondaryClip: secondaryClip,
            consumptions: consumptions
        )
    }
}

private final class SourceCanonicalWeaponReloadWeakHost: @unchecked Sendable {
    weak var value: (any SourceCanonicalEntityLuaHost)?

    init(_ value: (any SourceCanonicalEntityLuaHost)?) {
        self.value = value
    }
}

private final class SourceCanonicalWeaponReloadWeakRegistry: @unchecked Sendable {
    weak var value: GMLuaEntityRegistry?

    init(_ value: GMLuaEntityRegistry?) {
        self.value = value
    }
}

/// Native Weapon reload ABI used by the original `weapon_base` Lua. The
/// original SWEP tables and inherited `Reload` function remain untouched:
/// `IN_RELOAD` reaches that Lua function first, which then calls this native
/// `DefaultReload` surface.
public enum SourceCanonicalWeaponReloadBridge {
    public static func install(
        into runtime: GMLuaRuntime,
        host: (any SourceCanonicalEntityLuaHost)? = nil
    ) throws {
        guard runtime.realm != .menu,
              let typeSystem = runtime.typeSystem,
              let registry = runtime.entityRegistry,
              let weaponMetatable = typeSystem.metatable(named: "Weapon"),
              let playerMetatable = typeSystem.metatable(named: "Player") else {
            throw LuaError.runtime(
                "canonical Weapon reload requires Weapon, Player, and Entity registry surfaces"
            )
        }
        if runtime.realm == .server, host == nil {
            throw LuaError.runtime(
                "canonical Weapon reload requires an authoritative SERVER host"
            )
        }

        let state = runtime.state
        let hostBox = SourceCanonicalWeaponReloadWeakHost(host)
        let registryBox = SourceCanonicalWeaponReloadWeakRegistry(registry)
        let playerReloadAnimation = try requiredGlobalInt32(
            named: "PLAYER_RELOAD",
            state: state
        )

        func native(
            _ name: String,
            _ body: @escaping LuaNativeFunction
        ) -> LuaValue {
            .nativeFunction(LuaNativeFunctionBox(body, debugName: name))
        }

        func setMethod(
            _ name: String,
            on metatable: LuaTable,
            _ body: @escaping LuaNativeFunction
        ) throws {
            try state.setRawTableValue(
                native(name, body),
                for: .string(LuaString(name.split(separator: ":").last.map(String.init) ?? name)),
                in: metatable
            )
        }

        func weaponSnapshot(
            _ value: LuaValue?,
            function: String
        ) throws -> SourceCanonicalEntitySnapshot {
            guard let value,
                  let snapshot = registryBox.value?.canonicalSnapshot(for: value),
                  snapshot.kind == .weapon else {
                throw LuaError.runtime(
                    "bad self to '\(function)' (canonical Weapon expected)"
                )
            }
            return snapshot
        }

        func playerSnapshot(
            _ value: LuaValue?,
            function: String
        ) throws -> SourceCanonicalEntitySnapshot {
            guard let value,
                  let snapshot = registryBox.value?.canonicalSnapshot(for: value),
                  snapshot.kind == .player else {
                throw LuaError.runtime(
                    "bad self to '\(function)' (canonical Player expected)"
                )
            }
            return snapshot
        }

        func weaponTable(
            _ arguments: [LuaValue],
            function: String
        ) throws -> LuaTable {
            guard let value = arguments.first,
                  let table = registryBox.value?.luaTable(for: value) else {
                throw LuaError.runtime("\(function) Weapon Lua table is unavailable")
            }
            return table
        }

        func owner(
            of weapon: SourceCanonicalEntitySnapshot,
            function: String
        ) throws -> SourceCanonicalEntitySnapshot {
            guard let registry = registryBox.value else {
                throw LuaError.runtime("\(function) Entity registry is unavailable")
            }
            guard let player = registry.canonicalEntitySnapshots.first(where: {
                $0.kind == .player &&
                    $0.weaponInventory.weapon(identity: weapon.identity) != nil
            }) else {
                throw LuaError.runtime("\(function) Weapon has no canonical Player owner")
            }
            return player
        }

        func actionChannel(
            named action: String,
            in table: LuaTable,
            function: String
        ) throws -> SourceCanonicalWeaponReloadChannel {
            guard case let .table(actionTable) = try state.rawTableValue(
                for: .string(LuaString(action)),
                in: table
            ) else {
                throw LuaError.runtime(
                    "\(function) requires the inherited \(action) table"
                )
            }
            let rawClipSize = try state.rawTableValue(
                for: .string("ClipSize"),
                in: actionTable
            )
            guard case let .number(number) = rawClipSize,
                  number.isFinite,
                  number.rounded(.towardZero) == number,
                  let clipSize = Int32(exactly: number),
                  clipSize >= -1 else {
                throw LuaError.runtime(
                    "\(function) requires an authored 32-bit \(action).ClipSize"
                )
            }
            let rawAmmo = try state.rawTableValue(
                for: .string("Ammo"),
                in: actionTable
            )
            guard case let .string(ammoNameValue) = rawAmmo else {
                throw LuaError.runtime(
                    "\(function) requires an authored \(action).Ammo string"
                )
            }
            let ammoName = ammoNameValue.utf8String
            let ammoType: SourceCanonicalDefaultAmmoType?
            if ammoName.isEmpty || ammoName.caseInsensitiveCompare("none") == .orderedSame {
                ammoType = nil
            } else if let resolved = SourceCanonicalDefaultAmmoCatalog.type(
                name: ammoName
            ) {
                ammoType = resolved
            } else {
                throw LuaError.runtime(
                    "\(function) ammo type '\(ammoName)' is not in the canonical default catalog; custom game.AddAmmoType is unavailable"
                )
            }
            return SourceCanonicalWeaponReloadChannel(
                clipSize: clipSize,
                ammoType: ammoType
            )
        }

        func resolvedAmmoType(
            _ arguments: [LuaValue],
            index: Int,
            function: String
        ) throws -> SourceCanonicalDefaultAmmoType? {
            guard arguments.indices.contains(index) else {
                throw LuaError.runtime(
                    "bad argument #\(index) to '\(function)' (ammo ID or name expected)"
                )
            }
            switch arguments[index] {
            case let .number(number):
                guard number.isFinite,
                      number.rounded(.towardZero) == number,
                      let id = Int32(exactly: number) else {
                    throw LuaError.runtime(
                        "bad argument #\(index) to '\(function)' (32-bit ammo ID expected)"
                    )
                }
                return SourceCanonicalDefaultAmmoCatalog.type(id: id)
            case let .string(name):
                let spelling = name.utf8String
                if spelling.isEmpty ||
                    spelling.caseInsensitiveCompare("none") == .orderedSame {
                    return nil
                }
                if let numeric = Int32(spelling) {
                    return SourceCanonicalDefaultAmmoCatalog.type(id: numeric)
                }
                return SourceCanonicalDefaultAmmoCatalog.type(name: spelling)
            default:
                throw LuaError.runtime(
                    "bad argument #\(index) to '\(function)' (ammo ID or name expected)"
                )
            }
        }

        func int32Argument(
            _ arguments: [LuaValue],
            index: Int,
            function: String
        ) throws -> Int32 {
            guard arguments.indices.contains(index),
                  case let .number(number) = arguments[index],
                  number.isFinite,
                  number.rounded(.towardZero) == number,
                  let value = Int32(exactly: number) else {
                throw LuaError.runtime(
                    "bad argument #\(index) to '\(function)' (32-bit integer expected)"
                )
            }
            return value
        }

        func channel(
            named action: String,
            arguments: [LuaValue],
            function: String
        ) throws -> SourceCanonicalWeaponReloadChannel {
            try actionChannel(
                named: action,
                in: weaponTable(arguments, function: function),
                function: function
            )
        }

        for (method, action) in [
            ("Weapon:GetMaxClip1", "Primary"),
            ("Weapon:GetMaxClip2", "Secondary"),
        ] {
            try setMethod(method, on: weaponMetatable) { arguments in
                _ = try weaponSnapshot(arguments.first, function: method)
                return [.number(Double(try channel(
                    named: action,
                    arguments: arguments,
                    function: method
                ).clipSize))]
            }
        }

        for (method, action) in [
            ("Weapon:GetPrimaryAmmoType", "Primary"),
            ("Weapon:GetSecondaryAmmoType", "Secondary"),
        ] {
            try setMethod(method, on: weaponMetatable) { arguments in
                _ = try weaponSnapshot(arguments.first, function: method)
                return [.number(Double(try channel(
                    named: action,
                    arguments: arguments,
                    function: method
                ).ammoType?.id ?? -1))]
            }
        }

        try setMethod("Player:RemoveAmmo", on: playerMetatable) { arguments in
            let player = try playerSnapshot(
                arguments.first,
                function: "Player:RemoveAmmo"
            )
            guard runtime.realm == .server, let host = hostBox.value else {
                throw LuaError.runtime("Player:RemoveAmmo requires SERVER authority")
            }
            let amount = try int32Argument(
                arguments,
                index: 1,
                function: "Player:RemoveAmmo"
            )
            guard amount > 0,
                  let ammoType = try resolvedAmmoType(
                      arguments,
                      index: 2,
                      function: "Player:RemoveAmmo"
                  ),
                  let currentAmmo = player.playerAmmoState,
                  currentAmmo.count(for: ammoType) > 0 else { return [] }
            _ = try host.updateCanonicalEntity(player.identity) { candidate in
                guard var ammo = candidate.playerAmmoState else {
                    throw SourceCanonicalEntityError.playerAmmoStateRequired
                }
                _ = ammo.consume(amount, of: ammoType)
                candidate.playerAmmoState = ammo
            }
            return []
        }

        try setMethod("Weapon:DefaultReload", on: weaponMetatable) { arguments in
            let weapon = try weaponSnapshot(
                arguments.first,
                function: "Weapon:DefaultReload"
            )
            guard runtime.realm == .server,
                  let host = hostBox.value,
                  let endpoint = runtime.netEndpoint else {
                throw LuaError.runtime(
                    "Weapon:DefaultReload requires SERVER authority and gameplay FIFO"
                )
            }
            let activity = try int32Argument(
                arguments,
                index: 1,
                function: "Weapon:DefaultReload"
            )
            let table = try weaponTable(
                arguments,
                function: "Weapon:DefaultReload"
            )
            let primary = try actionChannel(
                named: "Primary",
                in: table,
                function: "Weapon:DefaultReload"
            )
            let secondary = try actionChannel(
                named: "Secondary",
                in: table,
                function: "Weapon:DefaultReload"
            )
            let player = try owner(
                of: weapon,
                function: "Weapon:DefaultReload"
            )
            guard let reserveAmmo = player.playerAmmoState else {
                throw SourceCanonicalEntityError.playerAmmoStateRequired
            }
            let plan = try SourceCanonicalWeaponReloadPlan.make(
                primary: primary,
                secondary: secondary,
                currentPrimaryClip: weapon.weaponRuntime.clip1,
                currentSecondaryClip: weapon.weaponRuntime.clip2,
                reserveAmmo: reserveAmmo
            )
            guard plan.didReload else { return [.boolean(false)] }

            let currentTime = runtime.timerScheduler?.currentTime ?? 0
            guard currentTime.isFinite,
                  abs(currentTime) <= Double(Float.greatestFiniteMagnitude) else {
                throw LuaError.runtime(
                    "Weapon:DefaultReload Source clock exceeds Float range"
                )
            }
            let cooldownEnd = Float(currentTime) +
                weapon.weaponRuntime.animationSequenceDuration
            guard cooldownEnd.isFinite else {
                throw LuaError.runtime(
                    "Weapon:DefaultReload authored sequence duration exceeds Source time range"
                )
            }

            _ = try host.updateCanonicalEntity(weapon.identity) { candidate in
                candidate.weaponRuntime.clip1 = plan.primaryClip
                candidate.weaponRuntime.clip2 = plan.secondaryClip
                candidate.weaponRuntime.nextPrimaryFire = max(
                    candidate.weaponRuntime.nextPrimaryFire,
                    cooldownEnd
                )
                candidate.weaponRuntime.nextSecondaryFire = max(
                    candidate.weaponRuntime.nextSecondaryFire,
                    cooldownEnd
                )
            }
            _ = try host.updateCanonicalEntity(player.identity) { candidate in
                guard var ammo = candidate.playerAmmoState else {
                    throw SourceCanonicalEntityError.playerAmmoStateRequired
                }
                for consumption in plan.consumptions {
                    let removed = ammo.consume(
                        consumption.count,
                        of: consumption.ammoType
                    )
                    guard removed == consumption.count else {
                        throw SourceCanonicalEntityError.invalidPlayerAmmoState
                    }
                }
                candidate.playerAmmoState = ammo
            }

            // Source's DefaultReload selects the exact caller-provided viewmodel
            // activity and PLAYER_RELOAD gesture. Reload audio belongs to the
            // decoded model activity/event data; no filename or duration is
            // synthesized when that data is unavailable.
            try endpoint.broadcastGameplayEvent(.weaponAnimation(
                GMLuaWeaponAnimationEvent(
                    weaponIdentity: weapon.identity,
                    activity: activity
                )
            ))
            try endpoint.broadcastGameplayEvent(.playerAnimation(
                GMLuaPlayerAnimationEvent(
                    playerIdentity: player.identity,
                    animation: playerReloadAnimation
                )
            ))
            return [.boolean(true)]
        }
    }

    private static func requiredGlobalInt32(
        named name: String,
        state: LuaState
    ) throws -> Int32 {
        guard case let .number(number) = state.getGlobal(name),
              number.isFinite,
              number.rounded(.towardZero) == number,
              let value = Int32(exactly: number) else {
            throw LuaError.runtime(
                "canonical Weapon reload requires exact global \(name)"
            )
        }
        return value
    }
}
