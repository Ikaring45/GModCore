import XCTest
import GModLua
@testable import GModEngine
@testable import GModGameSession

final class SourceCanonicalWeaponPickupIntegrationTests: XCTestCase {
    func testDroppedWeaponContactPickupPreservesHandleStateReplicationAndRenderRemoval() throws {
        let validation = PickupModelValidationProbe()
        let session = try makeSession(validation: validation)
        defer { _ = try? session.close() }
        let player = try canonicalPlayer(in: session)

        try session.serverRuntime.execute(
            """
            PICKUP_CAN_CALLS = 0
            PICKUP_EQUIP_CALLS = 0
            hook.Add("PlayerCanPickupWeapon", "CanonicalPickupPermission", function(ply, wep)
                PICKUP_CAN_CALLS = PICKUP_CAN_CALLS + 1
                assert(ply == Player(\(session.configuration.playerUserID)))
                assert(wep:GetClass() == "gmod_tool")
                return true
            end)
            hook.Add("WeaponEquip", "CanonicalPickupEquip", function(wep, ply)
                if wep:GetClass() ~= "gmod_tool" then return end
                PICKUP_EQUIP_CALLS = PICKUP_EQUIP_CALLS + 1
                assert(ply == Player(\(session.configuration.playerUserID)))
                assert(not IsValid(wep:GetOwner()))
            end)
            local ply = Player(\(session.configuration.playerUserID))
            local wep = ply:Give("gmod_tool")
            ply:SelectWeapon("gmod_tool")
            """,
            sourceName: "=(canonical pickup stock tool setup)"
        )
        let initialized = try session.runFixedTick()
        XCTAssertEqual(initialized.weaponGameplay.failures, [])
        let held = try weapon(className: "gmod_tool", in: session)
        XCTAssertNotNil(held.model, "real SWEP WorldModel validation must succeed")
        XCTAssertTrue(validation.requests.contains(
            SourceEntityModelReference("models/weapons/w_toolgun.mdl")
        ))

        _ = try session.sourceAdapter.updateCanonicalEntity(held.identity) {
            $0.weaponRuntime.clip1 = 17
            $0.weaponRuntime.nextPrimaryFire = 9.5
            $0.weaponRuntime.floatNetworkVariables = [42.25]
        }
        try session.serverRuntime.execute(
            """
            local ply = Player(\(session.configuration.playerUserID))
            local wep = ply:GetWeapon("gmod_tool")
            ply:DropWeapon(wep, Vector(96, 32, 48), Vector(8, 4, 2))
            assert(not IsValid(wep:GetOwner()))
            """,
            sourceName: "=(canonical pickup drop exact weapon)"
        )
        _ = try session.runFixedTick()

        let dropped = try weapon(className: "gmod_tool", in: session)
        XCTAssertEqual(dropped.identity, held.identity)
        XCTAssertEqual(dropped.weaponRuntime.clip1, 17)
        XCTAssertEqual(dropped.weaponRuntime.nextPrimaryFire, 9.5)
        XCTAssertEqual(dropped.weaponRuntime.floatNetworkVariables, [42.25])
        XCTAssertEqual(dropped.transform.origin, SourceVector3(96, 32, 48))
        XCTAssertEqual(dropped.motion.linearVelocity, SourceVector3(8, 4, 2))
        let droppedScene = try XCTUnwrap(
            session.clientDynamicEntityRenderScene(ifChangedFrom: nil)
        )
        XCTAssertTrue(
            droppedScene.instances.contains { $0.identity == dropped.identity },
            "unowned replicated Weapon must use the dynamic world-model path"
        )

        let pickupTick = try session.runFixedTick(
            weaponPickupContactCandidates: [dropped.identity]
        )
        let pickup = try XCTUnwrap(pickupTick.weaponPickup.attempts.first)
        XCTAssertEqual(pickup.disposition, .pickedUp)
        XCTAssertEqual(pickup.callbackFailures, [])
        let pickedServer = try weapon(className: "gmod_tool", in: session)
        XCTAssertEqual(pickedServer.identity, dropped.identity)
        XCTAssertEqual(pickedServer.weaponRuntime.clip1, 17)
        XCTAssertEqual(pickedServer.weaponRuntime.nextPrimaryFire, 9.5)
        XCTAssertEqual(pickedServer.weaponRuntime.floatNetworkVariables, [42.25])
        let playerAfterPickup = try canonicalPlayer(in: session)
        XCTAssertEqual(
            playerAfterPickup.weaponInventory.weapon(className: "gmod_tool")?.identity,
            dropped.identity
        )

        let replicatedPlayer = try XCTUnwrap(
            session.clientCanonicalEntitySnapshots.first {
                $0.identity == player.identity
            }
        )
        XCTAssertEqual(
            replicatedPlayer.weaponInventory.weapon(className: "gmod_tool")?.identity,
            dropped.identity
        )
        let replicatedWeapon = try XCTUnwrap(
            session.clientCanonicalEntitySnapshots.first {
                $0.identity == dropped.identity
            }
        )
        XCTAssertEqual(replicatedWeapon.weaponRuntime, pickedServer.weaponRuntime)
        let heldScene = try XCTUnwrap(
            session.clientDynamicEntityRenderScene(
                ifChangedFrom: droppedScene.revision
            )
        )
        XCTAssertFalse(heldScene.instances.contains {
            $0.identity == dropped.identity
        })
        XCTAssertEqual(numberGlobal("PICKUP_CAN_CALLS", in: session), 1)
        XCTAssertEqual(numberGlobal("PICKUP_EQUIP_CALLS", in: session), 1)
    }

