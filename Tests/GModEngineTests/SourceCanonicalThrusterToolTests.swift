import XCTest
@testable import GModEngine

private enum ThrusterToolTestFailure: Error, Equatable {
    case injectedQueueFailure
    case expectedSpawn
    case expectedUpdate
}

private final class ThrusterToolLimitRecorder {
    var requests: [SourceCanonicalThrusterLimitRequest] = []
    var responses: [Bool] = []

    func evaluate(_ request: SourceCanonicalThrusterLimitRequest) -> Bool {
        requests.append(request)
        return responses.isEmpty ? true : responses.removeFirst()
    }
}

private final class ThrusterToolModelRecorder {
    let definition: SourceCanonicalThrusterModelDefinition
    var requested: [SourceEntityModelReference] = []

    init(definition: SourceCanonicalThrusterModelDefinition) {
        self.definition = definition
    }

    func resolve(
        _ model: SourceEntityModelReference
    ) -> SourceCanonicalThrusterModelDefinition? {
        requested.append(model)
        return model.path.lowercased() == definition.model.path.lowercased()
            ? definition
            : nil
    }
}

private final class ThrusterToolPhysicsHost:
    SourceCanonicalPhysicsObjectLuaHost,
    @unchecked Sendable
{
    private var objects: [
        SourcePhysicsBodyID: SourceCanonicalPhysicsObjectSnapshot
    ] = [:]
    private var primaryByEntity: [
        SourceCanonicalEntityIdentity: SourcePhysicsBodyID
    ] = [:]
    var directMutations: [SourcePhysicsBodyMutationCommand] = []

    func publish(
        _ object: SourceCanonicalPhysicsObjectSnapshot,
        asPrimary: Bool = true
    ) {
        objects[object.bodyID] = object
        if asPrimary {
            primaryByEntity[object.bodyID.entityIdentity] = object.bodyID
        }
    }

    func primaryCanonicalPhysicsObject(
        for entity: SourceCanonicalEntityIdentity
    ) -> SourceCanonicalPhysicsObjectSnapshot? {
        primaryByEntity[entity].flatMap { objects[$0] }
    }

    func canonicalPhysicsObject(
        for bodyID: SourcePhysicsBodyID
    ) -> SourceCanonicalPhysicsObjectSnapshot? {
        objects[bodyID]
    }

    func enqueueCanonicalPhysicsObjectMutation(
        _ command: SourcePhysicsBodyMutationCommand
    ) throws {
        directMutations.append(command)
    }
}

private final class ThrusterToolRecordingQueue:
    SourceCanonicalThrusterPhysicsCommandQueue
{
    private(set) var accepted: [SourcePhysicsCommand] = []
    private var nextSequence: UInt64 = 100
    private var enqueueInvocation = 0
    var failOnEnqueueInvocation: Int?

    func enqueueCanonicalPhysicsBodyCommands(
        _ commands: [SourceCanonicalQueuedPhysicsBodyCommand]
    ) throws -> [SourcePhysicsCommand] {
        try append(commands.map(\.payload))
    }

    func preparePendingCanonicalPhysicsBodyCommands()
        -> [SourcePhysicsCommand]
    {
        accepted
    }

    func commitPendingCanonicalPhysicsBodyCommands(
        _ commands: [SourcePhysicsCommand]
    ) {
        guard accepted.starts(with: commands) else { return }
        accepted.removeFirst(commands.count)
    }

    func enqueueCanonicalPhysicsConstraintCommands(
        _ commands: [SourceCanonicalQueuedPhysicsConstraintCommand]
    ) throws -> [SourcePhysicsCommand] {
        try append(commands.map(\.payload))
    }

    func enqueueCanonicalThrusterPhysicsBodyDeletionCommands(
        _ commands: [SourcePhysicsBodyDeletionCommand]
    ) throws -> [SourcePhysicsCommand] {
        try append(commands.map(SourcePhysicsCommandPayload.deleteBody))
    }

    func rollbackCanonicalPhysicsConstraintCommands(
        _ commands: [SourcePhysicsCommand]
    ) {
        guard accepted.count >= commands.count else {
            preconditionFailure("rollback exceeds recorded FIFO")
        }
        let suffix = Array(accepted.suffix(commands.count))
        precondition(suffix == commands, "rollback must remove exact suffix")
        accepted.removeLast(commands.count)
    }

    private func append(
        _ payloads: [SourcePhysicsCommandPayload]
    ) throws -> [SourcePhysicsCommand] {
        enqueueInvocation += 1
        if enqueueInvocation == failOnEnqueueInvocation {
            throw ThrusterToolTestFailure.injectedQueueFailure
        }
        let commands = payloads.map { payload -> SourcePhysicsCommand in
            defer { nextSequence += 1 }
            return SourcePhysicsCommand(sequence: nextSequence, payload: payload)
        }
        accepted.append(contentsOf: commands)
        return commands
    }
}

