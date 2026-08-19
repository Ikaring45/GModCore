-- Original compatibility regression for GModLua's native Entity registry.
-- The host test registers deterministic engine identities before this runs.

assert(type(Entity) == "function")
assert(type(ents) == "table" and type(ents.GetAll) == "function")
assert(type(ents.GetByIndex) == "function")
assert(type(player) == "table" and type(player.GetAll) == "function")

-- Native type identity cannot be forged by a field-shaped Lua table.
assert(type(TEST_ENTITY) == "Entity")
assert(type(TEST_PLAYER) == "Player")
assert(type(TEST_WEAPON) == "Weapon")
assert(type(TEST_VEHICLE) == "Vehicle")
assert(TypeID(TEST_ENTITY) == TYPE_ENTITY)
assert(TypeID(TEST_PLAYER) == TYPE_ENTITY)
assert(isentity(TEST_ENTITY) and IsEntity(TEST_PLAYER))
assert(not isentity({ EntIndex = function() return 5 end }))

-- Lookups preserve host identity. Missing and removed indices resolve to the
-- one canonical invalid Entity rather than manufacturing placeholder values.
assert(Entity(5) == TEST_ENTITY)
assert(Entity(5) == Entity(5))
assert(Entity("5") == TEST_ENTITY)
assert(ents.GetByIndex(5) == TEST_ENTITY)
assert(Entity(6) == NULL)
assert(ents.GetByIndex(404) == NULL)
assert(Entity(-1) == NULL)
assert(Entity(404) == Entity(405))
assert(isentity(NULL) and not IsValid(NULL))
assert(NULL:EntIndex() == 0 and NULL:GetClass() == "NULL")
assert(not NULL:IsPlayer() and not NULL:IsWeapon() and not NULL:IsVehicle())

assert(IsValid(TEST_ENTITY) and TEST_ENTITY:IsValid())
assert(TEST_ENTITY:EntIndex() == 5)
assert(TEST_ENTITY:GetClass() == "prop_physics")
assert(not TEST_ENTITY:IsPlayer())
assert(not TEST_ENTITY:IsWeapon())
assert(not TEST_ENTITY:IsVehicle())

assert(TEST_PLAYER:EntIndex() == 2)
assert(Player(2) == TEST_PLAYER)
assert(TEST_PLAYER:GetClass() == "player")
assert(TEST_PLAYER:IsPlayer())
assert(not TEST_PLAYER:IsWeapon() and not TEST_PLAYER:IsVehicle())

assert(TEST_WEAPON:EntIndex() == 7)
assert(TEST_WEAPON:GetClass() == "weapon_crowbar")
assert(TEST_WEAPON:IsWeapon())
assert(not TEST_WEAPON:IsPlayer() and not TEST_WEAPON:IsVehicle())

assert(TEST_VEHICLE:EntIndex() == 9)
assert(TEST_VEHICLE:GetClass() == "prop_vehicle_jeep")
assert(TEST_VEHICLE:IsVehicle())
assert(not TEST_VEHICLE:IsPlayer() and not TEST_VEHICLE:IsWeapon())

-- Enumeration is deterministic by EntIndex and returns fresh array tables.
local all = ents.GetAll()
assert(#all == 4)
assert(all[1] == TEST_PLAYER)
assert(all[2] == TEST_ENTITY)
assert(all[3] == TEST_WEAPON)
assert(all[4] == TEST_VEHICLE)
all[1] = nil
local all_again = ents.GetAll()
assert(#all_again == 4 and all_again[1] == TEST_PLAYER)

local players = player.GetAll()
assert(#players == 1 and players[1] == TEST_PLAYER)

-- Replacing/removing an engine slot invalidates stale userdata while keeping
-- it safely callable with NULL-like method results.
assert(TEST_OLD_ENTITY ~= TEST_ENTITY)
assert(not IsValid(TEST_OLD_ENTITY) and not TEST_OLD_ENTITY:IsValid())
assert(TEST_OLD_ENTITY == NULL and TEST_OLD_ENTITY:EntIndex() == 0)
assert(TEST_OLD_ENTITY:GetClass() == "NULL")
assert(not IsValid(TEST_REMOVED_ENTITY) and not TEST_REMOVED_ENTITY:IsValid())
assert(TEST_REMOVED_ENTITY == NULL and TEST_REMOVED_ENTITY:EntIndex() == 0)
assert(TEST_REMOVED_ENTITY:GetClass() == "NULL")

GLUA_ENTITY_REGISTRY_REGRESSION_OK = true
