import GModLua

/// Rebinds the two creator accessors which the bundled
/// `lua/includes/extensions/entity.lua` intentionally implements in Lua.
///
/// The official Lua body is correct for native GMod because the engine owns
/// the Entity's Lua table. In this runtime it would create a realm-local
/// `m_PlayerCreator` field and bypass the canonical Source Entity state, so
/// the public methods are rebound once after `includes/init.lua` finishes.
public enum SourceCanonicalEntityCreatorGLuaBridge {
    public static func install(
        into runtime: GMLuaRuntime,
        host: any SourceCanonicalEntityLuaHost
    ) throws {
        guard runtime.realm == .server, !runtime.isClosed else {
            throw LuaError.runtime(
                "canonical Entity creator bridge requires an open SERVER runtime"
            )
        }
        guard let registry = runtime.entityRegistry,
              let typeSystem = runtime.typeSystem,
              let entityMetatable = typeSystem.metatable(named: "Entity") else {
            throw LuaError.runtime(
                "canonical Entity creator bridge requires the Entity registry and metatable"
            )
        }

        let state = runtime.state
        let nullValue = state.getGlobal("NULL")
        let hostBox = SourceCanonicalEntityCreatorWeakHost(host)
        let registryBox = SourceCanonicalEntityCreatorWeakRegistry(registry)

        func native(
            _ name: String,
            _ body: @escaping LuaNativeFunction
        ) -> LuaValue {
            .nativeFunction(LuaNativeFunctionBox(body, debugName: name))
        }

        func setMethod(
            _ name: String,
            body: @escaping LuaNativeFunction
        ) throws {
            try state.setRawTableValue(
                native(name, body),
                for: .string(LuaString(
                    name.split(separator: ":").last.map(String.init) ?? name
                )),
                in: entityMetatable
            )
        }

        func requiredSnapshot(
            _ value: LuaValue?,
            function: String
        ) throws -> SourceCanonicalEntitySnapshot {
            guard let value,
                  let registry = registryBox.value,
                  let snapshot = registry.canonicalSnapshot(for: value) else {
                throw LuaError.runtime(
                    "bad self to '\(function)' (live canonical Entity expected)"
                )
            }
            return snapshot
        }

        func liveValue(
            _ identity: SourceCanonicalEntityIdentity
        ) -> LuaValue? {
            guard let registry = registryBox.value else { return nil }
            let value = registry.entity(at: identity.entryIndex)
            guard registry.canonicalIdentity(for: value) == identity else {
                return nil
            }
            return value
        }

        func isCanonicalNull(_ value: LuaValue) -> Bool {
            guard let object = GMLuaTypeSystem.typedObject(from: value) else {
                return false
            }
            return object.metaName == "Entity" &&
                !object.isValid && object.payload == nil
        }

        try setMethod("Entity:SetCreator") { arguments in
            let entity = try requiredSnapshot(
                arguments.first,
                function: "Entity:SetCreator"
            )
            let creator: SourceCanonicalEntityIdentity?
            if !arguments.indices.contains(1) {
                creator = nil
            } else {
                switch arguments[1] {
                case .nilValue:
                    creator = nil
                default:
                    if isCanonicalNull(arguments[1]) {
                        creator = nil
                    } else if let registry = registryBox.value,
                              let resolved = registry.canonicalIdentity(
                                for: arguments[1]
                              ) {
                        creator = resolved
                    } else {
                        throw LuaError.runtime(
                            "bad argument #1 to 'SetCreator' " +
                                "(live Entity or NULL expected, got " +
                                "\(arguments[1].typeName))"
                        )
                    }
                }
            }
            guard let host = hostBox.value else {
                throw LuaError.runtime(
                    "Entity:SetCreator canonical entity host is unavailable"
                )
            }
            _ = try host.updateCanonicalEntity(entity.identity) { candidate in
                candidate.creator = creator
            }
            return []
        }

        try setMethod("Entity:GetCreator") { arguments in
            let entity = try requiredSnapshot(
                arguments.first,
                function: "Entity:GetCreator"
            )
            guard let creator = entity.creator,
                  let value = liveValue(creator) else {
                return [nullValue]
            }
            return [value]
        }
    }
}

private final class SourceCanonicalEntityCreatorWeakHost:
    @unchecked Sendable
{
    weak var value: (any SourceCanonicalEntityLuaHost)?

    init(_ value: any SourceCanonicalEntityLuaHost) {
        self.value = value
    }
}

private final class SourceCanonicalEntityCreatorWeakRegistry:
    @unchecked Sendable
{
    weak var value: GMLuaEntityRegistry?

    init(_ value: GMLuaEntityRegistry) {
        self.value = value
    }
}