final class SourceCanonicalThrusterToolTests: XCTestCase {
    func testStockSpawnWeldsWithFullHandlesAndDisablesAttachedBodyCollision()
        throws
    {
        let fixture = try makeFixture()
        let request = makeRequest(
            actor: fixture.player,
            target: fixture.target.identity,
            physicsBone: fixture.asset.bodyDefinition.solidIndex,
            settings: .bundledDefaults
        )
        var canToolCalls: [SourceCanonicalThrusterToolRequest] = []
        let result = try fixture.coordinator.perform(request) { request in
            canToolCalls.append(request)
            return true
        }
        let spawn = try requireSpawn(result)

        XCTAssertEqual(canToolCalls.count, 1)
        XCTAssertEqual(canToolCalls[0].mode, "thruster")
        XCTAssertEqual(canToolCalls[0].action, 1)
        XCTAssertEqual(canToolCalls[0].actor, fixture.player)
        XCTAssertEqual(fixture.limits.requests.map(\.phase), [.weapon, .player])
        XCTAssertTrue(fixture.limits.requests.allSatisfy {
            $0.player == fixture.player.identity && $0.category == "thrusters"
        })
        XCTAssertEqual(
            fixture.models.requested,
            [SourceCanonicalThrusterToolSettings.bundledDefaults.model]
        )

        let thruster = spawn.thruster
        XCTAssertEqual(thruster.className, "gmod_thruster")
        XCTAssertEqual(thruster.lifecycle, .active)
        XCTAssertEqual(thruster.revision, 1)
        XCTAssertEqual(thruster.owner, fixture.player.identity)
        XCTAssertEqual(thruster.creator, fixture.player.identity)
        XCTAssertEqual(thruster.target, fixture.target.identity)
        XCTAssertEqual(thruster.bodyID.entityIdentity, thruster.identity)
        XCTAssertEqual(
            thruster.bodyID.solidIndex,
            fixture.asset.bodyDefinition.solidIndex
        )
        let weld = try XCTUnwrap(thruster.weld)
        XCTAssertEqual(weld.targetEntity, fixture.target.identity)
        XCTAssertEqual(weld.targetBodyID, fixture.targetBody.bodyID)
        XCTAssertEqual(spawn.undo.name, "gmod_thruster")
        XCTAssertEqual(spawn.undo.player, fixture.player.identity)
        XCTAssertEqual(spawn.undo.thruster, thruster.identity)
        XCTAssertEqual(spawn.undo.constraintEntity, weld.constraintEntity)
        XCTAssertEqual(spawn.cleanupCategory, "thrusters")
        XCTAssertEqual(
            Set(spawn.cleanupEntities),
            Set([thruster.identity, weld.constraintEntity])
        )
        XCTAssertTrue(thruster.disablesCollisionsWhenWelded)
        XCTAssertEqual(thruster.collisionGroup, .world)
        XCTAssertFalse(thruster.isOn)
        XCTAssertEqual(
            thruster.forwardThrustOffset,
            SourceVector3(0, 0, fixture.asset.collisionProperty.maxs.z)
        )
        XCTAssertEqual(
            thruster.reverseEffectOffset,
            SourceVector3(0, 0, fixture.asset.collisionProperty.mins.z)
        )
        XCTAssertEqual(
            thruster.transform.origin,
            SourceVector3(
                100,
                200,
                32 - fixture.asset.collisionProperty.mins.z
            )
        )
        XCTAssertEqual(thruster.transform.angles.pitch, 0, accuracy: 0.0001)
        XCTAssertEqual(thruster.transform.angles.yaw, 0, accuracy: 0.0001)
        XCTAssertEqual(thruster.transform.angles.roll, 0, accuracy: 0.0001)

        XCTAssertEqual(fixture.graph.records.count, 1)
        XCTAssertEqual(
            Set(fixture.graph.records[0].entities),
            Set([thruster.identity, fixture.target.identity])
        )
        XCTAssertEqual(fixture.queue.accepted.count, 4)
        guard case let .createBody(bodyCreation) =
            fixture.queue.accepted[0].payload else {
            return XCTFail("first FIFO command must create the thruster body")
        }
        XCTAssertEqual(bodyCreation.bodyID, thruster.bodyID)
        XCTAssertFalse(
            bodyCreation.isCollisionEnabled,
            "stock attached nocollide disables the new thruster PhysObj"
        )
        guard case let .createFixedConstraint(fixed) =
            fixture.queue.accepted[1].payload else {
            return XCTFail("second FIFO command must author the weld")
        }
        XCTAssertEqual(fixed.constraintID, weld.constraintID)
        XCTAssertEqual(fixed.referenceBodyID, fixture.targetBody.bodyID)
        XCTAssertEqual(fixed.attachedBodyID, thruster.bodyID)
        guard case let .mutateBody(wakeThruster) =
            fixture.queue.accepted[2].payload,
              case .wake = wakeThruster.mutation,
              case let .mutateBody(wakeTarget) =
                fixture.queue.accepted[3].payload,
              case .wake = wakeTarget.mutation else {
            return XCTFail("weld creation must wake both bodies in FIFO order")
        }
        XCTAssertEqual(wakeThruster.bodyID, thruster.bodyID)
        XCTAssertEqual(wakeTarget.bodyID, fixture.targetBody.bodyID)
        XCTAssertEqual(
            fixture.queue.accepted.map(\.sequence),
            fixture.queue.accepted.map(\.sequence).sorted()
        )

        let client = SourceCanonicalThrusterClientProjection()
        let initial = try XCTUnwrap(
            fixture.coordinator.drainReplicationBatch()
        )
        XCTAssertEqual(initial.operations.count, 2)
        try client.apply(initial)
        XCTAssertFalse(try XCTUnwrap(client.snapshot(for: thruster.identity))
            .isEffectVisible)

        let switched = try XCTUnwrap(fixture.coordinator.handleInput(
            SourceCanonicalThrusterInput(
                player: fixture.player.identity,
                thruster: thruster.identity,
                direction: .forward,
                isPressed: true,
                source: .numpad(key: thruster.forwardKey)
            )
        ))
        XCTAssertEqual(switched.multiply, 1)
        XCTAssertTrue(switched.isOn)
        guard case let .mutateBody(inputWake) =
            fixture.queue.accepted.last?.payload,
              case .wake = inputWake.mutation else {
            return XCTFail("stock Switch must wake the thruster PhysObj")
        }
        XCTAssertEqual(inputWake.bodyID, thruster.bodyID)
        let switchedBatch = try XCTUnwrap(
            fixture.coordinator.drainReplicationBatch()
        )
        try client.apply(switchedBatch)
        let rendered = try XCTUnwrap(client.snapshot(for: thruster.identity))
        XCTAssertTrue(rendered.isEffectVisible)
        XCTAssertTrue(rendered.isLoopSoundActive)

        fixture.physics.publish(try makePhysicsObject(bodyCreation))
        let applications = try fixture.coordinator
            .enqueueActiveForceTorqueApplications()
        XCTAssertEqual(applications.count, 1)
        XCTAssertEqual(applications[0].thruster, thruster.identity)
        XCTAssertEqual(applications[0].bodyID, thruster.bodyID)
        let expectedLocalForce = -thruster.forwardThrustOffset *
            thruster.force * Float(switched.forceSimulationMultiplier) * 50
        assertVector(
            applications[0].worldForce,
            equals: thruster.transform.transformDirectionFromLocal(
                expectedLocalForce
            ),
            accuracy: 0.001
        )
        assertVector(
            applications[0].worldApplicationPoint,
            equals: thruster.transform.origin + thruster.forwardThrustOffset,
            accuracy: 0.0001
        )
        XCTAssertEqual(fixture.queue.accepted.last?.payload,
                       .mutateBody(applications[0].mutation))
    }

