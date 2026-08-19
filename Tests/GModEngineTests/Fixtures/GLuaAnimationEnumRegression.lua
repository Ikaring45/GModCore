assert(ACT_INVALID == -1)
assert(ACT_IDLE == 1)
assert(ACT_MP_STAND_IDLE == 990)
assert(ACT_MP_ATTACK_STAND_PRIMARYFIRE == 1011)
assert(ACT_HL2MP_IDLE == 1777)
assert(ACT_HL2MP_IDLE_SMG1 == 1797)
assert(ACT_GMOD_NOCLIP_LAYER == 1959)
assert(ACT_GMOD_IN_CHAT == 2019)
assert(ACT_GMOD_GESTURE_ITEM_PLACE == 2022)

-- The MP-to-HL2MP relation used by Base's top-level translation table must
-- be numeric, including the intentionally shared attack translation.
local idle = ACT_HL2MP_IDLE
local translation = {}
translation[ACT_MP_STAND_IDLE] = idle
translation[ACT_MP_WALK] = idle + 1
translation[ACT_MP_RUN] = idle + 2
translation[ACT_MP_CROUCH_IDLE] = idle + 3
translation[ACT_MP_CROUCHWALK] = idle + 4
translation[ACT_MP_ATTACK_STAND_PRIMARYFIRE] = idle + 5
translation[ACT_MP_ATTACK_CROUCH_PRIMARYFIRE] = idle + 5
translation[ACT_MP_RELOAD_STAND] = idle + 6
translation[ACT_MP_RELOAD_CROUCH] = idle + 6
translation[ACT_MP_JUMP] = ACT_HL2MP_JUMP_SLAM

assert(translation[ACT_MP_STAND_IDLE] == 1777)
assert(translation[ACT_MP_ATTACK_CROUCH_PRIMARYFIRE] == 1782)
assert(translation[ACT_MP_JUMP] == 1894)

assert(PLAYER_IDLE == 0 and PLAYER_ATTACK1 == 5 and PLAYER_LEAVE_AIMING == 9)
assert(PLAYERANIMEVENT_ATTACK_PRIMARY == 0)
assert(PLAYERANIMEVENT_JUMP == 6)
assert(PLAYERANIMEVENT_CUSTOM_GESTURE_SEQUENCE == 22)
assert(PLAYERANIMEVENT_CANCEL_RELOAD == 23)
assert(GESTURE_SLOT_ATTACK_AND_RELOAD == 0 and GESTURE_SLOT_CUSTOM == 6)
assert(FL_ANIMDUCKING == 4 and MOVETYPE_NOCLIP == 8)

GLUA_ANIMATION_ENUM_REGRESSION_OK = true
