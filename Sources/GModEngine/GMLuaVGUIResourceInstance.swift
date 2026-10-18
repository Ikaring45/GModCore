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

    public enum ResourceError: Error, Equatable {
        case unresolvedDirectives
        case unresolvedConditional(String)
        case unsupportedControl(String)
        case missingRoot(String)
        case missingControl(String)
        case invalidField(control: String, key: String)
    }

    public private(set) var unappliedFields: [UnappliedField] = []
    /// Controls still using their shipped Derma color path when an authored
    /// GameUI Scheme is supplied. This is separate from font/geometry parity.
    public private(set) var unappliedSchemeColorControls: [String] = []
    public private(set) var unappliedSchemeFontControls: [String] = []
    private let runtime: GMLuaRuntime
    private let index: LuaValue
    private let roots: Roots
    private var panels: [String: LuaValue] = [:]
    private var resource: SourceVGUIResource
    private let scheme: SourceVGUIScheme?
    private let rootControlName: String?
    private var laidOutViewport: GMLuaViewportSize?

    private static let classes = [
        "frame": "DFrame", "panel": "DPanel", "editablepanel": "EditablePanel",
        "label": "DLabel", "button": "DButton", "checkbutton": "DCheckBoxLabel",
        "textentry": "DTextEntry", "progressbar": "DProgress", "imagepanel": "DImage",
        "combobox": "DComboBox", "ccvarslider": "DSlider"
    ]

    init(runtime: GMLuaRuntime, resource: SourceVGUIResource,
         rootControlName: String?, scheme: SourceVGUIScheme? = nil,
         onCommand: @escaping (String) throws -> Void) throws {
        self.runtime = runtime
        self.resource = resource
        self.scheme = scheme
        self.rootControlName = rootControlName
        index = try runtime.executeReturningValues("return function(p,k) return p[k] end").first ?? .nilValue
        roots = Roots([index])
        runtime.state.registerGarbageCollectionRootProvider { [weak roots] in roots?.values ?? [] }
        guard resource.directives.isEmpty else { throw ResourceError.unresolvedDirectives }
        if let rootControlName, !resource.controls.contains(where: { $0.fieldName == rootControlName }) {
            throw ResourceError.missingRoot(rootControlName)
        }
        // Validate factories before constructing anything. Unknown native C++
        // controls must never become dummy panels or fictitious cvar widgets.
        var fieldNames: Set<String> = []
        var sliders: [String: GMLuaVGUIResourceCvarSlider] = [:]
        for control in resource.controls {
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
        }
        var ordered = resource.controls
        if let rootControlName, let offset = ordered.firstIndex(where: { $0.fieldName == rootControlName }) {
            ordered.insert(ordered.remove(at: offset), at: 0)
        }
        let create = try runtime.executeReturningValues("return vgui.Create").first ?? .nilValue
        do {
            for control in ordered {
                let parent = control.fieldName == rootControlName ? LuaValue.nilValue
                    : rootControlName.flatMap { panels[$0] } ?? .nilValue
                let hidesTitle = control.controlName?.lowercased() == "frame" && control.value("settitlebarvisible") == "0"
                let panel = try runtime.state.call(create, arguments: [
                    .string(LuaString(hidesTitle ? "DPanel" : Self.classes[control.controlName!.lowercased()]!)),
                    parent, .string(LuaString(control.fieldName))
                ]).first ?? .nilValue
                panels[control.fieldName] = panel
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
                var booleanFields = [("visible", "SetVisible"), ("enabled", "SetEnabled"),
                    ("paintbackground", "SetPaintBackgroundEnabled"), ("paintborder", "SetPaintBorderEnabled")]
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
                    if !["label", "button", "progressbar", "ccvarslider"].contains(kind) &&
                        !(kind == "frame" && hidesTitle) {
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
        guard viewport != laidOutViewport else { return }
        let screen = GMLuaPanelRect(x: 0, y: 0, width: Double(viewportWidth), height: Double(viewportHeight))
        var parent = screen
        var frames: [(String, GMLuaPanelRect)] = []
        if let root = resource.controls.first(where: { $0.fieldName == rootControlName }) {
            let frame = try root.frame(parent: screen, screen: screen)
            frames.append((root.fieldName, frame))
            parent = GMLuaPanelRect(x: 0, y: 0, width: frame.width, height: frame.height)
        }
        for control in resource.controls where control.fieldName != rootControlName {
            frames.append((control.fieldName, try control.frame(parent: parent, screen: screen)))
        }
        // Resolve every alias/range before mutating live control fonts. Names
        // are content-addressed so another resource can use a different Scheme
        // without replacing Default or any of the original Derma fonts.
        if let scheme, !scheme.fonts.isEmpty {
            let resolved = try resource.controls.filter(Self.usesSchemeFont).map { control in
                let kind = control.controlName?.lowercased() ?? ""
                let alias = control.value("font") ?? (kind == "ccvarslider" ? "DefaultVerySmall" :
                    (kind == "frame" ? scheme.string("FrameTitleBar.Font") ?? "Default" : "Default"))
                return (control, try scheme.font(alias, viewportHeight: viewportHeight))
            }
            let assign = try runtime.executeReturningValues("""
                return function(p, kind, name)
                    if kind == 'frame' then p.lblTitle:SetFont(name)
                    elseif kind == 'ccvarslider' then p.GarrysPAD_SourceCaptionFont = name
                    else p:SetFont(name) end
                end
                """).first ?? .nilValue
            for (control, definition) in resolved {
                guard let panel = panels[control.fieldName] else { throw ResourceError.missingControl(control.fieldName) }
                let name = try GMLuaVGUIResourceSchemeFont.install(definition, runtime: runtime)
                _ = try runtime.state.call(assign, arguments: [panel,
                    .string(LuaString(control.controlName!.lowercased())), .string(LuaString(name))])
            }
        }
        // Resolve all coordinates before touching live panels. Reapplying them
        // on idle frames would undo native dragging/resizing and relayout.
        for (name, frame) in frames { try applyFrame(frame, to: name) }
        laidOutViewport = viewport
    }

    private static func usesSchemeFont(_ control: SourceVGUIResource.Control) -> Bool {
        let kind = control.controlName?.lowercased() ?? ""
        return ["label", "button", "textentry", "combobox", "ccvarslider"].contains(kind) ||
            (kind == "frame" && control.value("settitlebarvisible") != "0")
    }

    public func setText(_ text: String, control: String) throws {
        _ = try call(control, "SetText", [.string(LuaString(text))])
    }

    public func text(control: String) throws -> String {
        guard resource.controls.contains(where: {
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
        guard resource.controls.contains(where: {
            $0.fieldName == control && $0.controlName?.lowercased() == "ccvarslider"
        }) else { throw ResourceError.invalidField(control: control, key: "slider") }
    }

    private func requireComboBox(_ control: String) throws {
        guard resource.controls.contains(where: {
            $0.fieldName == control && $0.controlName?.lowercased() == "combobox"
        }) else { throw ResourceError.invalidField(control: control, key: "choice") }
    }

    /// Reads the live control, including user changes, rather than the .res
    /// default. Persisting this value remains the owning settings host's job.
    public func isChecked(control: String) throws -> Bool {
        guard resource.controls.contains(where: {
            $0.fieldName == control && $0.controlName?.lowercased() == "checkbutton"
        }), case let .boolean(value) = try call(control, "GetChecked", []).first else {
            throw ResourceError.invalidField(control: control, key: "selected")
        }
        return value
    }

    public func setProgress(_ fraction: Double, control: String) throws {
        guard fraction.isFinite, (0...1).contains(fraction),
              resource.controls.contains(where: { $0.fieldName == control && $0.controlName?.lowercased() == "progressbar" }) else {
            throw ResourceError.invalidField(control: control, key: "progress")
        }
        _ = try call(control, "SetFraction", [.number(fraction)])
    }

    public func remove() throws {
        for name in panels.keys.sorted() { _ = try call(name, "Remove", []) }
        panels.removeAll()
        laidOutViewport = nil
    }

    private func applyFrame(_ frame: GMLuaPanelRect, to control: String) throws {
        _ = try call(control, "SetPos", [.number(frame.x), .number(frame.y)])
        _ = try call(control, "SetSize", [.number(frame.width), .number(frame.height)])
    }

    @discardableResult
    private func call(_ control: String, _ method: String, _ args: [LuaValue]) throws -> [LuaValue] {
        guard let panel = panels[control] else { throw ResourceError.missingControl(control) }
        let function = try runtime.state.call(index, arguments: [panel, .string(LuaString(method))]).first ?? .nilValue
        return try runtime.state.call(function, arguments: [panel] + args)
    }
}
