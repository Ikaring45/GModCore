import Foundation

/// Result of explicitly closing a Lua state. Lua 5.1 ignores errors raised by
/// `__gc` while closing, but exposing their text makes embedded-host diagnostics
/// deterministic without allowing one bad finalizer to suppress later ones.
public struct LuaCloseReport: Sendable, Equatable {
    public let finalizedUserdataCount: Int
    public let additionalPasses: Int
    public let deferredNewFinalizerCount: Int
    public let errorMessages: [String]

    public init(
        finalizedUserdataCount: Int,
        additionalPasses: Int,
        deferredNewFinalizerCount: Int,
        errorMessages: [String]
    ) {
        self.finalizedUserdataCount = finalizedUserdataCount
        self.additionalPasses = additionalPasses
        self.deferredNewFinalizerCount = deferredNewFinalizerCount
        self.errorMessages = errorMessages
    }
}

/// An explicit Lua-owned heap layered over Swift ARC.
///
/// ARC alone is not a Lua garbage collector: it releases acyclic temporaries
/// too early for weak-table semantics and cannot reclaim Lua reference cycles.
/// This heap strongly owns every Lua collectable until a root-based mark/sweep
/// cycle decides it is unreachable. Sweeping then releases and severs Lua graph
/// edges, leaving ARC to reclaim the Swift storage safely.
final class LuaGarbageCollector {
    private struct Marks {
        var objects = Set<ObjectIdentifier>()
        var environments = Set<ObjectIdentifier>()
    }

    private enum MarkWork {
        case value(LuaValue)
        case environment(LuaEnvironment)
    }

    private let lock = NSRecursiveLock()
    private weak var state: LuaState?

    private var tables: [ObjectIdentifier: LuaTable] = [:]
    private var functions: [ObjectIdentifier: LuaFunction] = [:]
    private var nativeFunctions: [ObjectIdentifier: LuaNativeFunctionBox] = [:]
    private var userdatas: [ObjectIdentifier: LuaUserdata] = [:]
    private var threads: [ObjectIdentifier: LuaThread] = [:]
    private var environments: [ObjectIdentifier: LuaEnvironment] = [:]

    private var userdataSerial: [ObjectIdentifier: UInt64] = [:]
    private var nextUserdataSerial: UInt64 = 0
    private var finalizedUserdata = Set<ObjectIdentifier>()
    private var finalizerGrace = Set<ObjectIdentifier>()

    private var running = true
    private var pause = 200
    private var stepMultiplier = 200
    // A full mark/sweep at every few dozen table literals is catastrophically
    // expensive for parser/constructor stress tests. Lua 5.1 amortizes this work
    // incrementally; use a multi-megabyte nursery before committing our atomic
    // sweep while explicit collectgarbage("step") retains fine-grained control.
    private static let minimumAutomaticThresholdBytes = 4 * 1024 * 1024
    private var collectionThresholdBytes = LuaGarbageCollector.minimumAutomaticThresholdBytes
    // LuaString is a byte-value backed by Swift ARC, so it is not retained in
    // the explicit mark/sweep object maps below. Runtime string construction
    // still creates real heap pressure. Preserve that allocation debt until a
    // collection commits so string-only loops can drive automatic collection
    // of otherwise unreachable Lua reference objects.
    private var stringAllocationDebtBytes = 0
    private var incrementalRemainingBytes: Int?
    private var isCollecting = false
    private var bornDuringCollection = Set<ObjectIdentifier>()
    private var isClosing = false
    private var closeReport: LuaCloseReport?

    var hasClosed: Bool {
        lock.lock(); defer { lock.unlock() }
        return closeReport != nil
    }

    func attach(to state: LuaState) {
        lock.lock(); defer { lock.unlock() }
        self.state = state
    }

    func adopt(_ value: LuaValue) {
        adopt([value])
    }

