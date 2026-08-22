import Foundation
import XCTest
@testable import GModEngine
@testable import GModGameSession

private final class PhysgunWorldMissProvider:
    GMLuaTraceProvider,
    @unchecked Sendable
{
    var isWorldReady: Bool { true }

    func traceWorld(_ request: GMLuaTraceRequest) throws -> SourceGameTrace {
        SourceGameTrace(ray: request.ray)
    }
}

private final class PhysgunDynamicProvider:
    GMLuaDynamicTraceCandidateProvider,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var candidatesStorage: [GMLuaDynamicTraceCandidate] = []
    private var requestStorage: GMLuaTraceRequest?

    var isDynamicTraceReady: Bool { true }

    var candidates: [GMLuaDynamicTraceCandidate] {
        get {
            lock.lock()
            defer { lock.unlock() }
            return candidatesStorage
        }
        set {
            lock.lock()
            candidatesStorage = newValue
            lock.unlock()
        }
    }

    var lastRequest: GMLuaTraceRequest? {
        lock.lock()
        defer { lock.unlock() }
        return requestStorage
    }

    func dynamicTraceCandidates(
        for request: GMLuaTraceRequest
    ) throws -> [GMLuaDynamicTraceCandidate] {
        lock.lock()
        requestStorage = request
        let result = candidatesStorage
        lock.unlock()
        return result
    }

    func shouldCollide(
        queryCollisionGroup: Int32,
        candidateCollisionGroup: Int32
    ) -> Bool {
        queryCollisionGroup == 0 && candidateCollisionGroup == 0
    }
}

