import Foundation
import XCTest
@testable import GModEngine
@testable import GModGameSession
import GModGameAssets
import GModLua

final class SourceCanonicalPhysicsObjectMutationIntegrationTests: XCTestCase {
    private let model = SourceEntityModelReference(
        "models/props/physics_mutation.mdl"
    )
    private let mdlData = Data("exact mutation mdl".utf8)
    private let phyData = Data("exact mutation phy".utf8)
    private let studioChecksum: Int32 = 91_337

    func testSetPosAndSetAnglesUseFullBodyFIFOAndPersistNextTick() throws {
        let setup = try makeSetup()
        defer { setup.close() }
        let position = SourceVector3(100, 200, 300)
        let angles = SourceQAngle(pitch: 11, yaw: 22, roll: 33)

        let values = try setup.server.executeReturningValues(
            """
            local prop = assert(ents.Create("prop_physics"))
            prop:SetModel("models/props/physics_mutation.mdl")
            prop:SetPos(Vector(10, 20, 30))
            prop:Spawn()
            prop:Activate()
            local phys = prop:GetPhysicsObject()
            assert(IsValid(phys))
            phys:EnableGravity(false)
            phys:SetPos(Vector(100, 200, 300), true)
            phys:SetAngles(Angle(11, 22, 33))
            TRANSFORM_PROP = prop
            return prop
            """,
            sourceName: "=(authoritative PhysObj transform FIFO)"
        )
        let entity = try XCTUnwrap(
            setup.server.entityRegistry?.canonicalSnapshot(
                for: try XCTUnwrap(values.first)
            )
        )
        let bodyID = try SourcePhysicsBodyID(
            entityIdentity: entity.identity,
            solidIndex: 0
        )
        let pending = setup.transport
            .preparePendingCanonicalPhysicsBodyCommands()
        XCTAssertEqual(pending.map(\.sequence), [1, 2, 3, 4])
        XCTAssertEqual(pending.compactMap { command in
            guard case let .mutateBody(mutation) = command.payload else {
                return nil
            }
            return mutation
        }, try [
            SourcePhysicsBodyMutationCommand(
                bodyID: bodyID,
                mutation: .setGravityEnabled(false)
            ),
            SourcePhysicsBodyMutationCommand(
                bodyID: bodyID,
                mutation: .setPosition(position, teleport: true)
            ),
            SourcePhysicsBodyMutationCommand(
                bodyID: bodyID,
                mutation: .setAngles(angles)
            ),
        ])

        _ = try setup.adapter.runServerFixedTick()
        let coordinator = SourceCanonicalPropPhysicsCoordinator(
            environment: setup.environment,
            commandSequenceSource: setup.transport
        )
        let firstStep = try coordinator.step(
            inputs: setup.adapter.prepareCanonicalPropPhysicsStep(),
            simulationTick: UInt64(setup.adapter.serverGlobals.tickCount)
        )
        XCTAssertEqual(firstStep.commandSequences, [1, 2, 3, 4, 5])
        let firstBody = try XCTUnwrap(firstStep.bodies.first)
        XCTAssertEqual(firstBody.bodyID, bodyID)
        XCTAssertEqual(firstBody.transform.origin, position)
        XCTAssertEqual(firstBody.transform.angles, angles)
        XCTAssertFalse(firstBody.isGravityEnabled)
        try setup.adapter.commitCanonicalPropPhysicsStep(firstStep)

        try setup.server.execute(
            """
            local phys = TRANSFORM_PROP:GetPhysicsObject()
            local pos = phys:GetPos()
            local ang = phys:GetAngles()
            assert(pos.x == 100 and pos.y == 200 and pos.z == 300)
            assert(ang.p == 11 and ang.y == 22 and ang.r == 33)
            """,
            sourceName: "=(committed PhysObj transform snapshot)"
        )

        _ = try setup.adapter.runServerFixedTick()
        let nextStep = try coordinator.step(
            inputs: setup.adapter.prepareCanonicalPropPhysicsStep(),
            simulationTick: UInt64(setup.adapter.serverGlobals.tickCount)
        )
        XCTAssertEqual(nextStep.commandSequences, [6])
        XCTAssertEqual(nextStep.operations, [])
        XCTAssertEqual(nextStep.bodies.first?.transform, firstBody.transform)
        try setup.adapter.commitCanonicalPropPhysicsStep(nextStep)
    }

