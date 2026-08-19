-- Original compatibility regression for GModLua's native Vector/Angle ABI.
--
-- The expected surface is derived from the public Garry's Mod API contract.
-- This file contains no Garry's Mod source code.

local EPSILON = 1e-9

local function near(actual, expected, epsilon)
    epsilon = epsilon or EPSILON
    return math.abs(actual - expected) <= epsilon
end

local function vector_near(value, x, y, z, epsilon)
    assert(isvector(value), "expected Vector")
    assert(near(value.x, x, epsilon), "unexpected Vector x")
    assert(near(value.y, y, epsilon), "unexpected Vector y")
    assert(near(value.z, z, epsilon), "unexpected Vector z")
end

local function angle_near(value, pitch, yaw, roll, epsilon)
    assert(isangle(value), "expected Angle")
    assert(near(value.p, pitch, epsilon), "unexpected Angle pitch")
    assert(near(value.y, yaw, epsilon), "unexpected Angle yaw")
    assert(near(value.r, roll, epsilon), "unexpected Angle roll")
end

local function must_fail(label, operation, expected_fragment)
    local ok, message = pcall(operation)
    assert(not ok, label .. " unexpectedly succeeded")
    assert(type(message) == "string", label .. " did not return a string error")
    if expected_fragment then
        assert(
            string.find(message, expected_fragment, 1, true) ~= nil,
            label .. " error did not mention " .. expected_fragment .. ": " .. message
        )
    end
end

-- Constructors: zero/default values, partial numeric arguments, string parse,
-- invalid-string fallback and copy construction with independent storage.
vector_near(Vector(), 0, 0, 0)
vector_near(Vector(4), 4, 0, 0)
vector_near(Vector(4, 5), 4, 5, 0)
vector_near(Vector(1.25, -2.5, 3.75), 1.25, -2.5, 3.75)
vector_near(Vector("4 5 6"), 4, 5, 6)
vector_near(Vector("not a vector"), 0, 0, 0)

local vector_source = Vector(7, 8, 9)
local vector_copy = Vector(vector_source)
vector_copy.x = 70
vector_near(vector_source, 7, 8, 9)
vector_near(vector_copy, 70, 8, 9)

angle_near(Angle(), 0, 0, 0)
angle_near(Angle(4), 4, 0, 0)
angle_near(Angle(4, 5), 4, 5, 0)
angle_near(Angle(1.25, -2.5, 3.75), 1.25, -2.5, 3.75)
angle_near(Angle("4 5 6"), 4, 5, 6)
angle_near(Angle("not an angle"), 0, 0, 0)

local angle_source = Angle(7, 8, 9)
local angle_copy = Angle(angle_source)
angle_copy.p = 70
angle_near(angle_source, 7, 8, 9)
angle_near(angle_copy, 70, 8, 9)

-- Type ABI and predicates. A table with matching visible fields must not forge
-- either native value type.
local vector_value = Vector(1, 2, 3)
local angle_value = Angle(4, 5, 6)
assert(type(vector_value) == "Vector")
assert(type(angle_value) == "Angle")
assert(TypeID(vector_value) == TYPE_VECTOR and TYPE_VECTOR == 10)
assert(TypeID(angle_value) == TYPE_ANGLE and TYPE_ANGLE == 11)
assert(isvector(vector_value) and not isangle(vector_value))
assert(isangle(angle_value) and not isvector(angle_value))
assert(not isvector({ x = 1, y = 2, z = 3 }))
assert(not isangle({ p = 1, y = 2, r = 3 }))

-- All documented component aliases are live views of the same mutable native
-- storage, including the fast one-based numeric indices.
local aliases = Vector(1, 2, 3)
assert(aliases.x == 1 and aliases.X == 1 and aliases.r == 1 and aliases[1] == 1)
assert(aliases.y == 2 and aliases.Y == 2 and aliases.g == 2 and aliases[2] == 2)
assert(aliases.z == 3 and aliases.Z == 3 and aliases.b == 3 and aliases[3] == 3)
aliases.X = 10
aliases[2] = 20
aliases.b = 30
vector_near(aliases, 10, 20, 30)
assert(aliases.r == 10 and aliases.Y == 20 and aliases[3] == 30)