final class SourceCanonicalPhysgunGameplayTests: XCTestCase {
    func testNativeDefinitionPickupShadowMoveDropRejectAndStaleRemoval()
        throws
    {
        let model = SourceEntityModelReference(
            "models/props/physgun_target.mdl"
        )
        let propAsset = try makeAttestedPropPhysicsTestAsset(
            modelPath: model.path
        )
        let session = try GModPlayableSession(
            configuration: .init(map: .construct),
            textMeasurer: nil,
            logger: { _, _ in },
            worldWalkCollisionProvider: nil,
            canonicalModelValidator: { requested, kind in
                requested == model && kind == .propPhysics ? .valid : .invalid
            },
            canonicalPropPhysicsAssetResolverForTesting:
                makeAttestedPropPhysicsTestResolver(asset: propAsset)
        )
        defer { _ = try? session.close() }

        let dynamic = PhysgunDynamicProvider()
        session.serverRuntime.traceBridge?.connect(provider:
            GMLuaCompositeTraceProvider(
                world: PhysgunWorldMissProvider(),
                dynamic: dynamic
            )
        )
        try session.serverRuntime.execute(
            """
            local definition = weapons.Get("weapon_physgun")
            assert(istable(definition), "native weapon_physgun is missing")
            assert(definition.Primary.ClipSize == -1)
            assert(definition.Primary.DefaultClip == -1)
            assert(definition.Primary.Automatic == true)
            PHYSGUN_PICKUPS = 0
            PHYSGUN_DROPS = 0
            hook.Add("OnPhysgunPickup", "physgun_vertical_pickup", function(ply, ent)
                assert(ply == Player(\(session.configuration.playerUserID)))
                assert(ent:GetClass() == "prop_physics")
                PHYSGUN_PICKUPS = PHYSGUN_PICKUPS + 1
            end)
            hook.Add("PhysgunDrop", "physgun_vertical_drop", function(ply, ent)
                assert(ply == Player(\(session.configuration.playerUserID)))
                assert(ent:GetClass() == "prop_physics")
                PHYSGUN_DROPS = PHYSGUN_DROPS + 1
            end)
            local ply = Player(\(session.configuration.playerUserID))
            local weapon = ply:Give("weapon_physgun")
            assert(IsValid(weapon), "Player:Give did not return weapon_physgun")
            ply:SelectWeapon("weapon_physgun")
            """,
            sourceName: "=(native physgun definition and hook fixture)"
        )

        let initialized = try session.runFixedTick()
        XCTAssertEqual(initialized.weaponGameplay.failures, [])
        let initialPlayer = try canonicalPlayer(in: session)
        _ = try session.sourceAdapter.updateCanonicalEntity(
            initialPlayer.identity
        ) { state in
            // This is a physgun/controller contract test, not a bundled BSP
            // contact-material test. Use clear noclip space while retaining
            // the real session, dynamic trace, FIFO, and physics solver.
            state.transform.origin = SourceVector3(0, 0, 12_000)
            state.transform.angles = .zero
            state.motion.linearVelocity = .zero
            state.motion.isOnGround = false
            state.moveType = .noClip
        }
        _ = try session.runFixedTick(
            movementInput: .init(viewAngles: .zero)
        )
        let player = try canonicalPlayer(in: session)
        let weaponIdentity = try XCTUnwrap(
            player.weaponInventory.activeWeapon
        )
        let weapon = try XCTUnwrap(
            session.sourceAdapter.canonicalSnapshot(for: weaponIdentity)
        )
        XCTAssertEqual(weapon.className, "weapon_physgun")
        XCTAssertEqual(weapon.weaponHoldType, "physgun")

        let first = try createTarget(
            in: session,
            model: model,
            viewAngles: player.transform.angles
        )
        dynamic.candidates = [try candidate(for: first)]

        let pickup = try session.runFixedTick(
            movementInput: .init(buttons: [.attack])
        )
        XCTAssertEqual(pickup.weaponGameplay.failures, [])
        XCTAssertEqual(pickup.physgunGameplay.failures, [])
        XCTAssertEqual(pickup.physgunGameplay.events.map(\.kind), [.pickup])
        let pickupEvent = try XCTUnwrap(pickup.physgunGameplay.events.first)
        XCTAssertEqual(pickupEvent.player, player.identity)
        XCTAssertEqual(pickupEvent.weapon, weapon.identity)
        XCTAssertEqual(pickupEvent.entity, first.entity.identity)
        XCTAssertEqual(pickupEvent.bodyID, first.body.bodyID)
        XCTAssertEqual(
            dynamic.lastRequest?.mask,
            SourceMasks.shot.union(.grate)
        )
        XCTAssertEqual(
            Set(dynamic.lastRequest?.excludedEntityHandles ?? []),
            Set([player.identity.handle, weapon.identity.handle])
        )

        let beforeMove = try XCTUnwrap(
            session.sourceAdapter.canonicalPhysicsObject(for: first.body.bodyID)
        )
        let moved = try session.runFixedTick(
            movementInput: .init(
                viewAngles: SourceQAngle(pitch: 0, yaw: 20, roll: 0),
                buttons: [.attack]
            )
        )
        XCTAssertEqual(moved.physgunGameplay.failures, [])
        XCTAssertEqual(moved.physgunGameplay.events.map(\.kind), [.move])
        let afterMove = try XCTUnwrap(
            session.sourceAdapter.canonicalPhysicsObject(for: first.body.bodyID)
        )
        XCTAssertNotEqual(afterMove.transform.origin, beforeMove.transform.origin)
        XCTAssertLessThanOrEqual(
            afterMove.linearVelocity.length,
            SourceCanonicalPhysgunGameplayController.maximumLinearSpeed + 0.001
        )

        let drop = try session.runFixedTick(
            movementInput: .init(
                viewAngles: SourceQAngle(pitch: 0, yaw: 20, roll: 0)
            )
        )
        XCTAssertEqual(drop.physgunGameplay.failures, [])
        XCTAssertEqual(drop.physgunGameplay.events.map(\.kind), [.drop])
        let droppedBody = try XCTUnwrap(
            session.sourceAdapter.canonicalPhysicsObject(for: first.body.bodyID)
        )
        XCTAssertEqual(droppedBody.motionType, .dynamicBody)
        XCTAssertTrue(droppedBody.isMotionEnabled)

        let secondPlayer = try canonicalPlayer(in: session)
        let second = try createTarget(
            in: session,
            model: model,
            viewAngles: secondPlayer.transform.angles
        )
        dynamic.candidates = [try candidate(for: second)]
        try session.serverRuntime.execute(
            """
            hook.Add("PhysgunPickup", "physgun_vertical_reject", function(ply, ent)
                return false
            end)
            """,
            sourceName: "=(reject physgun pickup)"
        )
        let rejected = try session.runFixedTick(
            movementInput: .init(
                viewAngles: secondPlayer.transform.angles,
                buttons: [.attack]
            )
        )
        XCTAssertEqual(rejected.physgunGameplay.failures, [])
        XCTAssertEqual(rejected.physgunGameplay.events.map(\.kind), [.rejected])
        let rejectedBody = try XCTUnwrap(
            session.sourceAdapter.canonicalPhysicsObject(
                for: second.body.bodyID
            )
        )
        XCTAssertEqual(rejectedBody.linearVelocity.x, second.body.linearVelocity.x)
        XCTAssertEqual(rejectedBody.linearVelocity.y, second.body.linearVelocity.y)
        XCTAssertLessThan(
            rejectedBody.linearVelocity.z,
            second.body.linearVelocity.z,
            "the ordinary gravity step remains active after a rejected pickup"
        )

        _ = try session.runFixedTick(
            movementInput: .init(viewAngles: secondPlayer.transform.angles)
        )
        try session.serverRuntime.execute(
            "hook.Remove('PhysgunPickup', 'physgun_vertical_reject')",
            sourceName: "=(allow physgun pickup again)"
        )
        let secondCurrent = try XCTUnwrap(
            session.sourceAdapter.canonicalPhysicsObject(for: second.body.bodyID)
        )
        dynamic.candidates = [try candidate(
            entity: try XCTUnwrap(
                session.sourceAdapter.canonicalSnapshot(for: second.entity.identity)
            ),
            body: secondCurrent
        )]
        let reacquired = try session.runFixedTick(
            movementInput: .init(
                viewAngles: secondPlayer.transform.angles,
                buttons: [.attack]
            )
        )
        XCTAssertEqual(reacquired.physgunGameplay.events.map(\.kind), [.pickup])

        _ = try session.sourceAdapter.markCanonicalEntityForRemoval(
            second.entity.identity
        )
        let stale = try session.runFixedTick(
            movementInput: .init(
                viewAngles: secondPlayer.transform.angles,
                buttons: [.attack]
            )
        )
        XCTAssertEqual(stale.physgunGameplay.failures, [])
        XCTAssertEqual(
            stale.physgunGameplay.events.map(\.kind),
            [.staleHoldCleared]
        )
        XCTAssertNil(
            session.sourceAdapter.canonicalPhysicsObject(for: second.body.bodyID)
        )

        try session.serverRuntime.execute(
            """
            assert(PHYSGUN_PICKUPS == 2, "pickup hook count " .. tostring(PHYSGUN_PICKUPS))
            assert(PHYSGUN_DROPS == 1, "drop hook count " .. tostring(PHYSGUN_DROPS))
            """,
            sourceName: "=(physgun hook counts)"
        )
    }

