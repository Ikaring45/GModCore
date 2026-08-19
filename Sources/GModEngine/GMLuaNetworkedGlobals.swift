import Foundation
import GModLua

private enum GMLuaNetworkedGlobalKind: Hashable, Sendable {
    case bool
    case int
    case float
    case string
    case entity
    case vector
    case angle
}

private struct GMLuaNetworkedGlobalKey: Hashable, Sendable {
    let index: LuaString
}

private enum GMLuaNetworkedGlobalValue: Sendable {
    case bool(Bool)
    // Despite its legacy name, SetGlobalInt uses a 64-bit float and does not
    // round fractional values in Garry's Mod.
    case int(Double)
    case float(Float)
    case string(LuaString)
    case entity(index: Int)
    case vector(x: Float, y: Float, z: Float)
    case angle(pitch: Float, yaw: Float, roll: Float)
}

private struct GMLuaNetworkedGlobalEntry: Sendable {
    let revision: UInt64
    let value: GMLuaNetworkedGlobalValue
}

/// Host-owned transport for Source-style global network variables.
///
/// Give the same instance to a SERVER runtime and its connected CLIENT
/// runtimes. Server writes then become visible to every connected runtime.
/// Lua userdata is never retained here: Entity values travel as engine
/// indices, and Vector/Angle values travel as copied Float32 components.
public final class GMLuaNetworkedGlobalTransport: @unchecked Sendable {
    public static let maximumSlots = 4095

    private let lock = NSLock()
    private var revision: UInt64 = 0
    private var serverEntries: [GMLuaNetworkedGlobalKey: GMLuaNetworkedGlobalEntry] = [:]
    private var pooledNames: [LuaString] = []
    private var pooledNameIDs: [LuaString: Int] = [:]

    public init() {}

    public var storedValueCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return serverEntries.count
    }

    public var pooledStringCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return pooledNames.count
    }

    /// Stable snapshot of the shared Source NetworkString table. Global
    /// network-variable keys and net-message names intentionally occupy this
    /// same 4095-entry namespace.
    public var pooledNetworkStrings: [String] {
        lock.lock()
        defer { lock.unlock() }
        return pooledNames.map(\.utf8String)
    }

    fileprivate func serverEntry(
        for key: GMLuaNetworkedGlobalKey
    ) -> GMLuaNetworkedGlobalEntry? {
        lock.lock()
        defer { lock.unlock() }
        return serverEntries[key]
    }

    @discardableResult
    fileprivate func writeServer(
        _ value: GMLuaNetworkedGlobalValue,
        for key: GMLuaNetworkedGlobalKey,
        function: String
    ) throws -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        if pooledNameIDs[key.index] == nil,
           pooledNames.count >= Self.maximumSlots {
            throw LuaError.runtime(
                "\(function) exceeded the shared 4095-slot NetworkString limit"
            )
        }
        if pooledNameIDs[key.index] == nil {
            pooledNames.append(key.index)
            pooledNameIDs[key.index] = pooledNames.count
        }
        revision &+= 1
        serverEntries[key] = GMLuaNetworkedGlobalEntry(
            revision: revision,
            value: value
        )
        return revision
    }

    fileprivate func poolNetworkString(
        _ name: LuaString,
        function: String
    ) throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        if let existing = pooledNameIDs[name] { return existing }
        guard pooledNames.count < Self.maximumSlots else {
            throw LuaError.runtime(
                "\(function) exceeded the shared 4095-slot NetworkString limit"
            )
        }
        pooledNames.append(name)
        let identifier = pooledNames.count
        pooledNameIDs[name] = identifier
        return identifier
    }

    func networkStringID(for name: LuaString) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return pooledNameIDs[name] ?? 0
    }

    func networkString(for identifier: Int) -> LuaString? {
        lock.lock()
        defer { lock.unlock() }
        guard identifier > 0, identifier <= pooledNames.count else { return nil }
        return pooledNames[identifier - 1]
    }

    fileprivate func reserveClientRevision() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        revision &+= 1
        return revision
    }

    /// Reissues the authoritative server snapshot with a revision newer than
    /// every server or client-local write observed by this transport.
    ///
    /// Hosts can call this at their network tick boundary to make clients
    /// prefer server values again after a local SetGlobal* overwrite. The
    /// desktop engine's periodic ten-second resend cadence is not automatically
    /// scheduled by this transport yet.
    @discardableResult
    public func resendServerSnapshot() -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard !serverEntries.isEmpty else { return 0 }
        revision &+= 1
        let snapshotRevision = revision
        let snapshot = serverEntries
        for (key, entry) in snapshot {
            serverEntries[key] = GMLuaNetworkedGlobalEntry(
                revision: snapshotRevision,
                value: entry.value
            )
        }
        return serverEntries.count
    }
}

