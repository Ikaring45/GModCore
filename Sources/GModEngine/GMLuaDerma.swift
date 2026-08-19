import Foundation
import GModLua

/// State-local registry for Derma control metadata and skin selection.
///
/// Control construction remains VGUI's responsibility. This layer implements
/// Derma's documented registry and skin dispatch semantics without claiming a
/// platform UI, layout engine, input bridge, or drawing backend.
public final class GMLuaDermaRegistry: @unchecked Sendable {
    fileprivate let state: LuaState
    private let vguiRegistry: GMLuaVGUIRegistry
    fileprivate let controls = LuaTable()
    fileprivate let skins = LuaTable()
    fileprivate let skinInheritanceMetatable = LuaTable()
    fileprivate var defaultSkin = LuaTable()
    fileprivate var skinChangeIndex = 1
    private var semanticIndex: LuaValue = .nilValue
    private var semanticSet: LuaValue = .nilValue

    fileprivate init(state: LuaState, vguiRegistry: GMLuaVGUIRegistry) {
        self.state = state
        self.vguiRegistry = vguiRegistry
    }

    public var registeredControlCount: Int {
        (try? state.rawTablePairs(in: controls).count) ?? 0
    }

    public var registeredSkinCount: Int {
        (try? state.rawTablePairs(in: skins).count) ?? 0
    }

    public var currentSkinChangeIndex: Int { skinChangeIndex }

    /// Remains false until Panel instances have a UIKit/Metal view bridge.
    public var hasPlatformViewBacking: Bool { vguiRegistry.hasPlatformViewBacking }

    fileprivate var references: [LuaValue] {
        [
            .table(controls), .table(skins), .table(defaultSkin),
            .table(skinInheritanceMetatable), semanticIndex, semanticSet
        ]
    }

    fileprivate func setHelpers(index: LuaValue, setter: LuaValue) {
        semanticIndex = index
        semanticSet = setter
    }

    fileprivate func defineControl(
        name: String,
        description: String,
        control: LuaTable,
        baseName: String
    ) throws -> LuaValue {
        let wasRegistered = !isNil(
            try state.rawTableValue(for: .string(LuaString(name)), in: controls)
        )
        let metadata = LuaTable()
        try set(.string(LuaString(name)), "ClassName", metadata)
        try set(.string(LuaString(description)), "Description", metadata)
        try set(.string(LuaString(baseName)), "BaseClass", metadata)
        try state.setTableValue(.table(metadata), for: .string("Derma"), in: control)

        guard case let .table(vgui) = state.getGlobal("vgui") else {
            throw LuaError.runtime("Derma requires the vgui library")
        }
        let register = try state.rawTableValue(for: .string("Register"), in: vgui)
        guard isCallable(register) else {
            throw LuaError.runtime("Derma requires vgui.Register")
        }
        _ = try state.call(
            register,
            arguments: [
                .string(LuaString(name)), .table(control), .string(LuaString(baseName))
            ]
        )

        try state.setRawTableValue(.table(metadata), for: .string(LuaString(name)), in: controls)
        state.setGlobal(name, value: .table(control))
        if wasRegistered { try reloadExistingPanels(className: name, control: control) }
        return .table(control)
    }

    fileprivate func defineSkin(
        name: String,
        description: String,
        skin: LuaTable
    ) throws {
        try state.setTableValue(.string(LuaString(name)), for: .string("Name"), in: skin)
        try state.setTableValue(
            .string(LuaString(description)),
            for: .string("Description"),
            in: skin
        )
        if case .nilValue = try state.rawTableValue(for: .string("Base"), in: skin) {
            try state.setTableValue(.string("Default"), for: .string("Base"), in: skin)
        }

        if name == "Default" {
            defaultSkin = skin
        } else {
            skin.metatable = skinInheritanceMetatable
        }
        try state.setRawTableValue(.table(skin), for: .string(LuaString(name)), in: skins)
        refreshSkins()
    }

