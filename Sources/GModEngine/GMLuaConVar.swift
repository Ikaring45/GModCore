import Foundation
import GModLua

/// Immutable host description of a ConVar that exists before Lua starts.
///
/// Engine-owned entries deliberately stay opt-in: the embedding host supplies
/// the exact catalog for its process, and unknown names remain unknown to Lua.
public struct GMLuaEngineConVarDescriptor: Sendable, Equatable {
    public let name: String
    public let defaultValue: String
    public let initialValue: String
    public let flags: Int64
    public let helpText: String
    public let minimum: Double?
    public let maximum: Double?

    public init(
        name: String,
        defaultValue: String,
        initialValue: String? = nil,
        flags: Int64 = 0,
        helpText: String = "",
        minimum: Double? = nil,
        maximum: Double? = nil
    ) {
        self.name = name
        self.defaultValue = defaultValue
        self.initialValue = initialValue ?? defaultValue
        self.flags = flags
        self.helpText = helpText
        self.minimum = minimum
        self.maximum = maximum
    }
}

public enum GMLuaEngineConVarCatalogError: Error, Equatable, Sendable {
    case emptyName
    case invalidBounds(name: String)
}

private final class GMLuaConVarCurrentValue: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: String

    init(_ value: String) {
        storage = value
    }

    var value: String {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }
}

private final class GMLuaEngineConVarEntry: @unchecked Sendable {
    let descriptor: GMLuaEngineConVarDescriptor
    let currentValue: GMLuaConVarCurrentValue

    init(descriptor: GMLuaEngineConVarDescriptor) {
        self.descriptor = descriptor
        currentValue = GMLuaConVarCurrentValue(
            boundedConVarString(
                descriptor.initialValue,
                minimum: descriptor.minimum,
                maximum: descriptor.maximum
            )
        )
    }
}

/// Host-owned catalog installed into a Lua state alongside Lua-created ConVars.
///
/// A catalog may be shared by multiple states. Host updates are immediately
/// visible through every installed ConVar object backed by that catalog. It is
/// intentionally only an in-process value source; persistence and replication
/// are separate engine services.
public final class GMLuaEngineConVarCatalog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: GMLuaEngineConVarEntry] = [:]

    public init() {}

    public convenience init(
        descriptors: [GMLuaEngineConVarDescriptor]
    ) throws {
        self.init()
        for descriptor in descriptors {
            _ = try define(descriptor)
        }
    }

    /// Defines one engine-owned ConVar. Case-insensitive duplicates preserve
    /// the first definition and return false.
    @discardableResult
    public func define(_ descriptor: GMLuaEngineConVarDescriptor) throws -> Bool {
        let key = Self.normalizedName(descriptor.name)
        guard !key.isEmpty else {
            throw GMLuaEngineConVarCatalogError.emptyName
        }
        if let minimum = descriptor.minimum,
           let maximum = descriptor.maximum,
           minimum > maximum {
            throw GMLuaEngineConVarCatalogError.invalidBounds(name: descriptor.name)
        }

        lock.lock()
        defer { lock.unlock() }
        guard entries[key] == nil else { return false }
        entries[key] = GMLuaEngineConVarEntry(descriptor: descriptor)
        return true
    }

    public func contains(_ name: String) -> Bool {
        entry(for: name) != nil
    }

    public func currentValue(for name: String) -> String? {
        entry(for: name)?.currentValue.value
    }

    /// Updates an existing engine-owned value. Unknown names are not created.
    @discardableResult
    public func setCurrentValue(_ value: String, for name: String) -> Bool {
        guard let entry = entry(for: name) else { return false }
        entry.currentValue.value = boundedConVarString(
            value,
            minimum: entry.descriptor.minimum,
            maximum: entry.descriptor.maximum
        )
        return true
    }

    private func entry(for name: String) -> GMLuaEngineConVarEntry? {
        lock.lock()
        defer { lock.unlock() }
        return entries[Self.normalizedName(name)]
    }

    fileprivate var snapshot: [GMLuaEngineConVarEntry] {
        lock.lock()
        defer { lock.unlock() }
        return entries.keys.sorted().compactMap { entries[$0] }
    }

    private static func normalizedName(_ value: String) -> String {
        value.lowercased()
    }
}

