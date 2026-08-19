import Dispatch
import Foundation
import GModLua

/// Host-owned high-resolution uptime source behind GLua's `SysTime`.
public protocol GMLuaSystemTimeSource: Sendable {
    func currentSystemTime() -> Double
}

/// Monotonic process-local clock. It is independent of wall-clock changes and
/// is sampled on every Lua call rather than once per Source frame.
public final class GMLuaMonotonicSystemTimeSource: GMLuaSystemTimeSource,
    @unchecked Sendable
{
    public static let process = GMLuaMonotonicSystemTimeSource()

    private let originNanoseconds: UInt64

    public init() {
        originNanoseconds = DispatchTime.now().uptimeNanoseconds
    }

    public func currentSystemTime() -> Double {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now >= originNanoseconds else { return 0 }
        return Double(now - originNanoseconds) / 1_000_000_000
    }
}

public enum GMLuaSystemTime {
    @discardableResult
    public static func install(
        into state: LuaState,
        source: any GMLuaSystemTimeSource
    ) -> any GMLuaSystemTimeSource {
        state.register("SysTime") { _ in
            let value = source.currentSystemTime()
            guard value.isFinite, value >= 0 else {
                throw LuaError.runtime(
                    "SysTime host source returned an invalid uptime"
                )
            }
            return [.number(value)]
        }
        return source
    }
}
