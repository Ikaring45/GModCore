import Testing
@testable import GModEngine

@Suite("Canonical prop physics coordinator")
struct SourceCanonicalPropPhysicsCoordinatorTests {
    @Test("spawned prop creates by full EHANDLE then advances exactly 0.015")
    func createAndSimulateUsesVerifiedBodyAndFullHandle() throws {
        let environment = RecordingPhysicsEnvironment()
        let sequences = RecordingPhysicsSequenceSource(first: 40)
        let coordinator = SourceCanonicalPropPhysicsCoordinator(
            environment: environment,
            commandSequenceSource: sequences
        )
        let definition = try makeBodyDefinition(solidIndex: 2)
        let entity = makeProp(
            entryIndex: 321,
            serialNumber: 77,
            lifecycle: .active,
            origin: SourceVector3(10, 20, 30),
            linearVelocity: SourceVector3(2, 0, 0)
        )

        let result = try coordinator.step(
            inputs: [try SourceCanonicalPropPhysicsInput(
                entity: entity,
                bodyDefinition: definition
            )],
            simulationTick: 8
        )

        let bodyID = try SourcePhysicsBodyID(
            entityIdentity: entity.identity,
            solidIndex: 2
        )
        #expect(result.commandSequences == [40, 41])
        #expect(result.operations == [.create(bodyID)])
        #expect(result.fixedTimeStepSeconds == 0.015)
        #expect(result.bodies.count == 1)
        #expect(result.bodies[0].bodyID.entityIdentity.entryIndex == 321)
        #expect(result.bodies[0].bodyID.entityIdentity.serialNumber == 77)
        #expect(result.bodies[0].bodyID.solidIndex == 2)
        #expect(
            result.bodies[0].transform.origin.x ==
                10 + (2 * SourcePhysicsContract.fixedTimeStepSeconds)
        )
        #expect(result.bodies[0].simulationTick == 8)
        #expect(coordinator.committedBodyIDs == [bodyID])
        #expect(coordinator.committedSimulationTick == 8)

        let commands = try #require(environment.successfulBatches.first?.commands)
        #expect(commands.map(\.sequence) == [40, 41])
        guard case let .createBody(create) = commands[0].payload else {
            Issue.record("first command must create the verified prop body")
            return
        }
        #expect(create.bodyID == bodyID)
        #expect(create.shape == definition.shape)
        #expect(create.massProperties == definition.massProperties)
        guard case let .simulate(simulate) = commands[1].payload else {
            Issue.record("second command must advance one fixed tick")
            return
        }
        #expect(simulate.simulationTick == 8)

