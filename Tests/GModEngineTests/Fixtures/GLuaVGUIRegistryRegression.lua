assert(type(vgui) == "table")
assert(FindMetaTable("Panel").MetaName == "Panel")
assert(FindMetaTable("Panel").MetaID == TYPE_PANEL)

local Base = {}
function Base:Init()
    self.baseInitializations = (self.baseInitializations or 0) + 1
end
function Base:InheritedValue()
    return "base"
end

local registeredBase = vgui.Register("FixtureBase", Base, "Panel")
assert(registeredBase == Base)
assert(vgui.GetControlTable("FixtureBase") == Base)
assert(vgui.Exists("FixtureBase"))

local Child = {}
function Child:Init()
    self.childInitializations = (self.childInitializations or 0) + 1
end
function Child:ChildValue()
    return "child"
end

assert(vgui.Register("FixtureChild", Child, "FixtureBase") == Child)
assert(vgui.GetControlTable("FixtureChild") == Child)
assert(rawget(vgui.GetControlTable("FixtureChild"), "InheritedValue") == nil)
assert(not vgui.Exists("MissingControl"))
assert(vgui.GetControlTable("MissingControl") == nil)

local parent = vgui.Create("Panel", nil, "fixture_parent")
local child = vgui.Create("FixtureChild", parent, "fixture_child")
assert(parent != nil and child != nil)
assert(type(parent) == "Panel" and type(child) == "Panel")
assert(TypeID(parent) == TYPE_PANEL and TypeID(child) == TYPE_PANEL)
assert(ispanel(parent) and ispanel(child))
assert(parent:GetName() == "fixture_parent")
assert(child:GetName() == "fixture_child")
assert(child:GetClassName() == "FixtureChild")
assert(child:GetParent() == parent)
assert(child:InheritedValue() == "base")
assert(child:ChildValue() == "child")
assert(child.baseInitializations == 1)
assert(child.childInitializations == 1)

local childTable = child:GetTable()
assert(type(childTable) == "table" and child:GetTable() == childTable)
child.observableField = 73
assert(childTable.observableField == 73)
childTable.fromTable = "visible"
assert(child.fromTable == "visible")

local all = vgui.GetAll()
assert(#all == 2 and all[1] == parent and all[2] == child)
assert(vgui.Create("DefinitelyMissingPanel") == nil)

child:SetParent(nil)
assert(child:GetParent() == nil)
child:SetParent(parent)
assert(child:GetParent() == parent)
local ok, cycleError = pcall(parent.SetParent, parent, child)
assert(not ok and string.find(cycleError, "descendant", 1, true))
assert(parent:GetParent() == nil and child:GetParent() == parent)
child:Remove()
assert(not child:IsValid())
assert(#vgui.GetAll() == 1)
parent:Remove()
assert(not parent:IsValid())
assert(#vgui.GetAll() == 0)

GLUA_VGUI_REGISTRY_REGRESSION_OK = true
