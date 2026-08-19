import GModLua

/// Native GLua constants for the NPC bootstrap surface.
///
/// Values and realm availability are taken from the public Garry's Mod enum
/// reference:
/// - https://wiki.facepunch.com/gmod/Enums/SF
/// - https://wiki.facepunch.com/gmod/Enums/CT
/// - https://wiki.facepunch.com/gmod/Enums/NPC_STATE
///
/// The SF reference explicitly documents that its list is not exhaustive.
/// Accordingly this type exposes the complete *publicly documented* SF set,
/// and does not invent values for entity-specific spawnflags.
public enum GMLuaNPCEnums {
    /// SF values documented as usable outside the server realm. The public
    /// reference says every SF constant except SF_PHYS* and SF_WEAPON* is
    /// server-only.
    public static let sharedSpawnFlagConstants: [String: Int] = [
        "SF_PHYSBOX_MOTIONDISABLED": 32_768,
        "SF_PHYSBOX_ALWAYS_PICK_UP": 1_048_576,
        "SF_PHYSBOX_NEVER_PICK_UP": 2_097_152,
        "SF_PHYSBOX_NEVER_PUNT": 4_194_304,
        "SF_PHYSPROP_MOTIONDISABLED": 8,
        "SF_PHYSPROP_PREVENT_PICKUP": 512,
        "SF_PHYSPROP_IS_GIB": 4_194_304,
        "SF_WEAPON_START_CONSTRAINED": 1,
        "SF_WEAPON_NO_PLAYER_PICKUP": 2,
        "SF_WEAPON_NO_PHYSCANNON_PUNT": 4
    ]

    /// Publicly documented SF values whose engine meaning is server-only.
    public static let serverSpawnFlagConstants: [String: Int] = [
        "SF_CITIZEN_AMMORESUPPLIER": 524_288,
        "SF_CITIZEN_FOLLOW": 65_536,
        "SF_CITIZEN_IGNORE_SEMAPHORE": 2_097_152,
        "SF_CITIZEN_MEDIC": 131_072,
        "SF_CITIZEN_NOT_COMMANDABLE": 1_048_576,
        "SF_CITIZEN_RANDOM_HEAD": 262_144,
        "SF_CITIZEN_RANDOM_HEAD_FEMALE": 8_388_608,
        "SF_CITIZEN_RANDOM_HEAD_MALE": 4_194_304,
        "SF_CITIZEN_USE_RENDER_BOUNDS": 16_777_216,
        "SF_FLOOR_TURRET_CITIZEN": 512,
        "SF_NPC_ALTCOLLISION": 4_096,
        "SF_NPC_ALWAYSTHINK": 1_024,
        "SF_NPC_DROP_HEALTHKIT": 8,
        "SF_NPC_FADE_CORPSE": 512,
        "SF_NPC_FALL_TO_GROUND": 4,
        "SF_NPC_GAG": 2,
        "SF_NPC_LONG_RANGE": 256,
        "SF_NPC_NO_PLAYER_PUSHAWAY": 16_384,
        "SF_NPC_NO_WEAPON_DROP": 8_192,
        "SF_NPC_START_EFFICIENT": 16,
        "SF_NPC_TEMPLATE": 2_048,
        "SF_NPC_WAIT_FOR_SCRIPT": 128,
        "SF_NPC_WAIT_TILL_SEEN": 1,
        "SF_ROLLERMINE_FRIENDLY": 65_536
    ]

    public static let citizenTypeConstants: [String: Int] = [
        "CT_DEFAULT": 0,
        "CT_DOWNTRODDEN": 1,
        "CT_REFUGEE": 2,
        "CT_REBEL": 3,
        "CT_UNIQUE": 4
    ]

    public static let npcStateConstants: [String: Int] = [
        "NPC_STATE_INVALID": -1,
        "NPC_STATE_NONE": 0,
        "NPC_STATE_IDLE": 1,
        "NPC_STATE_ALERT": 2,
        "NPC_STATE_COMBAT": 3,
        "NPC_STATE_SCRIPT": 4,
        "NPC_STATE_PLAYDEAD": 5,
        "NPC_STATE_PRONE": 6,
        "NPC_STATE_DEAD": 7
    ]

    public static var allServerConstants: [String: Int] {
        sharedSpawnFlagConstants
            .merging(serverSpawnFlagConstants) { _, rhs in rhs }
            .merging(citizenTypeConstants) { _, rhs in rhs }
            .merging(npcStateConstants) { _, rhs in rhs }
    }

    public static func install(into state: LuaState, realm: GMLuaRealm) {
        for (name, value) in sharedSpawnFlagConstants {
            state.setGlobal(name, value: .number(Double(value)))
        }

        guard realm == .server else { return }
        for constants in [serverSpawnFlagConstants, citizenTypeConstants, npcStateConstants] {
            for (name, value) in constants {
                state.setGlobal(name, value: .number(Double(value)))
            }
        }
    }
}
