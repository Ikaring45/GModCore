import XCTest
@testable import GModEngine
@testable import GModGameSession
import GModLua

final class SourceCanonicalPlayerSpawnHookIntegrationTests: XCTestCase {
    func testObserverABIMutatesOneCanonicalFullHandleThroughFIFO() throws {
        let runtime = GMLuaRuntime(
            realm: .server,
            logger: { _ in },
            netTransport: GMLuaNetTransport()
        )
        let adapter = try GMLuaSourceRuntimeAdapter(serverRuntime: runtime)
        defer {
            try? adapter.close()
            _ = runtime.close()
        }
        try adapter.installCanonicalEntityLuaBridge()

        let player = try adapter.createCanonicalEntity(
            kind: .player,
            at: 7,
            playerUserID: 41
        )
        let initial = try XCTUnwrap(
            adapter.canonicalSnapshot(for: player.identity)
        )
        XCTAssertEqual(initial.motion.playerObserverState, .notObserving)
        XCTAssertEqual(initial.viewOffset, SourceVector3(0, 0, 64))

        try runtime.execute(
            """
            local ply = Player(41)
            assert(OBS_MODE_NONE == 0)
            assert(OBS_MODE_DEATHCAM == 1)
            assert(OBS_MODE_FREEZECAM == 2)
            assert(OBS_MODE_FIXED == 3)
            assert(OBS_MODE_IN_EYE == 4)
            assert(OBS_MODE_CHASE == 5)
            assert(OBS_MODE_ROAMING == 6)
            assert(ply:GetObserverMode() == OBS_MODE_NONE)

            ply:Spectate(OBS_MODE_ROAMING)
            assert(ply:GetObserverMode() == OBS_MODE_ROAMING)

            assert(pcall(function() ply:Spectate(-1) end) == false)
            assert(pcall(function() ply:Spectate(7) end) == false)
            local playerMeta = FindMetaTable("Player")
            assert(pcall(function()
                playerMeta.Spectate(Entity(0), OBS_MODE_ROAMING)
            end) == false)
            """,
            sourceName: "=(canonical Player observer ABI)"
        )

        let roaming = try XCTUnwrap(
            adapter.canonicalSnapshot(for: player.identity)
        )
        XCTAssertEqual(roaming.identity, player.identity)
        XCTAssertEqual(roaming.revision, initial.revision + 1)
        XCTAssertEqual(roaming.motion.playerObserverState?.mode, .roaming)
        XCTAssertEqual(roaming.motion.playerObserverState?.lastMode, .roaming)
        XCTAssertEqual(roaming.transform.origin, SourceVector3(0, 0, 64))
        XCTAssertEqual(roaming.viewOffset, .zero)
        XCTAssertEqual(roaming.moveType, .observer)
        XCTAssertFalse(roaming.motion.isOnGround)
        XCTAssertFalse(roaming.motion.isDucked)
        XCTAssertFalse(roaming.motion.isAlive)
        XCTAssertTrue(roaming.isNotSolid)
        XCTAssertTrue(roaming.isNoDraw)
        XCTAssertEqual(roaming.combat.takeDamageMode, 0)
        XCTAssertEqual(roaming.combat.health, 1)

        try runtime.execute(
            """
            local ply = Player(41)
            ply:SetObserverMode(OBS_MODE_FIXED)
            assert(ply:GetObserverMode() == OBS_MODE_FIXED)
            ply:UnSpectate()
            assert(ply:GetObserverMode() == OBS_MODE_NONE)
            ply:UnSpectate()
            """,
            sourceName: "=(canonical Player observer transition)"
        )

        let stopped = try XCTUnwrap(
            adapter.canonicalSnapshot(for: player.identity)
        )
        XCTAssertEqual(stopped.identity, player.identity)
        XCTAssertEqual(stopped.revision, initial.revision + 3)
        XCTAssertEqual(
            stopped.motion.playerObserverState?.mode,
            SourceCanonicalPlayerObserverMode.none
        )
        XCTAssertEqual(stopped.motion.playerObserverState?.lastMode, .fixed)
        XCTAssertEqual(stopped.moveType, .none)
        XCTAssertEqual(stopped.viewOffset, .zero)
        XCTAssertTrue(stopped.isNotSolid)
        XCTAssertTrue(stopped.isNoDraw)
        XCTAssertFalse(stopped.motion.isAlive)
        XCTAssertEqual(
            adapter.pendingCanonicalEntityOperationCount,
            4,
            "create plus three valid observer mutations must retain FIFO order"
        )
    }

