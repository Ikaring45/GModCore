import Foundation
import GModLua

/// A command request that crosses from GLua into the host-owned engine layer.
/// Arguments remain separated exactly as supplied to `RunConsoleCommand`.
public struct GMLuaConsoleCommandInvocation: Sendable, Equatable {
    public let realm: GMLuaRealm
    public let command: String
    public let arguments: [String]

    public init(realm: GMLuaRealm, command: String, arguments: [String]) {
        self.realm = realm
        self.command = command
        self.arguments = arguments
    }
}

/// A host must explicitly say whether it executed, did not own, or rejected a
/// command. This keeps unavailable Source commands and permission checks from
/// becoming silent successes in the native iPad runtime.
public enum GMLuaConsoleCommandHostDisposition: Sendable, Equatable {
    case handled
    case unhandled
    case rejected(reason: String)
}

public typealias GMLuaConsoleCommandHostHandler = @Sendable (
    GMLuaConsoleCommandInvocation
) throws -> GMLuaConsoleCommandHostDisposition

/// State-local bridge for Lua ConVars, Lua console commands, and real engine
/// commands supplied by an embedding host.
public final class GMLuaConsoleCommandDispatcher: @unchecked Sendable {
    private let state: LuaState
    private let realm: GMLuaRealm
    private let conVars: GMLuaConVarRegistry
    private let entityRegistry: GMLuaEntityRegistry
    private let lock = NSLock()
    private var hostHandler: GMLuaConsoleCommandHostHandler?
    private var remoteServerHandler: GMLuaConsoleCommandHostHandler?
    private var registeredNamesByKey: [String: String] = [:]
    private var registeredKeysInOrder: [String] = []

    init(
        state: LuaState,
        realm: GMLuaRealm,
        conVars: GMLuaConVarRegistry,
        entityRegistry: GMLuaEntityRegistry
    ) {
        self.state = state
        self.realm = realm
        self.conVars = conVars
        self.entityRegistry = entityRegistry
    }

    /// Commands registered through the native `AddConsoleCommand` ABI, in
    /// first-registration order. Names are matched case-insensitively.
    public var registeredCommands: [String] {
        lock.lock()
        defer { lock.unlock() }
        return registeredKeysInOrder.compactMap { registeredNamesByKey[$0] }
    }

    public func connectHost(_ handler: @escaping GMLuaConsoleCommandHostHandler) {
        lock.lock()
        hostHandler = handler
        lock.unlock()
    }

    public func disconnectHost() {
        lock.lock()
        hostHandler = nil
        lock.unlock()
    }

    func connectRemoteServer(_ handler: @escaping GMLuaConsoleCommandHostHandler) {
        lock.lock()
        remoteServerHandler = handler
        lock.unlock()
    }

    func disconnectRemoteServer() {
        lock.lock()
        remoteServerHandler = nil
        lock.unlock()
    }

    func installBindings() {
        state.register("AddConsoleCommand") { [unowned self] arguments in
            try self.addConsoleCommand(arguments)
        }
        state.register("RunConsoleCommand") { [unowned self] arguments in
            try self.runConsoleCommand(arguments)
        }
    }

    private func addConsoleCommand(_ arguments: [LuaValue]) throws -> [LuaValue] {
        let name = try consoleString(
            arguments,
            index: 0,
            function: "AddConsoleCommand"
        )
        let key = normalizedName(name)
        guard !key.isEmpty else {
            throw LuaError.runtime("bad argument #1 to 'AddConsoleCommand' (non-empty string expected)")
        }

        // Desktop GMod silently refuses a Lua command whose name already
        // belongs to a ConVar. The Lua module may retain its callback, but the
        // engine command is not registered and therefore cannot dispatch it.
        guard !conVars.contains(name) else { return [] }

        lock.lock()
        if registeredNamesByKey[key] == nil {
            registeredKeysInOrder.append(key)
            registeredNamesByKey[key] = name
        }
        lock.unlock()
        return []
    }

    private func runConsoleCommand(_ values: [LuaValue]) throws -> [LuaValue] {
        let command = try consoleString(
            values,
            index: 0,
            function: "RunConsoleCommand"
        )
        let arguments = try values.indices.dropFirst().map {
            try consoleString(values, index: $0, function: "RunConsoleCommand")
        }

        // Lua-owned ConVars are the only variables this runtime can handle
        // without consulting a real engine host. Engine-owned catalog entries
        // deliberately reject `setConsoleValue`; both their setter and query
        // forms must therefore continue to the host handler below.
        //
        // A no-argument Lua-owned invocation is only a query. Reapplying its
        // already-bounded value is an observable no-op that lets the registry
        // make the same ownership decision without exposing userdata payloads.
        let handledLuaConVar: Bool
        if let value = arguments.first {
            handledLuaConVar = conVars.setConsoleValue(value, for: command)
        } else if let currentValue = conVars.stringValue(for: command) {
            handledLuaConVar = conVars.setConsoleValue(currentValue, for: command)
        } else {
            handledLuaConVar = false
        }
        if handledLuaConVar {
            return []
        }

        let invocation = GMLuaConsoleCommandInvocation(
            realm: realm,
            command: command,
            arguments: arguments
        )
        let handler: GMLuaConsoleCommandHostHandler? = {
            lock.lock()
            defer { lock.unlock() }
            return hostHandler
        }()

        if let handler {
            switch try handler(invocation) {
            case .handled:
                return []
            case .unhandled:
                break
            case let .rejected(reason):
                throw LuaError.runtime(
                    "RunConsoleCommand host rejected command '\(command)': \(reason)"
                )
            }
        }

        if isRegistered(command) {
            let caller: LuaValue
            if realm == .server {
                caller = state.getGlobal("NULL")
            } else {
                caller = entityRegistry.localPlayer()
                guard GMLuaTypeSystem.typedObject(from: caller)?.isValid == true else {
                    throw LuaError.runtime(
                        "RunConsoleCommand cannot dispatch local \(realm.rawValue) command " +
                        "'\(command)' without a host-owned player context (connected LocalPlayer unavailable)"
                    )
                }
            }
            try dispatchLuaCommand(
                command: command,
                arguments: arguments,
                caller: caller
            )
            return []
        }


        let remoteHandler: GMLuaConsoleCommandHostHandler? = {
            lock.lock()
            defer { lock.unlock() }
            return remoteServerHandler
        }()
        if realm == .client, let remoteHandler {
            switch try remoteHandler(invocation) {
            case .handled:
                return []
            case .unhandled:
                break
            case let .rejected(reason):
                throw LuaError.runtime(
                    "RunConsoleCommand server rejected command '\(command)': \(reason)"
                )
            }
        }

        if handler != nil {
            throw LuaError.runtime(
                "RunConsoleCommand host did not recognize engine command '\(command)'"
            )
        }
        throw LuaError.runtime(
            "RunConsoleCommand cannot execute engine command '\(command)' " +
            "because no console host is connected"
        )
    }

