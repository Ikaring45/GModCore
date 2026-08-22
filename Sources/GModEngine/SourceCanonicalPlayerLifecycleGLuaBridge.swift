import GModLua

/// Binds Source Player lifecycle operations to the canonical SERVER entity.
/// This bridge is installed after the ordinary combat surface, so it replaces
/// Player `TakeDamageInfo` with the lifecycle state machine while retaining
/// the non-Player CBaseEntity damage/physics path.
public enum SourceCanonicalPlayerLifecycleGLuaBridge {
    @discardableResult
    public static func install(
        into runtime: GMLuaRuntime,
        host: any SourceCanonicalEntityLuaHost,
        respawnResolver: SourceCanonicalPlayerRespawnResolver? = nil,
        dropWeapon: SourceCanonicalPlayerWeaponDrop? = nil
    ) throws -> SourceCanonicalPlayerLifecycleController {
        guard runtime.realm == .server,
              let typeSystem = runtime.typeSystem,
              let registry = runtime.entityRegistry,
              let entityMetatable = typeSystem.metatable(named: "Entity"),
              let playerMetatable = typeSystem.metatable(named: "Player")
        else {
            throw LuaError.runtime(
                "canonical Player lifecycle requires SERVER Entity/Player surfaces"
            )
        }
        let state = runtime.state

        let activeDrop: SourceCanonicalPlayerWeaponDrop = dropWeapon ?? {
            playerIdentity, weaponIdentity in
            let player = registry.player(at: playerIdentity.entryIndex)
            let weapon = registry.entity(at: weaponIdentity.entryIndex)
            guard registry.canonicalIdentity(for: player) == playerIdentity,
                  registry.canonicalIdentity(for: weapon) == weaponIdentity
            else {
                throw SourceCanonicalPlayerLifecycleError
                    .unavailableEntity(weaponIdentity)
            }
            let method = try state.rawTableValue(
                for: .string("DropWeapon"),
                in: playerMetatable
            )
            guard lifecycleIsCallable(method) else {
                throw LuaError.runtime(
                    "Player:DropWeapon is unavailable during death"
                )
            }
            _ = try state.call(method, arguments: [player, weapon])
        }
        let controller = SourceCanonicalPlayerLifecycleController(
            host: host,
            dropWeapon: activeDrop,
            respawnResolver: respawnResolver
        )
        runtime.playerLifecycleController = controller

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
            function: String
        ) throws -> SourceCanonicalEntitySnapshot {
            guard let value,
                  let snapshot = registry.canonicalSnapshot(for: value) else {
                throw LuaError.runtime(
                    "bad self to '\(function)' (live canonical Entity expected)"
                )
            }
            return snapshot
        }

        func damageInfo(
            _ value: LuaValue?,
            function: String
        ) throws -> SourceCanonicalDamageInfoValue {
            guard let value,
                  let object = GMLuaTypeSystem.typedObject(from: value),
                  object.isValid,
                  object.metaName == "CTakeDamageInfo",
                  let payload = object.payload as?
                    SourceCanonicalDamageInfoValue else {
                throw LuaError.runtime(
                    "bad argument #1 to '\(function)' (CTakeDamageInfo expected)"
                )
            }
            return payload
        }

        try setMethod("Player:Kill", on: playerMetatable) { arguments in
            let player = try snapshot(
                arguments.first,
                function: "Player:Kill"
            )
            guard player.kind == .player else {
                throw LuaError.runtime(
                    "bad self to 'Player:Kill' (live canonical Player expected)"
                )
            }
            let report = try controller.kill(player: player.identity)
            reportContainedFailures(
                report.sideEffectFailures,
                runtime: runtime
            )
            return []
        }

        try setMethod("Player:Spawn", on: playerMetatable) { arguments in
            let player = try snapshot(
                arguments.first,
                function: "Player:Spawn"
            )
            guard player.kind == .player else {
                throw LuaError.runtime(
                    "bad self to 'Player:Spawn' (live canonical Player expected)"
                )
            }
            _ = try controller.spawn(player: player.identity)
            let value = registry.player(at: player.identity.entryIndex)
            _ = runtime.dispatchContainedHostHook(
                named: "PlayerSpawn",
                arguments: [value]
            )
            return []
        }

        // Preserve the already-installed non-Player CBaseEntity damage path.
        let previousTakeDamageInfo = try state.rawTableValue(
            for: .string("TakeDamageInfo"),
            in: entityMetatable
        )
        guard lifecycleIsCallable(previousTakeDamageInfo) else {
            throw LuaError.runtime(
                "Entity:TakeDamageInfo is unavailable before Player lifecycle installation"
            )
        }
        try setMethod(
            "Entity:TakeDamageInfo",
            on: entityMetatable
        ) { arguments in
            let entity = try snapshot(
                arguments.first,
                function: "Entity:TakeDamageInfo"
            )
            guard entity.kind == .player else {
                return try state.call(
                    previousTakeDamageInfo,
                    arguments: arguments
                )
            }
            guard arguments.indices.contains(1) else {
                throw LuaError.runtime(
                    "bad argument #1 to 'Entity:TakeDamageInfo' (CTakeDamageInfo expected)"
                )
            }
            let info = try damageInfo(
                arguments[1],
                function: "Entity:TakeDamageInfo"
            )
            let report = try controller.takeDamageInfo(
                SourceCanonicalPlayerDamageRequest(
                    damage: info.damage,
                    force: info.force,
                    position: info.position,
                    attacker: info.attacker,
                    inflictor: info.inflictor,
                    weapon: info.weapon
                ),
                player: entity.identity
            )
            reportContainedFailures(
                report.sideEffectFailures,
                runtime: runtime
            )
            switch report.disposition {
            case .ignoredNotDamageable:
                return [.number(0)]
            default:
                return [.number(1)]
            }
        }
        return controller
    }

    private static func reportContainedFailures(
        _ failures: [SourceCanonicalPlayerLifecycleSideEffectFailure],
        runtime: GMLuaRuntime
    ) {
        guard !failures.isEmpty else { return }
        let reporter = runtime.state.getGlobal("ErrorNoHaltWithStack")
        guard lifecycleIsCallable(reporter) else { return }
        for failure in failures {
            _ = try? runtime.state.call(
                reporter,
                arguments: [.string(LuaString(
                    "canonical Player \(failure.operation.rawValue) failed: " +
                        failure.message + "\n"
                ))]
            )
        }
    }

    private static func lifecycleIsCallable(_ value: LuaValue) -> Bool {
        switch value {
        case .luaFunction, .nativeFunction:
            return true
        default:
            return false
        }
    }
}
