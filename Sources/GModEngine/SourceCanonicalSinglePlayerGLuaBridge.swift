import GModLua

public enum SourceCanonicalSinglePlayerGLuaBridgeError:
    Error,
    CustomStringConvertible
{
    case serverRealmRequired(GMLuaRealm)
    case missingRuntimeSurface(String)

    public var description: String {
        switch self {
        case let .serverRealmRequired(realm):
            return "canonical single-player ABI requires SERVER, got \(realm.rawValue)"
        case let .missingRuntimeSurface(surface):
            return "canonical single-player ABI requires \(surface)"
        }
    }
}

/// Installs native values whose Source contract is exact only because this
/// host is explicitly a single-player session.
///
/// In particular, GMod specifies `Player:UniqueID()` as the number `1` in
/// single-player. This bridge is never installed by generic Runtime startup,
/// so a future multiplayer host cannot accidentally reuse that value. It also
/// exposes the canonical Source entity-list deletion flag used by stock
/// Sandbox cleanup/undo extensions.
public enum SourceCanonicalSinglePlayerGLuaBridge {
    public static func install(into runtime: GMLuaRuntime) throws {
        guard runtime.realm == .server else {
            throw SourceCanonicalSinglePlayerGLuaBridgeError
                .serverRealmRequired(runtime.realm)
        }
        guard !runtime.isClosed else {
            throw SourceCanonicalSinglePlayerGLuaBridgeError
                .missingRuntimeSurface("an open runtime")
        }
        guard let registry = runtime.entityRegistry,
              let typeSystem = runtime.typeSystem,
              let entityMetatable = typeSystem.metatable(named: "Entity"),
              let playerMetatable = typeSystem.metatable(named: "Player") else {
            throw SourceCanonicalSinglePlayerGLuaBridgeError
                .missingRuntimeSurface("Entity registry and metatables")
        }

        let state = runtime.state

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

        func requiredSnapshot(
            _ value: LuaValue?,
            function: String,
            kind: SourceCanonicalEntityKind? = nil
        ) throws -> SourceCanonicalEntitySnapshot {
            guard let value,
                  let snapshot = registry.canonicalSnapshot(for: value) else {
                throw LuaError.runtime(
                    "bad self to '\(function)' (live canonical Entity expected)"
                )
            }
            if let kind, snapshot.kind != kind {
                throw LuaError.runtime(
                    "bad self to '\(function)' (\(kind.className) expected, got \(snapshot.className))"
                )
            }
            return snapshot
        }

        try setMethod("Player:UniqueID", on: playerMetatable) { arguments in
            _ = try requiredSnapshot(
                arguments.first,
                function: "Player:UniqueID",
                kind: .player
            )
            return [.number(1)]
        }

        try setMethod(
            "Entity:IsMarkedForDeletion",
            on: entityMetatable
        ) { arguments in
            let snapshot = try requiredSnapshot(
                arguments.first,
                function: "Entity:IsMarkedForDeletion"
            )
            return [.boolean(snapshot.lifecycle == .pendingRemoval)]
        }
    }
}
