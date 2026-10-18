import GModLua

/// Opt-in authored GameUI colors for resource controls. Never changes the
/// global Derma skin, whose Q/C controls use a different authored palette.
enum GMLuaVGUIResourceSchemeColors {
    static func install(runtime: GMLuaRuntime, panel: LuaValue,
        control: SourceVGUIResource.Control, scheme: SourceVGUIScheme) throws {
        let kind = control.controlName?.lowercased() ?? ""
        let roles: [String]
        switch kind {
        case "label":
            roles = ["Label.TextColor", "Label.TextDullColor", "Label.TextBrightColor", "Label.DisabledFgColor1"]
        case "button":
            roles = ["Button.TextColor", "Button.BgColor", "Button.ArmedTextColor", "Button.ArmedBgColor",
                "Button.DepressedTextColor", "Button.DepressedBgColor", "Label.DisabledFgColor1"]
        case "frame" where control.value("settitlebarvisible") == "0":
            roles = ["Frame.BgColor", "Frame.OutOfFocusBgColor"]
        case "progressbar": roles = ["ProgressBar.FgColor", "ProgressBar.BgColor"]
        default: return
        }
        let palette = LuaTable()
        func set(_ key: String, _ color: GMLuaPanelColorSnapshot) throws {
            let record = LuaTable()
            for (name, value) in [("r", color.red), ("g", color.green), ("b", color.blue), ("a", color.alpha)] {
                try runtime.state.setRawTableValue(.number(value), for: .string(LuaString(name)), in: record)
            }
            try runtime.state.setRawTableValue(.table(record), for: .string(LuaString(key)), in: palette)
        }
        for role in roles { try set(role, scheme.color(role)) }
        func setBorder(_ key: String, _ name: String) throws {
            let lines = LuaTable()
            for (index, segment) in try scheme.borderSegments(name).enumerated() {
                let record = LuaTable()
                try runtime.state.setRawTableValue(.string(LuaString(segment.side)), for: .string("side"), in: record)
                for (field, value) in [("depth", segment.depth), ("start", segment.startOffset), ("finish", segment.endOffset)] {
                    try runtime.state.setRawTableValue(.number(Double(value)), for: .string(LuaString(field)), in: record)
                }
                for (field, value) in [("r", segment.color.red), ("g", segment.color.green), ("b", segment.color.blue), ("a", segment.color.alpha)] {
                    try runtime.state.setRawTableValue(.number(value), for: .string(LuaString(field)), in: record)
                }
                try runtime.state.setRawTableValue(.table(record), for: .number(Double(index + 1)), in: lines)
            }
            try runtime.state.setRawTableValue(.table(lines), for: .string(LuaString(key)), in: palette)
        }
        if kind == "frame" { try setBorder("border", "FrameBorder") }
        if kind == "button" {
            try setBorder("border", "ButtonBorder")
            try setBorder("downBorder", "ButtonDepressedBorder")
        }
        let configure = try runtime.executeReturningValues(Self.source,
            sourceName: "@garryspad/resource_scheme_colors.lua").first ?? .nilValue
        _ = try runtime.state.call(configure, arguments: [panel, .string(LuaString(kind)), .table(palette),
            .boolean(control.value("dulltext") == "1"), .boolean(control.value("brighttext") == "1"),
            .boolean(control.value("paintbackground") != "0"), .boolean(control.value("paintborder") != "0")])
    }

    private static let source = """
        return function(p, kind, c, dull, bright, paintBackground, paintBorder)
            local function fill(color, x, y, w, h)
                surface.SetDrawColor(color.r, color.g, color.b, color.a)
                surface.DrawRect(x, y, w, h)
            end
            local function border(lines, w, h)
                for _, line in ipairs(lines) do
                    if line.side == 'left' then fill(line, line.depth, line.start, 1, math.max(0, h - line.start - line.finish))
                    elseif line.side == 'right' then fill(line, w - 1 - line.depth, line.start, 1, math.max(0, h - line.start - line.finish))
                    elseif line.side == 'top' then fill(line, line.start, line.depth, math.max(0, w - line.start - line.finish), 1)
                    else fill(line, line.start, h - 1 - line.depth, math.max(0, w - line.start - line.finish), 1) end
                end
            end
            if kind == 'label' or kind == 'button' then
                local function textColor(self)
                    if not self:IsEnabled() then return c['Label.DisabledFgColor1'] end
                    if kind == 'label' then
                        if dull then return c['Label.TextDullColor'] end
                        if bright then return c['Label.TextBrightColor'] end
                        return c['Label.TextColor']
                    end
                    if self:IsDown() then return c['Button.DepressedTextColor'] end
                    if self.Hovered then return c['Button.ArmedTextColor'] end
                    return c['Button.TextColor']
                end
                p.UpdateColours = function(self) self:SetTextColor(textColor(self)) end
                local think = p.Think
                p.Think = function(self) if think then think(self) end self:UpdateColours() end
                p:UpdateColours()
            end
            if kind == 'frame' then
                p.Paint = function(self, w, h)
                    if paintBackground then fill(c[self:HasHierarchicalFocus() and 'Frame.BgColor' or 'Frame.OutOfFocusBgColor'], 0, 0, w, h) end
                    if paintBorder then border(c.border, w, h) end
                    return true
                end
            elseif kind == 'button' then
                p.Paint = function(self, w, h)
                    local down = self:IsDown()
                    local state = down and 'Button.DepressedBgColor' or
                        (self:IsEnabled() and self.Hovered and 'Button.ArmedBgColor' or 'Button.BgColor')
                    if paintBackground then fill(c[state], 0, 0, w, h) end
                    if paintBorder then border(c[down and 'downBorder' or 'border'], w, h) end
                    return false
                end
            elseif kind == 'progressbar' then
                p.Paint = function(self, w, h)
                    if paintBackground then fill(c['ProgressBar.BgColor'], 0, 0, w, h) end
                    local count = math.floor(math.floor(w / 12) * self:GetFraction())
                    for i = 0, count - 1 do fill(c['ProgressBar.FgColor'], 4 + i * 12, 4, 8, math.max(0, h - 8)) end
                    return true
                end
            end
        end
        """
}
