import GModLua

public extension GMLuaRuntime {
    /// Explicit Lua lifetime boundary. Hosts should call this when unloading a
    /// realm so reachable userdata receive Lua 5.1 close-time finalization.
    @discardableResult
    func close() -> LuaCloseReport {
        if let netEndpoint, let netTransport {
            if netTransport.isPumpingOnCurrentThread() {
                return LuaCloseReport(
                    finalizedUserdataCount: 0,
                    additionalPasses: 0,
                    deferredNewFinalizerCount: 0,
                    errorMessages: [
                        "GMLuaRuntime.close() rejected during a Lua delivery callback; " +
                        "close the realm after the host pump returns"
                    ]
                )
            }
            return netTransport.withExclusiveLifecycleBoundary {
                netTransport.detachEndpoint(netEndpoint)
                return state.close()
            }
        }
        return state.close()
    }

    var isClosed: Bool { state.isClosed }
}