    fileprivate func namedSkin(_ name: String) throws -> LuaValue {
        try state.rawTableValue(for: .string(LuaString(name)), in: skins)
    }

    fileprivate func selectedDefaultSkin() throws -> LuaValue {
        if case let .table(gamemode) = state.getGlobal("gamemode") {
            let call = try state.rawTableValue(for: .string("Call"), in: gamemode)
            if isCallable(call),
               case let .string(name) = try state.call(
                    call,
                    arguments: [.string("ForceDermaSkin")]
               ).first ?? .nilValue {
                let selected = try namedSkin(name.utf8String)
                if !isNil(selected) { return selected }
            }
        }
        return .table(defaultSkin)
    }

    fileprivate func skinTableCopy() throws -> LuaTable {
        let copy = LuaTable()
        for (key, value) in try state.rawTablePairs(in: skins) {
            try state.setRawTableValue(value, for: key, in: copy)
        }
        return copy
    }

    fileprivate func refreshSkins() {
        skinChangeIndex += 1
    }

    fileprivate func skinHook(_ arguments: [LuaValue]) throws -> [LuaValue] {
        let hookType = try requiredString(arguments, index: 0, function: "SkinHook")
        let typeName = try requiredString(arguments, index: 1, function: "SkinHook")
        guard arguments.indices.contains(2) else { return [] }
        let panel = arguments[2]
        let getSkin = try index(panel, key: .string("GetSkin"))
        guard isCallable(getSkin) else { return [] }
        let skin = try state.call(getSkin, arguments: [panel]).first ?? .nilValue
        if isNil(skin) { return [] }
        let callback = try index(
            skin,
            key: .string(LuaString(hookType + typeName))
        )
        guard isCallable(callback) else { return [] }
        var callbackArguments = [skin, panel]
        if arguments.indices.contains(3) { callbackArguments.append(arguments[3]) }
        if arguments.indices.contains(4) { callbackArguments.append(arguments[4]) }
        return try state.call(callback, arguments: callbackArguments)
    }

    fileprivate func skinProperty(
        arguments: [LuaValue],
        tableName: String?
    ) throws -> LuaValue {
        let name = try requiredString(arguments, index: 0, function: tableName == nil ? "Color" : "SkinTexture")
        guard arguments.indices.contains(1) else { return arguments.indices.contains(2) ? arguments[2] : .nilValue }
        let panel = arguments[1]
        let fallback = arguments.indices.contains(2) ? arguments[2] : .nilValue
        let getSkin = try index(panel, key: .string("GetSkin"))
        guard isCallable(getSkin) else { return fallback }
        var source = try state.call(getSkin, arguments: [panel]).first ?? .nilValue
        if isNil(source) { return fallback }
        if let tableName {
            source = try index(source, key: .string(LuaString(tableName)))
            if isNil(source) { return fallback }
        }
        let value = try index(source, key: .string(LuaString(name)))
        return isNil(value) ? fallback : value
    }

    fileprivate func installHook(
        control: LuaTable,
        functionName: String,
        hookName: String,
        typeName: String
    ) throws {
        let callback = dermaFunction(name: "Derma_Hook:\(functionName)", registry: self) {
            [weak self] arguments in
            guard let self, let panel = arguments.first else { return [] }
            return try self.skinHook(
                [.string(LuaString(hookName)), .string(LuaString(typeName)), panel]
                    + Array(arguments.dropFirst())
            )
        }
        try state.setTableValue(
            callback,
            for: .string(LuaString(functionName)),
            in: control
        )
    }