    func testWorldPlacementDoesNotWeldOrDisableCollision() throws {
        let fixture = try makeFixture()
        let result = try fixture.coordinator.perform(makeRequest(
            actor: fixture.player,
            target: fixture.world.identity,
            physicsBone: 0,
            settings: .bundledDefaults
        ), canTool: { _ in true })
        let spawn = try requireSpawn(result)

        XCTAssertNil(spawn.thruster.weld)
        XCTAssertFalse(spawn.thruster.disablesCollisionsWhenWelded)
        XCTAssertEqual(spawn.thruster.collisionGroup, .defaultGroup)
        XCTAssertEqual(spawn.cleanupEntities, [spawn.thruster.identity])
        XCTAssertTrue(fixture.graph.records.isEmpty)
        XCTAssertEqual(fixture.queue.accepted.count, 1)
        guard case let .createBody(command) = fixture.queue.accepted[0].payload
        else { return XCTFail("world placement should only create one body") }
        XCTAssertTrue(command.isCollisionEnabled)
    }

    func testOwnedThrusterUpdateBypassesModelAndLimitAndRebindsInputs()
        throws
    {
        let fixture = try makeFixture()
        let spawn = try requireSpawn(try fixture.coordinator.perform(
            makeRequest(
                actor: fixture.player,
                target: fixture.target.identity,
                physicsBone: fixture.asset.bodyDefinition.solidIndex,
                settings: .bundledDefaults
            ),
            canTool: { _ in true }
        ))
        let client = SourceCanonicalThrusterClientProjection()
        try client.apply(try XCTUnwrap(
            fixture.coordinator.drainReplicationBatch()
        ))
        fixture.limits.requests.removeAll()
        fixture.models.requested.removeAll()

        let addonSettings = SourceCanonicalThrusterToolSettings(
            force: -500,
            model: SourceEntityModelReference("models/addon/not-in-list.mdl"),
            forwardKey: 17,
            reverseKey: 19,
            isToggle: true,
            disablesCollisionsWhenWelded: false,
            effect: "addon_custom_effect",
            activatesOnDamage: true,
            soundName: "Addon.CustomLoop"
        )
        let updated = try requireUpdate(try fixture.coordinator.perform(
            makeRequest(
                actor: fixture.player,
                target: spawn.thruster.identity,
                physicsBone: spawn.thruster.bodyID.solidIndex,
                settings: addonSettings
            ),
            canTool: { request in
                XCTAssertEqual(request.mode, "thruster")
                return true
            }
        ))

        XCTAssertEqual(updated.force, 0)
        XCTAssertEqual(updated.forwardKey, 17)
        XCTAssertEqual(updated.reverseKey, 19)
        XCTAssertTrue(updated.isToggle)
        XCTAssertEqual(updated.effect, "addon_custom_effect")
        XCTAssertEqual(updated.soundName, "Addon.CustomLoop")
        XCTAssertTrue(updated.activatesOnDamage)
        XCTAssertEqual(updated.multiply, 0)
        XCTAssertEqual(updated.forceSimulationMultiplier, 1)
        XCTAssertTrue(fixture.limits.requests.isEmpty)
        XCTAssertTrue(fixture.models.requested.isEmpty)

        XCTAssertNil(try fixture.coordinator.handleInput(
            SourceCanonicalThrusterInput(
                player: fixture.player.identity,
                thruster: updated.identity,
                direction: .forward,
                isPressed: true,
                source: .numpad(key: 45)
            )
        ))
        let toggledOn = try XCTUnwrap(fixture.coordinator.handleInput(
            SourceCanonicalThrusterInput(
                player: fixture.player.identity,
                thruster: updated.identity,
                direction: .reverse,
                isPressed: true,
                source: .numpad(key: 19)
            )
        ))
        XCTAssertEqual(toggledOn.multiply, -1)
        XCTAssertTrue(toggledOn.isOn)
        XCTAssertNil(try fixture.coordinator.handleInput(
            SourceCanonicalThrusterInput(
                player: fixture.player.identity,
                thruster: updated.identity,
                direction: .reverse,
                isPressed: false,
                source: .numpad(key: 19)
            )
        ))
        let toggledOff = try XCTUnwrap(fixture.coordinator.handleInput(
            SourceCanonicalThrusterInput(
                player: fixture.player.identity,
                thruster: updated.identity,
                direction: .reverse,
                isPressed: true,
                source: .numpad(key: 19)
            )
        ))
        XCTAssertEqual(toggledOff.multiply, 0)
        XCTAssertFalse(toggledOff.isOn)

        try client.apply(try XCTUnwrap(
            fixture.coordinator.drainReplicationBatch()
        ))
        let projected = try XCTUnwrap(client.snapshot(for: updated.identity))
        XCTAssertFalse(projected.isEffectVisible)
        XCTAssertFalse(projected.isLoopSoundActive)
    }

