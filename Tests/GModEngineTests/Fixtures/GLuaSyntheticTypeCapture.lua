-- Original synthetic regression: this is not Facepunch/GMod source.
-- It models only the ordering-sensitive act of capturing core Lua `type`
-- before a later compatibility layer replaces the public global.
local capturedCoreType = type

function SyntheticCapturedUserdataDescriptor(value)
    assert(capturedCoreType(value) == "userdata")
    local metadata = getmetatable(value)
    local base = metadata and metadata.MetaBaseClass
    return metadata and metadata.MetaName, base and base.MetaName
end
