import XCTest
import GModLua
@testable import GModEngine
@testable import GModGameSession

private struct StockWeaponWorldMissProvider: GMLuaTraceProvider {
    var isWorldReady: Bool { true }

    func traceWorld(_ request: GMLuaTraceRequest) throws -> SourceGameTrace {
        SourceGameTrace(ray: request.ray)
    }
}

private final class StockWeaponTargetTraceProvider:
    GMLuaDynamicTraceCandidateProvider, @unchecked Sendable
{
    private let lock = NSLock()
    private var target: SourceCanonicalEntityIdentity?
    private var center = SourceVector3.zero

    var isDynamicTraceReady: Bool { true }

    func aim(
        at target: SourceCanonicalEntityIdentity,
        center: SourceVector3
    ) {
        lock.lock()
        self.target = target
        self.center = center
        lock.unlock()
    }

    func dynamicTraceCandidates(
        for _: GMLuaTraceRequest
    ) throws -> [GMLuaDynamicTraceCandidate] {
        lock.lock()
        let target = target
        let center = center
        lock.unlock()
        guard let target else { return [] }
        let vertices = [
            SourceVector3(-4, -4, -4), SourceVector3(4, -4, -4),
            SourceVector3(-4, 4, -4), SourceVector3(4, 4, -4),
            SourceVector3(-4, -4, 4), SourceVector3(4, -4, 4),
            SourceVector3(-4, 4, 4), SourceVector3(4, 4, 4),
        ]
        let triangleIndices = [
            (0, 4, 6), (0, 6, 2), (1, 3, 7), (1, 7, 5),
            (0, 1, 5), (0, 5, 4), (2, 6, 7), (2, 7, 3),
            (0, 2, 3), (0, 3, 1), (4, 5, 7), (4, 7, 6),
        ]
        let triangles = try triangleIndices.map {
            try SourcePhysicsIndexedTriangle(
                first: $0.0,
                second: $0.1,
                third: $0.2,
                materialIndex: 0
            )
        }
        let hull = try GMLuaDynamicHullCollision(
            transform: SourceEntityTransform(origin: center),
            collisionProperty: SourceCollisionProperty(
                mins: SourceVector3(-4, -4, -4),
                maxs: SourceVector3(4, 4, 4)
            ),
            physicsShape: SourcePhysicsShapeSnapshot(
                topology: .convexParts,
                parts: [try SourcePhysicsMeshPartSnapshot(
                    vertices: vertices,
                    triangles: triangles
                )]
            ),
            contents: .solid,
            surface: SourceTraceSurface(name: "player_hull")
        )
        return [GMLuaDynamicTraceCandidate(
            identity: target,
            className: "player",
            collisionGroup: 0,
            studioHitboxes: [try GMLuaDynamicStudioHitbox(
                minimum: SourceVector3(-4, -4, -4),
                maximum: SourceVector3(4, 4, 4),
                boneToWorld: SourceStudioMatrix3x4(
                    1, 0, 0, center.x,
                    0, 1, 0, center.y,
                    0, 0, 1, center.z
                ),
                // Player studio hitboxes carry the entity CONTENTS_MONSTER bit
                // in addition to CONTENTS_HITBOX. The former is what makes a
                // default MASK_SOLID medkit line trace hit a Player.
                contents: [.monster, .hitbox],
                surface: SourceTraceSurface(name: "player_hitbox"),
                hitBox: 0,
                hitGroup: 0,
                physicsBone: 0
            )],
            hullCollision: hull
        )]
    }

    func shouldCollide(
        queryCollisionGroup: Int32,
        candidateCollisionGroup: Int32
    ) -> Bool {
        queryCollisionGroup == 0 && candidateCollisionGroup == 0
    }
}

