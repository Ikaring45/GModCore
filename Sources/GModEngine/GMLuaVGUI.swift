import Foundation
import GModLua

/// Value-only foreground color retained by the logical VGUI host.
///
/// Components intentionally remain Lua numbers. The public GLua contract does
/// not define out-of-range conversion, so this layer does not invent an 8-bit
/// clamp that could disagree with the native engine.
public struct GMLuaPanelColorSnapshot: Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
}

/// Inspectable logical state for an engine text panel.
///
/// This is not a renderer object. Font names are kept independently from the
/// current `surface` font, matching VGUI's per-panel font selection.
public struct GMLuaTextPanelStateSnapshot: Equatable, Sendable {
    public let panelIdentifier: Int
    public let engineClassName: String
    public let requestedClassName: String
    public let text: LuaString
    public let fontName: LuaString
    public let foregroundColor: GMLuaPanelColorSnapshot?
    public let contentAlignment: Int

    public init(
        panelIdentifier: Int,
        engineClassName: String,
        requestedClassName: String,
        text: LuaString,
        fontName: LuaString,
        foregroundColor: GMLuaPanelColorSnapshot?,
        contentAlignment: Int
    ) {
        self.panelIdentifier = panelIdentifier
        self.engineClassName = engineClassName
        self.requestedClassName = requestedClassName
        self.text = text
        self.fontName = fontName
        self.foregroundColor = foregroundColor
        self.contentAlignment = contentAlignment
    }
}

private final class GMLuaPanelValue: @unchecked Sendable {
    let identifier: Int
    let engineClassName: String
    let instanceTable = LuaTable()
    var requestedClassName: String
    var name: String
    var parentIdentifier: Int?
    var isParentedToHUD = false
    var x = 0.0
    var y = 0.0
    var width = 0.0
    var height = 0.0
    var alpha = 255.0
    var isVisible = true
    var mouseInputEnabled = true
    var keyboardInputEnabled = true
    var paintBackgroundEnabled = true
    var paintBorderEnabled = true
    var zPosition = 0.0
    var isLayoutInvalidated = false
    var isPerformingLayout = false
    var text = LuaString(bytes: [])
    var fontName = LuaString("Default")
    var foregroundColor: GMLuaPanelColorSnapshot?
    var contentAlignment = 5

    init(
        identifier: Int,
        engineClassName: String,
        requestedClassName: String,
        name: String,
        parentIdentifier: Int?
    ) {
        self.identifier = identifier
        self.engineClassName = engineClassName
        self.requestedClassName = requestedClassName
        self.name = name
        self.parentIdentifier = parentIdentifier
    }
}

/// State-local registry for native Panel identity and the Lua VGUI factory.
///
/// This is deliberately a logical VGUI layer. It creates real `Panel` typed
/// userdata and preserves the scripted-panel inheritance contract, but does
/// not claim that a platform view or a Metal drawable already exists.
public final class GMLuaVGUIRegistry: @unchecked Sendable {
    private static let engineClassNames: Set<String> = [
        "AchievementIcon", "AvatarImage", "CheckButton", "EditablePanel",
        "Frame", "HTML", "Label", "ModelImage", "Panel", "RadioButton",
        "RichText", "TGAImage", "TextEntry"
    ]

    private let state: LuaState
    private let typeSystem: GMLuaTypeSystem
    private let panelMetatable: LuaTable
    private let lock = NSLock()
    private var controls: [String: LuaTable] = [:]
    private var panels: [Int: LuaValue] = [:]
    private var nextPanelIdentifier = 1
    private var semanticIndex: LuaValue = .nilValue
    private var completedLayoutPasses: UInt64 = 0

    fileprivate init(
        state: LuaState,
        typeSystem: GMLuaTypeSystem,
        panelMetatable: LuaTable
    ) {
        self.state = state
        self.typeSystem = typeSystem
        self.panelMetatable = panelMetatable
    }