local angle_aliases = Angle(1, 2, 3)
assert(
    angle_aliases.p == 1 and angle_aliases.pitch == 1 and
    angle_aliases.x == 1 and angle_aliases[1] == 1
)
assert(angle_aliases.y == 2 and angle_aliases.yaw == 2 and angle_aliases[2] == 2)
assert(
    angle_aliases.r == 3 and angle_aliases.roll == 3 and
    angle_aliases.z == 3 and angle_aliases[3] == 3
)
angle_aliases.pitch = 10
angle_aliases[2] = 20
angle_aliases.z = 30
angle_near(angle_aliases, 10, 20, 30)
assert(angle_aliases.x == 10 and angle_aliases.yaw == 20 and angle_aliases.roll == 30)

-- Finite tostring formatting is part of the public constructor round-trip.
assert(tostring(Vector(1, 2, 3)) == "1.000000 2.000000 3.000000")
assert(tostring(Angle(1, 2, 3)) == "1.00 2.00 3.00")
vector_near(Vector(tostring(Vector(-1.25, 2.5, 30))), -1.25, 2.5, 30)
angle_near(Angle(tostring(Angle(-1.25, 2.5, 30))), -1.25, 2.5, 30)

-- Arithmetic operators create new values and preserve their operands.
local va = Vector(8, 12, 18)
local vb = Vector(2, 3, 6)
vector_near(va + vb, 10, 15, 24)
vector_near(va - vb, 6, 9, 12)
vector_near(-vb, -2, -3, -6)
vector_near(va * 2, 16, 24, 36)
vector_near(2 * va, 16, 24, 36)
vector_near(va * vb, 16, 36, 108)
vector_near(va / 2, 4, 6, 9)
vector_near(va / vb, 4, 4, 3)
vector_near(va, 8, 12, 18)
vector_near(vb, 2, 3, 6)
assert(Vector(1, 2, 3) == Vector(1, 2, 3))
assert(Vector(1, 2, 3) ~= Vector(1, 2, 4))
assert(Vector(1, 2, 3) ~= Angle(1, 2, 3))

local aa = Angle(8, 12, 18)
local ab = Angle(2, 3, 6)
angle_near(aa + ab, 10, 15, 24)
angle_near(aa - ab, 6, 9, 12)
angle_near(-ab, -2, -3, -6)
angle_near(aa * 2, 16, 24, 36)
angle_near(2 * aa, 16, 24, 36)
angle_near(aa / 2, 4, 6, 9)
angle_near(aa, 8, 12, 18)
angle_near(ab, 2, 3, 6)
assert(Angle(1, 2, 3) == Angle(1, 2, 3))
assert(Angle(1, 2, 3) ~= Angle(1, 2, 4))
assert(Angle(0, 360, 0) ~= Angle(0, 0, 0))

-- In-place methods mutate identity instead of allocating a replacement.
local vm = Vector(8, 12, 18)
local vm_identity = vm
vm:Add(Vector(2, 3, 6))
assert(vm == vm_identity)
vector_near(vm, 10, 15, 24)
vm:Sub(Vector(2, 3, 4))
vector_near(vm, 8, 12, 20)
vm:Mul(2)
vector_near(vm, 16, 24, 40)
vm:Mul(Vector(0.5, 0.25, 0.1))
vector_near(vm, 8, 6, 4)
vm:Div(2)
vector_near(vm, 4, 3, 2)

local am = Angle(8, 12, 18)
local am_identity = am
am:Add(Angle(2, 3, 6))
assert(am == am_identity)
angle_near(am, 10, 15, 24)
am:Sub(Angle(2, 3, 4))
angle_near(am, 8, 12, 20)
am:Mul(2)
angle_near(am, 16, 24, 40)
am:Div(2)
angle_near(am, 8, 12, 20)

