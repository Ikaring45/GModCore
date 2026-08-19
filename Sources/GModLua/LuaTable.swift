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

public final class LuaTable: @unchecked Sendable {
    private var storage: [LuaTableKey: LuaValue] = [:]
    private var originalKeys: [LuaTableKey: LuaValue] = [:]
    private var keyOrder: [LuaTableKey] = []

    public var metatable: LuaTable?

    public init() {}

    func rawValue(for key: LuaValue) throws -> LuaValue {
        let tableKey = try makeKey(from: key)
        return storage[tableKey] ?? .nilValue
    }

    func rawSetValue(_ value: LuaValue, for key: LuaValue) throws {
        let tableKey = try makeKey(from: key)
        set(value, for: tableKey, originalKey: key)
    }

    func rawValue(forString key: String) -> LuaValue {
        rawValue(forString: LuaString(key))
    }

    func rawValue(forString key: LuaString) -> LuaValue {
        storage[.string(key)] ?? .nilValue
    }

    func rawSetValue(_ value: LuaValue, forString key: String) {
        rawSetValue(value, forString: LuaString(key))
    }

    func rawSetValue(_ value: LuaValue, forString key: LuaString) {
        set(value, for: .string(key), originalKey: .string(key))
    }

    func rawValue(forNumber key: Double) -> LuaValue {
        storage[.number(normalizeNumberKey(key))] ?? .nilValue
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
            guard let found = keyOrder.firstIndex(of: tableKey) else {
                throw LuaError.runtime("invalid key to 'next'")
            }
            startIndex = found + 1
        } else {
            startIndex = 0
        }

        guard startIndex < keyOrder.count else { return nil }
        let tableKey = keyOrder[startIndex]
        guard let original = originalKeys[tableKey], let value = storage[tableKey] else {
            return nil
        }
        return (original, value)
    }

    func allPairs() -> [(LuaValue, LuaValue)] {
        cleanupDeadWeakEntriesIfNeeded()
        return keyOrder.compactMap { key in
            guard let original = originalKeys[key], let value = storage[key] else { return nil }
            return (original, value)
        }
    }

    func clear() {
        storage.removeAll(keepingCapacity: false)
        originalKeys.removeAll(keepingCapacity: false)
        keyOrder.removeAll(keepingCapacity: false)
    }

    var weakMode: String {
        guard let metatable else { return "" }
        guard case let .string(mode) = metatable.rawValue(forString: "__mode") else { return "" }
        return mode.utf8String
    }

    private func set(_ value: LuaValue, for key: LuaTableKey, originalKey: LuaValue) {
        if isNil(value) {
            storage.removeValue(forKey: key)
            originalKeys.removeValue(forKey: key)
            keyOrder.removeAll { $0 == key }
            return
        }

        if storage[key] == nil {
            keyOrder.append(key)
            originalKeys[key] = originalKey
        }
        storage[key] = value
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

    /// ARC is the host memory manager. Full Lua mark/sweep is modeled at the
    /// LuaState heap layer; this hook is intentionally cheap and lets weak-table
    /// cleanup be expanded without changing table API semantics.
    private func cleanupDeadWeakEntriesIfNeeded() {
        // Object identity entries are currently cleaned by LuaState.collectGarbage().
    }
}