        var canonical = SourceCanonicalEntityState.defaults(for: .propPhysics)
        canonical.motion.baseVelocity = SourceVector3(7, 8, 9)
        result.bodies[0].apply(to: &canonical)
        #expect(canonical.transform == result.bodies[0].transform)
        #expect(canonical.motion.linearVelocity == SourceVector3(2, 0, 0))
        #expect(canonical.motion.baseVelocity == SourceVector3(7, 8, 9))
    }

    @Test("unchanged solver state simulates in place and authoritative edits replace")
    func unchangedAndUpdatedBodiesUseMinimalFIFOCommands() throws {
        let environment = RecordingPhysicsEnvironment()
        let sequences = RecordingPhysicsSequenceSource(first: 100)
        let coordinator = SourceCanonicalPropPhysicsCoordinator(
            environment: environment,
            commandSequenceSource: sequences
        )
        let definition = try makeBodyDefinition()
        let initial = makeProp(
            entryIndex: 80,
            serialNumber: 4,
            lifecycle: .spawned,
            origin: SourceVector3(1, 0, 0),
            linearVelocity: SourceVector3(2, 0, 0)
        )
        let first = try coordinator.step(
            inputs: [try SourceCanonicalPropPhysicsInput(
                entity: initial,
                bodyDefinition: definition
            )],
            simulationTick: 1
        )

        let continued = makeProp(
            identity: initial.identity,
            lifecycle: .active,
            transform: first.bodies[0].transform,
            linearVelocity: first.bodies[0].linearVelocity,
            angularVelocity: first.bodies[0].angularVelocity
        )
        let second = try coordinator.step(
            inputs: [try SourceCanonicalPropPhysicsInput(
                entity: continued,
                bodyDefinition: definition
            )],
            simulationTick: 2
        )
        #expect(second.operations.isEmpty)
        #expect(second.commandSequences == [102])
        let secondCommands = environment.successfulBatches[1].commands
        #expect(secondCommands.count == 1)
        guard case .simulate = secondCommands[0].payload else {
            Issue.record("unchanged prop must not be recreated")
            return
        }

        let teleported = makeProp(
            identity: initial.identity,
            lifecycle: .active,
            transform: SourceEntityTransform(
                origin: SourceVector3(90, 3, 4),
                angles: SourceQAngle(pitch: 1, yaw: 2, roll: 3)
            ),
            linearVelocity: SourceVector3(4, 5, 6),
            angularVelocity: SourceVector3(7, 8, 9)
        )
        let third = try coordinator.step(
            inputs: [try SourceCanonicalPropPhysicsInput(
                entity: teleported,
                bodyDefinition: definition
            )],
            simulationTick: 3
        )
        let bodyID = try SourcePhysicsBodyID(
            entityIdentity: initial.identity,
            solidIndex: 0
        )
        #expect(third.operations == [.replace(bodyID)])
        #expect(third.commandSequences == [103, 104, 105])
        let thirdCommands = environment.successfulBatches[2].commands
        #expect(thirdCommands.map(\.sequence) == [103, 104, 105])
        guard
            case let .deleteBody(deletion) = thirdCommands[0].payload,
            case let .createBody(creation) = thirdCommands[1].payload,
            case .simulate = thirdCommands[2].payload
        else {
            Issue.record("replacement must remain delete, create, simulate FIFO")
            return
        }
        #expect(deletion.bodyID == bodyID)
        #expect(creation.bodyID == bodyID)
        #expect(creation.transform == teleported.transform)
        #expect(creation.linearVelocity == SourceVector3(4, 5, 6))
    }

    @Test("entry reuse deletes old generation before creating new generation")
    func generationReuseAndRemovalAreGenerationSafe() throws {
        let environment = RecordingPhysicsEnvironment()
        let sequences = RecordingPhysicsSequenceSource(first: 1)
        let coordinator = SourceCanonicalPropPhysicsCoordinator(
            environment: environment,
            commandSequenceSource: sequences
        )
        let definition = try makeBodyDefinition()
        let oldEntity = makeProp(
            entryIndex: 42,
            serialNumber: 10,
            lifecycle: .active
        )
        _ = try coordinator.step(
            inputs: [try SourceCanonicalPropPhysicsInput(
                entity: oldEntity,
                bodyDefinition: definition
            )],
            simulationTick: 10
        )

        let oldRemoved = makeProp(
            identity: oldEntity.identity,
            lifecycle: .removed
        )
        let newEntity = makeProp(
            entryIndex: 42,
            serialNumber: 11,
            lifecycle: .active,
            origin: SourceVector3(25, 0, 0)
        )
        let replacement = try coordinator.step(
            inputs: [
                try SourceCanonicalPropPhysicsInput(
                    entity: newEntity,
                    bodyDefinition: definition
                ),
                try SourceCanonicalPropPhysicsInput(
                    entity: oldRemoved,
                    bodyDefinition: nil
                )
            ],
            simulationTick: 11
        )
        let oldBodyID = try SourcePhysicsBodyID(
            entityIdentity: oldEntity.identity,
            solidIndex: 0
        )
        let newBodyID = try SourcePhysicsBodyID(
            entityIdentity: newEntity.identity,
            solidIndex: 0
        )
        #expect(oldBodyID.entityIdentity.entryIndex == newBodyID.entityIdentity.entryIndex)
        #expect(oldBodyID.entityIdentity.handle != newBodyID.entityIdentity.handle)
        #expect(replacement.operations == [.delete(oldBodyID), .create(newBodyID)])
        let replacementCommands = environment.successfulBatches[1].commands
        guard
            case let .deleteBody(deletion) = replacementCommands[0].payload,
            case let .createBody(creation) = replacementCommands[1].payload,
            case .simulate = replacementCommands[2].payload
        else {
            Issue.record("old generation must be deleted before new generation creation")
            return
        }
        #expect(deletion.bodyID == oldBodyID)
        #expect(creation.bodyID == newBodyID)
        #expect(coordinator.committedBodyIDs == [newBodyID])

        let pending = makeProp(identity: newEntity.identity, lifecycle: .pendingRemoval)
        let removed = try coordinator.step(
            inputs: [try SourceCanonicalPropPhysicsInput(
                entity: pending,
                bodyDefinition: nil
            )],
            simulationTick: 12
        )
        #expect(removed.operations == [.delete(newBodyID)])
        #expect(removed.bodies.isEmpty)
        #expect(coordinator.committedBodyIDs.isEmpty)
        #expect(environment.bodies.isEmpty)
    }

    @Test("environment failure consumes only host FIFO reservation and rolls back state")
    func environmentFailureRollsBackCoordinatorAndCanRetry() throws {
        let environment = RecordingPhysicsEnvironment()
        let sequences = RecordingPhysicsSequenceSource(first: 10)
        let coordinator = SourceCanonicalPropPhysicsCoordinator(
            environment: environment,
            commandSequenceSource: sequences
        )
        let definition = try makeBodyDefinition()
        let initial = makeProp(
            entryIndex: 17,
            serialNumber: 2,
            lifecycle: .active
        )
        let first = try coordinator.step(
            inputs: [try SourceCanonicalPropPhysicsInput(
                entity: initial,
                bodyDefinition: definition
            )],
            simulationTick: 1
        )
        let bodyID = first.bodies[0].bodyID
        let stateBeforeFailure = environment.bodies
        let changed = makeProp(
            identity: initial.identity,
            lifecycle: .active,
            transform: SourceEntityTransform(
                origin: SourceVector3(100, 0, 0),
                angles: .zero
            )
        )

        environment.failNextExecution = true
        #expect(throws: RecordingPhysicsEnvironment.Failure.injected) {
            _ = try coordinator.step(
                inputs: [try SourceCanonicalPropPhysicsInput(
                    entity: changed,
                    bodyDefinition: definition
                )],
                simulationTick: 2
            )
        }
        #expect(coordinator.committedSimulationTick == 1)
        #expect(coordinator.latestStepSnapshot == first)
        #expect(coordinator.committedBodyIDs == [bodyID])
        #expect(environment.bodies == stateBeforeFailure)

        let retry = try coordinator.step(
            inputs: [try SourceCanonicalPropPhysicsInput(
                entity: changed,
                bodyDefinition: definition
            )],
            simulationTick: 2
        )
        #expect(retry.operations == [.replace(bodyID)])
        #expect(retry.commandSequences == [15, 16, 17])
        #expect(sequences.reservations == [[10, 11], [12, 13, 14], [15, 16, 17]])
        #expect(coordinator.committedSimulationTick == 2)
    }

    @Test("stock remover transient deletes the rigid body without deleting Entity")
    func stockRemoverTransientDisablesBodyUntilDeferredRemoval() throws {
        let environment = RecordingPhysicsEnvironment()
        let sequences = RecordingPhysicsSequenceSource(first: 300)
        let coordinator = SourceCanonicalPropPhysicsCoordinator(
            environment: environment,
            commandSequenceSource: sequences
        )
        let definition = try makeBodyDefinition()
        let live = makeProp(
            entryIndex: 73,
            serialNumber: 8,
            lifecycle: .active
        )
        let created = try coordinator.step(
            inputs: [try SourceCanonicalPropPhysicsInput(
                entity: live,
                bodyDefinition: definition
            )],
            simulationTick: 1
        )
        let bodyID = try #require(created.bodies.first?.bodyID)

        let disabled = makeProp(
            identity: live.identity,
            lifecycle: .active,
            moveType: .none,
            isNotSolid: true
        )
        let removedFromSolver = try coordinator.step(
            inputs: [try SourceCanonicalPropPhysicsInput(
                entity: disabled,
                bodyDefinition: nil
            )],
            simulationTick: 2
        )

        #expect(removedFromSolver.operations == [.delete(bodyID)])
        #expect(removedFromSolver.bodies.isEmpty)
        #expect(environment.bodies.isEmpty)
        #expect(coordinator.committedBodyIDs.isEmpty)
        #expect(
            throws: SourceCanonicalPropPhysicsCoordinatorError
                .bodyDefinitionForDisabledEntity(live.identity)
        ) {
            _ = try SourceCanonicalPropPhysicsInput(
                entity: disabled,
                bodyDefinition: definition
            )
        }
    }

    @Test("invalid inputs and invalid environment output never commit")
    func validationIsFailClosedAndTransactional() throws {
        let definition = try makeBodyDefinition()
        let active = makeProp(
            entryIndex: 9,
            serialNumber: 3,
            lifecycle: .active
        )
        #expect(
            throws: SourceCanonicalPropPhysicsCoordinatorError
                .missingBodyDefinition(active.identity)
        ) {
            _ = try SourceCanonicalPropPhysicsInput(
                entity: active,
                bodyDefinition: nil
            )
        }

        let created = makeProp(
            identity: active.identity,
            lifecycle: .created
        )
        #expect(
            throws: SourceCanonicalPropPhysicsCoordinatorError
                .bodyDefinitionForInactiveEntity(
                    identity: active.identity,
                    lifecycle: .created
                )
        ) {
            _ = try SourceCanonicalPropPhysicsInput(
                entity: created,
                bodyDefinition: definition
            )
        }

        let environment = MissingBodyPhysicsEnvironment()
        let sequences = RecordingPhysicsSequenceSource(first: 700)
        let coordinator = SourceCanonicalPropPhysicsCoordinator(
            environment: environment,
            commandSequenceSource: sequences
        )
        let bodyID = try SourcePhysicsBodyID(
            entityIdentity: active.identity,
            solidIndex: 0
        )
        #expect(
            throws: SourceCanonicalPropPhysicsCoordinatorError
                .environmentMissingBody(bodyID)
        ) {
            _ = try coordinator.step(
                inputs: [try SourceCanonicalPropPhysicsInput(
                    entity: active,
                    bodyDefinition: definition
                )],
                simulationTick: 20
            )
        }
        #expect(coordinator.committedSimulationTick == nil)
        #expect(coordinator.latestStepSnapshot == nil)
        #expect(coordinator.committedBodyIDs.isEmpty)
    }

    private func makeProp(
        entryIndex: Int,
        serialNumber: Int,
        lifecycle: SourceCanonicalEntityLifecycle,
        origin: SourceVector3 = .zero,
        linearVelocity: SourceVector3 = .zero
    ) -> SourceCanonicalEntitySnapshot {
        makeProp(
            identity: SourceCanonicalEntityIdentity(
                handle: SourceBaseHandle(
                    entryIndex: entryIndex,
                    serialNumber: serialNumber
                )
            ),
            lifecycle: lifecycle,
            transform: SourceEntityTransform(origin: origin, angles: .zero),
            linearVelocity: linearVelocity
        )
    }

    private func makeProp(
        identity: SourceCanonicalEntityIdentity,
        lifecycle: SourceCanonicalEntityLifecycle,
        transform: SourceEntityTransform = .identity,
        linearVelocity: SourceVector3 = .zero,
        angularVelocity: SourceVector3 = .zero,
        moveType: SourceMoveType = .vPhysics,
        isNotSolid: Bool = false
    ) -> SourceCanonicalEntitySnapshot {
        var motion = SourceEntityMotionState()
        motion.linearVelocity = linearVelocity
        motion.angularVelocity = angularVelocity
        return SourceCanonicalEntitySnapshot(
            identity: identity,
            kind: .propPhysics,
            className: SourceCanonicalEntityKind.propPhysics.className,
            transform: transform,
            motion: motion,
            model: SourceEntityModelReference("models/props_c17/oildrum001.mdl"),
            isNotSolid: isNotSolid,
            solidType: .vPhysics,
            moveType: moveType,
            lifecycle: lifecycle,
            isNetworkable: true,
            revision: 1
        )
    }

    private func makeBodyDefinition(
        solidIndex: Int = 0
    ) throws -> SourceCanonicalPropPhysicsBodyDefinition {
        try SourceCanonicalPropPhysicsBodyDefinition(
            solidIndex: solidIndex,
            shape: makeTetrahedronShape(),
            massProperties: SourcePhysicsMassProperties(
                massKilograms: 12,
                principalInertia: SourceVector3(2, 3, 4)
            ),
            damping: .zero,
            motionType: .dynamicBody,
            materialIndex: 7,
            isGravityEnabled: true,
            isCollisionEnabled: true,
            startsAwake: true
        )
    }

    private func makeTetrahedronShape() throws -> SourcePhysicsShapeSnapshot {
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
            )
        ]
        let part = try SourcePhysicsMeshPartSnapshot(
            vertices: [
                SourceVector3(0, 0, 0),
                SourceVector3(1, 0, 0),
                SourceVector3(0, 1, 0),
                SourceVector3(0, 0, 1)
            ],
            triangles: triangles
        )
        return try SourcePhysicsShapeSnapshot(
            topology: .convexParts,
            parts: [part]
        )
    }
}

