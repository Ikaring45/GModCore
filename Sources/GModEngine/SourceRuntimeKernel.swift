import Foundation

/// Float-only vector used at the Source compatibility boundary.
///
/// Source 1 simulation state is based on 32-bit `Vector` components. Keeping
/// this type separate from the Lua userdata and Metal types prevents either
/// subsystem from silently changing simulation precision or ownership.
public struct SourceVector3: Equatable, Hashable, Sendable {
    public var x: Float
    public var y: Float
    public var z: Float

    public init(_ x: Float = 0, _ y: Float = 0, _ z: Float = 0) {
        self.x = x
        self.y = y
        self.z = z
    }

    public static let zero = SourceVector3()

    public subscript(axis: Int) -> Float {
        get {
            switch axis {
            case 0: return x
            case 1: return y
            case 2: return z
            default: preconditionFailure("SourceVector3 axis must be in 0...2")
            }
        }
        set {
            switch axis {
            case 0: x = newValue
            case 1: y = newValue
            case 2: z = newValue
            default: preconditionFailure("SourceVector3 axis must be in 0...2")
            }
        }
    }

    public var lengthSquared: Float { x * x + y * y + z * z }
    public var length: Float { lengthSquared.squareRoot() }

    public func dot(_ other: SourceVector3) -> Float {
        x * other.x + y * other.y + z * other.z
    }

    public static func + (lhs: SourceVector3, rhs: SourceVector3) -> SourceVector3 {
        SourceVector3(lhs.x + rhs.x, lhs.y + rhs.y, lhs.z + rhs.z)
    }

    public static func - (lhs: SourceVector3, rhs: SourceVector3) -> SourceVector3 {
        SourceVector3(lhs.x - rhs.x, lhs.y - rhs.y, lhs.z - rhs.z)
    }

    public static prefix func - (value: SourceVector3) -> SourceVector3 {
        SourceVector3(-value.x, -value.y, -value.z)
    }

    public static func * (lhs: SourceVector3, rhs: Float) -> SourceVector3 {
        SourceVector3(lhs.x * rhs, lhs.y * rhs, lhs.z * rhs)
    }

    public static func * (lhs: Float, rhs: SourceVector3) -> SourceVector3 {
        rhs * lhs
    }

    public static func / (lhs: SourceVector3, rhs: Float) -> SourceVector3 {
        SourceVector3(lhs.x / rhs, lhs.y / rhs, lhs.z / rhs)
    }

    public static func += (lhs: inout SourceVector3, rhs: SourceVector3) {
        lhs = lhs + rhs
    }

    public static func -= (lhs: inout SourceVector3, rhs: SourceVector3) {
        lhs = lhs - rhs
    }

    public static func *= (lhs: inout SourceVector3, rhs: Float) {
        lhs = lhs * rhs
    }
}

/// Numeric compatibility values cross-checked against Source SDK 2013
/// `const.h` and `entitylist_base.cpp`.
///
/// `entEntryMask` intentionally has 16 low bits even though the entity list has
/// 13 entry bits. This is the original layout, not a corrected reinterpretation.
public enum SourceEntityConstants {
    public static let maxEdictBits = 11
    public static let maxEdicts = 1 << maxEdictBits
    public static let numEntEntryBits = maxEdictBits + 2
    public static let numEntEntries = 1 << numEntEntryBits
    public static let invalidEHandleIndex = UInt32.max
    public static let numSerialNumberBits = 16
    public static let numSerialNumberShiftBits = 32 - numSerialNumberBits
    public static let entEntryMask = (1 << numSerialNumberBits) - 1
    public static let serialMask = (1 << (numSerialNumberBits - 1)) - 1
    public static let numNetworkedSerialNumberBits = 10
    public static let numNetworkedEHandleBits = maxEdictBits + numNetworkedSerialNumberBits
    public static let invalidNetworkedEHandleValue = (1 << numNetworkedEHandleBits) - 1
}

/// Bit-compatible representation of Source 1 `CBaseHandle`.
public struct SourceBaseHandle: Equatable, Hashable, Sendable, Comparable {
    public let rawValue: UInt32

    public init() {
        rawValue = SourceEntityConstants.invalidEHandleIndex
    }

