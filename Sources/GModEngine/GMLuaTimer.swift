import Foundation
import GModLua

public struct GMLuaTimerFailure: Sendable, Equatable {
    public let identifier: String
    public let message: String
}

private struct GMLuaTimerEntry {
    var delay: Double
    var configuredRepetitions: Int
    var repetitionsLeft: Int
    var callback: LuaValue
    var nextFireTime: Double
    var pausedTimeLeft: Double?
    var isStopped: Bool
    var generation: UInt64
    var removeAfterCallback: Bool
    var removeOnNextTick: Bool
}

/// State-local implementation of GLua's CurTime-driven timer scheduler.
///
/// The simulation host owns time: no wall-clock thread is created. Calling
/// `advance(by:)` from the fixed tick makes timer callbacks deterministic on
/// Windows and iPad and keeps Lua execution on the realm's owning thread.
public final class GMLuaTimerScheduler: @unchecked Sendable {
    private let state: LuaState
    private let minimumDelay: Double
    private let lock = NSLock()
    private var entries: [LuaString: GMLuaTimerEntry] = [:]
    private var currentTimeStorage: Double = 0
    private var nextGeneration: UInt64 = 1
    private var nextSimpleIdentifier: UInt64 = 1

    fileprivate init(state: LuaState, minimumDelay: Double) {
        self.state = state
        self.minimumDelay = minimumDelay
    }

    public var currentTime: Double {
        lock.lock()
        defer { lock.unlock() }
        return currentTimeStorage
    }

    public var timerCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    /// Advances CurTime and executes every timer due on this simulation tick.
    /// Callback errors are isolated and returned to the host; later timers are
    /// still dispatched, matching GMod's protected engine-to-Lua boundary.
    @discardableResult
    public func advance(by delta: Double) throws -> [GMLuaTimerFailure] {
        guard delta.isFinite, delta >= 0 else {
            throw LuaError.runtime("timer advance delta must be a finite non-negative number")
        }

        lock.lock()
        currentTimeStorage += delta
        entries = entries.filter { !$0.value.removeOnNextTick }
        lock.unlock()

        var failures: [GMLuaTimerFailure] = []
        var dispatchCount = 0
        while dispatchCount < 100_000 {
            let due: (identifier: LuaString, generation: UInt64, callback: LuaValue)?
            lock.lock()
            let now = currentTimeStorage
            let candidate = entries
                .filter { _, entry in
                    !entry.isStopped
                        && entry.pausedTimeLeft == nil
                        && !entry.removeOnNextTick
                        && entry.nextFireTime <= now
                }
                .min { lhs, rhs in
                    if lhs.value.nextFireTime != rhs.value.nextFireTime {
                        return lhs.value.nextFireTime < rhs.value.nextFireTime
                    }
                    return lhs.key < rhs.key
                }

            if let candidate {
                var entry = candidate.value
                if entry.repetitionsLeft > 0 {
                    entry.repetitionsLeft -= 1
                    entry.removeAfterCallback = entry.repetitionsLeft == 0
                }
                entry.nextFireTime = now + effectiveDelay(entry.delay)
                entries[candidate.key] = entry
                due = (candidate.key, entry.generation, entry.callback)
            } else {
                due = nil
            }
            lock.unlock()

            guard let due else { break }
            dispatchCount += 1
            do {
                _ = try state.call(due.callback)
            } catch {
                failures.append(
                    GMLuaTimerFailure(
                        identifier: due.identifier.utf8String,
                        message: Self.describe(error)
                    )
                )
            }

            lock.lock()
            if let current = entries[due.identifier],
               current.generation == due.generation,
               current.removeAfterCallback {
                entries.removeValue(forKey: due.identifier)
            }
            lock.unlock()
        }

        if dispatchCount == 100_000 {
            failures.append(
                GMLuaTimerFailure(
                    identifier: "<scheduler>",
                    message: "timer dispatch limit exceeded in one simulation tick"
                )
            )
        }
        return failures
    }

    fileprivate var references: [LuaValue] {
        lock.lock()
        defer { lock.unlock() }
        return entries.values.map(\.callback)
    }

