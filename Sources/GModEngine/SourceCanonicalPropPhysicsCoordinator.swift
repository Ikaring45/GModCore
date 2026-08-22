/// Supplies command identities from the host's existing global FIFO.
///
/// The prop coordinator deliberately does not allocate a second sequence
/// domain. A SERVER-session integration must inject the same reservation
/// source used by console, net, and canonical-entity delivery.
public protocol SourceCanonicalPropPhysicsCommandSequenceSource: AnyObject {
    func reservePhysicsCommandSequences(count: Int) throws -> [UInt64]
}

/// The only body commands that may wait for the next authoritative fixed
/// step. Simulation and queries remain coordinator-owned barriers.
public enum SourceCanonicalQueuedPhysicsBodyCommand: Equatable, Sendable {
    case create(SourcePhysicsBodyCreationCommand)
    case mutate(SourcePhysicsBodyMutationCommand)

    var payload: SourcePhysicsCommandPayload {
        switch self {
        case let .create(command): .createBody(command)
        case let .mutate(command): .mutateBody(command)
        }
    }
}

/// Transactional pending-command seam implemented by the same host object
/// that owns the global net/console/entity/physics sequence clock.
public protocol SourceCanonicalPropPhysicsMutationCommandQueue: AnyObject {
    @discardableResult
    func enqueueCanonicalPhysicsBodyCommands(
        _ commands: [SourceCanonicalQueuedPhysicsBodyCommand]
    ) throws -> [SourcePhysicsCommand]

    func preparePendingCanonicalPhysicsBodyCommands()
        -> [SourcePhysicsCommand]

    /// Removes exactly the prepared prefix. This is called only after the
    /// environment and coordinator validation succeed; throws retain it.
    func commitPendingCanonicalPhysicsBodyCommands(
        _ commands: [SourcePhysicsCommand]
    )
}

/// Verified physical data for one canonical `prop_physics` body.
///
/// Shape, mass, and principal inertia have already passed the validation in
/// `SourcePhysicsEnvironment.swift`. Every remaining behavior-affecting value
/// is explicit; this type has no guessed model bounds, density, or material.
public struct SourceCanonicalPropPhysicsBodyDefinition: Equatable, Sendable {
    public let solidIndex: Int
    public let shape: SourcePhysicsShapeSnapshot
    public let massProperties: SourcePhysicsMassProperties
    public let damping: SourcePhysicsDamping
    public let motionType: SourcePhysicsMotionType
    public let materialIndex: Int
    public let isGravityEnabled: Bool
    public let isCollisionEnabled: Bool
    public let startsAwake: Bool

    public init(
        solidIndex: Int,
        shape: SourcePhysicsShapeSnapshot,
        massProperties: SourcePhysicsMassProperties,
        damping: SourcePhysicsDamping,
        motionType: SourcePhysicsMotionType,
        materialIndex: Int,
        isGravityEnabled: Bool,
        isCollisionEnabled: Bool,
        startsAwake: Bool
    ) throws {
        guard solidIndex >= 0 else {
            throw SourcePhysicsContractError.negativeSolidIndex(solidIndex)
        }
        guard materialIndex >= 0 else {
            throw SourcePhysicsContractError.negativeMaterialIndex(
                field: "materialIndex",
                value: materialIndex
            )
        }
        self.solidIndex = solidIndex
        self.shape = shape
        self.massProperties = massProperties
        self.damping = damping
        self.motionType = motionType
        self.materialIndex = materialIndex
        self.isGravityEnabled = isGravityEnabled
        self.isCollisionEnabled = isCollisionEnabled
        self.startsAwake = startsAwake
    }
}