    func testDamageActivationKeepsLastForceAndUsesStrictFiveSecondExpiry()
        throws
    {
        let fixture = try makeFixture()
        var settings = SourceCanonicalThrusterToolSettings.bundledDefaults
        settings = SourceCanonicalThrusterToolSettings(
            force: settings.force,
            model: settings.model,
            forwardKey: settings.forwardKey,
            reverseKey: settings.reverseKey,
            isToggle: settings.isToggle,
            disablesCollisionsWhenWelded:
                settings.disablesCollisionsWhenWelded,
            effect: settings.effect,
            activatesOnDamage: true,
            soundName: settings.soundName
        )
        let spawn = try requireSpawn(try fixture.coordinator.perform(
            makeRequest(
                actor: fixture.player,
                target: fixture.target.identity,
                physicsBone: fixture.asset.bodyDefinition.solidIndex,
                settings: settings
            ),
            canTool: { _ in true }
        ))
        guard case let .createBody(bodyCreation) =
            fixture.queue.accepted[0].payload else {
            return XCTFail("missing thruster body creation")
        }
        fixture.physics.publish(try makePhysicsObject(bodyCreation))

        let damaged = try XCTUnwrap(
            fixture.coordinator.handleDamageActivation(
                thruster: spawn.thruster.identity,
                serverTime: 20
            )
        )
        XCTAssertTrue(damaged.isOn)
        XCTAssertEqual(damaged.multiply, 0)
        XCTAssertEqual(damaged.forceSimulationMultiplier, 1)
        XCTAssertEqual(damaged.damageSwitchOffTime, 25)
        let manuallyPressed = try XCTUnwrap(
            fixture.coordinator.handleInput(SourceCanonicalThrusterInput(
                player: fixture.player.identity,
                thruster: damaged.identity,
                direction: .forward,
                isPressed: true,
                source: .numpad(key: damaged.forwardKey)
            ))
        )
        XCTAssertEqual(
            manuallyPressed.damageSwitchOffTime,
            25,
            "stock AddMul does not cancel an existing damage timer"
        )
        XCTAssertEqual(
            try fixture.coordinator.enqueueActiveForceTorqueApplications().count,
            1
        )
        XCTAssertTrue(try fixture.coordinator.advanceServerTime(25).isEmpty)
        XCTAssertTrue(try XCTUnwrap(fixture.coordinator.snapshot(
            for: damaged.identity
        )).isOn)
        let expired = try fixture.coordinator.advanceServerTime(25.001)
        XCTAssertEqual(expired.count, 1)
        XCTAssertFalse(expired[0].isOn)
        XCTAssertEqual(expired[0].multiply, 1)
    }

