import Foundation
import GModLua

public enum GMLuaEntityKind: String, Sendable {
    case entity = "Entity"
    case player = "Player"
    case weapon = "Weapon"
    case vehicle = "Vehicle"
}

private final class GMLuaEntityValue: @unchecked Sendable {
    let index: Int
    let kind: GMLuaEntityKind
    var className: String

    init(index: Int, kind: GMLuaEntityKind, className: String) {
        self.index = index
        self.kind = kind
        self.className = className
    }
}

/// State-local identity registry for engine-backed Entity userdata.
///
/// The registry is deliberately empty until the host engine registers real
/// objects. Missing indices return canonical `NULL`; no fake Lua-table entity
/// is manufactured to make discovery appear successful.
public final class GMLuaEntityRegistry: @unchecked Sendable {
    private let state: LuaState
    private let typeSystem: GMLuaTypeSystem
    private let nullValue: LuaValue
    private let lock = NSLock()
    private var values: [Int: LuaValue] = [:]

    private init(state: LuaState, typeSystem: GMLuaTypeSystem, nullValue: LuaValue) {
        self.state = state
        self.typeSystem = typeSystem
        self.nullValue = nullValue
    }

    @discardableResult
    public func register(
        index: Int,
        kind: GMLuaEntityKind = .entity,
        className: String
    ) throws -> LuaValue {
        guard index >= 0 else {
            throw LuaError.runtime("entity index must be non-negative")
        }
        let payload = GMLuaEntityValue(index: index, kind: kind, className: className)
        let value = try typeSystem.makeObject(metaName: kind.rawValue, payload: payload)
        lock.lock()
        if let old = values[index], let oldObject = GMLuaTypeSystem.typedObject(from: old) {
            oldObject.isValid = false
        }
        values[index] = value
        lock.unlock()
        return value
    }

    public func unregister(index: Int) {
        lock.lock()
        let removed = values.removeValue(forKey: index)
        lock.unlock()
        GMLuaTypeSystem.typedObject(from: removed ?? .nilValue)?.isValid = false
    }

    public func entity(at index: Int) -> LuaValue {
        lock.lock()
        let value = values[index]
        lock.unlock()
        guard let value,
              GMLuaTypeSystem.typedObject(from: value)?.isValid == true else {
            return nullValue
        }
        return value
    }

    /// Reduces a state-local Entity userdata to the engine identity that is
    /// valid on the network transport. The receiving realm resolves that
    /// index through its own canonical registry.
    func networkIndex(from value: LuaValue, function: String) throws -> Int {
        guard let object = GMLuaTypeSystem.typedObject(from: value),
              ["Entity", "Player", "Weapon", "Vehicle"].contains(object.metaName) else {
            throw LuaError.runtime(
                "bad argument #2 to '\(function)' (Entity expected, got \(value.typeName))"
            )
        }
        guard object.isValid else { return -1 }
        guard let payload = object.payload as? GMLuaEntityValue else {
            throw LuaError.runtime("\(function) received an unregistered engine object")
        }
        return payload.index
    }