    fileprivate func installConVarMethods(control: LuaTable) throws {
        let setConVar = dermaFunction(name: "Panel:SetConVar", registry: self) {
            [weak self] arguments in
            guard let self, let panel = arguments.first else { return [] }
            let name = try requiredString(arguments, index: 1, function: "SetConVar")
            try self.assign(panel, key: .string("m_strConVar"), value: .string(LuaString(name)))
            return []
        }
        let changed = dermaFunction(name: "Panel:ConVarChanged", registry: self) {
            [weak self] arguments in
            guard let self, let panel = arguments.first else { return [] }
            let conVar = try self.index(panel, key: .string("m_strConVar"))
            guard case let .string(name) = conVar, name.count >= 2 else { return [] }
            let runner = self.state.getGlobal("RunConsoleCommand")
            guard isCallable(runner) else { return [] }
            let newValue = arguments.indices.contains(1) ? arguments[1].printable : "nil"
            _ = try self.state.call(
                runner,
                arguments: [.string(name), .string(LuaString(newValue))]
            )
            return []
        }
        let stringThink = conVarThinkFunction(
            registry: self,
            getterName: "GetConVarString",
            cachedField: "m_strConVarValue"
        )
        let numberThink = conVarThinkFunction(
            registry: self,
            getterName: "GetConVarNumber",
            cachedField: "m_strConVarValue"
        )
        for (name, value) in [
            ("SetConVar", setConVar), ("ConVarChanged", changed),
            ("ConVarStringThink", stringThink), ("ConVarNumberThink", numberThink)
        ] {
            try state.setTableValue(value, for: .string(LuaString(name)), in: control)
        }
    }

    private func reloadExistingPanels(className: String, control: LuaTable) throws {
        guard case let .table(vgui) = state.getGlobal("vgui") else { return }
        let getAll = try state.rawTableValue(for: .string("GetAll"), in: vgui)
        guard isCallable(getAll),
              case let .table(all) = try state.call(getAll).first ?? .nilValue else { return }

        for (_, panel) in try state.rawTablePairs(in: all) {
            guard case let .string(existingClass) = try index(panel, key: .string("ClassName")),
                  existingClass.utf8String == className,
                  (try index(panel, key: .string("AllowAutoRefresh"))).isTruthy else { continue }
            try callOptionalMethod(on: panel, named: "PreAutoRefresh")
            for (key, value) in try state.rawTablePairs(in: control) where isCallable(value) {
                try assign(panel, key: key, value: value)
            }
            try callOptionalMethod(on: panel, named: "PostAutoRefresh")
        }
    }

    private func callOptionalMethod(on target: LuaValue, named name: String) throws {
        let method = try index(target, key: .string(LuaString(name)))
        if isCallable(method) { _ = try state.call(method, arguments: [target]) }
    }

    fileprivate func index(_ target: LuaValue, key: LuaValue) throws -> LuaValue {
        try state.call(semanticIndex, arguments: [target, key]).first ?? .nilValue
    }

    fileprivate func assign(_ target: LuaValue, key: LuaValue, value: LuaValue) throws {
        _ = try state.call(semanticSet, arguments: [target, key, value])
    }

    private func set(_ value: LuaValue, _ name: String, _ table: LuaTable) throws {
        try state.setRawTableValue(value, for: .string(LuaString(name)), in: table)
    }
}

