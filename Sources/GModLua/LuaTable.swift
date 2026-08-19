import Foundation

enum LuaTableKey: Hashable {
    case string(LuaString)
    case number(Double)
    case boolean(Bool)
    case table(ObjectIdentifier)
    case luaFunction(ObjectIdentifier)
    case nativeFunction(ObjectIdentifier)
    case userdata(ObjectIdentifier)
    case thread(ObjectIdentifier)
}

private final class LuaWeakBox<T: AnyObject>: @unchecked Sendable {
    weak var value: T?

    init(_ value: T) {
        self.value = value
    }
}

/// A weak Lua table must not let Swift ARC become an accidental strong root.
/// Lua strings and scalar values deliberately remain strong: PUC Lua 5.1 does
/// not clear string entries from weak tables (see the official gc.lua suite).
private enum LuaStoredValue {
    case strong(LuaValue)
    case weakTable(LuaWeakBox<LuaTable>)
    case weakLuaFunction(LuaWeakBox<LuaFunction>)
    case weakNativeFunction(LuaWeakBox<LuaNativeFunctionBox>)
    case weakUserdata(LuaWeakBox<LuaUserdata>)
    case weakThread(LuaWeakBox<LuaThread>)

    init(_ value: LuaValue, weak: Bool) {
        guard weak else {
            self = .strong(value)
            return
        }
        switch value {
        case let .table(table): self = .weakTable(LuaWeakBox(table))
        case let .luaFunction(function): self = .weakLuaFunction(LuaWeakBox(function))
        case let .nativeFunction(function): self = .weakNativeFunction(LuaWeakBox(function))
        case let .userdata(userdata): self = .weakUserdata(LuaWeakBox(userdata))
        case let .thread(thread): self = .weakThread(LuaWeakBox(thread))
        default: self = .strong(value)
        }
    }

    var value: LuaValue? {
        switch self {
        case let .strong(value): return value
        case let .weakTable(box): return box.value.map(LuaValue.table)
        case let .weakLuaFunction(box): return box.value.map(LuaValue.luaFunction)
        case let .weakNativeFunction(box): return box.value.map(LuaValue.nativeFunction)
        case let .weakUserdata(box): return box.value.map(LuaValue.userdata)
        case let .weakThread(box): return box.value.map(LuaValue.thread)
        }
    }
}

public final class LuaTable: @unchecked Sendable {
    private var storage: [LuaTableKey: LuaStoredValue] = [:]
    private var originalKeys: [LuaTableKey: LuaStoredValue] = [:]
    private var keyOrder: [LuaTableKey] = []
    private var keyPositions: [LuaTableKey: Int] = [:]

    public var metatable: LuaTable? {
        didSet { reconfigureWeakStorage() }
    }

    public init() {}

    func rawValue(for key: LuaValue) throws -> LuaValue {
        if case .nilValue = key { return .nilValue }
        // Lua 5.1 only rejects NaN when it is used to *set* a table entry.
        // A lookup with NaN can never match an existing key, so it behaves as
        // an ordinary miss (and still allows the caller to consult __index).
        if case let .number(number) = key, number.isNaN { return .nilValue }
        let tableKey = try makeKey(from: key)
        guard let stored = storage[tableKey] else { return .nilValue }
        guard let value = stored.value else {
            removeEntry(for: tableKey)
            return .nilValue
        }
        return value
    }

    func rawSetValue(_ value: LuaValue, for key: LuaValue) throws {
        let tableKey = try makeKey(from: key)
        set(value, for: tableKey, originalKey: key)
    }

    func rawValue(forString key: String) -> LuaValue {
        rawValue(forString: LuaString(key))
    }

    func rawValue(forString key: LuaString) -> LuaValue {
        let tableKey = LuaTableKey.string(key)
        guard let stored = storage[tableKey] else { return .nilValue }
        guard let value = stored.value else {
            removeEntry(for: tableKey)
            return .nilValue
        }
        return value
    }

    func rawSetValue(_ value: LuaValue, forString key: String) {
        rawSetValue(value, forString: LuaString(key))
    }

    func rawSetValue(_ value: LuaValue, forString key: LuaString) {
        set(value, for: .string(key), originalKey: .string(key))
    }

    func rawValue(forNumber key: Double) -> LuaValue {
        let tableKey = LuaTableKey.number(normalizeNumberKey(key))
        guard let stored = storage[tableKey] else { return .nilValue }
        guard let value = stored.value else {
            removeEntry(for: tableKey)
            return .nilValue
        }
        return value
    }

    func rawSetValue(_ value: LuaValue, forNumber key: Double) {
        let normalized = normalizeNumberKey(key)
        set(value, for: .number(normalized), originalKey: .number(normalized))
    }

    /// Any valid Lua table boundary is legal for tables with holes. Returning the
    /// contiguous sequence boundary is deterministic and matches the common case.
    func rawLength() -> Int {
        var index = 1
        while true {
            if case .nilValue = rawValue(forNumber: Double(index)) {
                return index - 1
            }
            index += 1
        }
    }

    func nextPair(after key: LuaValue?) throws -> (LuaValue, LuaValue)? {
        cleanupDeadWeakEntriesIfNeeded()

        let startIndex: Int
        if let key, !isNil(key) {
            let tableKey = try makeKey(from: key)
            guard let found = keyPositions[tableKey] else {
                throw LuaError.runtime("invalid key to 'next'")
            }
            startIndex = found + 1
        } else {
            startIndex = 0
        }

        var index = startIndex
        while index < keyOrder.count {
            let tableKey = keyOrder[index]
            if let original = originalKeys[tableKey]?.value,
               let value = storage[tableKey]?.value {
                return (original, value)
            }
            index += 1
        }
        return nil
    }

