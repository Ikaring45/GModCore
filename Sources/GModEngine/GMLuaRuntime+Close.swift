import GModLua

public extension GMLuaRuntime {
    /// Explicit Lua lifetime boundary. Hosts should call this when unloading a
    /// realm so reachable userdata receive Lua 5.1 close-time finalization.
    @discardableResult
    func close() -> LuaCloseReport {
        if let netEndpoint, let netTransport {
            netTransport.detachEndpoint(netEndpoint)
        }
        return state.close()
    }

    var isClosed: Bool { state.isClosed }
}
