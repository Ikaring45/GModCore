-- Original synthetic surface texture-handle fixture. No game source is embedded here.
assert(type(surface) == "table")
assert(type(surface.GetTextureID) == "function")
assert(type(surface.SetTexture) == "function")
assert(type(surface.CreateFont) == "function")
assert(type(surface.SetFont) == "function")
assert(type(surface.GetTextSize) == "function")

local first = surface.GetTextureID("gui/corner8")
local repeated = surface.GetTextureID("gui/corner8")
local second = surface.GetTextureID("vgui/white")
assert(type(first) == "number" and first > 0)
assert(repeated == first)
assert(second > 0 and second != first)

surface.SetTexture(second)
SURFACE_SELECTED_TEXTURE = second

local ok = pcall(surface.GetTextureID, {})
assert(not ok)
ok = pcall(surface.SetTexture, "vgui/white")
assert(not ok)
ok = pcall(surface.SetTexture, 0 / 0)
assert(not ok)

surface.CreateFont("MixedCaseFont", {})
surface.SetFont("mixedcasefont")
local defaultWidth, defaultHeight = surface.GetTextSize("AB\nC")
assert(defaultWidth == 13 and defaultHeight == 26)

-- Auto-refresh/re-execution updates the named font. Font lookup follows the
-- Source font dictionary's ASCII case-insensitive name behavior.
surface.CreateFont("MIXEDCASEFONT", {
    font = "Helvetica",
    size = 22,
    weight = 800,
    blursize = 3,
    scanlines = 2,
    antialias = false,
    underline = true,
    italic = true,
    strikeout = true,
    symbol = true,
    rotary = true,
    shadow = true,
    additive = true,
    outline = true,
    extended = true
})
surface.SetFont("MixedCaseFont")
local replacedWidth, replacedHeight = surface.GetTextSize("ABCD")
assert(replacedWidth == 44 and replacedHeight == 22)

surface.SetFont("Trebuchet24")
local builtInWidth, builtInHeight = surface.GetTextSize("")
assert(builtInWidth == 0 and builtInHeight == 24)

ok = pcall(surface.SetFont, "DefinitelyMissingFont")
assert(not ok)
ok = pcall(surface.CreateFont, "BadFont", { size = "large" })
assert(not ok)
ok = pcall(surface.CreateFont, "BadFont", { font = string.rep("x", 32) })
assert(not ok)

GLUA_SURFACE_REGRESSION_OK = true