    func testCanToolAndBothStockLimitGatesRejectWithoutMutation() throws {
        do {
            let fixture = try makeFixture()
            let before = fixture.store.entityList.activeCount
            let denied = try fixture.coordinator.perform(makeRequest(
                actor: fixture.player,
                target: fixture.target.identity,
                physicsBone: fixture.asset.bodyDefinition.solidIndex,
                settings: .bundledDefaults
            ), canTool: { _ in false })
            XCTAssertEqual(denied, .rejected(.canToolDenied))
            XCTAssertEqual(fixture.store.entityList.activeCount, before)
            XCTAssertTrue(fixture.limits.requests.isEmpty)
            XCTAssertTrue(fixture.queue.accepted.isEmpty)
        }
        do {
            let fixture = try makeFixture()
            fixture.limits.responses = [false]
            let before = fixture.store.entityList.activeCount
            let denied = try fixture.coordinator.perform(makeRequest(
                actor: fixture.player,
                target: fixture.target.identity,
                physicsBone: fixture.asset.bodyDefinition.solidIndex,
                settings: .bundledDefaults
            ), canTool: { _ in true })
            XCTAssertEqual(denied, .rejected(.thrusterLimitReached))
            XCTAssertEqual(fixture.limits.requests.map(\.phase), [.weapon])
            XCTAssertEqual(fixture.store.entityList.activeCount, before)
            XCTAssertTrue(fixture.queue.accepted.isEmpty)
        }
        do {
            let fixture = try makeFixture()
            fixture.limits.responses = [true, false]
            let before = fixture.store.entityList.activeCount
            let denied = try fixture.coordinator.perform(makeRequest(
                actor: fixture.player,
                target: fixture.target.identity,
                physicsBone: fixture.asset.bodyDefinition.solidIndex,
                settings: .bundledDefaults
            ), canTool: { _ in true })
            XCTAssertEqual(denied, .rejected(.thrusterLimitReached))
            XCTAssertEqual(
                fixture.limits.requests.map(\.phase),
                [.weapon, .player]
            )
            XCTAssertEqual(fixture.store.entityList.activeCount, before)
            XCTAssertTrue(fixture.queue.accepted.isEmpty)
        }
    }