public enum SourceCanonicalPropPhysicsCoordinatorError: Error, Equatable, Sendable {
    case wrongEntityKind(
        identity: SourceCanonicalEntityIdentity,
        received: SourceCanonicalEntityKind
    )
    case wrongClassName(identity: SourceCanonicalEntityIdentity, received: String)
    case entityIsNotNetworkable(SourceCanonicalEntityIdentity)
    case missingModel(SourceCanonicalEntityIdentity)
    case wrongSolidType(
        identity: SourceCanonicalEntityIdentity,
        received: SourceEntitySolidType
    )
    case wrongMoveType(
        identity: SourceCanonicalEntityIdentity,
        received: SourceMoveType
    )
    case missingBodyDefinition(SourceCanonicalEntityIdentity)
    case bodyDefinitionForDisabledEntity(SourceCanonicalEntityIdentity)
    case bodyDefinitionForInactiveEntity(
        identity: SourceCanonicalEntityIdentity,
        lifecycle: SourceCanonicalEntityLifecycle
    )
    case duplicateEntityHandle(UInt32)
    case multipleLiveGenerations(entryIndex: Int)
    case simulationTickNotIncreasing(previous: UInt64, current: UInt64)
    case wrongReservedSequenceCount(expected: Int, received: Int)
    case environmentSimulationTickMismatch(expected: UInt64, received: UInt64)
    case environmentCommandSequenceMismatch(expected: UInt64, received: UInt64?)
    case pendingCommandSequenceNotBeforeStep(
        pending: UInt64,
        reserved: UInt64
    )
    case unsupportedPendingCommand(UInt64)
    case pendingCreationMismatch(SourcePhysicsBodyID)
    case pendingMutationBodyUnavailable(SourcePhysicsBodyID)
    case environmentMissingBody(SourcePhysicsBodyID)
    case environmentRetainedDeletedBody(SourcePhysicsBodyID)
    case environmentBodyConfigurationMismatch(SourcePhysicsBodyID)
    case environmentBodyTickMismatch(
        bodyID: SourcePhysicsBodyID,
        expected: UInt64,
        received: UInt64
    )
}

/// One canonical entity plus its verified physical definition.
///
/// Created, pending-removal, and removed entities must not carry a body.
/// Spawned and active props normally carry real extracted physical data. The
/// stock remover's exact transient state (`FSOLID_NOT_SOLID` plus
/// `MOVETYPE_NONE`) deliberately carries no live solver body while the
/// canonical Entity remains available to its delayed removal timer. This is
/// still fail-closed: no other move type and no unattested body is accepted.
public struct SourceCanonicalPropPhysicsInput: Equatable, Sendable {
    public let entity: SourceCanonicalEntitySnapshot
    public let bodyDefinition: SourceCanonicalPropPhysicsBodyDefinition?

    public init(
        entity: SourceCanonicalEntitySnapshot,
        bodyDefinition: SourceCanonicalPropPhysicsBodyDefinition?
    ) throws {
        guard entity.kind == .propPhysics else {
            throw SourceCanonicalPropPhysicsCoordinatorError.wrongEntityKind(
                identity: entity.identity,
                received: entity.kind
            )
        }
        guard entity.className == SourceCanonicalEntityKind.propPhysics.className else {
            throw SourceCanonicalPropPhysicsCoordinatorError.wrongClassName(
                identity: entity.identity,
                received: entity.className
            )
        }
        guard entity.isNetworkable else {
            throw SourceCanonicalPropPhysicsCoordinatorError
                .entityIsNotNetworkable(entity.identity)
        }

        switch entity.lifecycle {
        case .spawned, .active:
            guard entity.model != nil else {
                throw SourceCanonicalPropPhysicsCoordinatorError
                    .missingModel(entity.identity)
            }
            guard entity.solidType == .vPhysics else {
                throw SourceCanonicalPropPhysicsCoordinatorError.wrongSolidType(
                    identity: entity.identity,
                    received: entity.solidType
                )
            }
            if entity.moveType == .none, entity.isNotSolid {
                guard bodyDefinition == nil else {
                    throw SourceCanonicalPropPhysicsCoordinatorError
                        .bodyDefinitionForDisabledEntity(entity.identity)
                }
            } else if entity.moveType == .vPhysics {
                guard bodyDefinition != nil else {
                    throw SourceCanonicalPropPhysicsCoordinatorError
                        .missingBodyDefinition(entity.identity)
                }
            } else {
                throw SourceCanonicalPropPhysicsCoordinatorError.wrongMoveType(
                    identity: entity.identity,
                    received: entity.moveType
                )
            }
        case .created, .pendingRemoval, .removed:
            guard bodyDefinition == nil else {
                throw SourceCanonicalPropPhysicsCoordinatorError
                    .bodyDefinitionForInactiveEntity(
                        identity: entity.identity,
                        lifecycle: entity.lifecycle
                    )
            }
        }

        self.entity = entity
        self.bodyDefinition = bodyDefinition
    }
}

