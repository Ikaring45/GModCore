import XCTest
@testable import GModEngine
import GModLua

final class SourceCanonicalPhysicsObjectGLuaBridgeTests: XCTestCase {
    func testPendingAttestedBodyRunsFixInvalidPhysicsObjectAABBReadBranch() throws {
        let runtime = makeRuntime()
        defer { _ = runtime.close() }
        let typeSystem = try XCTUnwrap(runtime.typeSystem)
        try typeSystem.installFallbackUtilities()

        let entity = makeProp(
            entryIndex: 37,
            serialNumber: 12,
            lifecycle: .active,
            transform: SourceEntityTransform(
                origin: SourceVector3(10, 20, 30),
                angles: SourceQAngle(pitch: 1, yaw: 2, roll: 3)
            ),
            linearVelocity: SourceVector3(4, 5, 6),
            angularVelocity: SourceVector3(7, 8, 9)
        )
        let definition = try makeDefinition(
            solidIndex: 0,
            isCollisionEnabled: false,
            startsAwake: false
        )
        let pending = try SourceCanonicalPhysicsObjectSnapshot(
            pendingEntity: entity,
            definition: definition
        )
        let host = RecordingCanonicalPhysicsObjectHost()
        host.publish(pending, asPrimary: true)

        let registry = try XCTUnwrap(runtime.entityRegistry)
        _ = try registry.applyAuthoritativeSnapshot(entity)
        _ = try SourceCanonicalPhysicsObjectGLuaBridge.install(
            into: runtime,
            host: host
        )

        try runtime.execute(
            #"""
            local prop = Entity(37)
            local phys = prop:GetPhysicsObject()
            assert(IsValid(phys))
            assert(phys == prop:GetPhysicsObject())
            assert(phys:GetMass() == 12)

            local inertia = phys:GetInertia()
            assert(inertia.x == 2 and inertia.y == 3 and inertia.z == 4)
            local pos = phys:GetPos()
            assert(pos.x == 10 and pos.y == 20 and pos.z == 30)
            local ang = phys:GetAngles()
            assert(ang.p == 1 and ang.y == 2 and ang.r == 3)
            local velocity = phys:GetVelocity()
            assert(velocity.x == 4 and velocity.y == 5 and velocity.z == 6)
            local angular = phys:GetAngleVelocity()
            assert(angular.x == 7 and angular.y == 8 and angular.z == 9)
            assert(phys:IsGravityEnabled() == true)
            assert(phys:IsCollisionEnabled() == false)
            assert(phys:IsAsleep() == true)

            assert(phys.GetMassCenter == nil)
            assert(phys:IsMotionEnabled() == true)
            assert(phys.SetMass == nil)

            phys:Wake()
            phys:Sleep()
            phys:EnableMotion(false)
            phys:EnableGravity(false)
            phys:EnableCollisions(true)
            phys:SetVelocity(Vector(10, 20, 30))
            phys:AddVelocity(Vector(1, 2, 3))
            phys:ApplyForceCenter(Vector(100, 200, 300))

            function FixInvalidPhysicsObject(prop)
                local PhysObj = prop:GetPhysicsObject()
                if (not IsValid(PhysObj)) then return "invalid" end

                local min, max = PhysObj:GetAABB()
                if (not min or not max) then return "missing" end

                local PhysSize = (min - max):Length()
                if (PhysSize > 5) then return "normal" end
                error("normal prop unexpectedly reached PhysicsInitBox repair")
            end

            assert(FixInvalidPhysicsObject(prop) == "normal")
            local mins, maxs = phys:GetAABB()
            assert(mins.x == -4 and mins.y == -6 and mins.z == -8)
            assert(maxs.x == 12 and maxs.y == 10 and maxs.z == 14)
            PENDING_PHYS = phys
            """#,
            sourceName: "=(canonical pending PhysObj)"
        )

        XCTAssertEqual(host.mutations, try [
            SourcePhysicsBodyMutationCommand(
                bodyID: pending.bodyID,
                mutation: .wake
            ),
            SourcePhysicsBodyMutationCommand(
                bodyID: pending.bodyID,
                mutation: .sleep
            ),
            SourcePhysicsBodyMutationCommand(
                bodyID: pending.bodyID,
                mutation: .setMotionEnabled(false)
            ),
            SourcePhysicsBodyMutationCommand(
                bodyID: pending.bodyID,
                mutation: .setGravityEnabled(false)
            ),
            SourcePhysicsBodyMutationCommand(
                bodyID: pending.bodyID,
                mutation: .setCollisionEnabled(true)
            ),
            SourcePhysicsBodyMutationCommand(
                bodyID: pending.bodyID,
                mutation: .setLinearVelocity(SourceVector3(10, 20, 30))
            ),
            SourcePhysicsBodyMutationCommand(
                bodyID: pending.bodyID,
                mutation: .addLinearVelocity(SourceVector3(1, 2, 3))
            ),
            SourcePhysicsBodyMutationCommand(
                bodyID: pending.bodyID,
                mutation: .applyCenterForce(SourceVector3(100, 200, 300))
            ),
        ])

        let simulated = try makeBodySnapshot(
            bodyID: pending.bodyID,
            transform: SourceEntityTransform(
                origin: SourceVector3(40, 50, 60),
                angles: SourceQAngle(pitch: 11, yaw: 22, roll: 33)
            ),
            linearVelocity: SourceVector3(14, 15, 16),
            angularVelocity: SourceVector3(17, 18, 19),
            isCollisionEnabled: true,
            isSleeping: false
        )
        host.publish(
            try SourceCanonicalPhysicsObjectSnapshot(body: simulated),
            asPrimary: true
        )

        try runtime.execute(
            #"""
            local current = Entity(37):GetPhysicsObject()
            assert(current == PENDING_PHYS)
            local pos = current:GetPos()
            assert(pos.x == 40 and pos.y == 50 and pos.z == 60)
            assert(current:IsCollisionEnabled() == true)
            assert(current:IsAsleep() == false)
            """#,
            sourceName: "=(canonical simulated PhysObj transition)"
        )
    }

    func testCacheUsesFullBodyIdentityAndInvalidatesReusedEntityGeneration() throws {
        let runtime = makeRuntime()
        defer { _ = runtime.close() }
        let typeSystem = try XCTUnwrap(runtime.typeSystem)
        try typeSystem.installFallbackUtilities()
        let registry = try XCTUnwrap(runtime.entityRegistry)
        let host = RecordingCanonicalPhysicsObjectHost()
        _ = try SourceCanonicalPhysicsObjectGLuaBridge.install(
            into: runtime,
            host: host
        )

        let firstEntity = makeProp(
            entryIndex: 52,
            serialNumber: 6,
            lifecycle: .active
        )
        let firstSolid = try SourceCanonicalPhysicsObjectSnapshot(
            pendingEntity: firstEntity,
            definition: makeDefinition(solidIndex: 0)
        )
        let secondSolid = try SourceCanonicalPhysicsObjectSnapshot(
            pendingEntity: firstEntity,
            definition: makeDefinition(solidIndex: 1)
        )
        _ = try registry.applyAuthoritativeSnapshot(firstEntity)
        host.publish(firstSolid, asPrimary: true)
        host.publish(secondSolid, asPrimary: false)

        try runtime.execute(
            #"""
            FIRST_SOLID = Entity(52):GetPhysicsObject()
            assert(IsValid(FIRST_SOLID))
            assert(FIRST_SOLID == Entity(52):GetPhysicsObject())
            """#,
            sourceName: "=(canonical PhysObj first solid)"
        )

        host.selectPrimary(secondSolid.bodyID)
        try runtime.execute(
            #"""
            SECOND_SOLID = Entity(52):GetPhysicsObject()
            assert(IsValid(SECOND_SOLID))
            assert(SECOND_SOLID ~= FIRST_SOLID)
            assert(IsValid(FIRST_SOLID))
            """#,
            sourceName: "=(canonical PhysObj second solid)"
        )

        host.selectPrimary(firstSolid.bodyID)
        try runtime.execute(
            "assert(Entity(52):GetPhysicsObject() == FIRST_SOLID)",
            sourceName: "=(canonical PhysObj solid cache reuse)"
        )

        host.remove(firstSolid.bodyID)
        host.remove(secondSolid.bodyID)
        let removedFirstEntity = makeProp(
            entryIndex: 52,
            serialNumber: 6,
            lifecycle: .removed
        )
        XCTAssertTrue(try registry.applyAuthoritativeRemoval(removedFirstEntity))

        let replacementEntity = makeProp(
            entryIndex: 52,
            serialNumber: 7,
            lifecycle: .active
        )
        let replacement = try SourceCanonicalPhysicsObjectSnapshot(
            pendingEntity: replacementEntity,
            definition: makeDefinition(solidIndex: 0)
        )
        _ = try registry.applyAuthoritativeSnapshot(replacementEntity)
        host.publish(replacement, asPrimary: true)

        try runtime.execute(
            #"""
            assert(IsValid(FIRST_SOLID) == false)
            assert(IsValid(SECOND_SOLID) == false)
            local replacement = Entity(52):GetPhysicsObject()
            assert(IsValid(replacement))
            assert(replacement ~= FIRST_SOLID and replacement ~= SECOND_SOLID)

            local ok, message = pcall(function() FIRST_SOLID:GetMass() end)
            assert(ok == false)
            assert(string.find(message, "live canonical PhysObj expected", 1, true))
            """#,
            sourceName: "=(canonical PhysObj generation replacement)"
        )

        XCTAssertNotEqual(
            firstSolid.bodyID.entityIdentity.handle.rawValue,
            replacement.bodyID.entityIdentity.handle.rawValue
        )
        XCTAssertEqual(firstSolid.bodyID.entityIdentity.entryIndex, 52)
        XCTAssertEqual(replacement.bodyID.entityIdentity.entryIndex, 52)
    }

    private func makeRuntime() -> GMLuaRuntime {
        GMLuaRuntime(
            realm: .server,
            logger: { _ in },
            netTransport: GMLuaNetTransport()
        )
    }

    private func makeProp(
        entryIndex: Int,
        serialNumber: Int,
        lifecycle: SourceCanonicalEntityLifecycle,
        transform: SourceEntityTransform = .identity,
        linearVelocity: SourceVector3 = .zero,
        angularVelocity: SourceVector3 = .zero
    ) -> SourceCanonicalEntitySnapshot {
        var motion = SourceEntityMotionState()
        motion.linearVelocity = linearVelocity
        motion.angularVelocity = angularVelocity
        return SourceCanonicalEntitySnapshot(
            identity: SourceCanonicalEntityIdentity(
                handle: SourceBaseHandle(
                    entryIndex: entryIndex,
                    serialNumber: serialNumber
                )
            ),
            kind: .propPhysics,
            className: SourceCanonicalEntityKind.propPhysics.className,
            transform: transform,
            motion: motion,
            model: SourceEntityModelReference("models/props/test.mdl"),
            solidType: .vPhysics,
            moveType: .vPhysics,
            lifecycle: lifecycle,
            isNetworkable: true,
            revision: 1
        )
    }

    private func makeDefinition(
        solidIndex: Int,
        isCollisionEnabled: Bool = true,
        startsAwake: Bool = true
    ) throws -> SourceCanonicalPropPhysicsBodyDefinition {
        try SourceCanonicalPropPhysicsBodyDefinition(
            solidIndex: solidIndex,
            shape: makeShape(),
            massProperties: SourcePhysicsMassProperties(
                massKilograms: 12,
                principalInertia: SourceVector3(2, 3, 4)
            ),
            motionType: .dynamicBody,
            materialIndex: 7,
            isGravityEnabled: true,
            isCollisionEnabled: isCollisionEnabled,
            startsAwake: startsAwake
        )
    }

    private func makeShape() throws -> SourcePhysicsShapeSnapshot {
        let triangles = try [
            SourcePhysicsIndexedTriangle(
                first: 0,
                second: 2,
                third: 1,
                materialIndex: 7
            ),
            SourcePhysicsIndexedTriangle(
                first: 0,
                second: 1,
                third: 3,
                materialIndex: 7
            ),
            SourcePhysicsIndexedTriangle(
                first: 1,
                second: 2,
                third: 3,
                materialIndex: 7
            ),
            SourcePhysicsIndexedTriangle(
                first: 2,
                second: 0,
                third: 3,
                materialIndex: 7
            ),
        ]
        return try SourcePhysicsShapeSnapshot(
            topology: .convexParts,
            parts: [SourcePhysicsMeshPartSnapshot(
                vertices: [
                    SourceVector3(-4, -6, -8),
                    SourceVector3(12, -6, -8),
                    SourceVector3(-4, 10, -8),
                    SourceVector3(-4, -6, 14),
                ],
                triangles: triangles
            )]
        )
    }

    private func makeBodySnapshot(
        bodyID: SourcePhysicsBodyID,
        transform: SourceEntityTransform,
        linearVelocity: SourceVector3,
        angularVelocity: SourceVector3,
        isCollisionEnabled: Bool,
        isSleeping: Bool
    ) throws -> SourcePhysicsBodySnapshot {
        try SourcePhysicsBodySnapshot(
            bodyID: bodyID,
            shape: makeShape(),
            massProperties: SourcePhysicsMassProperties(
                massKilograms: 12,
                principalInertia: SourceVector3(2, 3, 4)
            ),
            transform: transform,
            linearVelocity: linearVelocity,
            angularVelocity: angularVelocity,
            motionType: .dynamicBody,
            materialIndex: 7,
            isGravityEnabled: true,
            isCollisionEnabled: isCollisionEnabled,
            isSleeping: isSleeping,
            simulationTick: 90
        )
    }
}

private final class RecordingCanonicalPhysicsObjectHost:
    SourceCanonicalPhysicsObjectLuaHost
{
    private(set) var mutations: [SourcePhysicsBodyMutationCommand] = []
    private var bodies: [
        SourcePhysicsBodyID: SourceCanonicalPhysicsObjectSnapshot
    ] = [:]
    private var primaryByEntity: [
        SourceCanonicalEntityIdentity: SourcePhysicsBodyID
    ] = [:]

    func publish(
        _ snapshot: SourceCanonicalPhysicsObjectSnapshot,
        asPrimary: Bool
    ) {
        bodies[snapshot.bodyID] = snapshot
        if asPrimary {
            primaryByEntity[snapshot.bodyID.entityIdentity] = snapshot.bodyID
        }
    }

    func selectPrimary(_ bodyID: SourcePhysicsBodyID) {
        precondition(bodies[bodyID] != nil)
        primaryByEntity[bodyID.entityIdentity] = bodyID
    }

    func remove(_ bodyID: SourcePhysicsBodyID) {
        bodies.removeValue(forKey: bodyID)
        if primaryByEntity[bodyID.entityIdentity] == bodyID {
            primaryByEntity.removeValue(forKey: bodyID.entityIdentity)
        }
    }

    func primaryCanonicalPhysicsObject(
        for entity: SourceCanonicalEntityIdentity
    ) -> SourceCanonicalPhysicsObjectSnapshot? {
        primaryByEntity[entity].flatMap { bodies[$0] }
    }

    func canonicalPhysicsObject(
        for bodyID: SourcePhysicsBodyID
    ) -> SourceCanonicalPhysicsObjectSnapshot? {
        bodies[bodyID]
    }

    func enqueueCanonicalPhysicsObjectMutation(
        _ command: SourcePhysicsBodyMutationCommand
    ) throws {
        guard bodies[command.bodyID] != nil else {
            throw SourceDeterministicPhysicsEnvironment.Error
                .missingBody(command.bodyID)
        }
        mutations.append(command)
    }
}
