import Foundation
import GModLua

/// Host-owned native resource adapter. Invoke on the runtime's owning lane.
/// This does not replace the deprecated GLua LoadControlsFromString method.
public final class GMLuaVGUIResourceInstance {
    private final class Roots: @unchecked Sendable {
        let values: [LuaValue]
        init(_ values: [LuaValue]) { self.values = values }
    }
    public struct UnappliedField: Equatable, Sendable {
        public let control: String
        public let key: String
    }

    /// A real panel from this adapter, usable only on the same runtime lane.
    /// Supplying it does not implement the C++ behavior of a custom page class.
    public struct ExistingPanel {
        fileprivate let runtime: GMLuaRuntime
        fileprivate let panel: LuaValue
        fileprivate let baseControlName: String
    }

    public enum MissingFactoryPolicy: Equatable, Sendable {
        case fail
        /// Source BuildGroup continues after a null factory result. No dummy
        /// panel is created, and every omitted control remains inspectable.
        case sourceContinue
    }

    public struct SkippedControl: Equatable, Sendable {
        public let name: String
        public let controlName: String?
    }

    public struct ReusedControl: Equatable, Sendable {
        public let name: String
        public let declaredControlName: String?
        public let appliedBaseControlName: String
    }

    public enum ResourceError: Error, Equatable {
        case unresolvedDirectives
        case unresolvedConditional(String)
        case unsupportedControl(String)
        case missingRoot(String)
        case missingControl(String)
        case invalidField(control: String, key: String)
        case foreignPanel
    }

    public private(set) var unappliedFields: [UnappliedField] = []
    /// Controls still using their shipped Derma color path when an authored
    /// GameUI Scheme is supplied. This is separate from font/geometry parity.
    public private(set) var unappliedSchemeColorControls: [String] = []
    public private(set) var unappliedSchemeFontControls: [String] = []
    public private(set) var skippedControls: [SkippedControl] = []
    public private(set) var reusedControls: [ReusedControl] = []
    private let runtime: GMLuaRuntime
    private let index: LuaValue
    private let roots: Roots
    private var panels: [String: LuaValue] = [:]
    private var ownedPanels: Set<String> = []
    private var panelKinds: [String: String] = [:]
    private var controls: [SourceVGUIResource.Control] = []
    private var resource: SourceVGUIResource
    private let scheme: SourceVGUIScheme?
    private let rootControlName: String?
    private let contextPanel: LuaValue?
    private let worldPanel: LuaValue?
    private var laidOutViewport: GMLuaViewportSize?
    private var laidOutContextBounds: GMLuaPanelRect?

    private static let classes = [
        "frame": "DFrame", "panel": "DPanel", "editablepanel": "EditablePanel",
        "label": "DLabel", "button": "DButton", "checkbutton": "DCheckBoxLabel",
        "textentry": "DTextEntry", "progressbar": "DProgress", "imagepanel": "DImage",
        "combobox": "DComboBox", "ccvarslider": "DSlider"
    ]