/// Semantic reconciliation performed during a successful fixed physics step.
public enum SourceCanonicalPropPhysicsOperation: Equatable, Sendable {
    case create(SourcePhysicsBodyID)
    /// The backend-neutral environment currently has immutable creation data.
    /// An authoritative prop update is therefore one FIFO delete/create pair
    /// for the same complete body identity, executed atomically in one batch.
    case replace(SourcePhysicsBodyID)
    case delete(SourcePhysicsBodyID)
}

/// Solver-authored state to commit back into the canonical entity store.
public struct SourceCanonicalPropPhysicsMotionSnapshot: Equatable, Sendable {
    public let bodyID: SourcePhysicsBodyID
    public let massProperties: SourcePhysicsMassProperties
    public let transform: SourceEntityTransform
    public let linearVelocity: SourceVector3
    public let angularVelocity: SourceVector3
    public let damping: SourcePhysicsDamping
    public let isMotionEnabled: Bool
    public let isGravityEnabled: Bool
    public let isCollisionEnabled: Bool
    public let isSleeping: Bool
    public let simulationTick: UInt64

    public init(body: SourcePhysicsBodySnapshot) {
        bodyID = body.bodyID
        massProperties = body.massProperties
        transform = body.transform
        linearVelocity = body.linearVelocity
        angularVelocity = body.angularVelocity
        damping = body.damping
        isMotionEnabled = body.isMotionEnabled
        isGravityEnabled = body.isGravityEnabled
        isCollisionEnabled = body.isCollisionEnabled
        isSleeping = body.isSleeping
        simulationTick = body.simulationTick
    }

    /// Applies only values authored by the rigid-body environment. Unrelated
    /// canonical movement fields remain owned by their existing subsystem.
    public func apply(to state: inout SourceCanonicalEntityState) {
        state.transform = transform
        state.motion.linearVelocity = linearVelocity
        state.motion.angularVelocity = angularVelocity
    }
}

/// Immutable result of one committed 0.015-second reconciliation/simulation.
public struct SourceCanonicalPropPhysicsStepSnapshot: Equatable, Sendable {
    public let simulationTick: UInt64
    public let commandSequences: [UInt64]
    public let operations: [SourceCanonicalPropPhysicsOperation]
    public let bodies: [SourceCanonicalPropPhysicsMotionSnapshot]

    public var fixedTimeStepSeconds: Float {
        SourcePhysicsContract.fixedTimeStepSeconds
    }
}

/// Reconciles canonical SERVER prop state with an injected physics backend.
///
/// This class owns no solver, model validation, PHY decoding, realm mirror, or
/// sequence clock. Call it from one authoritative SERVER lane. Every call
/// builds and validates a complete candidate batch before touching the
/// environment, then commits coordinator state only after a valid environment
/// snapshot is returned. `SourcePhysicsEnvironment` is itself required to
/// execute a batch atomically or throw.
public final class SourceCanonicalPropPhysicsCoordinator {
    private struct DesiredBody: Equatable {
        let creation: SourcePhysicsBodyCreationCommand
        let definition: SourceCanonicalPropPhysicsBodyDefinition
    }

    private struct CommittedBody {
        let definition: SourceCanonicalPropPhysicsBodyDefinition
        let body: SourcePhysicsBodySnapshot
    }