    public var registeredControlCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return controls.count
    }

    public var livePanelCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return panels.values.reduce(into: 0) { count, value in
            if GMLuaTypeSystem.typedObject(from: value)?.isValid == true { count += 1 }
        }
    }

    /// Number of live logical panels waiting for the host's next VGUI frame
    /// boundary. This does not imply that UIKit or renderer layout exists.
    public var pendingLayoutCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return panels.values.reduce(into: 0) { count, value in
            guard let descriptor = panelDescriptor(from: value),
                  descriptor.isLayoutInvalidated,
                  GMLuaTypeSystem.typedObject(from: value)?.isValid == true else { return }
            count += 1
        }
    }

    /// Successful logical `PerformLayout` passes dispatched by this registry.
    /// Platform view layout remains outside this pure Swift compatibility layer.
    public var completedLayoutPassCount: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return completedLayoutPasses
    }

    /// Stable value snapshots for live Label/TextEntry/RichText controls.
    public var textPanelStateSnapshots: [GMLuaTextPanelStateSnapshot] {
        lock.lock()
        defer { lock.unlock() }
        return panels.keys.sorted().compactMap { identifier in
            guard let value = panels[identifier],
                  let descriptor = panelDescriptor(from: value),
                  isTextEngineClass(descriptor.engineClassName),
                  GMLuaTypeSystem.typedObject(from: value)?.isValid == true else { return nil }
            return GMLuaTextPanelStateSnapshot(
                panelIdentifier: descriptor.identifier,
                engineClassName: descriptor.engineClassName,
                requestedClassName: descriptor.requestedClassName,
                text: descriptor.text,
                fontName: descriptor.fontName,
                foregroundColor: descriptor.foregroundColor,
                contentAlignment: descriptor.contentAlignment
            )
        }
    }

    /// `false` until the iPad view/renderer bridge is connected. The registry
    /// is still useful for loading and executing the original Derma Lua graph.
    public let hasPlatformViewBacking = false

    /// Text state is logical only until a UIKit/CoreText/Metal bridge consumes
    /// the snapshots above.
    public let hasPlatformTextBacking = false

    fileprivate var references: [LuaValue] {
        lock.lock()
        defer { lock.unlock() }
        return controls.values.map(LuaValue.table)
            + Array(panels.values)
            + [.table(panelMetatable), semanticIndex]
    }

    fileprivate func registerControl(
        name: String,
        table: LuaTable,
        baseName: String
    ) throws {
        try state.setRawTableValue(
            .string(LuaString(baseName)),
            for: .string("Base"),
            in: table
        )
        if case .nilValue = try state.rawTableValue(for: .string("Init"), in: table) {
            try state.setRawTableValue(
                .nativeFunction(LuaNativeFunctionBox({ _ in [] }, debugName: "Panel:Init")),
                for: .string("Init"),
                in: table
            )
        }

        let inheritance = LuaTable()
        let baseTable: LuaTable?
        lock.lock()
        baseTable = controls[baseName]
        lock.unlock()
        try state.setRawTableValue(
            .table(baseTable ?? panelMetatable),
            for: .string("__index"),
            in: inheritance
        )
        table.metatable = inheritance

        lock.lock()
        controls[name] = table
        lock.unlock()
    }

    fileprivate func control(named name: String) -> LuaTable? {
        lock.lock()
        defer { lock.unlock() }
        return controls[name]
    }

    fileprivate func create(
        className: String,
        parent: LuaValue?,
        name: String?
    ) throws -> LuaValue {
        let parentIdentifier: Int?
        if let parent, !isNil(parent) {
            guard let descriptor = panelDescriptor(from: parent),
                  GMLuaTypeSystem.typedObject(from: parent)?.isValid == true else {
                throw LuaError.runtime("bad argument #2 to 'Create' (Panel expected)")
            }
            parentIdentifier = descriptor.identifier
        } else {
            parentIdentifier = nil
        }

        let resolution = try resolveClassChain(className)
        guard let resolution else { return .nilValue }

        lock.lock()
        let identifier = nextPanelIdentifier
        nextPanelIdentifier += 1
        lock.unlock()

        let descriptor = GMLuaPanelValue(
            identifier: identifier,
            engineClassName: resolution.engineClassName,
            requestedClassName: className,
            name: name ?? className,
            parentIdentifier: parentIdentifier
        )
        let value = try typeSystem.makeObject(metaName: "Panel", payload: descriptor)
        lock.lock()
        panels[identifier] = value
        lock.unlock()

        do {
            try state.setRawTableValue(.number(0), for: .string("x"), in: descriptor.instanceTable)
            try state.setRawTableValue(.number(0), for: .string("y"), in: descriptor.instanceTable)
            try state.setRawTableValue(
                .string(LuaString(className)),
                for: .string("ClassName"),
                in: descriptor.instanceTable
            )
            for control in resolution.controlsBaseFirst {
                try prepare(descriptor, using: control)
                let initializer = try state.call(
                    semanticIndex,
                    arguments: [.table(descriptor.instanceTable), .string("Init")]
                ).first ?? .nilValue
                if case .luaFunction = initializer {
                    _ = try state.call(initializer, arguments: [value])
                } else if case .nativeFunction = initializer {
                    _ = try state.call(initializer, arguments: [value])
                }
            }
            return value
        } catch {
            remove(identifier: identifier)
            throw error
        }
    }

    fileprivate func remove(identifier: Int) {
        lock.lock()
        let identifiers = descendantIdentifiers(of: identifier)
        let removed = identifiers.compactMap { panels.removeValue(forKey: $0) }
        lock.unlock()
        for value in removed {
            GMLuaTypeSystem.typedObject(from: value)?.isValid = false
        }
    }

    fileprivate func panel(identifier: Int?) -> LuaValue? {
        guard let identifier else { return nil }
        lock.lock()
        let value = panels[identifier]
        lock.unlock()
        guard let value,
              GMLuaTypeSystem.typedObject(from: value)?.isValid == true else { return nil }
        return value
    }

    fileprivate func setParent(identifier: Int, parentIdentifier: Int?) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let value = panels[identifier],
              let descriptor = panelDescriptor(from: value),
              GMLuaTypeSystem.typedObject(from: value)?.isValid == true else {
            throw LuaError.runtime("invalid Panel")
        }
        guard let parentIdentifier else {
            descriptor.parentIdentifier = nil
            descriptor.isParentedToHUD = false
            return
        }
        guard panels[parentIdentifier] != nil else {
            throw LuaError.runtime("invalid parent Panel")
        }

        var current: Int? = parentIdentifier
        var visited: Set<Int> = []
        while let candidate = current {
            guard visited.insert(candidate).inserted else {
                throw LuaError.runtime("cycle in Panel parent hierarchy")
            }
            guard candidate != identifier else {
                throw LuaError.runtime("a Panel cannot be parented to its descendant")
            }
            current = panels[candidate].flatMap { panelDescriptor(from: $0) }?.parentIdentifier
        }
        descriptor.parentIdentifier = parentIdentifier
        descriptor.isParentedToHUD = false
    }

    fileprivate func parentToHUD(identifier: Int) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let value = panels[identifier],
              let descriptor = panelDescriptor(from: value),
              GMLuaTypeSystem.typedObject(from: value)?.isValid == true else {
            throw LuaError.runtime("invalid Panel")
        }
        descriptor.parentIdentifier = nil
        descriptor.isParentedToHUD = true
    }

    fileprivate func children(of identifier: Int) -> [LuaValue] {
        lock.lock()
        defer { lock.unlock() }
        return panels.keys.sorted().compactMap { childIdentifier in
            guard let value = panels[childIdentifier],
                  let child = panelDescriptor(from: value),
                  child.parentIdentifier == identifier,
                  GMLuaTypeSystem.typedObject(from: value)?.isValid == true else { return nil }
            return value
        }
    }

    fileprivate func hasParent(identifier: Int, ancestorIdentifier: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var current = panels[identifier].flatMap { panelDescriptor(from: $0) }?.parentIdentifier
        var visited: Set<Int> = []
        while let candidate = current, visited.insert(candidate).inserted {
            if candidate == ancestorIdentifier { return true }
            current = panels[candidate].flatMap { panelDescriptor(from: $0) }?.parentIdentifier
        }
        return false
    }

    fileprivate func setKeyboardInputEnabled(identifier: Int, enabled: Bool) {
        lock.lock()
        defer { lock.unlock() }
        var pending = [identifier]
        var visited: Set<Int> = []
        while let current = pending.popLast(), visited.insert(current).inserted {
            guard let value = panels[current],
                  let descriptor = panelDescriptor(from: value),
                  GMLuaTypeSystem.typedObject(from: value)?.isValid == true else { continue }
            descriptor.keyboardInputEnabled = enabled
            for (childIdentifier, childValue) in panels {
                guard panelDescriptor(from: childValue)?.parentIdentifier == current else { continue }
                pending.append(childIdentifier)
            }
        }
    }

    fileprivate func invalidateLayout(identifier: Int, layoutNow: Bool) throws {
        let shouldPerformImmediately: Bool
        lock.lock()
        guard let value = panels[identifier],
              let descriptor = panelDescriptor(from: value),
              GMLuaTypeSystem.typedObject(from: value)?.isValid == true else {
            lock.unlock()
            throw LuaError.runtime("invalid Panel")
        }
        descriptor.isLayoutInvalidated = true
        shouldPerformImmediately = layoutNow && !descriptor.isPerformingLayout
        lock.unlock()

        if shouldPerformImmediately {
            _ = try performLayout(identifier: identifier)
        }
    }

    /// Dispatches deferred Lua `PerformLayout` hooks at a host-selected VGUI
    /// frame boundary. Each panel present at the start is visited at most once;
    /// a hook that invalidates itself remains pending for a later boundary.
    ///
    /// This advances logical Lua layout only. It does not claim UIKit, docking,
    /// clipping, hit-testing, or renderer-backed geometry is implemented.
    @discardableResult
    public func performPendingLayouts(maxLayouts: Int = .max) throws -> Int {
        guard maxLayouts > 0 else { return 0 }

        lock.lock()
        let identifiers = panels.keys.sorted().filter { identifier in
            guard let value = panels[identifier],
                  let descriptor = panelDescriptor(from: value) else { return false }
            return descriptor.isLayoutInvalidated &&
                !descriptor.isPerformingLayout &&
                GMLuaTypeSystem.typedObject(from: value)?.isValid == true
        }
        lock.unlock()

        var performed = 0
        for identifier in identifiers.prefix(maxLayouts) {
            if try performLayout(identifier: identifier) {
                performed += 1
            }
        }
        return performed
    }

    private func performLayout(identifier: Int) throws -> Bool {
        let value: LuaValue
        let descriptor: GMLuaPanelValue

        lock.lock()
        guard let storedValue = panels[identifier],
              let storedDescriptor = panelDescriptor(from: storedValue),
              storedDescriptor.isLayoutInvalidated,
              !storedDescriptor.isPerformingLayout,
              GMLuaTypeSystem.typedObject(from: storedValue)?.isValid == true else {
            lock.unlock()
            return false
        }
        value = storedValue
        descriptor = storedDescriptor
        descriptor.isLayoutInvalidated = false
        descriptor.isPerformingLayout = true
        lock.unlock()

        var succeeded = false
        defer {
            lock.lock()
            descriptor.isPerformingLayout = false
            if succeeded {
                completedLayoutPasses &+= 1
            } else if panels[identifier] != nil,
                      GMLuaTypeSystem.typedObject(from: value)?.isValid == true {
                descriptor.isLayoutInvalidated = true
            }
            lock.unlock()
        }

        let callback = try state.call(
            semanticIndex,
            arguments: [.table(descriptor.instanceTable), .string("PerformLayout")]
        ).first ?? .nilValue
        if case .luaFunction = callback {
            _ = try state.call(callback, arguments: [
                value, .number(descriptor.width), .number(descriptor.height)
            ])
        } else if case .nativeFunction = callback {
            _ = try state.call(callback, arguments: [
                value, .number(descriptor.width), .number(descriptor.height)
            ])
        }
        succeeded = true
        return true
    }

    fileprivate func allPanels() -> [LuaValue] {
        lock.lock()
        defer { lock.unlock() }
        return panels.keys.sorted().compactMap { identifier in
            guard let value = panels[identifier],
                  GMLuaTypeSystem.typedObject(from: value)?.isValid == true else { return nil }
            return value
        }
    }

    fileprivate func prepare(_ descriptor: GMLuaPanelValue) throws {
        let classValue = try state.rawTableValue(
            for: .string("ClassName"),
            in: descriptor.instanceTable
        )
        if case let .string(className) = classValue {
            descriptor.requestedClassName = className.utf8String
        }

        var table = control(named: descriptor.requestedClassName)
        if table == nil,
           case let .table(vgui) = state.getGlobal("vgui") {
            let getter = try state.rawTableValue(for: .string("GetControlTable"), in: vgui)
            if case .luaFunction = getter {
                if case let .table(found) = try state.call(
                    getter,
                    arguments: [.string(LuaString(descriptor.requestedClassName))]
                ).first ?? .nilValue {
                    table = found
                }
            } else if case .nativeFunction = getter,
                      case let .table(found) = try state.call(
                        getter,
                        arguments: [.string(LuaString(descriptor.requestedClassName))]
                      ).first ?? .nilValue {
                table = found
            }
        }
        if let table { try prepare(descriptor, using: table) }
    }

    private func prepare(_ descriptor: GMLuaPanelValue, using control: LuaTable) throws {
        let proxyMetatable = LuaTable()
        try state.setRawTableValue(
            .table(control),
            for: .string("__index"),
            in: proxyMetatable
        )
        descriptor.instanceTable.metatable = proxyMetatable
    }

    private func resolveClassChain(
        _ requestedClassName: String
    ) throws -> (engineClassName: String, controlsBaseFirst: [LuaTable])? {
        if Self.engineClassNames.contains(requestedClassName) {
            return (requestedClassName, [])
        }

        var current = requestedClassName
        var visited: Set<String> = []
        var derivedFirst: [LuaTable] = []
        while !Self.engineClassNames.contains(current) {
            guard visited.insert(current).inserted else {
                throw LuaError.runtime("loop in VGUI base classes for '\(requestedClassName)'")
            }
            guard let control = control(named: current) else { return nil }
            derivedFirst.append(control)
            let base = try state.rawTableValue(for: .string("Base"), in: control)
            guard case let .string(baseName) = base else { return nil }
            current = baseName.utf8String
        }
        return (current, Array(derivedFirst.reversed()))
    }

    private func descendantIdentifiers(of root: Int) -> [Int] {
        var result: [Int] = []
        var pending = [root]
        var visited: Set<Int> = []
        while let current = pending.popLast() {
            guard visited.insert(current).inserted else { continue }
            result.append(current)
            for (identifier, value) in panels {
                guard let descriptor = panelDescriptor(from: value),
                      descriptor.parentIdentifier == current else { continue }
                pending.append(identifier)
            }
        }
        return result
    }

    fileprivate func setSemanticIndex(_ value: LuaValue) {
        semanticIndex = value
    }
}

