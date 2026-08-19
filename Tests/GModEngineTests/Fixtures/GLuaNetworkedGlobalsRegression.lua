assert(GetGlobalBool("missing_bool") == false)
assert(GetGlobalInt("missing_int") == 0)
assert(GetGlobalFloat("missing_float") == 0)
assert(GetGlobalString("missing_string") == "")
assert(GetGlobalEntity("missing_entity_implicit") == NULL)

assert(GetGlobalBool("missing_bool_default", true) == true)
assert(GetGlobalInt("missing_int_default", -17) == -17)
assert(GetGlobalFloat("missing_float_default", 2.5) == 2.5)
assert(GetGlobalString("missing_string_default", "fallback") == "fallback")
assert(GetGlobalEntity("missing_entity", TEST_NETWORK_ENTITY) == TEST_NETWORK_ENTITY)

local vector_default = Vector(9, 8, 7)
local angle_default = Angle(6, 5, 4)
assert(GetGlobalVector("missing_vector", vector_default) == vector_default)
assert(GetGlobalAngle("missing_angle", angle_default) == angle_default)

SetGlobalBool("fixture_bool", true)
SetGlobalInt("fixture_int", 17.9)
SetGlobalInt("fixture_fractional_int", 4.75)
SetGlobalFloat("fixture_float", 1.25)
SetGlobalString("fixture_string", 42)
SetGlobalEntity("fixture_entity", TEST_NETWORK_ENTITY)

local source_vector = Vector(1, 2, 3)
local source_angle = Angle(4, 5, 6)
SetGlobalVector("fixture_vector", source_vector)
SetGlobalAngle("fixture_angle", source_angle)
source_vector.x = 100
source_angle.p = 100

assert(GetGlobalBool("fixture_bool") == true)
assert(GetGlobalInt("fixture_int") == 17.9)
assert(GetGlobalInt("fixture_fractional_int") == 4.75)
assert(GetGlobalFloat("fixture_float") == 1.25)
assert(GetGlobalString("fixture_string") == "42")
assert(GetGlobalEntity("fixture_entity", NULL) == TEST_NETWORK_ENTITY)

local received_vector = GetGlobalVector("fixture_vector", vector_default)
local received_angle = GetGlobalAngle("fixture_angle", angle_default)
assert(received_vector.x == 1 and received_vector.y == 2 and received_vector.z == 3)
assert(received_angle.p == 4 and received_angle.y == 5 and received_angle.r == 6)
received_vector.x = -100
received_angle.p = -100
assert(GetGlobalVector("fixture_vector", vector_default).x == 1)
assert(GetGlobalAngle("fixture_angle", angle_default).p == 4)

SetGlobalInt("same_index", 33)
SetGlobalString("same_index", "separate typed value")
-- Global* is one untyped key/value map. Typed getter names do not convert or
-- filter an existing value; the most recent setter wins for every getter.
assert(GetGlobalInt("same_index") == "separate typed value")
assert(GetGlobalString("same_index") == "separate typed value")
assert(GetGlobalVar("same_index") == "separate typed value")

SetGlobalBool("same_index", true)
assert(GetGlobalInt("same_index") == true)
assert(GetGlobalString("same_index") == true)
assert(GetGlobalVar("same_index") == true)

SetGlobalVar("generic_number", 123.75)
assert(GetGlobalVar("generic_number") == 123.75)
assert(GetGlobalString("generic_number") == 123.75)
SetGlobalVar("generic_string", "value")
assert(GetGlobalInt("generic_string") == "value")
assert(GetGlobalVar("generic_missing") == nil)
assert(GetGlobalVar("generic_missing", "fallback") == "fallback")

SetGlobalEntity("fixture_null", NULL)
assert(GetGlobalEntity("fixture_null", TEST_NETWORK_ENTITY) == NULL)

local bool_id = __gmod_NetworkStringToID("fixture_bool")
assert(bool_id > 0)
assert(__gmod_NetworkIDToString(bool_id) == "fixture_bool")
local message_id = __gmod_AddNetworkString("fixture_message")
assert(message_id > 0)
assert(__gmod_AddNetworkString("fixture_message") == message_id)
assert(__gmod_NetworkStringToID("fixture_message") == message_id)

return true
