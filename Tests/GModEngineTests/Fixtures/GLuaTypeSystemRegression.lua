local expectedConstants = {
    TYPE_NONE = -1,
    TYPE_INVALID = -1,
    TYPE_NIL = 0,
    TYPE_BOOL = 1,
    TYPE_LIGHTUSERDATA = 2,
    TYPE_NUMBER = 3,
    TYPE_STRING = 4,
    TYPE_TABLE = 5,
    TYPE_FUNCTION = 6,
    TYPE_USERDATA = 7,
    TYPE_THREAD = 8,
    TYPE_ENTITY = 9,
    TYPE_VECTOR = 10,
    TYPE_ANGLE = 11,
    TYPE_PHYSOBJ = 12,
    TYPE_SAVE = 13,
    TYPE_RESTORE = 14,
    TYPE_DAMAGEINFO = 15,
    TYPE_EFFECTDATA = 16,
    TYPE_MOVEDATA = 17,
    TYPE_RECIPIENTFILTER = 18,
    TYPE_USERCMD = 19,
    TYPE_SCRIPTEDVEHICLE = 20,
    TYPE_MATERIAL = 21,
    TYPE_PANEL = 22,
    TYPE_PARTICLE = 23,
    TYPE_PARTICLEEMITTER = 24,
    TYPE_TEXTURE = 25,
    TYPE_USERMSG = 26,
    TYPE_CONVAR = 27,
    TYPE_IMESH = 28,
    TYPE_MATRIX = 29,
    TYPE_SOUND = 30,
    TYPE_PIXELVISHANDLE = 31,
    TYPE_DLIGHT = 32,
    TYPE_VIDEO = 33,
    TYPE_FILE = 34,
    TYPE_LOCOMOTION = 35,
    TYPE_PATH = 36,
    TYPE_NAVAREA = 37,
    TYPE_SOUNDHANDLE = 38,
    TYPE_NAVLADDER = 39,
    TYPE_PARTICLESYSTEM = 40,
    TYPE_PROJECTEDTEXTURE = 41,
    TYPE_PHYSCOLLIDE = 42,
    TYPE_SURFACEINFO = 43,
    TYPE_COUNT = 44,
    TYPE_COLOR = 255
}

for name, value in pairs(expectedConstants) do
    assert(_G[name] == value, name .. " ABI mismatch")
end

-- Primitive behavior remains the same as Lua 5.1. TypeID uses the numeric
-- GLua ABI and treats a missing argument as nil.
assert(type(nil) == "nil")
assert(type(false) == "boolean")
assert(type(1) == "number")
assert(type("x") == "string")
assert(type({}) == "table")
assert(type(function() end) == "function")
assert(type(coroutine.create(function() end)) == "thread")
assert(TypeID() == TYPE_NIL)
assert(TypeID(nil) == TYPE_NIL)
assert(TypeID(false) == TYPE_BOOL)
assert(TypeID(1) == TYPE_NUMBER)
assert(TypeID("x") == TYPE_STRING)
assert(TypeID({}) == TYPE_TABLE)
assert(TypeID(function() end) == TYPE_FUNCTION)
assert(TypeID(coroutine.create(function() end)) == TYPE_THREAD)

assert(isstring("x") and not isstring(1))
assert(isnumber(1) and not isnumber("1"))
assert(istable({}) and not istable(TEST_VECTOR))
assert(isfunction(function() end) and not isfunction({}))
assert(isbool(true) and isbool(false) and not isbool(nil) and not isbool(0))

-- Raw Lua userdata keeps GMod's capitalized fallback name.
local rawUserdata = newproxy()
assert(type(rawUserdata) == "UserData")
assert(TypeID(rawUserdata) == TYPE_USERDATA)

local entityMeta = assert(FindMetaTable("Entity"))
local playerMeta = assert(FindMetaTable("Player"))
local vectorMeta = assert(FindMetaTable("Vector"))
local angleMeta = assert(FindMetaTable("Angle"))
assert(FindMetaTable("DefinitelyMissing") == nil)
assert(entityMeta.MetaName == "Entity" and entityMeta.MetaID == TYPE_ENTITY)
assert(playerMeta.MetaName == "Player" and playerMeta.MetaID == TYPE_ENTITY)
assert(playerMeta.MetaBaseClass == entityMeta)
assert(vectorMeta.MetaName == "Vector" and vectorMeta.MetaID == TYPE_VECTOR)
assert(angleMeta.MetaName == "Angle" and angleMeta.MetaID == TYPE_ANGLE)