    fileprivate func create(
        identifier: LuaString,
        delay: Double,
        repetitions: Int,
        callback: LuaValue
    ) {
        lock.lock()
        let generation = allocateGenerationLocked()
        let normalizedRepetitions = repetitions <= 0 ? 0 : repetitions
        entries[identifier] = GMLuaTimerEntry(
            delay: max(0, delay),
            configuredRepetitions: normalizedRepetitions,
            repetitionsLeft: normalizedRepetitions,
            callback: callback,
            nextFireTime: currentTimeStorage + effectiveDelay(max(0, delay)),
            pausedTimeLeft: nil,
            isStopped: false,
            generation: generation,
            removeAfterCallback: false,
            removeOnNextTick: false
        )
        lock.unlock()
    }

    fileprivate func createSimple(delay: Double, callback: LuaValue) {
        lock.lock()
        let identifier = LuaString("__gmod_simple_\(nextSimpleIdentifier)")
        nextSimpleIdentifier &+= 1
        let generation = allocateGenerationLocked()
        entries[identifier] = GMLuaTimerEntry(
            delay: max(0, delay),
            configuredRepetitions: 1,
            repetitionsLeft: 1,
            callback: callback,
            nextFireTime: currentTimeStorage + effectiveDelay(max(0, delay)),
            pausedTimeLeft: nil,
            isStopped: false,
            generation: generation,
            removeAfterCallback: false,
            removeOnNextTick: false
        )
        lock.unlock()
    }

    fileprivate func remove(_ identifier: LuaString) {
        lock.lock()
        if var entry = entries[identifier] {
            // The native engine removes named timers on the following frame.
            // Keep identity observable until the host advances one tick while
            // preventing another callback from being selected meanwhile.
            entry.removeOnNextTick = true
            entry.generation = allocateGenerationLocked()
            entries[identifier] = entry
        }
        lock.unlock()
    }

    fileprivate func exists(_ identifier: LuaString) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return entries[identifier] != nil
    }

    fileprivate func adjust(
        _ identifier: LuaString,
        delay: Double,
        repetitions: Int?,
        callback: LuaValue?
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard var entry = entries[identifier] else { return false }
        entry.delay = max(0, delay)
        if let repetitions {
            let normalized = repetitions <= 0 ? 0 : repetitions
            entry.configuredRepetitions = normalized
            entry.repetitionsLeft = normalized
        }
        if let callback { entry.callback = callback }
        entry.nextFireTime = currentTimeStorage + effectiveDelay(entry.delay)
        entry.pausedTimeLeft = nil
        entry.isStopped = false
        entry.removeAfterCallback = false
        entry.removeOnNextTick = false
        entry.generation = allocateGenerationLocked()
        entries[identifier] = entry
        return true
    }

    fileprivate func pause(_ identifier: LuaString) {
        lock.lock()
        defer { lock.unlock() }
        guard var entry = entries[identifier],
              entry.pausedTimeLeft == nil,
              !entry.isStopped else { return }
        entry.pausedTimeLeft = max(0, entry.nextFireTime - currentTimeStorage)
        entry.generation = allocateGenerationLocked()
        entries[identifier] = entry
    }

    fileprivate func unpause(_ identifier: LuaString) {
        lock.lock()
        defer { lock.unlock() }
        guard var entry = entries[identifier], let remaining = entry.pausedTimeLeft else { return }
        entry.pausedTimeLeft = nil
        entry.isStopped = false
        entry.nextFireTime = currentTimeStorage + remaining
        entry.generation = allocateGenerationLocked()
        entries[identifier] = entry
    }

    fileprivate func toggle(_ identifier: LuaString) {
        lock.lock()
        defer { lock.unlock() }
        guard var entry = entries[identifier] else { return }
        if let remaining = entry.pausedTimeLeft {
            entry.pausedTimeLeft = nil
            entry.isStopped = false
            entry.nextFireTime = currentTimeStorage + remaining
        } else if !entry.isStopped {
            entry.pausedTimeLeft = max(0, entry.nextFireTime - currentTimeStorage)
        }
        entry.generation = allocateGenerationLocked()
        entries[identifier] = entry
    }

    fileprivate func stop(_ identifier: LuaString) {
        lock.lock()
        defer { lock.unlock() }
        guard var entry = entries[identifier] else { return }
        entry.isStopped = true
        entry.pausedTimeLeft = nil
        entry.repetitionsLeft = entry.configuredRepetitions
        entry.nextFireTime = currentTimeStorage + effectiveDelay(entry.delay)
        entry.removeAfterCallback = false
        entry.removeOnNextTick = false
        entry.generation = allocateGenerationLocked()
        entries[identifier] = entry
    }

    fileprivate func start(_ identifier: LuaString) {
        lock.lock()
        defer { lock.unlock() }
        guard var entry = entries[identifier] else { return }
        entry.isStopped = false
        entry.pausedTimeLeft = nil
        entry.repetitionsLeft = entry.configuredRepetitions
        entry.nextFireTime = currentTimeStorage + effectiveDelay(entry.delay)
        entry.removeAfterCallback = false
        entry.removeOnNextTick = false
        entry.generation = allocateGenerationLocked()
        entries[identifier] = entry
    }

    fileprivate func isPaused(_ identifier: LuaString) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[identifier] else { return false }
        return entry.pausedTimeLeft != nil || entry.isStopped
    }

    fileprivate func timeLeft(_ identifier: LuaString) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[identifier] else { return nil }
        if let paused = entry.pausedTimeLeft { return -paused }
        if entry.isStopped { return -entry.delay }
        return entry.nextFireTime - currentTimeStorage
    }

    fileprivate func repetitionsLeft(_ identifier: LuaString) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        return entries[identifier]?.repetitionsLeft
    }

    private func effectiveDelay(_ delay: Double) -> Double {
        max(delay, minimumDelay)
    }

    private func allocateGenerationLocked() -> UInt64 {
        let value = nextGeneration
        nextGeneration &+= 1
        return value
    }

    private static func describe(_ error: Error) -> String {
        if let raised = error as? LuaRaisedError { return raised.value.printable }
        return String(describing: error)
    }
}