    public init(entryIndex: Int, serialNumber: Int) {
        precondition(
            entryIndex >= 0 && (entryIndex & SourceEntityConstants.entEntryMask) == entryIndex,
            "CBaseHandle entry index is outside ENT_ENTRY_MASK"
        )
        precondition(
            serialNumber >= 0 && serialNumber < (1 << SourceEntityConstants.numSerialNumberBits),
            "CBaseHandle serial number does not fit NUM_SERIAL_NUM_BITS"
        )
        rawValue = UInt32(entryIndex) |
            (UInt32(serialNumber) << UInt32(SourceEntityConstants.numSerialNumberShiftBits))
    }

    private init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    /// Mirrors the deliberately unsafe `CBaseHandle::UnsafeFromIndex` factory.
    public static func unsafeFromIndex(_ rawValue: UInt32) -> SourceBaseHandle {
        SourceBaseHandle(rawValue: rawValue)
    }

    public static let invalid = SourceBaseHandle()

    public var isValid: Bool {
        rawValue != SourceEntityConstants.invalidEHandleIndex
    }

    public var entryIndex: Int {
        // Preserve the compatibility hack in CBaseHandle::GetEntryIndex. The
        // invalid handle resolves to the always-empty final entity-list slot,
        // not to the value produced by applying ENT_ENTRY_MASK to 0xffffffff.
        guard isValid else { return SourceEntityConstants.numEntEntries - 1 }
        return Int(rawValue & UInt32(SourceEntityConstants.entEntryMask))
    }

    public var serialNumber: Int {
        Int(rawValue >> UInt32(SourceEntityConstants.numSerialNumberShiftBits))
    }

    /// Source returns a signed `int`; an invalid handle therefore returns -1.
    public var intValue: Int32 {
        Int32(bitPattern: rawValue)
    }

    public static func < (lhs: SourceBaseHandle, rhs: SourceBaseHandle) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// The fixed-tick subset of `CGlobalVarsBase` needed by deterministic gameplay.
public struct SourceGlobalVars: Equatable, Sendable {
    public static let intervalPerTick: Float = 0.015

    public private(set) var tickCount: Int32
    public private(set) var frameCount: Int32
    public private(set) var currentTime: Float
    public private(set) var frameTime: Float
    public var interpolationAmount: Float

    public init(
        tickCount: Int32 = 0,
        frameCount: Int32 = 0,
        interpolationAmount: Float = 0
    ) {
        self.tickCount = tickCount
        self.frameCount = frameCount
        currentTime = Float(tickCount) * Self.intervalPerTick
        frameTime = Self.intervalPerTick
        self.interpolationAmount = interpolationAmount
    }

    mutating func beginServerTick() {
        tickCount &+= 1
        frameCount &+= 1
        currentTime = Float(tickCount) * Self.intervalPerTick
        frameTime = Self.intervalPerTick
    }
}

/// Source uses -1 (`TICK_NEVER_THINK`) to remove a think function from the
/// incremental simulation/think list.
public let sourceTickNeverThink: Int32 = -1

/// `CLIENT_THINK_ALWAYS` belongs to Source's separate client think list.
///
/// It is exposed so compatibility callers do not accidentally reinterpret it
/// as a server `CBaseEntity` schedule. Server `PhysicsRunSpecificThink` treats
/// every tick <= 0, including this value, as inactive.
public let sourceClientThinkAlways: Int32 = -1293

/// Selects the same three dispatch paths as `CBaseEntity::thinkmethods_t`.
public enum SourceThinkDispatchMethod: Equatable, Sendable {
    case allFunctions
    case baseOnly
    case allButBase
}

/// Swift representation of a Source member-function pointer stored in
/// `thinkfunc_t`. The entity argument keeps handlers reusable without making
/// the closure own the entity it is installed on.
public typealias SourceContextThinkCallback = (
    _ entity: SourceEntity,
    _ globals: inout SourceGlobalVars
) -> Void

/// Engine-owned base entity surface. Lua userdata must wrap its handle rather
/// than owning a second copy of this state.
open class SourceEntity {
    private struct ThinkContext {
        let name: String
        var callback: SourceContextThinkCallback?
        var nextThinkTick: Int32
        var lastThinkTick: Int32
    }

