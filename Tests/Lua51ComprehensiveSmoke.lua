-- Reference script used by GMLuaRuntime.lua51ComprehensiveSmokeTest()
-- The Swift wrapper includes an in-memory module loader for gmod_test_module.lua.

print("Lua", _VERSION)

local total = 0
for i = 1, 10 do
    if i % 2 == 0 && !false then
        total = total + i
    end
end
print("control", total, 2 + 3 * 4, 2^3^2)

local function vararg(...)
    return select("#", ...), ...
end
print("vararg", pcall(vararg, 10, 20, 30))

local object = { value = 40 }
function object:Add(x) return self.value + x end
print("object", object:Add(2))

local ok, err = xpcall(
    function() error("boom") end,
    function(e) return "handled:" .. e end
)
print("error", ok, err)