    init(runtime: GMLuaRuntime, resource: SourceVGUIResource,
         rootControlName: String?, scheme: SourceVGUIScheme? = nil,
         context: ExistingPanel? = nil, existingPanels: [ExistingPanel] = [],
         missingFactoryPolicy: MissingFactoryPolicy = .fail,
         onCommand: @escaping (String) throws -> Void) throws {
        self.runtime = runtime
        self.resource = resource
        self.scheme = scheme
        self.contextPanel = context?.panel
        worldPanel = context == nil ? nil : try runtime.executeReturningValues("return vgui.GetWorldPanel()").first
        index = try runtime.executeReturningValues("return function(p,k) return p[k] end").first ?? .nilValue
        roots = Roots([index])
        runtime.state.registerGarbageCollectionRootProvider { [weak roots] in roots?.values ?? [] }
        guard resource.directives.isEmpty else { throw ResourceError.unresolvedDirectives }
        if let rootControlName, !resource.controls.contains(where: { $0.fieldName == rootControlName }) {
            throw ResourceError.missingRoot(rootControlName)
        }
        // BuildGroup matches existing panels by resource BLOCK key, case
        // insensitively, before asking the context's factory for a new panel.
        // Retain native order: the context precedes other supplied controls.
        let isValid = try runtime.executeReturningValues("return IsValid").first ?? .nilValue
        var candidates: [(ExistingPanel, String)] = []
        for binding in (context.map { [$0] } ?? []) + existingPanels {
            guard binding.runtime === runtime else { throw ResourceError.foreignPanel }
            guard case .boolean(true) = try runtime.state.call(isValid, arguments: [binding.panel]).first else {
                throw ResourceError.missingControl("existing panel")
            }
            let getName = try runtime.state.call(index, arguments: [binding.panel, .string("GetName")]).first ?? .nilValue
            guard case let .string(name) = try runtime.state.call(getName, arguments: [binding.panel]).first else {
                throw ResourceError.missingControl("existing panel name")
            }
            candidates.append((binding, name.utf8String))
        }
        var reusedPanels: [String: LuaValue] = [:]
        var contextField: String?
        for original in resource.controls {
            guard original.conditional == nil, original.entries.allSatisfy({ $0.conditional == nil }) else {
                throw ResourceError.unresolvedConditional(original.name)
            }
            if let (binding, _) = candidates.first(where: {
                $0.1.caseInsensitiveCompare(original.name) == .orderedSame
            }) {
                let entries = original.entries.filter { $0.key.caseInsensitiveCompare("ControlName") != .orderedSame }
                    + [.init(key: "ControlName", value: .string(binding.baseControlName), conditional: nil)]
                controls.append(.init(name: original.name, entries: entries, conditional: nil))
                reusedPanels[original.fieldName] = binding.panel
                reusedControls.append(.init(name: original.name, declaredControlName: original.controlName,
                    appliedBaseControlName: binding.baseControlName))
                if context != nil, candidates.first?.1.caseInsensitiveCompare(original.name) == .orderedSame {
                    contextField = original.fieldName
                }
            } else if let name = original.controlName, Self.classes[name.lowercased()] != nil {
                controls.append(original)
            } else if missingFactoryPolicy == .sourceContinue {
                skippedControls.append(.init(name: original.name, controlName: original.controlName))
            } else {
                throw ResourceError.unsupportedControl(original.controlName ?? original.name)
            }
        }
        if context != nil, let rootControlName, rootControlName != contextField {
            throw ResourceError.invalidField(control: rootControlName, key: "context root")
        }
        self.rootControlName = contextField ?? rootControlName
        if let rootControlName = self.rootControlName,
           !controls.contains(where: { $0.fieldName == rootControlName }) {
            throw ResourceError.missingRoot(rootControlName)
        }
        // Validate remaining factories/fields before constructing anything.
        // Unknown native classes never become dummy or fictitious cvar widgets.
        var fieldNames: Set<String> = []
        var sliders: [String: GMLuaVGUIResourceCvarSlider] = [:]
        for control in controls {
            guard fieldNames.insert(control.fieldName).inserted else {
                throw ResourceError.invalidField(control: control.name, key: "duplicate fieldName")
            }
            guard control.conditional == nil, control.entries.allSatisfy({ $0.conditional == nil }) else {
                throw ResourceError.unresolvedConditional(control.name)
            }
            guard let name = control.controlName, Self.classes[name.lowercased()] != nil else {
                throw ResourceError.unsupportedControl(control.controlName ?? control.name)
            }
            // Native ComboBox_Factory defaults to editable. DComboBox is not
            // a TextEntry: support only the explicitly read-only resource mode.
            if name.lowercased() == "combobox", control.value("editable") != "0" {
                throw ResourceError.invalidField(control: control.name, key: "editable")
            }
            if name.lowercased() == "ccvarslider" {
                sliders[control.fieldName] = try GMLuaVGUIResourceCvarSlider(
                    control: control, registry: runtime.conVarRegistry)
            }
            if ["checkbutton", "frame"].contains(name.lowercased()),
               !(name.lowercased() == "frame" && control.value("settitlebarvisible") == "0"),
               let scheme, scheme.fonts.isEmpty {
                throw SourceVGUIScheme.SchemeError.missingFont("Marlett")
            }
            if name.lowercased() == "frame" {
                for key in ["settitlebarvisible", "setclosebuttonvisible"] {
                    if let value = control.value(key), value != "0" && value != "1" {
                        throw ResourceError.invalidField(control: control.name, key: key)
                    }
                }
            }
        }
        var ordered = controls
        if let rootControlName = self.rootControlName, let offset = ordered.firstIndex(where: { $0.fieldName == rootControlName }) {
            ordered.insert(ordered.remove(at: offset), at: 0)
        }
        let create = try runtime.executeReturningValues("return vgui.Create").first ?? .nilValue
        do {
            for control in ordered {
                let parent = control.fieldName == self.rootControlName ? LuaValue.nilValue
                    : self.rootControlName.flatMap { panels[$0] } ?? contextPanel ?? .nilValue
                let hidesTitle = control.controlName?.lowercased() == "frame" && control.value("settitlebarvisible") == "0"
                let sourceCheck = scheme != nil && control.controlName?.lowercased() == "checkbutton"
                let panel: LuaValue
                if let existing = reusedPanels[control.fieldName] {
                    panel = existing
                } else {
                    panel = try runtime.state.call(create, arguments: [
                        .string(LuaString(hidesTitle ? "DPanel" : sourceCheck ? "DButton" : Self.classes[control.controlName!.lowercased()]!)),
                        parent, .string(LuaString(control.name))
                    ]).first ?? .nilValue
                    ownedPanels.insert(control.fieldName)
                }
                panels[control.fieldName] = panel
                panelKinds[control.fieldName] = hidesTitle ? "Panel" : control.controlName!
                if let fieldName = control.value("fieldName") {
                    _ = try call(control.fieldName, "SetName", [.string(LuaString(fieldName))])
                }
                if control.controlName?.lowercased() == "frame", !hidesTitle {
                    // Source Frame defaults to retaining its instance on Close.
                    // Derma's global DFrame default is intentionally unchanged.
                    let configure = try runtime.executeReturningValues("""
                        return function(p, close, created)
                            if created then p:SetDeleteOnClose(false) end
                            p.btnClose:SetDoubleClickingEnabled(false)
                            p.btnClose:SetVisible(close)
                            p.btnMaxim:SetVisible(false)
                            p.btnMinim:SetVisible(false)
                        end
                        """).first ?? .nilValue
                    _ = try runtime.state.call(configure, arguments: [panel,
                        .boolean(control.value("setclosebuttonvisible") != "0"), .boolean(ownedPanels.contains(control.fieldName))])
                }
                if sourceCheck, let scheme {
                    try GMLuaVGUIResourceSchemeCheckButton.install(runtime: runtime, panel: panel, scheme: scheme)
                    _ = try call(control.fieldName, "SetContentAlignment", [.number(4)])
                    if let value = control.value("smallcheckimage"), value != "0" && value != "1" {
                        throw ResourceError.invalidField(control: control.name, key: "smallcheckimage")
                    }
                }
                if control.controlName?.lowercased() == "button" {
                    _ = try call(control.fieldName, "SetDoubleClickingEnabled", [.boolean(false)])
                } else if control.controlName?.lowercased() == "checkbutton", !sourceCheck {
                    let configure = try runtime.executeReturningValues("""
                        return function(p)
                            p.Button:SetDoubleClickingEnabled(false)
                            p.Label:SetDoubleClickingEnabled(false)
                        end
                        """).first ?? .nilValue
                    _ = try runtime.state.call(configure, arguments: [panel])
                }
                if let slider = sliders[control.fieldName] {
                    try slider.install(runtime: runtime, panel: panel, scheme: scheme)
                }
                if control.controlName?.lowercased() == "progressbar" {
                    // Native Source ProgressBar is segmented, unlike Derma's
                    // continuous green DProgress skin. Independently implement
                    // its eastward 4-gap/8-width/4-inset geometry; retain the
                    // real fraction accessor and the installed GMod palette.
                    // Full dynamic scheme/proportional scaling remains separate.
                    let install = try runtime.executeReturningValues("""
                        return function(p)
                            p.Paint = function(self, w, h)
                                surface.SetDrawColor(0, 0, 0, 128)
                                surface.DrawRect(0, 0, w, h)
                                surface.SetDrawColor(255, 255, 255, 255)
                                local count = math.floor(math.floor(w / 12) * self:GetFraction())
                                for i = 0, count - 1 do
                                    surface.DrawRect(4 + i * 12, 4, 8, math.max(0, h - 8))
                                end
                                return true
                            end
                        end
                        """).first ?? .nilValue
                    _ = try runtime.state.call(install, arguments: [panel])
                }
                for (key, method) in [("labelText", "SetText"), ("title", "SetTitle"), ("font", "SetFont")] {
                    if key == "title", hidesTitle { continue }
                    if key == "font", control.controlName?.lowercased() == "frame" { continue }
                    if let text = control.value(key) {
                        _ = try call(control.fieldName, method, [.string(LuaString(text))])
                    }
                }
                if let alignment = control.value("textAlignment") {
                    let positions = ["northwest": 7, "north": 8, "northeast": 9,
                                     "west": 4, "center": 5, "east": 6,
                                     "southwest": 1, "south": 2, "southeast": 3]
                    guard let position = positions[alignment.lowercased()] else {
                        throw ResourceError.invalidField(control: control.name, key: "textAlignment")
                    }
                    _ = try call(control.fieldName, "SetContentAlignment", [.number(Double(position))])
                }
                var applied: Set<String> = ["controlname", "fieldname", "xpos", "ypos", "wide", "tall",
                    "labeltext", "title", "font", "visible", "enabled", "command", "textalignment"]
                if control.controlName?.lowercased() == "frame" {
                    applied.insert("settitlebarvisible")
                    applied.remove("font")
                    if !hidesTitle { applied.insert("setclosebuttonvisible") }
                    if !hidesTitle, let scheme, !scheme.fonts.isEmpty { applied.insert("title_font") }
                }
                if sourceCheck { applied.insert("smallcheckimage") }
                if sliders[control.fieldName] != nil {
                    applied.formUnion(["minvalue", "maxvalue", "cvar_name", "allowoutofrange", "use_convar_minmax"])
                }
                if control.controlName?.lowercased() == "combobox" {
                    // Source inserts choices in host-provided order; stock
                    // DComboBox otherwise sorts them alphabetically on open.
                    _ = try call(control.fieldName, "SetSortItems", [.boolean(false)])
                    applied.insert("editable")
                }
                if ["textentry", "combobox"].contains(control.controlName?.lowercased() ?? ""),
                   let text = control.value("text") {
                    _ = try call(control.fieldName, "SetText", [.string(LuaString(text))])
                    applied.insert("text")
                }
                if control.controlName?.lowercased() == "checkbutton",
                   let selected = control.value("selected") {
                    guard selected == "0" || selected == "1" else {
                        throw ResourceError.invalidField(control: control.name, key: "selected")
                    }
                    _ = try call(control.fieldName, "SetChecked", [.boolean(selected == "1")])
                    applied.insert("selected")
                }
                var booleanFields = [("enabled", "SetEnabled"),
                    ("paintbackground", "SetPaintBackgroundEnabled"), ("paintborder", "SetPaintBorderEnabled")]
                // Native Frame::ApplySettings explicitly ignores .res visible;
                // its owning host controls visibility, not the saved resource.
                if control.controlName?.lowercased() != "frame" { booleanFields.append(("visible", "SetVisible")) }
                if control.controlName?.lowercased() == "frame", !hidesTitle {
                    booleanFields += [("sizable", "SetSizable"), ("draggable", "SetDraggable")]
                }
                if control.controlName?.lowercased() == "label" {
                    booleanFields.append(("wrap", "SetWrap"))
                }
                if control.controlName?.lowercased() == "textentry" {
                    booleanFields.append(("editable", "SetEditable"))
                    booleanFields.append(("numericinputonly", "SetAllowNumericInputOnly"))
                    booleanFields.append(("unicode", "SetAllowNonAsciiCharacters"))
                    if let raw = control.value("maxchars") {
                        guard let maximum = Int(raw) else {
                            throw ResourceError.invalidField(control: control.name, key: "maxchars")
                        }
                        _ = try call(control.fieldName, "SetMaximumCharCount", [.number(Double(maximum))])
                        applied.insert("maxchars")
                    }
                }
                for (key, method) in booleanFields {
                    if let value = control.value(key) {
                        guard value == "0" || value == "1" else {
                            throw ResourceError.invalidField(control: control.name, key: key)
                        }
                        _ = try call(control.fieldName, method, [.boolean(value == "1")])
                        applied.insert(key)
                    }
                }
                if control.value("textinsetx") != nil || control.value("textinsety") != nil {
                    guard let x = Double(control.value("textinsetx") ?? "0"), x.isFinite,
                          let y = Double(control.value("textinsety") ?? "0"), y.isFinite else {
                        throw ResourceError.invalidField(control: control.name, key: "textinset")
                    }
                    _ = try call(control.fieldName, "SetTextInset", [.number(x), .number(y)])
                    applied.formUnion(["textinsetx", "textinsety"])
                }
                if let text = control.value("command") {
                    guard control.controlName?.lowercased() == "button" else {
                        throw ResourceError.invalidField(control: control.name, key: "command")
                    }
                    let callback = LuaValue.nativeFunction(LuaNativeFunctionBox({ _ in
                        try onCommand(text)
                        return []
                    }, debugName: "resource command: \(text)"))
                    // Userdata sidecars are assigned through the same semantic
                    // path as original Lua DButton.DoClick overrides.
                    let setter = try runtime.executeReturningValues("return function(p,k,v) p[k]=v end").first ?? .nilValue
                    _ = try runtime.state.call(setter, arguments: [panel, .string("DoClick"), callback])
                }
                if let scheme {
                    try GMLuaVGUIResourceSchemeColors.install(runtime: runtime, panel: panel, control: control, scheme: scheme)
                    let kind = control.controlName?.lowercased() ?? ""
                    if !["label", "button", "checkbutton", "progressbar", "ccvarslider", "frame", "panel", "editablepanel"].contains(kind) {
                        unappliedSchemeColorControls.append(control.fieldName)
                    }
                    if control.controlName?.lowercased() == "label" {
                        applied.formUnion(["dulltext", "brighttext"])
                    }
                    if scheme.fonts.isEmpty, Self.usesSchemeFont(control) {
                        unappliedSchemeFontControls.append(control.fieldName)
                    }
                }
                unappliedFields += control.entries.filter { !applied.contains($0.key.lowercased()) }
                    .filter { !(hidesTitle && $0.key.lowercased() == "settitlebarvisible") }
                    .map { UnappliedField(control: control.fieldName, key: $0.key) }
            }
        } catch {
            try? remove()
            throw error
        }
    }