/// Lua binding for the legacy SetGlobal*/GetGlobal* family.
///
/// A runtime constructed without an explicit transport owns a standalone
/// transport. That mode models one isolated GMod realm: server writes can be
/// read back in that realm, client writes are client-local, and an unset key
/// returns only the documented caller/default value. It never fabricates a
/// connection to another runtime.
public final class GMLuaNetworkedGlobals: @unchecked Sendable {
    public let realm: GMLuaRealm
    public let transport: GMLuaNetworkedGlobalTransport
    public let usesStandaloneTransport: Bool

    private let typeSystem: GMLuaTypeSystem
    private let entityRegistry: GMLuaEntityRegistry
    private let localLock = NSLock()
    private var clientEntries: [GMLuaNetworkedGlobalKey: GMLuaNetworkedGlobalEntry] = [:]
    private var clientPooledNames: Set<LuaString> = []

    private init(
        realm: GMLuaRealm,
        transport: GMLuaNetworkedGlobalTransport,
        usesStandaloneTransport: Bool,
        typeSystem: GMLuaTypeSystem,
        entityRegistry: GMLuaEntityRegistry
    ) {
        self.realm = realm
        self.transport = transport
        self.usesStandaloneTransport = usesStandaloneTransport
        self.typeSystem = typeSystem
        self.entityRegistry = entityRegistry
    }

    static func install(
        into state: LuaState,
        realm: GMLuaRealm,
        typeSystem: GMLuaTypeSystem,
        entityRegistry: GMLuaEntityRegistry,
        transport explicitTransport: GMLuaNetworkedGlobalTransport?
    ) -> GMLuaNetworkedGlobals {
        let binding = GMLuaNetworkedGlobals(
            realm: realm,
            transport: explicitTransport ?? GMLuaNetworkedGlobalTransport(),
            usesStandaloneTransport: explicitTransport == nil,
            typeSystem: typeSystem,
            entityRegistry: entityRegistry
        )

        binding.installSetter("SetGlobalBool", kind: .bool, into: state)
        binding.installSetter("SetGlobalInt", kind: .int, into: state)
        binding.installSetter("SetGlobalFloat", kind: .float, into: state)
        binding.installSetter("SetGlobalString", kind: .string, into: state)
        binding.installSetter("SetGlobalEntity", kind: .entity, into: state)
        binding.installSetter("SetGlobalVector", kind: .vector, into: state)
        binding.installSetter("SetGlobalAngle", kind: .angle, into: state)
        binding.installGenericSetter(into: state)

        binding.installGetter("GetGlobalBool", kind: .bool, into: state)
        binding.installGetter("GetGlobalInt", kind: .int, into: state)
        binding.installGetter("GetGlobalFloat", kind: .float, into: state)
        binding.installGetter("GetGlobalString", kind: .string, into: state)
        binding.installGetter("GetGlobalEntity", kind: .entity, into: state)
        binding.installGetter("GetGlobalVector", kind: .vector, into: state)
        binding.installGetter("GetGlobalAngle", kind: .angle, into: state)
        binding.installGenericGetter(into: state)

        return binding
    }

    private func installGenericSetter(into state: LuaState) {
        state.register("SetGlobalVar") { [unowned self] arguments in
            let key = GMLuaNetworkedGlobalKey(
                index: try self.requiredIndex(
                    arguments,
                    function: "SetGlobalVar"
                )
            )
            let value = try self.requiredGenericSetValue(
                arguments,
                function: "SetGlobalVar"
            )
            try self.store(value, for: key, function: "SetGlobalVar")
            return []
        }
    }

    private func installGenericGetter(into state: LuaState) {
        state.register("GetGlobalVar") { [unowned self] arguments in
            let key = GMLuaNetworkedGlobalKey(
                index: try self.requiredIndex(
                    arguments,
                    function: "GetGlobalVar"
                )
            )
            if let entry = self.visibleEntry(for: key) {
                return [try self.luaValue(
                    from: entry.value,
                    function: "GetGlobalVar"
                )]
            }
            return [arguments.indices.contains(1) ? arguments[1] : .nilValue]
        }
    }

    private func installSetter(
        _ function: String,
        kind: GMLuaNetworkedGlobalKind,
        into state: LuaState
    ) {
        state.register(function) { [unowned self] arguments in
            let key = GMLuaNetworkedGlobalKey(
                index: try self.requiredIndex(arguments, function: function)
            )
            let value = try self.requiredSetValue(
                arguments,
                kind: kind,
                function: function
            )
            try self.store(value, for: key, function: function)
            return []
        }
    }

