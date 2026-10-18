import GModLua

/// Resource-only Source CheckButton presentation over the shipped DButton
/// input/capture path. Never replaces the global Derma checkbox or skin.
enum GMLuaVGUIResourceSchemeCheckButton {
    static func install(runtime: GMLuaRuntime, panel: LuaValue, scheme: SourceVGUIScheme) throws {
        let colors = LuaTable()
        for key in ["CheckButton.TextColor", "CheckButton.SelectedTextColor", "CheckButton.HighlightFgColor",
                    "CheckButton.BgColor", "CheckButton.Border1", "CheckButton.Border2", "CheckButton.Check",
                    "CheckButton.DisabledFgColor", "CheckButton.DisabledBgColor",
                    "Label.DisabledFgColor1", "Label.DisabledFgColor2"] {
            let color = try scheme.color(key)
            let record = LuaTable()
            for (name, value) in [("r", color.red), ("g", color.green), ("b", color.blue), ("a", color.alpha)] {
                try runtime.state.setRawTableValue(.number(value), for: .string(LuaString(name)), in: record)
            }
            try runtime.state.setRawTableValue(.table(record), for: .string(LuaString(key)), in: colors)
        }
        let configure = try runtime.executeReturningValues(source,
            sourceName: "@garryspad/resource_scheme_checkbutton.lua").first ?? .nilValue
        _ = try runtime.state.call(configure, arguments: [panel, .table(colors)])
    }

    private static let source = """
        return function(p, c)
            local checked = false
            function p:GetChecked() return checked end
            function p:SetChecked(value) checked = value and true or false end
            function p:DoClick() self:SetChecked(not checked) end
            local function draw(text, font, color, x, y)
                surface.SetFont(font)
                surface.SetTextColor(color.r, color.g, color.b, color.a)
                surface.SetTextPos(x, y)
                surface.DrawText(text)
            end
            p.Paint = function(self, w, h)
                local symbol = self.GarrysPAD_SourceCheckFont
                if not symbol then error('Source CheckButton requires Scheme font layout') end
                local font = self:GetFont()
                local text = self:GetText()
                surface.SetFont(symbol)
                local iw, ih = surface.GetTextSize('g')
                surface.SetFont(font)
                local tw, th = surface.GetTextSize(text)
                local insetX, insetY = self:GetTextInset()
                local align = self:GetContentAlignment()
                local groupWidth = iw + 6 + tw
                local groupHeight = math.max(ih, th)
                local column = (align - 1) % 3
                local row = math.floor((align - 1) / 3)
                local function trunc(v) if v < 0 then return math.ceil(v) end return math.floor(v) end
                local actualColumn = (iw > w or tw > w) and 0 or column
                local x = actualColumn == 0 and 0 or (actualColumn == 1 and trunc((w - groupWidth) / 2) or w - groupWidth)
                local groupY = insetY + (row == 2 and 0 or (row == 1 and trunc((h - groupHeight) / 2) or h - groupHeight))
                local function y(tall)
                    return groupY + (row == 1 and trunc((groupHeight - tall) / 2) or 0)
                end
                -- Label::SetImageAtIndex's offset is BEFORE the image, not a
                -- post-image gap. The text inset applies to the caption only.
                x = x + 6
                local captionX = x + iw + (column == 0 and insetX or (column == 2 and -insetX or 0))
                local imageY = y(ih)
                local enabled = self:IsEnabled()
                -- Native CheckImage layers the Marlett g/e/f background and
                -- border glyphs at (0,1), then selected b at (0,2).
                draw('g', symbol, c[enabled and 'CheckButton.BgColor' or 'CheckButton.DisabledBgColor'], x, imageY + 1)
                draw('e', symbol, c['CheckButton.Border1'], x, imageY + 1)
                draw('f', symbol, c['CheckButton.Border2'], x, imageY + 1)
                if checked then
                    draw('b', symbol, c[enabled and 'CheckButton.Check' or 'CheckButton.DisabledFgColor'], x, imageY + 2)
                end
                if enabled then
                    local role = self.Hovered and 'CheckButton.HighlightFgColor' or
                        (checked and 'CheckButton.SelectedTextColor' or 'CheckButton.TextColor')
                    draw(text, font, c[role], captionX, y(th))
                else
                    draw(text, font, c['Label.DisabledFgColor1'], captionX + 1, y(th) + 1)
                    draw(text, font, c['Label.DisabledFgColor2'], captionX, y(th))
                end
                return true
            end
        end
        """
}
