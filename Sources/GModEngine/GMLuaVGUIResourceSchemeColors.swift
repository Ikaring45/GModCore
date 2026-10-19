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
        case "frame":
            roles = ["Frame.BgColor", "Frame.OutOfFocusBgColor"]
                + (control.value("settitlebarvisible") == "0" ? [] : [
                    "FrameTitleBar.TextColor", "FrameTitleBar.BgColor", "FrameTitleBar.DisabledTextColor", "FrameTitleBar.DisabledBgColor",
                    "FrameTitleButton.FgColor", "FrameTitleButton.BgColor", "FrameTitleButton.DisabledFgColor", "FrameTitleButton.DisabledBgColor"
                ])
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
        let titledFrame = kind == "frame" && control.value("settitlebarvisible") != "0"
        if titledFrame {
            for key in ["FrameSystemButton.Icon", "FrameSystemButton.DisabledIcon"] {
                if let icon = scheme.string(key), !icon.isEmpty {
                    throw GMLuaVGUIResourceInstance.ResourceError.invalidField(control: control.name, key: key)
                }
            }
            guard let inset = Int32(scheme.string("Frame.TitleTextInsetX") ?? "28") else {
                throw GMLuaVGUIResourceInstance.ResourceError.invalidField(control: control.name, key: "Frame.TitleTextInsetX")
            }
            try runtime.state.setRawTableValue(.number(Double(inset)), for: .string("titleInset"), in: palette)
            try setBorder("titleBorder", "TitleButtonBorder")
            try setBorder("titleDownBorder", "TitleButtonDepressedBorder")
            try setBorder("titleInactiveBorder", "TitleButtonDisabledBorder")
        }
        if kind == "button" {
            try setBorder("border", "ButtonBorder")
            try setBorder("downBorder", "ButtonDepressedBorder")
        }
        let configure = try runtime.executeReturningValues(Self.source,
            sourceName: "@garryspad/resource_scheme_colors.lua").first ?? .nilValue
        _ = try runtime.state.call(configure, arguments: [panel, .string(LuaString(kind)), .table(palette),
            .boolean(control.value("dulltext") == "1"), .boolean(control.value("brighttext") == "1"),
            .boolean(control.value("paintbackground") != "0"), .boolean(control.value("paintborder") != "0"),
            .boolean(titledFrame)])
    }

    private static let source = """
        return function(p, kind, c, dull, bright, paintBackground, paintBorder, titledFrame)
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
                if titledFrame then
                    p.lblTitle:SetContentAlignment(7)
                    p.lblTitle:SetTextInset(0, 0)
                    p.lblTitle:SetVisible(paintBackground)
                    p.lblTitle.UpdateColours = function(label)
                        label:SetTextColor(c[p:HasHierarchicalFocus() and 'FrameTitleBar.TextColor' or 'FrameTitleBar.DisabledTextColor'])
                    end
                    local close = p.btnClose
                    close:SetText('r')
                    close:SetContentAlignment(7)
                    close:SetTextInset(2, 1)
                    close.UpdateColours = function(button)
                        button:SetTextColor(c[p:HasHierarchicalFocus() and 'FrameTitleButton.FgColor' or 'FrameTitleButton.DisabledFgColor'])
                    end
                    close.Paint = function(button, w, h)
                        if not p.GarrysPAD_SourceFrameButtonFont then error('Source Frame requires Scheme font layout') end
                        local active = p:HasHierarchicalFocus()
                        fill(c[active and 'FrameTitleButton.BgColor' or 'FrameTitleButton.DisabledBgColor'], 0, 0, w, h)
                        local edge = not active and 'titleInactiveBorder' or (button:IsDown() and 'titleDownBorder' or 'titleBorder')
                        border(c[edge], w, h)
                        return false
                    end
                    local think = p.Think
                    local lastFocus = p:HasHierarchicalFocus()
                    p.Think = function(self)
                        if think then think(self) end
                        local focused = self:HasHierarchicalFocus()
                        if focused ~= lastFocus then
                            lastFocus = focused
                            self.lblTitle:UpdateColours()
                            self.btnClose:UpdateColours()
                        end
                    end
                    p.lblTitle:UpdateColours()
                    close:UpdateColours()
                    -- Normal-caption, unscaled Frame.cpp geometry. Unsupported
                    -- native OS minimize/maximize/system-menu actions stay hidden.
                    p.PerformLayout = function(self)
                        self.btnClose:SetPos(self:GetWide() - 25, 8)
                        self.btnClose:SetSize(18, 18)
                        surface.SetFont(self.lblTitle:GetFont())
                        local _, tall = surface.GetTextSize('M')
                        self.lblTitle:SetPos(c.titleInset, 9)
                        self.lblTitle:SetSize(math.max(0, self:GetWide() - 72), tall)
                    end
                end
                p.Paint = function(self, w, h)
                    if titledFrame and not self.GarrysPAD_SourceFrameButtonFont then error('Source Frame requires Scheme font layout') end
                    local active = self:HasHierarchicalFocus()
                    if paintBackground then
                        fill(c[active and 'Frame.BgColor' or 'Frame.OutOfFocusBgColor'], 0, 0, w, h)
                        if titledFrame then
                            fill(c[active and 'FrameTitleBar.BgColor' or 'FrameTitleBar.DisabledBgColor'], 5, 5, math.max(0, w - 10), 23)
                        end
                    end
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
