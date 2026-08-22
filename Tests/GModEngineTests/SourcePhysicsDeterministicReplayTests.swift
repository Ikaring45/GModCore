import Testing
@testable import GModEngine

@Suite("Cross-platform Source physics deterministic replay contract")
struct SourcePhysicsDeterministicReplayTests {
    @Test("records and replays create, update, delete, simulate, and query values")
    func recordsAndReplaysCanonicalTranscript() throws {
        let corpus = try makeCorpus()
        let recorderProbe = ScriptedPhysicsContractProbe(
            batches: corpus.batches,
            snapshots: corpus.snapshots
        )
        let harness = SourcePhysicsDeterministicReplayHarness()

        let log = try harness.record(
            commandBatches: corpus.batches,
            using: recorderProbe
        )

        #expect(recorderProbe.executionCount == 4)
        #expect(log.fixedTimeStepSeconds == 0.015)
        #expect(log.frames.count == 4)
        #expect(log.frames[0].bodySnapshots[0].bodyID == corpus.oldBodyID)
        #expect(
            log.frames[0].bodySnapshots[0].bodyID.entityIdentity.handle
                .rawValue == corpus.oldBodyID.entityIdentity.handle.rawValue
        )
        #expect(log.frames[0].bodySnapshots[0].bodyID.solidIndex == 2)
        #expect(log.frames[1].events[0] == .bodyUpdated(
            deleteCommandSequence: 13,
            createCommandSequence: 14,
            bodyID: corpus.oldBodyID
        ))
        #expect(log.frames[2].events[0] == .bodyDeleted(
            commandSequence: 16,
            bodyID: corpus.oldBodyID
        ))
        #expect(log.frames[2].events[1] == .bodyCreated(
            commandSequence: 17,
            bodyID: corpus.newBodyID
        ))

        let decoded = try SourcePhysicsReplayLog(
            canonicalBytes: log.canonicalBytes
        )
        #expect(decoded == log)

        let replayProbe = ScriptedPhysicsContractProbe(
            batches: corpus.batches,
            snapshots: corpus.snapshots
        )
        let comparison = try harness.replay(decoded, using: replayProbe)
        #expect(comparison.frameCount == 4)
        #expect(comparison.canonicalByteCount == log.canonicalBytes.count)
        #expect(replayProbe.executionCount == 4)
    }

    @Test("offset-force world point round-trips through canonical replay bytes")
    func offsetForceMutationRoundTrips() throws {
        let bodyID = try makeBodyID(entryIndex: 42, serialNumber: 9)
        let creation = try makeCreation(bodyID: bodyID, x: 0)
        let mutation = try SourcePhysicsBodyMutationCommand(
            bodyID: bodyID,
            mutation: .applyForceOffset(
                force: SourceVector3(0, 12, 0),
                worldPosition: SourceVector3(0, 0, 33)
            )
        )
        let batch = try SourcePhysicsCommandBatch(commands: [
            SourcePhysicsCommand(
                sequence: 1,
                payload: .createBody(creation)
            ),
            SourcePhysicsCommand(
                sequence: 2,
                payload: .mutateBody(mutation)
            ),
            SourcePhysicsCommand(
                sequence: 3,
                payload: .simulate(SourcePhysicsSimulateCommand(
                    simulationTick: 1
                ))
            ),
        ])
        let harness = SourcePhysicsDeterministicReplayHarness()
        let log = try harness.record(
            commandBatches: [batch],
            using: SourceDeterministicPhysicsEnvironment()
        )
        #expect(SourcePhysicsReplayLog.formatVersion == 4)

        let decoded = try SourcePhysicsReplayLog(
            canonicalBytes: log.canonicalBytes
        )
        guard case let .mutateBody(decodedMutation) =
                decoded.frames[0].commandBatch.commands[1].payload else {
            Issue.record("decoded command lost offset-force mutation")
            return
        }
        #expect(decodedMutation == mutation)
        #expect(decoded == log)
        _ = try harness.replay(
            decoded,
            using: SourceDeterministicPhysicsEnvironment()
        )
    }

    @Test("center torque impulse round-trips through canonical replay bytes")
    func centerTorqueImpulseMutationRoundTrips() throws {
        let bodyID = try makeBodyID(entryIndex: 43, serialNumber: 9)
        let creation = try makeCreation(bodyID: bodyID, x: 0)
        let mutation = try SourcePhysicsBodyMutationCommand(
            bodyID: bodyID,
            mutation: .applyTorqueCenter(SourceVector3(7, 8, 9))
        )
        let batch = try SourcePhysicsCommandBatch(commands: [
            SourcePhysicsCommand(
                sequence: 1,
                payload: .createBody(creation)
            ),
            SourcePhysicsCommand(
                sequence: 2,
                payload: .mutateBody(mutation)
            ),
            SourcePhysicsCommand(
                sequence: 3,
                payload: .simulate(SourcePhysicsSimulateCommand(
                    simulationTick: 1
                ))
            ),
        ])
        let harness = SourcePhysicsDeterministicReplayHarness()
        let log = try harness.record(
            commandBatches: [batch],
            using: SourceDeterministicPhysicsEnvironment()
        )

        let decoded = try SourcePhysicsReplayLog(
            canonicalBytes: log.canonicalBytes
        )
        guard case let .mutateBody(decodedMutation) =
                decoded.frames[0].commandBatch.commands[1].payload else {
            Issue.record("decoded command lost center torque impulse")
            return
        }
        #expect(decodedMutation == mutation)
        #expect(decoded == log)
        _ = try harness.replay(
            decoded,
            using: SourceDeterministicPhysicsEnvironment()
        )
    }

    @Test("exact replay detects a different but structurally valid solver value")
    func deterministicValueDifferenceFailsClosed() throws {
        let corpus = try makeCorpus()
        let harness = SourcePhysicsDeterministicReplayHarness()
        let expected = try harness.record(
            commandBatches: corpus.batches,
            using: ScriptedPhysicsContractProbe(
                batches: corpus.batches,
                snapshots: corpus.snapshots
            )
        )
        var changedSnapshots = corpus.snapshots
        let changedBody = try makeBodySnapshot(
            creation: corpus.updatedCreation,
            transform: SourceEntityTransform(
                origin: SourceVector3(21, 0, 32),
                angles: .zero
            ),
            tick: 101
        )
        changedSnapshots[1] = try SourcePhysicsEnvironmentSnapshot(
            simulationTick: 101,
            lastProcessedCommandSequence: 15,
            bodies: [changedBody],
            queryResults: []
        )

        #expect(
            throws: SourcePhysicsReplayError
                .deterministicValueMismatch(frame: 1)
        ) {
            _ = try harness.replay(
                expected,
                using: ScriptedPhysicsContractProbe(
                    batches: corpus.batches,
                    snapshots: changedSnapshots
                )
            )
        }
    }

    @Test("sequence gaps and unsafe EHANDLE generation reuse fail before execution")
    func sequenceAndGenerationReuseFailClosed() throws {
        let bodyID = try makeBodyID(entryIndex: 41, serialNumber: 7)
        let nextGeneration = try makeBodyID(entryIndex: 41, serialNumber: 8)
        let creation = try makeCreation(bodyID: bodyID, x: 0)
        let nextCreation = try makeCreation(bodyID: nextGeneration, x: 1)
        let firstBatch = try SourcePhysicsCommandBatch(commands: [
            SourcePhysicsCommand(sequence: 50, payload: .createBody(creation)),
            SourcePhysicsCommand(
                sequence: 51,
                payload: .simulate(SourcePhysicsSimulateCommand(
                    simulationTick: 500
                ))
            )
        ])
        let firstSnapshot = try SourcePhysicsEnvironmentSnapshot(
            simulationTick: 500,
            lastProcessedCommandSequence: 51,
            bodies: [makeBodySnapshot(creation: creation, tick: 500)],
            queryResults: []
        )
        let gapBatch = try SourcePhysicsCommandBatch(commands: [
            SourcePhysicsCommand(
                sequence: 53,
                payload: .simulate(SourcePhysicsSimulateCommand(
                    simulationTick: 501
                ))
            )
        ])
        let probe = ScriptedPhysicsContractProbe(
            batches: [firstBatch],
            snapshots: [firstSnapshot]
        )
        #expect(
            throws: SourcePhysicsReplayError.commandSequenceGap(
                expected: 52,
                received: 53
            )
        ) {
            _ = try SourcePhysicsDeterministicReplayHarness().record(
                commandBatches: [firstBatch, gapBatch],
                using: probe
            )
        }
        #expect(probe.executionCount == 1)

        let conflictingBatch = try SourcePhysicsCommandBatch(commands: [
            SourcePhysicsCommand(
                sequence: 52,
                payload: .createBody(nextCreation)
            ),
            SourcePhysicsCommand(
                sequence: 53,
                payload: .simulate(SourcePhysicsSimulateCommand(
                    simulationTick: 501
                ))
            )
        ])
        let generationProbe = ScriptedPhysicsContractProbe(
            batches: [firstBatch],
            snapshots: [firstSnapshot]
        )
        #expect(
            throws: SourcePhysicsReplayError.liveEntityGenerationConflict(
                entryIndex: 41,
                liveHandle: bodyID.entityIdentity.handle.rawValue,
                attemptedHandle: nextGeneration.entityIdentity.handle.rawValue
            )
        ) {
            _ = try SourcePhysicsDeterministicReplayHarness().record(
                commandBatches: [firstBatch, conflictingBatch],
                using: generationProbe
            )
        }
        #expect(generationProbe.executionCount == 1)

        let deleteBatch = try SourcePhysicsCommandBatch(commands: [
            SourcePhysicsCommand(
                sequence: 52,
                payload: .deleteBody(SourcePhysicsBodyDeletionCommand(
                    bodyID: bodyID
                ))
            ),
            SourcePhysicsCommand(
                sequence: 53,
                payload: .simulate(SourcePhysicsSimulateCommand(
                    simulationTick: 501
                ))
            )
        ])
        let recreateBatch = try SourcePhysicsCommandBatch(commands: [
            SourcePhysicsCommand(sequence: 54, payload: .createBody(creation)),
            SourcePhysicsCommand(
                sequence: 55,
                payload: .simulate(SourcePhysicsSimulateCommand(
                    simulationTick: 502
                ))
            )
        ])
        let deletedSnapshot = try SourcePhysicsEnvironmentSnapshot(
            simulationTick: 501,
            lastProcessedCommandSequence: 53,
            bodies: [],
            queryResults: []
        )
        let reuseProbe = ScriptedPhysicsContractProbe(
            batches: [firstBatch, deleteBatch],
            snapshots: [firstSnapshot, deletedSnapshot]
        )
        #expect(throws: SourcePhysicsReplayError.retiredBodyReused(bodyID)) {
            _ = try SourcePhysicsDeterministicReplayHarness().record(
                commandBatches: [firstBatch, deleteBatch, recreateBatch],
                using: reuseProbe
            )
        }
        #expect(reuseProbe.executionCount == 2)
    }

    @Test("reordered body and query outputs are rejected")
    func reorderedOutputsFailClosed() throws {
        let firstID = try makeBodyID(entryIndex: 2, serialNumber: 1)
        let secondID = try makeBodyID(entryIndex: 3, serialNumber: 1)
        let firstCreation = try makeCreation(bodyID: firstID, x: 0)
        let secondCreation = try makeCreation(bodyID: secondID, x: 2)
        let bodyBatch = try SourcePhysicsCommandBatch(commands: [
            SourcePhysicsCommand(
                sequence: 1,
                payload: .createBody(firstCreation)
            ),
            SourcePhysicsCommand(
                sequence: 2,
                payload: .createBody(secondCreation)
            ),
            SourcePhysicsCommand(
                sequence: 3,
                payload: .simulate(SourcePhysicsSimulateCommand(
                    simulationTick: 1
                ))
            )
        ])
        let reversedBodies = try SourcePhysicsEnvironmentSnapshot(
            simulationTick: 1,
            lastProcessedCommandSequence: 3,
            bodies: [
                makeBodySnapshot(creation: secondCreation, tick: 1),
                makeBodySnapshot(creation: firstCreation, tick: 1)
            ],
            queryResults: []
        )
        #expect(
            throws: SourcePhysicsReplayError.environmentBodyOrderInvalid(
                previous: secondID,
                current: firstID
            )
        ) {
            _ = try SourcePhysicsDeterministicReplayHarness().record(
                commandBatches: [bodyBatch],
                using: ScriptedPhysicsContractProbe(
                    batches: [bodyBatch],
                    snapshots: [reversedBodies]
                )
            )
        }

        let firstQuery = try makeQuery(queryID: 10)
        let secondQuery = try makeQuery(queryID: 11)
        let queryBatch = try SourcePhysicsCommandBatch(commands: [
            SourcePhysicsCommand(
                sequence: 20,
                payload: .simulate(SourcePhysicsSimulateCommand(
                    simulationTick: 8
                ))
            ),
            SourcePhysicsCommand(sequence: 21, payload: .query(firstQuery)),
            SourcePhysicsCommand(sequence: 22, payload: .query(secondQuery))
        ])
        let firstResult = SourcePhysicsQueryResultSnapshot(
            queryID: 10,
            commandSequence: 21,
            simulationTick: 8,
            hit: nil
        )
        let secondResult = SourcePhysicsQueryResultSnapshot(
            queryID: 11,
            commandSequence: 22,
            simulationTick: 8,
            hit: nil
        )
        let reversedResults = try SourcePhysicsEnvironmentSnapshot(
            simulationTick: 8,
            lastProcessedCommandSequence: 22,
            bodies: [],
            queryResults: [secondResult, firstResult]
        )
        #expect(
            throws: SourcePhysicsReplayError
                .environmentQueryResultOrderMismatch(
                    index: 0,
                    expectedQueryID: 10,
                    receivedQueryID: 11
                )
        ) {
            _ = try SourcePhysicsDeterministicReplayHarness().record(
                commandBatches: [queryBatch],
                using: ScriptedPhysicsContractProbe(
                    batches: [queryBatch],
                    snapshots: [reversedResults]
                )
            )
        }
    }

    @Test("non-finite binary values and bounded transcript overflow fail closed")
    func binaryAndBudgetValidationFailClosed() throws {
        let batch = try SourcePhysicsCommandBatch(commands: [
            SourcePhysicsCommand(
                sequence: 1,
                payload: .simulate(SourcePhysicsSimulateCommand(
                    simulationTick: 1
                ))
            )
        ])
        let snapshot = try SourcePhysicsEnvironmentSnapshot(
            simulationTick: 1,
            lastProcessedCommandSequence: 1,
            bodies: [],
            queryResults: []
        )
        let log = try SourcePhysicsDeterministicReplayHarness().record(
            commandBatches: [batch],
            using: ScriptedPhysicsContractProbe(
                batches: [batch],
                snapshots: [snapshot]
            )
        )
        var nonFiniteHeader = log.canonicalBytes
        nonFiniteHeader[6] = 0x00
        nonFiniteHeader[7] = 0x00
        nonFiniteHeader[8] = 0xc0
        nonFiniteHeader[9] = 0x7f
        #expect(
            throws: SourcePhysicsReplayError.nonFinite(
                field: "fixedTimeStepSeconds"
            )
        ) {
            _ = try SourcePhysicsReplayLog(canonicalBytes: nonFiniteHeader)
        }

        let budget = try SourcePhysicsReplayBudget(
            maximumBytes: 1_000_000,
            maximumFrames: 1,
            maximumCommands: 8,
            maximumBodySnapshots: 8,
            maximumQueryResults: 8,
            maximumEvents: 8,
            maximumMeshParts: 16,
            maximumVertices: 128,
            maximumTriangles: 128,
            maximumIgnoredEntityReferences: 8
        )
        let nextBatch = try SourcePhysicsCommandBatch(commands: [
            SourcePhysicsCommand(
                sequence: 2,
                payload: .simulate(SourcePhysicsSimulateCommand(
                    simulationTick: 2
                ))
            )
        ])
        let boundedProbe = ScriptedPhysicsContractProbe(
            batches: [batch],
            snapshots: [snapshot]
        )
        #expect(
            throws: SourcePhysicsReplayError.budgetExceeded(
                field: "frames",
                limit: 1,
                attempted: 2
            )
        ) {
            _ = try SourcePhysicsDeterministicReplayHarness(
                budget: budget
            ).record(
                commandBatches: [batch, nextBatch],
                using: boundedProbe
            )
        }
        #expect(boundedProbe.executionCount == 1)
    }

    private func makeCorpus() throws -> ReplayCorpus {
        let oldBodyID = try makeBodyID(entryIndex: 41, serialNumber: 7)
        let newBodyID = try makeBodyID(entryIndex: 41, serialNumber: 8)
        let initialCreation = try makeCreation(bodyID: oldBodyID, x: 0)
        let updatedCreation = try makeCreation(bodyID: oldBodyID, x: 20)
        let replacementCreation = try makeCreation(bodyID: newBodyID, x: 40)
        let query = try makeQuery(queryID: 700)

        let firstBatch = try SourcePhysicsCommandBatch(commands: [
            SourcePhysicsCommand(
                sequence: 10,
                payload: .createBody(initialCreation)
            ),
            SourcePhysicsCommand(
                sequence: 11,
                payload: .simulate(SourcePhysicsSimulateCommand(
                    simulationTick: 100
                ))
            ),
            SourcePhysicsCommand(sequence: 12, payload: .query(query))
        ])
        let queryHit = try SourcePhysicsQueryHitSnapshot(
            bodyID: oldBodyID,
            fraction: 0.5,
            position: SourceVector3(5, 0, 32),
            normal: SourceVector3(-1, 0, 0),
            materialIndex: 3,
            startedSolid: false,
            allSolid: false
        )
        let queryResult = SourcePhysicsQueryResultSnapshot(
            queryID: 700,
            commandSequence: 12,
            simulationTick: 100,
            hit: queryHit
        )
        let firstSnapshot = try SourcePhysicsEnvironmentSnapshot(
            simulationTick: 100,
            lastProcessedCommandSequence: 12,
            bodies: [makeBodySnapshot(
                creation: initialCreation,
                tick: 100
            )],
            queryResults: [queryResult]
        )

        let updateBatch = try SourcePhysicsCommandBatch(commands: [
            SourcePhysicsCommand(
                sequence: 13,
                payload: .deleteBody(SourcePhysicsBodyDeletionCommand(
                    bodyID: oldBodyID
                ))
            ),
            SourcePhysicsCommand(
                sequence: 14,
                payload: .createBody(updatedCreation)
            ),
            SourcePhysicsCommand(
                sequence: 15,
                payload: .simulate(SourcePhysicsSimulateCommand(
                    simulationTick: 101
                ))
            )
        ])
        let updateSnapshot = try SourcePhysicsEnvironmentSnapshot(
            simulationTick: 101,
            lastProcessedCommandSequence: 15,
            bodies: [makeBodySnapshot(
                creation: updatedCreation,
                tick: 101
            )],
            queryResults: []
        )

        let generationBatch = try SourcePhysicsCommandBatch(commands: [
            SourcePhysicsCommand(
                sequence: 16,
                payload: .deleteBody(SourcePhysicsBodyDeletionCommand(
                    bodyID: oldBodyID
                ))
            ),
            SourcePhysicsCommand(
                sequence: 17,
                payload: .createBody(replacementCreation)
            ),
            SourcePhysicsCommand(
                sequence: 18,
                payload: .simulate(SourcePhysicsSimulateCommand(
                    simulationTick: 102
                ))
            )
        ])
        let generationSnapshot = try SourcePhysicsEnvironmentSnapshot(
            simulationTick: 102,
            lastProcessedCommandSequence: 18,
            bodies: [makeBodySnapshot(
                creation: replacementCreation,
                tick: 102
            )],
            queryResults: []
        )

        let deletionBatch = try SourcePhysicsCommandBatch(commands: [
            SourcePhysicsCommand(
                sequence: 19,
                payload: .deleteBody(SourcePhysicsBodyDeletionCommand(
                    bodyID: newBodyID
                ))
            ),
            SourcePhysicsCommand(
                sequence: 20,
                payload: .simulate(SourcePhysicsSimulateCommand(
                    simulationTick: 103
                ))
            )
        ])
        let deletionSnapshot = try SourcePhysicsEnvironmentSnapshot(
            simulationTick: 103,
            lastProcessedCommandSequence: 20,
            bodies: [],
            queryResults: []
        )

        return ReplayCorpus(
            batches: [
                firstBatch,
                updateBatch,
                generationBatch,
                deletionBatch
            ],
            snapshots: [
                firstSnapshot,
                updateSnapshot,
                generationSnapshot,
                deletionSnapshot
            ],
            oldBodyID: oldBodyID,
            newBodyID: newBodyID,
            updatedCreation: updatedCreation
        )
    }

    private func makeBodyID(
        entryIndex: Int,
        serialNumber: Int
    ) throws -> SourcePhysicsBodyID {
        try SourcePhysicsBodyID(
            entityIdentity: SourceCanonicalEntityIdentity(
                handle: SourceBaseHandle(
                    entryIndex: entryIndex,
                    serialNumber: serialNumber
                )
            ),
            solidIndex: 2
        )
    }

    private func makeCreation(
        bodyID: SourcePhysicsBodyID,
        x: Float
    ) throws -> SourcePhysicsBodyCreationCommand {
        try SourcePhysicsBodyCreationCommand(
            bodyID: bodyID,
            shape: makeShape(),
            massProperties: SourcePhysicsMassProperties(
                massKilograms: 12,
                principalInertia: SourceVector3(3, 4, 5)
            ),
            transform: SourceEntityTransform(
                origin: SourceVector3(x, 0, 32),
                angles: .zero
            ),
            linearVelocity: .zero,
            angularVelocity: .zero,
            motionType: .dynamicBody,
            materialIndex: 3,
            isGravityEnabled: true,
            isCollisionEnabled: true,
            startsAwake: true
        )
    }

    private func makeBodySnapshot(
        creation: SourcePhysicsBodyCreationCommand,
        transform: SourceEntityTransform? = nil,
        tick: UInt64
    ) throws -> SourcePhysicsBodySnapshot {
        try SourcePhysicsBodySnapshot(
            bodyID: creation.bodyID,
            shape: creation.shape,
            massProperties: creation.massProperties,
            transform: transform ?? creation.transform,
            linearVelocity: creation.linearVelocity,
            angularVelocity: creation.angularVelocity,
            motionType: creation.motionType,
            materialIndex: creation.materialIndex,
            isGravityEnabled: creation.isGravityEnabled,
            isCollisionEnabled: creation.isCollisionEnabled,
            isSleeping: false,
            simulationTick: tick
        )
    }

    private func makeQuery(queryID: UInt64) throws
        -> SourcePhysicsQueryCommand
    {
        try SourcePhysicsQueryCommand(
            queryID: queryID,
            geometry: .lineSegment(
                start: SourceVector3(0, 0, 32),
                end: SourceVector3(10, 0, 32)
            ),
            contentsMask: UInt32.max,
            collisionGroup: 0,
            scope: .staticAndMoving,
            ignoredEntities: []
        )
    }

    private func makeShape() throws -> SourcePhysicsShapeSnapshot {
        let vertices = [
            SourceVector3(0, 0, 0),
            SourceVector3(1, 0, 0),
            SourceVector3(0, 1, 0),
            SourceVector3(0, 0, 1)
        ]
        let triangles = try [
            SourcePhysicsIndexedTriangle(
                first: 0,
                second: 2,
                third: 1,
                materialIndex: 3
            ),
            SourcePhysicsIndexedTriangle(
                first: 0,
                second: 1,
                third: 3,
                materialIndex: 3
            ),
            SourcePhysicsIndexedTriangle(
                first: 1,
                second: 2,
                third: 3,
                materialIndex: 3
            ),
            SourcePhysicsIndexedTriangle(
                first: 2,
                second: 0,
                third: 3,
                materialIndex: 3
            )
        ]
        return try SourcePhysicsShapeSnapshot(
            topology: .convexParts,
            parts: [SourcePhysicsMeshPartSnapshot(
                vertices: vertices,
                triangles: triangles
            )]
        )
    }
}

