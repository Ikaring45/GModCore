import GModLua

extension GMLuaRuntime {
    /// Resolves the live hook dispatcher and active gamemode for every engine
    /// event. Neither value is cached: addons may replace hook.Call and the
    /// startup orchestrator may replace GAMEMODE between host frames.
    public func dispatchHostHook(named event: String) throws {
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
            arguments: [.string(LuaString(event)), gamemode]
        )
    }
}