public enum GMLuaVGUI {
    @discardableResult
    public static func install(
        into state: LuaState,
        typeSystem: GMLuaTypeSystem
    ) throws -> GMLuaVGUIRegistry {
        guard let panelMetatable = typeSystem.metatable(named: "Panel") else {
            throw LuaError.runtime("GLua Panel metatable was not installed")
        }
        let registry = GMLuaVGUIRegistry(
            state: state,
            typeSystem: typeSystem,
            panelMetatable: panelMetatable
        )
        let semanticIndex = try state.executeReturningValues(
            "return function(container, key) return container[key] end",
            sourceName: "=[GModLua VGUI index helper]"
        ).first ?? .nilValue
        registry.setSemanticIndex(semanticIndex)

        let panelIndex = nativeFunction(
            name: "Panel.__index",
            registry: registry
        ) { arguments in
            guard arguments.count >= 2,
                  let descriptor = panelDescriptor(from: arguments[0]) else {
                return [.nilValue]
            }
            let value = try state.call(
                semanticIndex,
                arguments: [.table(descriptor.instanceTable), arguments[1]]
            ).first ?? .nilValue
            if !isNil(value) { return [value] }
            return [try state.rawTableValue(for: arguments[1], in: panelMetatable)]
        }
        let panelNewIndex = nativeFunction(
            name: "Panel.__newindex",
            registry: registry
        ) { arguments in
            guard arguments.count >= 3,
                  let descriptor = panelDescriptor(from: arguments[0]) else {
                throw LuaError.runtime("attempt to index an invalid Panel")
            }
            try state.setRawTableValue(
                arguments[2],
                for: arguments[1],
                in: descriptor.instanceTable
            )
            return []
        }
        try set(panelIndex, "__index", panelMetatable, state)
        try set(panelNewIndex, "__newindex", panelMetatable, state)

        try installPanelMethods(
            state: state,
            registry: registry,
            panelMetatable: panelMetatable
        )

        let vgui = LuaTable()
        let register = nativeFunction(name: "vgui.Register", registry: registry) { arguments in
            let className = try requiredString(arguments, 0, "Register")
            guard arguments.indices.contains(1), case let .table(control) = arguments[1] else {
                throw LuaError.runtime("bad argument #2 to 'Register' (table expected)")
            }
            let baseName = try optionalString(arguments, 2, "Panel", "Register")
            try registry.registerControl(name: className, table: control, baseName: baseName)
            state.setGlobal("PANEL", value: .nilValue)
            return [.table(control)]
        }
        let getControlTable = nativeFunction(
            name: "vgui.GetControlTable",
            registry: registry
        ) { arguments in
            let className = try requiredString(arguments, 0, "GetControlTable")
            return [registry.control(named: className).map(LuaValue.table) ?? .nilValue]
        }
        let exists = nativeFunction(name: "vgui.Exists", registry: registry) { arguments in
            let className = try requiredString(arguments, 0, "Exists")
            return [.boolean(registry.control(named: className) != nil)]
        }
        let create = nativeFunction(name: "vgui.Create", registry: registry) { arguments in
            let className = try requiredString(arguments, 0, "Create")
            let parent = arguments.indices.contains(1) ? arguments[1] : nil
            let name: String?
            if arguments.indices.contains(2), !isNil(arguments[2]) {
                name = try requiredString(arguments, 2, "Create")
            } else {
                name = nil
            }
            return [try registry.create(className: className, parent: parent, name: name)]
        }
        let getAll = nativeFunction(name: "vgui.GetAll", registry: registry) { _ in
            let table = LuaTable()
            for (offset, value) in registry.allPanels().enumerated() {
                try state.setRawTableValue(
                    value,
                    for: .number(Double(offset + 1)),
                    in: table
                )
            }
            return [.table(table)]
        }

        for (name, value) in [
            ("Register", register), ("GetControlTable", getControlTable),
            ("Exists", exists), ("Create", create), ("GetAll", getAll)
        ] {
            try set(value, name, vgui, state)
        }
        state.setGlobal("vgui", value: .table(vgui))
        return registry
    }