/// Installs GLua's documented timer table over a host-driven scheduler.
public enum GMLuaTimer {
    @discardableResult
    public static func install(
        into state: LuaState,
        minimumTickInterval: Double = 0.015
    ) throws -> GMLuaTimerScheduler {
        guard minimumTickInterval.isFinite, minimumTickInterval > 0 else {
            throw LuaError.runtime("minimum timer tick interval must be positive and finite")
        }
        let scheduler = GMLuaTimerScheduler(
            state: state,
            minimumDelay: minimumTickInterval
        )
        let timerTable: LuaTable
        if case let .table(existing) = state.getGlobal("timer") {
            timerTable = existing
        } else {
            timerTable = LuaTable()
        }

        func set(_ name: String, _ body: @escaping LuaNativeFunction) throws {
            let box = LuaNativeFunctionBox(
                body,
                debugName: "timer.\(name)",
                gcReferences: { [weak scheduler] in scheduler?.references ?? [] }
            )
            try state.setRawTableValue(
                .nativeFunction(box),
                for: .string(LuaString(name)),
                in: timerTable
            )
        }

        try set("Create") { [scheduler] arguments in
            let identifier = try identifier(arguments, index: 0, function: "Create")
            let delay = try number(arguments, index: 1, function: "Create")
            let repetitions = try integer(arguments, index: 2, function: "Create")
            let callback = try function(arguments, index: 3, function: "Create")
            scheduler.create(
                identifier: identifier,
                delay: delay,
                repetitions: repetitions,
                callback: callback
            )
            return []
        }
        try set("Simple") { [scheduler] arguments in
            let delay = try number(arguments, index: 0, function: "Simple")
            let callback = try function(arguments, index: 1, function: "Simple")
            scheduler.createSimple(delay: delay, callback: callback)
            return []
        }
        let remove: LuaNativeFunction = { [scheduler] arguments in
            scheduler.remove(try identifier(arguments, index: 0, function: "Remove"))
            return []
        }
        try set("Remove", remove)
        try set("Destroy", remove)
        try set("Exists") { [scheduler] arguments in
            [.boolean(scheduler.exists(try identifier(arguments, index: 0, function: "Exists")))]
        }
        try set("Adjust") { [scheduler] arguments in
            let name = try identifier(arguments, index: 0, function: "Adjust")
            let delay = try number(arguments, index: 1, function: "Adjust")
            let repetitions = try optionalInteger(arguments, index: 2, function: "Adjust")
            let callback = try optionalFunction(arguments, index: 3, function: "Adjust")
            return [
                .boolean(
                    scheduler.adjust(
                        name,
                        delay: delay,
                        repetitions: repetitions,
                        callback: callback
                    )
                )
            ]
        }
        try set("Pause") { [scheduler] arguments in
            scheduler.pause(try identifier(arguments, index: 0, function: "Pause"))
            return []
        }
        try set("UnPause") { [scheduler] arguments in
            scheduler.unpause(try identifier(arguments, index: 0, function: "UnPause"))
            return []
        }
        try set("Toggle") { [scheduler] arguments in
            scheduler.toggle(try identifier(arguments, index: 0, function: "Toggle"))
            return []
        }
        try set("Stop") { [scheduler] arguments in
            scheduler.stop(try identifier(arguments, index: 0, function: "Stop"))
            return []
        }
        try set("Start") { [scheduler] arguments in
            scheduler.start(try identifier(arguments, index: 0, function: "Start"))
            return []
        }
        try set("IsPaused") { [scheduler] arguments in
            [.boolean(scheduler.isPaused(try identifier(arguments, index: 0, function: "IsPaused")))]
        }
        try set("TimeLeft") { [scheduler] arguments in
            let value = scheduler.timeLeft(try identifier(arguments, index: 0, function: "TimeLeft"))
            return [value.map(LuaValue.number) ?? .nilValue]
        }
        try set("RepsLeft") { [scheduler] arguments in
            let value = scheduler.repetitionsLeft(
                try identifier(arguments, index: 0, function: "RepsLeft")
            )
            return [value.map { .number(Double($0)) } ?? .nilValue]
        }
        try set("Check") { _ in [] }

        state.setGlobal("timer", value: .table(timerTable))
        state.setGlobal(
            "CurTime",
            value: .nativeFunction(
                LuaNativeFunctionBox(
                    { [scheduler] _ in [.number(scheduler.currentTime)] },
                    debugName: "CurTime",
                    gcReferences: { [weak scheduler] in scheduler?.references ?? [] }
                )
            )
        )
        return scheduler
    }

