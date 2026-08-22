import Foundation

/// One CLIENT-owned Weapon after canonical EHANDLE validation and original
/// SWEP metadata resolution. This value is renderer and UI independent.
public struct SourceOwnedWeaponSelectorEntry: Equatable, Sendable {
    public let weaponIdentity: SourceCanonicalEntityIdentity
    public let metadata: GMLuaScriptedWeaponSelectionMetadata
    public let isActive: Bool

    init(
        weaponIdentity: SourceCanonicalEntityIdentity,
        metadata: GMLuaScriptedWeaponSelectionMetadata,
        isActive: Bool
    ) {
        self.weaponIdentity = weaponIdentity
        self.metadata = metadata
        self.isActive = isActive
    }

    public var className: String { metadata.className }
}

/// Deterministically ordered selector state for one canonical CLIENT Player.
///
/// Ownership authority is the Player snapshot's full-EHANDLE inventory. The
/// current canonical Weapon snapshot has no dedicated owner identity, and its
/// `creator` is deliberately not treated as owner because creation and current
/// ownership are separate Source contracts.
public struct SourceOwnedWeaponSelectorCatalog: Equatable, Sendable {
    public let playerIdentity: SourceCanonicalEntityIdentity
    public let entries: [SourceOwnedWeaponSelectorEntry]
    public let activeWeaponIdentity: SourceCanonicalEntityIdentity?

    init(
        playerIdentity: SourceCanonicalEntityIdentity,
        entries: [SourceOwnedWeaponSelectorEntry],
        activeWeaponIdentity: SourceCanonicalEntityIdentity?
    ) {
        self.playerIdentity = playerIdentity
        self.entries = entries
        self.activeWeaponIdentity = activeWeaponIdentity
    }

    public var activeEntry: SourceOwnedWeaponSelectorEntry? {
        guard let activeWeaponIdentity else { return nil }
        return entries.first { $0.weaponIdentity == activeWeaponIdentity }
    }

    /// Returns the next class in Slot -> SlotPos -> class-name order. A Player
    /// with no active Weapon returns nil instead of guessing a starting item.
    public func nextWeaponClassName() -> String? {
        adjacentWeaponClassName(offset: 1)
    }

    /// Returns the previous class in Slot -> SlotPos -> class-name order. A
    /// Player with no active Weapon returns nil instead of guessing an item.
    public func previousWeaponClassName() -> String? {
        adjacentWeaponClassName(offset: -1)
    }

    private func adjacentWeaponClassName(offset: Int) -> String? {
        guard !entries.isEmpty,
              let activeWeaponIdentity,
              let activeIndex = entries.firstIndex(where: {
                  $0.weaponIdentity == activeWeaponIdentity
              }) else { return nil }
        let target = (activeIndex + offset + entries.count) % entries.count
        return entries[target].className
    }
}

public enum SourceOwnedWeaponSelectorCatalogError:
    Error,
    Equatable,
    Sendable,
    CustomStringConvertible
{
    case unsupportedRealm(String)
    case playerSnapshotRequired(
        identity: SourceCanonicalEntityIdentity,
        actualKind: SourceCanonicalEntityKind
    )
    case duplicateInventoryHandle(SourceCanonicalEntityIdentity)
    case duplicateInventoryClassName(String)
    case duplicateSnapshotHandle(SourceCanonicalEntityIdentity)
    case activeWeaponNotOwned(SourceCanonicalEntityIdentity)
    case missingWeapon(SourceCanonicalEntityIdentity)
    case nonWeaponSnapshot(
        identity: SourceCanonicalEntityIdentity,
        actualKind: SourceCanonicalEntityKind
    )
    case weaponClassMismatch(
        identity: SourceCanonicalEntityIdentity,
        inventoryClassName: String,
        snapshotClassName: String
    )
    case weaponLifecycleNotSelectable(
        identity: SourceCanonicalEntityIdentity,
        lifecycle: SourceCanonicalEntityLifecycle
    )
    case invalidMetadata(
        className: String,
        error: GMLuaScriptedWeaponSelectionMetadataError
    )
    case metadataResolutionFailed(className: String, reason: String)

    public var description: String {
        switch self {
        case let .unsupportedRealm(realm):
            return "owned Weapon selector catalog requires CLIENT, got \(realm)"
        case let .playerSnapshotRequired(identity, actualKind):
            return "entity \(identity.handle.rawValue) is \(actualKind.rawValue), expected player"
        case let .duplicateInventoryHandle(identity):
            return "Player inventory repeats EHANDLE \(identity.handle.rawValue)"
        case let .duplicateInventoryClassName(className):
            return "Player inventory repeats Weapon class \(className)"
        case let .duplicateSnapshotHandle(identity):
            return "CLIENT snapshots repeat EHANDLE \(identity.handle.rawValue)"
        case let .activeWeaponNotOwned(identity):
            return "active Weapon EHANDLE \(identity.handle.rawValue) is not owned"
        case let .missingWeapon(identity):
            return "owned Weapon EHANDLE \(identity.handle.rawValue) is missing"
        case let .nonWeaponSnapshot(identity, actualKind):
            return "owned EHANDLE \(identity.handle.rawValue) resolves to \(actualKind.rawValue)"
        case let .weaponClassMismatch(identity, inventoryClassName, snapshotClassName):
            return "owned Weapon EHANDLE \(identity.handle.rawValue) class mismatch: " +
                "inventory \(inventoryClassName), snapshot \(snapshotClassName)"
        case let .weaponLifecycleNotSelectable(identity, lifecycle):
            return "owned Weapon EHANDLE \(identity.handle.rawValue) has lifecycle \(lifecycle)"
        case let .invalidMetadata(className, error):
            return "\(className) selector metadata is invalid: \(error)"
        case let .metadataResolutionFailed(className, reason):
            return "\(className) selector metadata resolution failed: \(reason)"
        }
    }
}