/// Mutable payload for a GLua `ConVar` userdata.
///
/// Persistence and replication belong to engine services rather than being
/// pretended by this in-memory substrate.
private final class GMLuaConVarValue: @unchecked Sendable {
    let name: String
    let defaultValue: String
    private let currentValue: GMLuaConVarCurrentValue
    let flags: Int64
    let helpText: String
    let minimum: Double?
    let maximum: Double?
    let isEngineOwned: Bool

    init(
        name: String,
        defaultValue: String,
        value: String,
        flags: Int64,
        helpText: String,
        minimum: Double?,
        maximum: Double?,
        isEngineOwned: Bool = false,
        sharedCurrentValue: GMLuaConVarCurrentValue? = nil
    ) {
        self.name = name
        self.defaultValue = defaultValue
        currentValue = sharedCurrentValue ?? GMLuaConVarCurrentValue(value)
        self.flags = flags
        self.helpText = helpText
        self.minimum = minimum
        self.maximum = maximum
        self.isEngineOwned = isEngineOwned
    }

    var value: String {
        get { currentValue.value }
        set { currentValue.value = newValue }
    }
}

/// State-local registry shared by the ConVar bindings and console dispatcher.
///
/// The public read methods let an embedding host inspect installed variables
/// without exposing their userdata payload. Mutations from Lua console input
/// stay internal so engine-owned values remain under their catalog owner.
public final class GMLuaConVarRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: LuaValue] = [:]

    fileprivate var references: [LuaValue] {
        lock.lock()
        defer { lock.unlock() }
        return Array(values.values)
    }

    public func contains(_ name: String) -> Bool {
        luaValue(for: name) != nil
    }

    public func stringValue(for name: String) -> String? {
        guard let value = luaValue(for: name),
              let conVar = GMLuaTypeSystem.typedObject(from: value)?.payload
                as? GMLuaConVarValue else {
            return nil
        }
        return conVar.value
    }

    /// Applies the console form of assigning a Lua-created ConVar. Returns
    /// false for engine-owned or unknown variables, which belong to the host.
    @discardableResult
    func setConsoleValue(_ value: String, for name: String) -> Bool {
        guard let luaValue = luaValue(for: name),
              let conVar = GMLuaTypeSystem.typedObject(from: luaValue)?.payload
                as? GMLuaConVarValue,
              !conVar.isEngineOwned else {
            return false
        }
        conVar.value = GMLuaConVar.boundedString(value, for: conVar)
        return true
    }

    fileprivate func luaValue(for name: String) -> LuaValue? {
        lock.lock()
        defer { lock.unlock() }
        return values[Self.normalizedName(name)]
    }

    /// Returns an existing object for a case-insensitive duplicate, otherwise
    /// installs the supplied userdata and returns nil.
    fileprivate func insertIfAbsent(_ value: LuaValue, for name: String) -> LuaValue? {
        let key = Self.normalizedName(name)
        lock.lock()
        defer { lock.unlock() }
        if let existing = values[key] { return existing }
        values[key] = value
        return nil
    }

    fileprivate static func normalizedName(_ value: String) -> String {
        value.lowercased()
    }
}

/// Native, state-local implementation of the documented GLua ConVar surface.
public enum GMLuaConVar {
    // Public FCVAR values documented by Facepunch. Lua-created realm flags are
    // applied automatically in the same way as the engine bindings.
    private static let flagConstants: [String: Int64] = [
        "FCVAR_NONE": 0,
        "FCVAR_UNREGISTERED": 1,
        "FCVAR_GAMEDLL": 4,
        "FCVAR_CLIENTDLL": 8,
        "FCVAR_PROTECTED": 32,
        "FCVAR_SPONLY": 64,
        "FCVAR_ARCHIVE": 128,
        "FCVAR_NOTIFY": 256,
        "FCVAR_USERINFO": 512,
        "FCVAR_PRINTABLEONLY": 1_024,
        "FCVAR_UNLOGGED": 2_048,
        "FCVAR_NEVER_AS_STRING": 4_096,
        "FCVAR_REPLICATED": 8_192,
        "FCVAR_CHEAT": 16_384,
        "FCVAR_DEMO": 65_536,
        "FCVAR_DONTRECORD": 131_072,
        "FCVAR_LUA_CLIENT": 262_144,
        "FCVAR_LUA_SERVER": 524_288,
        "FCVAR_NOT_CONNECTED": 4_194_304,
        "FCVAR_ARCHIVE_XBOX": 16_777_216,
        "FCVAR_SERVER_CAN_EXECUTE": 268_435_456,
        "FCVAR_SERVER_CANNOT_QUERY": 536_870_912,
        "FCVAR_CLIENTCMD_CAN_EXECUTE": 1_073_741_824
    ]