    func testPlayerColorABIPreservesFiniteStockVectorsAndRejectsInvalidInput()
        throws
    {
        let runtime = GMLuaRuntime(
            realm: .server,
            logger: { _ in },
            netTransport: GMLuaNetTransport()
        )
        let adapter = try GMLuaSourceRuntimeAdapter(serverRuntime: runtime)
        defer {
            try? adapter.close()
            _ = runtime.close()
        }
        try adapter.installCanonicalEntityLuaBridge()

        let player = try adapter.createCanonicalEntity(
            kind: .player,
            at: 7,
            playerUserID: 41
        )
        let initial = try XCTUnwrap(
            adapter.canonicalSnapshot(for: player.identity)
        )
        XCTAssertEqual(initial.playerColorState, .white)

        try runtime.execute(
            """
            local ply = Player(41)
            assert(ply:GetPlayerColor() == Vector(1, 1, 1))
            assert(ply:GetWeaponColor() == Vector(1, 1, 1))

            ply:SetPlayerColor(Vector(0.24, 0.34, 0.41))
            ply:SetWeaponColor(Vector(0.30, 1.80, 2.10))
            local playerColor = ply:GetPlayerColor()
            local weaponColor = ply:GetWeaponColor()
            assert(math.abs(playerColor.x - 0.24) < 0.000001)
            assert(math.abs(playerColor.y - 0.34) < 0.000001)
            assert(math.abs(playerColor.z - 0.41) < 0.000001)
            assert(math.abs(weaponColor.x - 0.30) < 0.000001)
            assert(math.abs(weaponColor.y - 1.80) < 0.000001)
            assert(math.abs(weaponColor.z - 2.10) < 0.000001)

            assert(pcall(function()
                ply:SetPlayerColor(Vector(0 / 0, 0, 0))
            end) == false)
            assert(pcall(function()
                ply:SetWeaponColor(Vector(math.huge, 0, 0))
            end) == false)
            local playerMeta = FindMetaTable("Player")
            assert(pcall(function()
                playerMeta.SetPlayerColor(Entity(0), Vector(1, 0, 0))
            end) == false)
            """,
            sourceName: "=(canonical Player material-proxy color ABI)"
        )

        let colored = try XCTUnwrap(
            adapter.canonicalSnapshot(for: player.identity)
        )
        XCTAssertEqual(colored.identity, player.identity)
        XCTAssertEqual(colored.revision, initial.revision + 2)
        XCTAssertEqual(
            colored.playerColorState?.playerColor,
            SourceVector3(0.24, 0.34, 0.41)
        )
        XCTAssertEqual(
            colored.playerColorState?.weaponColor,
            SourceVector3(0.30, 1.80, 2.10)
        )
        XCTAssertEqual(
            colored.renderState,
            initial.renderState,
            "Player material-proxy colors must not mutate Entity color32"
        )
        XCTAssertEqual(
            adapter.pendingCanonicalEntityOperationCount,
            3,
            "create plus two valid color mutations must retain FIFO order"
        )
    }

