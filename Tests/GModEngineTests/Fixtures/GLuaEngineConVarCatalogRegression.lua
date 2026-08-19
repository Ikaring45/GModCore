local language = GetConVar("gmod_language")
assert(type(language) == "ConVar")
assert(language == GetConVar("GMOD_LANGUAGE"))
assert(language:GetName() == "gmod_language")
assert(language:GetDefault() == "en")
assert(language:GetString() == "en")
assert(language:GetFlags() == FCVAR_ARCHIVE)
assert(language:GetHelpText() == "Headless engine language")
assert(language:GetMin() == 0)
assert(language:GetMax() == 0)

local serverCollision = CreateConVar(
    "GMOD_LANGUAGE",
    "de",
    FCVAR_NOTIFY,
    "must not replace host metadata"
)
assert(serverCollision == language)
assert(serverCollision:GetDefault() == "en")
assert(serverCollision:GetFlags() == FCVAR_ARCHIVE)

local clientCollision = CreateClientConVar(
    "gmod_language",
    "ja",
    true,
    true,
    "must also preserve the host object"
)
assert(clientCollision == language)
assert(clientCollision:GetString() == "en")

local bounded = GetConVar("gpad_host_bounded")
assert(type(bounded) == "ConVar")
assert(bounded:GetDefault() == "3")
assert(bounded:GetString() == "10")
assert(bounded:GetMin() == -10)
assert(bounded:GetMax() == 10)

assert(GetConVar("gpad_host_unknown") == nil)
assert(not ConVarExists("gpad_host_unknown"))
assert(GetConVarString("gpad_host_unknown") == "")
assert(GetConVarNumber("gpad_host_unknown") == 0)

GLUA_ENGINE_CONVAR_CATALOG_REGRESSION_OK = true
