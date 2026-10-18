import Foundation
import GModLua

/// CCvarSlider value/binding and unscaled pointer contract over a shipped
/// Derma container. This is not a new global GLua control or replacement DSlider.
/// Proportional schemes and native action-signal delivery remain separate.
struct GMLuaVGUIResourceCvarSlider {
    let conVarName: String
    let minimum: Int32
    let maximum: Int32
    let captionMinimum: Double
    let captionMaximum: Double
    let allowsOutOfRange: Bool

    init(control: SourceVGUIResource.Control, registry: GMLuaConVarRegistry?) throws {
        typealias Failure = GMLuaVGUIResourceInstance.ResourceError
        func invalid(_ key: String) -> Failure { .invalidField(control: control.name, key: key) }
        guard let name = control.value("cvar_name"), !name.isEmpty, name.utf8.count < 64,
              let bounds = registry?.bounds(for: name) else { throw invalid("cvar_name") }
        func number(_ key: String, default fallback: Double) throws -> Double {
            guard let raw = control.value(key) else { return fallback }
            guard let value = Double(raw), value.isFinite else { throw invalid(key) }
            return value
        }
        func boolean(_ key: String) throws -> Bool {
            guard let value = control.value(key) else { return false }
            guard value == "0" || value == "1" else { throw invalid(key) }
            return value == "1"
        }
        var low = try number("minvalue", default: 0)
        var high = try number("maxvalue", default: 1)
        let useConVarBounds = try boolean("use_convar_minmax")
        if let bound = bounds.minimum { low = useConVarBounds ? bound : max(low, bound) }
        if let bound = bounds.maximum { high = useConVarBounds ? bound : min(high, bound) }
        // The native slider stores signed int ticks at a scale of 100. Reject
        // degenerate/nonfinite configurations rather than divide by zero or
        // silently replace a reversed resource range with a guessed one.
        guard let lower = Int32(exactly: (low * 100).rounded(.towardZero)),
              let upper = Int32(exactly: (high * 100).rounded(.towardZero)), lower < upper else {
            throw invalid("minvalue/maxvalue")
        }
        conVarName = name
        minimum = lower
        maximum = upper
        captionMinimum = low
        captionMaximum = high
        allowsOutOfRange = try boolean("allowoutofrange")
    }

    func install(runtime: GMLuaRuntime, panel: LuaValue, scheme: SourceVGUIScheme?) throws {
        let palette = LuaTable()
        if let scheme {
            for key in ["Slider.NobColor", "Slider.TextColor", "Slider.TrackColor",
                        "Slider.DisabledTextColor1", "Slider.DisabledTextColor2"] {
                let color = try scheme.color(key)
                let record = LuaTable()
                for (name, value) in [("r", color.red), ("g", color.green), ("b", color.blue), ("a", color.alpha)] {
                    try runtime.state.setRawTableValue(.number(value), for: .string(LuaString(name)), in: record)
                }
                try runtime.state.setRawTableValue(.table(record), for: .string(LuaString(key)), in: palette)
            }
        }
        let configure = try runtime.executeReturningValues(Self.source,
            sourceName: "@garryspad/resource_cvar_slider.lua").first ?? .nilValue
        _ = try runtime.state.call(configure, arguments: [panel, .string(LuaString(conVarName)),
            .number(Double(minimum)), .number(Double(maximum)), .boolean(allowsOutOfRange),
            .number(captionMinimum), .number(captionMaximum), .table(palette)])
    }

