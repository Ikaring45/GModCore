-- Original synthetic fixture. It models the small public contract needed by
-- TTT's cl_lang.lua without copying shipped Garry's Mod source.

local COLOR_META = {}
COLOR_META.__index = COLOR_META
RegisterMetaTable("Color", COLOR_META)

local function TestColor(r, g, b, a)
    return setmetatable({ r = r, g = g, b = b, a = a or 255 }, COLOR_META)
end

local COLOR_RED = TestColor(255, 40, 50, 220)
local LANG = {}

-- cl_lang.lua captures the native function during file load, before a style
-- is invoked. Keeping this assignment working is the startup acceptance test.
LANG.Styles = {
    chat_warn = function(text)
        chat.AddText(COLOR_RED, text)
    end,
    chat_plain = chat.AddText
}

LANG.Styles.chat_warn("localized warning")

local mutable_color = TestColor(10, 20, 30, 40)
local printable_table = setmetatable({}, {
    __tostring = function()
        return "synthetic-table"
    end
})

local entity_meta = FindMetaTable("Entity")
entity_meta.__tostring = function()
    return "synthetic-nonplayer-entity"
end

LANG.Styles.chat_plain(
    mutable_color,
    " plain ",
    TEST_CHAT_PLAYER,
    42.5,
    false,
    nil,
    printable_table,
    TEST_CHAT_ENTITY
)

-- The host snapshot must be a copy rather than a retained Color table.
mutable_color.r = 200
mutable_color.a = 255

-- No arguments is still a well-formed logical invocation.
chat.AddText()

GLUA_CHAT_ADDTEXT_REGRESSION_OK = true