    public func layout(viewportWidth: Int, viewportHeight: Int) throws {
        guard viewportWidth > 0, viewportHeight > 0 else {
            throw ResourceError.invalidField(control: resource.name, key: "viewport")
        }
        let viewport = GMLuaViewportSize(width: viewportWidth, height: viewportHeight)
        if contextPanel == nil, viewport == laidOutViewport { return }
        let screen = GMLuaPanelRect(x: 0, y: 0, width: Double(viewportWidth), height: Double(viewportHeight))
        var parent = screen
        if let contextPanel {
            if rootControlName == nil {
                parent = try panelBounds(contextPanel)
            } else {
                let contextParent = try callPanel(contextPanel, "GetParent", []).first ?? .nilValue
                switch contextParent {
                case .nilValue: break
                case let .userdata(value):
                    if case let .userdata(world)? = worldPanel, value === world { break }
                    parent = try panelBounds(contextParent)
                default: parent = try panelBounds(contextParent)
                }
            }
        }
        let contextBounds = contextPanel == nil ? nil : parent
        guard viewport != laidOutViewport || contextBounds != laidOutContextBounds else { return }
        var frames: [(String, GMLuaPanelRect)] = []
        if let root = controls.first(where: { $0.fieldName == rootControlName }) {
            let frame = try root.frame(parent: parent, screen: screen)
            frames.append((root.fieldName, frame))
            parent = GMLuaPanelRect(x: 0, y: 0, width: frame.width, height: frame.height)
        }
        for control in controls where control.fieldName != rootControlName {
            frames.append((control.fieldName, try control.frame(parent: parent, screen: screen)))
        }
        // Resolve every alias/range before mutating live control fonts. Names
        // are content-addressed so another resource can use a different Scheme
        // without replacing Default or any of the original Derma fonts.
        if let scheme, !scheme.fonts.isEmpty {
            let resolved = try controls.filter(Self.usesSchemeFont).map { control in
                let kind = control.controlName?.lowercased() ?? ""
                let alias = kind == "frame" ? (control.value("title_font") ?? scheme.string("FrameTitleBar.Font") ?? "Default") :
                    (control.value("font") ?? (kind == "ccvarslider" ? "DefaultVerySmall" : "Default"))
                let symbol = ["checkbutton", "frame"].contains(kind) ? try scheme.font(
                    kind == "checkbutton" && control.value("smallcheckimage") == "1" ? "MarlettSmall" : "Marlett",
                    viewportHeight: viewportHeight) : nil
                if let symbol, !GMLuaMarlettSymbolText.supports(face: symbol.face) || symbol.flags["symbol"] != true {
                    throw SourceVGUIScheme.SchemeError.unsupportedFont(symbol.alias)
                }
                return (control, try scheme.font(alias, viewportHeight: viewportHeight), symbol)
            }
            let assign = try runtime.executeReturningValues("""
                return function(p, kind, name, symbol)
                    if kind == 'frame' then
                        p.lblTitle:SetFont(name)
                        if symbol then
                            p.btnClose:SetFont(symbol)
                            p.GarrysPAD_SourceFrameButtonFont = symbol
                        end
                        p:InvalidateLayout(true)
                    elseif kind == 'ccvarslider' then p.GarrysPAD_SourceCaptionFont = name
                    else p:SetFont(name) end
                    if symbol then p.GarrysPAD_SourceCheckFont = symbol end
                end
                """).first ?? .nilValue
            for (control, definition, symbol) in resolved {
                guard let panel = panels[control.fieldName] else { throw ResourceError.missingControl(control.fieldName) }
                let name = try GMLuaVGUIResourceSchemeFont.install(definition, runtime: runtime)
                let symbolName = try symbol.map { try GMLuaVGUIResourceSchemeFont.install($0, runtime: runtime) }
                _ = try runtime.state.call(assign, arguments: [panel,
                    .string(LuaString(control.controlName!.lowercased())), .string(LuaString(name)),
                    symbolName.map { .string(LuaString($0)) } ?? .nilValue])
            }
        }
        // Resolve all coordinates before touching live panels. Reapplying them
        // on idle frames would undo native dragging/resizing and relayout.
        for (name, frame) in frames { try applyFrame(frame, to: name) }
        laidOutViewport = viewport
        laidOutContextBounds = contextBounds
    }

