import XCTest
import GModLua
@testable import GModEngine
@testable import GModGameSession

final class SourceCanonicalWorldWeaponUseDropIntegrationTests: XCTestCase {
    func testStockSpawnWeaponPublishesCanonicalCreatorAndAuthoredOBB() throws {
        let model = SourceEntityModelReference("models/weapons/w_toolgun.mdl")
        let authoredWeaponHull = try SourceCollisionProperty(
            mins: SourceVector3(-11, -7, -3),
            maxs: SourceVector3(13, 8, 9)
        )
        let session = try GModPlayableSession(
            configuration: .init(),
            textMeasurer: nil,
            logger: { _, _ in },
            worldWalkCollisionProvider: nil,
            canonicalModelValidator: { candidate, kind in
                candidate == model && kind == .weapon ? .valid : .invalid
            },
            canonicalModelCollisionPropertyResolverForTesting: {
                candidate,
                kind in
                candidate == model && kind == .weapon
                    ? .valid(authoredWeaponHull)
                    : .invalid
            }
        )
        defer { _ = try? session.close() }

        try session.serverRuntime.execute(
            """
            local ply = Player(1)
            local tr = {
                Hit = true,
                HitPos = Vector(0, 0, 64),
                HitNormal = Vector(0, 0, 1)
            }
            local wep = assert(Spawn_Weapon(ply, "gmod_tool", tr))
            assert(wep:GetCreator() == ply)
            local mins = wep:OBBMins()
            local maxs = wep:OBBMaxs()
            assert(mins.x == -11 and mins.y == -7 and mins.z == -3)
            assert(maxs.x == 13 and maxs.y == 8 and maxs.z == 9)
            STOCK_SPAWNED_WEAPON = wep
            """,
            sourceName: "=(stock Sandbox Spawn_Weapon canonical route)"
        )

        let player = try XCTUnwrap(
            session.sourceAdapter.canonicalEntitySnapshots.first {
                $0.kind == .player
            }
        )
        let weapon = try XCTUnwrap(
            session.sourceAdapter.canonicalEntitySnapshots.first {
                $0.kind == .weapon && $0.className == "gmod_tool"
            }
        )
        XCTAssertEqual(weapon.creator, player.identity)
        XCTAssertEqual(weapon.collisionProperty, authoredWeaponHull)
        XCTAssertEqual(weapon.lifecycle, .spawned)

        let tick = try session.runFixedTick()
        XCTAssertEqual(tick.actionFailures, [])
        XCTAssertEqual(
            session.clientCanonicalEntitySnapshots.first {
                $0.identity == weapon.identity
            },
            session.sourceAdapter.canonicalSnapshot(for: weapon.identity)
        )
    }