    func adopt(_ values: [LuaValue]) {
        lock.lock(); defer { lock.unlock() }
        guard closeReport == nil else { return }
        var seenObjects = Set<ObjectIdentifier>()
        var seenEnvironments = Set<ObjectIdentifier>()
        for value in values {
            adopt(value, seenObjects: &seenObjects, seenEnvironments: &seenEnvironments)
        }
    }

    func memoryKilobytes() -> Double {
        lock.lock(); defer { lock.unlock() }
        return Double(estimatedLiveBytes) / 1024.0
    }

    func accountStringAllocation(_ string: LuaString) {
        lock.lock(); defer { lock.unlock() }
        guard closeReport == nil else { return }
        let bytes = string.estimatedHeapByteCount
        stringAllocationDebtBytes = saturatingAdd(stringAllocationDebtBytes, bytes)
    }

    /// Finalizes the complete state, including userdata still reachable from
    /// globals. Lua 5.1 snapshots finalizable userdata once at lua_close entry
    /// (`luaC_separateudata(L, 1)`), then invokes that snapshot in reverse order.
    /// Userdata created by a finalizer is therefore reported and torn down rather
    /// than re-separated in this same close. Errors are collected and ignored
    /// until every snapshotted finalizer has run.
    func close() -> LuaCloseReport {
        lock.lock(); defer { lock.unlock() }
        if let closeReport { return closeReport }
        if isClosing {
            return LuaCloseReport(
                finalizedUserdataCount: 0,
                additionalPasses: 0,
                deferredNewFinalizerCount: 0,
                errorMessages: ["recursive LuaState.close() ignored"]
            )
        }
        if isCollecting {
            return LuaCloseReport(
                finalizedUserdataCount: 0,
                additionalPasses: 0,
                deferredNewFinalizerCount: 0,
                errorMessages: ["LuaState.close() rejected during active garbage collection"]
            )
        }
        guard let state else {
            let report = LuaCloseReport(
                finalizedUserdataCount: 0,
                additionalPasses: 0,
                deferredNewFinalizerCount: 0,
                errorMessages: []
            )
            closeReport = report
            return report
        }

        isClosing = true
        isCollecting = true
        running = false
        var finalizedCount = 0
        var errors: [String] = []

        let candidates = closeFinalizerCandidates()
        for (identifier, userdata, finalizer, _) in candidates {
            finalizedUserdata.insert(identifier)
            finalizedCount += 1
            do {
                _ = try state.callValue(
                    finalizer,
                    arguments: [.userdata(userdata)],
                    callName: "__gc",
                    callNameWhat: "metamethod"
                )
            } catch {
                errors.append(state.errorValue(error).printable)
            }
            state.clearFailureFramesForCurrentThread()
        }

        let deferred = closeFinalizerCandidates().count
        tearDownHeap()
        let report = LuaCloseReport(
            finalizedUserdataCount: finalizedCount,
            additionalPasses: 0,
            deferredNewFinalizerCount: deferred,
            errorMessages: errors
        )
        closeReport = report
        isCollecting = false
        isClosing = false
        return report
    }

    private func closeFinalizerCandidates() -> [(ObjectIdentifier, LuaUserdata, LuaValue, UInt64)] {
        userdatas.compactMap { identifier, userdata in
            guard !finalizedUserdata.contains(identifier),
                  let metatable = userdata.metatable else { return nil }
            let finalizer = metatable.rawValue(forString: "__gc")
            guard !finalizer.isNilValue else { return nil }
            return (identifier, userdata, finalizer, userdataSerial[identifier] ?? 0)
        }.sorted { $0.3 > $1.3 }
    }

    private func tearDownHeap() {
        for table in tables.values {
            table.clear()
            table.metatable = nil
        }
        for function in nativeFunctions.values { function.environment = nil }
        for userdata in userdatas.values { userdata.gcClearReferences() }
        for thread in threads.values { thread.gcClearReferences() }
        for environment in environments.values { environment.gcClearValues() }

        tables.removeAll(keepingCapacity: false)
        functions.removeAll(keepingCapacity: false)
        nativeFunctions.removeAll(keepingCapacity: false)
        userdatas.removeAll(keepingCapacity: false)
        threads.removeAll(keepingCapacity: false)
        environments.removeAll(keepingCapacity: false)
        userdataSerial.removeAll(keepingCapacity: false)
        finalizedUserdata.removeAll(keepingCapacity: false)
        finalizerGrace.removeAll(keepingCapacity: false)
        bornDuringCollection.removeAll(keepingCapacity: false)
        stringAllocationDebtBytes = 0
        incrementalRemainingBytes = nil
    }

