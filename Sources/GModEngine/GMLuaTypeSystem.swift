import Foundation
import GModLua

/// Numeric ABI shared by GLua's `TypeID`, `TYPE_*` constants and net type tags.
///
/// This is a namespace rather than a raw-value enum because GLua intentionally
/// exposes both `TYPE_NONE` and `TYPE_INVALID` with the same value.
public enum GMLuaTypeID {
    public static let none = -1
    public static let invalid = -1
    public static let `nil` = 0
    public static let bool = 1
    public static let lightUserdata = 2
    public static let number = 3
    public static let string = 4
    public static let table = 5
    public static let function = 6
    public static let userdata = 7
    public static let thread = 8
    public static let entity = 9
    public static let vector = 10
    public static let angle = 11
    public static let physicsObject = 12
    public static let save = 13
    public static let restore = 14
    public static let damageInfo = 15
    public static let effectData = 16
    public static let moveData = 17
    public static let recipientFilter = 18
    public static let userCommand = 19
    public static let scriptedVehicle = 20
    public static let material = 21
    public static let panel = 22
    public static let particle = 23
    public static let particleEmitter = 24
    public static let texture = 25
    public static let userMessage = 26
    public static let conVar = 27
    public static let mesh = 28
    public static let matrix = 29
    public static let sound = 30
    public static let pixelVisibilityHandle = 31
    public static let dynamicLight = 32
    public static let video = 33
    public static let file = 34
    public static let locomotion = 35
    public static let path = 36
    public static let navigationArea = 37
    public static let soundHandle = 38
    public static let navigationLadder = 39
    public static let particleSystem = 40
    public static let projectedTexture = 41
    public static let physicsCollide = 42
    public static let surfaceInfo = 43
    public static let count = 44

    /// Color remains an ordinary Lua table. 255 is only the special net tag
    /// used by `net.WriteType`; `TypeID(Color(...))` still returns TYPE_TABLE.
    public static let color = 255

    public static let constants: [String: Int] = [
        "TYPE_NONE": none,
        "TYPE_INVALID": invalid,
        "TYPE_NIL": `nil`,
        "TYPE_BOOL": bool,
        "TYPE_LIGHTUSERDATA": lightUserdata,
        "TYPE_NUMBER": number,
        "TYPE_STRING": string,
        "TYPE_TABLE": table,
        "TYPE_FUNCTION": function,
        "TYPE_USERDATA": userdata,
        "TYPE_THREAD": thread,
        "TYPE_ENTITY": entity,
        "TYPE_VECTOR": vector,
        "TYPE_ANGLE": angle,
        "TYPE_PHYSOBJ": physicsObject,
        "TYPE_SAVE": save,
        "TYPE_RESTORE": restore,
        "TYPE_DAMAGEINFO": damageInfo,
        "TYPE_EFFECTDATA": effectData,
        "TYPE_MOVEDATA": moveData,
        "TYPE_RECIPIENTFILTER": recipientFilter,
        "TYPE_USERCMD": userCommand,
        "TYPE_SCRIPTEDVEHICLE": scriptedVehicle,
        "TYPE_MATERIAL": material,
        "TYPE_PANEL": panel,
        "TYPE_PARTICLE": particle,
        "TYPE_PARTICLEEMITTER": particleEmitter,
        "TYPE_TEXTURE": texture,
        "TYPE_USERMSG": userMessage,
        "TYPE_CONVAR": conVar,
        "TYPE_IMESH": mesh,
        "TYPE_MATRIX": matrix,
        "TYPE_SOUND": sound,
        "TYPE_PIXELVISHANDLE": pixelVisibilityHandle,
        "TYPE_DLIGHT": dynamicLight,
        "TYPE_VIDEO": video,
        "TYPE_FILE": file,
        "TYPE_LOCOMOTION": locomotion,
        "TYPE_PATH": path,
        "TYPE_NAVAREA": navigationArea,
        "TYPE_SOUNDHANDLE": soundHandle,
        "TYPE_NAVLADDER": navigationLadder,
        "TYPE_PARTICLESYSTEM": particleSystem,
        "TYPE_PROJECTEDTEXTURE": projectedTexture,
        "TYPE_PHYSCOLLIDE": physicsCollide,
        "TYPE_SURFACEINFO": surfaceInfo,
        "TYPE_COUNT": count,
        "TYPE_COLOR": color
    ]
}

