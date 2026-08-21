assert(vgui.Create("DPanel") == nil, "DPanel must not be invented as an engine control")

local DPanel = {}
function DPanel:Init()
    self:SetPaintBorderEnabled(false)
    self:SetPaintBackgroundEnabled(false)
end
derma.DefineControl("DPanel", "synthetic logical panel", DPanel, "Panel")

local parent = assert(vgui.Create("DPanel", nil, "logical_parent"))
local first = assert(vgui.Create("Panel", parent, "first"))
local second = assert(vgui.Create("Panel", parent, "second"))

parent:SetPos(10.25, -4.5)
parent:SetSize(300.9, 120.2)
assert(parent.x == 10.25 and parent.y == -4.5)
assert(parent:GetPos() == 10.25 and select(2, parent:GetPos()) == -4.5)
assert(parent:GetWide() == 300 and parent:GetTall() == 120)
local x, y, width, height = parent:GetBounds()
assert(x == 10.25 and y == -4.5 and width == 300 and height == 120)

parent:SetName("renamed_parent")
assert(parent:GetName() == "renamed_parent")
parent:SetAlpha(127.9)
assert(parent:GetAlpha() == 127)
parent:SetVisible(false)
assert(not parent:IsVisible())
parent:SetMouseInputEnabled(false)
assert(not parent:IsMouseInputEnabled())

assert(parent:ChildCount() == 2)
assert(parent:GetChild(0) == first and parent:GetChild(1) == second)
assert(parent:GetChild(2) == nil)
local children = parent:GetChildren()
assert(#children == 2 and children[1] == first and children[2] == second)
assert(first:HasParent(parent) and not parent:HasParent(first))

parent:SetKeyboardInputEnabled(false)
assert(not parent:IsKeyboardInputEnabled())
assert(not first:IsKeyboardInputEnabled() and not second:IsKeyboardInputEnabled())
parent:SetKeyBoardInputEnabled(true)
assert(parent:IsKeyboardInputEnabled())
assert(first:IsKeyboardInputEnabled() and second:IsKeyboardInputEnabled())

second:SetZPos(12.8)
assert(second:GetZPos() == 12)
second:ParentToHUD()
assert(second:GetParent() == nil)
assert(parent:ChildCount() == 1 and parent:GetChild(0) == first)

parent:Remove()
assert(not parent:IsValid() and parent:IsMarkedForDeletion())
assert(first:IsValid() and not first:IsMarkedForDeletion())
assert(second:IsValid())
second:Remove()
assert(not second:IsValid() and second:IsMarkedForDeletion())
assert(#vgui.GetAll() == 1 and vgui.GetAll()[1] == first)

GLUA_PANEL_ENGINE_DEFERRED_PARENT = parent
GLUA_PANEL_ENGINE_DEFERRED_CHILD = first
GLUA_PANEL_ENGINE_DEFERRED_SECOND = second

GLUA_PANEL_ENGINE_CONTROL_REGRESSION_OK = true