private final class RecordingPhysicsSequenceSource:
    SourceCanonicalPropPhysicsCommandSequenceSource
{
    private var next: UInt64
    private(set) var reservations: [[UInt64]] = []

    init(first: UInt64) {
        next = first
    }

    func reservePhysicsCommandSequences(count: Int) throws -> [UInt64] {
        let result = (0 ..< count).map { next + UInt64($0) }
        next += UInt64(count)
        reservations.append(result)
        return result
    }
}

private final class RecordingPhysicsEnvironment: SourcePhysicsEnvironment {
    enum Failure: Error, Equatable {
        case injected
        case duplicateBody(SourcePhysicsBodyID)
        case missingBody(SourcePhysicsBodyID)
    }

    private(set) var successfulBatches: [SourcePhysicsCommandBatch] = []
    private(set) var bodies: [SourcePhysicsBodyID: SourcePhysicsBodySnapshot] = [:]
    var failNextExecution = false
    private var simulationTick: UInt64 = 0

    func execute(
        _ batch: SourcePhysicsCommandBatch
    ) throws -> SourcePhysicsEnvironmentSnapshot {
        if failNextExecution {
            failNextExecution = false
            throw Failure.injected
        }

        var candidateBodies = bodies
        var candidateTick = simulationTick
        for command in batch.commands {
            switch command.payload {
            case let .createBody(creation):
                guard candidateBodies[creation.bodyID] == nil else {
                    throw Failure.duplicateBody(creation.bodyID)
                }
                candidateBodies[creation.bodyID] = try makeBody(
                    creation: creation,
                    transform: creation.transform,
                    linearVelocity: creation.linearVelocity,
                    angularVelocity: creation.angularVelocity,
                    isSleeping: !creation.startsAwake,
                    simulationTick: candidateTick
                )
            case let .deleteBody(deletion):
                guard candidateBodies.removeValue(forKey: deletion.bodyID) != nil else {
                    throw Failure.missingBody(deletion.bodyID)
                }
            case let .mutateBody(mutation):
                guard let body = candidateBodies[mutation.bodyID] else {
                    throw Failure.missingBody(mutation.bodyID)
                }
                candidateBodies[mutation.bodyID] = try mutatedBody(
                    body,
                    by: mutation.mutation
                )
            case let .simulate(simulate):
                candidateTick = simulate.simulationTick
                for (bodyID, body) in candidateBodies {
                    let delta = body.linearVelocity *
                        SourcePhysicsContract.fixedTimeStepSeconds
                    let transform = SourceEntityTransform(
                        origin: body.transform.origin + delta,
                        angles: body.transform.angles
                    )
                    candidateBodies[bodyID] = try makeBody(
                        body: body,
                        transform: transform,
                        simulationTick: candidateTick
                    )
                }
            case .query:
                break
            }
        }

        let snapshot = try SourcePhysicsEnvironmentSnapshot(
            simulationTick: candidateTick,
            lastProcessedCommandSequence: batch.commands.last?.sequence,
            bodies: candidateBodies.values.sorted(by: bodyPrecedes),
            queryResults: []
        )
        bodies = candidateBodies
        simulationTick = candidateTick
        successfulBatches.append(batch)
        return snapshot
    }

