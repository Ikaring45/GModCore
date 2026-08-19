-- Original synthetic logical-resource fixture. No game source is embedded here.
assert(type(Material) == "function")
assert(type(render) == "table")
assert(type(render.GetScreenEffectTexture) == "function")

local material, elapsed = Material("pp/copy")
assert(type(material) == "IMaterial")
assert(TypeID(material) == TYPE_MATERIAL)
assert(material:GetName() == "pp/copy")
assert(type(elapsed) == "number" and elapsed >= 0)
assert(Material("pp/copy") == material)

local imported = Material("vgui/example.png", "0000110")
assert(type(imported) == "IMaterial")
assert(imported:GetName() == "vgui/example.png")
assert(imported != Material("vgui/example.png", "0000010"))

local screen0 = render.GetScreenEffectTexture()
local screen0Again = render.GetScreenEffectTexture(0)
local screen1 = render.GetScreenEffectTexture(1)
assert(type(screen0) == "ITexture")
assert(TypeID(screen0) == TYPE_TEXTURE)
assert(screen0 == screen0Again and screen0 != screen1)
assert(screen0:GetName() == "_rt_fullframefb")
assert(screen1:GetName() == "_rt_fullframefb1")

assert(STUDIO_RENDER == 1)
assert(STUDIO_SKIP_DECALS == 268435456)

assert(util.PrecacheSound("ui/synthetic.wav") == nil)
assert(util.PrecacheModel("models/synthetic.mdl") == nil)
assert(PrecacheParticleSystem("synthetic_particle") == nil)

local ok = pcall(Material, {})
assert(not ok)
ok = pcall(render.GetScreenEffectTexture, 4)
assert(not ok)

GLUA_RESOURCE_HANDLE_REGRESSION_OK = true