    private func installGetter(
        _ function: String,
        kind: GMLuaNetworkedGlobalKind,
        into state: LuaState
    ) {
        state.register(function) { [unowned self] arguments in
            let key = GMLuaNetworkedGlobalKey(
                index: try self.requiredIndex(arguments, function: function)
            )
            if let entry = self.visibleEntry(for: key) {
                return [try self.luaValue(from: entry.value, function: function)]
            }
            return [try self.defaultValue(
                arguments,
                kind: kind,
                function: function
            )]
        }
    }

    private func store(
        _ value: GMLuaNetworkedGlobalValue,
        for key: GMLuaNetworkedGlobalKey,
        function: String
    ) throws {
        if realm == .server {
            try transport.writeServer(value, for: key, function: function)
            return
        }

        let newRevision = transport.reserveClientRevision()
        localLock.lock()
        defer { localLock.unlock() }
        if !clientPooledNames.contains(key.index),
           clientPooledNames.count >= GMLuaNetworkedGlobalTransport.maximumSlots {
            throw LuaError.runtime(
                "\(function) exceeded the 4095-slot client-local global network limit"
            )
        }
        clientPooledNames.insert(key.index)
        clientEntries[key] = GMLuaNetworkedGlobalEntry(
            revision: newRevision,
            value: value
        )
    }

    func addNetworkString(_ name: LuaString) throws -> Int {
        try transport.poolNetworkString(name, function: "util.AddNetworkString")
    }

    func networkStringID(for name: LuaString) -> Int {
        transport.networkStringID(for: name)
    }

    func networkString(for identifier: Int) -> LuaString? {
        transport.networkString(for: identifier)
    }

    private func visibleEntry(
        for key: GMLuaNetworkedGlobalKey
    ) -> GMLuaNetworkedGlobalEntry? {
        let serverEntry = transport.serverEntry(for: key)
        guard realm != .server else { return serverEntry }

        localLock.lock()
        let clientEntry = clientEntries[key]
        localLock.unlock()
        switch (serverEntry, clientEntry) {
        case let (server?, client?):
            return client.revision > server.revision ? client : server
        case let (server?, nil): return server
        case let (nil, client?): return client
        case (nil, nil): return nil
        }
    }

    private func requiredIndex(
        _ arguments: [LuaValue],
        function: String
    ) throws -> LuaString {
        guard let value = arguments.first else {
            throw LuaError.runtime(
                "bad argument #1 to '\(function)' (string expected, got no value)"
            )
        }
        switch value {
        case let .string(index): return index
        case .number: return LuaString(value.printable)
        default:
            throw LuaError.runtime(
                "bad argument #1 to '\(function)' (string expected, got \(value.typeName))"
            )
        }
    }

    private func requiredSetValue(
        _ arguments: [LuaValue],
        kind: GMLuaNetworkedGlobalKind,
        function: String
    ) throws -> GMLuaNetworkedGlobalValue {
        guard arguments.indices.contains(1) else {
            throw LuaError.runtime(
                "bad argument #2 to '\(function)' (\(typeName(for: kind)) expected, got no value)"
            )
        }
        let value = arguments[1]
        switch kind {
        case .bool:
            guard case let .boolean(bool) = value else {
                throw typeError(value, function: function, expected: "boolean")
            }
            return .bool(bool)
        case .int:
            let number = try requiredNumber(value, function: function)
            return .int(number)
        case .float:
            return .float(Float(try requiredNumber(value, function: function)))
        case .string:
            let string = try requiredString(value, function: function)
            guard string.count <= 199 else {
                throw LuaError.runtime(
                    "bad argument #2 to '\(function)' (string exceeds the 199-byte legacy limit)"
                )
            }
            return .string(string)
        case .entity:
            return .entity(index: try entityRegistry.networkIndex(
                from: value,
                function: function
            ))
        case .vector:
            let components = try GMLuaVectorAngle.networkVectorComponents(
                from: value,
                function: function
            )
            return .vector(
                x: Float(components.0),
                y: Float(components.1),
                z: Float(components.2)
            )
        case .angle:
            let components = try GMLuaVectorAngle.networkAngleComponents(
                from: value,
                function: function
            )
            return .angle(
                pitch: Float(components.0),
                yaw: Float(components.1),
                roll: Float(components.2)
            )
        }
    }