    private static func usesSchemeFont(_ control: SourceVGUIResource.Control) -> Bool {
        let kind = control.controlName?.lowercased() ?? ""
        return ["label", "button", "checkbutton", "textentry", "combobox", "ccvarslider"].contains(kind) ||
            (kind == "frame" && control.value("settitlebarvisible") != "0")
    }

    /// Bind only an actually constructed panel. Name matching is performed at
    /// load time using Panel:GetName(), never a caller-provided class alias.
    public func existingPanel(control: String) throws -> ExistingPanel {
        guard let panel = panels[control], let kind = panelKinds[control] else {
            throw ResourceError.missingControl(control)
        }
        return ExistingPanel(runtime: runtime, panel: panel, baseControlName: kind)
    }

    public func setText(_ text: String, control: String) throws {
        _ = try call(control, "SetText", [.string(LuaString(text))])
    }

    /// Live host visibility/focus, distinct from Frame::ApplySettings ignoring
    /// a saved .res visible field. Retained resource frames can be reopened.
    public func setVisible(_ visible: Bool, control: String) throws {
        _ = try call(control, "SetVisible", [.boolean(visible)])
    }

    public func isVisible(control: String) throws -> Bool {
        guard case let .boolean(value) = try call(control, "IsVisible", []).first else {
            throw ResourceError.invalidField(control: control, key: "visible")
        }
        return value
    }