    func testUsePermissionAndForcedPickupUseOriginalHookBoundary() throws {
        let session = try makeSession(validation: PickupModelValidationProbe())
        defer { _ = try? session.close() }

        try session.serverRuntime.execute(
            """
            USE_PICKUP_CALLS = 0
            CAN_PICKUP_CALLS = 0
            DENY_USE = true
            hook.Add("PlayerUse", "CanonicalPickupUse", function(ply, wep)
                if wep:GetClass() ~= "gmod_tool" then return end
                USE_PICKUP_CALLS = USE_PICKUP_CALLS + 1
                return not DENY_USE
            end)
            hook.Add("PlayerCanPickupWeapon", "CanonicalPickupDeny", function(ply, wep)
                if wep:GetClass() ~= "gmod_tool" then return end
                CAN_PICKUP_CALLS = CAN_PICKUP_CALLS + 1
                return false
            end)
            local ply = Player(\(session.configuration.playerUserID))
            ply:Give("gmod_tool")
            ply:SelectWeapon("gmod_tool")
            """,
            sourceName: "=(canonical pickup permission fixture)"
        )
        _ = try session.runFixedTick()
        var worldWeapon = try weapon(className: "gmod_tool", in: session)
        try session.serverRuntime.execute(
            """
            local ply = Player(\(session.configuration.playerUserID))
            ply:DropWeapon(ply:GetWeapon("gmod_tool"), Vector(16, 0, 64))
            """,
            sourceName: "=(canonical pickup use drop)"
        )
        worldWeapon = try weapon(className: "gmod_tool", in: session)

        let deniedTick = try session.runFixedTick(
            movementInput: .init(buttons: [.use]),
            weaponPickupUseTarget: worldWeapon.identity
        )
        let deniedUse = deniedTick.weaponPickup
        XCTAssertEqual(deniedUse.attempts.map(\.disposition), [
            .deniedByPlayerUse,
        ])
        XCTAssertNil(
            try canonicalPlayer(in: session).weaponInventory.weapon(
                className: "gmod_tool"
            )
        )
        XCTAssertEqual(numberGlobal("USE_PICKUP_CALLS", in: session), 1)
        XCTAssertEqual(numberGlobal("CAN_PICKUP_CALLS", in: session), 0)

        try session.serverRuntime.execute(
            """
            DENY_USE = false
            local ply = Player(\(session.configuration.playerUserID))
            local wep = Entity(\(worldWeapon.identity.entryIndex))
            assert(ply:PickupWeapon(wep, true) == false)
            assert(not ply:HasWeapon("gmod_tool"))
            assert(ply:PickupWeapon(wep) == true)
            assert(ply:GetWeapon("gmod_tool") == wep)
            """,
            sourceName: "=(forced Player PickupWeapon bypass)"
        )
        XCTAssertEqual(numberGlobal("CAN_PICKUP_CALLS", in: session), 0)
        XCTAssertEqual(
            try canonicalPlayer(in: session)
                .weaponInventory.weapon(className: "gmod_tool")?.identity,
            worldWeapon.identity
        )
    }

