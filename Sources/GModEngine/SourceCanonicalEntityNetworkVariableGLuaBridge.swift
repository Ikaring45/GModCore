import GModLua

/// Authoritative mutation boundary for legacy Entity NW variables. Getter
/// state is read from each realm's immutable canonical registry snapshot;
/// only SERVER receives this host.
public protocol SourceCanonicalEntityNetworkVariableLuaHost: AnyObject {
    func canonicalSnapshot(
        for identity: SourceCanonicalEntityIdentity
    ) -> SourceCanonicalEntitySnapshot?

    func setCanonicalNetworkedString(
        _ value: SourceNetworkVariableString,
        forKey key: SourceNetworkVariableString,
        on identity: SourceCanonicalEntityIdentity
    ) throws -> SourceCanonicalEntitySnapshot

    func setCanonicalNetworkedInt(
        _ value: SourceNetworkedIntValue,
        forKey key: SourceNetworkVariableString,
        on identity: SourceCanonicalEntityIdentity
    ) throws -> SourceCanonicalEntitySnapshot
}

public enum SourceCanonicalEntityNetworkVariableGLuaBridgeError:
    Error,
    CustomStringConvertible
{
    case serverHostRequired
    case missingRuntimeSurface(String)

    public var description: String {
        switch self {
        case .serverHostRequired:
            return "SERVER canonical NW-variable ABI requires an authoritative host"
        case let .missingRuntimeSurface(surface):
            return "canonical NW-variable ABI requires \(surface)"
        }
    }
}

private final class SourceCanonicalNetworkVariableWeakHost:
    @unchecked Sendable
{
    weak var value: (any SourceCanonicalEntityNetworkVariableLuaHost)?

    init(_ value: (any SourceCanonicalEntityNetworkVariableLuaHost)?) {
        self.value = value
    }
}

private final class SourceCanonicalNetworkVariableWeakRegistry:
    @unchecked Sendable
{
    weak var value: GMLuaEntityRegistry?

    init(_ value: GMLuaEntityRegistry) {
        self.value = value
    }
}

/// Installs the original `GetNWString`/`SetNWString` and
/// `GetNWInt`/`SetNWInt` spellings over canonical Entity snapshots.
///
/// CLIENT receives getters only. Its snapshot cannot change until the existing
/// shared-session FIFO applies a SERVER entity replication packet.
public enum SourceCanonicalEntityNetworkVariableGLuaBridge {
    public static func install(
        into runtime: GMLuaRuntime,
        serverHost: (any SourceCanonicalEntityNetworkVariableLuaHost)? = nil
    ) throws {
        guard !runtime.isClosed else {
            throw SourceCanonicalEntityNetworkVariableGLuaBridgeError
                .missingRuntimeSurface("an open runtime")
        }
        guard let registry = runtime.entityRegistry else {
            throw SourceCanonicalEntityNetworkVariableGLuaBridgeError
                .missingRuntimeSurface("Entity registry")
        }
        guard let typeSystem = runtime.typeSystem,
              let entityMetatable = typeSystem.metatable(named: "Entity") else {
            throw SourceCanonicalEntityNetworkVariableGLuaBridgeError
                .missingRuntimeSurface("Entity metatable")
        }
        if runtime.realm == .server, serverHost == nil {
            throw SourceCanonicalEntityNetworkVariableGLuaBridgeError
                .serverHostRequired
        }

        let state = runtime.state
        let registryBox = SourceCanonicalNetworkVariableWeakRegistry(registry)
        let hostBox = SourceCanonicalNetworkVariableWeakHost(serverHost)

        func setMethod(
            _ name: String,
            _ body: @escaping LuaNativeFunction
        ) throws {
            try state.setRawTableValue(
                .nativeFunction(LuaNativeFunctionBox(body, debugName: name)),
                for: .string(LuaString(name.split(separator: ":").last.map(String.init) ?? name)),
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

        func requiredLuaString(
            _ arguments: [LuaValue],
            index: Int,
            argumentPosition: Int,
            function: String
        ) throws -> LuaString {
            guard arguments.indices.contains(index),
                  case let .string(value) = arguments[index] else {
                let actual = arguments.indices.contains(index)
                    ? arguments[index].typeName
                    : "no value"
                throw LuaError.runtime(
                    "bad argument #\(argumentPosition) to '\(function)' " +
                        "(string expected, got \(actual))"
                )
            }
            return value
        }

        func key(
            _ arguments: [LuaValue],
            function: String
        ) throws -> SourceNetworkVariableString {
            let raw = try requiredLuaString(
                arguments,
                index: 1,
                argumentPosition: 1,
                function: function
            )
            return SourceNetworkVariableString(bytes: raw.bytes)
        }

        try setMethod("Entity:GetNWString") { arguments in
            let snapshot = try requiredSnapshot(
                arguments.first,
                function: "Entity:GetNWString"
            )
            let variableKey = try key(arguments, function: "Entity:GetNWString")
            if let value = snapshot.networkVariables.string(forKey: variableKey) {
                return [.string(LuaString(bytes: value.bytes))]
            }
            return [arguments.indices.contains(2) ? arguments[2] : .nilValue]
        }

        try setMethod("Entity:GetNWInt") { arguments in
            let snapshot = try requiredSnapshot(
                arguments.first,
                function: "Entity:GetNWInt"
            )
            let variableKey = try key(arguments, function: "Entity:GetNWInt")
            if let value = snapshot.networkVariables.int(forKey: variableKey) {
                return [.number(value.luaNumber)]
            }
            return [arguments.indices.contains(2) ? arguments[2] : .number(0)]
        }

        guard runtime.realm == .server else { return }

        try setMethod("Entity:SetNWString") { arguments in
            let snapshot = try requiredSnapshot(
                arguments.first,
                function: "Entity:SetNWString"
            )
            let variableKey = try key(arguments, function: "Entity:SetNWString")
            let rawValue = try requiredLuaString(
                arguments,
                index: 2,
                argumentPosition: 2,
                function: "Entity:SetNWString"
            )
            guard let host = hostBox.value else {
                throw LuaError.runtime(
                    "Entity:SetNWString canonical entity host is unavailable"
                )
            }
            _ = try host.setCanonicalNetworkedString(
                SourceNetworkVariableString(bytes: rawValue.bytes),
                forKey: variableKey,
                on: snapshot.identity
            )
            return []
        }

        try setMethod("Entity:SetNWInt") { arguments in
            let snapshot = try requiredSnapshot(
                arguments.first,
                function: "Entity:SetNWInt"
            )
            let variableKey = try key(arguments, function: "Entity:SetNWInt")
            guard arguments.indices.contains(2),
                  case let .number(number) = arguments[2] else {
                let actual = arguments.indices.contains(2)
                    ? arguments[2].typeName
                    : "no value"
                throw LuaError.runtime(
                    "bad argument #2 to 'Entity:SetNWInt' " +
                        "(number expected, got \(actual))"
                )
            }
            guard let host = hostBox.value else {
                throw LuaError.runtime(
                    "Entity:SetNWInt canonical entity host is unavailable"
                )
            }
            _ = try host.setCanonicalNetworkedInt(
                SourceNetworkedIntValue(luaNumber: number),
                forKey: variableKey,
                on: snapshot.identity
            )
            return []
        }
    }
}

extension GMLuaSourceRuntimeAdapter:
    SourceCanonicalEntityNetworkVariableLuaHost
{}