    public var registeredCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return values.count
    }

    fileprivate var references: [LuaValue] {
        lock.lock()
        defer { lock.unlock() }
        return Array(values.values) + [nullValue]
    }

    fileprivate func all(kind: GMLuaEntityKind? = nil) -> [LuaValue] {
        lock.lock()
        defer { lock.unlock() }
        return values.keys.sorted().compactMap { index in
            guard let value = values[index],
                  GMLuaTypeSystem.typedObject(from: value)?.isValid == true else { return nil }
            if let kind,
               (GMLuaTypeSystem.typedObject(from: value)?.payload as? GMLuaEntityValue)?.kind != kind {
                return nil
            }
            return value
        }
    }

    public static func install(
        into state: LuaState,
        typeSystem: GMLuaTypeSystem
    ) throws -> GMLuaEntityRegistry {
        let registry = GMLuaEntityRegistry(
            state: state,
            typeSystem: typeSystem,
            nullValue: state.getGlobal("NULL")
        )

        let entityMetatableNames = ["Entity", "Player", "Weapon", "Vehicle"]
        for methodName in ["EntIndex", "GetClass", "IsPlayer", "IsWeapon", "IsVehicle"] {
            let function = LuaValue.nativeFunction(
                LuaNativeFunctionBox(
                    { arguments in
                        let descriptor = try descriptor(arguments.first, method: methodName)
                        switch methodName {
                        case "EntIndex": return [.number(Double(descriptor?.index ?? -1))]
                        case "GetClass": return [.string(LuaString(descriptor?.className ?? "NULL"))]
                        case "IsPlayer": return [.boolean(descriptor?.kind == .player)]
                        case "IsWeapon": return [.boolean(descriptor?.kind == .weapon)]
                        case "IsVehicle": return [.boolean(descriptor?.kind == .vehicle)]
                        default: return []
                        }
                    },
                    debugName: "Entity:\(methodName)"
                )
            )
            for metatableName in entityMetatableNames {
                guard let metatable = typeSystem.metatable(named: metatableName) else { continue }
                try state.setRawTableValue(
                    function,
                    for: .string(LuaString(methodName)),
                    in: metatable
                )
            }
        }

        let entityLookup = LuaValue.nativeFunction(
            LuaNativeFunctionBox(
                { [weak registry] arguments in
                    guard let registry else { return [.nilValue] }
                    let index = try entityIndex(arguments, function: "Entity")
                    return [registry.entity(at: index)]
                },
                debugName: "Entity",
                gcReferences: { [weak registry] in registry?.references ?? [] }
            )
        )
        state.setGlobal("Entity", value: entityLookup)

        let ents = existingTable(named: "ents", in: state)
        let player = existingTable(named: "player", in: state)

        try state.setRawTableValue(
            .nativeFunction(
                LuaNativeFunctionBox(
                    { [weak registry, weak state] _ in
                        guard let registry, let state else { return [.table(LuaTable())] }
                        return [.table(try valueArray(registry.all(), state: state))]
                    },
                    debugName: "ents.GetAll",
                    gcReferences: { [weak registry] in registry?.references ?? [] }
                )
            ),
            for: .string("GetAll"),
            in: ents
        )
        try state.setRawTableValue(entityLookup, for: .string("GetByIndex"), in: ents)
        try state.setRawTableValue(
            .nativeFunction(
                LuaNativeFunctionBox(
                    { [weak registry, weak state] _ in
                        guard let registry, let state else { return [.table(LuaTable())] }
                        return [.table(try valueArray(registry.all(kind: .player), state: state))]
                    },
                    debugName: "player.GetAll",
                    gcReferences: { [weak registry] in registry?.references ?? [] }
                )
            ),
            for: .string("GetAll"),
            in: player
        )
        state.setGlobal("ents", value: .table(ents))
        state.setGlobal("player", value: .table(player))
        return registry
    }

    private static func descriptor(
        _ value: LuaValue?,
        method: String
    ) throws -> GMLuaEntityValue? {
        guard let value,
              let object = GMLuaTypeSystem.typedObject(from: value),
              ["Entity", "Player", "Weapon", "Vehicle"].contains(object.metaName) else {
            throw LuaError.runtime(
                "bad self to 'Entity:\(method)' (Entity expected, got \(value?.typeName ?? "no value"))"
            )
        }
        guard object.isValid else { return nil }
        guard let payload = object.payload as? GMLuaEntityValue else {
            throw LuaError.runtime("Entity:\(method) received an unregistered engine object")
        }
        return payload
    }

    private static func entityIndex(_ arguments: [LuaValue], function: String) throws -> Int {
        guard let first = arguments.first else {
            throw LuaError.runtime("bad argument #1 to '\(function)' (number expected, got no value)")
        }
        let number: Double
        switch first {
        case let .number(value): number = value
        case let .string(value):
            guard let parsed = Double(value.utf8String) else {
                throw LuaError.runtime("bad argument #1 to '\(function)' (number expected, got string)")
            }
            number = parsed
        default:
            throw LuaError.runtime(
                "bad argument #1 to '\(function)' (number expected, got \(first.typeName))"
            )
        }
        let lowerBoundInclusive = Double(Int.min)
        let upperBoundExclusive = -lowerBoundInclusive
        guard number.isFinite,
              number >= lowerBoundInclusive,
              number < upperBoundExclusive else {
            throw LuaError.runtime("bad argument #1 to '\(function)' (finite entity index expected)")
        }
        return Int(number.rounded(.towardZero))
    }

    private static func existingTable(named name: String, in state: LuaState) -> LuaTable {
        if case let .table(table) = state.getGlobal(name) { return table }
        return LuaTable()
    }

    private static func valueArray(_ values: [LuaValue], state: LuaState) throws -> LuaTable {
        let table = LuaTable()
        for (offset, value) in values.enumerated() {
            try state.setRawTableValue(
                value,
                for: .number(Double(offset + 1)),
                in: table
            )
        }
        return table
    }
}
