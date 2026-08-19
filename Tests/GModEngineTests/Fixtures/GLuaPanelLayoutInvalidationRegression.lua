local LayoutPanel = {}

function LayoutPanel:Init()
    self.LayoutCalls = 0
end

function LayoutPanel:PerformLayout(width, height)
    self.LayoutCalls = self.LayoutCalls + 1
    self.LastLayoutWidth = width
    self.LastLayoutHeight = height

    if self.RequeueDuringLayout then
        self.RequeueDuringLayout = false
        self:InvalidateLayout()
    end
end

vgui.Register("FixtureLayoutPanel", LayoutPanel, "Panel")

DEFERRED_LAYOUT_PANEL = assert(vgui.Create("FixtureLayoutPanel"))
DEFERRED_LAYOUT_PANEL:SetSize(120.9, 40.8)
assert(DEFERRED_LAYOUT_PANEL:InvalidateLayout() == nil)
assert(DEFERRED_LAYOUT_PANEL:InvalidateLayout(false) == nil)
assert(DEFERRED_LAYOUT_PANEL.LayoutCalls == 0)

IMMEDIATE_LAYOUT_PANEL = assert(vgui.Create("FixtureLayoutPanel"))
IMMEDIATE_LAYOUT_PANEL:SetSize(81.7, 22.4)
assert(IMMEDIATE_LAYOUT_PANEL:InvalidateLayout(true) == nil)
assert(IMMEDIATE_LAYOUT_PANEL.LayoutCalls == 1)
assert(IMMEDIATE_LAYOUT_PANEL.LastLayoutWidth == 81)
assert(IMMEDIATE_LAYOUT_PANEL.LastLayoutHeight == 22)

assert(not pcall(function()
    DEFERRED_LAYOUT_PANEL:InvalidateLayout("now")
end))

REQUEUED_LAYOUT_PANEL = assert(vgui.Create("FixtureLayoutPanel"))
REQUEUED_LAYOUT_PANEL.RequeueDuringLayout = true
REQUEUED_LAYOUT_PANEL:InvalidateLayout(true)
assert(REQUEUED_LAYOUT_PANEL.LayoutCalls == 1)

GLUA_PANEL_LAYOUT_INVALIDATION_FIXTURE_READY = true
