assert(type(derma) == "table")
assert(derma.Controls == derma.GetControlList())
assert(type(derma.SkinList) == "table")

-- Independent fixture implementation of the observable copy behavior needed
-- below. The real core normally supplies table.Copy before Derma, while this
-- focused test intentionally starts without the installed GMod bootstrap.
local function fixtureTableCopy(input, visited)
    if input == nil then return nil end

    local result = setmetatable({}, debug.getmetatable(input))
    for key, candidate in pairs(input) do
        local replacement = candidate
        if type(candidate) == "table" then
            visited = visited or {}
            replacement = visited[candidate]
            if replacement == nil then
                visited[input] = result
                replacement = fixtureTableCopy(candidate, visited)
            end
        end
        result[key] = replacement
    end
    return result
end
table.Copy = fixtureTableCopy

local Base = {}
function Base:Init()
    self.baseInitialized = true
end
function Base:Value()
    return "old"
end

assert(derma.DefineControl("DermaFixture", "fixture control", Base, "Panel") == Base)
assert(DermaFixture == Base)
assert(vgui.GetControlTable("DermaFixture") == Base)
local metadata = derma.GetControlList().DermaFixture
assert(metadata.ClassName == "DermaFixture")
assert(metadata.Description == "fixture control")
assert(metadata.BaseClass == "Panel")
assert(Base.Derma == metadata)

local panel = vgui.Create("DermaFixture", nil, "derma_fixture")
assert(panel.baseInitialized and panel:Value() == "old")
panel.AllowAutoRefresh = true
function panel:PreAutoRefresh() self.preRefresh = (self.preRefresh or 0) + 1 end
function panel:PostAutoRefresh() self.postRefresh = (self.postRefresh or 0) + 1 end

local Reloaded = {}
function Reloaded:Value()
    return "new"
end
derma.DefineControl("DermaFixture", "reloaded", Reloaded, "Panel")
assert(panel:Value() == "new")
assert(panel.preRefresh == 1 and panel.postRefresh == 1)
assert(derma.GetControlList().DermaFixture.Description == "reloaded")

local Default = {
    Accent = "blue",
    tex = { Button = "texture" }
}
function Default:PaintFixture(target, w, h)
    target.skinPaint = w + h
    return "painted"
end
derma.DefineSkin("Default", "default fixture skin", Default)

local Derived = { Own = "value" }
derma.DefineSkin("Derived", "derived fixture skin", Derived)
assert(derma.GetNamedSkin("Default") == Default)
assert(derma.GetNamedSkin("Derived") == Derived)
assert(Derived.Accent == "blue" and Derived.Own == "value")
assert(derma.GetNamedSkin("Missing") == nil)
assert(derma.GetDefaultSkin() == Default)
local skinCopy = derma.GetSkinTable()
assert(skinCopy != derma.SkinList)
assert(skinCopy.Default != Default and skinCopy.Derived != Derived)
assert(skinCopy.Default.tex != Default.tex)
assert(skinCopy.Default.tex.Button == "texture")
assert(skinCopy.Derived.Own == "value" and skinCopy.Derived.Accent == "blue")

Default.self = Default
Default.shared = Default.tex
Default.otherShared = Default.tex
Default.emptyShared = {}
Default.otherEmptyShared = Default.emptyShared
skinCopy = derma.GetSkinTable()
assert(skinCopy.Default.self == skinCopy.Default)
assert(skinCopy.Default.shared != skinCopy.Default.otherShared)
assert(skinCopy.Default.shared != Default.tex)
assert(skinCopy.Default.emptyShared != skinCopy.Default.otherEmptyShared)
assert(getmetatable(skinCopy.Derived) == getmetatable(Derived))

panel.GetSkin = function() return Derived end
assert(derma.Color("Accent", panel, "fallback") == "blue")
assert(derma.Color("Missing", panel, "fallback") == "fallback")
assert(derma.SkinTexture("Button", panel, "fallback") == "texture")
assert(derma.SkinTexture("Missing", panel, "fallback") == "fallback")
assert(derma.SkinHook("Paint", "Fixture", panel, 4, 5) == "painted")
assert(panel.skinPaint == 9)

local Hooked = {}
Derma_Hook(Hooked, "Paint", "Paint", "Fixture")
derma.DefineControl("DermaHookedFixture", "hooked", Hooked, "Panel")
local hooked = vgui.Create("DermaHookedFixture")
hooked.GetSkin = function() return Default end
assert(hooked:Paint(2, 3) == "painted" and hooked.skinPaint == 5)

local ConVarPanel = {}
Derma_Install_Convar_Functions(ConVarPanel)
function ConVarPanel:SetValue(value) self.observedValue = value end
derma.DefineControl("DermaConVarFixture", "convar", ConVarPanel, "Panel")
local convarPanel = vgui.Create("DermaConVarFixture")
local commandName, commandValue
RunConsoleCommand = function(name, value) commandName, commandValue = name, value end
GetConVarString = function() return "hello" end
GetConVarNumber = function() return 12.5 end
convarPanel:SetConVar("fixture_value")
convarPanel:ConVarChanged(7)
assert(commandName == "fixture_value" and commandValue == "7")
convarPanel:ConVarStringThink()
assert(convarPanel.observedValue == "hello")
convarPanel:ConVarNumberThink()
assert(convarPanel.observedValue == 12.5)

local before = derma.SkinChangeIndex()
derma.RefreshSkins()
assert(derma.SkinChangeIndex() == before + 1)

GLUA_DERMA_REGISTRY_REGRESSION_OK = true