    private static func installPanelMethods(
        state: LuaState,
        registry: GMLuaVGUIRegistry,
        panelMetatable: LuaTable
    ) throws {
        let methods: [(String, LuaNativeFunction)] = [
            ("GetTable", { arguments in
                [.table(try requiredPanel(arguments, "GetTable").instanceTable)]
            }),
            ("GetName", { arguments in
                [.string(LuaString(try requiredPanel(arguments, "GetName").name))]
            }),
            ("SetName", { arguments in
                let panel = try requiredPanel(arguments, "SetName")
                panel.name = try requiredString(arguments, 1, "SetName")
                return []
            }),
            ("GetClassName", { arguments in
                let panel = try requiredPanel(arguments, "GetClassName")
                return [.string(LuaString(panel.requestedClassName))]
            }),
            ("GetParent", { arguments in
                let panel = try requiredPanel(arguments, "GetParent")
                return [registry.panel(identifier: panel.parentIdentifier) ?? .nilValue]
            }),
            ("SetParent", { arguments in
                let panel = try requiredPanel(arguments, "SetParent")
                if arguments.count < 2 || isNil(arguments[1]) {
                    try registry.setParent(identifier: panel.identifier, parentIdentifier: nil)
                    return []
                }
                guard let parent = panelDescriptor(from: arguments[1]),
                      GMLuaTypeSystem.typedObject(from: arguments[1])?.isValid == true else {
                    throw LuaError.runtime("bad argument #1 to 'SetParent' (Panel expected)")
                }
                try registry.setParent(
                    identifier: panel.identifier,
                    parentIdentifier: parent.identifier
                )
                return []
            }),
            ("ParentToHUD", { arguments in
                let panel = try requiredPanel(arguments, "ParentToHUD")
                try registry.parentToHUD(identifier: panel.identifier)
                return []
            }),
            ("GetChildren", { arguments in
                let panel = try requiredPanel(arguments, "GetChildren")
                let result = LuaTable()
                for (offset, child) in registry.children(of: panel.identifier).enumerated() {
                    try state.setRawTableValue(
                        child,
                        for: .number(Double(offset + 1)),
                        in: result
                    )
                }
                return [.table(result)]
            }),
            ("ChildCount", { arguments in
                let panel = try requiredPanel(arguments, "ChildCount")
                return [.number(Double(registry.children(of: panel.identifier).count))]
            }),
            ("GetChild", { arguments in
                let panel = try requiredPanel(arguments, "GetChild")
                let index = try requiredInteger(arguments, 1, "GetChild")
                let children = registry.children(of: panel.identifier)
                guard index >= 0, index < children.count else { return [.nilValue] }
                return [children[index]]
            }),
            ("HasParent", { arguments in
                let panel = try requiredPanel(arguments, "HasParent")
                guard arguments.indices.contains(1),
                      let ancestor = panelDescriptor(from: arguments[1]),
                      GMLuaTypeSystem.typedObject(from: arguments[1])?.isValid == true else {
                    return [.boolean(false)]
                }
                return [.boolean(registry.hasParent(
                    identifier: panel.identifier,
                    ancestorIdentifier: ancestor.identifier
                ))]
            }),
            ("SetPos", { arguments in
                let panel = try requiredPanel(arguments, "SetPos")
                let x = try requiredNumber(arguments, 1, "SetPos")
                let y = try requiredNumber(arguments, 2, "SetPos")
                panel.x = x
                panel.y = y
                try state.setRawTableValue(.number(x), for: .string("x"), in: panel.instanceTable)
                try state.setRawTableValue(.number(y), for: .string("y"), in: panel.instanceTable)
                return []
            }),
            ("GetPos", { arguments in
                let panel = try requiredPanel(arguments, "GetPos")
                return [.number(panel.x), .number(panel.y)]
            }),
            ("SetSize", { arguments in
                let panel = try requiredPanel(arguments, "SetSize")
                panel.width = floor(try requiredNumber(arguments, 1, "SetSize"))
                panel.height = floor(try requiredNumber(arguments, 2, "SetSize"))
                return []
            }),
            ("GetSize", { arguments in
                let panel = try requiredPanel(arguments, "GetSize")
                return [.number(panel.width), .number(panel.height)]
            }),
            ("GetWide", { arguments in
                [.number(try requiredPanel(arguments, "GetWide").width)]
            }),
            ("GetTall", { arguments in
                [.number(try requiredPanel(arguments, "GetTall").height)]
            }),
            ("GetBounds", { arguments in
                let panel = try requiredPanel(arguments, "GetBounds")
                return [
                    .number(panel.x), .number(panel.y),
                    .number(panel.width), .number(panel.height)
                ]
            }),
            ("InvalidateLayout", { arguments in
                let panel = try requiredPanel(arguments, "InvalidateLayout")
                let layoutNow = try optionalBoolean(
                    arguments,
                    1,
                    false,
                    "InvalidateLayout"
                )
                try registry.invalidateLayout(
                    identifier: panel.identifier,
                    layoutNow: layoutNow
                )
                return []
            }),
            ("SetText", { arguments in
                let panel = try requiredTextPanel(arguments, "SetText")
                let supplied = try requiredLuaString(arguments, 1, "SetText")
                if panel.engineClassName == "Label" {
                    panel.text = LuaString(bytes: Array(supplied.bytes.prefix(1_023)))
                    try registry.invalidateLayout(identifier: panel.identifier, layoutNow: false)
                } else {
                    panel.text = supplied
                }
                return []
            }),
            ("GetText", { arguments in
                let panel = try requiredTextPanel(arguments, "GetText")
                let text: LuaString
                if panel.engineClassName == "TextEntry" {
                    text = panel.text
                } else {
                    text = LuaString(bytes: Array(panel.text.bytes.prefix(1_023)))
                }
                return [.string(text)]
            }),
            ("GetValue", { arguments in
                let panel = try requiredPanel(arguments, "GetValue")
                guard panel.engineClassName == "Label" || panel.engineClassName == "TextEntry" else {
                    throw unsupportedPanelMethod(panel, "GetValue")
                }
                return [.string(LuaString(bytes: Array(panel.text.bytes.prefix(8_092))))]
            }),
            ("SetFontInternal", { arguments in
                let panel = try requiredTextPanel(arguments, "SetFontInternal")
                panel.fontName = try requiredLuaString(arguments, 1, "SetFontInternal")
                return []
            }),
            ("GetFont", { arguments in
                let panel = try requiredTextPanel(arguments, "GetFont")
                return [.string(panel.fontName)]
            }),
            ("SetFGColor", { arguments in
                let panel = try requiredTextPanel(arguments, "SetFGColor")
                panel.foregroundColor = try requiredPanelColor(
                    arguments,
                    state: state,
                    function: "SetFGColor"
                )
                return []
            }),
            ("GetFGColor", { arguments in
                let panel = try requiredTextPanel(arguments, "GetFGColor")
                guard let color = panel.foregroundColor else {
                    throw LuaError.runtime(
                        "Panel:GetFGColor has no logical scheme color before ApplySchemeSettings"
                    )
                }
                return [try makeColorValue(color, state: state)]
            }),
            ("SetContentAlignment", { arguments in
                let panel = try requiredLabel(arguments, "SetContentAlignment")
                let alignment = try requiredInteger(arguments, 1, "SetContentAlignment")
                guard (1...9).contains(alignment) else {
                    throw LuaError.runtime(
                        "bad argument #1 to 'SetContentAlignment' (alignment 1 through 9 expected)"
                    )
                }
                panel.contentAlignment = alignment
                try registry.invalidateLayout(identifier: panel.identifier, layoutNow: false)
                return []
            }),
            ("GetContentAlignment", { arguments in
                let panel = try requiredLabel(arguments, "GetContentAlignment")
                return [.number(Double(panel.contentAlignment))]
            }),
            ("SetVisible", { arguments in
                let panel = try requiredPanel(arguments, "SetVisible")
                panel.isVisible = try requiredBoolean(arguments, 1, "SetVisible")
                return []
            }),
            ("IsVisible", { arguments in
                [.boolean(try requiredPanel(arguments, "IsVisible").isVisible)]
            }),
            ("SetAlpha", { arguments in
                let panel = try requiredPanel(arguments, "SetAlpha")
                let alpha = try requiredNumber(arguments, 1, "SetAlpha")
                panel.alpha = min(255, max(0, alpha.rounded(.towardZero)))
                return []
            }),
            ("GetAlpha", { arguments in
                [.number(try requiredPanel(arguments, "GetAlpha").alpha)]
            }),
            ("SetMouseInputEnabled", { arguments in
                let panel = try requiredPanel(arguments, "SetMouseInputEnabled")
                panel.mouseInputEnabled = try requiredBoolean(
                    arguments,
                    1,
                    "SetMouseInputEnabled"
                )
                return []
            }),
            ("IsMouseInputEnabled", { arguments in
                [.boolean(try requiredPanel(arguments, "IsMouseInputEnabled").mouseInputEnabled)]
            }),
            ("SetKeyboardInputEnabled", { arguments in
                let panel = try requiredPanel(arguments, "SetKeyboardInputEnabled")
                registry.setKeyboardInputEnabled(
                    identifier: panel.identifier,
                    enabled: try requiredBoolean(arguments, 1, "SetKeyboardInputEnabled")
                )
                return []
            }),
            ("SetKeyBoardInputEnabled", { arguments in
                let panel = try requiredPanel(arguments, "SetKeyBoardInputEnabled")
                registry.setKeyboardInputEnabled(
                    identifier: panel.identifier,
                    enabled: try requiredBoolean(arguments, 1, "SetKeyBoardInputEnabled")
                )
                return []
            }),
            ("IsKeyboardInputEnabled", { arguments in
                [.boolean(try requiredPanel(arguments, "IsKeyboardInputEnabled").keyboardInputEnabled)]
            }),
            ("SetPaintBackgroundEnabled", { arguments in
                let panel = try requiredPanel(arguments, "SetPaintBackgroundEnabled")
                panel.paintBackgroundEnabled = try requiredBoolean(
                    arguments,
                    1,
                    "SetPaintBackgroundEnabled"
                )
                return []
            }),
            ("SetPaintBorderEnabled", { arguments in
                let panel = try requiredPanel(arguments, "SetPaintBorderEnabled")
                panel.paintBorderEnabled = try requiredBoolean(
                    arguments,
                    1,
                    "SetPaintBorderEnabled"
                )
                return []
            }),
            ("SetZPos", { arguments in
                let panel = try requiredPanel(arguments, "SetZPos")
                panel.zPosition = try requiredNumber(arguments, 1, "SetZPos").rounded(.towardZero)
                return []
            }),
            ("GetZPos", { arguments in
                [.number(try requiredPanel(arguments, "GetZPos").zPosition)]
            }),
            ("Prepare", { arguments in
                let panel = try requiredPanel(arguments, "Prepare")
                try registry.prepare(panel)
                return []
            }),
            ("Remove", { arguments in
                let panel = try requiredPanel(arguments, "Remove", requireValid: false)
                registry.remove(identifier: panel.identifier)
                return []
            })
        ]
        for (name, body) in methods {
            try set(
                nativeFunction(name: "Panel:\(name)", registry: registry, body),
                name,
                panelMetatable,
                state
            )
        }
    }
}