    func testSetMassUsesFullBodyIdentityFIFOAndPublishesCanonicalSnapshot()
        throws
    {
        let setup = try makeSetup()
        defer { setup.close() }

        let values = try setup.server.executeReturningValues(
            """
            local prop = assert(ents.Create("prop_physics"))
            prop:SetModel("models/props/physics_mutation.mdl")
            prop:Spawn()
            prop:Activate()
            local phys = prop:GetPhysicsObject()
            assert(IsValid(phys))
            assert(phys:GetMass() == 19)
            phys:SetMass(38)
            MASS_PROP = prop
            return prop
            """,
            sourceName: "=(authoritative PhysObj SetMass FIFO)"
        )
        let entity = try XCTUnwrap(
            setup.server.entityRegistry?.canonicalSnapshot(
                for: try XCTUnwrap(values.first)
            )
        )
        let bodyID = try SourcePhysicsBodyID(
            entityIdentity: entity.identity,
            solidIndex: 0
        )
        let pending = setup.transport
            .preparePendingCanonicalPhysicsBodyCommands()
        XCTAssertEqual(pending.map(\.sequence), [1, 2])
        guard case let .createBody(creation) = pending[0].payload,
              case let .mutateBody(mutation) = pending[1].payload else {
            return XCTFail("SetMass did not follow body creation in the FIFO")
        }
        XCTAssertEqual(creation.bodyID, bodyID)
        XCTAssertEqual(mutation.bodyID, bodyID)
        XCTAssertEqual(mutation.mutation, .setMassKilograms(38))

        _ = try setup.adapter.runServerFixedTick()
        let coordinator = SourceCanonicalPropPhysicsCoordinator(
            environment: setup.environment,
            commandSequenceSource: setup.transport
        )
        let step = try coordinator.step(
            inputs: setup.adapter.prepareCanonicalPropPhysicsStep(),
            simulationTick: UInt64(setup.adapter.serverGlobals.tickCount)
        )
        XCTAssertEqual(step.commandSequences, [1, 2, 3])
        let body = try XCTUnwrap(step.bodies.first)
        XCTAssertEqual(body.bodyID, bodyID)
        XCTAssertEqual(body.massProperties.massKilograms, 38)
        XCTAssertEqual(
            body.massProperties.principalInertia,
            SourceVector3(4, 6, 8)
        )
        try setup.adapter.commitCanonicalPropPhysicsStep(step)

        _ = try setup.adapter.runServerFixedTick()
        let nextStep = try coordinator.step(
            inputs: setup.adapter.prepareCanonicalPropPhysicsStep(),
            simulationTick: UInt64(setup.adapter.serverGlobals.tickCount)
        )
        XCTAssertEqual(nextStep.commandSequences, [4])
        XCTAssertEqual(nextStep.operations, [])
        XCTAssertEqual(nextStep.bodies.first?.massProperties, body.massProperties)
        try setup.adapter.commitCanonicalPropPhysicsStep(nextStep)

        try setup.server.execute(
            """
            local phys = MASS_PROP:GetPhysicsObject()
            assert(IsValid(phys))
            assert(phys:GetMass() == 38)
            local inertia = phys:GetInertia()
            assert(inertia.x == 4 and inertia.y == 6 and inertia.z == 8)
            """,
            sourceName: "=(committed PhysObj SetMass snapshot)"
        )
    }