    @discardableResult
    public static func install(
        into state: LuaState,
        typeSystem: GMLuaTypeSystem,
        realm: GMLuaRealm = .server,
        engineCatalog: GMLuaEngineConVarCatalog = GMLuaEngineConVarCatalog()
    ) throws -> GMLuaConVarRegistry {
        guard let metatable = typeSystem.metatable(named: "ConVar") else {
            throw LuaError.runtime("GLua ConVar metatable was not installed")
        }

        let store = GMLuaConVarRegistry()
        let automaticRealmFlag = flagConstants[
            realm == .server ? "FCVAR_LUA_SERVER" : "FCVAR_LUA_CLIENT"
        ] ?? 0

        for (name, value) in flagConstants {
            state.setGlobal(name, value: .number(Double(value)))
        }

        for entry in engineCatalog.snapshot {
            let descriptor = entry.descriptor
            let payload = GMLuaConVarValue(
                name: descriptor.name,
                defaultValue: descriptor.defaultValue,
                value: entry.currentValue.value,
                flags: descriptor.flags,
                helpText: descriptor.helpText,
                minimum: descriptor.minimum,
                maximum: descriptor.maximum,
                isEngineOwned: true,
                sharedCurrentValue: entry.currentValue
            )
            let value = try typeSystem.makeObject(metaName: "ConVar", payload: payload)
            _ = store.insertIfAbsent(value, for: descriptor.name)
        }

        func installMethod(
            _ name: String,
            _ body: @escaping LuaNativeFunction
        ) throws {
            try state.setRawTableValue(
                .nativeFunction(LuaNativeFunctionBox(body, debugName: "ConVar:\(name)")),
                for: .string(LuaString(name)),
                in: metatable
            )
        }

        try installMethod("GetName") { arguments in
            [.string(LuaString(try payload(arguments, method: "GetName").name))]
        }
        try installMethod("GetDefault") { arguments in
            [.string(LuaString(try payload(arguments, method: "GetDefault").defaultValue))]
        }
        try installMethod("GetString") { arguments in
            [.string(LuaString(try payload(arguments, method: "GetString").value))]
        }
        try installMethod("GetFloat") { arguments in
            [.number(numericValue(try payload(arguments, method: "GetFloat").value))]
        }
        try installMethod("GetInt") { arguments in
            let value = numericValue(try payload(arguments, method: "GetInt").value)
            return [.number(value.rounded(.towardZero))]
        }
        try installMethod("GetBool") { arguments in
            let value = numericValue(try payload(arguments, method: "GetBool").value)
            return [.boolean(value.rounded(.towardZero) != 0)]
        }
        try installMethod("GetFlags") { arguments in
            [.number(Double(try payload(arguments, method: "GetFlags").flags))]
        }
        try installMethod("GetHelpText") { arguments in
            [.string(LuaString(try payload(arguments, method: "GetHelpText").helpText))]
        }
        try installMethod("GetMin") { arguments in
            // The public GLua signature is numeric even when no explicit bound
            // was supplied; Source's neutral bound exposed to Lua is zero.
            [.number(try payload(arguments, method: "GetMin").minimum ?? 0)]
        }
        try installMethod("GetMax") { arguments in
            [.number(try payload(arguments, method: "GetMax").maximum ?? 0)]
        }
        try installMethod("IsFlagSet") { arguments in
            let conVar = try payload(arguments, method: "IsFlagSet")
            let requested = try integerFlag(
                requiredNumber(arguments, index: 1, function: "IsFlagSet"),
                function: "IsFlagSet",
                index: 1
            )
            return [.boolean(requested != 0 && (conVar.flags & requested) != 0)]
        }
        try installMethod("SetString") { arguments in
            let conVar = try payload(arguments, method: "SetString")
            let value = try requiredString(arguments, index: 1, function: "SetString")
            conVar.value = boundedString(value, for: conVar)
            return []
        }
        try installMethod("SetFloat") { arguments in
            let conVar = try payload(arguments, method: "SetFloat")
            let value = bounded(
                try requiredNumber(arguments, index: 1, function: "SetFloat"),
                for: conVar
            )
            conVar.value = LuaValue.number(value).printable
            return []
        }
        try installMethod("SetInt") { arguments in
            let conVar = try payload(arguments, method: "SetInt")
            let integer = try requiredNumber(
                arguments,
                index: 1,
                function: "SetInt"
            ).rounded(.towardZero)
            conVar.value = LuaValue.number(bounded(integer, for: conVar)).printable
            return []
        }
        try installMethod("SetBool") { arguments in
            let conVar = try payload(arguments, method: "SetBool")
            guard arguments.indices.contains(1), case let .boolean(value) = arguments[1] else {
                throw badArgument(
                    arguments,
                    index: 1,
                    function: "SetBool",
                    expected: "boolean"
                )
            }
            conVar.value = boundedString(value ? "1" : "0", for: conVar)
            return []
        }
        try installMethod("Revert") { arguments in
            let conVar = try payload(arguments, method: "Revert")
            conVar.value = boundedString(conVar.defaultValue, for: conVar)
            return []
        }

        let createBody: LuaNativeFunction = { arguments in
            let name = try requiredString(
                arguments,
                index: 0,
                function: "CreateConVar"
            )
            let defaultValue = try requiredString(
                arguments,
                index: 1,
                function: "CreateConVar"
            )
            let key = normalizedName(name)
            guard !key.isEmpty else {
                throw LuaError.runtime("ConVar name cannot be empty")
            }
            if let existing = store.luaValue(for: key) { return [existing] }

            let suppliedFlags = try flags(
                arguments.indices.contains(2) ? arguments[2] : .number(0),
                state: state
            )
            let helpText: String
            if !arguments.indices.contains(3) || isNil(arguments[3]) {
                helpText = ""
            } else {
                helpText = try requiredString(
                    arguments,
                    index: 3,
                    function: "CreateConVar"
                )
            }
            let minimum = try optionalNumber(
                arguments,
                index: 4,
                function: "CreateConVar"
            )
            let maximum = try optionalNumber(
                arguments,
                index: 5,
                function: "CreateConVar"
            )
            if let minimum, let maximum, minimum > maximum {
                throw LuaError.runtime("CreateConVar minimum cannot exceed maximum")
            }

            let payload = GMLuaConVarValue(
                name: name,
                defaultValue: defaultValue,
                value: defaultValue,
                flags: suppliedFlags | automaticRealmFlag,
                helpText: helpText,
                minimum: minimum,
                maximum: maximum
            )
            payload.value = boundedString(defaultValue, for: payload)
            let value = try typeSystem.makeObject(metaName: "ConVar", payload: payload)
            if let existing = store.insertIfAbsent(value, for: key) { return [existing] }
            return [value]
        }
        let create = LuaValue.nativeFunction(
            LuaNativeFunctionBox(
                createBody,
                debugName: "CreateConVar",
                gcReferences: { store.references }
            )
        )
        state.setGlobal("CreateConVar", value: create)

        let get = LuaValue.nativeFunction(
            LuaNativeFunctionBox(
                { arguments in
                    let name = try requiredString(
                        arguments,
                        index: 0,
                        function: "GetConVar"
                    )
                    return [store.luaValue(for: normalizedName(name)) ?? .nilValue]
                },
                debugName: "GetConVar_Internal",
                gcReferences: { store.references }
            )
        )
        state.setGlobal("GetConVar_Internal", value: get)
        state.setGlobal("GetConVar", value: get)

        state.setGlobal(
            "ConVarExists",
            value: .nativeFunction(
                LuaNativeFunctionBox(
                    { arguments in
                        let name = try requiredString(
                            arguments,
                            index: 0,
                            function: "ConVarExists"
                        )
                        return [.boolean(store.luaValue(for: normalizedName(name)) != nil)]
                    },
                    debugName: "ConVarExists",
                    gcReferences: { store.references }
                )
            )
        )

        state.setGlobal(
            "GetConVarString",
            value: .nativeFunction(
                LuaNativeFunctionBox(
                    { arguments in
                        let name = try requiredString(
                            arguments,
                            index: 0,
                            function: "GetConVarString"
                        )
                        guard let value = store.luaValue(for: normalizedName(name)),
                              let conVar = GMLuaTypeSystem.typedObject(from: value)?.payload
                                as? GMLuaConVarValue else {
                            return [.string(LuaString(""))]
                        }
                        return [.string(LuaString(conVar.value))]
                    },
                    debugName: "GetConVarString",
                    gcReferences: { store.references }
                )
            )
        )

        state.setGlobal(
            "GetConVarNumber",
            value: .nativeFunction(
                LuaNativeFunctionBox(
                    { arguments in
                        let name = try requiredString(
                            arguments,
                            index: 0,
                            function: "GetConVarNumber"
                        )
                        guard let value = store.luaValue(for: normalizedName(name)),
                              let conVar = GMLuaTypeSystem.typedObject(from: value)?.payload
                                as? GMLuaConVarValue else {
                            return [.number(0)]
                        }
                        return [.number(numericValue(conVar.value))]
                    },
                    debugName: "GetConVarNumber",
                    gcReferences: { store.references }
                )
            )
        )

        // The real util.lua replaces this with its longstanding shared wrapper.
        // Providing it before that load is useful for standalone/runtime tests
        // and preserves its documented flag behavior.
        state.setGlobal(
            "CreateClientConVar",
            value: .nativeFunction(
                LuaNativeFunctionBox(
                    { arguments in
                        let name = try requiredString(
                            arguments,
                            index: 0,
                            function: "CreateClientConVar"
                        )
                        let defaultValue = try requiredString(
                            arguments,
                            index: 1,
                            function: "CreateClientConVar"
                        )
                        let shouldSave = optionalBoolean(arguments, index: 2, default: true)
                        let userInfo = optionalBoolean(arguments, index: 3, default: false)
                        var clientFlags: Int64 = 0
                        if shouldSave { clientFlags |= flagConstants["FCVAR_ARCHIVE"] ?? 0 }
                        if userInfo { clientFlags |= flagConstants["FCVAR_USERINFO"] ?? 0 }

                        var forwarded: [LuaValue] = [
                            .string(LuaString(name)),
                            .string(LuaString(defaultValue)),
                            .number(Double(clientFlags))
                        ]
                        forwarded.append(
                            arguments.indices.contains(4) ? arguments[4] : .string(LuaString(""))
                        )
                        forwarded.append(arguments.indices.contains(5) ? arguments[5] : .nilValue)
                        forwarded.append(arguments.indices.contains(6) ? arguments[6] : .nilValue)
                        return try createBody(forwarded)
                    },
                    debugName: "CreateClientConVar",
                    gcReferences: { store.references }
                )
            )
        )

        return store
    }