    private enum ExpectedMassState {
        case exact(SourcePhysicsMassProperties)
        /// SetMass guarantees mass at the public boundary. The backend owns
        /// its inertia policy until the resulting body snapshot is committed.
        case backendAuthoredInertia(massKilograms: Float)
    }

    private let environment: SourcePhysicsEnvironment
    private let commandSequenceSource: SourceCanonicalPropPhysicsCommandSequenceSource
    private var committedBodies: [SourcePhysicsBodyID: CommittedBody] = [:]
    private var committedSimulationTickStorage: UInt64?

    public private(set) var latestStepSnapshot: SourceCanonicalPropPhysicsStepSnapshot?

    public init(
        environment: SourcePhysicsEnvironment,
        commandSequenceSource: SourceCanonicalPropPhysicsCommandSequenceSource
    ) {
        self.environment = environment
        self.commandSequenceSource = commandSequenceSource
    }

    public var committedSimulationTick: UInt64? {
        committedSimulationTickStorage
    }

    public var committedBodyIDs: [SourcePhysicsBodyID] {
        committedBodies.keys.sorted(by: Self.bodyIDPrecedes)
    }

    /// Performs exactly one Source fixed step.
    ///
    /// Missing entries are deletions. Thus a current canonical prop projection
    /// can be passed directly, while an old EHANDLE generation is removed
    /// before a newly reused entry is created. The caller must feed returned
    /// motion values back to canonical state before the following step; an
    /// intentional canonical pose/velocity change is reconciled as a replace.
    @discardableResult
    public func step(
        inputs: [SourceCanonicalPropPhysicsInput],
        simulationTick: UInt64
    ) throws -> SourceCanonicalPropPhysicsStepSnapshot {
        if
            let previous = committedSimulationTickStorage,
            simulationTick <= previous
        {
            throw SourceCanonicalPropPhysicsCoordinatorError
                .simulationTickNotIncreasing(
                    previous: previous,
                    current: simulationTick
                )
        }

        let desiredBodies = try makeDesiredBodies(inputs: inputs)
        let plan = makePlan(desiredBodies: desiredBodies)
        let mutationQueue = commandSequenceSource as?
            any SourceCanonicalPropPhysicsMutationCommandQueue
        let pendingCommands = mutationQueue?
            .preparePendingCanonicalPhysicsBodyCommands() ?? []
        let pendingCreationIDs = try validatePendingCommands(
            pendingCommands,
            desiredBodies: desiredBodies
        )
        var deletionSet = Set(plan.deletions)
        for bodyID in pendingCreationIDs where desiredBodies[bodyID] == nil {
            deletionSet.insert(bodyID)
        }
        let deletions = deletionSet.sorted(by: Self.bodyIDPrecedes)
        let pendingCreationSet = Set(pendingCreationIDs)
        let creations = plan.creations.filter {
            !pendingCreationSet.contains($0)
        }
        let commandCount = deletions.count + creations.count + 1
        let sequences = try commandSequenceSource
            .reservePhysicsCommandSequences(count: commandCount)
        guard sequences.count == commandCount else {
            throw SourceCanonicalPropPhysicsCoordinatorError
                .wrongReservedSequenceCount(
                    expected: commandCount,
                    received: sequences.count
                )
        }

        var commandIndex = 0
        if let pendingSequence = pendingCommands.last?.sequence,
           let reservedSequence = sequences.first,
           pendingSequence >= reservedSequence {
            throw SourceCanonicalPropPhysicsCoordinatorError
                .pendingCommandSequenceNotBeforeStep(
                    pending: pendingSequence,
                    reserved: reservedSequence
                )
        }

        var commands = pendingCommands
        commands.reserveCapacity(pendingCommands.count + commandCount)
        for bodyID in deletions {
            commands.append(SourcePhysicsCommand(
                sequence: sequences[commandIndex],
                payload: .deleteBody(SourcePhysicsBodyDeletionCommand(bodyID: bodyID))
            ))
            commandIndex += 1
        }
        for bodyID in creations {
            guard let desiredBody = desiredBodies[bodyID] else {
                preconditionFailure("prop physics plan lost a desired body")
            }
            commands.append(SourcePhysicsCommand(
                sequence: sequences[commandIndex],
                payload: .createBody(desiredBody.creation)
            ))
            commandIndex += 1
        }
        commands.append(SourcePhysicsCommand(
            sequence: sequences[commandIndex],
            payload: .simulate(SourcePhysicsSimulateCommand(
                simulationTick: simulationTick
            ))
        ))

        let batch = try SourcePhysicsCommandBatch(commands: commands)
        let environmentSnapshot = try environment.execute(batch)
        let candidateBodies = try validate(
            environmentSnapshot: environmentSnapshot,
            desiredBodies: desiredBodies,
            expectedMassStates: expectedMassStates(after: commands),
            deletedBodyIDs: deletions,
            finalCommandSequence: sequences[commandIndex],
            simulationTick: simulationTick
        )

        let reportedPendingCreations = pendingCreationIDs.filter {
            desiredBodies[$0] != nil
        }
        let operations = makeOperations(
            deletedBodyIDs: deletions,
            createdBodyIDs: (creations + reportedPendingCreations)
                .sorted(by: Self.bodyIDPrecedes),
            desiredBodies: desiredBodies
        )
        let motionSnapshots = candidateBodies.values
            .map(\.body)
            .sorted { Self.bodyIDPrecedes($0.bodyID, $1.bodyID) }
            .map(SourceCanonicalPropPhysicsMotionSnapshot.init(body:))
        let result = SourceCanonicalPropPhysicsStepSnapshot(
            simulationTick: simulationTick,
            commandSequences: commands.map(\.sequence),
            operations: operations,
            bodies: motionSnapshots
        )

        mutationQueue?.commitPendingCanonicalPhysicsBodyCommands(
            pendingCommands
        )
        committedBodies = candidateBodies
        committedSimulationTickStorage = simulationTick
        latestStepSnapshot = result
        return result
    }