    private static let source = """
        return function(p, name, low, high, allowOutside, captionLow, captionHigh, palette)
            local cvar = assert(GetConVar(name))
            local s = { raw = low, initial = low, last = low,
                start = 0, current = 0, modified = false, updating = false }
            local function trunc(v) if v < 0 then return math.ceil(v) end return math.floor(v) end
            local function displayTicks(v)
                s.raw = math.Clamp(trunc(v), low, high)
                s.updating = true
                p:SetSlideX((s.raw - low) / (high - low))
                s.updating = false
                p.Knob:SetPos(math.floor(math.max(0, p:GetWide() - 16) * p:GetSlideX() + 0.5), 2)
            end
            local function display(v) displayTicks(v * 100) end
            p:SetLockY(0.5)
            function p:HasBeenModified()
                if s.raw ~= s.initial then s.modified = true end
                return s.modified
            end
            function p:GetSliderValue()
                if allowOutside then return s.current end
                return s.raw / 100
            end
            function p:SetSliderValue(v)
                display(v)
                s.last = s.raw
                if s.current ~= v then s.current = v; s.modified = true end
            end
            function p:Reset()
                s.start = cvar:GetFloat()
                s.current = s.start
                display(s.start)
                s.initial = s.raw
                s.last = s.raw
            end
            function p:ApplyChanges()
                if not s.modified then return end
                s.initial = s.raw
                s.start = allowOutside and s.current or s.raw / 100
                cvar:SetFloat(s.start)
            end
            local function moved(ticks)
                displayTicks(ticks)
                if p:HasBeenModified() and s.last ~= s.raw then
                    s.last = s.raw
                    s.current = s.raw / 100
                end
            end
            function p:OnValueChanged(x, y)
                if not s.updating then moved(low + math.Clamp(x, 0, 1) * (high - low)) end
            end
            -- Unscaled Source Slider geometry: 8px thumb, y=8/h=4 track,
            -- eleven ticks and two decimal captions. Dynamic scheme borders
            -- and proportional QuickPropScale are not supplied by this adapter.
            p.Knob:SetSize(8, 16)
            -- Source's thumb is painted, not an independent input button.
            p.Knob:SetMouseInputEnabled(false)
            p.Knob:SetKeyboardInputEnabled(false)
            local function thumbX()
                return math.floor(math.max(0, p:GetWide() - 16) * p:GetSlideX() + 0.5)
            end
            p.Knob.Paint = function(knob, w, h)
                local color = palette['Slider.NobColor'] or knob:GetSkin().colNumSliderNotch
                surface.SetDrawColor(color.r, color.g, color.b, color.a)
                surface.DrawRect(0, 0, w, h)
            end
            p.PerformLayout = function(self, w, h)
                self.Knob:SetPos(thumbX(), 2)
            end
            -- The command renderer snapshots child geometry before Paint.
            -- Synchronize on the visible frame's Think boundary so an external
            -- ConVar update moves the thumb in that same captured frame.
            p.Think = function(self)
                local owner = self
                while IsValid(owner) do
                    if not owner:IsVisible() then return end
                    owner = owner:GetParent()
                end
                local current = cvar:GetFloat()
                if current ~= s.start then
                    s.start = current; s.current = current
                    display(current)
                    s.initial = s.raw
                end
            end
            p.Paint = function(self, w, h)
                local enabled = self:IsEnabled()
                local color = palette[enabled and 'Slider.TextColor' or 'Slider.DisabledTextColor1']
                    or self:GetSkin().colNumSliderNotch
                local track = palette['Slider.TrackColor'] or Color(0, 0, 0, 128)
                surface.SetDrawColor(track.r, track.g, track.b, track.a)
                surface.DrawRect(0, 8, math.max(0, w - 8), 4)
                if not enabled and palette['Slider.DisabledTextColor2'] then
                    surface.SetDrawColor(color.r, color.g, color.b, color.a)
                    for i = 0, 10 do
                        surface.DrawRect(math.floor(4 + i * math.max(0, w - 16) / 10) + 1, 17, 1, 5)
                    end
                    local shadow = palette['Slider.DisabledTextColor2']
                    surface.SetDrawColor(shadow.r, shadow.g, shadow.b, shadow.a)
                else
                    surface.SetDrawColor(color.r, color.g, color.b, color.a)
                end
                for i = 0, 10 do
                    surface.DrawRect(math.floor(4 + i * math.max(0, w - 16) / 10), 16, 1, 5)
                end
                surface.SetFont(self.GarrysPAD_SourceCaptionFont or 'Default')
                surface.SetTextColor(color.r, color.g, color.b, color.a)
                surface.SetTextPos(0, 20)
                surface.DrawText(string.format('%.2f', captionLow))
                local right = string.format('%.2f', captionHigh)
                local rw = surface.GetTextSize(right)
                surface.SetTextPos(math.max(0, w - 8 - rw), 20)
                surface.DrawText(right)
            end
            -- Native Slider defaults to no drag-on-reposition: clicking the
            -- track jumps, while only pressing within the thumb captures drag.
            function p:OnMousePressed(button)
                if not self:IsEnabled() then return end
                self:RequestFocus()
                local x = trunc(self:CursorPos())
                local thumb = thumbX()
                if x >= thumb and x < thumb + 8 then
                    s.dragging = true; s.dragStart = x; s.thumbStart = thumb
                    self:MouseCapture(true)
                elseif self:GetWide() > 9 then
                    local fraction = math.Clamp(x / (self:GetWide() - 9), 0, 1)
                    moved(trunc(low + fraction * (high - low) + 0.5))
                end
            end
            function p:OnCursorMoved(x, y)
                if not s.dragging then return end
                local current = trunc(self:CursorPos())
                local pixels = self:GetWide() - 16
                local fraction = pixels ~= 0 and (s.thumbStart + current - s.dragStart) / pixels or 0
                moved(trunc(low + fraction * (high - low)))
            end
            function p:OnMouseReleased(button)
                if s.dragging then s.dragging = false; self:MouseCapture(false) end
                if self:IsEnabled() then self:ApplyChanges() end
            end
            function p:OnKeyCodeTyped(code)
                if code == KEY_LEFT or code == KEY_DOWN then moved(s.raw - 1)
                elseif code == KEY_RIGHT or code == KEY_UP then moved(s.raw + 1)
                elseif code == KEY_PAGEDOWN then moved(s.raw - trunc((high - low) / 10))
                elseif code == KEY_PAGEUP then moved(s.raw + trunc((high - low) / 10))
                elseif code == KEY_HOME then moved(low)
                elseif code == KEY_END then moved(high) end
            end
            p:Reset()
        end
        """
}