    private static let maxThinkContextComparisonBytes = 32

    public let className: String
    public fileprivate(set) var refHandle: SourceBaseHandle = .invalid
    public fileprivate(set) var isMarkedForDeletion = false
    /// Mirrors whether `edict()` is non-null. Physics dispatch uses this
    /// identity, not the game-simulation EFlag.
    public fileprivate(set) var isNetworkable = false

    /// Equivalent to the inverse of `EFL_NO_GAME_PHYSICS_SIMULATION`.
    public var isGamePhysicsSimulationEnabled: Bool {
        didSet {
            if oldValue != isGamePhysicsSimulationEnabled {
                owningEntityList?.simulationStateChanged(self)
            }
        }
    }

    /// Scheduled tick for the legacy/base think function.
    public private(set) var nextThinkTick: Int32
    public private(set) var lastThinkTick: Int32 = 0

    private var thinkContexts: [ThinkContext] = []

    private var lastSimulationTick: Int32 = sourceTickNeverThink
    fileprivate weak var owningEntityList: SourceEntityList?

    public init(
        className: String,
        isGamePhysicsSimulationEnabled: Bool = false,
        nextThinkTick: Int32 = sourceTickNeverThink,
        /// Source initializes this from `gpGlobals->tickcount`. Callers that
        /// create entities after tick zero must pass that creation tick; zero
        /// is only the deterministic pre-first-frame default.
        lastThinkTick: Int32 = 0
    ) {
        self.className = className
        self.isGamePhysicsSimulationEnabled = isGamePhysicsSimulationEnabled
        self.nextThinkTick = nextThinkTick
        self.lastThinkTick = lastThinkTick
    }

    public final func setNextThinkTick(_ tick: Int32) {
        nextThinkTick = tick
        owningEntityList?.simulationStateChanged(self)
    }

    /// Finds or appends a context exactly like `RegisterThinkContext`.
    ///
    /// Source uses `Q_strncmp(..., MAX_CONTEXT_LENGTH)` rather than an
    /// unbounded comparison, so names with the same first 32 UTF-8 bytes map
    /// to the same context. A new context starts at tick 0 (inactive), not at
    /// `TICK_NEVER_THINK`.
    @discardableResult
    public final func registerThinkContext(_ context: String) -> Int {
        if let index = thinkContextIndex(named: context) {
            return index
        }
        thinkContexts.append(
            ThinkContext(
                name: context,
                callback: nil,
                nextThinkTick: 0,
                lastThinkTick: 0
            )
        )
        return thinkContexts.count - 1
    }

    /// Installs/replaces a context callback, mirroring `ThinkSet` /
    /// `SetContextThink`.
    ///
    /// The zero-tick behavior is intentionally unusual: `ThinkSet` does not
    /// alter an existing schedule when its time argument is exactly zero.
    @discardableResult
    public final func setContextThink(
        _ callback: SourceContextThinkCallback?,
        nextThinkTick: Int32 = 0,
        context: String
    ) -> Int {
        let index = registerThinkContext(context)
        thinkContexts[index].callback = callback
        if nextThinkTick != 0 {
            thinkContexts[index].nextThinkTick = nextThinkTick
            owningEntityList?.simulationStateChanged(self)
        }
        return index
    }

    /// `SetNextThink(..., context)` always writes the requested value,
    /// including zero, and registers a missing context at the vector tail.
    public final func setNextThinkTick(_ tick: Int32, context: String) {
        let index = registerThinkContext(context)
        thinkContexts[index].nextThinkTick = tick
        owningEntityList?.simulationStateChanged(self)
    }

    public final func nextThinkTick(context: String) -> Int32 {
        guard let index = thinkContextIndex(named: context) else {
            return sourceTickNeverThink
        }
        return thinkContexts[index].nextThinkTick
    }

    public final func lastThinkTick(context: String) -> Int32 {
        guard let index = thinkContextIndex(named: context) else {
            return sourceTickNeverThink
        }
        return thinkContexts[index].lastThinkTick
    }

    public final var thinkContextCount: Int { thinkContexts.count }

    public final func thinkContextName(at index: Int) -> String? {
        guard thinkContexts.indices.contains(index) else { return nil }
        return thinkContexts[index].name
    }

