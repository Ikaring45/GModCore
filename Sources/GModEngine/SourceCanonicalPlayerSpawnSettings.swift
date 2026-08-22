/// Player-class state authored by the original
/// `player_manager.OnPlayerSpawn` route.
///
/// Armor has an engine-visible effect through the canonical combat snapshot.
/// The flashlight, teammate-collision, and avoidance values are retained and
/// replicated authoritatively, but their consuming engine systems are not yet
/// implemented. Retaining them here makes that boundary explicit instead of
/// reporting a successful realm-local no-op.
public struct SourceCanonicalPlayerSpawnSettings: Equatable, Sendable {
    public var allowsFlashlight: Bool
    public var shouldDropWeaponOnDeath: Bool
    public var noCollideWithTeammates: Bool
    public var avoidsPlayers: Bool
    public var armor: Int32
    public var maximumArmor: Int32

    public init(
        allowsFlashlight: Bool = true,
        shouldDropWeaponOnDeath: Bool = false,
        noCollideWithTeammates: Bool = true,
        avoidsPlayers: Bool = true,
        armor: Int32 = 0,
        maximumArmor: Int32 = 100
    ) {
        self.allowsFlashlight = allowsFlashlight
        self.shouldDropWeaponOnDeath = shouldDropWeaponOnDeath
        self.noCollideWithTeammates = noCollideWithTeammates
        self.avoidsPlayers = avoidsPlayers
        self.armor = armor
        self.maximumArmor = maximumArmor
    }

    public static let playerClassDefaults = Self()
}
