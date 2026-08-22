import XCTest
import GModLua
@testable import GModEngine
@testable import GModGameSession

final class SourceCanonicalWeaponReloadTests: XCTestCase {
    func testOriginalWeaponBaseReloadRefillsBothClipsConsumesReserveAndReplicates()
        throws
    {
        let session = try GModPlayableSession(
            configuration: .init(),
            textMeasurer: nil,
            logger: { _, _ in }
        )
        defer { _ = try? session.close() }

        let player = try canonicalPlayer(in: session)
        try session.serverRuntime.execute(
            """
            weapons.Register({
                Base = "weapon_base",
                PrintName = "Canonical reload acceptance",
                Primary = {
                    ClipSize = 8,
                    DefaultClip = 2,
                    Automatic = false,
                    Ammo = "Pistol"
                },
                Secondary = {
                    ClipSize = 4,
                    DefaultClip = 1,
                    Automatic = false,
                    Ammo = "Pistol"
                }
            }, "weapon_reload_acceptance")

            local ply = Player(\(session.configuration.playerUserID))
            assert(ply:GiveAmmo(10, "Pistol", true) == 10)
            assert(IsValid(ply:Give("weapon_reload_acceptance")))
            ply:SelectWeapon("weapon_reload_acceptance")
            """,
            sourceName: "=(register inherited weapon_base reload acceptance)"
        )

        let initialized = try tick(session)
        XCTAssertEqual(initialized.failures, [])
        var weapon = try activeWeapon(player.identity, in: session)
        XCTAssertEqual(weapon.weaponRuntime.clip1, 2)
        XCTAssertEqual(weapon.weaponRuntime.clip2, 1)
        try session.serverRuntime.execute(
            """
            local ply = Player(\(session.configuration.playerUserID))
            local weapon = ply:GetActiveWeapon()
            assert(weapon:GetMaxClip1() == 8)
            assert(weapon:GetMaxClip2() == 4)
            assert(weapon:GetPrimaryAmmoType() == 3)
            assert(weapon:GetSecondaryAmmoType() == 3)
            assert(weapon:Ammo1() == 10)
            assert(weapon:Ammo2() == 10)
            """,
            sourceName: "=(verify authored reload metadata)"
        )

        _ = try session.sourceAdapter.updateCanonicalEntity(
            weapon.identity
        ) { state in
            // This is an explicit decoded-sequence fixture. Production's zero
            // value stays zero rather than being replaced by a guessed time.
            state.weaponRuntime.animationSequenceDuration = 0.45
        }
        _ = try tick(session)
        let deliveriesBeforeReload = try clientDeliveries(in: session).count
        let reloadStartTime = Float(
            try XCTUnwrap(session.serverRuntime.timerScheduler?.currentTime)
        )

        let reloaded = try tick(session, buttons: [.reload])
        XCTAssertEqual(reloaded.failures, [])
        XCTAssertTrue(reloaded.invocations.contains {
            $0.className == "weapon_reload_acceptance" &&
                $0.invocation == .reload
        })

        weapon = try activeWeapon(player.identity, in: session)
        let playerAfterReload = try canonicalPlayer(in: session)
        XCTAssertEqual(weapon.weaponRuntime.clip1, 8)
        XCTAssertEqual(weapon.weaponRuntime.clip2, 4)
        XCTAssertEqual(
            playerAfterReload.playerAmmoState?.entries,
            [.init(typeID: 3, typeName: "Pistol", count: 1)]
        )
        XCTAssertEqual(
            weapon.weaponRuntime.nextPrimaryFire,
            reloadStartTime + 0.45,
            accuracy: 0.000_01
        )
        XCTAssertEqual(
            weapon.weaponRuntime.nextSecondaryFire,
            reloadStartTime + 0.45,
            accuracy: 0.000_01
        )
        XCTAssertEqual(
            session.clientCanonicalEntitySnapshots.first {
                $0.identity == weapon.identity
            }?.weaponRuntime,
            weapon.weaponRuntime
        )
        XCTAssertEqual(
            session.clientCanonicalEntitySnapshots.first {
                $0.identity == player.identity
            }?.playerAmmoState,
            playerAfterReload.playerAmmoState
        )

        let newDeliveries = Array(
            try clientDeliveries(in: session).dropFirst(deliveriesBeforeReload)
        )
        XCTAssertTrue(newDeliveries.contains {
            guard case let .weaponAnimation(event) = $0.payload else {
                return false
            }
            return event.weaponIdentity == weapon.identity &&
                event.activity == 183
        })
        XCTAssertTrue(newDeliveries.contains {
            guard case let .playerAnimation(event) = $0.payload else {
                return false
            }
            return event.playerIdentity == player.identity &&
                event.animation == 7
        })
        XCTAssertFalse(newDeliveries.contains {
            if case .entitySound = $0.payload { return true }
            return false
        }, "DefaultReload must not invent an audio filename outside model event data")
        XCTAssertEqual(
            newDeliveries.map(\.transportSequence),
            newDeliveries.map(\.transportSequence).sorted()
        )

        let blockedAttack = try tick(session, buttons: [.attack])
        XCTAssertFalse(blockedAttack.invocations.contains {
            $0.invocation == .primaryAttack
        })

        try session.serverRuntime.execute(
            """
            local weapon = Player(\(session.configuration.playerUserID)):GetActiveWeapon()
            weapon:SetNextPrimaryFire(0)
            weapon:SetNextSecondaryFire(0)
            """,
            sourceName: "=(clear reload cooldown for no-op boundaries)"
        )
        _ = try tick(session)
        let beforeFullReload = try clientDeliveries(in: session).count
        let fullReload = try tick(session, buttons: [.reload])
        XCTAssertEqual(fullReload.failures, [])
        XCTAssertTrue(fullReload.invocations.contains {
            $0.invocation == .reload
        })
        XCTAssertEqual(try clientDeliveries(in: session).count, beforeFullReload)
        XCTAssertEqual(
            try activeWeapon(player.identity, in: session).weaponRuntime.clip1,
            8
        )

        try session.serverRuntime.execute(
            """
            local ply = Player(\(session.configuration.playerUserID))
            local weapon = ply:GetActiveWeapon()
            ply:RemoveAllAmmo()
            weapon:SetClip1(0)
            weapon:SetClip2(0)
            weapon:SetNextPrimaryFire(0)
            weapon:SetNextSecondaryFire(0)
            assert(weapon:DefaultReload(ACT_VM_RELOAD) == false)
            """,
            sourceName: "=(empty reserve reload boundary)"
        )
        _ = try tick(session)
        let beforeEmptyReload = try clientDeliveries(in: session).count
        let emptyReload = try tick(session, buttons: [.reload])
        XCTAssertEqual(emptyReload.failures, [])
        XCTAssertTrue(emptyReload.invocations.contains {
            $0.invocation == .reload
        })
        weapon = try activeWeapon(player.identity, in: session)
        XCTAssertEqual(weapon.weaponRuntime.clip1, 0)
        XCTAssertEqual(weapon.weaponRuntime.clip2, 0)
        XCTAssertEqual(try canonicalPlayer(in: session).playerAmmoState, .empty)
        XCTAssertEqual(try clientDeliveries(in: session).count, beforeEmptyReload)
    }