public enum GMLuaDerma {
    @discardableResult
    public static func install(
        into state: LuaState,
        vguiRegistry: GMLuaVGUIRegistry
    ) throws -> GMLuaDermaRegistry {
        let registry = GMLuaDermaRegistry(state: state, vguiRegistry: vguiRegistry)
        let helpers = try state.executeReturningValues(
            """
            return function(target, key) return target[key] end,
                   function(target, key, value) target[key] = value end
            """,
            sourceName: "=[GModLua Derma access helpers]"
        )
        guard helpers.count == 2 else { throw LuaError.runtime("could not install Derma helpers") }
        registry.setHelpers(index: helpers[0], setter: helpers[1])

        let skinIndex = dermaFunction(name: "DermaSkin.__index", registry: registry) {
            [weak registry] arguments in
            guard let registry, arguments.indices.contains(1) else { return [.nilValue] }
            return [try registry.state.rawTableValue(for: arguments[1], in: registry.defaultSkin)]
        }
        try state.setRawTableValue(
            skinIndex,
            for: .string("__index"),
            in: registry.skinInheritanceMetatable
        )

        let derma = LuaTable()
        try put(.table(registry.controls), named: "Controls", in: derma, state: state)
        try put(.table(registry.skins), named: "SkinList", in: derma, state: state)
        try put(
            dermaFunction(name: "derma.DefineControl", registry: registry) { arguments in
                let name = try requiredString(arguments, index: 0, function: "DefineControl")
                let description = try requiredString(arguments, index: 1, function: "DefineControl")
                guard arguments.indices.contains(2), case let .table(control) = arguments[2] else {
                    throw LuaError.runtime("bad argument #3 to 'DefineControl' (table expected)")
                }
                let baseName = try optionalString(
                    arguments,
                    index: 3,
                    fallback: "Panel",
                    function: "DefineControl"
                )
                return [try registry.defineControl(
                    name: name,
                    description: description,
                    control: control,
                    baseName: baseName
                )]
            },
            named: "DefineControl",
            in: derma,
            state: state
        )
        try put(
            dermaFunction(name: "derma.GetControlList", registry: registry) { _ in
                [.table(registry.controls)]
            },
            named: "GetControlList",
            in: derma,
            state: state
        )
        try put(
            dermaFunction(name: "derma.DefineSkin", registry: registry) { arguments in
                let name = try requiredString(arguments, index: 0, function: "DefineSkin")
                let description = try requiredString(arguments, index: 1, function: "DefineSkin")
                guard arguments.indices.contains(2), case let .table(skin) = arguments[2] else {
                    throw LuaError.runtime("bad argument #3 to 'DefineSkin' (table expected)")
                }
                try registry.defineSkin(name: name, description: description, skin: skin)
                return []
            },
            named: "DefineSkin",
            in: derma,
            state: state
        )
        try put(
            dermaFunction(name: "derma.GetDefaultSkin", registry: registry) { _ in
                [try registry.selectedDefaultSkin()]
            },
            named: "GetDefaultSkin",
            in: derma,
            state: state
        )
        try put(
            dermaFunction(name: "derma.GetNamedSkin", registry: registry) { arguments in
                let name = try requiredString(arguments, index: 0, function: "GetNamedSkin")
                return [try registry.namedSkin(name)]
            },
            named: "GetNamedSkin",
            in: derma,
            state: state
        )
        try put(
            dermaFunction(name: "derma.GetSkinTable", registry: registry) { _ in
                [.table(try registry.skinTableCopy())]
            },
            named: "GetSkinTable",
            in: derma,
            state: state
        )
        try put(
            dermaFunction(name: "derma.RefreshSkins", registry: registry) { _ in
                registry.refreshSkins()
                return []
            },
            named: "RefreshSkins",
            in: derma,
            state: state
        )
        try put(
            dermaFunction(name: "derma.SkinChangeIndex", registry: registry) { _ in
                [.number(Double(registry.skinChangeIndex))]
            },
            named: "SkinChangeIndex",
            in: derma,
            state: state
        )
        try put(
            dermaFunction(name: "derma.SkinHook", registry: registry) {
                try registry.skinHook($0)
            },
            named: "SkinHook",
            in: derma,
            state: state
        )
        try put(
            dermaFunction(name: "derma.SkinTexture", registry: registry) {
                [try registry.skinProperty(arguments: $0, tableName: "tex")]
            },
            named: "SkinTexture",
            in: derma,
            state: state
        )
        try put(
            dermaFunction(name: "derma.Color", registry: registry) {
                [try registry.skinProperty(arguments: $0, tableName: nil)]
            },
            named: "Color",
            in: derma,
            state: state
        )
        state.setGlobal("derma", value: .table(derma))

        state.setGlobal(
            "Derma_Hook",
            value: dermaFunction(name: "Derma_Hook", registry: registry) { arguments in
                guard arguments.indices.contains(0), case let .table(control) = arguments[0] else {
                    throw LuaError.runtime("bad argument #1 to 'Derma_Hook' (table expected)")
                }
                let functionName = try requiredString(arguments, index: 1, function: "Derma_Hook")
                let hookName = try requiredString(arguments, index: 2, function: "Derma_Hook")
                let typeName = try requiredString(arguments, index: 3, function: "Derma_Hook")
                try registry.installHook(
                    control: control,
                    functionName: functionName,
                    hookName: hookName,
                    typeName: typeName
                )
                return []
            }
        )
        state.setGlobal(
            "Derma_Install_Convar_Functions",
            value: dermaFunction(
                name: "Derma_Install_Convar_Functions",
                registry: registry
            ) { arguments in
                guard let first = arguments.first, case let .table(control) = first else {
                    throw LuaError.runtime(
                        "bad argument #1 to 'Derma_Install_Convar_Functions' (table expected)"
                    )
                }
                try registry.installConVarMethods(control: control)
                return []
            }
        )
        return registry
    }
}