    private func canonicalPlayer(
        in session: GModPlayableSession
    ) throws -> SourceCanonicalEntitySnapshot {
        try XCTUnwrap(session.sourceAdapter.canonicalEntitySnapshots.first {
            $0.kind == .player
        })
    }

    private func weapon(
        className: String,
        in session: GModPlayableSession
    ) throws -> SourceCanonicalEntitySnapshot {
        try XCTUnwrap(session.sourceAdapter.canonicalEntitySnapshots.first {
            $0.kind == .weapon &&
                $0.className.caseInsensitiveCompare(className) == .orderedSame
        })
    }

    private func numberGlobal(
        _ name: String,
        in session: GModPlayableSession
    ) -> Double? {
        guard case let .number(value) = session.serverRuntime.state.getGlobal(name)
        else { return nil }
        return value
    }

    private func makeSession(
        validation: PickupModelValidationProbe
    ) throws -> GModPlayableSession {
        let cache = try GModStudioRenderableModelCache(
            policy: .init(
                maximumEntryCount: 8,
                maximumGeometryByteCount: 4_096
            ),
            compile: { model, bodyValue, skinFamilyIndex in
                let normalized = model.path.lowercased()
                let checksum: Int32 = 0x1234_5678
                return .resolved(GModStudioRenderableModelResource(
                    id: .init(
                        normalizedModelPath: normalized,
                        checksum: checksum,
                        bodyValue: bodyValue,
                        skinFamilyIndex: skinFamilyIndex
                    ),
                    model: .init(
                        checksum: checksum,
                        modelName: normalized,
                        lodIndex: 0,
                        bodyValue: bodyValue,
                        skinFamilyIndex: skinFamilyIndex,
                        vertices: [
                            .init(
                                position: .zero,
                                normal: SourceVector3(0, 0, 1),
                                textureCoordinate: .init(u: 0, v: 0)
                            ),
                        ],
                        indices: [],
                        drawRanges: []
                    )
                ))
            }
        )
        return try GModPlayableSession(
            configuration: .init(),
            textMeasurer: nil,
            logger: { _, _ in },
            worldWalkCollisionProvider: nil,
            canonicalModelValidator: { model, kind in
                validation.validate(model, kind: kind)
            },
            studioRenderableModelCacheForTesting: cache
        )
    }
}

private final class PickupModelValidationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var requestsStorage: [SourceEntityModelReference] = []

    var requests: [SourceEntityModelReference] {
        lock.lock()
        defer { lock.unlock() }
        return requestsStorage
    }

    func validate(
        _ model: SourceEntityModelReference,
        kind: SourceCanonicalEntityKind
    ) -> SourceCanonicalModelValidation {
        lock.lock()
        requestsStorage.append(model)
        lock.unlock()
        guard kind == .weapon,
              model.path.caseInsensitiveCompare(
                "models/weapons/w_toolgun.mdl"
              ) == .orderedSame else { return .invalid }
        return .valid
    }
}