    private func makeDesiredBodies(
        inputs: [SourceCanonicalPropPhysicsInput]
    ) throws -> [SourcePhysicsBodyID: DesiredBody] {
        var seenHandles = Set<UInt32>()
        var liveEntries = Set<Int>()
        var desired: [SourcePhysicsBodyID: DesiredBody] = [:]
        desired.reserveCapacity(inputs.count)

        for input in inputs {
            let identity = input.entity.identity
            guard seenHandles.insert(identity.handle.rawValue).inserted else {
                throw SourceCanonicalPropPhysicsCoordinatorError
                    .duplicateEntityHandle(identity.handle.rawValue)
            }
            guard let definition = input.bodyDefinition else { continue }
            guard liveEntries.insert(identity.entryIndex).inserted else {
                throw SourceCanonicalPropPhysicsCoordinatorError
                    .multipleLiveGenerations(entryIndex: identity.entryIndex)
            }

            let bodyID = try SourcePhysicsBodyID(
                entityIdentity: identity,
                solidIndex: definition.solidIndex
            )
            let creation = try SourcePhysicsBodyCreationCommand(
                bodyID: bodyID,
                shape: definition.shape,
                massProperties: definition.massProperties,
                transform: input.entity.transform,
                linearVelocity: input.entity.motion.linearVelocity,
                angularVelocity: input.entity.motion.angularVelocity,
                damping: definition.damping,
                motionType: definition.motionType,
                materialIndex: definition.materialIndex,
                isGravityEnabled: definition.isGravityEnabled,
                isCollisionEnabled: definition.isCollisionEnabled,
                startsAwake: definition.startsAwake
            )
            desired[bodyID] = DesiredBody(
                creation: creation,
                definition: definition
            )
        }
        return desired
    }