    /// Mirrors `WillThink`: zero and every negative sentinel are inactive.
    public final var willThink: Bool {
        if nextThinkTick > 0 { return true }
        return thinkContexts.contains { $0.nextThinkTick > 0 }
    }

    /// Mirrors `GetFirstThinkTick`, including its positive-ticks-only rule.
    public final var firstThinkTick: Int32 {
        var first = nextThinkTick > 0 ? nextThinkTick : sourceTickNeverThink
        for context in thinkContexts where context.nextThinkTick > 0 {
            if first == sourceTickNeverThink || context.nextThinkTick < first {
                first = context.nextThinkTick
            }
        }
        return first
    }

    /// Override for MOVETYPE/game physics. The default base behavior still runs
    /// a due think, matching the role of `CBaseEntity::PhysicsSimulate`.
    open func physicsSimulate(globals: inout SourceGlobalVars) {
        _ = physicsRunThink(globals: &globals)
    }

    /// Override for the scheduled base think callback.
    open func think(globals: inout SourceGlobalVars) {}

    @discardableResult
    public final func physicsRunThink(
        globals: inout SourceGlobalVars,
        method: SourceThinkDispatchMethod = .allFunctions
    ) -> Bool {
        // This is the observable equivalent of EFL_NO_THINK_FUNCTION. The SDK
        // exits successfully even if the entity is already in the delete queue.
        guard willThink else { return true }

        if method != .allButBase {
            let alive = runSpecificThink(
                contextIndex: nil,
                callback: { entity, globals in entity.think(globals: &globals) },
                globals: &globals
            )
            if !alive { return false }
        }

        if method == .baseOnly { return true }

        // The SDK re-evaluates m_aThinkFunctions.Count() on every iteration.
        // A callback that AddToTail-registers a due context can therefore make
        // that context run later in this same PhysicsRunThink call.
        var index = 0
        while index < thinkContexts.count {
            let callback = thinkContexts[index].callback
            let alive = runSpecificThink(
                contextIndex: index,
                callback: callback,
                globals: &globals
            )
            if !alive { return false }
            index += 1
        }
        return true
    }

    private func runSpecificThink(
        contextIndex: Int?,
        callback: SourceContextThinkCallback?,
        globals: inout SourceGlobalVars
    ) -> Bool {
        let scheduledTick: Int32
        if let contextIndex {
            scheduledTick = thinkContexts[contextIndex].nextThinkTick
        } else {
            scheduledTick = nextThinkTick
        }

        // `PhysicsRunSpecificThink` returns true before checking deletion for
        // inactive or future schedules. This differs from an intuitive
        // `!IsMarkedForDeletion()` early return and is retained deliberately.
        guard scheduledTick > 0, scheduledTick <= globals.tickCount else {
            return true
        }

        // Clear before dispatch so the callback's self-reschedule survives.
        if let contextIndex {
            thinkContexts[contextIndex].nextThinkTick = sourceTickNeverThink
        } else {
            nextThinkTick = sourceTickNeverThink
        }
        owningEntityList?.simulationStateChanged(self)

        callback?(self, &globals)

        // Source writes last-think after dispatch, even when the callback has
        // marked the entity for deferred deletion.
        if let contextIndex {
            thinkContexts[contextIndex].lastThinkTick = globals.tickCount
        } else {
            lastThinkTick = globals.tickCount
        }
        return !isMarkedForDeletion
    }

    private func thinkContextIndex(named context: String) -> Int? {
        let searchKey = Array(
            context.utf8.prefix(Self.maxThinkContextComparisonBytes)
        )
        return thinkContexts.firstIndex { existing in
            Array(existing.name.utf8.prefix(Self.maxThinkContextComparisonBytes)) == searchKey
        }
    }

    fileprivate func runPhysicsSimulationOnce(globals: inout SourceGlobalVars) {
        guard lastSimulationTick != globals.tickCount else { return }
        lastSimulationTick = globals.tickCount
        physicsSimulate(globals: &globals)
    }
}

public enum SourceEntityListError: Error, Equatable {
    case invalidEntryIndex(Int)
    case networkableEntryIndexRequired(Int)
    case occupiedEntryIndex(Int)
    case entityAlreadyRegistered
    case noFreeNonNetworkableSlots
}

/// Serial-numbered entity slots with Source-compatible deferred destruction.
public final class SourceEntityList {
    private struct Slot {
        var entity: SourceEntity?
        var serialNumber: Int
    }