final class SourceCanonicalStockWeaponCombatTests: XCTestCase {
    func testStockFistsMedkitAndCameraUseCanonicalCombatStateAndFIFO()
        throws
    {
        let session = try GModPlayableSession(
            configuration: .init(),
            textMeasurer: nil,
            logger: { _, _ in }
        )
        defer { _ = try? session.close() }

        let owner = try canonicalPlayer(in: session)
        var targetState = SourceCanonicalEntityState.defaults(for: .player)
        targetState.transform.origin = owner.transform.origin
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

        let dynamic = StockWeaponTargetTraceProvider()
        dynamic.aim(
            at: target.identity,
            center: owner.transform.origin + owner.viewOffset +
                owner.transform.angles.sourceBasis.forward * 24
        )
        session.serverRuntime.traceBridge?.connect(
            provider: GMLuaCompositeTraceProvider(
                world: StockWeaponWorldMissProvider(),
                dynamic: dynamic
            )
        )
        _ = try tick(session)

        try give("weapon_fists", in: session)
        let fistsInitial = try tick(session)
        XCTAssertEqual(fistsInitial.failures, [])
        XCTAssertTrue(fistsInitial.invocations.contains {
            $0.className == "weapon_fists" && $0.invocation == .deploy
        })

        let fistsAttack = try tick(session, buttons: [.attack])
        XCTAssertEqual(fistsAttack.failures, [])
        XCTAssertTrue(fistsAttack.invocations.contains {
            $0.className == "weapon_fists" && $0.invocation == .primaryAttack
        })
        for _ in 0..<18 {
            let report = try tick(session)
            XCTAssertEqual(report.failures, [], "delayed fists action: \(report.failures)")
        }

        let punchedTarget = try snapshot(target.identity, in: session)
        let fistsAfterDelay = try activeWeapon(in: session)
        XCTAssertTrue(
            (88...92).contains(punchedTarget.combat.health),
            "health=\(punchedTarget.combat.health) weapon=\(fistsAfterDelay.weaponRuntime) time=\(String(describing: session.serverRuntime.timerScheduler?.currentTime))"
        )
        XCTAssertEqual(
            session.clientCanonicalEntitySnapshots.first {
                $0.identity == target.identity
            }?.combat.health,
            punchedTarget.combat.health
        )

        try give("weapon_medkit", in: session)
        let medkitInitial = try tick(session)
        XCTAssertEqual(medkitInitial.failures, [])
        let medkitBefore = try activeWeapon(in: session)
        XCTAssertEqual(medkitBefore.className, "weapon_medkit")
        XCTAssertEqual(medkitBefore.weaponRuntime.clip1, 100)

        let targetBeforeHeal = punchedTarget.combat.health
        let medkitPrimary = try tick(session, buttons: [.attack])
        XCTAssertEqual(medkitPrimary.failures, [])
        let targetAfterHeal = try snapshot(target.identity, in: session)
        let expectedTargetHealth = min(100, targetBeforeHeal + 20)
        XCTAssertEqual(targetAfterHeal.combat.health, expectedTargetHealth)
        let medkitAfterPrimary = try activeWeapon(in: session)
        XCTAssertEqual(
            medkitAfterPrimary.weaponRuntime.clip1,
            100 - (expectedTargetHealth - targetBeforeHeal)
        )

        try session.serverRuntime.execute(
            "Player(\(session.configuration.playerUserID)):SetHealth(50)",
            sourceName: "=(stock medkit owner damage fixture)"
        )
        var fireWaitTicks = 0
        while Float(session.serverRuntime.timerScheduler?.currentTime ?? 0) <=
                (try activeWeapon(in: session)).weaponRuntime.nextSecondaryFire {
            _ = try tick(session)
            fireWaitTicks += 1
            XCTAssertLessThan(fireWaitTicks, 200)
        }
        let medkitSecondary = try tick(session, buttons: [.attack2])
        XCTAssertEqual(medkitSecondary.failures, [])
        let medkitAtSecondary = try activeWeapon(in: session)
        XCTAssertTrue(medkitSecondary.invocations.contains {
            $0.className == "weapon_medkit" && $0.invocation == .secondaryAttack
        }, "secondary report=\(medkitSecondary) weapon=\(medkitAtSecondary.weaponRuntime) time=\(String(describing: session.serverRuntime.timerScheduler?.currentTime))")
        XCTAssertEqual(try canonicalPlayer(in: session).combat.health, 70)
        let medkitAfterSecondary = try activeWeapon(in: session)
        XCTAssertEqual(
            session.clientCanonicalEntitySnapshots.first {
                $0.identity == medkitAfterSecondary.identity
            }?.weaponRuntime,
            medkitAfterSecondary.weaponRuntime
        )
        _ = try tick(session)
        let medkitReload = try tick(session, buttons: [.reload])
        XCTAssertEqual(medkitReload.failures, [])
        XCTAssertTrue(medkitReload.invocations.contains {
            $0.className == "weapon_medkit" && $0.invocation == .reload
        })

        try give("gmod_camera", in: session)
        let cameraInitial = try tick(session)
        XCTAssertEqual(cameraInitial.failures, [])
        var camera = try activeWeapon(in: session)
        XCTAssertEqual(camera.className, "gmod_camera")
        XCTAssertEqual(camera.weaponRuntime.floatNetworkVariables[0], 75)
        XCTAssertEqual(camera.weaponRuntime.floatNetworkVariables[1], 0)

        let cameraPrimary = try tick(session, buttons: [.attack])
        XCTAssertEqual(cameraPrimary.failures, [])
        XCTAssertTrue(cameraPrimary.invocations.contains {
            $0.className == "gmod_camera" && $0.invocation == .primaryAttack
        })
        let captureRequests = try XCTUnwrap(
            session.clientRuntime.cameraCaptureRequests
        ).pending
        XCTAssertEqual(captureRequests.map(\.sequence), [1])
        let captureTime = try XCTUnwrap(captureRequests.first?.requestedAt)
        let clientTime = try XCTUnwrap(
            session.clientRuntime.timerScheduler?.currentTime
        )
        XCTAssertGreaterThan(captureTime, 0)
        XCTAssertLessThanOrEqual(captureTime, clientTime)
        XCTAssertLessThanOrEqual(
            clientTime - captureTime,
            SourceCanonicalWeaponCombatBridge.sourceFixedFrameTime + 0.000_001
        )
        _ = try tick(session)
        let cameraSecondary = try tick(session, buttons: [.attack2])
        XCTAssertEqual(cameraSecondary.failures, [])
        XCTAssertTrue(cameraSecondary.invocations.contains {
            $0.className == "gmod_camera" && $0.invocation == .secondaryAttack
        })
        _ = try tick(session)
        let cameraReload = try tick(session, buttons: [.reload])
        XCTAssertEqual(cameraReload.failures, [])
        XCTAssertTrue(cameraReload.invocations.contains {
            $0.className == "gmod_camera" && $0.invocation == .reload
        })
        camera = try activeWeapon(in: session)
        XCTAssertEqual(camera.weaponRuntime.floatNetworkVariables[0], 75)
        XCTAssertEqual(camera.weaponRuntime.floatNetworkVariables[1], 0)

        let deliveries = try XCTUnwrap(
            session.clientToolActionBridge.clientEventState
        ).capturedDeliveries
        XCTAssertTrue(deliveries.contains { delivery in
            if case .entitySound = delivery.payload { return true }
            return false
        })
        XCTAssertTrue(deliveries.contains { delivery in
            if case .weaponAnimation = delivery.payload { return true }
            return false
        })
        XCTAssertTrue(deliveries.contains { delivery in
            if case .playerAnimation = delivery.payload { return true }
            return false
        })
        XCTAssertEqual(deliveries.map(\.transportSequence),
            deliveries.map(\.transportSequence).sorted())
    }

    private func give(
        _ className: String,
        in session: GModPlayableSession
    ) throws {
        try session.serverRuntime.execute(
            """
            local ply = Player(\(session.configuration.playerUserID))
            assert(IsValid(ply:Give(\"\(className)\")))
            ply:SelectWeapon(\"\(className)\")
            """,
            sourceName: "=(give stock \(className))"
        )
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
        in session: GModPlayableSession
    ) throws -> SourceCanonicalEntitySnapshot {
        let player = try canonicalPlayer(in: session)
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