    private static func payload(
        _ arguments: [LuaValue],
        method: String
    ) throws -> GMLuaConVarValue {
        guard let first = arguments.first,
              let object = GMLuaTypeSystem.typedObject(from: first),
              object.metaName == "ConVar",
              let payload = object.payload as? GMLuaConVarValue else {
            throw LuaError.runtime(
                "bad self to 'ConVar:\(method)' (ConVar expected, got " +
                (arguments.first?.typeName ?? "no value") + ")"
            )
        }
        return payload
    }

    private static func flags(_ value: LuaValue, state: LuaState) throws -> Int64 {
        switch value {
        case .nilValue:
            return 0
        case let .number(number):
            return try integerFlag(number, function: "CreateConVar", index: 2)
        case let .table(table):
            var result: Int64 = 0
            var index = 1
            while true {
                let entry = try state.rawTableValue(for: .number(Double(index)), in: table)
                if isNil(entry) { break }
                result |= try integerFlag(
                    number(from: entry, function: "CreateConVar", index: 2),
                    function: "CreateConVar",
                    index: 2
                )
                index += 1
            }
            return result
        default:
            throw LuaError.runtime(
                "bad argument #3 to 'CreateConVar' (number or table expected, got \(value.typeName))"
            )
        }
    }

    private static func requiredString(
        _ arguments: [LuaValue],
        index: Int,
        function: String
    ) throws -> String {
        guard arguments.indices.contains(index) else {
            throw badArgument(arguments, index: index, function: function, expected: "string")
        }
        switch arguments[index] {
        case let .string(string): return string.utf8String
        case let .number(number): return LuaValue.number(number).printable
        default:
            throw badArgument(arguments, index: index, function: function, expected: "string")
        }
    }