    private struct SimThinkEntry {
        var entryIndex: Int
        var nextThinkTick: Int32
    }

    private var slots: [Slot]
    private var activeEntryIndices: [Int] = []
    private var freeNonNetworkableEntryIndices: [Int]
    private var nextFreeNonNetworkableIndex = 0
    private var pendingDeletion: [SourceBaseHandle] = []
    private var pendingDeletionSet: Set<SourceBaseHandle> = []
    private var simThinkEntries: [SimThinkEntry] = []
    private var simThinkPositionByEntry: [Int]

    public init(initialSerialNumber: Int? = nil) {
        if let initialSerialNumber {
            precondition(
                initialSerialNumber >= 0 &&
                    initialSerialNumber <= SourceEntityConstants.serialMask
            )
            slots = Array(
                repeating: Slot(entity: nil, serialNumber: initialSerialNumber),
                count: SourceEntityConstants.numEntEntries
            )
        } else {
            // CBaseEntityList seeds every slot independently with
            // `rand() & SERIAL_MASK`; the host RNG is intentionally hidden.
            slots = (0..<SourceEntityConstants.numEntEntries).map { _ in
                Slot(
                    entity: nil,
                    serialNumber: Int.random(in: 0...SourceEntityConstants.serialMask)
                )
            }
        }
        simThinkPositionByEntry = Array(
            repeating: -1,
            count: SourceEntityConstants.numEntEntries
        )
        // The SDK starts this free list at MAX_EDICTS + 1 and keeps the final
        // slot empty for the invalid-handle GetEntryIndex compatibility path.
        freeNonNetworkableEntryIndices = Array(
            (SourceEntityConstants.maxEdicts + 1)..<(SourceEntityConstants.numEntEntries - 1)
        )
    }

    public var activeCount: Int { activeEntryIndices.count }
    public var pendingDeletionCount: Int { pendingDeletion.count }

    @discardableResult
    public func addNetworkableEntity(
        _ entity: SourceEntity,
        at entryIndex: Int
    ) throws -> SourceBaseHandle {
        guard entryIndex >= 0 && entryIndex < SourceEntityConstants.maxEdicts else {
            throw SourceEntityListError.networkableEntryIndexRequired(entryIndex)
        }
        return try addEntity(entity, at: entryIndex)
    }

    @discardableResult
    public func addNonNetworkableEntity(_ entity: SourceEntity) throws -> SourceBaseHandle {
        while nextFreeNonNetworkableIndex < freeNonNetworkableEntryIndices.count {
            let entryIndex = freeNonNetworkableEntryIndices[nextFreeNonNetworkableIndex]
            nextFreeNonNetworkableIndex += 1
            if slots[entryIndex].entity == nil {
                return try addEntity(entity, at: entryIndex)
            }
        }
        throw SourceEntityListError.noFreeNonNetworkableSlots
    }

    @discardableResult
    public func addEntity(
        _ entity: SourceEntity,
        at entryIndex: Int
    ) throws -> SourceBaseHandle {
        guard entryIndex >= 0 && entryIndex < SourceEntityConstants.numEntEntries - 1 else {
            throw SourceEntityListError.invalidEntryIndex(entryIndex)
        }
        guard !entity.refHandle.isValid else {
            throw SourceEntityListError.entityAlreadyRegistered
        }
        guard slots[entryIndex].entity == nil else {
            throw SourceEntityListError.occupiedEntryIndex(entryIndex)
        }

        let handle = SourceBaseHandle(
            entryIndex: entryIndex,
            serialNumber: slots[entryIndex].serialNumber
        )
        slots[entryIndex].entity = entity
        activeEntryIndices.append(entryIndex)
        entity.refHandle = handle
        entity.isMarkedForDeletion = false
        entity.isNetworkable = entryIndex < SourceEntityConstants.maxEdicts
        entity.owningEntityList = self
        simulationStateChanged(entity)
        return handle
    }

