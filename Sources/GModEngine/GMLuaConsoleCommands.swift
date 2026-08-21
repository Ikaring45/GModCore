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

/// Host-owned SERVER route used by `Player:ConCommand`. The dispatcher first
/// validates that the receiver is its current Player generation; the
/// transport then binds the ordered parsed commands to the exact connected
/// CLIENT generation in the shared global FIFO.
typealias GMLuaTargetedClientConsoleHandler = @Sendable (
    _ player: LuaValue,
    _ playerIndex: Int,
    _ commands: [GMLuaConsoleCommandInvocation]
) throws -> Void

/// Additional host-owned predicate for GMod's binary console-command block
/// policy. The input is the lowercased, argument-free command name.
public typealias GMLuaConsoleCommandBlockPredicate = @Sendable (String) -> Bool

/// The open-source Lua layer exposes `IsConCommandBlocked`, but the complete
/// default list is owned by GMod's closed engine binaries. This snapshot makes
/// the modeled coverage explicit instead of presenting an empty fallback as
/// binary parity.
public struct GMLuaConsoleCommandBlockPolicySnapshot: Sendable, Equatable {
    public let explicitlyBlockedCommandNames: [String]
    public let hasAdditionalHostPredicate: Bool
    public let includesCompleteGModBinaryPolicy: Bool

    public init(
        explicitlyBlockedCommandNames: [String],
        hasAdditionalHostPredicate: Bool,
        includesCompleteGModBinaryPolicy: Bool
    ) {
        self.explicitlyBlockedCommandNames = explicitlyBlockedCommandNames
        self.hasAdditionalHostPredicate = hasAdditionalHostPredicate
        self.includesCompleteGModBinaryPolicy = includesCompleteGModBinaryPolicy
    }
}

public enum GMLuaPlayerConsoleCommandOutcome: Sendable, Equatable {
    case dispatched(commandCount: Int)
    case blocked(commandName: String)
    case ignoredEmptyCommand
    case failed(message: String)
}

/// One call that reached the native method captured by the stock CLIENT
/// `extensions/player.lua` queue. The raw string is retained alongside the
/// parsed command invocations so a host can audit ordering and quoting.
public struct GMLuaPlayerConsoleCommandRequest: Sendable, Equatable {
    public let sequence: UInt64
    public let realm: GMLuaRealm
    public let playerIndex: Int
    public let rawCommand: String
    public let parsedCommands: [GMLuaConsoleCommandInvocation]
    public let outcome: GMLuaPlayerConsoleCommandOutcome

    public init(
        sequence: UInt64,
        realm: GMLuaRealm,
        playerIndex: Int,
        rawCommand: String,
        parsedCommands: [GMLuaConsoleCommandInvocation],
        outcome: GMLuaPlayerConsoleCommandOutcome
    ) {
        self.sequence = sequence
        self.realm = realm
        self.playerIndex = playerIndex
        self.rawCommand = rawCommand
        self.parsedCommands = parsedCommands
        self.outcome = outcome
    }
}

public struct GMLuaPlayerConsoleCommandRequestReport: Sendable, Equatable {
    public let requests: [GMLuaPlayerConsoleCommandRequest]
    public let attemptedRequestCount: Int
    public let droppedRequestCount: Int

    public init(
        requests: [GMLuaPlayerConsoleCommandRequest],
        attemptedRequestCount: Int,
        droppedRequestCount: Int
    ) {
        self.requests = requests
        self.attemptedRequestCount = attemptedRequestCount
        self.droppedRequestCount = droppedRequestCount
    }
}

public enum GMLuaConsoleCommandPolicyError: Error, CustomStringConvertible, Equatable {
    case invalidBlockedCommandName(String)

    public var description: String {
        switch self {
        case let .invalidBlockedCommandName(name):
            return "blocked console command name must be one non-empty argument-free token: \(name)"
        }
    }
}

