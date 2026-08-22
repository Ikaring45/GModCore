import GModEngine
import XCTest

final class SourceOwnedWeaponSelectorCatalogTests: XCTestCase {
    func testJoinsFullHandlesSortsMetadataAndCyclesFromExactActiveWeapon() throws {
        let runtime = try makeRuntime(
            definitions: """
            weapon_b = { Slot = 0, SlotPos = 10, PrintName = "B" },
            weapon_c = { Slot = 1, SlotPos = 2, PrintName = "C" },
            weapon_a = { Slot = 1, SlotPos = 5, PrintName = "A" },
            weapon_z = { Slot = 1, SlotPos = 5, PrintName = "Z" }
            """
        )
        defer { _ = runtime.close() }

        let weaponA = identity(10, serial: 2)
        let weaponB = identity(11, serial: 3)
        let weaponC = identity(12, serial: 4)
        let weaponZ = identity(13, serial: 5)
        let inventory = SourceCanonicalWeaponInventory(
            weapons: [
                .init(identity: weaponZ, className: "weapon_z"),
                .init(identity: weaponA, className: "weapon_a"),
                .init(identity: weaponB, className: "weapon_b"),
                .init(identity: weaponC, className: "weapon_c"),
            ],
            activeWeapon: weaponA
        )
        let player = snapshot(
            identity: identity(1, serial: 7),
            kind: .player,
            className: "player",
            inventory: inventory
        )
        let weapons = [
            snapshot(identity: weaponC, kind: .weapon, className: "weapon_c"),
            snapshot(identity: weaponZ, kind: .weapon, className: "weapon_z"),
            snapshot(identity: weaponB, kind: .weapon, className: "weapon_b"),
            snapshot(identity: weaponA, kind: .weapon, className: "weapon_a"),
            snapshot(
                identity: identity(99, serial: 1),
                kind: .weapon,
                className: "unowned_weapon"
            ),
        ]

        let catalog = try runtime.ownedWeaponSelectorCatalog(
            playerSnapshot: player,
            weaponSnapshots: weapons
        )

        XCTAssertEqual(catalog.playerIdentity, player.identity)
        XCTAssertEqual(catalog.entries.map(\.className), [
            "weapon_b", "weapon_c", "weapon_a", "weapon_z",
        ])
        XCTAssertEqual(catalog.entries.map(\.weaponIdentity), [
            weaponB, weaponC, weaponA, weaponZ,
        ])
        XCTAssertEqual(catalog.activeWeaponIdentity, weaponA)
        XCTAssertEqual(catalog.activeEntry?.weaponIdentity, weaponA)
        XCTAssertEqual(catalog.entries.map(\.isActive), [false, false, true, false])
        XCTAssertEqual(catalog.nextWeaponClassName(), "weapon_z")
        XCTAssertEqual(catalog.previousWeaponClassName(), "weapon_c")
    }

    func testCyclesAtBothEndsAndDoesNotGuessWithoutActiveIdentity() throws {
        let runtime = try makeRuntime(
            definitions: """
            first = { Slot = 0, SlotPos = 0, PrintName = "First" },
            last = { Slot = 1, SlotPos = 0, PrintName = "Last" }
            """
        )
        defer { _ = runtime.close() }

        let first = identity(2, serial: 1)
        let last = identity(3, serial: 1)
        let records = [
            SourceCanonicalWeaponRecord(identity: first, className: "first"),
            SourceCanonicalWeaponRecord(identity: last, className: "last"),
        ]
        let snapshots = [
            snapshot(identity: first, kind: .weapon, className: "first"),
            snapshot(identity: last, kind: .weapon, className: "last"),
        ]

        let firstActive = try runtime.ownedWeaponSelectorCatalog(
            playerSnapshot: snapshot(
                identity: identity(1, serial: 1),
                kind: .player,
                className: "player",
                inventory: .init(weapons: records, activeWeapon: first)
            ),
            weaponSnapshots: snapshots
        )
        XCTAssertEqual(firstActive.previousWeaponClassName(), "last")

        let lastActive = try runtime.ownedWeaponSelectorCatalog(
            playerSnapshot: snapshot(
                identity: identity(1, serial: 1),
                kind: .player,
                className: "player",
                inventory: .init(weapons: records, activeWeapon: last)
            ),
            weaponSnapshots: snapshots
        )
        XCTAssertEqual(lastActive.nextWeaponClassName(), "first")

        let noActive = try runtime.ownedWeaponSelectorCatalog(
            playerSnapshot: snapshot(
                identity: identity(1, serial: 1),
                kind: .player,
                className: "player",
                inventory: .init(weapons: records)
            ),
            weaponSnapshots: snapshots
        )
        XCTAssertNil(noActive.activeEntry)
        XCTAssertNil(noActive.nextWeaponClassName())
        XCTAssertNil(noActive.previousWeaponClassName())
    }