    public func requestFocus(control: String) throws {
        _ = try call(control, "RequestFocus", [])
    }

    public func text(control: String) throws -> String {
        guard controls.contains(where: {
            $0.fieldName == control && ["textentry", "combobox"].contains($0.controlName?.lowercased() ?? "")
        }), case let .string(value) = try call(control, "GetText", []).first else {
            throw ResourceError.invalidField(control: control, key: "text")
        }
        return value.utf8String
    }

    /// Host-populated choices use stock DComboBox's one-based indices. This
    /// does not invent available video modes or bind/persist a Source convar.
    @discardableResult
    public func addChoice(_ text: String, control: String) throws -> Int {
        try requireComboBox(control)
        guard case let .number(index) = try call(control, "AddChoice", [.string(LuaString(text))]).first,
              let index = Int(exactly: index) else {
            throw ResourceError.invalidField(control: control, key: "choice")
        }
        return index
    }

    public func selectChoice(at index: Int, control: String) throws {
        try requireComboBox(control)
        guard index > 0, case .string = try call(control, "GetOptionText", [.number(Double(index))]).first else {
            throw ResourceError.invalidField(control: control, key: "choice")
        }
        _ = try call(control, "ChooseOptionID", [.number(Double(index))])
    }

    public func selectedChoiceIndex(control: String) throws -> Int? {
        try requireComboBox(control)
        guard case let .number(index) = try call(control, "GetSelectedID", []).first else { return nil }
        return Int(exactly: index)
    }