    func testQueueFailureRollsBackExactBodyConstraintAndEntitySuffix()
        throws
    {
        let fixture = try makeFixture()
        fixture.queue.failOnEnqueueInvocation = 3
        let before = fixture.store.entityList.activeCount
        XCTAssertThrowsError(try fixture.coordinator.perform(makeRequest(
            actor: fixture.player,
            target: fixture.target.identity,
            physicsBone: fixture.asset.bodyDefinition.solidIndex,
            settings: .bundledDefaults
        ), canTool: { _ in true })) { error in
            XCTAssertEqual(
                error as? ThrusterToolTestFailure,
                .injectedQueueFailure
            )
        }
        XCTAssertTrue(fixture.queue.accepted.isEmpty)
        XCTAssertTrue(fixture.graph.records.isEmpty)
        XCTAssertTrue(fixture.coordinator.snapshots.isEmpty)
        XCTAssertTrue(fixture.coordinator.undoRecords.isEmpty)
        XCTAssertNil(try fixture.coordinator.drainReplicationBatch())
        XCTAssertEqual(fixture.store.entityList.activeCount, before)
    }

    func testUndoCleanupRemovesWeldAndRejectsStaleReusedHandle() throws {
        let fixture = try makeFixture()
        let first = try requireSpawn(try fixture.coordinator.perform(
            makeRequest(
                actor: fixture.player,
                target: fixture.target.identity,
                physicsBone: fixture.asset.bodyDefinition.solidIndex,
                settings: .bundledDefaults
            ),
            canTool: { _ in true }
        ))
        let client = SourceCanonicalThrusterClientProjection()
        try client.apply(try XCTUnwrap(
            fixture.coordinator.drainReplicationBatch()
        ))

        XCTAssertEqual(
            try fixture.coordinator.undoLatestThruster(
                for: fixture.player.identity
            ),
            first.thruster.identity
        )
        XCTAssertEqual(
            fixture.coordinator.snapshot(for: first.thruster.identity)?.lifecycle,
            .pendingRemoval
        )
        XCTAssertTrue(fixture.graph.records.isEmpty)
        XCTAssertEqual(fixture.store.entityList.pendingDeletionCount, 2)
        XCTAssertEqual(fixture.queue.accepted.count, 6)
        guard case let .deleteConstraint(deleteWeld) =
            fixture.queue.accepted[4].payload,
              case let .deleteBody(deleteBody) =
                fixture.queue.accepted[5].payload else {
            return XCTFail("undo must delete weld then full-identity body")
        }
        XCTAssertEqual(
            deleteWeld.constraintID,
            try XCTUnwrap(first.thruster.weld).constraintID
        )
        XCTAssertEqual(deleteBody.bodyID, first.thruster.bodyID)
        try client.apply(try XCTUnwrap(
            fixture.coordinator.drainReplicationBatch()
        ))
        XCTAssertEqual(
            client.snapshot(for: first.thruster.identity)?.lifecycle,
            .pendingRemoval
        )

        XCTAssertEqual(fixture.store.entityList.cleanupDeleteList(), 2)
        let removed = try XCTUnwrap(
            fixture.coordinator.acknowledgeCleanup(first.thruster.identity)
        )
        XCTAssertEqual(removed.lifecycle, .removed)
        try client.apply(try XCTUnwrap(
            fixture.coordinator.drainReplicationBatch()
        ))
        XCTAssertNil(client.snapshot(for: first.thruster.identity))
        XCTAssertFalse(fixture.coordinator.undoRecords[0].isLive)

        fixture.limits.requests.removeAll()
        let replacement = try requireSpawn(try fixture.coordinator.perform(
            makeRequest(
                actor: fixture.player,
                target: fixture.target.identity,
                physicsBone: fixture.asset.bodyDefinition.solidIndex,
                settings: .bundledDefaults
            ),
            canTool: { _ in true }
        ))
        XCTAssertEqual(
            replacement.thruster.identity.entryIndex,
            first.thruster.identity.entryIndex
        )
        XCTAssertNotEqual(
            replacement.thruster.identity.handle,
            first.thruster.identity.handle
        )
        XCTAssertNil(try fixture.coordinator.handleInput(
            SourceCanonicalThrusterInput(
                player: fixture.player.identity,
                thruster: first.thruster.identity,
                direction: .forward,
                isPressed: true,
                source: .numpad(key: 45)
            )
        ))
        XCTAssertNotNil(fixture.coordinator.snapshot(
            for: replacement.thruster.identity
        ))
    }

