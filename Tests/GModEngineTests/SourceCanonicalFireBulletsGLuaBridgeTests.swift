import XCTest
import GModLua
@testable import GModEngine
@testable import GModGameSession

private struct FireBulletsWorldMissProvider: GMLuaTraceProvider {
    var isWorldReady: Bool { true }

    func traceWorld(_ request: GMLuaTraceRequest) throws -> SourceGameTrace {
        SourceGameTrace(ray: request.ray)
    }
}

private final class FireBulletsDynamicTargetProvider:
    GMLuaDynamicTraceCandidateProvider, @unchecked Sendable
{
    private let lock = NSLock()
    private var target: SourceCanonicalEntityIdentity?
    private var center = SourceVector3.zero
    private var requestsStorage: [GMLuaTraceRequest] = []

    var isDynamicTraceReady: Bool { true }

    var requests: [GMLuaTraceRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requestsStorage
    }

    func setTarget(
        _ target: SourceCanonicalEntityIdentity,
        center: SourceVector3
    ) {
        lock.lock()
        self.target = target
        self.center = center
        lock.unlock()
    }

    func dynamicTraceCandidates(
        for request: GMLuaTraceRequest
    ) throws -> [GMLuaDynamicTraceCandidate] {
        lock.lock()
        requestsStorage.append(request)
        let target = target
        let center = center
        lock.unlock()
        guard let target else { return [] }
        return [GMLuaDynamicTraceCandidate(
            identity: target,
            className: "player",
            collisionGroup: 0,
            studioHitboxes: [try GMLuaDynamicStudioHitbox(
                minimum: SourceVector3(-32, -32, -32),
                maximum: SourceVector3(32, 32, 32),
                boneToWorld: SourceStudioMatrix3x4(
                    1, 0, 0, center.x,
                    0, 1, 0, center.y,
                    0, 0, 1, center.z
                ),
                contents: [.monster, .hitbox],
                surface: SourceTraceSurface(name: "player_hitbox"),
                hitBox: 0,
                hitGroup: 0,
                physicsBone: 0
            )]
        )]
    }

    func shouldCollide(
        queryCollisionGroup: Int32,
        candidateCollisionGroup: Int32
    ) -> Bool {
        queryCollisionGroup == 0 && candidateCollisionGroup == 0
    }
}