    private func makePlan(
        desiredBodies: [SourcePhysicsBodyID: DesiredBody]
    ) -> (deletions: [SourcePhysicsBodyID], creations: [SourcePhysicsBodyID]) {
        var deletions = Set<SourcePhysicsBodyID>()
        var creations = Set<SourcePhysicsBodyID>()

        for bodyID in committedBodies.keys where desiredBodies[bodyID] == nil {
            deletions.insert(bodyID)
        }
        for (bodyID, desired) in desiredBodies {
            guard let committed = committedBodies[bodyID] else {
                creations.insert(bodyID)
                continue
            }
            if requiresReplacement(committed: committed, desired: desired) {
                deletions.insert(bodyID)
                creations.insert(bodyID)
            }
        }
        return (
            deletions.sorted(by: Self.bodyIDPrecedes),
            creations.sorted(by: Self.bodyIDPrecedes)
        )
    }

    private func validatePendingCommands(
        _ commands: [SourcePhysicsCommand],
        desiredBodies: [SourcePhysicsBodyID: DesiredBody]
    ) throws -> [SourcePhysicsBodyID] {
        var liveBodyIDs = Set(committedBodies.keys)
        var createdBodyIDs: [SourcePhysicsBodyID] = []
        for command in commands {
            switch command.payload {
            case let .createBody(creation):
                guard !liveBodyIDs.contains(creation.bodyID) else {
                    throw SourceCanonicalPropPhysicsCoordinatorError
                        .pendingCreationMismatch(creation.bodyID)
                }
                if let desired = desiredBodies[creation.bodyID],
                   desired.creation != creation {
                    throw SourceCanonicalPropPhysicsCoordinatorError
                        .pendingCreationMismatch(creation.bodyID)
                }
                liveBodyIDs.insert(creation.bodyID)
                createdBodyIDs.append(creation.bodyID)
            case let .mutateBody(mutation):
                guard liveBodyIDs.contains(mutation.bodyID) else {
                    throw SourceCanonicalPropPhysicsCoordinatorError
                        .pendingMutationBodyUnavailable(mutation.bodyID)
                }
            case .deleteBody, .simulate, .query:
                throw SourceCanonicalPropPhysicsCoordinatorError
                    .unsupportedPendingCommand(command.sequence)
            }
        }
        return createdBodyIDs
    }

    private func requiresReplacement(
        committed: CommittedBody,
        desired: DesiredBody
    ) -> Bool {
        committed.definition != desired.definition ||
            committed.body.transform != desired.creation.transform ||
            committed.body.linearVelocity != desired.creation.linearVelocity ||
            committed.body.angularVelocity != desired.creation.angularVelocity
    }