    public func entity(for handle: SourceBaseHandle) -> SourceEntity? {
        guard handle.isValid else { return nil }
        let entryIndex = handle.entryIndex
        guard entryIndex >= 0 && entryIndex < slots.count else { return nil }
        let slot = slots[entryIndex]
        guard slot.serialNumber == handle.serialNumber else { return nil }
        return slot.entity
    }

    public func entity(at entryIndex: Int) -> SourceEntity? {
        guard entryIndex >= 0 && entryIndex < slots.count else { return nil }
        return slots[entryIndex].entity
    }

    public func handle(at entryIndex: Int) -> SourceBaseHandle {
        guard entryIndex >= 0 && entryIndex < slots.count,
              slots[entryIndex].entity != nil else {
            return .invalid
        }
        return SourceBaseHandle(
            entryIndex: entryIndex,
            serialNumber: slots[entryIndex].serialNumber
        )
    }

    public func markForDeletion(_ handle: SourceBaseHandle) {
        guard let entity = entity(for: handle), !entity.isMarkedForDeletion else { return }
        entity.isMarkedForDeletion = true
        if pendingDeletionSet.insert(handle).inserted {
            pendingDeletion.append(handle)
        }
    }

    public func markForDeletion(_ entity: SourceEntity) {
        markForDeletion(entity.refHandle)
    }

    /// Deletes all still-matching handles and advances each slot serial. A stale
    /// queued handle can never remove a later occupant of a reused slot.
    @discardableResult
    public func cleanupDeleteList() -> Int {
        let deleting = pendingDeletion
        pendingDeletion.removeAll(keepingCapacity: true)
        pendingDeletionSet.removeAll(keepingCapacity: true)

        var removedCount = 0
        for handle in deleting {
            guard let entity = entity(for: handle) else { continue }
            let entryIndex = handle.entryIndex
            removeSimThinkEntry(entryIndex: entryIndex)
            entity.owningEntityList = nil
            entity.refHandle = .invalid
            entity.isNetworkable = false
            slots[entryIndex].entity = nil
            slots[entryIndex].serialNumber =
                (slots[entryIndex].serialNumber + 1) & SourceEntityConstants.serialMask
            if let activeIndex = activeEntryIndices.firstIndex(of: entryIndex) {
                activeEntryIndices.remove(at: activeIndex)
            }
            if entryIndex > SourceEntityConstants.maxEdicts {
                freeNonNetworkableEntryIndices.append(entryIndex)
            }
            removedCount += 1
        }
        return removedCount
    }

    /// Mirrors `CSimThinkManager::EntityChanged`: first participation uses
    /// AddToTail, loss of both simulation and think uses FastRemove, and a
    /// later reactivation appends instead of returning to entity-list order.
    fileprivate func simulationStateChanged(_ entity: SourceEntity) {
        guard entity.refHandle.isValid, !entity.isMarkedForDeletion else { return }
        let entryIndex = entity.refHandle.entryIndex
        guard entryIndex >= 0, entryIndex < simThinkPositionByEntry.count,
              slots[entryIndex].entity === entity else { return }

        let shouldParticipate = entity.isGamePhysicsSimulationEnabled ||
            entity.firstThinkTick > 0
        let existingPosition = simThinkPositionByEntry[entryIndex]
        if !shouldParticipate {
            if existingPosition >= 0 { removeSimThinkEntry(entryIndex: entryIndex) }
            return
        }

        let nextThinkTick: Int32 = entity.isGamePhysicsSimulationEnabled
            ? 0
            : entity.firstThinkTick
        precondition(nextThinkTick >= 0)
        if existingPosition >= 0 {
            simThinkEntries[existingPosition].nextThinkTick = nextThinkTick
        } else {
            simThinkPositionByEntry[entryIndex] = simThinkEntries.count
            simThinkEntries.append(
                SimThinkEntry(entryIndex: entryIndex, nextThinkTick: nextThinkTick)
            )
        }
    }

    /// Copies the due subset before simulation in the incrementally maintained
    /// sim-think vector's current order. Callback mutations cannot change this
    /// frame's copied pointer order.
    fileprivate func simulationSnapshot(currentTick: Int32) -> [SourceEntity] {
        simThinkEntries.compactMap { entry in
            guard entry.nextThinkTick <= currentTick else { return nil }
            return slots[entry.entryIndex].entity
        }
    }

