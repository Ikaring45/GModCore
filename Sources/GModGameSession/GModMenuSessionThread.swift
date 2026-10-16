import Foundation
import GModEngine

/// Owned execution environment for the recursive MENU Lua/VGUI graph.
/// The cooperative pool has no engine-sized stack or stable thread identity.
/// Use this executor for the actor owning the session, including startup and
/// fallback teardown, rather than dispatching individual Lua calls to Tasks.
public final class GModMenuSessionThread: @unchecked Sendable {
    private let executor = GModPlayableSessionDedicatedExecutor(name: "GMod MENU Lua")

    public init() {}

    public var unownedExecutor: UnownedSerialExecutor {
        executor.asUnownedSerialExecutor()
    }

    public var isCurrentWorker: Bool { executor.isCurrentWorker }
    public var workerIdentity: String { executor.workerIdentity }
    public static var stackSize: Int { GModPlayableSessionDedicatedExecutor.stackSize }

    public func preconditionIsCurrentWorker() {
        executor.preconditionIsCurrentWorker()
    }

    public func retainForShutdown(_ session: GMLuaMenuSession) {
        executor.preconditionIsCurrentWorker()
        executor.replaceShutdownCleanup { _ in
            _ = session.close()
        }
    }

    public func clearShutdownCleanup() {
        executor.preconditionIsCurrentWorker()
        executor.clearShutdownCleanup()
    }
}