    private func validate(
        environmentSnapshot: SourcePhysicsEnvironmentSnapshot,
        desiredBodies: [SourcePhysicsBodyID: DesiredBody],
        expectedMassStates: [SourcePhysicsBodyID: ExpectedMassState],
        deletedBodyIDs: [SourcePhysicsBodyID],
        finalCommandSequence: UInt64,
        simulationTick: UInt64
    ) throws -> [SourcePhysicsBodyID: CommittedBody] {
        guard environmentSnapshot.simulationTick == simulationTick else {
            throw SourceCanonicalPropPhysicsCoordinatorError
                .environmentSimulationTickMismatch(
                    expected: simulationTick,
                    received: environmentSnapshot.simulationTick
                )
        }
        guard
            environmentSnapshot.lastProcessedCommandSequence == finalCommandSequence
        else {
            throw SourceCanonicalPropPhysicsCoordinatorError
                .environmentCommandSequenceMismatch(
                    expected: finalCommandSequence,
                    received: environmentSnapshot.lastProcessedCommandSequence
                )
        }

        let returnedBodies = Dictionary(
            uniqueKeysWithValues: environmentSnapshot.bodies.map { ($0.bodyID, $0) }
        )
        for bodyID in deletedBodyIDs where desiredBodies[bodyID] == nil {
            guard returnedBodies[bodyID] == nil else {
                throw SourceCanonicalPropPhysicsCoordinatorError
                    .environmentRetainedDeletedBody(bodyID)
            }
        }

        var candidate: [SourcePhysicsBodyID: CommittedBody] = [:]
        candidate.reserveCapacity(desiredBodies.count)
        for (bodyID, desired) in desiredBodies {
            guard let body = returnedBodies[bodyID] else {
                throw SourceCanonicalPropPhysicsCoordinatorError
                    .environmentMissingBody(bodyID)
            }
            guard body.simulationTick == simulationTick else {
                throw SourceCanonicalPropPhysicsCoordinatorError
                    .environmentBodyTickMismatch(
                        bodyID: bodyID,
                        expected: simulationTick,
                        received: body.simulationTick
                    )
            }
            guard let expectedMass = expectedMassStates[bodyID] else {
                throw SourceCanonicalPropPhysicsCoordinatorError
                    .environmentBodyConfigurationMismatch(bodyID)
            }
            switch expectedMass {
            case let .exact(properties):
                guard body.massProperties == properties else {
                    throw SourceCanonicalPropPhysicsCoordinatorError
                        .environmentBodyConfigurationMismatch(bodyID)
                }
            case let .backendAuthoredInertia(massKilograms):
                guard body.massProperties.massKilograms == massKilograms else {
                    throw SourceCanonicalPropPhysicsCoordinatorError
                        .environmentBodyConfigurationMismatch(bodyID)
                }
            }
            guard
                body.shape == desired.definition.shape,
                body.motionType == desired.definition.motionType,
                body.materialIndex == desired.definition.materialIndex
            else {
                throw SourceCanonicalPropPhysicsCoordinatorError
                    .environmentBodyConfigurationMismatch(bodyID)
            }
            candidate[bodyID] = CommittedBody(
                definition: desired.definition,
                body: body
            )
        }
        return candidate
    }

    private func expectedMassStates(
        after commands: [SourcePhysicsCommand]
    ) -> [SourcePhysicsBodyID: ExpectedMassState] {
        var states = committedBodies.mapValues {
            ExpectedMassState.exact($0.body.massProperties)
        }
        for command in commands {
            switch command.payload {
            case let .createBody(creation):
                states[creation.bodyID] = .exact(creation.massProperties)
            case let .deleteBody(deletion):
                states.removeValue(forKey: deletion.bodyID)
            case let .mutateBody(command):
                if case let .setMassKilograms(massKilograms) = command.mutation {
                    states[command.bodyID] = .backendAuthoredInertia(
                        massKilograms: massKilograms
                    )
                }
            case .simulate, .query:
                break
            }
        }
        return states
    }

    private func makeOperations(
        deletedBodyIDs: [SourcePhysicsBodyID],
        createdBodyIDs: [SourcePhysicsBodyID],
        desiredBodies: [SourcePhysicsBodyID: DesiredBody]
    ) -> [SourceCanonicalPropPhysicsOperation] {
        let deleted = Set(deletedBodyIDs)
        let created = Set(createdBodyIDs)
        var result: [SourceCanonicalPropPhysicsOperation] = []
        result.reserveCapacity(deleted.union(created).count)

        for bodyID in deletedBodyIDs where !created.contains(bodyID) {
            result.append(.delete(bodyID))
        }
        for bodyID in createdBodyIDs {
            if deleted.contains(bodyID), desiredBodies[bodyID] != nil {
                result.append(.replace(bodyID))
            } else {
                result.append(.create(bodyID))
            }
        }
        return result
    }

    private static func bodyIDPrecedes(
        _ lhs: SourcePhysicsBodyID,
        _ rhs: SourcePhysicsBodyID
    ) -> Bool {
        let lhsHandle = lhs.entityIdentity.handle.rawValue
        let rhsHandle = rhs.entityIdentity.handle.rawValue
        if lhsHandle != rhsHandle { return lhsHandle < rhsHandle }
        return lhs.solidIndex < rhs.solidIndex
    }
}
