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
    let generation: UInt64
    let userID: Int?
    var className: String
    var luaTable: LuaTable? = LuaTable()

    init(
        index: Int,
        kind: GMLuaEntityKind,
        generation: UInt64,
        userID: Int?,
        className: String
    ) {
        self.index = index
        self.kind = kind
        self.generation = generation
        self.userID = userID
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
    private let semanticIndex: LuaValue
    private let lock = NSLock()
    private var values: [Int: LuaValue] = [:]
    private var playerIdentityByUserID: [Int: (index: Int, generation: UInt64)] = [:]
    private var localPlayerIdentity: (index: Int, generation: UInt64)?

    private init(
        state: LuaState,
        typeSystem: GMLuaTypeSystem,
        nullValue: LuaValue,
        semanticIndex: LuaValue
    ) {
        self.state = state
        self.typeSystem = typeSystem
        self.nullValue = nullValue
        self.semanticIndex = semanticIndex
    }

    @discardableResult
    public func register(
        index: Int,
        kind: GMLuaEntityKind = .entity,
        className: String
    ) throws -> LuaValue {
        try register(
            index: index,
            kind: kind,
            generation: 0,
            userID: kind == .player ? index : nil,
            className: className
        )
    }

    @discardableResult
    func registerPlayerMirror(
        index: Int,
        generation: UInt64,
        userID: Int,
        className: String
    ) throws -> LuaValue {
        try register(
            index: index,
            kind: .player,
            generation: generation,
            userID: userID,
            className: className
        )
    }

    private func register(
        index: Int,
        kind: GMLuaEntityKind,
        generation: UInt64,
        userID: Int?,
        className: String
    ) throws -> LuaValue {
        guard index >= 0 else {
            throw LuaError.runtime("entity index must be non-negative")
        }
        if kind == .player {
            guard let userID, userID > 0 else {
                throw LuaError.runtime("Player user ID must be positive")
            }
        }
        let payload = GMLuaEntityValue(
            index: index,
            kind: kind,
            generation: generation,
            userID: userID,
            className: className
        )
        let value = try typeSystem.makeObject(metaName: kind.rawValue, payload: payload)
        lock.lock()
        if let userID,
           let mapped = playerIdentityByUserID[userID],
           mapped.index != index {
            lock.unlock()
            throw LuaError.runtime("Player user ID \(userID) is already registered")
        }
        if let old = values[index], let oldObject = GMLuaTypeSystem.typedObject(from: old) {
            oldObject.isValid = false
            if let oldPayload = oldObject.payload as? GMLuaEntityValue {
                oldPayload.luaTable = nil
                removePlayerUserIDMapping(for: oldPayload)
            }
        }
        values[index] = value
        if let userID {
            playerIdentityByUserID[userID] = (index, generation)
        }
        lock.unlock()
        state.refreshGarbageCollectionRootProviders()
        return value
    }

    public func unregister(index: Int) {
        lock.lock()
        let removed = values.removeValue(forKey: index)
        if let object = GMLuaTypeSystem.typedObject(from: removed ?? .nilValue) {
            object.isValid = false
            if let payload = object.payload as? GMLuaEntityValue {
                payload.luaTable = nil
                removePlayerUserIDMapping(for: payload)
                if localPlayerIdentity?.index == index,
                   localPlayerIdentity?.generation == payload.generation {
                    localPlayerIdentity = nil
                }
            }
        }
        lock.unlock()
    }

    func unregisterPlayerMirror(index: Int, generation: UInt64) {
        lock.lock()
        let current = values[index]
        let payload = current
            .flatMap(GMLuaTypeSystem.typedObject(from:))?
            .payload as? GMLuaEntityValue
        if payload?.kind == .player, payload?.generation == generation {
            let removed = values.removeValue(forKey: index)
            GMLuaTypeSystem.typedObject(from: removed ?? .nilValue)?.isValid = false
            payload?.luaTable = nil
            if let payload { removePlayerUserIDMapping(for: payload) }
            if localPlayerIdentity?.index == index,
               localPlayerIdentity?.generation == generation {
                localPlayerIdentity = nil
            }
        }
        lock.unlock()
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

    public func player(at index: Int) -> LuaValue {
        let value = entity(at: index)
        guard let object = GMLuaTypeSystem.typedObject(from: value),
              object.isValid,
              let payload = object.payload as? GMLuaEntityValue,
              payload.kind == .player else { return nullValue }
        return value
    }

    /// Resolves GLua's global `Player(number)`, whose numeric argument is a
    /// UserID rather than an EntIndex. Engine/net code must continue to use
    /// ``player(at:)`` for canonical entity-index lookup.
    public func player(forUserID userID: Int) -> LuaValue {
        lock.lock()
        let identity = playerIdentityByUserID[userID]
        let value = identity.flatMap { values[$0.index] }
        lock.unlock()
        guard let identity,
              let value,
              let object = GMLuaTypeSystem.typedObject(from: value),
              object.isValid,
              let payload = object.payload as? GMLuaEntityValue,
              payload.kind == .player,
              payload.generation == identity.generation,
              payload.userID == userID else { return nullValue }
        return value
    }

    private func removePlayerUserIDMapping(for payload: GMLuaEntityValue) {
        guard let userID = payload.userID,
              let mapped = playerIdentityByUserID[userID],
              mapped.index == payload.index,
              mapped.generation == payload.generation else { return }
        playerIdentityByUserID.removeValue(forKey: userID)
    }

    func setLocalPlayer(index: Int, generation: UInt64) throws {
        let value = player(at: index)
        guard let object = GMLuaTypeSystem.typedObject(from: value),
              object.isValid,
              let payload = object.payload as? GMLuaEntityValue,
              payload.generation == generation else {
            throw LuaError.runtime(
                "LocalPlayer requires the current canonical Player mirror"
            )
        }
        lock.lock()
        localPlayerIdentity = (index, generation)
        lock.unlock()
    }

    func clearLocalPlayer(index: Int, generation: UInt64) {
        lock.lock()
        if localPlayerIdentity?.index == index,
           localPlayerIdentity?.generation == generation {
            localPlayerIdentity = nil
        }
        lock.unlock()
    }

    func localPlayer() -> LuaValue {
        lock.lock()
        let identity = localPlayerIdentity
        let value = identity.flatMap { values[$0.index] }
        lock.unlock()
        guard let identity,
              let value,
              let object = GMLuaTypeSystem.typedObject(from: value),
              object.isValid,
              let payload = object.payload as? GMLuaEntityValue,
              payload.kind == .player,
              payload.generation == identity.generation else { return nullValue }
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

    func playerNetworkIndex(
        from value: LuaValue,
        function: String,
        argumentPosition: Int = 1
    ) throws -> Int {
        guard let object = GMLuaTypeSystem.typedObject(from: value),
              object.metaName == "Player" else {
            throw LuaError.runtime(
                "bad argument #\(argumentPosition) to '\(function)' " +
                "(Player expected, got \(value.typeName))"
            )
        }
        guard object.isValid,
              let payload = object.payload as? GMLuaEntityValue,
              payload.kind == .player else {
            throw LuaError.runtime(
                "bad argument #\(argumentPosition) to '\(function)' " +
                "(current connected Player expected, got invalid Player)"
            )
        }
        let canonical = player(at: payload.index)
        guard GMLuaTypeSystem.typedObject(from: canonical) === object else {
            throw LuaError.runtime(
                "bad argument #\(argumentPosition) to '\(function)' " +
                "(stale Player generation)"
            )
        }
        return payload.index
    }

    public var registeredCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return values.count
    }

    fileprivate func luaTable(for value: LuaValue) -> LuaTable? {
        guard case let .userdata(userdata) = value,
              let object = GMLuaTypeSystem.typedObject(from: value),
              let payload = object.payload as? GMLuaEntityValue else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard object.isValid,
              case let .userdata(canonical)? = values[payload.index],
              canonical === userdata else { return nil }
        return payload.luaTable
    }

    fileprivate func indexedLuaTableValue(
        for value: LuaValue,
        key: LuaValue
    ) throws -> LuaValue {
        guard let table = luaTable(for: value) else { return .nilValue }
        return try state.call(
            semanticIndex,
            arguments: [.table(table), key]
        ).first ?? .nilValue
    }

    @discardableResult
    fileprivate func setIndexedLuaTableValue(
        _ newValue: LuaValue,
        for value: LuaValue,
        key: LuaValue
    ) throws -> Bool {
        // Capture under the registry lock, then run ordinary table assignment
        // outside it because a custom __newindex may execute arbitrary Lua.
        guard let table = luaTable(for: value) else { return false }
        try state.setTableValue(newValue, for: key, in: table)
        return true
    }

    @discardableResult
    fileprivate func replaceLuaTable(
        for value: LuaValue,
        with replacement: LuaTable
    ) -> Bool {
        guard case let .userdata(userdata) = value,
              let object = GMLuaTypeSystem.typedObject(from: value),
              let payload = object.payload as? GMLuaEntityValue else { return false }
        lock.lock()
        guard object.isValid,
              case let .userdata(canonical)? = values[payload.index],
              canonical === userdata else {
            lock.unlock()
            return false
        }
        payload.luaTable = replacement
        lock.unlock()
        state.refreshGarbageCollectionRootProviders()
        return true
    }

    fileprivate var references: [LuaValue] {
        lock.lock()
        defer { lock.unlock() }
        let canonical = Array(values.values)
        let tables = canonical.compactMap { value -> LuaTable? in
            guard let payload = GMLuaTypeSystem.typedObject(from: value)?.payload
                as? GMLuaEntityValue else { return nil }
            return payload.luaTable
        }.map(LuaValue.table)
        return canonical + tables + [nullValue, semanticIndex]
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
        typeSystem: GMLuaTypeSystem,
        realm: GMLuaRealm = .server
    ) throws -> GMLuaEntityRegistry {
        let semanticIndex = try state.executeReturningValues(
            "return function(container, key) return container[key] end",
            sourceName: "=[GModLua Entity table index helper]"
        ).first ?? .nilValue
        let nullValue = state.getGlobal("NULL")
        let registry = GMLuaEntityRegistry(
            state: state,
            typeSystem: typeSystem,
            nullValue: nullValue,
            semanticIndex: semanticIndex
        )
        state.registerGarbageCollectionRootProvider { [weak registry] in
            registry?.references ?? []
        }

        let entityMetatableNames = ["Entity", "Player", "Weapon", "Vehicle"]
        func entityNativeFunction(
            _ name: String,
            _ body: @escaping LuaNativeFunction
        ) -> LuaValue {
            .nativeFunction(
                LuaNativeFunctionBox(
                    body,
                    debugName: name,
                    gcReferences: { [weak registry] in registry?.references ?? [] }
                )
            )
        }
        for methodName in ["EntIndex", "GetClass", "IsPlayer", "IsWeapon", "IsVehicle"] {
            let function = entityNativeFunction("Entity:\(methodName)") { arguments in
                        let descriptor = try descriptor(arguments.first, method: methodName)
                        switch methodName {
                        case "EntIndex": return [.number(Double(descriptor?.index ?? 0))]
                        case "GetClass": return [.string(LuaString(descriptor?.className ?? "NULL"))]
                        case "IsPlayer": return [.boolean(descriptor?.kind == .player)]
                        case "IsWeapon": return [.boolean(descriptor?.kind == .weapon)]
                        case "IsVehicle": return [.boolean(descriptor?.kind == .vehicle)]
                        default: return []
                        }
                    }
            for metatableName in entityMetatableNames {
                guard let metatable = typeSystem.metatable(named: metatableName) else { continue }
                try state.setRawTableValue(
                    function,
                    for: .string(LuaString(methodName)),
                    in: metatable
                )
            }
        }

        let getTable = entityNativeFunction("Entity:GetTable") { arguments in
            _ = try descriptor(arguments.first, method: "GetTable")
            return [arguments.first.flatMap(registry.luaTable(for:)).map(LuaValue.table)
                ?? .nilValue]
        }
        let setTable = entityNativeFunction("Entity:SetTable") { arguments in
            _ = try descriptor(arguments.first, method: "SetTable")
            guard arguments.indices.contains(1), case let .table(table) = arguments[1] else {
                let actual = arguments.indices.contains(1)
                    ? arguments[1].typeName
                    : "no value"
                throw LuaError.runtime(
                    "bad argument #1 to 'Entity:SetTable' (table expected, got \(actual))"
                )
            }
            if let receiver = arguments.first {
                _ = registry.replaceLuaTable(for: receiver, with: table)
            }
            return []
        }
        for metatableName in entityMetatableNames {
            guard let metatable = typeSystem.metatable(named: metatableName) else { continue }
            try state.setRawTableValue(getTable, for: .string("GetTable"), in: metatable)
            try state.setRawTableValue(setTable, for: .string("SetTable"), in: metatable)
        }

        let entityEquality = entityNativeFunction("Entity.__eq") { arguments in
            guard arguments.count >= 2,
                  let left = GMLuaTypeSystem.typedObject(from: arguments[0]),
                  let right = GMLuaTypeSystem.typedObject(from: arguments[1]) else {
                return [.boolean(false)]
            }
            return [.boolean(!left.isValid && !right.isValid)]
        }
        for metatableName in entityMetatableNames {
            guard let metatable = typeSystem.metatable(named: metatableName) else { continue }
            try state.setRawTableValue(
                entityEquality,
                for: .string("__eq"),
                in: metatable
            )
        }

        guard let entityMetatable = typeSystem.metatable(named: "Entity") else {
            throw LuaError.runtime("GLua Entity metatable was not installed")
        }
        for metatableName in entityMetatableNames {
            guard let metatable = typeSystem.metatable(named: metatableName) else { continue }
            let methodTables = metatableName == "Entity"
                ? [entityMetatable]
                : [metatable, entityMetatable]
            let index = entityNativeFunction("\(metatableName).__index") { arguments in
                guard arguments.indices.contains(1) else { return [.nilValue] }
                for methodTable in methodTables {
                    let method = try state.rawTableValue(for: arguments[1], in: methodTable)
                    if case .nilValue = method {
                        continue
                    }
                    return [method]
                }
                let tableValue = try registry.indexedLuaTableValue(
                    for: arguments[0],
                    key: arguments[1]
                )
                if case .nilValue = tableValue {
                    if metatableName == "Entity",
                       case let .string(key) = arguments[1],
                       key.utf8String == "Owner" {
                        let getOwner = try state.rawTableValue(
                            for: .string("GetOwner"),
                            in: entityMetatable
                        )
                        switch getOwner {
                        case .luaFunction, .nativeFunction:
                            return [try state.call(
                                getOwner,
                                arguments: [arguments[0]]
                            ).first ?? .nilValue]
                        default:
                            break
                        }
                    }
                }
                return [tableValue]
            }
            let newIndex = entityNativeFunction("\(metatableName).__newindex") { arguments in
                guard arguments.count >= 3 else { return [] }
                _ = try registry.setIndexedLuaTableValue(
                    arguments[2],
                    for: arguments[0],
                    key: arguments[1]
                )
                return []
            }
            try state.setRawTableValue(index, for: .string("__index"), in: metatable)
            try state.setRawTableValue(newIndex, for: .string("__newindex"), in: metatable)
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

        let playerLookup = LuaValue.nativeFunction(
            LuaNativeFunctionBox(
                { [weak registry] arguments in
                    guard let registry else { return [.nilValue] }
                    let userID = try entityIndex(arguments, function: "Player")
                    return [registry.player(forUserID: userID)]
                },
                debugName: "Player",
                gcReferences: { [weak registry] in registry?.references ?? [] }
            )
        )
        state.setGlobal("Player", value: playerLookup)
        if realm == .client {
            state.setGlobal(
                "LocalPlayer",
                value: .nativeFunction(
                    LuaNativeFunctionBox(
                        { [weak registry] _ in
                            [registry?.localPlayer() ?? nullValue]
                        },
                        debugName: "LocalPlayer",
                        gcReferences: { [weak registry] in registry?.references ?? [] }
                    )
                )
            )
        }

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