/// Internal typed boundary for an interactive remote command. Only expected
/// user-action outcomes belong here; host-handler throws and dispatcher
/// invariants continue to use Swift error propagation.
enum GMLuaRemoteConsoleCommandDispatchOutcome: Sendable, Equatable {
    case handled
    case actionFailure(message: String)
}

/// Host-private transaction around one outer CLIENT -> SERVER forwarded
/// command. The dispatcher deliberately does not expose this to Lua and keeps
/// only a weak host reference so command registration cannot retain engine
/// lifetime.
protocol GMLuaForwardedConsoleCommandTransactionHost: AnyObject {
    func withForwardedConsoleCommandTransaction(
        _ body: () throws -> GMLuaRemoteConsoleCommandDispatchOutcome
    ) throws -> GMLuaRemoteConsoleCommandDispatchOutcome
}

/// Carries a host/lifecycle/invariant error through a nested Lua call without
/// flattening its concrete type or object identity into a Lua error string.
private final class GMLuaConsoleFatalSentinel: Error, @unchecked Sendable {
    let underlying: Error

    init(_ underlying: Error) {
        self.underlying = underlying
    }
}

/// Thread-scoped side channel paired with the sentinel. Lua `pcall` may catch
/// arbitrary Swift errors and convert them to Lua values; retaining the first
/// fatal sentinel here ensures that cannot downgrade a host invariant into a
/// successful or recoverable user action.
private final class GMLuaConsoleReportingContext: @unchecked Sendable {
    var depth = 0
    var firstFatal: GMLuaConsoleFatalSentinel?
}

/// State-local bridge for Lua ConVars, Lua console commands, and real engine
/// commands supplied by an embedding host.
public final class GMLuaConsoleCommandDispatcher: @unchecked Sendable {
    public static let defaultMaximumPlayerConsoleCommandRequestCount = 1_024

    private let state: LuaState
    private let realm: GMLuaRealm
    private let conVars: GMLuaConVarRegistry
    private let entityRegistry: GMLuaEntityRegistry
    private let logger: (String) -> Void
    private let maximumPlayerConsoleCommandRequestCount: Int
    private let lock = NSLock()
    private var hostHandler: GMLuaConsoleCommandHostHandler?
    private var remoteServerHandler: GMLuaConsoleCommandHostHandler?
    private var targetedClientHandler: GMLuaTargetedClientConsoleHandler?
    private weak var forwardedCommandTransactionHost:
        (any GMLuaForwardedConsoleCommandTransactionHost)?
    private var blockedCommandNames: Set<String> = []
    private var blockPredicate: GMLuaConsoleCommandBlockPredicate?
    private var registeredNamesByKey: [String: String] = [:]
    private var registeredKeysInOrder: [String] = []
    private var playerConsoleCommandRequests: [GMLuaPlayerConsoleCommandRequest] = []
    private var attemptedPlayerConsoleCommandRequestCount = 0
    private var droppedPlayerConsoleCommandRequestCount = 0
    private var nextPlayerConsoleCommandRequestSequence: UInt64 = 0

    init(
        state: LuaState,
        realm: GMLuaRealm,
        conVars: GMLuaConVarRegistry,
        entityRegistry: GMLuaEntityRegistry,
        logger: @escaping (String) -> Void,
        maximumPlayerConsoleCommandRequestCount: Int =
            GMLuaConsoleCommandDispatcher.defaultMaximumPlayerConsoleCommandRequestCount
    ) {
        self.state = state
        self.realm = realm
        self.conVars = conVars
        self.entityRegistry = entityRegistry
        self.logger = logger
        self.maximumPlayerConsoleCommandRequestCount = max(
            0,
            maximumPlayerConsoleCommandRequestCount
        )
    }

    /// Commands registered through the native `AddConsoleCommand` ABI, in
    /// first-registration order. Names are matched case-insensitively.
    public var registeredCommands: [String] {
        lock.lock()
        defer { lock.unlock() }
        return registeredKeysInOrder.compactMap { registeredNamesByKey[$0] }
    }