    func testSpawnWakeAndMutatorsShareGlobalFIFOThenPublishNextTick()
        throws
    {
        let setup = try makeSetup()
        defer { setup.close() }
        let skippedSequence = try setup.transport
            .reservePhysicsCommandSequences(count: 1)
        XCTAssertEqual(skippedSequence, [1])

        let values = try setup.server.executeReturningValues(
            """
            local prop = assert(ents.Create("prop_physics"))
            prop:SetModel("models/props/physics_mutation.mdl")
            prop:SetPos(Vector(10, 20, 30))
            prop:Spawn()
            prop:Activate()
            local phys = prop:GetPhysicsObject()
            assert(IsValid(phys))
            phys:Wake()
            phys:EnableGravity(false)
            phys:EnableCollisions(false)
            phys:SetVelocity(Vector(10, 0, 0))
            phys:AddVelocity(Vector(5, 0, 0))
            phys:SetAngleVelocity(Vector(1, 2, 3))
            phys:AddAngleVelocity(Vector(4, 5, 6))
            phys:SetDamping(2, 4)
            phys:ApplyForceCenter(Vector(190, 0, 0))
            phys:ApplyTorqueCenter(Vector(8, 0, 0))
            MUTATION_PROP = prop
            return prop
            """,
            sourceName: "=(authoritative PhysObj mutation FIFO)"
        )
        let prop = try XCTUnwrap(values.first)
        let entity = try XCTUnwrap(
            setup.server.entityRegistry?.canonicalSnapshot(for: prop)
        )
        let bodyID = try SourcePhysicsBodyID(
            entityIdentity: entity.identity,
            solidIndex: 0
        )
        let pending = setup.transport
            .preparePendingCanonicalPhysicsBodyCommands()
        XCTAssertEqual(pending.map(\.sequence), Array(2 ... 12).map(UInt64.init))
        XCTAssertEqual(setup.transport.pendingPhysicsBodyCommandCount, 11)
        guard case let .createBody(creation) = pending[0].payload else {
            return XCTFail("first pending command was not verified body creation")
        }
        XCTAssertEqual(creation.bodyID, bodyID)
        for command in pending.dropFirst() {
            guard case let .mutateBody(mutation) = command.payload else {
                return XCTFail("non-mutation followed queued creation")
            }
            XCTAssertEqual(mutation.bodyID, bodyID)
        }

        _ = try setup.adapter.runServerFixedTick()
        let coordinator = SourceCanonicalPropPhysicsCoordinator(
            environment: setup.environment,
            commandSequenceSource: setup.transport
        )
        let tick = UInt64(setup.adapter.serverGlobals.tickCount)
        let firstStep = try coordinator.step(
            inputs: setup.adapter.prepareCanonicalPropPhysicsStep(),
            simulationTick: tick
        )
        XCTAssertEqual(firstStep.commandSequences, Array(2 ... 13).map(UInt64.init))
        XCTAssertEqual(firstStep.operations, [.create(bodyID)])
        XCTAssertEqual(setup.transport.pendingPhysicsBodyCommandCount, 0)
        let firstBody = try XCTUnwrap(firstStep.bodies.first)
        XCTAssertEqual(firstBody.bodyID, bodyID)
        XCTAssertTrue(firstBody.isMotionEnabled)
        XCTAssertFalse(firstBody.isGravityEnabled)
        XCTAssertFalse(firstBody.isCollisionEnabled)
        XCTAssertEqual(firstBody.transform.origin.z, 30)
        XCTAssertEqual(firstBody.damping.linear, 2)
        XCTAssertEqual(firstBody.damping.angular, 4)
        XCTAssertEqual(firstBody.linearVelocity.x, 14.6955, accuracy: 0.000_01)
        XCTAssertEqual(
            firstBody.angularVelocity,
            SourceVector3(8.46, 6.58, 8.46)
        )
        XCTAssertEqual(firstBody.transform.origin.x, 10.220_432, accuracy: 0.000_01)
        XCTAssertEqual(firstBody.transform.angles.pitch, 0.1269, accuracy: 0.000_01)
        try setup.adapter.commitCanonicalPropPhysicsStep(firstStep)

        try setup.server.execute(
            """
            local phys = MUTATION_PROP:GetPhysicsObject()
            assert(IsValid(phys))
            assert(phys:IsMotionEnabled())
            assert(phys:IsGravityEnabled() == false)
            assert(phys:IsCollisionEnabled() == false)
            local velocity = phys:GetVelocity()
            assert(math.abs(velocity.x - 14.6955) < 0.0001)
            local angular = phys:GetAngleVelocity()
            assert(math.abs(angular.x - 8.46) < 0.0001)
            assert(math.abs(angular.y - 6.58) < 0.0001)
            assert(math.abs(angular.z - 8.46) < 0.0001)
            local speedDamping, rotDamping = phys:GetDamping()
            assert(speedDamping == 2 and rotDamping == 4)
            assert(phys:GetSpeedDamping() == 2)
            assert(phys:GetRotDamping() == 4)
            """,
            sourceName: "=(committed PhysObj mutation snapshot)"
        )

        _ = try setup.adapter.runServerFixedTick()
        let secondTick = UInt64(setup.adapter.serverGlobals.tickCount)
        let secondStep = try coordinator.step(
            inputs: setup.adapter.prepareCanonicalPropPhysicsStep(),
            simulationTick: secondTick
        )
        XCTAssertEqual(secondStep.commandSequences, [14])
        XCTAssertEqual(secondStep.operations, [])
        XCTAssertFalse(try XCTUnwrap(secondStep.bodies.first).isGravityEnabled)
        try setup.adapter.commitCanonicalPropPhysicsStep(secondStep)

        try setup.server.execute(
            """
            local phys = MUTATION_PROP:GetPhysicsObject()
            assert(IsValid(phys))
            MUTATION_PROP:Remove()
            local ok, message = pcall(function()
                phys:AddAngleVelocity(Vector(10, 20, 30))
            end)
            assert(ok == false)
            assert(string.find(message, "live canonical PhysObj expected", 1, true))
            """,
            sourceName: "=(pending-removal PhysObj angular mutation rejection)"
        )
        XCTAssertEqual(setup.transport.pendingPhysicsBodyCommandCount, 0)
    }