-- Vector normalization mutates in place; GetNormalized returns an independent
-- normalized copy. Zero vectors remain zero in both paths.
local normal = Vector(3, 4, 0)
normal:Normalize()
vector_near(normal, 0.6, 0.8, 0)
assert(near(normal:Length(), 1))

local source_normal = Vector(0, 0, 5)
local normalized_copy = source_normal:GetNormalized()
vector_near(source_normal, 0, 0, 5)
vector_near(normalized_copy, 0, 0, 1)
assert(normalized_copy ~= source_normal)

local zero = Vector()
zero:Normalize()
vector_near(zero, 0, 0, 0)
vector_near(Vector():GetNormalized(), 0, 0, 0)

local normalized_angle = Angle(181, -181, 361)
normalized_angle:Normalize()
angle_near(normalized_angle, -179, 179, 1)

-- Source-coordinate basis vectors. Besides cardinal cases, verify a general
-- angle produces an orthonormal, consistently handed frame.
vector_near(Angle(0, 0, 0):Forward(), 1, 0, 0)
vector_near(Angle(0, 0, 0):Right(), 0, -1, 0)
vector_near(Angle(0, 0, 0):Up(), 0, 0, 1)
vector_near(Angle(0, 90, 0):Forward(), 0, 1, 0, 1e-8)
vector_near(Angle(0, 90, 0):Right(), 1, 0, 0, 1e-8)
vector_near(Angle(90, 0, 0):Forward(), 0, 0, -1, 1e-8)

local basis = Angle(23, -47, 13)
local forward = basis:Forward()
local right = basis:Right()
local up = basis:Up()
assert(near(forward:Length(), 1, 1e-8))
assert(near(right:Length(), 1, 1e-8))
assert(near(up:Length(), 1, 1e-8))
assert(near(forward:Dot(right), 0, 1e-8))
assert(near(forward:Dot(up), 0, 1e-8))
assert(near(right:Dot(up), 0, 1e-8))
local handed_up = right:Cross(forward)
vector_near(handed_up, up.x, up.y, up.z, 1e-8)

-- IEEE-754 edge behavior matters to physics, traces and networking. The public
-- number contract establishes NaN/infinity as numbers, so constructors and
-- component equality must preserve them. Division-by-zero behavior itself is
-- deliberately recorded below as a non-gating observation: the public Vector
-- and Angle contracts do not specify whether zero division returns non-finite
-- components or raises an error.
local positive_infinity = 1 / 0
local negative_infinity = -1 / 0
local nan = 0 / 0
assert(positive_infinity > 0 and negative_infinity < 0 and nan ~= nan)

local nan_vector = Vector(nan, positive_infinity, negative_infinity)
local nan_angle = Angle(nan, positive_infinity, negative_infinity)
assert(nan_vector.x ~= nan_vector.x)
assert(nan_vector.y == positive_infinity and nan_vector.z == negative_infinity)
assert(nan_angle.p ~= nan_angle.p)
assert(nan_angle.y == positive_infinity and nan_angle.r == negative_infinity)
assert(nan_vector ~= Vector(nan, positive_infinity, negative_infinity))
assert(nan_angle ~= Angle(nan, positive_infinity, negative_infinity))

local vector_scalar_zero_ok, vector_scalar_zero = pcall(function()
    return Vector(1, -1, 0) / 0
end)
local vector_component_zero_ok, vector_component_zero = pcall(function()
    return Vector(1, 0, -1) / Vector(0, 0, 0)
end)
local angle_scalar_zero_ok, angle_scalar_zero = pcall(function()
    return Angle(1, -1, 0) / 0
end)
GLUA_VECTOR_ANGLE_NONFINITE_OBSERVATION = {
    vector_scalar_zero_ok = vector_scalar_zero_ok,
    vector_scalar_zero = tostring(vector_scalar_zero),
    vector_component_zero_ok = vector_component_zero_ok,
    vector_component_zero = tostring(vector_component_zero),
    angle_scalar_zero_ok = angle_scalar_zero_ok,
    angle_scalar_zero = tostring(angle_scalar_zero)
}