    private static func identifier(
        _ arguments: [LuaValue],
        index: Int,
        function: String
    ) throws -> LuaString {
        guard arguments.indices.contains(index) else {
            throw badArgument(arguments, index: index, function: function, expected: "string")
        }
        switch arguments[index] {
        case let .string(value): return value
        case let .number(value): return LuaString(LuaValue.number(value).printable)
        default:
            throw badArgument(arguments, index: index, function: function, expected: "string")
        }
    }

    private static func number(
        _ arguments: [LuaValue],
        index: Int,
        function: String
    ) throws -> Double {
        guard arguments.indices.contains(index) else {
            throw badArgument(arguments, index: index, function: function, expected: "number")
        }
        let value: Double
        switch arguments[index] {
        case let .number(number): value = number
        case let .string(string):
            guard let parsed = Double(string.utf8String) else {
                throw badArgument(arguments, index: index, function: function, expected: "number")
            }
            value = parsed
        default:
            throw badArgument(arguments, index: index, function: function, expected: "number")
        }
        guard value.isFinite else {
            throw LuaError.runtime("bad argument #\(index + 1) to '\(function)' (finite number expected)")
        }
        return value
    }

    private static func integer(
        _ arguments: [LuaValue],
        index: Int,
        function: String
    ) throws -> Int {
        let value = try number(arguments, index: index, function: function).rounded(.towardZero)
        guard value >= Double(Int.min), value <= Double(Int.max) else {
            throw LuaError.runtime("bad argument #\(index + 1) to '\(function)' (integer out of range)")
        }
        return Int(value)
    }

    private static func optionalInteger(
        _ arguments: [LuaValue],
        index: Int,
        function: String
    ) throws -> Int? {
        guard arguments.indices.contains(index) else { return nil }
        if case .nilValue = arguments[index] { return nil }
        return try integer(arguments, index: index, function: function)
    }

    private static func function(
        _ arguments: [LuaValue],
        index: Int,
        function: String
    ) throws -> LuaValue {
        guard arguments.indices.contains(index) else {
            throw badArgument(arguments, index: index, function: function, expected: "function")
        }
        switch arguments[index] {
        case .luaFunction, .nativeFunction: return arguments[index]
        default:
            throw badArgument(arguments, index: index, function: function, expected: "function")
        }
    }

    private static func optionalFunction(
        _ arguments: [LuaValue],
        index: Int,
        function: String
    ) throws -> LuaValue? {
        guard arguments.indices.contains(index) else { return nil }
        if case .nilValue = arguments[index] { return nil }
        return try self.function(arguments, index: index, function: function)
    }

    private static func badArgument(
        _ arguments: [LuaValue],
        index: Int,
        function: String,
        expected: String
    ) -> LuaError {
        let actual = arguments.indices.contains(index) ? arguments[index].typeName : "no value"
        return .runtime(
            "bad argument #\(index + 1) to '\(function)' (\(expected) expected, got \(actual))"
        )
    }
}