    /// `CUtlVector::FastRemove` overwrites the removed position with the final
    /// entry. This non-stable order is observable and deliberately retained.
    private func removeSimThinkEntry(entryIndex: Int) {
        let position = simThinkPositionByEntry[entryIndex]
        guard position >= 0 else { return }
        let lastPosition = simThinkEntries.count - 1
        if position != lastPosition {
            let moved = simThinkEntries[lastPosition]
            simThinkEntries[position] = moved
            simThinkPositionByEntry[moved.entryIndex] = position
        }
        simThinkEntries.removeLast()
        simThinkPositionByEntry[entryIndex] = -1
    }
}

/// Observable server-frame phases retained in Source SDK 2013 order.
public enum SourceServerPhase: String, CaseIterable, Equatable, Sendable {
    case cleanupDeleteListOutsideServerFrame
    case frameUpdatePreEntityThink
    case gameStartFrame
    case physicsRunThinkFunctionsCleanup
    case physicsRunThinkFunctions
    case frameUpdatePostEntityThink
    case serviceEventQueue
    case cleanupDeleteListAfterEntityThink
    case updateAllClientData
    case endGameFrame
}

/// GMod-observable hooks dispatched from its GameStartFrame integration. A
/// Windows x86-64 oracle confirms `Think` precedes `Tick` at identical CurTime.
public enum SourceAddonHookPhase: String, CaseIterable, Equatable, Sendable {
    case think = "Think"
    case tick = "Tick"
}

/// Engine-owned fixed-tick kernel. Platform renderers consume snapshots from a
/// higher layer; they must not drive individual subsystem phases themselves.
public final class SourceRuntimeKernel {
    public let entityList: SourceEntityList
    public private(set) var globals: SourceGlobalVars
    public private(set) var lastPhaseTrace: [SourceServerPhase] = []
    public private(set) var lastAddonHookTrace: [SourceAddonHookPhase] = []

    public init(
        entityList: SourceEntityList = SourceEntityList(),
        globals: SourceGlobalVars = SourceGlobalVars()
    ) {
        self.entityList = entityList
        self.globals = globals
    }

    /// Runs the simulating=true server path. Paused-player-only simulation is a
    /// separate Source contract and is intentionally not conflated with this one.
    public func runServerTick(
        onAddonHook: ((SourceAddonHookPhase) -> Void)? = nil,
        onPhase: ((SourceServerPhase) -> Void)? = nil
    ) {
        globals.beginServerTick()
        lastPhaseTrace.removeAll(keepingCapacity: true)
        lastAddonHookTrace.removeAll(keepingCapacity: true)

        perform(.cleanupDeleteListOutsideServerFrame, onPhase: onPhase) {
            entityList.cleanupDeleteList()
        }
        perform(.frameUpdatePreEntityThink, onPhase: onPhase)
        perform(.gameStartFrame, onPhase: onPhase) {
            for hook in SourceAddonHookPhase.allCases {
                lastAddonHookTrace.append(hook)
                onAddonHook?(hook)
            }
        }

        perform(.physicsRunThinkFunctionsCleanup, onPhase: onPhase) {
            entityList.cleanupDeleteList()
        }

        let simulationSnapshot = entityList.simulationSnapshot(currentTick: globals.tickCount)
        perform(.physicsRunThinkFunctions, onPhase: onPhase) {
            for entity in simulationSnapshot {
                if entity.isNetworkable {
                    entity.runPhysicsSimulationOnce(globals: &globals)
                } else {
                    _ = entity.physicsRunThink(globals: &globals)
                }
            }
        }

        perform(.frameUpdatePostEntityThink, onPhase: onPhase)
        perform(.serviceEventQueue, onPhase: onPhase)
        perform(.cleanupDeleteListAfterEntityThink, onPhase: onPhase) {
            entityList.cleanupDeleteList()
        }
        perform(.updateAllClientData, onPhase: onPhase)
        perform(.endGameFrame, onPhase: onPhase)
    }

    private func perform(
        _ phase: SourceServerPhase,
        onPhase: ((SourceServerPhase) -> Void)?,
        action: () -> Void = {}
    ) {
        lastPhaseTrace.append(phase)
        onPhase?(phase)
        action()
    }
}