    public var commandBlockPolicySnapshot: GMLuaConsoleCommandBlockPolicySnapshot {
        lock.lock()
        defer { lock.unlock() }
        return GMLuaConsoleCommandBlockPolicySnapshot(
            explicitlyBlockedCommandNames: blockedCommandNames.sorted(),
            hasAdditionalHostPredicate: blockPredicate != nil,
            // The complete default policy is compiled into GMod binaries and
            // has no authoritative source table in the installed Lua tree.
            includesCompleteGModBinaryPolicy: false
        )
    }

    public var pendingPlayerConsoleCommandRequestReport:
        GMLuaPlayerConsoleCommandRequestReport {
        lock.lock()
        defer { lock.unlock() }
        return playerConsoleCommandRequestReportLocked()
    }

    public func drainPlayerConsoleCommandRequestReport()
        -> GMLuaPlayerConsoleCommandRequestReport {
        lock.lock()
        defer { lock.unlock() }
        let report = playerConsoleCommandRequestReportLocked()
        playerConsoleCommandRequests.removeAll(keepingCapacity: true)
        attemptedPlayerConsoleCommandRequestCount = 0
        droppedPlayerConsoleCommandRequestCount = 0
        return report
    }

    /// Replaces the explicit, case-insensitive command-name portion of the
    /// block policy. Names are command tokens, not full command lines.
    public func replaceBlockedCommandNames(_ names: Set<String>) throws {
        var normalized: Set<String> = []
        normalized.reserveCapacity(names.count)
        for name in names {
            let parsed = try Self.parseConsoleCommandLine(name, function: "blocked policy")
            guard parsed.count == 1,
                  parsed[0].arguments.isEmpty,
                  parsed[0].command == name.trimmingCharacters(in: .whitespacesAndNewlines)
            else {
                throw GMLuaConsoleCommandPolicyError.invalidBlockedCommandName(name)
            }
            normalized.insert(normalizedName(parsed[0].command))
        }
        lock.lock()
        blockedCommandNames = normalized
        lock.unlock()
    }

    public func connectCommandBlockPredicate(
        _ predicate: @escaping GMLuaConsoleCommandBlockPredicate
    ) {
        lock.lock()
        blockPredicate = predicate
        lock.unlock()
    }