    private func tick(
        _ session: GModPlayableSession,
        buttons: SourceInputButtons = []
    ) throws -> SourceCanonicalWeaponGameplayTickReport {
        let report = try session.runFixedTick(
            movementInput: GModPlayableMovementInput(buttons: buttons)
        )
        XCTAssertEqual(report.actionFailures, [])
        return report.weaponGameplay
    }

    private func canonicalPlayer(
        in session: GModPlayableSession
    ) throws -> SourceCanonicalEntitySnapshot {
        try XCTUnwrap(session.sourceAdapter.canonicalEntitySnapshots.first {
            $0.kind == .player && $0.identity.entryIndex ==
                session.configuration.playerEntityIndex
        })
    }

    private func activeWeapon(
        _ playerIdentity: SourceCanonicalEntityIdentity,
        in session: GModPlayableSession
    ) throws -> SourceCanonicalEntitySnapshot {
        let player = try XCTUnwrap(
            session.sourceAdapter.canonicalSnapshot(for: playerIdentity)
        )
        let identity = try XCTUnwrap(player.weaponInventory.activeWeapon)
        return try XCTUnwrap(
            session.sourceAdapter.canonicalSnapshot(for: identity)
        )
    }

    private func clientDeliveries(
        in session: GModPlayableSession
    ) throws -> [GMLuaGameplayEventDelivery] {
        try XCTUnwrap(
            session.clientToolActionBridge.clientEventState
        ).capturedDeliveries
    }
}
