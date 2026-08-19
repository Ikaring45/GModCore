assert(SF_NPC_DROP_HEALTHKIT == 8)
assert(SF_CITIZEN_MEDIC == 131072)
assert(bit.bor(SF_NPC_DROP_HEALTHKIT, SF_CITIZEN_MEDIC) == 131080)
assert(SF_CITIZEN_RANDOM_HEAD == 262144)
assert(SF_FLOOR_TURRET_CITIZEN == 512)
assert(SF_NPC_NO_PLAYER_PUSHAWAY == 16384)

local citizens = {
    { citizenType = CT_DOWNTRODDEN },
    { citizenType = CT_REFUGEE },
    { citizenType = CT_REBEL },
    { citizenType = CT_UNIQUE }
}
assert(citizens[1].citizenType == 1)
assert(citizens[2].citizenType == 2)
assert(citizens[3].citizenType == 3)
assert(citizens[4].citizenType == 4)

local stateNames = {
    [NPC_STATE_INVALID] = "invalid",
    [NPC_STATE_NONE] = "none",
    [NPC_STATE_IDLE] = "idle",
    [NPC_STATE_ALERT] = "alert",
    [NPC_STATE_COMBAT] = "combat",
    [NPC_STATE_SCRIPT] = "script",
    [NPC_STATE_PLAYDEAD] = "playdead",
    [NPC_STATE_PRONE] = "prone",
    [NPC_STATE_DEAD] = "dead"
}
assert(stateNames[-1] == "invalid")
assert(stateNames[0] == "none")
assert(stateNames[7] == "dead")

GLUA_NPC_ENUM_REGRESSION_OK = true
