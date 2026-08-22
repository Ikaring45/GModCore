import Foundation
import XCTest
import GModLua
@testable import GModEngine
@testable import GModGameSession

private struct DamageImpulseWorldMissProvider: GMLuaTraceProvider {
    var isWorldReady: Bool { true }

    func traceWorld(_ request: GMLuaTraceRequest) throws -> SourceGameTrace {
        SourceGameTrace(ray: request.ray)
    }
}

private final class DamageImpulseDynamicPropProvider:
    GMLuaDynamicTraceCandidateProvider,
    @unchecked Sendable
{
    private let target: SourceCanonicalEntityIdentity
    private let center: SourceVector3

    init(target: SourceCanonicalEntityIdentity, center: SourceVector3) {
        self.target = target
        self.center = center
    }

    var isDynamicTraceReady: Bool { true }

    func dynamicTraceCandidates(
        for request: GMLuaTraceRequest
    ) throws -> [GMLuaDynamicTraceCandidate] {
        [GMLuaDynamicTraceCandidate(
            identity: target,
            className: SourceCanonicalEntityKind.propPhysics.className,
            collisionGroup: 0,
            studioHitboxes: [try GMLuaDynamicStudioHitbox(
                minimum: SourceVector3(-32, -32, -32),
                maximum: SourceVector3(32, 32, 32),
                boneToWorld: SourceStudioMatrix3x4(
                    1, 0, 0, center.x,
                    0, 1, 0, center.y,
                    0, 0, 1, center.z
                ),
                contents: [.solid],
                surface: SourceTraceSurface(name: "prop_physics_hitbox"),
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

private final class RecordingDamagePhysicsHost:
    SourceCanonicalPhysicsObjectLuaHost
{
    var primary: SourceCanonicalPhysicsObjectSnapshot?
    private(set) var requestedEntities: [SourceCanonicalEntityIdentity] = []
    private(set) var mutations: [SourcePhysicsBodyMutationCommand] = []

    func primaryCanonicalPhysicsObject(
        for entity: SourceCanonicalEntityIdentity
    ) -> SourceCanonicalPhysicsObjectSnapshot? {
        requestedEntities.append(entity)
        return primary
    }

    func canonicalPhysicsObject(
        for bodyID: SourcePhysicsBodyID
    ) -> SourceCanonicalPhysicsObjectSnapshot? {
        primary?.bodyID == bodyID ? primary : nil
    }

    func enqueueCanonicalPhysicsObjectMutation(
        _ command: SourcePhysicsBodyMutationCommand
    ) throws {
        mutations.append(command)
    }
}

final class SourceCanonicalDamagePhysicsImpulseTests: XCTestCase {
    func testFireBulletsQueuesOfficialDamageImpulseForNextFixedStepAndReplicates()
        throws
    {
        let model = SourceEntityModelReference(
            "models/props/damage_impulse.mdl"
        )
        let mass: Float = 20
        let asset = try makeAttestedPropPhysicsTestAsset(
            modelPath: model.path,
            massKilograms: mass,
            bodyBehavior: SourceAttestedPropPhysicsBodyBehavior(
                motionType: .dynamicBody,
                damping: .zero,
                isGravityEnabled: false,
                isCollisionEnabled: true,
                startsAwake: true
            )
        )
        let appearance = try SourceStudioModelAppearanceLayout(
            checksum: asset.studioChecksum,
            modelName: model.path,
            skinFamilyCount: 1,
            bodyGroups: []
        )
        let layout = try SourceStudioBodyGroupLayout(
            bodyParts: [],
            appearance: appearance
        )
        let session = try GModPlayableSession(
            configuration: .init(),
            textMeasurer: nil,
            logger: { _, _ in },
            worldWalkCollisionProvider: nil,
            canonicalModelValidator: { candidate, kind in
                candidate == model && kind == .propPhysics ? .valid : .invalid
            },
            canonicalPropPhysicsAssetResolverForTesting:
                makeAttestedPropPhysicsTestResolver(asset: asset),
            canonicalBodyGroupLayoutResolverForTesting: { candidate in
                candidate == model ? layout : nil
            }
        )
        defer { _ = try? session.close() }

        let shooter = try XCTUnwrap(
            session.sourceAdapter.canonicalEntitySnapshots.first {
                $0.kind == .player && $0.identity.entryIndex ==
                    session.configuration.playerEntityIndex
            }
        )
        let shooterOrigin = SourceVector3.zero
        _ = try session.sourceAdapter.updateCanonicalEntity(
            shooter.identity
        ) { state in
            state.transform = SourceEntityTransform(
                origin: shooterOrigin,
                angles: .zero
            )
            state.moveType = .noClip
            state.motion.linearVelocity = .zero
            state.motion.baseVelocity = .zero
            state.motion.outputWishVelocity = .zero
        }
        let targetCenter = SourceVector3(256, 0, 64)
        var propState = SourceCanonicalEntityState.defaults(for: .propPhysics)
        propState.model = model
        propState.transform.origin = targetCenter
        propState.combat = SourceCanonicalCombatState(
            health: 100,
            maximumHealth: 100,
            takeDamageMode: 2
        )
        let created = try session.sourceAdapter.createCanonicalEntity(
            kind: .propPhysics,
            at: 24,
            state: propState
        )
        _ = try session.sourceAdapter.spawnCanonicalEntity(created.identity)
        let prop = try session.sourceAdapter.activateCanonicalEntity(
            created.identity
        )

        session.serverRuntime.traceBridge?.connect(
            provider: GMLuaCompositeTraceProvider(
                world: DamageImpulseWorldMissProvider(),
                dynamic: DamageImpulseDynamicPropProvider(
                    target: prop.identity,
                    center: targetCenter
                )
            )
        )
        try session.serverRuntime.execute(
            """
            hook.Add("EntityFireBullets", "damage_impulse_acceptance", function(_, data)
                data.Damage = 10
                data.Force = 3
                data.Distance = 1024
                data.Spread = Vector(0, 0, 0)
                return true
            end)
            weapons.Register({
                Base = "weapon_base",
                PrintName = "Damage Impulse Acceptance",
                Primary = {
                    ClipSize = 4,
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
            }, "weapon_damage_impulse_acceptance")
            local ply = Player(\(session.configuration.playerUserID))
            assert(IsValid(ply:Give("weapon_damage_impulse_acceptance")))
            ply:SelectWeapon("weapon_damage_impulse_acceptance")
            """,
            sourceName: "=(damage impulse weapon setup)"
        )

        _ = try session.runFixedTick()
        let before = try XCTUnwrap(
            session.sourceAdapter.primaryCanonicalPhysicsObject(
                for: prop.identity
            )
        )
        XCTAssertEqual(before.massProperties.massKilograms, mass)
        XCTAssertEqual(before.linearVelocity, .zero)
        XCTAssertEqual(
            session.clientCanonicalEntitySnapshots.first {
                $0.identity == prop.identity
            }?.motion.linearVelocity,
            .zero
        )

        let fired = try session.runFixedTick(
            movementInput: GModPlayableMovementInput(buttons: [.attack])
        )
        XCTAssertEqual(fired.actionFailures, [])
        XCTAssertEqual(fired.weaponGameplay.failures, [])

        let officialImpulse = try SourceCanonicalBulletDamageForce.impulse(
            ammoTypeName: "Pistol",
            direction: SourceVector3(1, 0, 0),
            forceScale: 3,
            physicsPushScale: 1
        )
        let expectedVelocityX = officialImpulse.x / mass
        let body = try XCTUnwrap(
            session.sourceAdapter.primaryCanonicalPhysicsObject(
                for: prop.identity
            )
        )
        XCTAssertEqual(
            body.linearVelocity.x,
            expectedVelocityX,
            accuracy: 0.000_1
        )
        XCTAssertEqual(body.linearVelocity.y, 0, accuracy: 0.000_1)
        XCTAssertEqual(body.linearVelocity.z, 0, accuracy: 0.000_1)
        XCTAssertEqual(body.angularVelocity.x, 0, accuracy: 0.000_1)
        XCTAssertEqual(body.angularVelocity.y, 0, accuracy: 0.000_1)
        XCTAssertEqual(body.angularVelocity.z, 0, accuracy: 0.000_1)
        XCTAssertGreaterThan(body.transform.origin.x, before.transform.origin.x)

        let authoritative = try XCTUnwrap(
            session.sourceAdapter.canonicalSnapshot(for: prop.identity)
        )
        let replicated = try XCTUnwrap(
            session.clientCanonicalEntitySnapshots.first {
                $0.identity == prop.identity
            }
        )
        XCTAssertEqual(authoritative.combat.health, 90)
        XCTAssertEqual(replicated.combat.health, 90)
        XCTAssertEqual(replicated.transform, authoritative.transform)
        XCTAssertEqual(replicated.motion.linearVelocity, body.linearVelocity)
        XCTAssertEqual(replicated.motion.angularVelocity, body.angularVelocity)
    }

    func testOnlyLiveDynamicAttestedPropBodyCanReceiveImpulse() throws {
        let host = RecordingDamagePhysicsHost()
        let world = snapshot(kind: .world, entry: 0, serial: 4)
        let player = snapshot(kind: .player, entry: 1, serial: 4)
        let removingProp = snapshot(
            kind: .propPhysics,
            entry: 19,
            serial: 4,
            lifecycle: .pendingRemoval
        )

        XCTAssertEqual(
            try SourceCanonicalDamagePhysicsImpulse.enqueue(
                target: world,
                impulse: SourceVector3(10, 0, 0),
                worldPosition: .zero,
                physicsHost: host
            ),
            .ignoredEntityKind(identity: world.identity, kind: .world)
        )
        XCTAssertEqual(
            try SourceCanonicalDamagePhysicsImpulse.enqueue(
                target: player,
                impulse: SourceVector3(10, 0, 0),
                worldPosition: .zero,
                physicsHost: host
            ),
            .ignoredEntityKind(identity: player.identity, kind: .player)
        )
        XCTAssertEqual(
            try SourceCanonicalDamagePhysicsImpulse.enqueue(
                target: removingProp,
                impulse: SourceVector3(10, 0, 0),
                worldPosition: .zero,
                physicsHost: host
            ),
            .inactiveTarget(
                identity: removingProp.identity,
                lifecycle: .pendingRemoval
            )
        )
        XCTAssertTrue(host.requestedEntities.isEmpty)
        XCTAssertTrue(host.mutations.isEmpty)

        let prop = snapshot(kind: .propPhysics, entry: 20, serial: 4)
        XCTAssertEqual(
            try SourceCanonicalDamagePhysicsImpulse.enqueue(
                target: prop,
                impulse: SourceVector3(10, 0, 0),
                worldPosition: .zero,
                physicsHost: host
            ),
            .noPhysicsBody(prop.identity)
        )
        XCTAssertTrue(host.mutations.isEmpty)

        let staticAsset = try makeAttestedPropPhysicsTestAsset(
            modelPath: try XCTUnwrap(prop.model).path,
            bodyBehavior: SourceAttestedPropPhysicsBodyBehavior(
                motionType: .staticBody,
                damping: .zero,
                isGravityEnabled: false,
                isCollisionEnabled: true,
                startsAwake: false
            )
        )
        host.primary = try SourceCanonicalPhysicsObjectSnapshot(
            pendingEntity: prop,
            definition: staticAsset.bodyDefinition
        )
        let staticBody = try XCTUnwrap(host.primary)
        XCTAssertEqual(
            try SourceCanonicalDamagePhysicsImpulse.enqueue(
                target: prop,
                impulse: SourceVector3(10, 0, 0),
                worldPosition: .zero,
                physicsHost: host
            ),
            .ignoredNonDynamicBody(
                bodyID: staticBody.bodyID,
                motionType: .staticBody
            )
        )
        XCTAssertTrue(host.mutations.isEmpty)
    }

    func testFullEHANDLEGenerationMismatchFailsBeforeEnqueue() throws {
        let old = snapshot(kind: .propPhysics, entry: 30, serial: 6)
        let replacement = snapshot(kind: .propPhysics, entry: 30, serial: 7)
        let asset = try makeAttestedPropPhysicsTestAsset(
            modelPath: try XCTUnwrap(replacement.model).path,
            bodyBehavior: SourceAttestedPropPhysicsBodyBehavior(
                motionType: .dynamicBody,
                damping: .zero,
                isGravityEnabled: false,
                isCollisionEnabled: true,
                startsAwake: true
            )
        )
        let host = RecordingDamagePhysicsHost()
        host.primary = try SourceCanonicalPhysicsObjectSnapshot(
            pendingEntity: replacement,
            definition: asset.bodyDefinition
        )

        XCTAssertThrowsError(
            try SourceCanonicalDamagePhysicsImpulse.enqueue(
                target: old,
                impulse: SourceVector3(10, 0, 0),
                worldPosition: .zero,
                physicsHost: host
            )
        ) { error in
            XCTAssertEqual(
                error as? SourceCanonicalDamagePhysicsImpulseError,
                .bodyIdentityMismatch(
                    expected: old.identity,
                    received: replacement.identity
                )
            )
        }
        XCTAssertTrue(host.mutations.isEmpty)
    }

    func testBulletForceUsesOfficialAmmoValueAndRejectsUnknownForce() throws {
        let impulse = try SourceCanonicalBulletDamageForce.impulse(
            ammoTypeName: "Pistol",
            direction: SourceVector3(4, 0, 0),
            forceScale: 3,
            physicsPushScale: 1
        )
        let pounds: Float = 0.002_285 * 200 / 16
        let kilograms = pounds * (1 / Float(2.2))
        let expected = Float(1_225 * 12) * kilograms * 3.5 * 3
        XCTAssertEqual(impulse.x, expected, accuracy: 0.000_1)
        XCTAssertEqual(impulse.y, 0)
        XCTAssertEqual(impulse.z, 0)

        XCTAssertThrowsError(
            try SourceCanonicalBulletDamageForce.impulse(
                ammoTypeName: "9mmRound",
                direction: SourceVector3(1, 0, 0),
                forceScale: 1,
                physicsPushScale: 1
            )
        ) { error in
            XCTAssertEqual(
                error as? SourceCanonicalBulletDamageForceError,
                .unavailableAmmoForce("9mmRound")
            )
        }
    }

    private func snapshot(
        kind: SourceCanonicalEntityKind,
        entry: Int,
        serial: Int,
        lifecycle: SourceCanonicalEntityLifecycle = .active
    ) -> SourceCanonicalEntitySnapshot {
        let identity = SourceCanonicalEntityIdentity(handle: SourceBaseHandle(
            entryIndex: entry,
            serialNumber: serial
        ))
        let defaults = SourceCanonicalEntityState.defaults(for: kind)
        let model = kind == .propPhysics
            ? SourceEntityModelReference("models/props/impulse_contract.mdl")
            : defaults.model
        return SourceCanonicalEntitySnapshot(
            identity: identity,
            kind: kind,
            className: kind.className,
            transform: defaults.transform,
            motion: defaults.motion,
            model: model,
            collisionProperty: defaults.collisionProperty,
            collisionGroup: defaults.collisionGroup,
            isNotSolid: defaults.isNotSolid,
            solidType: defaults.solidType,
            moveType: defaults.moveType,
            lifecycle: lifecycle,
            isNetworkable: true,
            revision: 1,
            combat: defaults.combat
        )
    }
}