-- Invalid overloads must fail rather than silently producing discovery values.
-- The public contract fixes the invalid operation; the stable type token keeps
-- the assertion resilient to chunk/line prefixes added by different runners.
must_fail("Vector plus number", function() return Vector(1, 2, 3) + 1 end, "Vector")
must_fail("Vector minus Angle", function() return Vector(1, 2, 3) - Angle() end, "Vector")
must_fail("Angle plus Vector", function() return Angle(1, 2, 3) + Vector() end, "Angle")
must_fail("Angle times Angle", function() return Angle(1, 2, 3) * Angle() end, "number")
must_fail("Vector field non-number", function() vector_value.x = true end, "number")
must_fail("Angle field non-number", function() angle_value.pitch = {} end, "number")

-- Remaining deterministic methods from the public value-type surface.
local geometry_a = Vector(1, 2, 9)
local geometry_b = Vector(4, 6, -3)
assert(geometry_a:Distance2DSqr(geometry_b) == 25)
assert(geometry_a:Distance2D(geometry_b) == 5)
assert(geometry_a:DotProduct(geometry_b) == geometry_a:Dot(geometry_b))
vector_near(geometry_a:GetNegated(), -1, -2, -9)
assert(near(geometry_a:GetNormal():Length(), 1))
assert(Vector(1, 2, 3):IsEqualTol(Vector(1.01, 1.99, 3), 0.011))

local editing = Vector(1, 2, 3)
editing:Negate()
vector_near(editing, -1, -2, -3)
editing:Set(Vector(4, 5, 6))
editing:SetUnpacked(7, 8, 9)
vector_near(editing, 7, 8, 9)
assert(editing:WithinAABox(Vector(10, 10, 10), Vector(0, 0, 0)))
local vector_table = editing:ToTable()
assert(vector_table.x == 7 and vector_table.y == 8 and vector_table.z == 9)
editing:Zero()
assert(editing:IsZero())

local angle_editing = Angle(1, 2, 3)
angle_editing:Set(Angle(4, 5, 6))
angle_editing:SetUnpacked(7, 8, 9)
angle_near(angle_editing, 7, 8, 9)
assert(angle_editing:IsEqualTol(Angle(7.01, 7.99, 9), 0.011))
local angle_table = angle_editing:ToTable()
assert(angle_table.p == 7 and angle_table.y == 8 and angle_table.r == 9)
angle_editing:Zero()
assert(angle_editing:IsZero())

angle_near(Vector(1, 0, 0):Angle(), 0, 0, 0, 1e-8)
angle_near(Vector(0, 1, 0):Angle(), 0, 90, 0, 1e-8)
angle_near(Vector(0, 0, 1):Angle(), -90, 0, 0, 1e-8)
local orientation = Angle(23, -47, 13)
local reconstructed = orientation:Forward():AngleEx(orientation:Up())
assert(reconstructed:IsEqualTol(orientation, 1e-8))

local rotated_vector = Vector(1, 0, 0)
rotated_vector:Rotate(Angle(0, 90, 0))
vector_near(rotated_vector, 0, 1, 0, 1e-8)
local rotated_angle = Angle(0, 0, 0)
rotated_angle:RotateAroundAxis(Vector(0, 0, 1), 90)
vector_near(rotated_angle:Forward(), 0, 1, 0, 1e-8)

vector_near(LerpVector(0.25, Vector(0, 0, 0), Vector(8, 12, 16)), 2, 3, 4)
angle_near(LerpAngle(0.5, Angle(0, 170, 0), Angle(0, -170, 0)), 0, 180, 0)

GLUA_VECTOR_ANGLE_REGRESSION_OK = true