final class SourceCanonicalFireBulletsGLuaBridgeTests: XCTestCase {
    func testOriginalBasePrimaryAttackConsumesClipTracesDamagesAndReplicatesEvent()
        throws
    {
        let session = try GModPlayableSession(
            configuration: .init(),
            textMeasurer: nil,
            logger: { _, _ in }
        )
        defer { _ = try? session.close() }

        let shooter = try XCTUnwrap(
            session.sourceAdapter.canonicalEntitySnapshots.first {
                $0.kind == .player && $0.identity.entryIndex ==
                    session.configuration.playerEntityIndex
            }
        )
        _ = try session.sourceAdapter.updateCanonicalEntity(
            shooter.identity
        ) { state in
            state.moveType = .noClip
            state.motion.linearVelocity = .zero
            state.motion.baseVelocity = .zero
            state.motion.outputWishVelocity = .zero
        }

        var targetState = SourceCanonicalEntityState.defaults(for: .player)
        targetState.moveType = .noClip
        let targetCreated = try session.sourceAdapter.createCanonicalEntity(
            kind: .player,
            at: 2,
            state: targetState,
            playerUserID: 2
        )
        _ = try session.sourceAdapter.spawnCanonicalEntity(
            targetCreated.identity
        )
        let target = try session.sourceAdapter.activateCanonicalEntity(
            targetCreated.identity
        )

        let dynamic = FireBulletsDynamicTargetProvider()
        let shootPosition = shooter.transform.origin + shooter.viewOffset
        dynamic.setTarget(
            target.identity,
            center: shootPosition +
                shooter.transform.angles.sourceBasis.forward * 256
        )
        session.serverRuntime.traceBridge?.connect(
            provider: GMLuaCompositeTraceProvider(
                world: FireBulletsWorldMissProvider(),
                dynamic: dynamic
            )
        )

        try session.serverRuntime.execute(
            """
            FIRE_BULLETS_ORDER = {}
            hook.Add("EntityFireBullets", "canonical_acceptance", function(ent, data)
                FIRE_BULLETS_ORDER[#FIRE_BULLETS_ORDER + 1] = "hook"
                assert(ent == Player(\(session.configuration.playerUserID)))
                assert(data.Src == ent:GetShootPos())
                assert(data.Dir == ent:GetAimVector())
                assert(data.Num == 1)
                assert(data.AmmoType == "Pistol")
                data.Damage = 25
                data.Distance = 1024
                data.Tracer = 2
                data.Force = 3
                return true
            end)
            weapons.Register({
                Base = "weapon_base",
                PrintName = "Canonical FireBullets Acceptance",
                Primary = {
                    ClipSize = 8,
                    DefaultClip = 4,
                    Automatic = false,
                    Ammo = "Pistol"
                },
                Secondary = {
                    ClipSize = -1,
                    DefaultClip = -1,
                    Automatic = false,
                    Ammo = "none"
                }
            }, "weapon_firebullets_acceptance")
            local ply = Player(\(session.configuration.playerUserID))
            assert(IsValid(ply:Give("weapon_firebullets_acceptance")))
            ply:SelectWeapon("weapon_firebullets_acceptance")
            """,
            sourceName: "=(register original base FireBullets acceptance)"
        )

        let initial = try session.runFixedTick(
            movementInput: GModPlayableMovementInput()
        )
        XCTAssertEqual(initial.actionFailures, [])
        XCTAssertEqual(initial.weaponGameplay.failures, [])
        let before = try activeWeapon(in: session, player: shooter.identity)
        XCTAssertEqual(before.weaponRuntime.clip1, 4)

        let fired = try session.runFixedTick(
            movementInput: GModPlayableMovementInput(buttons: [.attack])
        )
        XCTAssertEqual(fired.actionFailures, [])
        XCTAssertEqual(fired.weaponGameplay.failures, [])
        XCTAssertTrue(fired.weaponGameplay.invocations.contains {
            $0.className == "weapon_firebullets_acceptance" &&
                $0.invocation == .primaryAttack
        })

        let weapon = try activeWeapon(in: session, player: shooter.identity)
        XCTAssertEqual(weapon.weaponRuntime.clip1, 3)
        let damaged = try snapshot(target.identity, in: session)
        XCTAssertEqual(damaged.combat.health, 75)
        XCTAssertEqual(
            session.clientCanonicalEntitySnapshots.first {
                $0.identity == target.identity
            }?.combat.health,
            75
        )
        XCTAssertEqual(
            session.clientCanonicalEntitySnapshots.first {
                $0.identity == weapon.identity
            }?.weaponRuntime.clip1,
            3
        )
        XCTAssertEqual(dynamic.requests.count, 1)
        XCTAssertEqual(dynamic.requests[0].kind, .line)
        XCTAssertEqual(dynamic.requests[0].mask, SourceMasks.shot)
        XCTAssertEqual(
            dynamic.requests[0].excludedEntityHandles,
            [shooter.identity.handle]
        )

        try session.serverRuntime.execute(
            """
            assert(#FIRE_BULLETS_ORDER == 1)
            assert(FIRE_BULLETS_ORDER[1] == "hook")
            """,
            sourceName: "=(verify EntityFireBullets hook order)"
        )

        let deliveries = try XCTUnwrap(
            session.clientToolActionBridge.clientEventState
        ).capturedDeliveries
        let bulletEvents = deliveries.compactMap { delivery -> (
            UInt64,
            GMLuaFireBulletsEvent
        )? in
            guard case let .fireBullets(event) = delivery.payload else {
                return nil
            }
            return (delivery.transportSequence, event)
        }
        XCTAssertEqual(bulletEvents.count, 1)
        let event = bulletEvents[0].1
        XCTAssertEqual(event.shooterIdentity, shooter.identity)
        XCTAssertEqual(event.attackerIdentity, shooter.identity)
        XCTAssertEqual(event.inflictorIdentity, weapon.identity)
        XCTAssertEqual(event.canonicalShootPosition, shootPosition)
        XCTAssertEqual(event.canonicalEyeAngles, shooter.transform.angles)
        XCTAssertEqual(event.source, shootPosition)
        XCTAssertEqual(event.spread, SourceVector3(0.01, 0.01, 0))
        XCTAssertEqual(event.distance, 1024)
        XCTAssertEqual(event.tracerFrequency, 2)
        XCTAssertEqual(event.damage, 25)
        XCTAssertEqual(event.forceScale, 3)
        XCTAssertEqual(event.ammoType, LuaString("Pistol"))
        XCTAssertEqual(event.pellets.count, 1)
        XCTAssertEqual(event.pellets[0].pelletIndex, 0)
        XCTAssertEqual(event.pellets[0].predictionSeed, 0)
        XCTAssertEqual(event.pellets[0].trace.entityHandle, target.identity.handle)
        XCTAssertTrue(event.pellets[0].trace.didHitNonWorldEntity)
        XCTAssertTrue(event.pellets[0].emitsTracer)
        XCTAssertEqual(
            deliveries.map(\.transportSequence),
            deliveries.map(\.transportSequence).sorted()
        )
        XCTAssertTrue(deliveries.contains {
            if case .playerMuzzleFlash = $0.payload { return true }
            return false
        })
        XCTAssertTrue(deliveries.contains {
            if case .playerViewPunch = $0.payload { return true }
            return false
        })
    }

    private func activeWeapon(
        in session: GModPlayableSession,
        player identity: SourceCanonicalEntityIdentity
    ) throws -> SourceCanonicalEntitySnapshot {
        let player = try snapshot(identity, in: session)
        return try snapshot(
            XCTUnwrap(player.weaponInventory.activeWeapon),
            in: session
        )
    }

    private func snapshot(
        _ identity: SourceCanonicalEntityIdentity,
        in session: GModPlayableSession
    ) throws -> SourceCanonicalEntitySnapshot {
        try XCTUnwrap(session.sourceAdapter.canonicalEntitySnapshots.first {
            $0.identity == identity
        })
    }
}