private func conVarThinkFunction(
    registry: GMLuaDermaRegistry,
    getterName: String,
    cachedField: String
) -> LuaValue {
    dermaFunction(name: "Panel:\(getterName)Think", registry: registry) {
        [weak registry] arguments in
        guard let registry, let panel = arguments.first else { return [] }
        let conVar = try registry.index(panel, key: .string("m_strConVar"))
        guard case let .string(name) = conVar, name.count >= 2 else { return [] }
        let getter = registry.state.getGlobal(getterName)
        guard isCallable(getter) else { return [] }
        let value = try registry.state.call(getter, arguments: [.string(name)]).first ?? .nilValue
        if getterName == "GetConVarNumber", case let .number(number) = value, number.isNaN {
            return []
        }
        let cached = try registry.index(panel, key: .string(LuaString(cachedField)))
        if luaScalarEqual(cached, value) { return [] }
        try registry.assign(panel, key: .string(LuaString(cachedField)), value: value)
        let setter = try registry.index(panel, key: .string("SetValue"))
        if isCallable(setter) { _ = try registry.state.call(setter, arguments: [panel, value]) }
        return []
    }
}

private func dermaFunction(
    name: String,
    registry: GMLuaDermaRegistry,
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

private func put(
    _ value: LuaValue,
    named name: String,
    in table: LuaTable,
    state: LuaState
) throws {
    try state.setRawTableValue(value, for: .string(LuaString(name)), in: table)
}

private func requiredString(
    _ arguments: [LuaValue],
    index: Int,
    function: String
) throws -> String {
    guard arguments.indices.contains(index), case let .string(value) = arguments[index] else {
        throw LuaError.runtime(
            "bad argument #\(index + 1) to '\(function)' (string expected)"
        )
    }
    return value.utf8String
}

private func optionalString(
    _ arguments: [LuaValue],
    index: Int,
    fallback: String,
    function: String
) throws -> String {
    guard arguments.indices.contains(index), !isNil(arguments[index]) else { return fallback }
    return try requiredString(arguments, index: index, function: function)
}

private func isCallable(_ value: LuaValue) -> Bool {
    if case .luaFunction = value { return true }
    if case .nativeFunction = value { return true }
    return false
}

private func isNil(_ value: LuaValue) -> Bool {
    if case .nilValue = value { return true }
    return false
}

private func luaScalarEqual(_ lhs: LuaValue, _ rhs: LuaValue) -> Bool {
    switch (lhs, rhs) {
    case (.nilValue, .nilValue): return true
    case let (.boolean(a), .boolean(b)): return a == b
    case let (.number(a), .number(b)): return a == b
    case let (.string(a), .string(b)): return a == b
    case let (.table(a), .table(b)): return a === b
    case let (.userdata(a), .userdata(b)): return a === b
    case let (.luaFunction(a), .luaFunction(b)): return a === b
    case let (.nativeFunction(a), .nativeFunction(b)): return a === b
    case let (.thread(a), .thread(b)): return a === b
    default: return false
    }
}