    private func makeBody(
        creation: SourcePhysicsBodyCreationCommand,
        transform: SourceEntityTransform,
        linearVelocity: SourceVector3,
        angularVelocity: SourceVector3,
        isSleeping: Bool,
        simulationTick: UInt64
    ) throws -> SourcePhysicsBodySnapshot {
        try SourcePhysicsBodySnapshot(
            bodyID: creation.bodyID,
            shape: creation.shape,
            massProperties: creation.massProperties,
            transform: transform,
            linearVelocity: linearVelocity,
            angularVelocity: angularVelocity,
            damping: creation.damping,
            motionType: creation.motionType,
            materialIndex: creation.materialIndex,
            isGravityEnabled: creation.isGravityEnabled,
            isCollisionEnabled: creation.isCollisionEnabled,
            isSleeping: isSleeping,
            simulationTick: simulationTick
        )
    }

    private func makeBody(
        body: SourcePhysicsBodySnapshot,
        transform: SourceEntityTransform,
        simulationTick: UInt64
    ) throws -> SourcePhysicsBodySnapshot {
        try SourcePhysicsBodySnapshot(
            bodyID: body.bodyID,
            shape: body.shape,
            massProperties: body.massProperties,
            transform: transform,
            linearVelocity: body.linearVelocity,
            angularVelocity: body.angularVelocity,
            damping: body.damping,
            motionType: body.motionType,
            materialIndex: body.materialIndex,
            isMotionEnabled: body.isMotionEnabled,
            isGravityEnabled: body.isGravityEnabled,
            isCollisionEnabled: body.isCollisionEnabled,
            isSleeping: body.isSleeping,
            simulationTick: simulationTick
        )
    }