    /// Live CCvarSlider value. A drag changes this before writing its ConVar
    /// on release; host-edited fields can explicitly call applySliderChanges.
    public func sliderValue(control: String) throws -> Double {
        try requireSlider(control)
        guard case let .number(value) = try call(control, "GetSliderValue", []).first else {
            throw ResourceError.invalidField(control: control, key: "slider")
        }
        return value
    }

    public func setSliderValue(_ value: Double, control: String) throws {
        try requireSlider(control)
        guard value.isFinite, (value * 100).isFinite else {
            throw ResourceError.invalidField(control: control, key: "slider")
        }
        _ = try call(control, "SetSliderValue", [.number(value)])
    }

    public func resetSlider(control: String) throws {
        try requireSlider(control)
        _ = try call(control, "Reset", [])
    }

    public func applySliderChanges(control: String) throws {
        try requireSlider(control)
        _ = try call(control, "ApplyChanges", [])
    }

    public func sliderHasBeenModified(control: String) throws -> Bool {
        try requireSlider(control)
        guard case let .boolean(value) = try call(control, "HasBeenModified", []).first else {
            throw ResourceError.invalidField(control: control, key: "slider")
        }
        return value
    }

    private func requireSlider(_ control: String) throws {
        guard controls.contains(where: {
            $0.fieldName == control && $0.controlName?.lowercased() == "ccvarslider"
        }) else { throw ResourceError.invalidField(control: control, key: "slider") }
    }

