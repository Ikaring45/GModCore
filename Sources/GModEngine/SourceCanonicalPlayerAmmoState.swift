import Foundation

/// One engine-defined Garry's Mod ammo type. IDs and canonical spellings are
/// taken from the default ammo catalog; custom `game.AddAmmoType` registration
/// remains a separate engine service rather than being guessed from use sites.
struct SourceCanonicalDefaultAmmoType: Equatable, Sendable {
    let id: Int32
    let name: String
}

enum SourceCanonicalDefaultAmmoCatalog {
    static let all: [SourceCanonicalDefaultAmmoType] = [
        .init(id: 1, name: "AR2"),
        .init(id: 2, name: "AR2AltFire"),
        .init(id: 3, name: "Pistol"),
        .init(id: 4, name: "SMG1"),
        .init(id: 5, name: "357"),
        .init(id: 6, name: "XBowBolt"),
        .init(id: 7, name: "Buckshot"),
        .init(id: 8, name: "RPG_Round"),
        .init(id: 9, name: "SMG1_Grenade"),
        .init(id: 10, name: "Grenade"),
        .init(id: 11, name: "slam"),
        .init(id: 12, name: "AlyxGun"),
        .init(id: 13, name: "SniperRound"),
        .init(id: 14, name: "SniperPenetratedRound"),
        .init(id: 15, name: "Thumper"),
        .init(id: 16, name: "Gravity"),
        .init(id: 17, name: "Battery"),
        .init(id: 18, name: "GaussEnergy"),
        .init(id: 19, name: "CombineCannon"),
        .init(id: 20, name: "AirboatGun"),
        .init(id: 21, name: "StriderMinigun"),
        .init(id: 22, name: "HelicopterGun"),
        .init(id: 23, name: "9mmRound"),
        .init(id: 24, name: "357Round"),
        .init(id: 25, name: "BuckshotHL1"),
        .init(id: 26, name: "XBowBoltHL1"),
        .init(id: 27, name: "MP5_Grenade"),
        .init(id: 28, name: "RPG_Rocket"),
        .init(id: 29, name: "Uranium"),
        .init(id: 30, name: "GrenadeHL1"),
        .init(id: 31, name: "Hornet"),
        .init(id: 32, name: "Snark"),
        .init(id: 33, name: "TripMine"),
        .init(id: 34, name: "Satchel"),
        .init(id: 35, name: "12mmRound"),
        .init(id: 36, name: "StriderMinigunDirect"),
        .init(id: 37, name: "CombineHeavyCannon"),
    ]

    static func type(id: Int32) -> SourceCanonicalDefaultAmmoType? {
        all.first { $0.id == id }
    }

    static func type(name: String) -> SourceCanonicalDefaultAmmoType? {
        all.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
}

/// Player-only reserve ammunition. Zero counts are represented by absence so
/// `RemoveAllAmmo` clears one small, ordered value while SERVER and CLIENT
/// snapshots retain identical ammo IDs, names, and counts.
public struct SourceCanonicalPlayerAmmoState: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public let typeID: Int32
        public let typeName: String
        public var count: Int32

        public init(typeID: Int32, typeName: String, count: Int32) {
            self.typeID = typeID
            self.typeName = typeName
            self.count = count
        }
    }

    public private(set) var entries: [Entry]

    public init(entries: [Entry] = []) {
        self.entries = entries.sorted { $0.typeID < $1.typeID }
    }

    public static let empty = SourceCanonicalPlayerAmmoState()

    func count(for type: SourceCanonicalDefaultAmmoType) -> Int32 {
        entries.first { $0.typeID == type.id }?.count ?? 0
    }

    @discardableResult
    mutating func give(
        _ amount: Int32,
        of type: SourceCanonicalDefaultAmmoType,
        maximumCount: Int32
    ) -> Int32 {
        guard amount > 0, maximumCount > 0 else { return 0 }
        let current = count(for: type)
        guard current < maximumCount else { return 0 }
        let added = min(amount, maximumCount - current)
        guard added > 0 else { return 0 }

        if let index = entries.firstIndex(where: { $0.typeID == type.id }) {
            entries[index].count += added
        } else {
            entries.append(Entry(
                typeID: type.id,
                typeName: type.name,
                count: added
            ))
            entries.sort { $0.typeID < $1.typeID }
        }
        return added
    }

    /// Removes up to `amount` rounds from one registered Source ammo type.
    /// Zero-count entries are erased so snapshots retain the same canonical
    /// compact representation used by `RemoveAllAmmo` and `GiveAmmo`.
    @discardableResult
    mutating func consume(
        _ amount: Int32,
        of type: SourceCanonicalDefaultAmmoType
    ) -> Int32 {
        guard amount > 0,
              let index = entries.firstIndex(where: {
                  $0.typeID == type.id
              }) else { return 0 }
        let removed = min(amount, entries[index].count)
        guard removed > 0 else { return 0 }
        entries[index].count -= removed
        if entries[index].count == 0 {
            entries.remove(at: index)
        }
        return removed
    }

    @discardableResult
    mutating func removeAll() -> Bool {
        guard !entries.isEmpty else { return false }
        entries.removeAll(keepingCapacity: true)
        return true
    }

    var isValid: Bool {
        var previousID: Int32 = 0
        for entry in entries {
            guard entry.typeID > previousID,
                  entry.count > 0,
                  let type = SourceCanonicalDefaultAmmoCatalog.type(
                    id: entry.typeID
                  ),
                  type.name == entry.typeName else { return false }
            previousID = entry.typeID
        }
        return true
    }
}