private func nativeFunction(
    name: String,
    registry: GMLuaVGUIRegistry,
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

private func panelDescriptor(from value: LuaValue) -> GMLuaPanelValue? {
    GMLuaTypeSystem.typedObject(from: value)?.payload as? GMLuaPanelValue
}

private func requiredPanel(
    _ arguments: [LuaValue],
    _ method: String,
    requireValid: Bool = true
) throws -> GMLuaPanelValue {
    guard let first = arguments.first,
          let descriptor = panelDescriptor(from: first),
          !requireValid || GMLuaTypeSystem.typedObject(from: first)?.isValid == true else {
        throw LuaError.runtime("bad self for Panel:\(method)")
    }
    return descriptor
}

private func isTextEngineClass(_ className: String) -> Bool {
    className == "Label" || className == "TextEntry" || className == "RichText"
}

private func unsupportedPanelMethod(_ panel: GMLuaPanelValue, _ method: String) -> LuaError {
    LuaError.runtime(
        "Panel:\(method) is not implemented by engine class '\(panel.engineClassName)'"
    )
}

private func requiredTextPanel(
    _ arguments: [LuaValue],
    _ method: String
) throws -> GMLuaPanelValue {
    let panel = try requiredPanel(arguments, method)
    guard isTextEngineClass(panel.engineClassName) else {
        throw unsupportedPanelMethod(panel, method)
    }
    return panel
}

private func requiredLabel(
    _ arguments: [LuaValue],
    _ method: String
) throws -> GMLuaPanelValue {
    let panel = try requiredPanel(arguments, method)
    guard panel.engineClassName == "Label" else {
        throw unsupportedPanelMethod(panel, method)
    }
    return panel
}

private func requiredLuaString(
    _ arguments: [LuaValue],
    _ index: Int,
    _ function: String
) throws -> LuaString {
    guard arguments.indices.contains(index), case let .string(value) = arguments[index] else {
        throw LuaError.runtime(
            "bad argument #\(index + 1) to '\(function)' (string expected)"
        )
    }
    return value
}

private func requiredPanelColor(
    _ arguments: [LuaValue],
    state: LuaState,
    function: String
) throws -> GMLuaPanelColorSnapshot {
    if arguments.indices.contains(1), case let .table(table) = arguments[1] {
        func component(_ name: String) throws -> Double {
            let value = try state.rawTableValue(for: .string(LuaString(name)), in: table)
            guard case let .number(number) = value, number.isFinite else {
                throw LuaError.runtime(
                    "bad argument #1 to '\(function)' (Color table with finite \(name) expected)"
                )
            }
            return number
        }
        return try GMLuaPanelColorSnapshot(
            red: component("r"),
            green: component("g"),
            blue: component("b"),
            alpha: component("a")
        )
    }

    return GMLuaPanelColorSnapshot(
        red: try requiredNumber(arguments, 1, function),
        green: try requiredNumber(arguments, 2, function),
        blue: try requiredNumber(arguments, 3, function),
        alpha: try requiredNumber(arguments, 4, function)
    )
}

private func makeColorValue(
    _ color: GMLuaPanelColorSnapshot,
    state: LuaState
) throws -> LuaValue {
    let arguments: [LuaValue] = [
        .number(color.red), .number(color.green),
        .number(color.blue), .number(color.alpha)
    ]
    let constructor = state.getGlobal("Color")
    if case .luaFunction = constructor {
        if let value = try state.call(constructor, arguments: arguments).first, !isNil(value) {
            return value
        }
    } else if case .nativeFunction = constructor,
              let value = try state.call(constructor, arguments: arguments).first,
              !isNil(value) {
        return value
    }

    let table = LuaTable()
    try state.setRawTableValue(.number(color.red), for: .string("r"), in: table)
    try state.setRawTableValue(.number(color.green), for: .string("g"), in: table)
    try state.setRawTableValue(.number(color.blue), for: .string("b"), in: table)
    try state.setRawTableValue(.number(color.alpha), for: .string("a"), in: table)
    return .table(table)
}

private func requiredString(
    _ arguments: [LuaValue],
    _ index: Int,
    _ function: String
) throws -> String {
    try requiredLuaString(arguments, index, function).utf8String
}

private func optionalString(
    _ arguments: [LuaValue],
    _ index: Int,
    _ fallback: String,
    _ function: String
) throws -> String {
    guard arguments.indices.contains(index), !isNil(arguments[index]) else { return fallback }
    return try requiredString(arguments, index, function)
}

private func requiredNumber(
    _ arguments: [LuaValue],
    _ index: Int,
    _ function: String
) throws -> Double {
    guard arguments.indices.contains(index), case let .number(value) = arguments[index],
          value.isFinite else {
        throw LuaError.runtime(
            "bad argument #\(index) to '\(function)' (finite number expected)"
        )
    }
    return value
}

private func requiredInteger(
    _ arguments: [LuaValue],
    _ index: Int,
    _ function: String
) throws -> Int {
    let value = try requiredNumber(arguments, index, function)
    let integral = value.rounded(.towardZero)
    guard integral == value, integral >= Double(Int.min), integral < Double(Int.max) else {
        throw LuaError.runtime("bad argument #\(index) to '\(function)' (integer expected)")
    }
    return Int(integral)
}

private func requiredBoolean(
    _ arguments: [LuaValue],
    _ index: Int,
    _ function: String
) throws -> Bool {
    guard arguments.indices.contains(index), case let .boolean(value) = arguments[index] else {
        throw LuaError.runtime("bad argument #\(index) to '\(function)' (boolean expected)")
    }
    return value
}

private func optionalBoolean(
    _ arguments: [LuaValue],
    _ index: Int,
    _ fallback: Bool,
    _ function: String
) throws -> Bool {
    guard arguments.indices.contains(index), !isNil(arguments[index]) else { return fallback }
    return try requiredBoolean(arguments, index, function)
}

private func set(
    _ value: LuaValue,
    _ name: String,
    _ table: LuaTable,
    _ state: LuaState
) throws {
    try state.setRawTableValue(value, for: .string(LuaString(name)), in: table)
}

private func isNil(_ value: LuaValue) -> Bool {
    if case .nilValue = value { return true }
    return false
}
