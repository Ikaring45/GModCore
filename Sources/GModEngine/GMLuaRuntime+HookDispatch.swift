import GModLua

extension GMLuaRuntime {
    /// Resolves the live hook dispatcher and active gamemode for every engine
    /// event. Neither value is cached: addons may replace hook.Call and the
    /// startup orchestrator may replace GAMEMODE between host frames.
    public func dispatchHostHook(
        named event: String,
        arguments: [LuaValue] = []
    ) throws {
        guard !isClosed else {
            throw LuaError.runtime("cannot dispatch \(event) into a closed \(realm.rawValue) runtime")
        }
        guard case let .table(hookLibrary) = state.getGlobal("hook") else {
            throw LuaError.runtime("global hook table is unavailable for \(event)")
        }
        let call = try state.rawTableValue(for: .string("Call"), in: hookLibrary)
        switch call {
        case .luaFunction, .nativeFunction:
            break
        default:
            throw LuaError.runtime("hook.Call is \(call.typeName), expected function")
        }
        let gamemode = state.getGlobal("GAMEMODE")
        _ = try state.call(
            call,
            arguments: [.string(LuaString(event)), gamemode] + arguments
        )
    }

    /// Runs an engine-originated hook without allowing an addon failure to
    /// unwind the host lifecycle operation which produced the event. Source
    /// has already committed that operation by this boundary, so retrying the
    /// packet/tick would duplicate observable Lua work. The ordinary GLua
    /// error surface receives the diagnostic when it is available.
    @discardableResult
    func dispatchContainedHostHook(
        named event: String,
        arguments: [LuaValue] = []
    ) -> String? {
        do {
            try dispatchHostHook(named: event, arguments: arguments)
            return nil
        } catch {
            let message = "host hook \(event) failed: \(Self.describe(error))"
            let reporter = state.getGlobal("ErrorNoHaltWithStack")
            switch reporter {
            case .luaFunction, .nativeFunction:
                _ = try? state.call(
                    reporter,
                    arguments: [.string(LuaString(message + "\n"))]
                )
            default:
                break
            }
            return message
        }
    }
}
