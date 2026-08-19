local direct = ContextInclude("child.lua")
assert(direct == "caller-child")

local nested = ContextInclude("nested/entry.lua")
assert(nested == "nested-leaf")

local required = require("context_module")
assert(required == "required-child")

local loaded = assert(loadfile("lua/context/loadfile/module.lua"))
assert(loaded() == "loadfile-child")

CONTEXT_LATE_CALLBACK = function()
    return include("callback.lua")
end

GLUA_INCLUDE_EXECUTION_CONTEXT_OK = true