    func allPairs() -> [(LuaValue, LuaValue)] {
        cleanupDeadWeakEntriesIfNeeded()
        return keyOrder.compactMap { key in
            guard let original = originalKeys[key]?.value, let value = storage[key]?.value else { return nil }
            return (original, value)
        }
    }

    func clear() {
        storage.removeAll(keepingCapacity: false)
        originalKeys.removeAll(keepingCapacity: false)
        keyOrder.removeAll(keepingCapacity: false)
        keyPositions.removeAll(keepingCapacity: false)
    }

    var weakMode: String {
        guard let metatable else { return "" }
        guard case let .string(mode) = metatable.rawValue(forString: "__mode") else { return "" }
        return mode.utf8String
    }

    private func set(_ value: LuaValue, for key: LuaTableKey, originalKey: LuaValue) {
        if isNil(value) {
            storage.removeValue(forKey: key)
            // Keep the key as a tombstone. Lua permits deleting the current
            // key during traversal and passing that dead key back to next().
            return
        }

        if storage[key] == nil {
            // Reuse a tombstone left by deletion/weak collection. keyOrder is
            // the table's traversal history; appending the same key twice can
            // make next()/pairs() yield duplicate entries after reinsertion.
            if keyPositions[key] == nil {
                keyPositions[key] = keyOrder.count
                keyOrder.append(key)
            }
        }
        let mode = weakMode
        originalKeys[key] = LuaStoredValue(originalKey, weak: mode.contains("k"))
        storage[key] = LuaStoredValue(value, weak: mode.contains("v"))
    }

    private func makeKey(from value: LuaValue) throws -> LuaTableKey {
        switch value {
        case let .string(string):
            return .string(string)
        case let .number(number):
            guard !number.isNaN else { throw LuaError.runtime("table index is NaN") }
            return .number(normalizeNumberKey(number))
        case let .boolean(boolean):
            return .boolean(boolean)
        case let .table(table):
            return .table(ObjectIdentifier(table))
        case let .luaFunction(function):
            return .luaFunction(ObjectIdentifier(function))
        case let .nativeFunction(function):
            return .nativeFunction(ObjectIdentifier(function))
        case let .userdata(userdata):
            return .userdata(ObjectIdentifier(userdata))
        case let .thread(thread):
            return .thread(ObjectIdentifier(thread))
        case .nilValue:
            throw LuaError.runtime("table index is nil")
        }
    }

    private func normalizeNumberKey(_ number: Double) -> Double {
        number == 0 ? 0 : number
    }

    private func isNil(_ value: LuaValue) -> Bool {
        if case .nilValue = value { return true }
        return false
    }

    private func removeEntry(for key: LuaTableKey) {
        storage.removeValue(forKey: key)
        originalKeys.removeValue(forKey: key)
        // keyPositions/keyOrder intentionally keep a tombstone. Lua permits
        // deleting the current key while traversing and passing it to next().
    }

    private func reconfigureWeakStorage() {
        let mode = weakMode
        for key in keyOrder {
            guard let original = originalKeys[key]?.value,
                  let value = storage[key]?.value else {
                if storage[key] != nil || originalKeys[key] != nil { removeEntry(for: key) }
                continue
            }
            originalKeys[key] = LuaStoredValue(original, weak: mode.contains("k"))
            storage[key] = LuaStoredValue(value, weak: mode.contains("v"))
        }
    }

    /// Snapshot used by the explicit Lua heap marker. Weak entries are still
    /// visible here while the heap owns their objects; reachability rules are
    /// applied by LuaGarbageCollector rather than by Swift ARC timing.
    func gcPairs() -> [(LuaValue, LuaValue)] {
        keyOrder.compactMap { key in
            guard let original = originalKeys[key]?.value,
                  let value = storage[key]?.value else { return nil }
            return (original, value)
        }
    }

    /// Clears dead weak entries after a mark phase. Userdata queued for __gc
    /// remain as weak keys for one cycle, matching Lua 5.1 finalization order;
    /// weak values are always cleared before finalizers run.
    func gcSweepWeakEntries(
        marked: Set<ObjectIdentifier>,
        preservingFinalizingKeys: Set<ObjectIdentifier>
    ) {
        let mode = weakMode
        guard mode.contains("k") || mode.contains("v") else { return }
        for key in keyOrder {
            guard let original = originalKeys[key]?.value,
                  let value = storage[key]?.value else {
                removeEntry(for: key)
                continue
            }
            if mode.contains("k"),
               let identifier = original.collectableObjectIdentifier,
               !marked.contains(identifier),
               !preservingFinalizingKeys.contains(identifier) {
                removeEntry(for: key)
                continue
            }
            if mode.contains("v"),
               let identifier = value.collectableObjectIdentifier,
               !marked.contains(identifier) {
                removeEntry(for: key)
            }
        }
    }

    private func cleanupDeadWeakEntriesIfNeeded() {
        let mode = weakMode
        guard mode.contains("k") || mode.contains("v") else { return }
        for key in keyOrder where storage[key]?.value == nil || originalKeys[key]?.value == nil {
            removeEntry(for: key)
        }
    }
}
