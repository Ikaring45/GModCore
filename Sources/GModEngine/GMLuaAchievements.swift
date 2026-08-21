import Foundation
import GModLua

/// A client achievement mutation requested by bundled Garry's Mod Lua.
///
/// The request is deliberately not presented as Steam progress or an unlock.
/// A platform host must connect it to the authenticated user's persistence
/// backend before it can affect an external achievement service.
public enum GMLuaAchievementRequest: Sendable, Equatable {
    /// Increment the "Menu User" spawn-menu-open counter once.
    case spawnMenuOpened
    /// Increment the bundled Sandbox prop-spawn counter once.
    case propSpawned
}

public typealias GMLuaAchievementRequestSink = @Sendable (
    GMLuaAchievementRequest
) -> Void

/// One atomic read/drain of the bounded offline request buffer.
public struct GMLuaAchievementRequestBufferSnapshot: Sendable, Equatable {
    public let requests: [GMLuaAchievementRequest]
    public let droppedRequestCount: UInt64
    public let didDropCountSaturate: Bool

    public init(
        requests: [GMLuaAchievementRequest],
        droppedRequestCount: UInt64,
        didDropCountSaturate: Bool
    ) {
        self.requests = requests
        self.droppedRequestCount = droppedRequestCount
        self.didDropCountSaturate = didDropCountSaturate
    }
}

/// Host handoff for the CLIENT-only `achievements` library.
///
/// Supported mutations enter a bounded value-only offline buffer and may also
/// be forwarded to a host sink. Overflow is explicit rather than allowing
/// addon Lua to grow process memory without bound. This gives the Lua call a
/// real observable effect without inventing Steam authentication, persistent
/// progress, or an achievement unlock. Unsupported progress/read APIs remain
/// absent.
public final class GMLuaAchievements: @unchecked Sendable {
    public static let maxBufferedRequests = 4_096

    public let realm: GMLuaRealm

    private let lock = NSLock()
    private var requestStorage: [GMLuaAchievementRequest] = []
    private var droppedRequestCountStorage: UInt64 = 0
    private var didDropCountSaturateStorage = false
    private var sinkStorage: GMLuaAchievementRequestSink?

    private init(
        realm: GMLuaRealm,
        requestSink: GMLuaAchievementRequestSink?
    ) {
        self.realm = realm
        sinkStorage = requestSink
    }

    /// Buffered requests not yet removed by ``drainCapturedRequests()``.
    /// This array never exceeds ``maxBufferedRequests``.
    public var capturedRequests: [GMLuaAchievementRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requestStorage
    }

    /// Number of calls omitted from the bounded buffer since its last drain.
    public var droppedRequestCount: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return droppedRequestCountStorage
    }

    /// Atomically removes the buffer and its overflow diagnostics.
    public func drainCapturedRequests() -> GMLuaAchievementRequestBufferSnapshot {
        lock.lock()
        defer { lock.unlock() }
        let drained = GMLuaAchievementRequestBufferSnapshot(
            requests: requestStorage,
            droppedRequestCount: droppedRequestCountStorage,
            didDropCountSaturate: didDropCountSaturateStorage
        )
        requestStorage.removeAll(keepingCapacity: true)
        droppedRequestCountStorage = 0
        didDropCountSaturateStorage = false
        return drained
    }

    /// Connects an authenticated/persistent host backend.
    ///
    /// Already captured requests remain available through
    /// ``drainCapturedRequests()``; connecting a sink does not replay them.
    public func connectRequestSink(
        _ sink: @escaping GMLuaAchievementRequestSink
    ) {
        lock.lock()
        sinkStorage = sink
        lock.unlock()
    }

    public func disconnectRequestSink() {
        lock.lock()
        sinkStorage = nil
        lock.unlock()
    }

    /// Installs only the authentic surface needed by bundled Sandbox today.
    /// SERVER and MENU are left untouched instead of receiving a fabricated
    /// local-player achievement service.
    @discardableResult
    public static func install(
        into state: LuaState,
        realm: GMLuaRealm,
        requestSink: GMLuaAchievementRequestSink? = nil
    ) throws -> GMLuaAchievements? {
        guard realm == .client else { return nil }

        let bridge = GMLuaAchievements(
            realm: realm,
            requestSink: requestSink
        )
        let table: LuaTable
        if case let .table(existing) = state.getGlobal("achievements") {
            table = existing
        } else {
            table = LuaTable()
        }

        let spawnMenuOpen = LuaValue.nativeFunction(
            LuaNativeFunctionBox(
                { [bridge] _ in
                    bridge.capture(.spawnMenuOpened)
                    return []
                },
                debugName: "achievements.SpawnMenuOpen"
            )
        )
        try state.setRawTableValue(
            spawnMenuOpen,
            for: .string("SpawnMenuOpen"),
            in: table
        )
        let spawnedProp = LuaValue.nativeFunction(
            LuaNativeFunctionBox(
                { [bridge] _ in
                    bridge.capture(.propSpawned)
                    return []
                },
                debugName: "achievements.SpawnedProp"
            )
        )
        try state.setRawTableValue(
            spawnedProp,
            for: .string("SpawnedProp"),
            in: table
        )
        state.setGlobal("achievements", value: .table(table))
        return bridge
    }

    private func capture(_ request: GMLuaAchievementRequest) {
        let sink: GMLuaAchievementRequestSink?
        lock.lock()
        if requestStorage.count < Self.maxBufferedRequests {
            requestStorage.append(request)
        } else if droppedRequestCountStorage < UInt64.max {
            droppedRequestCountStorage += 1
        } else {
            didDropCountSaturateStorage = true
        }
        sink = sinkStorage
        lock.unlock()
        sink?(request)
    }
}