    func stop() -> Int {
        lock.lock(); defer { lock.unlock() }
        running = false
        return 0
    }

    func restart() -> Int {
        lock.lock(); defer { lock.unlock() }
        running = true
        return 0
    }

    func setPause(_ value: Int) -> Int {
        lock.lock(); defer { lock.unlock() }
        let previous = pause
        pause = max(0, value)
        return previous
    }

    func setStepMultiplier(_ value: Int) -> Int {
        lock.lock(); defer { lock.unlock() }
        let previous = stepMultiplier
        stepMultiplier = max(0, value)
        return previous
    }

    /// A statement boundary is a safe point: expression temporaries have been
    /// assigned to their Lua environment and are visible to root enumeration.
    func safePoint() throws {
        lock.lock(); defer { lock.unlock() }
        guard running, !isCollecting,
              automaticCollectionPressureBytes >= collectionThresholdBytes,
              let state else { return }
        _ = try collect(state: state)
    }

    @discardableResult
    func fullCollection() throws -> Int {
        lock.lock(); defer { lock.unlock() }
        guard let state else { return 0 }
        // LUA_GCCOLLECT runs a complete cycle and leaves the threshold active
        // again even when LUA_GCSTOP preceded it. The official gc.lua and
        // locals.lua suites rely on collectgarbage() restoring automatic GC.
        running = true
        return try collect(state: state)
    }