    func testPersistenceStateUsesCanonicalSnapshotAndClientFIFO() throws {
        let session = try GModPlayableSession(
            configuration: .init(map: .construct),
            textMeasurer: nil,
            logger: { _, _ in }
        )
        defer { _ = try? session.close() }
        let player = try canonicalPlayer(in: session)

        try session.serverRuntime.execute(
            """
            local ply = Player(\(session.configuration.playerUserID))
            assert(ply:GetPersistent() == false)
            ply:SetPersistent(true)
            assert(ply:GetPersistent() == true)
            """,
            sourceName: "=(canonical persistence SERVER ABI)"
        )
        _ = try session.runFixedTick()
        XCTAssertTrue(
            try XCTUnwrap(
                session.sourceAdapter.canonicalSnapshot(for: player.identity)
            ).isPersistent
        )
        let clientPlayer = try XCTUnwrap(
            session.clientCanonicalEntitySnapshots.first {
                $0.identity == player.identity
            }
        )
        XCTAssertTrue(clientPlayer.isPersistent)
        try session.clientRuntime.execute(
            """
            assert(LocalPlayer():GetPersistent() == true)
            """,
            sourceName: "=(canonical persistence CLIENT FIFO projection)"
        )
    }

    private struct Target {
        let entity: SourceCanonicalEntitySnapshot
        let body: SourceCanonicalPhysicsObjectSnapshot
    }

