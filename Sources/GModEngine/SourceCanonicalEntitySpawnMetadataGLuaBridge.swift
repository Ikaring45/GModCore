import GModLua

public protocol SourceCanonicalEntitySpawnMetadataLuaHost: AnyObject {
    func setCanonicalSpawnEffect(
        _ enabled: Bool,
        on identity: SourceCanonicalEntityIdentity
    ) throws -> SourceCanonicalEntitySnapshot
}

public enum SourceCanonicalEntitySpawnMetadataGLuaBridgeError:
    Error,
    CustomStringConvertible
{
    case serverHostRequired
    case missingRuntimeSurface(String)

    public var description: String {
        switch self {
        case .serverHostRequired:
            return "SERVER canonical spawn metadata ABI requires an authoritative host"
        case let .missingRuntimeSurface(surface):
            return "canonical spawn metadata ABI requires \(surface)"
        }
    }
}

private final class SourceCanonicalSpawnMetadataWeakHost:
    @unchecked Sendable
{
    weak var value: (any SourceCanonicalEntitySpawnMetadataLuaHost)?

    init(_ value: (any SourceCanonicalEntitySpawnMetadataLuaHost)?) {
        self.value = value
    }
}

private final class SourceCanonicalSpawnMetadataWeakRegistry:
    @unchecked Sendable
{
    weak var value: GMLuaEntityRegistry?

    init(_ value: GMLuaEntityRegistry) {
        self.value = value
    }
}

/// Installs the engine-owned spawn-effect bit and creation clock on canonical
/// Entity userdata. CLIENT getters read only the immutable replicated
/// snapshot; only SERVER can author the bit.
public enum SourceCanonicalEntitySpawnMetadataGLuaBridge {
    public static func install(
        into runtime: GMLuaRuntime,
        serverHost: (any SourceCanonicalEntitySpawnMetadataLuaHost)? = nil
    ) throws {
        guard !runtime.isClosed else {
            throw SourceCanonicalEntitySpawnMetadataGLuaBridgeError
                .missingRuntimeSurface("an open runtime")
        }
        guard let registry = runtime.entityRegistry,
              let typeSystem = runtime.typeSystem,
              let entityMetatable = typeSystem.metatable(named: "Entity") else {
            throw SourceCanonicalEntitySpawnMetadataGLuaBridgeError
                .missingRuntimeSurface("Entity registry and metatable")
        }
        if runtime.realm == .server, serverHost == nil {
            throw SourceCanonicalEntitySpawnMetadataGLuaBridgeError
                .serverHostRequired
        }

        let state = runtime.state
        let registryBox = SourceCanonicalSpawnMetadataWeakRegistry(registry)
        let hostBox = SourceCanonicalSpawnMetadataWeakHost(serverHost)

        func setMethod(
            _ name: String,
            _ body: @escaping LuaNativeFunction
        ) throws {
            try state.setRawTableValue(
                .nativeFunction(LuaNativeFunctionBox(body, debugName: name)),
                for: .string(LuaString(
                    name.split(separator: ":").last.map(String.init) ?? name
                )),
                in: entityMetatable
            )
        }

        func requiredSnapshot(
            _ receiver: LuaValue?,
            function: String
        ) throws -> SourceCanonicalEntitySnapshot {
            guard let receiver,
                  let registry = registryBox.value,
                  let snapshot = registry.canonicalSnapshot(for: receiver) else {
                throw LuaError.runtime(
                    "bad self to '\(function)' (live canonical Entity expected)"
                )
            }
            return snapshot
        }

        try setMethod("Entity:GetSpawnEffect") { arguments in
            let snapshot = try requiredSnapshot(
                arguments.first,
                function: "Entity:GetSpawnEffect"
            )
            return [.boolean(snapshot.spawnEffect)]
        }
        try setMethod("Entity:GetCreationTime") { arguments in
            let snapshot = try requiredSnapshot(
                arguments.first,
                function: "Entity:GetCreationTime"
            )
            return [.number(Double(snapshot.creationTime))]
        }

        guard runtime.realm == .server else { return }

        try setMethod("Entity:SetSpawnEffect") { arguments in
            let snapshot = try requiredSnapshot(
                arguments.first,
                function: "Entity:SetSpawnEffect"
            )
            guard arguments.indices.contains(1),
                  case let .boolean(enabled) = arguments[1] else {
                let actual = arguments.indices.contains(1)
                    ? arguments[1].typeName
                    : "no value"
                throw LuaError.runtime(
                    "bad argument #1 to 'Entity:SetSpawnEffect' " +
                        "(boolean expected, got \(actual))"
                )
            }
            guard let host = hostBox.value else {
                throw LuaError.runtime(
                    "Entity:SetSpawnEffect canonical entity host is unavailable"
                )
            }
            _ = try host.setCanonicalSpawnEffect(
                enabled,
                on: snapshot.identity
            )
            return []
        }
    }
}

extension GMLuaSourceRuntimeAdapter:
    SourceCanonicalEntitySpawnMetadataLuaHost
{}