    func testEnvironmentFailureRetainsPreparedPrefixForExactRetry() throws {
        let setup = try makeSetup()
        defer { setup.close() }
        _ = try setup.server.executeReturningValues(
            """
            local prop = assert(ents.Create("prop_physics"))
            prop:SetModel("models/props/physics_mutation.mdl")
            prop:Spawn()
            local phys = prop:GetPhysicsObject()
            phys:SetVelocity(Vector(25, 0, 0))
            return prop
            """,
            sourceName: "=(retryable PhysObj mutation)"
        )
        _ = try setup.adapter.runServerFixedTick()
        let inputs = try setup.adapter.prepareCanonicalPropPhysicsStep()
        let failing = FailingOncePhysicsEnvironment(delegate: setup.environment)
        let coordinator = SourceCanonicalPropPhysicsCoordinator(
            environment: failing,
            commandSequenceSource: setup.transport
        )
        let tick = UInt64(setup.adapter.serverGlobals.tickCount)

        XCTAssertThrowsError(try coordinator.step(
            inputs: inputs,
            simulationTick: tick
        )) { error in
            XCTAssertEqual(
                error as? FailingOncePhysicsEnvironment.Failure,
                .injected
            )
        }
        XCTAssertEqual(setup.transport.pendingPhysicsBodyCommandCount, 2)
        XCTAssertNil(coordinator.committedSimulationTick)
        XCTAssertEqual(setup.environment.latestContacts, [])

        let retried = try coordinator.step(
            inputs: inputs,
            simulationTick: tick
        )
        XCTAssertEqual(retried.commandSequences, [1, 2, 4])
        XCTAssertEqual(setup.transport.pendingPhysicsBodyCommandCount, 0)
        XCTAssertEqual(retried.bodies.first?.linearVelocity.x, 25)
        try setup.adapter.commitCanonicalPropPhysicsStep(retried)
    }
}

private extension SourceCanonicalPhysicsObjectMutationIntegrationTests {
    struct Setup {
        let transport: GMLuaNetTransport
        let server: GMLuaRuntime
        let adapter: GMLuaSourceRuntimeAdapter
        let environment: SourceDeterministicPhysicsEnvironment

        func close() {
            try? adapter.close()
            _ = server.close()
        }
    }

    func makeSetup() throws -> Setup {
        let asset = try makeAttestedPropPhysicsTestAsset(
            modelPath: model.path,
            massKilograms: 19,
            mdlSHA256: digest(mdlData),
            phySHA256: digest(phyData),
            studioChecksum: studioChecksum
        )
        let resolver = try GModAttestedPropPhysicsAssetResolver(
            attestedAssets: [asset],
            loadObservedAsset: { [mdlData, phyData, studioChecksum] candidate in
                .loaded(GModObservedPropPhysicsAsset(
                    normalizedModelPath: candidate.path,
                    mdlData: mdlData,
                    phyData: phyData,
                    studioChecksum: studioChecksum
                ))
            }
        )
        let transport = GMLuaNetTransport()
        let server = GMLuaRuntime(
            realm: .server,
            logger: { _ in },
            netTransport: transport
        )
        try XCTUnwrap(server.typeSystem).installFallbackUtilities()
        let adapter = try GMLuaSourceRuntimeAdapter(
            serverRuntime: server,
            initialEntitySerialNumber: 47,
            canonicalModelValidator: { [model] candidate, kind in
                candidate == model && kind == .propPhysics ? .valid : .invalid
            },
            canonicalPropPhysicsAssetResolver: { candidate in
                resolver.resolve(candidate).canonicalResolution
            }
        )
        try adapter.installCanonicalEntityLuaBridge()
        try adapter.installCanonicalPhysicsObjectLuaBridge()
        return Setup(
            transport: transport,
            server: server,
            adapter: adapter,
            environment: SourceDeterministicPhysicsEnvironment()
        )
    }

    func digest(_ data: Data) -> String {
        var hasher = GModContentSHA256()
        hasher.update(data)
        return hasher.hexadecimalDigest()
    }
}

private final class FailingOncePhysicsEnvironment: SourcePhysicsEnvironment {
    enum Failure: Error, Equatable { case injected }

    let delegate: SourcePhysicsEnvironment
    private var shouldFail = true

    init(delegate: SourcePhysicsEnvironment) {
        self.delegate = delegate
    }

    func execute(
        _ batch: SourcePhysicsCommandBatch
    ) throws -> SourcePhysicsEnvironmentSnapshot {
        if shouldFail {
            shouldFail = false
            throw Failure.injected
        }
        return try delegate.execute(batch)
    }
}