    func testNonActivePlayerIsRejectedBeforeCanTool() throws {
        let fixture = try makeFixture()
        let created = try fixture.store.create(
            kind: .player,
            at: 11
        )
        let spawned = try fixture.store.spawn(created.identity)
        var canToolCalled = false
        let result = try fixture.coordinator.perform(makeRequest(
            actor: spawned,
            target: fixture.target.identity,
            physicsBone: fixture.asset.bodyDefinition.solidIndex,
            settings: .bundledDefaults
        ), canTool: { _ in canToolCalled = true; return true })
        XCTAssertEqual(result, .rejected(.actorIsNotLivePlayer))
        XCTAssertFalse(canToolCalled)
    }

    private struct Fixture {
        let store: SourceCanonicalEntityStore
        let physics: ThrusterToolPhysicsHost
        let queue: ThrusterToolRecordingQueue
        let graph: SourceCanonicalConstraintGraph
        let limits: ThrusterToolLimitRecorder
        let models: ThrusterToolModelRecorder
        let coordinator: SourceCanonicalThrusterToolCoordinator
        let asset: SourceAttestedPropPhysicsAsset
        let world: SourceCanonicalEntitySnapshot
        let player: SourceCanonicalEntitySnapshot
        let target: SourceCanonicalEntitySnapshot
        let targetBody: SourceCanonicalPhysicsObjectSnapshot
    }