    func testRejectsDuplicateAndStaleFullHandleInputs() throws {
        let runtime = try makeRuntime(
            definitions: """
            alpha = { Slot = 0, SlotPos = 0, PrintName = "Alpha" },
            beta = { Slot = 0, SlotPos = 1, PrintName = "Beta" }
            """
        )
        defer { _ = runtime.close() }
        let playerIdentity = identity(1, serial: 1)
        let owned = identity(4, serial: 9)
        let ownedSnapshot = snapshot(
            identity: owned,
            kind: .weapon,
            className: "alpha"
        )

        assertCatalogError(
            .duplicateInventoryHandle(owned),
            runtime: runtime,
            player: snapshot(
                identity: playerIdentity,
                kind: .player,
                className: "player",
                inventory: .init(weapons: [
                    .init(identity: owned, className: "alpha"),
                    .init(identity: owned, className: "beta"),
                ])
            ),
            weapons: [ownedSnapshot]
        )
        assertCatalogError(
            .duplicateSnapshotHandle(owned),
            runtime: runtime,
            player: player(
                playerIdentity,
                record: .init(identity: owned, className: "alpha")
            ),
            weapons: [ownedSnapshot, ownedSnapshot]
        )

        let recycled = identity(owned.entryIndex, serial: owned.serialNumber + 1)
        assertCatalogError(
            .missingWeapon(owned),
            runtime: runtime,
            player: player(
                playerIdentity,
                record: .init(identity: owned, className: "alpha")
            ),
            weapons: [
                snapshot(identity: recycled, kind: .weapon, className: "alpha"),
            ]
        )
        assertCatalogError(
            .activeWeaponNotOwned(identity(8, serial: 2)),
            runtime: runtime,
            player: snapshot(
                identity: playerIdentity,
                kind: .player,
                className: "player",
                inventory: .init(
                    weapons: [.init(identity: owned, className: "alpha")],
                    activeWeapon: identity(8, serial: 2)
                )
            ),
            weapons: [ownedSnapshot]
        )
    }

    func testRejectsNonWeaponClassMismatchLifecycleAndInvalidMetadata() throws {
        let runtime = try makeRuntime(
            definitions: """
            alpha = { Slot = 0, SlotPos = 0, PrintName = "Alpha" },
            bad_metadata = { Slot = "0", SlotPos = 0, PrintName = "Bad" }
            """
        )
        defer { _ = runtime.close() }
        let playerIdentity = identity(1, serial: 1)
        let owned = identity(5, serial: 3)
        let alphaPlayer = player(
            playerIdentity,
            record: .init(identity: owned, className: "alpha")
        )

        assertCatalogError(
            .nonWeaponSnapshot(identity: owned, actualKind: .propPhysics),
            runtime: runtime,
            player: alphaPlayer,
            weapons: [
                snapshot(identity: owned, kind: .propPhysics, className: "prop_physics"),
            ]
        )
        assertCatalogError(
            .weaponClassMismatch(
                identity: owned,
                inventoryClassName: "alpha",
                snapshotClassName: "beta"
            ),
            runtime: runtime,
            player: alphaPlayer,
            weapons: [snapshot(identity: owned, kind: .weapon, className: "beta")]
        )
        assertCatalogError(
            .weaponLifecycleNotSelectable(
                identity: owned,
                lifecycle: .pendingRemoval
            ),
            runtime: runtime,
            player: alphaPlayer,
            weapons: [
                snapshot(
                    identity: owned,
                    kind: .weapon,
                    className: "alpha",
                    lifecycle: .pendingRemoval
                ),
            ]
        )

        let badIdentity = identity(6, serial: 4)
        assertCatalogError(
            .invalidMetadata(
                className: "bad_metadata",
                error: .invalidFieldType(
                    className: "bad_metadata",
                    field: "Slot",
                    actualType: "string"
                )
            ),
            runtime: runtime,
            player: player(
                playerIdentity,
                record: .init(identity: badIdentity, className: "bad_metadata")
            ),
            weapons: [
                snapshot(
                    identity: badIdentity,
                    kind: .weapon,
                    className: "bad_metadata"
                ),
            ]
        )
    }

    private func makeRuntime(definitions: String) throws -> GMLuaRuntime {
        let runtime = GMLuaRuntime(realm: .client, logger: { _ in })
        do {
            try runtime.execute(
                """
                weapons = {}
                local definitions = {
                \(definitions)
                }
                function weapons.Get(name) return definitions[name] end
                """,
                sourceName: "=(owned Weapon selector metadata)"
            )
            return runtime
        } catch {
            _ = runtime.close()
            throw error
        }
    }

    private func identity(
        _ entryIndex: Int,
        serial: Int
    ) -> SourceCanonicalEntityIdentity {
        SourceCanonicalEntityIdentity(handle: SourceBaseHandle(
            entryIndex: entryIndex,
            serialNumber: serial
        ))
    }

    private func player(
        _ identity: SourceCanonicalEntityIdentity,
        record: SourceCanonicalWeaponRecord
    ) -> SourceCanonicalEntitySnapshot {
        snapshot(
            identity: identity,
            kind: .player,
            className: "player",
            inventory: .init(weapons: [record])
        )
    }

    private func snapshot(
        identity: SourceCanonicalEntityIdentity,
        kind: SourceCanonicalEntityKind,
        className: String,
        inventory: SourceCanonicalWeaponInventory = .init(),
        lifecycle: SourceCanonicalEntityLifecycle = .active
    ) -> SourceCanonicalEntitySnapshot {
        SourceCanonicalEntitySnapshot(
            identity: identity,
            kind: kind,
            className: className,
            transform: .identity,
            motion: .init(),
            model: nil,
            solidType: .none,
            moveType: .none,
            lifecycle: lifecycle,
            isNetworkable: true,
            revision: 1,
            playerDisplayName: kind == .player ? "Player" : nil,
            weaponInventory: inventory,
            weaponHoldType: kind == .weapon ? "normal" : nil
        )
    }

    private func assertCatalogError(
        _ expected: SourceOwnedWeaponSelectorCatalogError,
        runtime: GMLuaRuntime,
        player: SourceCanonicalEntitySnapshot,
        weapons: [SourceCanonicalEntitySnapshot],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try runtime.ownedWeaponSelectorCatalog(
                playerSnapshot: player,
                weaponSnapshots: weapons
            ),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                error as? SourceOwnedWeaponSelectorCatalogError,
                expected,
                file: file,
                line: line
            )
        }
    }
}