/// Native payload shared by engine-backed GLua userdata.
///
/// The payload keeps type identity separate from Lua-visible tables, preventing
/// `{ MetaName = "Vector", MetaID = TYPE_VECTOR }` from becoming a Vector.
public final class GMLuaTypedObject: @unchecked Sendable {
    public let metaName: String
    public let typeID: Int
    public var isValid: Bool
    public let payload: Any?

    public init(
        metaName: String,
        typeID: Int,
        isValid: Bool = true,
        payload: Any? = nil
    ) {
        self.metaName = metaName
        self.typeID = typeID
        self.isValid = isValid
        self.payload = payload
    }
}

private final class GMLuaMetatableRegistry: @unchecked Sendable {
    var tables: [String: LuaTable] = [:]
    var typeIDs: [String: Int] = [:]
    var nextCustomTypeID = GMLuaTypeID.count

    var referencedValues: [LuaValue] {
        tables.values.map(LuaValue.table)
    }
}

/// Selects whether the installer stops at the native ABI expected before the
/// public GLua utility layer, or also supplies an original behavioral fallback
/// for a standalone embedding which will not load that layer.
public enum GMLuaTypeUtilityLayer: Sendable, Equatable {
    case nativeABIOnly
    case bundledFallback
}

/// Installs GLua's type/metatable ABI without changing the core Lua state until
/// `install(into:)` is explicitly called.
public final class GMLuaTypeSystem: @unchecked Sendable {
    private static let validityHelper = "__gmodlua_type_object_is_valid"
    private static let fallbackGlobals = [
        "TypeID", "isstring", "isnumber", "istable", "isfunction", "isbool",
        "isangle", "isvector", "ismatrix", "ispanel", "isentity", "IsEntity", "IsValid"
    ]

    private static let nativeMetatypes: [(name: String, typeID: Int)] = [
        ("Entity", GMLuaTypeID.entity),
        ("Player", GMLuaTypeID.entity),
        ("Weapon", GMLuaTypeID.entity),
        ("Vehicle", GMLuaTypeID.entity),
        ("Vector", GMLuaTypeID.vector),
        ("Angle", GMLuaTypeID.angle),
        ("PhysObj", GMLuaTypeID.physicsObject),
        ("ISave", GMLuaTypeID.save),
        ("IRestore", GMLuaTypeID.restore),
        ("CTakeDamageInfo", GMLuaTypeID.damageInfo),
        ("CEffectData", GMLuaTypeID.effectData),
        ("CMoveData", GMLuaTypeID.moveData),
        ("CRecipientFilter", GMLuaTypeID.recipientFilter),
        ("CUserCmd", GMLuaTypeID.userCommand),
        ("ScriptedVehicle", GMLuaTypeID.scriptedVehicle),
        ("IMaterial", GMLuaTypeID.material),
        ("Panel", GMLuaTypeID.panel),
        ("CLuaParticle", GMLuaTypeID.particle),
        ("CLuaEmitter", GMLuaTypeID.particleEmitter),
        ("ITexture", GMLuaTypeID.texture),
        ("bf_read", GMLuaTypeID.userMessage),
        ("ConVar", GMLuaTypeID.conVar),
        ("IMesh", GMLuaTypeID.mesh),
        ("VMatrix", GMLuaTypeID.matrix),
        ("CSoundPatch", GMLuaTypeID.sound),
        ("pixelvis_handle_t", GMLuaTypeID.pixelVisibilityHandle),
        ("dlight_t", GMLuaTypeID.dynamicLight),
        ("IVideoWriter", GMLuaTypeID.video),
        ("File", GMLuaTypeID.file),
        ("CLuaLocomotion", GMLuaTypeID.locomotion),
        ("PathFollower", GMLuaTypeID.path),
        ("CNavArea", GMLuaTypeID.navigationArea),
        ("IGModAudioChannel", GMLuaTypeID.soundHandle),
        ("CNavLadder", GMLuaTypeID.navigationLadder),
        ("CNewParticleEffect", GMLuaTypeID.particleSystem),
        ("ProjectedTexture", GMLuaTypeID.projectedTexture),
        ("PhysCollide", GMLuaTypeID.physicsCollide),
        ("SurfaceInfo", GMLuaTypeID.surfaceInfo)
    ]

