assert(type(input) == "table")

-- LookupBinding is the load-time path used by TTT's Key helper. The host
-- deliberately binds two keys to +use so lowest BUTTON_CODE ordering is
-- observable without relying on a platform keyboard layout.
assert(input.LookupBinding("+use") == "a")
assert(input.LookupBinding("use") == "a")
assert(input.LookupBinding("+use", true) == "a")
assert(input.LookupBinding("use", true) == nil)
assert(input.LookupBinding("+not_bound") == nil)

assert(input.LookupKeyBinding(15) == "+use")
assert(input.LookupKeyBinding(999) == nil)
assert(input.GetKeyName(15) == "e")
assert(input.GetKeyName(999) == nil)
assert(input.GetKeyCode("e") == 15)
assert(input.GetKeyCode("not-a-button") == -1)

local x, y = input.GetCursorPos()
assert(x == 41 and y == 73)
input.SetCursorPos(320.5, 240.25)
x, y = input.GetCursorPos()
assert(x == 320.5 and y == 240.25)

-- No button is implicitly pressed. The native test host feeds real logical
-- transitions after this chunk returns.
assert(input.IsKeyDown(17) == false)
assert(input.IsMouseDown(107) == false)
assert(input.IsButtonDown(150) == false)
assert(input.IsShiftDown() == false)
assert(input.IsControlDown() == false)

input.StartKeyTrapping()
assert(input.IsKeyTrapping() == true)
assert(input.CheckKeyTrapping() == nil)

function GLUA_INPUT_ASSERT_HOST_STATE()
    assert(input.IsKeyDown(17) == true)
    assert(input.IsKeyDown(107) == false)
    assert(input.IsMouseDown(107) == true)
    assert(input.IsMouseDown(17) == false)
    assert(input.IsButtonDown(17) == true)
    assert(input.IsButtonDown(107) == true)
    assert(input.IsButtonDown(150) == true)
    assert(input.IsShiftDown() == true)
    assert(input.IsControlDown() == true)

    -- A captured transition remains visible to DBinder's IsKeyTrapping gate
    -- until CheckKeyTrapping consumes it.
    assert(input.IsKeyTrapping() == true)
    assert(input.CheckKeyTrapping() == 17)
    assert(input.IsKeyTrapping() == false)
    assert(input.CheckKeyTrapping() == nil)
    return true
end

GLUA_INPUT_REGRESSION_READY = true
