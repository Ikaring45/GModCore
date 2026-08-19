import Foundation
import GModLua

public extension GMLuaRuntime {
    /// Explicit Lua lifetime boundary. Hosts should call this when unloading a
    /// realm so reachable userdata receive Lua 5.1 close-time finalization.
    @discardableResult
    func close() -> LuaCloseReport {
        if isExecutingSourceAdapterOnCurrentThread {
            return LuaCloseReport(
                finalizedUserdataCount: 0,
                additionalPasses: 0,
                deferredNewFinalizerCount: 0,
                errorMessages: [
                    "GMLuaRuntime.close() rejected during Source adapter execution; " +
                    "close the realm after the host run returns"
                ]
            )
        }
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

extension GMLuaRuntime {
    /// Marks a runtime as participating in one Source adapter host run on the
    /// current thread. The marker is thread-local: a same-thread callback close
    /// is rejected, while a close from another thread still waits on the shared
    /// transport lifecycle boundary.
    func withSourceAdapterExecutionBoundary<T>(
        _ body: () throws -> T
    ) rethrows -> T {
        let threadDictionary = Thread.current.threadDictionary
        let key = sourceAdapterExecutionThreadMarkerKey
        let priorDepth = threadDictionary[key] as? Int ?? 0
        threadDictionary[key] = priorDepth + 1
        defer {
            if priorDepth == 0 {
                threadDictionary.removeObject(forKey: key)
            } else {
                threadDictionary[key] = priorDepth
            }
        }
        return try body()
    }

    private var isExecutingSourceAdapterOnCurrentThread: Bool {
        (Thread.current.threadDictionary[sourceAdapterExecutionThreadMarkerKey] as? Int ?? 0) > 0
    }

    private var sourceAdapterExecutionThreadMarkerKey: String {
        "GMLuaRuntime.sourceAdapterExecution.\(ObjectIdentifier(self))"
    }
}