private struct ReplayCorpus {
    let batches: [SourcePhysicsCommandBatch]
    let snapshots: [SourcePhysicsEnvironmentSnapshot]
    let oldBodyID: SourcePhysicsBodyID
    let newBodyID: SourcePhysicsBodyID
    let updatedCreation: SourcePhysicsBodyCreationCommand
}

/// Returns authored immutable snapshots only. It intentionally performs no
/// integration, contact generation, gravity, or other solver behavior.
private final class ScriptedPhysicsContractProbe: SourcePhysicsEnvironment {
    private let batches: [SourcePhysicsCommandBatch]
    private let snapshots: [SourcePhysicsEnvironmentSnapshot]
    private(set) var executionCount = 0

    init(
        batches: [SourcePhysicsCommandBatch],
        snapshots: [SourcePhysicsEnvironmentSnapshot]
    ) {
        self.batches = batches
        self.snapshots = snapshots
    }

    func execute(
        _ batch: SourcePhysicsCommandBatch
    ) throws -> SourcePhysicsEnvironmentSnapshot {
        guard executionCount < batches.count,
              executionCount < snapshots.count else {
            throw ScriptedPhysicsContractProbeError.unexpectedExecution
        }
        guard batch == batches[executionCount] else {
            throw ScriptedPhysicsContractProbeError.commandMismatch
        }
        defer { executionCount += 1 }
        return snapshots[executionCount]
    }
}

private enum ScriptedPhysicsContractProbeError: Error {
    case unexpectedExecution
    case commandMismatch
}
