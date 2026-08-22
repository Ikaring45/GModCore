import Foundation
import GModLua

private final class SourceCanonicalPlayerHandsWeakHost: @unchecked Sendable {
    weak var value: (any SourceCanonicalEntityLuaHost)?

    init(_ value: (any SourceCanonicalEntityLuaHost)?) {
        self.value = value
    }
}

private final class SourceCanonicalPlayerHandsWeakRegistry:
    @unchecked Sendable
{
    weak var value: GMLuaEntityRegistry?

    init(_ value: GMLuaEntityRegistry?) {
        self.value = value
    }
}

private final class SourceCanonicalPlayerHandsWeakRuntime:
    @unchecked Sendable
{
    weak var value: GMLuaRuntime?

    init(_ value: GMLuaRuntime) {
        self.value = value
    }
}

/// Native engine surface used by the stock `Player:SetupHands` Lua extension.
///
/// The bundled Lua remains the caller and still selects the model through
/// `player_manager` and `GM:PlayerSetHandsModel`. This bridge supplies only
/// the engine-owned pieces which Garry's Mod normally implements in C++:
/// `Player:GetHands`/`SetHands`, `ents.Create("gmod_hands")`, and the concrete
/// c_model's owner/viewmodel attachment. All authored fields are canonical
/// snapshots and therefore use the ordinary SERVER-to-CLIENT FIFO.
public enum SourceCanonicalPlayerHandsGLuaBridge {
    public static func install(
        into runtime: GMLuaRuntime,
        host: (any SourceCanonicalEntityLuaHost)? = nil
    ) throws {
        guard runtime.realm == .server || runtime.realm == .client else {
            throw LuaError.runtime(
                "canonical Player hands require SERVER or CLIENT"
            )
        }
        if runtime.realm == .server, host == nil {
            throw LuaError.runtime(
                "canonical Player hands SERVER requires an authoritative host"
            )
        }
        guard let registry = runtime.entityRegistry,
              let typeSystem = runtime.typeSystem,
              let entityMetatable = typeSystem.metatable(named: "Entity"),
              let playerMetatable = typeSystem.metatable(named: "Player") else {
            throw LuaError.runtime(
                "canonical Player hands require Entity and Player metatables"
            )
        }

        let state = runtime.state
        let nullValue = state.getGlobal("NULL")
        let hostBox = SourceCanonicalPlayerHandsWeakHost(host)
        let registryBox = SourceCanonicalPlayerHandsWeakRegistry(registry)
        let runtimeBox = SourceCanonicalPlayerHandsWeakRuntime(runtime)

        func native(
            _ name: String,
            _ body: @escaping LuaNativeFunction
        ) -> LuaValue {
            .nativeFunction(LuaNativeFunctionBox(body, debugName: name))
        }

        func setMethod(
            _ name: String,
            on metatable: LuaTable,
            body: @escaping LuaNativeFunction
        ) throws {
            try state.setRawTableValue(
                native(name, body),
                for: .string(LuaString(
                    name.split(separator: ":").last.map(String.init) ?? name
                )),
                in: metatable
            )
        }

        func requiredHost(
            _ function: String
        ) throws -> any SourceCanonicalEntityLuaHost {
            guard let host = hostBox.value else {
                throw LuaError.runtime(
                    "\(function) canonical entity host is unavailable"
                )
            }
            return host
        }

        func requiredSnapshot(
            _ value: LuaValue?,
            function: String,
            kind: SourceCanonicalEntityKind
        ) throws -> SourceCanonicalEntitySnapshot {
            guard let value,
                  let registry = registryBox.value,
                  let snapshot = registry.canonicalSnapshot(for: value),
                  snapshot.kind == kind else {
                throw LuaError.runtime(
                    "bad self to '\(function)' (live \(kind.className) expected)"
                )
            }
            return snapshot
        }

        func liveValue(
            _ identity: SourceCanonicalEntityIdentity,
            kind: SourceCanonicalEntityKind
        ) -> LuaValue? {
            guard let registry = registryBox.value else { return nil }
            let value = registry.entity(at: identity.entryIndex)
            guard let snapshot = registry.canonicalSnapshot(for: value),
                  snapshot.identity == identity,
                  snapshot.kind == kind,
                  snapshot.lifecycle != .removed else { return nil }
            return value
        }

        let previousGetOwner = try state.rawTableValue(
            for: .string("GetOwner"),
            in: entityMetatable
        )
        let previousGetModel = try state.rawTableValue(
            for: .string("GetModel"),
            in: entityMetatable
        )
        let previousGetParent = try state.rawTableValue(
            for: .string("GetParent"),
            in: entityMetatable
        )
        let previousGetPlayerColor = try state.rawTableValue(
            for: .string("GetPlayerColor"),
            in: entityMetatable
        )

        try setMethod("Player:GetHands", on: playerMetatable) { arguments in
            let player = try requiredSnapshot(
                arguments.first,
                function: "Player:GetHands",
                kind: .player
            )
            guard let identity = player.playerHands,
                  let value = liveValue(identity, kind: .playerHands) else {
                return [nullValue]
            }
            return [value]
        }

        try setMethod("Entity:GetModel", on: entityMetatable) { arguments in
            guard let value = arguments.first,
                  let registry = registryBox.value,
                  let snapshot = registry.canonicalSnapshot(for: value) else {
                switch previousGetModel {
                case .luaFunction, .nativeFunction:
                    return try state.call(previousGetModel, arguments: arguments)
                default:
                    return [.string("")]
                }
            }
            return [.string(LuaString(snapshot.model?.path ?? ""))]
        }

        try setMethod("Entity:GetOwner", on: entityMetatable) { arguments in
            guard let value = arguments.first,
                  let registry = registryBox.value,
                  let snapshot = registry.canonicalSnapshot(for: value),
                  snapshot.kind == .playerHands else {
                switch previousGetOwner {
                case .luaFunction, .nativeFunction:
                    return try state.call(previousGetOwner, arguments: arguments)
                default:
                    return [nullValue]
                }
            }
            guard let identity = snapshot.handsOwner,
                  let owner = liveValue(identity, kind: .player) else {
                return [nullValue]
            }
            return [owner]
        }

        try setMethod("Entity:GetParent", on: entityMetatable) { arguments in
            guard let value = arguments.first,
                  let registry = registryBox.value,
                  let snapshot = registry.canonicalSnapshot(for: value),
                  snapshot.kind == .playerHands else {
                switch previousGetParent {
                case .luaFunction, .nativeFunction:
                    return try state.call(previousGetParent, arguments: arguments)
                default:
                    return [nullValue]
                }
            }
            guard let ownerIdentity = snapshot.handsOwner,
                  let viewModelIndex = snapshot.handsViewModelIndex,
                  let owner = liveValue(ownerIdentity, kind: .player) else {
                return [nullValue]
            }
            let getViewModel = try state.rawTableValue(
                for: .string("GetViewModel"),
                in: playerMetatable
            )
            switch getViewModel {
            case .luaFunction, .nativeFunction:
                return try state.call(
                    getViewModel,
                    arguments: [owner, .number(Double(viewModelIndex))]
                )
            default:
                return [nullValue]
            }
        }

        try setMethod(
            "Entity:GetPlayerColor",
            on: entityMetatable
        ) { arguments in
            guard let value = arguments.first,
                  let registry = registryBox.value,
                  let snapshot = registry.canonicalSnapshot(for: value),
                  snapshot.kind == .playerHands else {
                switch previousGetPlayerColor {
                case .luaFunction, .nativeFunction:
                    return try state.call(
                        previousGetPlayerColor,
                        arguments: arguments
                    )
                default:
                    return []
                }
            }
            guard let ownerIdentity = snapshot.handsOwner,
                  let owner = liveValue(ownerIdentity, kind: .player) else {
                return []
            }
            let getPlayerColor = try state.rawTableValue(
                for: .string("GetPlayerColor"),
                in: playerMetatable
            )
            switch getPlayerColor {
            case .luaFunction, .nativeFunction:
                return try state.call(getPlayerColor, arguments: [owner])
            default:
                return []
            }
        }

        guard runtime.realm == .server else { return }

        try setMethod("Player:SetHands", on: playerMetatable) { arguments in
            let player = try requiredSnapshot(
                arguments.first,
                function: "Player:SetHands",
                kind: .player
            )
            guard arguments.indices.contains(1),
                  let registry = registryBox.value,
                  let hands = registry.canonicalSnapshot(for: arguments[1]),
                  hands.kind == .playerHands else {
                throw LuaError.runtime(
                    "bad argument #1 to 'Player:SetHands' " +
                    "(live gmod_hands expected)"
                )
            }
            _ = try requiredHost("Player:SetHands")
                .updateCanonicalEntity(player.identity) {
                    $0.playerHands = hands.identity
                }
            return []
        }

        try setMethod("Entity:DoSetup", on: entityMetatable) { arguments in
            let hands = try requiredSnapshot(
                arguments.first,
                function: "gmod_hands:DoSetup",
                kind: .playerHands
            )
            guard arguments.indices.contains(1) else {
                throw LuaError.runtime(
                    "bad argument #1 to 'gmod_hands:DoSetup' (Player expected)"
                )
            }
            let player = try requiredSnapshot(
                arguments[1],
                function: "gmod_hands:DoSetup",
                kind: .player
            )
            let modelPlayerValue: LuaValue
            if arguments.indices.contains(2),
               case .nilValue = arguments[2] {
                modelPlayerValue = arguments[1]
            } else if arguments.indices.contains(2) {
                _ = try requiredSnapshot(
                    arguments[2],
                    function: "gmod_hands:DoSetup",
                    kind: .player
                )
                modelPlayerValue = arguments[2]
            } else {
                modelPlayerValue = arguments[1]
            }

            let host = try requiredHost("gmod_hands:DoSetup")
            _ = try host.updateCanonicalEntity(hands.identity) { candidate in
                candidate.handsOwner = player.identity
                candidate.handsViewModelIndex = 0
                candidate.transform.origin = player.transform.origin
                candidate.transform.angles = .zero
                candidate.isNotSolid = true
                candidate.moveType = .none
            }
            _ = try host.updateCanonicalEntity(player.identity) { candidate in
                candidate.playerHands = hands.identity
            }
            guard let runtime = runtimeBox.value else {
                throw LuaError.runtime(
                    "gmod_hands:DoSetup runtime is unavailable"
                )
            }
            try runtime.dispatchHostHook(
                named: "PlayerSetHandsModel",
                arguments: [modelPlayerValue, arguments[0]]
            )
            return []
        }

        let ents: LuaTable
        if case let .table(existing) = state.getGlobal("ents") {
            ents = existing
        } else {
            throw LuaError.runtime("canonical Player hands require ents")
        }
        let previousCreate = try state.rawTableValue(
            for: .string("Create"),
            in: ents
        )
        try state.setRawTableValue(
            native("ents.Create(gmod_hands)") { arguments in
                guard case let .string(className)? = arguments.first,
                      className.utf8String ==
                        SourceCanonicalEntityKind.playerHands.className else {
                    switch previousCreate {
                    case .luaFunction, .nativeFunction:
                        return try state.call(
                            previousCreate,
                            arguments: arguments
                        )
                    default:
                        return [nullValue]
                    }
                }
                let host = try requiredHost("ents.Create")
                let snapshot: SourceCanonicalEntitySnapshot
                do {
                    snapshot = try host.createCanonicalEntity(
                        kind: .playerHands,
                        at: nil,
                        state: nil,
                        playerUserID: nil
                    )
                } catch SourceCanonicalEntityError.noFreeNetworkableSlot {
                    return [nullValue]
                }
                guard let value = liveValue(
                    snapshot.identity,
                    kind: .playerHands
                ) else {
                    _ = try host.rollbackCanonicalEntityCreation(
                        snapshot.identity
                    )
                    throw LuaError.runtime(
                        "ents.Create(gmod_hands) did not publish its exact EHANDLE"
                    )
                }
                return [value]
            },
            for: .string("Create"),
            in: ents
        )
    }
}
