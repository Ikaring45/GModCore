import GModLua

public enum GMLuaClientConsoleCommandInvocationError:
    Error,
    Equatable,
    Sendable,
    CustomStringConvertible
{
    case runtimeClosed
    case clientRealmRequired(actualRealm: String)
    case runConsoleCommandUnavailable(actualType: String)
    case consoleCommandDispatcherUnavailable

    public var description: String {
        switch self {
        case .runtimeClosed:
            return "CLIENT RunConsoleCommand runtime is closed"
        case let .clientRealmRequired(actualRealm):
            return "CLIENT RunConsoleCommand requires CLIENT, got \(actualRealm)"
        case let .runConsoleCommandUnavailable(actualType):
            return "CLIENT global RunConsoleCommand is unavailable (got \(actualType))"
        case .consoleCommandDispatcherUnavailable:
            return "CLIENT console command dispatcher is unavailable"
        }
    }
}

public extension GMLuaRuntime {
    /// Calls the live CLIENT global `RunConsoleCommand` with separate Lua
    /// string values. No Lua source is generated or concatenated, so command
    /// and argument bytes cannot become executable syntax at this boundary.
    /// The caller must invoke this on the runtime's serialized lane.
    func invokeClientRunConsoleCommand(
        command: String,
        arguments: [String] = []
    ) throws {
        guard !isClosed else {
            throw GMLuaClientConsoleCommandInvocationError.runtimeClosed
        }
        switch realm {
        case .client:
            break
        case .server, .menu:
            throw GMLuaClientConsoleCommandInvocationError
                .clientRealmRequired(actualRealm: realm.rawValue)
        }

        let runConsoleCommand = state.getGlobal("RunConsoleCommand")
        switch runConsoleCommand {
        case .luaFunction, .nativeFunction:
            break
        default:
            throw GMLuaClientConsoleCommandInvocationError
                .runConsoleCommandUnavailable(
                    actualType: runConsoleCommand.typeName
                )
        }
        _ = try state.call(
            runConsoleCommand,
            arguments: [.string(LuaString(command))] + arguments.map {
                .string(LuaString($0))
            }
        )
    }

    /// Executes one user-entered Source console line through the live CLIENT
    /// `RunConsoleCommand` bridge. The dispatcher's existing tokenizer retains
    /// quoted arguments and semicolon/newline command ordering, while every
    /// value crosses into Lua as a separate string instead of executable source.
    /// The caller must invoke this on the runtime's serialized lane.
    @discardableResult
    func invokeClientConsoleCommandLine(_ source: String) throws -> Int {
        guard !isClosed else {
            throw GMLuaClientConsoleCommandInvocationError.runtimeClosed
        }
        switch realm {
        case .client:
            break
        case .server, .menu:
            throw GMLuaClientConsoleCommandInvocationError
                .clientRealmRequired(actualRealm: realm.rawValue)
        }
        guard let consoleCommandDispatcher else {
            throw GMLuaClientConsoleCommandInvocationError
                .consoleCommandDispatcherUnavailable
        }

        let invocations = try consoleCommandDispatcher
            .parseInteractiveConsoleCommandLine(source)
        for invocation in invocations {
            try invokeClientRunConsoleCommand(
                command: invocation.command,
                arguments: invocation.arguments
            )
        }
        return invocations.count
    }
}