    private func requireComboBox(_ control: String) throws {
        guard controls.contains(where: {
            $0.fieldName == control && $0.controlName?.lowercased() == "combobox"
        }) else { throw ResourceError.invalidField(control: control, key: "choice") }
    }

    /// Reads the live control, including user changes, rather than the .res
    /// default. Persisting this value remains the owning settings host's job.
    public func isChecked(control: String) throws -> Bool {
        guard controls.contains(where: {
            $0.fieldName == control && $0.controlName?.lowercased() == "checkbutton"
        }), case let .boolean(value) = try call(control, "GetChecked", []).first else {
            throw ResourceError.invalidField(control: control, key: "selected")
        }
        return value
    }

    public func setProgress(_ fraction: Double, control: String) throws {
        guard fraction.isFinite, (0...1).contains(fraction),
              controls.contains(where: { $0.fieldName == control && $0.controlName?.lowercased() == "progressbar" }) else {
            throw ResourceError.invalidField(control: control, key: "progress")
        }
        _ = try call(control, "SetFraction", [.number(fraction)])
    }

    public func remove() throws {
        // BuildGroup destroys only controls created from this resource, never
        // its code-created context or other supplied live panels.
        for name in ownedPanels.sorted() { _ = try call(name, "Remove", []) }
        panels.removeAll()
        ownedPanels.removeAll()
        panelKinds.removeAll()
        laidOutViewport = nil
        laidOutContextBounds = nil
    }

    private func applyFrame(_ frame: GMLuaPanelRect, to control: String) throws {
        _ = try call(control, "SetPos", [.number(frame.x), .number(frame.y)])
        _ = try call(control, "SetSize", [.number(frame.width), .number(frame.height)])
    }

    @discardableResult
    private func call(_ control: String, _ method: String, _ args: [LuaValue]) throws -> [LuaValue] {
        guard let panel = panels[control] else { throw ResourceError.missingControl(control) }
        return try callPanel(panel, method, args)
    }

    private func panelBounds(_ panel: LuaValue) throws -> GMLuaPanelRect {
        guard case let .number(width) = try callPanel(panel, "GetWide", []).first,
              case let .number(height) = try callPanel(panel, "GetTall", []).first else {
            throw ResourceError.invalidField(control: resource.name, key: "context bounds")
        }
        return .init(x: 0, y: 0, width: width, height: height)
    }

    private func callPanel(_ panel: LuaValue, _ method: String, _ args: [LuaValue]) throws -> [LuaValue] {
        let function = try runtime.state.call(index, arguments: [panel, .string(LuaString(method))]).first ?? .nilValue
        return try runtime.state.call(function, arguments: [panel] + args)
    }
}