-- Engine-backed userdata uses its real metatable. Entity subclasses retain
-- their own type() name while sharing TYPE_ENTITY and isentity semantics.
assert(type(TEST_VECTOR) == "Vector" and TypeID(TEST_VECTOR) == TYPE_VECTOR)
assert(type(TEST_ANGLE) == "Angle" and TypeID(TEST_ANGLE) == TYPE_ANGLE)
assert(type(TEST_ENTITY) == "Entity" and TypeID(TEST_ENTITY) == TYPE_ENTITY)
assert(type(TEST_PLAYER) == "Player" and TypeID(TEST_PLAYER) == TYPE_ENTITY)
assert(type(TEST_WEAPON) == "Weapon" and TypeID(TEST_WEAPON) == TYPE_ENTITY)
assert(type(TEST_PANEL) == "Panel" and TypeID(TEST_PANEL) == TYPE_PANEL)
assert(isvector(TEST_VECTOR) and not isvector(TEST_ANGLE))
assert(isangle(TEST_ANGLE) and not isangle(TEST_VECTOR))
assert(ispanel(TEST_PANEL) and not ispanel(TEST_ENTITY))
assert(isentity(TEST_ENTITY))
assert(isentity(TEST_PLAYER))
assert(isentity(TEST_WEAPON))
assert(not isentity(TEST_PANEL))
assert(IsEntity == isentity and IsEntity(TEST_PLAYER))

-- A table cannot impersonate a native type, even when either the table or its
-- own metatable contains apparently correct MetaName/MetaID fields.
local forgedFields = { MetaName = "Vector", MetaID = TYPE_VECTOR }
local forgedMetatable = setmetatable({}, { MetaName = "Angle", MetaID = TYPE_ANGLE })
assert(type(forgedFields) == "table" and TypeID(forgedFields) == TYPE_TABLE)
assert(type(forgedMetatable) == "table" and TypeID(forgedMetatable) == TYPE_TABLE)
assert(not isvector(forgedFields) and not isangle(forgedMetatable))

-- RegisterMetaTable assigns canonical fields, preserves identity and rejects
-- attempts to replace both engine and previously registered metatables.
local customMeta = { MetaName = "forged", MetaID = 12345 }
assert(select("#", RegisterMetaTable("CustomABI", customMeta)) == 0)
assert(FindMetaTable("CustomABI") == customMeta)
assert(customMeta.MetaName == "CustomABI" and customMeta.MetaID == TYPE_COUNT)
local okDuplicate = pcall(RegisterMetaTable, "CustomABI", {})
local okBuiltin = pcall(RegisterMetaTable, "Vector", {})
local okBadName = pcall(RegisterMetaTable, {}, {})
local okBadTable = pcall(RegisterMetaTable, "BadTable", false)
assert(not okDuplicate and not okBuiltin and not okBadName and not okBadTable)

customMeta.__index = customMeta
customMeta.IsValid = function() return true end
local customUserdata = newproxy()
debug.setmetatable(customUserdata, customMeta)
assert(type(customUserdata) == "CustomABI")
assert(TypeID(customUserdata) == customMeta.MetaID)
assert(IsValid(customUserdata))

-- Color is intentionally a normal Lua table. TYPE_COLOR=255 is a net.WriteType
-- discriminator rather than the result of TypeID.
local colorMeta = {}
RegisterMetaTable("Color", colorMeta)
local color = setmetatable({ r = 1, g = 2, b = 3, a = 255 }, colorMeta)
assert(colorMeta.MetaName == "Color" and colorMeta.MetaID == TYPE_COUNT + 1)
assert(type(color) == "table" and TypeID(color) == TYPE_TABLE)

-- The native functions use ILuaBase::CheckString, which accepts Lua numbers.
local numericNameMeta = {}
RegisterMetaTable(123, numericNameMeta)
assert(FindMetaTable(123) == numericNameMeta)
assert(numericNameMeta.MetaName == "123" and numericNameMeta.MetaID == TYPE_COUNT + 2)

-- The standalone behavioral fallback keeps the public validity contract:
-- nil/missing methods are false, custom objects work, and scalar indexing
-- errors are preserved rather than silently accepted.
assert(IsValid(TEST_ENTITY))
assert(IsValid(TEST_PLAYER))
assert(IsValid(TEST_PANEL))
assert(not IsValid(TEST_INVALID_ENTITY))
assert(not IsValid(TEST_VECTOR))
assert(not IsValid(nil))
assert(not IsValid({}))
assert(IsValid({ IsValid = function() return true end }))
assert(not IsValid({ IsValid = function() return false end }))
assert(not pcall(IsValid, 123))

assert(NULL ~= nil and NULL == NULL)
assert(type(NULL) == "Entity")
assert(TypeID(NULL) == TYPE_ENTITY)
assert(isentity(NULL) and IsEntity(NULL))
assert(not IsValid(NULL))