    public func disconnectCommandBlockPredicate() {
        lock.lock()
        blockPredicate = nil
        lock.unlock()
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

    func connectTargetedClients(
        _ handler: @escaping GMLuaTargetedClientConsoleHandler
    ) {
        lock.lock()
        targetedClientHandler = handler
        lock.unlock()
    }

    func connectForwardedCommandTransactionHost(
        _ host: any GMLuaForwardedConsoleCommandTransactionHost
    ) {
        lock.lock()
        forwardedCommandTransactionHost = host
        lock.unlock()
    }

    func disconnectForwardedCommandTransactionHost(
        _ host: any GMLuaForwardedConsoleCommandTransactionHost
    ) {
        lock.lock()
        if let current = forwardedCommandTransactionHost,
           current === host {
            forwardedCommandTransactionHost = nil
        }
        lock.unlock()
    }

    func installBindings() throws {
        state.register("AddConsoleCommand") { [unowned self] arguments in
            try self.addConsoleCommand(arguments)
        }
        state.register("RunConsoleCommand") { [unowned self] arguments in
            try self.runConsoleCommand(arguments)
        }
        state.register("IsConCommandBlocked") { [unowned self] arguments in
            let rawCommand = try self.requiredExactConsoleString(
                arguments,
                index: 0,
                function: "IsConCommandBlocked"
            )
            let parsed = try Self.parseConsoleCommandLine(
                rawCommand,
                function: "IsConCommandBlocked"
            )
            return [.boolean(parsed.contains { self.isCommandBlocked($0.command) })]
        }
        try entityRegistry.installPlayerMethod(
            named: "ConCommand",
            function: .nativeFunction(
                LuaNativeFunctionBox(
                    { [unowned self] arguments in
                        try self.playerConCommand(arguments)
                    },
                    debugName: "Player:ConCommand"
                )
            )
        )
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

    private func playerConCommand(_ arguments: [LuaValue]) throws -> [LuaValue] {
        guard let receiver = arguments.first else {
            throw LuaError.runtime(
                "bad self to 'Player:ConCommand' (Player expected, got no value)"
            )
        }
        let playerIndex = try entityRegistry.playerNetworkIndex(
            from: receiver,
            function: "Player:ConCommand"
        )
        let rawCommand = try requiredExactConsoleString(
            arguments,
            index: 1,
            function: "ConCommand",
            visibleArgumentPosition: 1
        )
        let parsed = try Self.parseConsoleCommandLine(
            rawCommand,
            function: "Player:ConCommand"
        )
        let invocations = parsed.map {
            GMLuaConsoleCommandInvocation(
                realm: realm,
                command: $0.command,
                arguments: $0.arguments
            )
        }

        guard !parsed.isEmpty else {
            recordPlayerConsoleCommandRequest(
                playerIndex: playerIndex,
                rawCommand: rawCommand,
                parsedCommands: [],
                outcome: .ignoredEmptyCommand
            )
            return []
        }
        if let blocked = parsed.first(where: { isCommandBlocked($0.command) }) {
            let name = normalizedName(blocked.command)
            recordPlayerConsoleCommandRequest(
                playerIndex: playerIndex,
                rawCommand: rawCommand,
                parsedCommands: invocations,
                outcome: .blocked(commandName: name)
            )
            // GMod reports a blocked Player:ConCommand to the console without
            // turning the Lua call itself into a successful engine dispatch.
            logger("ConCommand blocked! (\(name))")
            return []
        }

        if realm == .server {
            let handler: GMLuaTargetedClientConsoleHandler? = {
                lock.lock()
                defer { lock.unlock() }
                return targetedClientHandler
            }()
            guard let handler else {
                let message =
                    "Player:ConCommand target CLIENT transport is unavailable"
                recordPlayerConsoleCommandRequest(
                    playerIndex: playerIndex,
                    rawCommand: rawCommand,
                    parsedCommands: invocations,
                    outcome: .failed(message: message)
                )
                throw LuaError.runtime(message)
            }
            do {
                try handler(receiver, playerIndex, invocations)
                recordPlayerConsoleCommandRequest(
                    playerIndex: playerIndex,
                    rawCommand: rawCommand,
                    parsedCommands: invocations,
                    outcome: .dispatched(commandCount: parsed.count)
                )
                return []
            } catch {
                recordPlayerConsoleCommandRequest(
                    playerIndex: playerIndex,
                    rawCommand: rawCommand,
                    parsedCommands: invocations,
                    outcome: .failed(message: GMLuaRuntime.describe(error))
                )
                throw error
            }
        }

        do {
            let runner = state.getGlobal("RunConsoleCommand")
            guard runner.typeName == "function" else {
                throw LuaError.runtime(
                    "Player:ConCommand cannot execute because RunConsoleCommand is unavailable"
                )
            }
            for command in parsed {
                _ = try state.call(
                    runner,
                    arguments: [
                        .string(LuaString(command.command)),
                    ] + command.arguments.map { .string(LuaString($0)) }
                )
            }
            recordPlayerConsoleCommandRequest(
                playerIndex: playerIndex,
                rawCommand: rawCommand,
                parsedCommands: invocations,
                outcome: .dispatched(commandCount: parsed.count)
            )
            return []
        } catch {
            recordPlayerConsoleCommandRequest(
                playerIndex: playerIndex,
                rawCommand: rawCommand,
                parsedCommands: invocations,
                outcome: .failed(message: GMLuaRuntime.describe(error))
            )
            throw error
        }
    }

    /// Executes one SERVER-targeted delivery through the destination CLIENT's
    /// ordinary console dispatcher at the transport pump boundary. Parsed
    /// command order is retained; this is not a direct `concommand.Run` call.
    func dispatchTargetedClientCommand(
        command: String,
        arguments: [String]
    ) throws {
        guard realm == .client else {
            throw LuaError.runtime(
                "targeted console command destination is not CLIENT"
            )
        }
        _ = try runConsoleCommand(
            [.string(LuaString(command))] +
                arguments.map { .string(LuaString($0)) }
        )
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
            let disposition: GMLuaConsoleCommandHostDisposition
            do {
                disposition = try handler(invocation)
            } catch {
                throw nestedFatalError(error)
            }
            switch disposition {
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
            let disposition: GMLuaConsoleCommandHostDisposition
            do {
                disposition = try remoteHandler(invocation)
            } catch {
                throw nestedFatalError(error)
            }
            switch disposition {
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
        let call: (function: LuaValue, arguments: [LuaValue])
        do {
            call = try makeLuaCommandCall(
                command: command,
                arguments: arguments,
                caller: caller
            )
        } catch {
            // During a reporting body this is a nested dispatcher invariant;
            // outside that scope the original strict error is returned as-is.
            throw nestedFatalError(error)
        }
        _ = try state.call(call.function, arguments: call.arguments)
    }

    private func dispatchLuaCommandReportingBodyFailure(
        command: String,
        arguments: [String],
        caller: LuaValue
    ) throws -> GMLuaRemoteConsoleCommandDispatchOutcome {
        // Missing concommand.Run or failure to build the call is a dispatcher
        // invariant and therefore occurs outside the action-failure catch.
        let call = try makeLuaCommandCall(
            command: command,
            arguments: arguments,
            caller: caller
        )
        do {
            _ = try withReportingLuaCommandBody {
                try state.call(call.function, arguments: call.arguments)
            }
            return .handled
        } catch let sentinel as GMLuaConsoleFatalSentinel {
            throw sentinel.underlying
        } catch {
            return .actionFailure(message: GMLuaRuntime.describe(error))
        }
    }

    private func makeLuaCommandCall(
        command: String,
        arguments: [String],
        caller: LuaValue
    ) throws -> (function: LuaValue, arguments: [LuaValue]) {
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
        return (
            function: runner,
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
        let outcome = try dispatchRemoteCommandClassifyingActionFailures(
            command: command,
            arguments: arguments,
            caller: caller,
            reportActionFailures: false
        )
        if case let .actionFailure(message) = outcome {
            // The strict path throws action failures at their original branch;
            // this is a defensive exhaustiveness guard.
            throw LuaError.runtime(message)
        }
    }

    func dispatchRemoteCommandReportingActionFailures(
        command: String,
        arguments: [String],
        caller: LuaValue
    ) throws -> GMLuaRemoteConsoleCommandDispatchOutcome {
        try dispatchRemoteCommandClassifyingActionFailures(
            command: command,
            arguments: arguments,
            caller: caller,
            reportActionFailures: true
        )
    }

    private func dispatchRemoteCommandClassifyingActionFailures(
        command: String,
        arguments: [String],
        caller: LuaValue,
        reportActionFailures: Bool
    ) throws -> GMLuaRemoteConsoleCommandDispatchOutcome {
        guard realm == .server else {
            throw LuaError.runtime("remote console command destination is not SERVER")
        }

        let transactionHost: (any GMLuaForwardedConsoleCommandTransactionHost)? = {
            lock.lock()
            defer { lock.unlock() }
            return forwardedCommandTransactionHost
        }()
        if let transactionHost {
            return try transactionHost.withForwardedConsoleCommandTransaction {
                try self.dispatchRemoteCommandWithoutTransaction(
                    command: command,
                    arguments: arguments,
                    caller: caller,
                    reportActionFailures: reportActionFailures
                )
            }
        }
        return try dispatchRemoteCommandWithoutTransaction(
            command: command,
            arguments: arguments,
            caller: caller,
            reportActionFailures: reportActionFailures
        )
    }

    private func dispatchRemoteCommandWithoutTransaction(
        command: String,
        arguments: [String],
        caller: LuaValue,
        reportActionFailures: Bool
    ) throws -> GMLuaRemoteConsoleCommandDispatchOutcome {
        let handledLuaConVar: Bool
        if let value = arguments.first {
            handledLuaConVar = conVars.setConsoleValue(value, for: command)
        } else if let currentValue = conVars.stringValue(for: command) {
            handledLuaConVar = conVars.setConsoleValue(currentValue, for: command)
        } else {
            handledLuaConVar = false
        }
        if handledLuaConVar { return .handled }

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
            // A throwing engine host is an invariant/lifecycle error, not an
            // expected rejected action. Keep it outside every reporting catch.
            switch try handler(invocation) {
            case .handled:
                return .handled
            case .unhandled:
                break
            case let .rejected(reason):
                return try actionFailure(
                    "RunConsoleCommand host rejected command '\(command)': \(reason)",
                    report: reportActionFailures
                )
            }
        }
        if isRegistered(command) {
            if reportActionFailures {
                return try dispatchLuaCommandReportingBodyFailure(
                    command: command,
                    arguments: arguments,
                    caller: caller
                )
            }
            try dispatchLuaCommand(
                command: command,
                arguments: arguments,
                caller: caller
            )
            return .handled
        }
        if handler != nil {
            return try actionFailure(
                "RunConsoleCommand host did not recognize engine command '\(command)'",
                report: reportActionFailures
            )
        }
        return try actionFailure(
            "RunConsoleCommand cannot execute SERVER command '\(command)' " +
                "because no console host or Lua concommand owns it",
            report: reportActionFailures
        )
    }

    private func actionFailure(
        _ message: String,
        report: Bool
    ) throws -> GMLuaRemoteConsoleCommandDispatchOutcome {
        if report { return .actionFailure(message: message) }
        throw LuaError.runtime(message)
    }

    private var reportingContextThreadKey: String {
        "GMLuaConsoleCommandDispatcher.reporting.\(ObjectIdentifier(self))"
    }

    private func withReportingLuaCommandBody<T>(
        _ body: () throws -> T
    ) throws -> T {
        let dictionary = Thread.current.threadDictionary
        let key = reportingContextThreadKey
        let existing = dictionary[key] as? GMLuaConsoleReportingContext
        let context = existing ?? GMLuaConsoleReportingContext()
        if existing == nil { dictionary[key] = context }
        context.depth += 1
        defer {
            context.depth -= 1
            if context.depth == 0 {
                dictionary.removeObject(forKey: key)
            }
        }

        do {
            let result = try body()
            if let fatal = context.firstFatal { throw fatal }
            return result
        } catch {
            if let fatal = context.firstFatal { throw fatal }
            throw error
        }
    }

    /// Wraps only while a reporting Lua body is active. This makes the strict
    /// dispatcher path preserve the original concrete error and identity.
    private func nestedFatalError(_ error: Error) -> Error {
        let dictionary = Thread.current.threadDictionary
        guard let context = dictionary[reportingContextThreadKey]
            as? GMLuaConsoleReportingContext else {
            return error
        }
        let sentinel = (error as? GMLuaConsoleFatalSentinel)
            ?? GMLuaConsoleFatalSentinel(error)
        if context.firstFatal == nil { context.firstFatal = sentinel }
        return sentinel
    }

    private func isRegistered(_ name: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return registeredNamesByKey[normalizedName(name)] != nil
    }

    private func isCommandBlocked(_ name: String) -> Bool {
        let normalized = normalizedName(name)
        let explicit: Bool
        let predicate: GMLuaConsoleCommandBlockPredicate?
        lock.lock()
        explicit = blockedCommandNames.contains(normalized)
        predicate = blockPredicate
        lock.unlock()
        return explicit || predicate?(normalized) == true
    }

    private func recordPlayerConsoleCommandRequest(
        playerIndex: Int,
        rawCommand: String,
        parsedCommands: [GMLuaConsoleCommandInvocation],
        outcome: GMLuaPlayerConsoleCommandOutcome
    ) {
        lock.lock()
        attemptedPlayerConsoleCommandRequestCount += 1
        nextPlayerConsoleCommandRequestSequence &+= 1
        if playerConsoleCommandRequests.count < maximumPlayerConsoleCommandRequestCount {
            playerConsoleCommandRequests.append(GMLuaPlayerConsoleCommandRequest(
                sequence: nextPlayerConsoleCommandRequestSequence,
                realm: realm,
                playerIndex: playerIndex,
                rawCommand: rawCommand,
                parsedCommands: parsedCommands,
                outcome: outcome
            ))
        } else {
            droppedPlayerConsoleCommandRequestCount += 1
        }
        lock.unlock()
    }

    private func playerConsoleCommandRequestReportLocked()
        -> GMLuaPlayerConsoleCommandRequestReport {
        GMLuaPlayerConsoleCommandRequestReport(
            requests: playerConsoleCommandRequests,
            attemptedRequestCount: attemptedPlayerConsoleCommandRequestCount,
            droppedRequestCount: droppedPlayerConsoleCommandRequestCount
        )
    }

    private struct ParsedConsoleCommand {
        let command: String
        let arguments: [String]
    }

    /// Tokenizes the Source-style command strings passed by native
    /// Player:ConCommand. Quotes preserve whitespace, backslash escapes a quote
    /// or backslash inside quotes, and newline/semicolon delimit commands.
    private static func parseConsoleCommandLine(
        _ source: String,
        function: String
    ) throws -> [ParsedConsoleCommand] {
        var result: [ParsedConsoleCommand] = []
        var tokens: [String] = []
        var token = ""
        var tokenStarted = false
        var quote: Character?
        var escaped = false

        func finishToken() {
            guard tokenStarted else { return }
            tokens.append(token)
            token.removeAll(keepingCapacity: true)
            tokenStarted = false
        }
        func finishCommand() {
            finishToken()
            guard let command = tokens.first, !command.isEmpty else {
                tokens.removeAll(keepingCapacity: true)
                return
            }
            result.append(ParsedConsoleCommand(
                command: command,
                arguments: Array(tokens.dropFirst())
            ))
            tokens.removeAll(keepingCapacity: true)
        }

        for character in source {
            if let activeQuote = quote {
                tokenStarted = true
                if escaped {
                    if character != activeQuote, character != "\\" {
                        token.append("\\")
                    }
                    token.append(character)
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == activeQuote {
                    quote = nil
                } else {
                    token.append(character)
                }
                continue
            }

            switch character {
            case "\"", "'":
                quote = character
                tokenStarted = true
            case ";", "\n", "\r":
                finishCommand()
            default:
                if character.isWhitespace {
                    finishToken()
                } else {
                    tokenStarted = true
                    token.append(character)
                }
            }
        }
        if escaped { token.append("\\") }
        guard quote == nil else {
            throw LuaError.runtime("\(function): unterminated quoted console argument")
        }
        finishCommand()
        return result
    }

    private func requiredExactConsoleString(
        _ arguments: [LuaValue],
        index: Int,
        function: String,
        visibleArgumentPosition: Int? = nil
    ) throws -> String {
        let position = visibleArgumentPosition ?? index + 1
        guard arguments.indices.contains(index),
              case let .string(value) = arguments[index] else {
            let actual = arguments.indices.contains(index)
                ? arguments[index].typeName
                : "no value"
            throw LuaError.runtime(
                "bad argument #\(position) to '\(function)' " +
                "(string expected, got \(actual))"
            )
        }
        let result = value.utf8String
        guard !result.contains("\0") else {
            throw LuaError.runtime(
                "bad argument #\(position) to '\(function)' " +
                "(console strings cannot contain NUL bytes)"
            )
        }
        return result
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
