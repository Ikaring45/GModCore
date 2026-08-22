import XCTest
@testable import GModEngine
@testable import GModGameSession

final class SourceCanonicalPlayerLifecycleTests: XCTestCase {
    func testDamageDeathDropSpawnAndClientSnapshotUseOneCanonicalPlayer()
        throws
    {
        let session = try GModPlayableSession(
            configuration: .init(),
            textMeasurer: nil,
            logger: { _, _ in }
        )
        defer { _ = try? session.close() }

        var player = try canonicalPlayer(in: session)
        _ = try session.sourceAdapter.updateCanonicalEntity(
            player.identity
        ) { state in
            state.transform.origin = SourceVector3(321, -99, 777)
            state.motion.linearVelocity = SourceVector3(40, 50, -60)
            state.motion.angularVelocity = SourceVector3(1, 2, 3)
            state.motion.baseVelocity = SourceVector3(4, 5, 6)
            state.motion.waterCurrentBaseVelocity = SourceVector3(7, 8, 9)
            state.motion.outputWishVelocity = SourceVector3(10, 11, 12)
            state.motion.isOnGround = true
            state.motion.waterJumpTime = 2
            state.motion.waterLevel = .waist
            state.motion.isDucked = true
            state.motion.ladderNormal = SourceVector3(0, 1, 0)
        }

        try session.serverRuntime.execute(
            """
            local ply = Player(1)
            local weapon = ply:Give("gmod_tool")
            assert(IsValid(weapon))
            ply:SelectWeapon("gmod_tool")
            ply:ShouldDropWeapon(true)
            local damage = DamageInfo()
            damage:SetDamage(150)
            damage:SetDamageForce(Vector(12, 0, 0))
            damage:SetDamagePosition(Vector(321, -99, 777))
            damage:SetAttacker(ply)
            damage:SetInflictor(weapon)
            damage:SetWeapon(weapon)
            assert(ply:TakeDamageInfo(damage) == 1)
            assert(ply:Health() == -50)
            assert(ply:Alive() == false)
            assert(not IsValid(ply:GetActiveWeapon()))
            """,
            sourceName: "=(canonical Player lethal TakeDamageInfo)"
        )

        player = try canonicalPlayer(in: session)
        XCTAssertEqual(player.combat.health, -50)
        XCTAssertFalse(player.motion.isAlive)
        XCTAssertNil(player.weaponInventory.activeWeapon)
        XCTAssertEqual(
            try SourceCanonicalPlayerLifecycleController.lifeState(of: player),
            .dead
        )

        _ = try session.runFixedTick(movementInput: .idle)
        var clientPlayer = try clientCanonicalPlayer(in: session)
        XCTAssertEqual(clientPlayer.identity, player.identity)
        XCTAssertEqual(clientPlayer.combat.health, -50)
        XCTAssertFalse(clientPlayer.motion.isAlive)

        try session.serverRuntime.execute(
            """
            local ply = Player(1)
            ply:Spawn()
            assert(ply:Alive())
            assert(ply:Health() == ply:GetMaxHealth())
            """,
            sourceName: "=(canonical Player respawn)"
        )
        player = try canonicalPlayer(in: session)
        XCTAssertEqual(player.transform.origin, session.spawnPoint.origin)
        XCTAssertEqual(player.transform.angles, session.spawnPoint.angles)
        XCTAssertEqual(player.motion.linearVelocity, .zero)
        XCTAssertEqual(player.motion.angularVelocity, .zero)
        XCTAssertEqual(player.motion.baseVelocity, .zero)
        XCTAssertEqual(player.motion.waterCurrentBaseVelocity, .zero)
        XCTAssertEqual(player.motion.outputWishVelocity, .zero)
        XCTAssertFalse(player.motion.isOnGround)
        XCTAssertEqual(player.motion.waterJumpTime, 0)
        XCTAssertEqual(player.motion.waterLevel, .notInWater)
        XCTAssertFalse(player.motion.isDucked)
        XCTAssertEqual(player.motion.ladderNormal, .zero)
        XCTAssertTrue(player.motion.isAlive)
        XCTAssertEqual(player.combat.health, player.combat.maximumHealth)
        XCTAssertEqual(
            try SourceCanonicalPlayerLifecycleController.lifeState(of: player),
            .alive
        )

        _ = try session.runFixedTick(movementInput: .idle)
        clientPlayer = try clientCanonicalPlayer(in: session)
        XCTAssertEqual(clientPlayer.identity, player.identity)
        XCTAssertEqual(clientPlayer.combat, player.combat)
        XCTAssertEqual(clientPlayer.transform, player.transform)
        XCTAssertEqual(clientPlayer.motion, player.motion)

        try session.serverRuntime.execute(
            """
            local ply = Player(1)
            ply:Kill()
            assert(not ply:Alive() and ply:Health() == 0)
            ply:Kill()
            assert(not ply:Alive() and ply:Health() == 0)
            """,
            sourceName: "=(canonical Player idempotent Kill)"
        )
        player = try canonicalPlayer(in: session)
        XCTAssertEqual(player.combat.health, 0)
        XCTAssertFalse(player.motion.isAlive)
    }

    private func canonicalPlayer(
        in session: GModPlayableSession
    ) throws -> SourceCanonicalEntitySnapshot {
        try XCTUnwrap(session.sourceAdapter.canonicalEntitySnapshots.first {
            $0.kind == .player && $0.identity.entryIndex ==
                session.configuration.playerEntityIndex
        })
    }

    private func clientCanonicalPlayer(
        in session: GModPlayableSession
    ) throws -> SourceCanonicalEntitySnapshot {
        try XCTUnwrap(session.clientCanonicalEntitySnapshots.first {
            $0.kind == .player && $0.identity.entryIndex ==
                session.configuration.playerEntityIndex
        })
    }
}