    private func mutatedBody(
        _ body: SourcePhysicsBodySnapshot,
        by mutation: SourcePhysicsBodyMutation
    ) throws -> SourcePhysicsBodySnapshot {
        var linearVelocity = body.linearVelocity
        var angularVelocity = body.angularVelocity
        var damping = body.damping
        var massProperties = body.massProperties
        var isMotionEnabled = body.isMotionEnabled
        var isGravityEnabled = body.isGravityEnabled
        var isCollisionEnabled = body.isCollisionEnabled
        var isSleeping = body.isSleeping
        switch mutation {
        case .wake:
            isSleeping = false
        case .sleep:
            isSleeping = true
            linearVelocity = .zero
            angularVelocity = .zero
        case let .setMotionEnabled(enabled):
            isMotionEnabled = enabled
            isSleeping = !enabled
            if !enabled {
                linearVelocity = .zero
                angularVelocity = .zero
            }
        case let .setGravityEnabled(enabled):
            isGravityEnabled = enabled
        case let .setCollisionEnabled(enabled):
            isCollisionEnabled = enabled
        case let .setLinearVelocity(value):
            linearVelocity = value
        case let .addLinearVelocity(value):
            linearVelocity += value
        case let .setAngularVelocity(value):
            angularVelocity = value
        case let .addAngularVelocity(value):
            angularVelocity += value
        case .applyCenterForce, .applyForceOffset:
            break
        case let .applyCenterImpulse(value):
            linearVelocity += value / body.massProperties.massKilograms
        case let .applyTorqueCenter(value):
            angularVelocity += inverseInertiaMultiply(
                body: body,
                worldVector: value
            )
        case let .setDamping(linear, angular):
            damping = try SourcePhysicsDamping(
                linear: linear,
                angular: angular
            )
        case let .setMassKilograms(massKilograms):
            let scale = massKilograms / body.massProperties.massKilograms
            massProperties = try SourcePhysicsMassProperties(
                massKilograms: massKilograms,
                principalInertia: body.massProperties.principalInertia * scale
            )
        }
        return try SourcePhysicsBodySnapshot(
            bodyID: body.bodyID,
            shape: body.shape,
            massProperties: massProperties,
            transform: body.transform,
            linearVelocity: linearVelocity,
            angularVelocity: angularVelocity,
            damping: damping,
            motionType: body.motionType,
            materialIndex: body.materialIndex,
            isMotionEnabled: isMotionEnabled,
            isGravityEnabled: isGravityEnabled,
            isCollisionEnabled: isCollisionEnabled,
            isSleeping: isSleeping,
            simulationTick: body.simulationTick
        )
    }