    func testRegisteredWorldWeaponCreateContactPickupDropAndUsePickupKeepFullHandle()
        throws
    {
        let expectedModel = SourceEntityModelReference(
            "models/weapons/w_toolgun.mdl"
        )
        let authoredWeaponHull = try SourceCollisionProperty(
            mins: SourceVector3(-8, -4, -3),
            maxs: SourceVector3(9, 5, 6)
        )
        let session = try GModPlayableSession(
            configuration: .init(),
            textMeasurer: nil,
            logger: { _, _ in },
            worldWalkCollisionProvider: nil,
            canonicalModelValidator: { model, kind in
                model == expectedModel && kind == .weapon ? .valid : .invalid
            },
            canonicalModelCollisionPropertyResolverForTesting: { model, kind in
                model == expectedModel && kind == .weapon
                    ? .valid(authoredWeaponHull)
                    : .invalid
            }
        )
        defer { _ = try? session.close() }

        let player = try XCTUnwrap(
            session.sourceAdapter.canonicalEntitySnapshots.first {
                $0.kind == .player
            }
        )
        try session.serverRuntime.execute(
            """
            local ply = Player(\(session.configuration.playerUserID))
            local wep = ents.Create("gmod_tool")
            assert(IsValid(wep))
            assert(wep:IsWeapon())
            assert(wep:GetClass() == "gmod_tool")
            assert(not IsValid(wep:GetOwner()))
            WORLD_WEAPON = wep
            assert(not IsValid(ents.Create("not_a_registered_swep")))
            """,
            sourceName: "=(canonical registered world Weapon allocation)"
        )
        try session.serverRuntime.execute(
            """
            local wep = WORLD_WEAPON
            wep:SetPos(Vector(80, 24, 48))
            wep:Spawn()
            """,
            sourceName: "=(canonical registered world Weapon spawn)"
        )

        let created = try XCTUnwrap(
            session.sourceAdapter.canonicalEntitySnapshots.first {
                $0.kind == .weapon && $0.className == "gmod_tool"
            }
        )
        XCTAssertEqual(created.model, expectedModel)
        XCTAssertEqual(created.collisionProperty, authoredWeaponHull)
        XCTAssertEqual(created.lifecycle, .spawned)
        XCTAssertNil(created.creator)
        XCTAssertEqual(created.transform.origin, SourceVector3(80, 24, 48))
        XCTAssertFalse(created.isNotSolid)

        let contactTick = try session.runFixedTick(
            weaponPickupContactCandidates: [created.identity]
        )
        XCTAssertEqual(
            contactTick.weaponPickup.attempts.map(\.disposition),
            [.pickedUp]
        )
        var owned = try XCTUnwrap(
            session.sourceAdapter.canonicalEntitySnapshots.first {
                $0.identity == created.identity
            }
        )
        XCTAssertTrue(owned.isNotSolid)
        var currentPlayer = try XCTUnwrap(
            session.sourceAdapter.canonicalEntitySnapshots.first {
                $0.identity == player.identity
            }
        )
        XCTAssertEqual(
            currentPlayer.weaponInventory.weapon(className: "gmod_tool")?.identity,
            created.identity
        )
        XCTAssertEqual(
            session.clientCanonicalEntitySnapshots.first {
                $0.identity == created.identity
            }?.isNotSolid,
            true
        )

        try session.serverRuntime.execute(
            """
            local ply = Player(\(session.configuration.playerUserID))
            assert(ply:GetWeapon("gmod_tool") == WORLD_WEAPON)
            ply:DropWeapon(WORLD_WEAPON, Vector(160, 32, 72), Vector(4, 5, 6))
            assert(not ply:HasWeapon("gmod_tool"))
            assert(not IsValid(WORLD_WEAPON:GetOwner()))
            """,
            sourceName: "=(canonical exact-handle world Weapon drop)"
        )
        let dropped = try XCTUnwrap(
            session.sourceAdapter.canonicalEntitySnapshots.first {
                $0.identity == created.identity
            }
        )
        XCTAssertFalse(dropped.isNotSolid)
        XCTAssertEqual(dropped.transform.origin, SourceVector3(160, 32, 72))
        XCTAssertEqual(dropped.motion.linearVelocity, SourceVector3(4, 5, 6))

        let useTick = try session.runFixedTick(
            movementInput: .init(buttons: [.use]),
            weaponPickupUseTarget: dropped.identity
        )
        XCTAssertEqual(
            useTick.weaponPickup.attempts.map(\.disposition),
            [.pickedUp]
        )
        owned = try XCTUnwrap(
            session.sourceAdapter.canonicalEntitySnapshots.first {
                $0.identity == created.identity
            }
        )
        XCTAssertEqual(owned.identity, created.identity)
        XCTAssertTrue(owned.isNotSolid)
        currentPlayer = try XCTUnwrap(
            session.sourceAdapter.canonicalEntitySnapshots.first {
                $0.identity == player.identity
            }
        )
        XCTAssertEqual(
            currentPlayer.weaponInventory.weapon(className: "gmod_tool")?.identity,
            created.identity
        )
    }
}
