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
            PHYSGUN_FREEZES = 0
            PHYSGUN_UNFREEZES = 0
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
            hook.Add("PlayerFrozeObject", "physgun_vertical_freeze", function(ply, ent, phys)
                assert(ply == Player(\(session.configuration.playerUserID)))
                assert(ent:GetClass() == "prop_physics")
                assert(IsValid(phys))
                PHYSGUN_FREEZES = PHYSGUN_FREEZES + 1
            end)
            hook.Add("PlayerUnfrozeObject", "physgun_vertical_unfreeze", function(ply, ent, phys)
                assert(ply == Player(\(session.configuration.playerUserID)))
                assert(ent:GetClass() == "prop_physics")
                assert(IsValid(phys))
                PHYSGUN_UNFREEZES = PHYSGUN_UNFREEZES + 1
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

        try session.serverRuntime.execute(
            """
            hook.Add("OnPhysgunFreeze", "physgun_vertical_freeze_reject", function()
                return false
            end)
            """,
            sourceName: "=(intercept physgun freeze)"
        )
        let interceptedFreeze = try session.runFixedTick(
            movementInput: .init(
                viewAngles: SourceQAngle(pitch: 0, yaw: 20, roll: 0),
                buttons: [.attack, .attack2]
            )
        )
        XCTAssertEqual(interceptedFreeze.physgunGameplay.failures, [])
        XCTAssertEqual(
            interceptedFreeze.physgunGameplay.events.map(\.kind),
            [.freezeIntercepted, .drop]
        )
        XCTAssertTrue(try XCTUnwrap(
            session.sourceAdapter.canonicalPhysicsObject(for: first.body.bodyID)
        ).isMotionEnabled)

        // A rejected freeze releases the prop with its current velocity. Put
        // the fixture back on the sight line through the authoritative FIFO
        // so the next assertion measures pickup/unfreeze rather than a trace
        // miss caused by that ordinary post-drop inertia.
        let playerAfterIntercept = try canonicalPlayer(in: session)
        let yawTwenty = SourceQAngle(pitch: 0, yaw: 20, roll: 0)
        let resetOrigin = playerAfterIntercept.transform.origin +
            playerAfterIntercept.viewOffset + yawTwenty.sourceBasis.forward * 48
        for mutation in [
            SourcePhysicsBodyMutation.setPosition(resetOrigin, teleport: true),
            .setLinearVelocity(.zero),
            .setAngularVelocity(.zero),
        ] {
            try session.sourceAdapter.enqueueCanonicalPhysicsObjectMutation(
                SourcePhysicsBodyMutationCommand(
                    bodyID: first.body.bodyID,
                    mutation: mutation
                )
            )
        }
        _ = try session.runFixedTick(
            movementInput: .init(
                viewAngles: yawTwenty
            )
        )
        try session.serverRuntime.execute(
            "hook.Remove('OnPhysgunFreeze', 'physgun_vertical_freeze_reject')",
            sourceName: "=(allow stock physgun freeze)"
        )
        let firstAfterIntercept = try XCTUnwrap(
            session.sourceAdapter.canonicalPhysicsObject(for: first.body.bodyID)
        )
        dynamic.candidates = [try candidate(
            entity: try XCTUnwrap(
                session.sourceAdapter.canonicalSnapshot(for: first.entity.identity)
            ),
            body: firstAfterIntercept
        )]
        let repickupBeforeFreeze = try session.runFixedTick(
            movementInput: .init(
                viewAngles: yawTwenty,
                buttons: [.attack]
            )
        )
        XCTAssertEqual(repickupBeforeFreeze.physgunGameplay.failures, [])
        XCTAssertEqual(repickupBeforeFreeze.physgunGameplay.events.map(\.kind), [.pickup])

        let freeze = try session.runFixedTick(
            movementInput: .init(
                viewAngles: yawTwenty,
                buttons: [.attack, .attack2]
            )
        )
        XCTAssertEqual(freeze.physgunGameplay.failures, [])
        XCTAssertEqual(freeze.physgunGameplay.events.map(\.kind), [.freeze, .drop])
        let frozenBody = try XCTUnwrap(
            session.sourceAdapter.canonicalPhysicsObject(for: first.body.bodyID)
        )
        XCTAssertEqual(frozenBody.motionType, .dynamicBody)
        XCTAssertFalse(frozenBody.isMotionEnabled)

        dynamic.candidates = [try candidate(
            entity: try XCTUnwrap(
                session.sourceAdapter.canonicalSnapshot(for: first.entity.identity)
            ),
            body: frozenBody
        )]
        try session.serverRuntime.execute(
            """
            hook.Add("OnPhysgunReload", "physgun_vertical_reload_reject", function()
                return false
            end)
            """,
            sourceName: "=(intercept physgun reload)"
        )
        let interceptedReload = try session.runFixedTick(
            movementInput: .init(
                viewAngles: yawTwenty,
                buttons: [.reload]
            )
        )
        XCTAssertEqual(interceptedReload.physgunGameplay.failures, [])
        XCTAssertEqual(interceptedReload.physgunGameplay.events, [])
        XCTAssertFalse(try XCTUnwrap(
            session.sourceAdapter.canonicalPhysicsObject(for: first.body.bodyID)
        ).isMotionEnabled)

        _ = try session.runFixedTick(
            movementInput: .init(viewAngles: yawTwenty)
        )
        try session.serverRuntime.execute(
            """
            hook.Remove("OnPhysgunReload", "physgun_vertical_reload_reject")
            hook.Add("CanPlayerUnfreeze", "physgun_vertical_unfreeze_reject", function()
                return false
            end)
            """,
            sourceName: "=(reject targeted physgun unfreeze)"
        )
        let rejectedUnfreeze = try session.runFixedTick(
            movementInput: .init(
                viewAngles: yawTwenty,
                buttons: [.reload]
            )
        )
        XCTAssertEqual(rejectedUnfreeze.physgunGameplay.failures, [])
        XCTAssertEqual(
            rejectedUnfreeze.physgunGameplay.events.map(\.kind),
            [.unfreezeRejected]
        )
        XCTAssertFalse(try XCTUnwrap(
            session.sourceAdapter.canonicalPhysicsObject(for: first.body.bodyID)
        ).isMotionEnabled)

        _ = try session.runFixedTick(
            movementInput: .init(viewAngles: yawTwenty)
        )
        try session.serverRuntime.execute(
            "hook.Remove('CanPlayerUnfreeze', 'physgun_vertical_unfreeze_reject')",
            sourceName: "=(allow targeted physgun unfreeze)"
        )
        let unfreeze = try session.runFixedTick(
            movementInput: .init(
                viewAngles: yawTwenty,
                buttons: [.reload]
            )
        )
        XCTAssertEqual(unfreeze.physgunGameplay.failures, [])
        XCTAssertEqual(unfreeze.physgunGameplay.events.map(\.kind), [.unfreeze])
        XCTAssertTrue(try XCTUnwrap(
            session.sourceAdapter.canonicalPhysicsObject(for: first.body.bodyID)
        ).isMotionEnabled)

        // Re-freeze the already tracked fixture through the authoritative
        // mutation queue so the existing pickup path still proves that taking
        // hold of a frozen body enables motion on the next fixed tick.
        try session.sourceAdapter.enqueueCanonicalPhysicsObjectMutation(
            SourcePhysicsBodyMutationCommand(
                bodyID: first.body.bodyID,
                mutation: .setMotionEnabled(false)
            )
        )
        _ = try session.runFixedTick(
            movementInput: .init(viewAngles: yawTwenty)
        )
        try session.serverRuntime.execute(
            """
            PHYSGUN_ADDON_UNFREEZE = 0
            local playerMeta = assert(FindMetaTable("Player"))
            playerMeta.PhysgunUnfreeze = function(self)
                assert(self == Player(\(session.configuration.playerUserID)))
                PHYSGUN_ADDON_UNFREEZE = PHYSGUN_ADDON_UNFREEZE + 1
                return 77
            end
            """,
            sourceName: "=(addon-owned physgun unfreeze override)"
        )
        let addonReload = try session.runFixedTick(
            movementInput: .init(
                viewAngles: yawTwenty,
                buttons: [.reload]
            )
        )
        XCTAssertEqual(addonReload.physgunGameplay.failures, [])
        XCTAssertEqual(addonReload.physgunGameplay.events, [])
        XCTAssertFalse(try XCTUnwrap(
            session.sourceAdapter.canonicalPhysicsObject(for: first.body.bodyID)
        ).isMotionEnabled)
        try session.serverRuntime.execute(
            "assert(PHYSGUN_ADDON_UNFREEZE == 1)",
            sourceName: "=(addon physgun unfreeze override retained)"
        )
        dynamic.candidates = [try candidate(
            entity: try XCTUnwrap(
                session.sourceAdapter.canonicalSnapshot(for: first.entity.identity)
            ),
            body: try XCTUnwrap(
                session.sourceAdapter.canonicalPhysicsObject(for: first.body.bodyID)
            )
        )]
        let pickupFrozen = try session.runFixedTick(
            movementInput: .init(
                viewAngles: yawTwenty,
                buttons: [.attack]
            )
        )
        XCTAssertEqual(pickupFrozen.physgunGameplay.failures, [])
        XCTAssertEqual(pickupFrozen.physgunGameplay.events.map(\.kind), [.pickup])
        XCTAssertTrue(try XCTUnwrap(
            session.sourceAdapter.canonicalPhysicsObject(for: first.body.bodyID)
        ).isMotionEnabled)

        let drop = try session.runFixedTick(
            movementInput: .init(
                viewAngles: yawTwenty
            )
        )
        XCTAssertEqual(drop.physgunGameplay.failures, [])
        XCTAssertEqual(drop.physgunGameplay.events.map(\.kind), [.drop])
        let droppedBody = try XCTUnwrap(
            session.sourceAdapter.canonicalPhysicsObject(for: first.body.bodyID)
        )
        XCTAssertEqual(droppedBody.motionType, .dynamicBody)
        XCTAssertTrue(droppedBody.isMotionEnabled)

        // The next test prop is spawned on the same deterministic sight-line
        // fixture. Remove the completed first prop before creating it so this
        // controller test does not depend on a prop-vs-prop material pair.
        _ = try session.sourceAdapter.markCanonicalEntityForRemoval(
            first.entity.identity
        )
        _ = try session.runFixedTick(
            movementInput: .init(viewAngles: yawTwenty)
        )
        XCTAssertNil(
            session.sourceAdapter.canonicalPhysicsObject(for: first.body.bodyID)
        )

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
            assert(PHYSGUN_PICKUPS == 4, "pickup hook count " .. tostring(PHYSGUN_PICKUPS))
            assert(PHYSGUN_DROPS == 3, "drop hook count " .. tostring(PHYSGUN_DROPS))
            assert(PHYSGUN_FREEZES == 1, "freeze hook count " .. tostring(PHYSGUN_FREEZES))
            assert(PHYSGUN_UNFREEZES == 1, "unfreeze hook count " .. tostring(PHYSGUN_UNFREEZES))
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