    private func inverseInertiaMultiply(
        body: SourcePhysicsBodySnapshot,
        worldVector: SourceVector3
    ) -> SourceVector3 {
        let basis = body.transform.angles.sourceBasis
        let localX = basis.forward
        let localY = -basis.right
        let localZ = basis.up
        let local = SourceVector3(
            worldVector.dot(localX),
            worldVector.dot(localY),
            worldVector.dot(localZ)
        )
        let inertia = body.massProperties.principalInertia
        let scaled = SourceVector3(
            local.x / inertia.x,
            local.y / inertia.y,
            local.z / inertia.z
        )
        return localX * scaled.x + localY * scaled.y + localZ * scaled.z
    }

    private func bodyPrecedes(
        _ lhs: SourcePhysicsBodySnapshot,
        _ rhs: SourcePhysicsBodySnapshot
    ) -> Bool {
        let lhsHandle = lhs.bodyID.entityIdentity.handle.rawValue
        let rhsHandle = rhs.bodyID.entityIdentity.handle.rawValue
        if lhsHandle != rhsHandle { return lhsHandle < rhsHandle }
        return lhs.bodyID.solidIndex < rhs.bodyID.solidIndex
    }
}

private final class MissingBodyPhysicsEnvironment: SourcePhysicsEnvironment {
    func execute(
        _ batch: SourcePhysicsCommandBatch
    ) throws -> SourcePhysicsEnvironmentSnapshot {
        let simulationTick = batch.commands.compactMap { command -> UInt64? in
            guard case let .simulate(simulate) = command.payload else { return nil }
            return simulate.simulationTick
        }.last ?? 0
        return try SourcePhysicsEnvironmentSnapshot(
            simulationTick: simulationTick,
            lastProcessedCommandSequence: batch.commands.last?.sequence,
            bodies: [],
            queryResults: []
        )
    }
}