    private static func integerFlag(
        _ value: Double,
        function: String,
        index: Int
    ) throws -> Int64 {
        // `Double(Int64.max)` rounds up to exactly 2^63. An inclusive upper
        // comparison therefore admits 2^63 and makes Swift's Int64
        // conversion trap the process. Use the exact, exclusive 2^63 bound.
        let int64UpperBoundExclusive = 9_223_372_036_854_775_808.0
        let int64LowerBoundInclusive = -9_223_372_036_854_775_808.0
        guard value.isFinite,
              value >= int64LowerBoundInclusive,
              value < int64UpperBoundExclusive else {
            throw LuaError.runtime(
                "bad argument #\(index + 1) to '\(function)' (finite bitflag expected)"
            )
        }
        return Int64(value.rounded(.towardZero))
    }

    private static func requiredNumber(
        _ arguments: [LuaValue],
        index: Int,
        function: String
    ) throws -> Double {
        guard arguments.indices.contains(index) else {
            throw badArgument(arguments, index: index, function: function, expected: "number")
        }
        return try number(from: arguments[index], function: function, index: index)
    }

    private static func optionalNumber(
        _ arguments: [LuaValue],
        index: Int,
        function: String
    ) throws -> Double? {
        guard arguments.indices.contains(index), !isNil(arguments[index]) else { return nil }
        return try number(from: arguments[index], function: function, index: index)
    }