    private func makeFixture() throws -> Fixture {
        let model = SourceCanonicalThrusterToolSettings.bundledDefaults.model
        let asset = try makeAttestedPropPhysicsTestAsset(
            modelPath: model.path,
            bodyBehavior: SourceAttestedPropPhysicsBodyBehavior(
                motionType: .dynamicBody,
                damping: .zero,
                isGravityEnabled: true,
                isCollisionEnabled: true,
                startsAwake: true
            )
        )
        let definition = try SourceCanonicalThrusterModelDefinition(
            model: model,
            collisionBounds: asset.collisionProperty,
            body: asset.bodyDefinition
        )
        let store = SourceCanonicalEntityStore(
            modelValidator: { requested, kind in
                requested.path.lowercased() == model.path.lowercased() &&
                    kind == .propPhysics ? .valid : .invalid
            }
        )
        let worldCreated = try store.create(kind: .world, at: 0)
        _ = try store.spawn(worldCreated.identity)
        let world = try store.activate(worldCreated.identity)
        let playerCreated = try store.create(kind: .player, at: 1)
        _ = try store.spawn(playerCreated.identity)
        let player = try store.activate(playerCreated.identity)
        var targetState = SourceCanonicalEntityState.defaults(for: .propPhysics)
        targetState.model = model
        targetState.collisionProperty = asset.collisionProperty
        targetState.transform = SourceEntityTransform(
            origin: SourceVector3(256, 32, 64),
            angles: SourceQAngle(yaw: 30)
        )
        let targetCreated = try store.create(
            kind: .propPhysics,
            at: 10,
            state: targetState
        )
        _ = try store.spawn(targetCreated.identity)
        let target = try store.activate(targetCreated.identity)
        let targetBody = try SourceCanonicalPhysicsObjectSnapshot(
            pendingEntity: target,
            definition: asset.bodyDefinition
        )
        let physics = ThrusterToolPhysicsHost()
        physics.publish(targetBody)
        let queue = ThrusterToolRecordingQueue()
        let graph = SourceCanonicalConstraintGraph()
        let limits = ThrusterToolLimitRecorder()
        let models = ThrusterToolModelRecorder(definition: definition)
        let coordinator = SourceCanonicalThrusterToolCoordinator(
            entityList: store.entityList,
            physicsHost: physics,
            commandQueue: queue,
            constraintGraph: graph,
            modelResolver: { models.resolve($0) },
            limitGate: { limits.evaluate($0) }
        )
        return Fixture(
            store: store,
            physics: physics,
            queue: queue,
            graph: graph,
            limits: limits,
            models: models,
            coordinator: coordinator,
            asset: asset,
            world: world,
            player: player,
            target: target,
            targetBody: targetBody
        )
    }

    private func makeRequest(
        actor: SourceCanonicalEntitySnapshot,
        target: SourceCanonicalEntityIdentity,
        physicsBone: Int,
        settings: SourceCanonicalThrusterToolSettings
    ) -> SourceCanonicalThrusterToolRequest {
        SourceCanonicalThrusterToolRequest(
            actor: actor,
            trace: SourceCanonicalThrusterTrace(
                hitPosition: SourceVector3(100, 200, 32),
                hitNormal: SourceVector3(0, 0, 1),
                target: target,
                physicsBone: physicsBone
            ),
            settings: settings
        )
    }

    private func requireSpawn(
        _ result: SourceCanonicalThrusterToolResult
    ) throws -> SourceCanonicalThrusterSpawnResult {
        guard case let .spawned(spawn) = result else {
            XCTFail("expected a spawned stock thruster, received \(result)")
            throw ThrusterToolTestFailure.expectedSpawn
        }
        return spawn
    }

    private func requireUpdate(
        _ result: SourceCanonicalThrusterToolResult
    ) throws -> SourceCanonicalThrusterEntitySnapshot {
        guard case let .updated(snapshot) = result else {
            XCTFail("expected an updated stock thruster, received \(result)")
            throw ThrusterToolTestFailure.expectedUpdate
        }
        return snapshot
    }

    private func makePhysicsObject(
        _ creation: SourcePhysicsBodyCreationCommand
    ) throws -> SourceCanonicalPhysicsObjectSnapshot {
        try SourceCanonicalPhysicsObjectSnapshot(body:
            SourcePhysicsBodySnapshot(
                bodyID: creation.bodyID,
                shape: creation.shape,
                massProperties: creation.massProperties,
                transform: creation.transform,
                linearVelocity: creation.linearVelocity,
                angularVelocity: creation.angularVelocity,
                damping: creation.damping,
                motionType: creation.motionType,
                materialIndex: creation.materialIndex,
                isGravityEnabled: creation.isGravityEnabled,
                isCollisionEnabled: creation.isCollisionEnabled,
                isSleeping: !creation.startsAwake,
                simulationTick: 0
            )
        )
    }

    private func assertVector(
        _ actual: SourceVector3,
        equals expected: SourceVector3,
        accuracy: Float,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.x, expected.x, accuracy: accuracy,
                       file: file, line: line)
        XCTAssertEqual(actual.y, expected.y, accuracy: accuracy,
                       file: file, line: line)
        XCTAssertEqual(actual.z, expected.z, accuracy: accuracy,
                       file: file, line: line)
    }
}