public extension GMLuaRuntime {
    /// Joins one canonical CLIENT Player inventory with the matching canonical
    /// Weapon snapshots using complete Source EHANDLE identities.
    ///
    /// `weaponSnapshots` may contain unowned Weapons, but every owned record
    /// must resolve to exactly one live Weapon snapshot with the same class.
    /// Metadata is read from the inherited table returned by the original
    /// `weapons.Get`; no ordering or display fallback is manufactured here.
    func ownedWeaponSelectorCatalog(
        playerSnapshot player: SourceCanonicalEntitySnapshot,
        weaponSnapshots: [SourceCanonicalEntitySnapshot]
    ) throws -> SourceOwnedWeaponSelectorCatalog {
        switch realm {
        case .client:
            break
        case .server, .menu:
            throw SourceOwnedWeaponSelectorCatalogError.unsupportedRealm(
                realm.rawValue
            )
        }
        guard player.kind == .player else {
            throw SourceOwnedWeaponSelectorCatalogError.playerSnapshotRequired(
                identity: player.identity,
                actualKind: player.kind
            )
        }

        var snapshotsByIdentity:
            [SourceCanonicalEntityIdentity: SourceCanonicalEntitySnapshot] = [:]
        for snapshot in weaponSnapshots {
            guard snapshotsByIdentity.updateValue(
                snapshot,
                forKey: snapshot.identity
            ) == nil else {
                throw SourceOwnedWeaponSelectorCatalogError
                    .duplicateSnapshotHandle(snapshot.identity)
            }
        }

        var inventoryIdentities: Set<SourceCanonicalEntityIdentity> = []
        var foldedClassNames: Set<String> = []
        for record in player.weaponInventory.weapons {
            guard inventoryIdentities.insert(record.identity).inserted else {
                throw SourceOwnedWeaponSelectorCatalogError
                    .duplicateInventoryHandle(record.identity)
            }
            let folded = record.className.lowercased()
            guard foldedClassNames.insert(folded).inserted else {
                throw SourceOwnedWeaponSelectorCatalogError
                    .duplicateInventoryClassName(record.className)
            }
        }
        if let active = player.weaponInventory.activeWeapon,
           !inventoryIdentities.contains(active) {
            throw SourceOwnedWeaponSelectorCatalogError
                .activeWeaponNotOwned(active)
        }

        // Resolve in class/handle order so even a malformed multi-entry input
        // reaches the same first metadata failure independent of inventory
        // insertion order.
        let records = player.weaponInventory.weapons.sorted {
            if $0.className != $1.className {
                return Self.weaponSelectorClassPrecedes(
                    $0.className,
                    $1.className
                )
            }
            return $0.identity.handle < $1.identity.handle
        }
        var entries: [SourceOwnedWeaponSelectorEntry] = []
        entries.reserveCapacity(records.count)
        for record in records {
            guard let weapon = snapshotsByIdentity[record.identity] else {
                throw SourceOwnedWeaponSelectorCatalogError
                    .missingWeapon(record.identity)
            }
            guard weapon.kind == .weapon else {
                throw SourceOwnedWeaponSelectorCatalogError.nonWeaponSnapshot(
                    identity: weapon.identity,
                    actualKind: weapon.kind
                )
            }
            guard weapon.className.caseInsensitiveCompare(record.className)
                == .orderedSame else {
                throw SourceOwnedWeaponSelectorCatalogError.weaponClassMismatch(
                    identity: weapon.identity,
                    inventoryClassName: record.className,
                    snapshotClassName: weapon.className
                )
            }
            guard weapon.lifecycle == .active else {
                throw SourceOwnedWeaponSelectorCatalogError
                    .weaponLifecycleNotSelectable(
                        identity: weapon.identity,
                        lifecycle: weapon.lifecycle
                    )
            }

            let metadata: GMLuaScriptedWeaponSelectionMetadata
            do {
                metadata = try scriptedWeaponSelectionMetadata(
                    className: weapon.className
                )
            } catch let error as GMLuaScriptedWeaponSelectionMetadataError {
                throw SourceOwnedWeaponSelectorCatalogError.invalidMetadata(
                    className: weapon.className,
                    error: error
                )
            } catch {
                throw SourceOwnedWeaponSelectorCatalogError
                    .metadataResolutionFailed(
                        className: weapon.className,
                        reason: GMLuaRuntime.describe(error)
                    )
            }
            entries.append(SourceOwnedWeaponSelectorEntry(
                weaponIdentity: weapon.identity,
                metadata: metadata,
                isActive: player.weaponInventory.activeWeapon == weapon.identity
            ))
        }

        entries.sort {
            if $0.metadata.slot != $1.metadata.slot {
                return $0.metadata.slot < $1.metadata.slot
            }
            if $0.metadata.slotPosition != $1.metadata.slotPosition {
                return $0.metadata.slotPosition < $1.metadata.slotPosition
            }
            return Self.weaponSelectorClassPrecedes(
                $0.className,
                $1.className
            )
        }
        return SourceOwnedWeaponSelectorCatalog(
            playerIdentity: player.identity,
            entries: entries,
            activeWeaponIdentity: player.weaponInventory.activeWeapon
        )
    }

    private static func weaponSelectorClassPrecedes(
        _ lhs: String,
        _ rhs: String
    ) -> Bool {
        lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }
}