    private func createTarget(
        in session: GModPlayableSession,
        model: SourceEntityModelReference,
        viewAngles: SourceQAngle
    ) throws -> Target {
        let player = try canonicalPlayer(in: session)
        let eye = player.transform.origin + player.viewOffset
        var state = SourceCanonicalEntityState.defaults(for: .propPhysics)
        // Keep the focused fixture inside the clear space immediately around
        // info_player_start; 128 units from gm_construct's authored spawn can
        // already overlap a brush and turn this into a BSP material test.
        state.transform.origin = eye + viewAngles.sourceBasis.forward * 48
        state.model = model
        let created = try session.sourceAdapter.createCanonicalEntity(
            kind: .propPhysics,
            state: state
        )
        _ = try session.sourceAdapter.spawnCanonicalEntity(created.identity)
        _ = try session.sourceAdapter.activateCanonicalEntity(created.identity)
        _ = try session.runFixedTick(
            movementInput: .init(viewAngles: viewAngles)
        )
        let entity = try XCTUnwrap(
            session.sourceAdapter.canonicalSnapshot(for: created.identity)
        )
        let body = try XCTUnwrap(
            session.sourceAdapter.primaryCanonicalPhysicsObject(
                for: created.identity
            )
        )
        return Target(entity: entity, body: body)
    }

    private func candidate(for target: Target) throws
        -> GMLuaDynamicTraceCandidate
    {
        try candidate(entity: target.entity, body: target.body)
    }

    private func candidate(
        entity: SourceCanonicalEntitySnapshot,
        body: SourceCanonicalPhysicsObjectSnapshot
    ) throws -> GMLuaDynamicTraceCandidate {
        let basis = body.transform.angles.sourceBasis
        let origin = body.transform.origin
        let physicsBone = try XCTUnwrap(Int16(exactly: body.bodyID.solidIndex))
        return GMLuaDynamicTraceCandidate(
            identity: entity.identity,
            className: entity.className,
            collisionGroup: entity.collisionGroup,
            studioHitboxes: [try GMLuaDynamicStudioHitbox(
                minimum: SourceVector3(-12, -12, -12),
                maximum: SourceVector3(12, 12, 12),
                boneToWorld: SourceStudioMatrix3x4(
                    basis.forward.x, -basis.right.x, basis.up.x, origin.x,
                    basis.forward.y, -basis.right.y, basis.up.y, origin.y,
                    basis.forward.z, -basis.right.z, basis.up.z, origin.z
                ),
                contents: .solid,
                surface: SourceTraceSurface(name: "canonical_physgun_target"),
                hitBox: 0,
                hitGroup: 0,
                physicsBone: physicsBone
            )]
        )
    }

    private func canonicalPlayer(
        in session: GModPlayableSession
    ) throws -> SourceCanonicalEntitySnapshot {
        try XCTUnwrap(
            session.sourceAdapter.canonicalEntitySnapshots.first {
                $0.kind == .player
            }
        )
    }
}