    func dispatchLuaCommand(
        command: String,
        arguments: [String],
        caller: LuaValue
    ) throws {
        guard case let .table(concommand) = state.getGlobal("concommand") else {
            throw LuaError.runtime(
                "RunConsoleCommand cannot dispatch Lua command '\(command)' " +
                "because concommand.Run is unavailable"
            )
        }
        let runner = try state.rawTableValue(for: .string("Run"), in: concommand)
        guard runner.typeName == "function" else {
            throw LuaError.runtime(
                "RunConsoleCommand cannot dispatch Lua command '\(command)' " +
                "because concommand.Run is unavailable"
            )
        }

        let argumentTable = LuaTable()
        for (offset, argument) in arguments.enumerated() {
            try state.setRawTableValue(
                .string(LuaString(argument)),
                for: .number(Double(offset + 1)),
                in: argumentTable
            )
        }
        _ = try state.call(
            runner,
            arguments: [
                caller,
                .string(LuaString(command)),
                .table(argumentTable),
                .string(LuaString(arguments.joined(separator: " ")))
            ]
        )
    }

    /// Applies a CLIENT-originated command through the SERVER command surface.
    /// This intentionally repeats SERVER `RunConsoleCommand` ownership order:
    /// Lua ConVar, engine host, then a registered Lua concommand. Forwarding
    /// must not jump straight to `concommand.Run` and bypass engine commands.
    func dispatchRemoteCommand(
        command: String,
        arguments: [String],
        caller: LuaValue
    ) throws {
        guard realm == .server else {
            throw LuaError.runtime("remote console command destination is not SERVER")
        }

        let handledLuaConVar: Bool
        if let value = arguments.first {
            handledLuaConVar = conVars.setConsoleValue(value, for: command)
        } else if let currentValue = conVars.stringValue(for: command) {
            handledLuaConVar = conVars.setConsoleValue(currentValue, for: command)
        } else {
            handledLuaConVar = false
        }
        if handledLuaConVar { return }

        let invocation = GMLuaConsoleCommandInvocation(
            realm: .server,
            command: command,
            arguments: arguments
        )
        let handler: GMLuaConsoleCommandHostHandler? = {
            lock.lock()
            defer { lock.unlock() }
            return hostHandler
        }()
        if let handler {
            switch try handler(invocation) {
            case .handled:
                return
            case .unhandled:
                break
            case let .rejected(reason):
                throw LuaError.runtime(
                    "RunConsoleCommand host rejected command '\(command)': \(reason)"
                )
            }
        }
        if isRegistered(command) {
            try dispatchLuaCommand(
                command: command,
                arguments: arguments,
                caller: caller
            )
            return
        }
        if handler != nil {
            throw LuaError.runtime(
                "RunConsoleCommand host did not recognize engine command '\(command)'"
            )
        }
        throw LuaError.runtime(
            "RunConsoleCommand cannot execute SERVER command '\(command)' " +
            "because no console host or Lua concommand owns it"
        )
    }

    private func isRegistered(_ name: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return registeredNamesByKey[normalizedName(name)] != nil
    }

    private func consoleString(
        _ arguments: [LuaValue],
        index: Int,
        function: String
    ) throws -> String {
        guard arguments.indices.contains(index) else {
            throw badStringArgument(arguments, index: index, function: function)
        }
        let result: String
        switch arguments[index] {
        case let .string(value): result = value.utf8String
        case let .number(value): result = LuaValue.number(value).printable
        default:
            throw badStringArgument(arguments, index: index, function: function)
        }
        guard !result.contains("\0") else {
            throw LuaError.runtime(
                "bad argument #\(index + 1) to '\(function)' " +
                "(console strings cannot contain NUL bytes)"
            )
        }
        return result
    }

    private func badStringArgument(
        _ arguments: [LuaValue],
        index: Int,
        function: String
    ) -> LuaError {
        let actual = arguments.indices.contains(index) ? arguments[index].typeName : "no value"
        return .runtime(
            "bad argument #\(index + 1) to '\(function)' " +
            "(string expected, got \(actual))"
        )
    }

    private func normalizedName(_ name: String) -> String { name.lowercased() }
}