    func testOriginalSandboxPlayerSpawnReplicatesCanonicalColorsAmmoAndWeapons()
        throws {
        let configuration = GModPlayableSessionConfiguration(
            map: .construct,
            playerEntityIndex: 7,
            playerUserID: 70
        )
        let playerModel = SourceEntityModelReference(
            "models/player/kleiner.mdl"
        )
        let handsModel = SourceEntityModelReference(
            "models/weapons/c_arms_citizen.mdl"
        )
        // This fixture stands in for already-decoded Studio metadata only in
        // the route test. Production sessions resolve the same fields from
        // validated MDL/VVD/VTX bytes or an exact full-identity attestation.
        let playerBodyGroupLayout = try SourceStudioBodyGroupLayout(
            bodyParts: [
                .init(modelSelectionBase: 1, modelCount: 2),
                .init(modelSelectionBase: 2, modelCount: 3),
            ]
        )
        let handsBodyGroupLayout = try SourceStudioBodyGroupLayout(
            bodyParts: [
                .init(modelSelectionBase: 1, modelCount: 2),
                .init(modelSelectionBase: 2, modelCount: 1),
                .init(modelSelectionBase: 2, modelCount: 1),
                .init(modelSelectionBase: 2, modelCount: 1),
                .init(modelSelectionBase: 2, modelCount: 1),
                .init(modelSelectionBase: 2, modelCount: 1),
                .init(modelSelectionBase: 2, modelCount: 1),
            ]
        )
        let session = try GModPlayableSession(
            configuration: configuration,
            textMeasurer: nil,
            logger: { _, _ in },
            worldWalkCollisionProvider: nil,
            canonicalBodyGroupLayoutResolverForTesting: { model in
                if model == playerModel { return playerBodyGroupLayout }
                if model == handsModel { return handsBodyGroupLayout }
                return nil
            }
        )
        defer { _ = try? session.close() }
        let serverRegistry = try XCTUnwrap(session.serverRuntime.entityRegistry)
        let clientRegistry = try XCTUnwrap(session.clientRuntime.entityRegistry)
        let initialClient = try XCTUnwrap(
            clientRegistry.canonicalSnapshot(at: configuration.playerEntityIndex)
        )
        XCTAssertEqual(initialClient.playerColorState, .white)
        XCTAssertEqual(initialClient.playerAmmoState, .empty)

        let values = try session.serverRuntime.executeReturningValues(
            """
            local ok, message = pcall(
                hook.Call,
                "PlayerSpawn",
                GAMEMODE,
                Player(70),
                false
            )
            return ok, message
            """,
            sourceName: "=(original Sandbox PlayerSpawn hook)"
        )
        guard case let .boolean(completed)? = values.first else {
            return XCTFail("original PlayerSpawn result was malformed")
        }
        XCTAssertTrue(
            completed,
            "original Sandbox PlayerSpawn must complete through SetupHands: " +
                (values.dropFirst().first.map(String.init(describing:)) ?? "nil")
        )
        let authoredServer = try XCTUnwrap(
            serverRegistry.canonicalSnapshot(at: configuration.playerEntityIndex)
        )
        XCTAssertEqual(
            authoredServer.motion.playerObserverState?.mode,
            SourceCanonicalPlayerObserverMode.none
        )
        XCTAssertEqual(
            authoredServer.playerColorState?.playerColor,
            SourceVector3(0.24, 0.34, 0.41)
        )
        XCTAssertEqual(
            authoredServer.playerColorState?.weaponColor,
            SourceVector3(0.30, 1.80, 2.10)
        )
        XCTAssertEqual(authoredServer.model, playerModel)
        XCTAssertEqual(authoredServer.bodyValue, 0)
        let serverHandsIdentity = try XCTUnwrap(authoredServer.playerHands)
        let serverHands = try XCTUnwrap(
            serverRegistry.canonicalSnapshot(
                at: serverHandsIdentity.entryIndex
            )
        )
        XCTAssertEqual(serverHands.identity, serverHandsIdentity)
        XCTAssertEqual(serverHands.kind, .playerHands)
        XCTAssertEqual(serverHands.handsOwner, authoredServer.identity)
        XCTAssertEqual(serverHands.handsViewModelIndex, 0)
        XCTAssertEqual(serverHands.model, handsModel)
        XCTAssertEqual(serverHands.skin, 0)
        XCTAssertEqual(serverHands.bodyValue, 0)
        XCTAssertEqual(serverHands.lifecycle, .spawned)
        XCTAssertEqual(
            authoredServer.playerAmmoState?.entries,
            [
                .init(typeID: 1, typeName: "AR2", count: 100),
                .init(typeID: 2, typeName: "AR2AltFire", count: 6),
                .init(typeID: 3, typeName: "Pistol", count: 256),
                .init(typeID: 4, typeName: "SMG1", count: 256),
                .init(typeID: 5, typeName: "357", count: 32),
                .init(typeID: 6, typeName: "XBowBolt", count: 32),
                .init(typeID: 7, typeName: "Buckshot", count: 64),
                .init(typeID: 10, typeName: "Grenade", count: 5),
            ]
        )
        XCTAssertEqual(
            authoredServer.weaponInventory.weapons.map(\.className),
            [
                "weapon_crowbar",
                "weapon_pistol",
                "weapon_smg1",
                "weapon_frag",
                "weapon_physcannon",
                "weapon_crossbow",
                "weapon_shotgun",
                "weapon_357",
                "weapon_rpg",
                "weapon_ar2",
                "gmod_tool",
                "gmod_camera",
                "weapon_physgun",
            ],
            "original Player:Give calls must use the canonical Weapon inventory"
        )
        for record in authoredServer.weaponInventory.weapons {
            let weapon = try XCTUnwrap(
                serverRegistry.canonicalSnapshot(at: record.identity.entryIndex)
            )
            XCTAssertEqual(weapon.identity, record.identity)
            XCTAssertEqual(weapon.kind, .weapon)
            XCTAssertEqual(weapon.className, record.className)
        }
        XCTAssertEqual(
            clientRegistry.canonicalSnapshot(
                at: configuration.playerEntityIndex
            ),
            initialClient,
            "SERVER colors must wait for the canonical replication FIFO"
        )

        _ = try session.runFixedTick()
        let replicated = try XCTUnwrap(
            clientRegistry.canonicalSnapshot(at: configuration.playerEntityIndex)
        )
        let serverAfterTick = try XCTUnwrap(
            serverRegistry.canonicalSnapshot(at: configuration.playerEntityIndex)
        )
        XCTAssertEqual(replicated.identity, authoredServer.identity)
        XCTAssertEqual(replicated.playerColorState, serverAfterTick.playerColorState)
        XCTAssertEqual(replicated.playerAmmoState, serverAfterTick.playerAmmoState)
        XCTAssertEqual(
            replicated.weaponInventory,
            serverAfterTick.weaponInventory
        )
        XCTAssertEqual(replicated.playerHands, serverAfterTick.playerHands)
        let replicatedHands = try XCTUnwrap(
            clientRegistry.canonicalSnapshot(
                at: serverHandsIdentity.entryIndex
            )
        )
        XCTAssertEqual(replicatedHands.identity, serverHandsIdentity)
        XCTAssertEqual(replicatedHands.model, handsModel)
        XCTAssertEqual(replicatedHands.handsOwner, replicated.identity)
        try session.clientRuntime.execute(
            """
            local ply = Player(70)
            local playerColor = ply:GetPlayerColor()
            local weaponColor = ply:GetWeaponColor()
            assert(math.abs(playerColor.x - 0.24) < 0.000001)
            assert(math.abs(playerColor.y - 0.34) < 0.000001)
            assert(math.abs(playerColor.z - 0.41) < 0.000001)
            assert(math.abs(weaponColor.x - 0.30) < 0.000001)
            assert(math.abs(weaponColor.y - 1.80) < 0.000001)
            assert(math.abs(weaponColor.z - 2.10) < 0.000001)
            assert(ply:GetAmmoCount("Pistol") == 256)
            assert(ply:GetAmmoCount(4) == 256)
            assert(ply:GetAmmoCount("grenade") == 5)
            assert(ply:GetAmmoCount("AR2") == 100)
            assert(#ply:GetWeapons() == 13)
            assert(ply:HasWeapon("weapon_physgun"))
            assert(ply:GetNumBodyGroups() == 2)
            assert(ply:GetBodygroup(0) == 0)
            assert(ply:GetBodygroup(1) == 0)
            local hands = ply:GetHands()
            assert(IsValid(hands))
            assert(hands:GetClass() == "gmod_hands")
            assert(hands:GetOwner() == ply)
            assert(hands:GetModel() == "models/weapons/c_arms_citizen.mdl")
            assert(hands:GetSkin() == 0)
            assert(ply.SetPlayerColor == nil)
            assert(ply.SetWeaponColor == nil)
            assert(ply.GiveAmmo == nil)
            assert(ply.RemoveAllAmmo == nil)
            """,
            sourceName: "=(replicated canonical Player colors)"
        )
    }
}