    private static func number(
        from value: LuaValue,
        function: String,
        index: Int
    ) throws -> Double {
        switch value {
        case let .number(number): return number
        case let .string(string):
            if let number = Double(string.utf8String.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return number
            }
            fallthrough
        default:
            throw LuaError.runtime(
                "bad argument #\(index + 1) to '\(function)' " +
                "(number expected, got \(value.typeName))"
            )
        }
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

    private static func optionalBoolean(
        _ arguments: [LuaValue],
        index: Int,
        default defaultValue: Bool
    ) -> Bool {
        guard arguments.indices.contains(index), !isNil(arguments[index]) else {
            return defaultValue
        }
        if case let .boolean(value) = arguments[index] { return value }
        return arguments[index].isTruthy
    }

    private static func normalizedName(_ value: String) -> String {
        value.lowercased()
    }

    private static func numericValue(_ value: String) -> Double {
        Double(value.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    private static func bounded(_ value: Double, for conVar: GMLuaConVarValue) -> Double {
        var result = value
        if let minimum = conVar.minimum { result = max(minimum, result) }
        if let maximum = conVar.maximum { result = min(maximum, result) }
        return result
    }

    fileprivate static func boundedString(
        _ value: String,
        for conVar: GMLuaConVarValue
    ) -> String {
        boundedConVarString(
            value,
            minimum: conVar.minimum,
            maximum: conVar.maximum
        )
    }

    private static func isNil(_ value: LuaValue) -> Bool {
        if case .nilValue = value { return true }
        return false
    }
}

private func boundedConVarString(
    _ value: String,
    minimum: Double?,
    maximum: Double?
) -> String {
    guard let parsed = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)) else {
        return value
    }
    var result = parsed
    if let minimum { result = max(minimum, result) }
    if let maximum { result = min(maximum, result) }
    return result == parsed ? value : LuaValue.number(result).printable
}
