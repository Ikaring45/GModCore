local classes = {
    first = { name = "first" },
    second = { name = "second" },
    nested = { name = "nested" }
}

baseclass = {}
function baseclass.Get(name)
    return assert(classes[name], "unknown base class: " .. tostring(name))
end

local globalSentinel = {}
BaseClass = globalSentinel

DEFINE_BASECLASS("first")
local firstClosure = function() return BaseClass end
local firstNestedFactory = function()
    return function() return BaseClass end
end

DEFINE_BASECLASS("second")
local secondClosure = function() return BaseClass end

assert(firstClosure() == classes.first)
assert(firstNestedFactory()() == classes.first)
assert(secondClosure() == classes.second)
assert(rawget(_G, "BaseClass") == globalSentinel)

local nestedClosure
do
    DEFINE_BASECLASS("nested")
    nestedClosure = function() return BaseClass end
end

assert(nestedClosure() == classes.nested)
assert(secondClosure() == classes.second)

local sourceInfo = debug.getinfo(firstClosure, "S")
assert(sourceInfo.linedefined == 16, sourceInfo.linedefined)

print("GLua DEFINE_BASECLASS regression OK")