    private func requiredGenericSetValue(
        _ arguments: [LuaValue],
        function: String
    ) throws -> GMLuaNetworkedGlobalValue {
        guard arguments.indices.contains(1) else {
            throw LuaError.runtime(
                "bad argument #2 to '\(function)' (networkable value expected, got no value)"
            )
        }
        let value = arguments[1]
        switch value {
        case let .boolean(bool):
            return .bool(bool)
        case let .number(number):
            // Lua 5.1 exposes one number type. Keep its Double payload so the
            // generic API does not silently reduce precision.
            return .int(number)
        case let .string(string):
            guard string.count <= 199 else {
                throw LuaError.runtime(
                    "bad argument #2 to '\(function)' (string exceeds the 199-byte legacy limit)"
                )
            }
            return .string(string)
        case .userdata:
            guard let object = GMLuaTypeSystem.typedObject(from: value) else {
                throw typeError(
                    value,
                    function: function,
                    expected: "networkable value"
                )
            }
            switch object.typeID {
            case GMLuaTypeID.entity:
                return .entity(index: try entityRegistry.networkIndex(
                    from: value,
                    function: function
                ))
            case GMLuaTypeID.vector:
                let components = try GMLuaVectorAngle.networkVectorComponents(
                    from: value,
                    function: function
                )
                return .vector(
                    x: Float(components.0),
                    y: Float(components.1),
                    z: Float(components.2)
                )
            case GMLuaTypeID.angle:
                let components = try GMLuaVectorAngle.networkAngleComponents(
                    from: value,
                    function: function
                )
                return .angle(
                    pitch: Float(components.0),
                    yaw: Float(components.1),
                    roll: Float(components.2)
                )
            default:
                throw typeError(
                    value,
                    function: function,
                    expected: "networkable value"
                )
            }
        default:
            throw typeError(
                value,
                function: function,
                expected: "networkable value"
            )
        }
    }

    private func defaultValue(
        _ arguments: [LuaValue],
        kind: GMLuaNetworkedGlobalKind,
        function: String
    ) throws -> LuaValue {
        guard arguments.indices.contains(1) else {
            switch kind {
            case .bool: return .boolean(false)
            case .int, .float: return .number(0)
            case .string: return .string("")
            case .entity:
                return entityRegistry.entity(at: -1)
            case .vector, .angle:
                throw LuaError.runtime(
                    "bad argument #2 to '\(function)' (\(typeName(for: kind)) expected, got no value)"
                )
            }
        }
        let value = arguments[1]
        switch kind {
        case .bool:
            guard case .boolean = value else {
                throw typeError(value, function: function, expected: "boolean")
            }
        case .int, .float:
            _ = try requiredNumber(value, function: function)
        case .string:
            _ = try requiredString(value, function: function)
        case .entity:
            _ = try entityRegistry.networkIndex(from: value, function: function)
        case .vector:
            _ = try GMLuaVectorAngle.networkVectorComponents(
                from: value,
                function: function
            )
        case .angle:
            _ = try GMLuaVectorAngle.networkAngleComponents(
                from: value,
                function: function
            )
        }
        return value
    }

    private func luaValue(
        from value: GMLuaNetworkedGlobalValue,
        function: String
    ) throws -> LuaValue {
        switch value {
        case let .bool(bool): return .boolean(bool)
        case let .int(int): return .number(int)
        case let .float(float): return .number(Double(float))
        case let .string(string): return .string(string)
        case let .entity(index): return entityRegistry.entity(at: index)
        case let .vector(x, y, z):
            return try GMLuaVectorAngle.makeNetworkVector(
                Double(x),
                Double(y),
                Double(z),
                typeSystem: typeSystem
            )
        case let .angle(pitch, yaw, roll):
            return try GMLuaVectorAngle.makeNetworkAngle(
                Double(pitch),
                Double(yaw),
                Double(roll),
                typeSystem: typeSystem
            )
        }
    }

    private func requiredNumber(
        _ value: LuaValue,
        function: String
    ) throws -> Double {
        switch value {
        case let .number(number): return number
        case let .string(string):
            if let number = Double(string.utf8String) { return number }
            fallthrough
        default:
            throw typeError(value, function: function, expected: "number")
        }
    }

    private func requiredString(
        _ value: LuaValue,
        function: String
    ) throws -> LuaString {
        switch value {
        case let .string(string): return string
        case .number: return LuaString(value.printable)
        default:
            throw typeError(value, function: function, expected: "string")
        }
    }

    private func typeError(
        _ value: LuaValue,
        function: String,
        expected: String
    ) -> LuaError {
        LuaError.runtime(
            "bad argument #2 to '\(function)' (\(expected) expected, got \(value.typeName))"
        )
    }

    private func typeName(for kind: GMLuaNetworkedGlobalKind) -> String {
        switch kind {
        case .bool: return "boolean"
        case .int, .float: return "number"
        case .string: return "string"
        case .entity: return "Entity"
        case .vector: return "Vector"
        case .angle: return "Angle"
        }
    }
}