    /// Performs an incremental amount of work. The mark graph remains atomic so
    /// Lua cannot observe a half-swept heap; the budget determines how many calls
    /// are required before that atomic cycle is committed.
    func step(_ sizeKilobytes: Int) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let state else { return true }
        if incrementalRemainingBytes == nil {
            incrementalRemainingBytes = max(1, automaticCollectionPressureBytes)
        }
        let multiplier = max(1, stepMultiplier)
        let baseKilobytes = sizeKilobytes > 0 ? sizeKilobytes : 1
        let byteBudget = saturatingMultiply(baseKilobytes, 1024)
        let scaledBudget = saturatingMultiply(byteBudget, multiplier)
        let workBytes = max(1, scaledBudget / 200)
        let remaining = incrementalRemainingBytes ?? 0
        if workBytes < remaining {
            incrementalRemainingBytes = remaining - workBytes
            return false
        }
        incrementalRemainingBytes = nil
        _ = try collect(state: state)
        return true
    }

    private var estimatedLiveBytes: Int {
        // Deliberately stable estimates: collectgarbage("count") is specified as
        // an approximate heap size, not the host allocator's resident-set size.
        tables.count * 1024
            + functions.count * 512
            + nativeFunctions.count * 128
            + userdatas.count * 256
            + threads.count * 512
            + environments.count * 256
    }

    private var automaticCollectionPressureBytes: Int {
        saturatingAdd(estimatedLiveBytes, stringAllocationDebtBytes)
    }

    private func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
        precondition(lhs >= 0 && rhs >= 0)
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int.max : value
    }

    private func saturatingMultiply(_ lhs: Int, _ rhs: Int) -> Int {
        precondition(lhs >= 0 && rhs >= 0)
        let (value, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        return overflow ? Int.max : value
    }

    private func adopt(
        _ value: LuaValue,
        seenObjects: inout Set<ObjectIdentifier>,
        seenEnvironments: inout Set<ObjectIdentifier>
    ) {
        guard let identifier = value.collectableObjectIdentifier,
              seenObjects.insert(identifier).inserted else { return }

        switch value {
        case let .table(table):
            guard tables[identifier] == nil else { return }
            if isCollecting { bornDuringCollection.insert(identifier) }
            tables[identifier] = table
            if let metatable = table.metatable {
                adopt(.table(metatable), seenObjects: &seenObjects, seenEnvironments: &seenEnvironments)
            }
            for (key, element) in table.gcPairs() {
                adopt(key, seenObjects: &seenObjects, seenEnvironments: &seenEnvironments)
                adopt(element, seenObjects: &seenObjects, seenEnvironments: &seenEnvironments)
            }

        case let .luaFunction(function):
            guard functions[identifier] == nil else { return }
            if isCollecting { bornDuringCollection.insert(identifier) }
            functions[identifier] = function
            adopt(.table(function.environmentTable), seenObjects: &seenObjects, seenEnvironments: &seenEnvironments)
            adopt(function.closure, seenObjects: &seenObjects, seenEnvironments: &seenEnvironments)

        case let .nativeFunction(function):
            guard nativeFunctions[identifier] == nil else { return }
            if isCollecting { bornDuringCollection.insert(identifier) }
            nativeFunctions[identifier] = function
            if let environment = function.environment {
                adopt(.table(environment), seenObjects: &seenObjects, seenEnvironments: &seenEnvironments)
            }
            for reference in function.gcReferences() {
                adopt(reference, seenObjects: &seenObjects, seenEnvironments: &seenEnvironments)
            }

        case let .userdata(userdata):
            guard userdatas[identifier] == nil else { return }
            if isCollecting { bornDuringCollection.insert(identifier) }
            nextUserdataSerial &+= 1
            userdataSerial[identifier] = nextUserdataSerial
            userdatas[identifier] = userdata
            if let metatable = userdata.metatable {
                adopt(.table(metatable), seenObjects: &seenObjects, seenEnvironments: &seenEnvironments)
            }
            if let environment = userdata.environment {
                adopt(.table(environment), seenObjects: &seenObjects, seenEnvironments: &seenEnvironments)
            }

        case let .thread(thread):
            guard threads[identifier] == nil else { return }
            if isCollecting { bornDuringCollection.insert(identifier) }
            threads[identifier] = thread
            let references = thread.gcReferences()
            for reference in references.values {
                adopt(reference, seenObjects: &seenObjects, seenEnvironments: &seenEnvironments)
            }
            for environment in references.environments {
                adopt(environment, seenObjects: &seenObjects, seenEnvironments: &seenEnvironments)
            }

        case .nilValue, .boolean, .number, .string:
            break
        }
    }

    private func adopt(
        _ environment: LuaEnvironment,
        seenObjects: inout Set<ObjectIdentifier>,
        seenEnvironments: inout Set<ObjectIdentifier>
    ) {
        let identifier = ObjectIdentifier(environment)
        guard seenEnvironments.insert(identifier).inserted,
              environments[identifier] == nil else { return }
        environments[identifier] = environment
        let references = environment.gcReferences()
        adopt(.table(references.globalTable), seenObjects: &seenObjects, seenEnvironments: &seenEnvironments)
        if let parent = references.parent {
            adopt(parent, seenObjects: &seenObjects, seenEnvironments: &seenEnvironments)
        }
        for value in references.values {
            adopt(value, seenObjects: &seenObjects, seenEnvironments: &seenEnvironments)
        }
    }

    private func collect(state: LuaState) throws -> Int {
        guard !isCollecting else { return 0 }
        let collectedStringAllocationDebt = stringAllocationDebtBytes
        isCollecting = true
        bornDuringCollection.removeAll(keepingCapacity: true)
        defer { isCollecting = false }

        let roots = state.garbageCollectionRoots()
        var initialMarks = Marks()
        mark(values: roots.values, environments: roots.environments, marks: &initialMarks)

        var potentialFinalizers: [(ObjectIdentifier, LuaUserdata, LuaValue, UInt64)] = []
        for (identifier, userdata) in userdatas
            where !initialMarks.objects.contains(identifier) && !finalizedUserdata.contains(identifier) {
            guard let metatable = userdata.metatable else { continue }
            let finalizer = metatable.rawValue(forString: "__gc")
            guard !finalizer.isNilValue else { continue }
            potentialFinalizers.append((identifier, userdata, finalizer, userdataSerial[identifier] ?? 0))
        }

        let potentialIDs = Set(potentialFinalizers.map(\.0))
        for table in tables.values {
            table.gcSweepWeakEntries(
                marked: initialMarks.objects,
                preservingFinalizingKeys: potentialIDs
            )
        }

        // A finalizer itself can be a weak metatable value. Re-read it after
        // weak-value cleanup so such a function is correctly considered dead.
        potentialFinalizers = potentialFinalizers.compactMap { item in
            guard let metatable = item.1.metatable else { return nil }
            let current = metatable.rawValue(forString: "__gc")
            return current.isNilValue ? nil : (item.0, item.1, current, item.3)
        }
        let finalizerIDs = Set(potentialFinalizers.map(\.0))
        if finalizerIDs != potentialIDs {
            for table in tables.values {
                table.gcSweepWeakEntries(
                    marked: initialMarks.objects,
                    preservingFinalizingKeys: finalizerIDs
                )
            }
        }

        var firstFinalizerError: Error?
        var newlyFinalized = Set<ObjectIdentifier>()
        for (identifier, userdata, finalizer, _) in potentialFinalizers.sorted(by: { $0.3 > $1.3 }) {
            finalizedUserdata.insert(identifier)
            newlyFinalized.insert(identifier)
            do {
                _ = try state.callValue(finalizer, arguments: [.userdata(userdata)], callName: "__gc", callNameWhat: "metamethod")
            } catch {
                if firstFinalizerError == nil { firstFinalizerError = error }
            }
        }

        let rootsAfterFinalizers = state.garbageCollectionRoots()
        var reachableMarks = Marks()
        mark(
            values: rootsAfterFinalizers.values,
            environments: rootsAfterFinalizers.environments,
            marks: &reachableMarks
        )

        // Unresurrected finalized userdata and their strong dependencies remain
        // intact until the next cycle. This is what makes weak finalized keys
        // observable during __gc but gone after a second collection.
        var graceMarks = Marks()
        for identifier in newlyFinalized where !reachableMarks.objects.contains(identifier) {
            if let userdata = userdatas[identifier] {
                mark(values: [.userdata(userdata)], environments: [], marks: &graceMarks)
            }
        }

        var retainedObjects = reachableMarks.objects
        retainedObjects.formUnion(graceMarks.objects)
        var retainedEnvironments = reachableMarks.environments
        retainedEnvironments.formUnion(graceMarks.environments)

        // Objects allocated by a finalizer are not part of the cycle that is
        // already being swept. Keep their graph until the next collection so a
        // newproxy(o) created inside __gc can itself be finalized later.
        var newbornMarks = Marks()
        let newbornValues = bornDuringCollection.compactMap(value(for:))
        mark(values: newbornValues, environments: [], marks: &newbornMarks)
        retainedObjects.formUnion(newbornMarks.objects)
        retainedEnvironments.formUnion(newbornMarks.environments)

        let graceKeys = Set(newlyFinalized.filter { !reachableMarks.objects.contains($0) })
        for table in tables.values {
            table.gcSweepWeakEntries(marked: reachableMarks.objects, preservingFinalizingKeys: graceKeys)
        }

        sweep(retaining: retainedObjects, retainedEnvironments: retainedEnvironments)
        finalizerGrace = graceKeys
        bornDuringCollection.removeAll(keepingCapacity: true)
        // A finalizer can allocate strings while this atomic collection is in
        // progress. Retire only the debt that existed when the cycle began.
        stringAllocationDebtBytes = max(
            0,
            stringAllocationDebtBytes - collectedStringAllocationDebt
        )
        incrementalRemainingBytes = nil
        collectionThresholdBytes = max(
            Self.minimumAutomaticThresholdBytes,
            saturatingMultiply(estimatedLiveBytes, max(1, pause)) / 100
        )

        if let firstFinalizerError { throw firstFinalizerError }
        return 0
    }

    private func mark(values: [LuaValue], environments: [LuaEnvironment], marks: inout Marks) {
        // Lua programs routinely build graphs much deeper than the host call
        // stack (official gc.lua uses a 200,000-node linked list). Marking must
        // therefore be iterative, not recursive Swift calls.
        var work = values.map(MarkWork.value) + environments.map(MarkWork.environment)
        while let item = work.popLast() {
            switch item {
            case let .environment(environment):
                let identifier = ObjectIdentifier(environment)
                guard marks.environments.insert(identifier).inserted else { continue }
                let references = environment.gcReferences()
                work.append(.value(.table(references.globalTable)))
                if let parent = references.parent { work.append(.environment(parent)) }
                work.append(contentsOf: references.values.map(MarkWork.value))

            case let .value(value):
                guard let identifier = value.collectableObjectIdentifier,
                      marks.objects.insert(identifier).inserted else { continue }
                switch value {
                case let .table(table):
                    if let metatable = table.metatable { work.append(.value(.table(metatable))) }
                    let mode = table.weakMode
                    for (key, element) in table.gcPairs() {
                        if !mode.contains("k") { work.append(.value(key)) }
                        if !mode.contains("v") { work.append(.value(element)) }
                    }
                case let .luaFunction(function):
                    work.append(.value(.table(function.environmentTable)))
                    work.append(.environment(function.closure))
                case let .nativeFunction(function):
                    if let environment = function.environment { work.append(.value(.table(environment))) }
                    work.append(contentsOf: function.gcReferences().map(MarkWork.value))
                case let .userdata(userdata):
                    if let metatable = userdata.metatable { work.append(.value(.table(metatable))) }
                    if let environment = userdata.environment { work.append(.value(.table(environment))) }
                case let .thread(thread):
                    let references = thread.gcReferences()
                    work.append(contentsOf: references.values.map(MarkWork.value))
                    work.append(contentsOf: references.environments.map(MarkWork.environment))
                case .nilValue, .boolean, .number, .string:
                    break
                }
            }
        }
    }

    private func sweep(retaining marked: Set<ObjectIdentifier>, retainedEnvironments: Set<ObjectIdentifier>) {
        for (identifier, table) in tables where !marked.contains(identifier) {
            table.clear()
            table.metatable = nil
            tables.removeValue(forKey: identifier)
        }
        for identifier in functions.keys where !marked.contains(identifier) {
            functions.removeValue(forKey: identifier)
        }
        for (identifier, function) in nativeFunctions where !marked.contains(identifier) {
            function.environment = nil
            nativeFunctions.removeValue(forKey: identifier)
        }
        for (identifier, userdata) in userdatas where !marked.contains(identifier) {
            userdata.gcClearReferences()
            userdatas.removeValue(forKey: identifier)
            userdataSerial.removeValue(forKey: identifier)
            finalizedUserdata.remove(identifier)
            finalizerGrace.remove(identifier)
        }
        for (identifier, thread) in threads where !marked.contains(identifier) {
            thread.gcClearReferences()
            threads.removeValue(forKey: identifier)
        }
        for (identifier, environment) in environments where !retainedEnvironments.contains(identifier) {
            environment.gcClearValues()
            environments.removeValue(forKey: identifier)
        }
    }

    private func value(for identifier: ObjectIdentifier) -> LuaValue? {
        if let value = tables[identifier] { return .table(value) }
        if let value = functions[identifier] { return .luaFunction(value) }
        if let value = nativeFunctions[identifier] { return .nativeFunction(value) }
        if let value = userdatas[identifier] { return .userdata(value) }
        if let value = threads[identifier] { return .thread(value) }
        return nil
    }
}

private extension LuaValue {
    var isNilValue: Bool {
        if case .nilValue = self { return true }
        return false
    }
}