    private let state: LuaState
    private let registry: GMLuaMetatableRegistry
    private let coreType: LuaValue
    private var fallbackUtilitiesInstalled = false

    private init(state: LuaState, registry: GMLuaMetatableRegistry, coreType: LuaValue) {
        self.state = state
        self.registry = registry
        self.coreType = coreType
    }

    /// Installs `TYPE_*`, metatable registry, native userdata identity and a
    /// canonical invalid `NULL` Entity.
    ///
    /// The default deliberately leaves core `type` untouched: the real GMod
    /// `includes/util.lua` captures it as `C_type` before defining GLua's public
    /// wrapper. Use `.bundledFallback` only when that official file will not be
    /// loaded by the embedding.
    @discardableResult
    public static func install(
        into state: LuaState,
        utilityLayer: GMLuaTypeUtilityLayer = .nativeABIOnly
    ) throws -> GMLuaTypeSystem {
        let registry = GMLuaMetatableRegistry()
        let system = GMLuaTypeSystem(
            state: state,
            registry: registry,
            coreType: state.getGlobal("type")
        )

        for (name, value) in GMLuaTypeID.constants {
            state.setGlobal(name, value: .number(Double(value)))
        }

        for descriptor in nativeMetatypes {
            let metatable = LuaTable()
            try setField(.string(LuaString(descriptor.name)), named: "MetaName", in: metatable, state: state)
            try setField(.number(Double(descriptor.typeID)), named: "MetaID", in: metatable, state: state)
            try setField(.table(metatable), named: "__index", in: metatable, state: state)
            registry.tables[descriptor.name] = metatable
            registry.typeIDs[descriptor.name] = descriptor.typeID
        }

        guard let entityMetatable = registry.tables["Entity"] else {
            throw LuaError.runtime("GLua Entity metatable was not installed")
        }
        for subtype in ["Player", "Weapon", "Vehicle"] {
            guard let metatable = registry.tables[subtype] else { continue }
            try setField(.table(entityMetatable), named: "MetaBaseClass", in: metatable, state: state)
        }

        let findMetatable = LuaValue.nativeFunction(
            LuaNativeFunctionBox(
                { arguments in
                    let name = try requiredString(arguments, index: 0, functionName: "FindMetaTable")
                    return [registry.tables[name].map(LuaValue.table) ?? .nilValue]
                },
                debugName: "FindMetaTable",
                gcReferences: { registry.referencedValues }
            )
        )
        state.setGlobal("FindMetaTable", value: findMetatable)

        let registerMetatable = LuaValue.nativeFunction(
            LuaNativeFunctionBox(
                { [unowned state] arguments in
                    let name = try requiredString(arguments, index: 0, functionName: "RegisterMetaTable")
                    guard arguments.indices.contains(1) else {
                        throw LuaError.runtime(
                            "bad argument #2 to 'RegisterMetaTable' (table expected, got no value)"
                        )
                    }
                    guard case let .table(metatable) = arguments[1] else {
                        throw LuaError.runtime(
                            "bad argument #2 to 'RegisterMetaTable' " +
                            "(table expected, got \(arguments[1].typeName))"
                        )
                    }
                    guard registry.tables[name] == nil else {
                        throw LuaError.runtime("metatable '\(name)' is already registered")
                    }

                    guard registry.nextCustomTypeID < GMLuaTypeID.color else {
                        throw LuaError.runtime("no free GLua metatable type IDs")
                    }
                    let customTypeID = registry.nextCustomTypeID
                    registry.nextCustomTypeID += 1

                    // CLuaInterface::RegisterMetaTable allocates custom IDs
                    // from TYPE_COUNT upward. Tables using these metatables
                    // still remain TYPE_TABLE, matching Color's ABI.
                    try setField(.string(LuaString(name)), named: "MetaName", in: metatable, state: state)
                    try setField(
                        .number(Double(customTypeID)),
                        named: "MetaID",
                        in: metatable,
                        state: state
                    )
                    registry.tables[name] = metatable
                    registry.typeIDs[name] = customTypeID
                    return []
                },
                debugName: "RegisterMetaTable",
                gcReferences: { registry.referencedValues }
            )
        )
        state.setGlobal("RegisterMetaTable", value: registerMetatable)

        state.register(validityHelper) { arguments in
            guard let first = arguments.first,
                  case let .userdata(userdata) = first,
                  let object = userdata.payload as? GMLuaTypedObject else {
                return [.boolean(false)]
            }
            return [.boolean(object.isValid)]
        }
        defer { state.setGlobal(validityHelper, value: .nilValue) }

        try state.execute(
            #"""
            local nativeIsValid = __gmodlua_type_object_is_valid
            local validityMetatables = { "Entity", "Player", "Weapon", "Vehicle", "Panel", "PhysObj" }
            for _, name in ipairs(validityMetatables) do
                local valueMetatable = FindMetaTable(name)
                if valueMetatable then valueMetatable.IsValid = nativeIsValid end
            end
            """#,
            sourceName: "=[GModLua type system]"
        )

        state.setGlobal("NULL", value: try system.makeObject(metaName: "Entity", isValid: false))
        if utilityLayer == .bundledFallback {
            try system.installFallbackUtilities()
        }
        return system
    }

    /// Installs an original behavioral fallback compatible with GLua's public
    /// type predicates for standalone runners that will not load the official
    /// utility layer. The implementation is native Swift except for a tiny
    /// generic method-dispatch helper used by `IsValid`.
    public func installFallbackUtilities() throws {
        let registry = registry

        func registeredDescriptor(for value: LuaValue) -> (name: String, typeID: Int)? {
            guard case let .userdata(userdata) = value,
                  let metatable = userdata.metatable else { return nil }
            for (name, registered) in registry.tables where registered === metatable {
                guard let typeID = registry.typeIDs[name] else { continue }
                return (name, typeID)
            }
            return nil
        }

        func publicTypeName(of value: LuaValue) -> String {
            guard case .userdata = value else { return value.typeName }
            return registeredDescriptor(for: value)?.name ?? "UserData"
        }

        func publicTypeID(of value: LuaValue) -> Int {
            switch value {
            case .nilValue: return GMLuaTypeID.nil
            case .boolean: return GMLuaTypeID.bool
            case .number: return GMLuaTypeID.number
            case .string: return GMLuaTypeID.string
            case .table: return GMLuaTypeID.table
            case .luaFunction, .nativeFunction: return GMLuaTypeID.function
            case .thread: return GMLuaTypeID.thread
            case .userdata:
                return registeredDescriptor(for: value)?.typeID ?? GMLuaTypeID.userdata
            }
        }

        state.register("type") { arguments in
            let value = arguments.first ?? .nilValue
            return [.string(LuaString(publicTypeName(of: value)))]
        }
        state.register("TypeID") { arguments in
            [.number(Double(publicTypeID(of: arguments.first ?? .nilValue)))]
        }
        state.register("isstring") { [.boolean(($0.first ?? .nilValue).typeName == "string")] }
        state.register("isnumber") { [.boolean(($0.first ?? .nilValue).typeName == "number")] }
        state.register("istable") { [.boolean(($0.first ?? .nilValue).typeName == "table")] }
        state.register("isfunction") { [.boolean(($0.first ?? .nilValue).typeName == "function")] }
        state.register("isbool") { arguments in
            guard let first = arguments.first, case .boolean = first else {
                return [.boolean(false)]
            }
            return [.boolean(true)]
        }
        state.register("isangle") {
            [.boolean(publicTypeName(of: $0.first ?? .nilValue) == "Angle")]
        }
        state.register("isvector") {
            [.boolean(publicTypeName(of: $0.first ?? .nilValue) == "Vector")]
        }
        state.register("ismatrix") {
            [.boolean(publicTypeName(of: $0.first ?? .nilValue) == "VMatrix")]
        }
        state.register("ispanel") {
            [.boolean(publicTypeName(of: $0.first ?? .nilValue) == "Panel")]
        }

        let entityPredicate = LuaValue.nativeFunction(
            LuaNativeFunctionBox(
                { arguments in
                    let value = arguments.first ?? .nilValue
                    return [
                        .boolean(
                            registeredDescriptor(for: value)?.typeID == GMLuaTypeID.entity
                        )
                    ]
                },
                debugName: "isentity",
                gcReferences: { registry.referencedValues }
            )
        )
        state.setGlobal("isentity", value: entityPredicate)
        state.setGlobal("IsEntity", value: entityPredicate)

        // This is an original minimal dispatcher, not copied game source. A
        // Lua closure is necessary so table/userdata __index and callable
        // metamethods keep the interpreter's ordinary error behavior.
        try state.execute(
            """
            function IsValid(candidate)
                if candidate == nil then return false end
                local validator = candidate.IsValid
                if validator == nil then return false end
                return validator(candidate)
            end
            """,
            sourceName: "=[GModLua standalone validity fallback]"
        )
        fallbackUtilitiesInstalled = true
    }

    /// Restores the pristine Lua `type` and removes bundled utility functions
    /// before executing the real `lua/includes/util.lua`. This prevents that
    /// file's `local C_type = type` from capturing a GLua wrapper.
    public func prepareForOfficialUtilityLoad() {
        guard fallbackUtilitiesInstalled else { return }
        state.setGlobal("type", value: coreType)
        for name in Self.fallbackGlobals {
            state.setGlobal(name, value: .nilValue)
        }
        fallbackUtilitiesInstalled = false
    }

    /// Creates an engine-backed userdata whose type comes from a registered
    /// metatable. Unknown names fail instead of accepting a forged Lua table.
    public func makeObject(
        metaName: String,
        isValid: Bool = true,
        payload: Any? = nil
    ) throws -> LuaValue {
        guard let metatable = registry.tables[metaName],
              let typeID = registry.typeIDs[metaName] else {
            throw LuaError.runtime("unknown GLua metatable '\(metaName)'")
        }
        let object = GMLuaTypedObject(
            metaName: metaName,
            typeID: typeID,
            isValid: isValid,
            payload: payload
        )
        let userdata = LuaUserdata(payload: object)
        userdata.metatable = metatable
        return .userdata(userdata)
    }

    public func metatable(named name: String) -> LuaTable? {
        registry.tables[name]
    }

    public static func typedObject(from value: LuaValue) -> GMLuaTypedObject? {
        guard case let .userdata(userdata) = value else { return nil }
        return userdata.payload as? GMLuaTypedObject
    }

    private static func setField(
        _ value: LuaValue,
        named name: String,
        in table: LuaTable,
        state: LuaState
    ) throws {
        // The public engine boundary deliberately exposes raw table writes but
        // not GModLua's internal key representation.
        try state.setRawTableValue(value, for: .string(LuaString(name)), in: table)
    }

    private static func requiredString(
        _ arguments: [LuaValue],
        index: Int,
        functionName: String
    ) throws -> String {
        guard arguments.indices.contains(index) else {
            throw LuaError.runtime(
                "bad argument #\(index + 1) to '\(functionName)' (string expected, got no value)"
            )
        }
        switch arguments[index] {
        case let .string(value):
            return value.utf8String
        case let .number(value):
            // ILuaBase::CheckString follows luaL_checkstring and accepts a
            // number through Lua's ordinary number-to-string coercion.
            return LuaValue.number(value).printable
        default:
            throw LuaError.runtime(
                "bad argument #\(index + 1) to '\(functionName)' " +
                "(string expected, got \(arguments[index].typeName))"
            )
        }
    }
}
