local PANEL = {}

function PANEL:Init()
    self.SchemeCalls = 0
    self.LayoutCalls = 0
    self:SetText("initial")
    self:ApplySchemeSettings()
end

function PANEL:ApplySchemeSettings()
    self.SchemeCalls = self.SchemeCalls + 1
    self:SetFontInternal("DermaDefault")
    self:SetFGColor(12, 34, 56, 78)
end

function PANEL:PerformLayout(width, height)
    self.LayoutCalls = self.LayoutCalls + 1
    self.LastLayoutWidth = width
    self.LastLayoutHeight = height
    self:ApplySchemeSettings()
end

vgui.Register("FixtureLabel", PANEL, "Label")

FIXTURE_LABEL = assert(vgui.Create("FixtureLabel"))
FIXTURE_LABEL:SetSize(160, 24)
assert(FIXTURE_LABEL:GetFont() == "DermaDefault")
assert(FIXTURE_LABEL:GetText() == "initial")
assert(FIXTURE_LABEL:GetValue() == "initial")
assert(FIXTURE_LABEL:GetContentAlignment() == 5)
assert(FIXTURE_LABEL.SchemeCalls == 1)

local foreground = FIXTURE_LABEL:GetFGColor()
assert(foreground.r == 12 and foreground.g == 34)
assert(foreground.b == 56 and foreground.a == 78)

FIXTURE_LABEL:SetFGColor({ r = 91, g = 92, b = 93, a = 94 })
foreground = FIXTURE_LABEL:GetFGColor()
assert(foreground.r == 91 and foreground.g == 92)
assert(foreground.b == 93 and foreground.a == 94)

local binary = string.char(255, 0, 128) .. "label"
FIXTURE_LABEL:SetText(binary)
assert(FIXTURE_LABEL:GetText() == binary)

FIXTURE_LABEL:SetText(string.rep("L", 1030))
assert(#FIXTURE_LABEL:GetText() == 1023)
assert(#FIXTURE_LABEL:GetValue() == 1023)

FIXTURE_LABEL:SetContentAlignment(9)
assert(FIXTURE_LABEL:GetContentAlignment() == 9)
local ok = pcall(function() FIXTURE_LABEL:SetContentAlignment(10) end)
assert(ok == false)

local textEntry = assert(vgui.Create("TextEntry"))
local longEntryText = string.rep("E", 8200) .. string.char(255)
textEntry:SetText(longEntryText)
assert(textEntry:GetText() == longEntryText)
assert(#textEntry:GetValue() == 8092)
textEntry:SetFontInternal("EntryFont")
assert(textEntry:GetFont() == "EntryFont")

local richText = assert(vgui.Create("RichText"))
richText:SetText(string.rep("R", 1100))
assert(#richText:GetText() == 1023)

local rawPanel = assert(vgui.Create("Panel"))
ok = pcall(function() rawPanel:SetText("must not be accepted") end)
assert(ok == false)
ok = pcall(function() rawPanel:SetFontInternal("must not be accepted") end)
assert(ok == false)

GLUA_LABEL_ENGINE_CONTROL_REGRESSION_READY = true
