/// Cross-platform record/replay boundary for an injected
/// ``SourcePhysicsEnvironment``.
///
/// This type is deliberately not a physics backend. It records the exact
/// backend-neutral commands and immutable snapshots which crossed the existing
/// Source physics contract. A Windows probe and an iOS backend can therefore
/// consume the same canonical bytes without exposing either backend's types.
public struct SourcePhysicsReplayBudget: Equatable, Sendable {
    public let maximumBytes: Int
    public let maximumFrames: Int
    public let maximumCommands: Int
    public let maximumBodySnapshots: Int
    public let maximumQueryResults: Int
    public let maximumEvents: Int
    public let maximumMeshParts: Int
    public let maximumVertices: Int
    public let maximumTriangles: Int
    public let maximumIgnoredEntityReferences: Int

    public init(
        maximumBytes: Int,
        maximumFrames: Int,
        maximumCommands: Int,
        maximumBodySnapshots: Int,
        maximumQueryResults: Int,
        maximumEvents: Int,
        maximumMeshParts: Int,
        maximumVertices: Int,
        maximumTriangles: Int,
        maximumIgnoredEntityReferences: Int
    ) throws {
        let values = [
            "maximumBytes": maximumBytes,
            "maximumFrames": maximumFrames,
            "maximumCommands": maximumCommands,
            "maximumBodySnapshots": maximumBodySnapshots,
            "maximumQueryResults": maximumQueryResults,
            "maximumEvents": maximumEvents,
            "maximumMeshParts": maximumMeshParts,
            "maximumVertices": maximumVertices,
            "maximumTriangles": maximumTriangles,
            "maximumIgnoredEntityReferences": maximumIgnoredEntityReferences
        ]
        for (field, value) in values where value <= 0 {
            throw SourcePhysicsReplayError.invalidBudget(
                field: field,
                value: value
            )
        }
        self.maximumBytes = maximumBytes
        self.maximumFrames = maximumFrames
        self.maximumCommands = maximumCommands
        self.maximumBodySnapshots = maximumBodySnapshots
        self.maximumQueryResults = maximumQueryResults
        self.maximumEvents = maximumEvents
        self.maximumMeshParts = maximumMeshParts
        self.maximumVertices = maximumVertices
        self.maximumTriangles = maximumTriangles
        self.maximumIgnoredEntityReferences = maximumIgnoredEntityReferences
    }

    /// A finite default sized for one bounded cross-platform replay corpus.
    public static let standard = SourcePhysicsReplayBudget(
        uncheckedMaximumBytes: 64 * 1_024 * 1_024,
        maximumFrames: 16_384,
        maximumCommands: 262_144,
        maximumBodySnapshots: 262_144,
        maximumQueryResults: 262_144,
        maximumEvents: 524_288,
        maximumMeshParts: 262_144,
        maximumVertices: 4_000_000,
        maximumTriangles: 8_000_000,
        maximumIgnoredEntityReferences: 1_000_000
    )

    private init(
        uncheckedMaximumBytes: Int,
        maximumFrames: Int,
        maximumCommands: Int,
        maximumBodySnapshots: Int,
        maximumQueryResults: Int,
        maximumEvents: Int,
        maximumMeshParts: Int,
        maximumVertices: Int,
        maximumTriangles: Int,
        maximumIgnoredEntityReferences: Int
    ) {
        maximumBytes = uncheckedMaximumBytes
        self.maximumFrames = maximumFrames
        self.maximumCommands = maximumCommands
        self.maximumBodySnapshots = maximumBodySnapshots
        self.maximumQueryResults = maximumQueryResults
        self.maximumEvents = maximumEvents
        self.maximumMeshParts = maximumMeshParts
        self.maximumVertices = maximumVertices
        self.maximumTriangles = maximumTriangles
        self.maximumIgnoredEntityReferences = maximumIgnoredEntityReferences
    }
}

public enum SourcePhysicsReplayError: Error, Equatable, Sendable {
    case invalidBudget(field: String, value: Int)
    case budgetExceeded(field: String, limit: Int, attempted: Int)
    case emptyCommandBatch(frame: Int)
    case commandSequenceGap(expected: UInt64, received: UInt64)
    case commandSequenceOverflow(UInt64)
    case simulationTickGap(expected: UInt64, received: UInt64)
    case simulationTickOverflow(UInt64)
    case simulationRequiredBeforeSnapshot(frame: Int)
    case simulationRequiredBeforeQuery(queryID: UInt64)
    case duplicateBodyCommand(
        bodyID: SourcePhysicsBodyID,
        operation: String
    )
    case bodyNotLive(SourcePhysicsBodyID)
    case bodyMutationNotSupported(SourcePhysicsBodyID)
    case bodyMutationWhileMotionDisabled(SourcePhysicsBodyID)
    case duplicateLiveBody(SourcePhysicsBodyID)
    case liveEntityGenerationConflict(
        entryIndex: Int,
        liveHandle: UInt32,
        attemptedHandle: UInt32
    )
    case retiredBodyReused(SourcePhysicsBodyID)
    case retiredEntityGenerationReused(UInt32)
    case updateOrderInvalid(SourcePhysicsBodyID)
    case updateCrossesExecutionBarrier(SourcePhysicsBodyID)
    case updateDidNotComplete(SourcePhysicsBodyID)
    case duplicateQueryID(UInt64)
    case environmentCommandSequenceMismatch(
        expected: UInt64,
        received: UInt64?
    )
    case environmentSimulationTickMismatch(
        expected: UInt64,
        received: UInt64
    )
    case environmentBodyOrderInvalid(
        previous: SourcePhysicsBodyID,
        current: SourcePhysicsBodyID
    )
    case environmentBodySetMismatch(
        expected: [SourcePhysicsBodyID],
        received: [SourcePhysicsBodyID]
    )
    case environmentBodyDefinitionMismatch(SourcePhysicsBodyID)
    case environmentBodyTickMismatch(
        bodyID: SourcePhysicsBodyID,
        expected: UInt64,
        received: UInt64
    )
    case environmentQueryResultCountMismatch(expected: Int, received: Int)
    case environmentQueryResultOrderMismatch(
        index: Int,
        expectedQueryID: UInt64,
        receivedQueryID: UInt64
    )
    case environmentQuerySequenceMismatch(
        queryID: UInt64,
        expected: UInt64,
        received: UInt64
    )
    case environmentQueryTickMismatch(
        queryID: UInt64,
        expected: UInt64,
        received: UInt64
    )
    case queryHitUnknownBody(
        queryID: UInt64,
        bodyID: SourcePhysicsBodyID
    )
    case recordedEventsMismatch(frame: Int)
    case unsupportedFormatVersion(UInt16)
    case invalidMagic
    case fixedTimeStepMismatch(expectedBits: UInt32, receivedBits: UInt32)
    case nonFinite(field: String)
    case integerOutsideCanonicalRange(field: String, value: Int)
    case invalidBoolean(field: String, value: UInt8)
    case invalidTag(field: String, value: UInt8)
    case invalidEntityHandle(UInt32)
    case entityEntryIndexOutsideCanonicalRange(Int)
    case truncatedCanonicalLog(offset: Int)
    case trailingCanonicalBytes(count: Int)
    case nonCanonicalEncoding
    case deterministicValueMismatch(frame: Int)
    case deterministicByteMismatch(offset: Int)
}

/// Canonical command-completion events. `bodyUpdated` is the existing Source
/// contract's ordered delete-then-create replacement of one full body ID; it
/// does not add an invented backend update command.
public enum SourcePhysicsReplayEventSnapshot: Equatable, Sendable {
    case bodyCreated(
        commandSequence: UInt64,
        bodyID: SourcePhysicsBodyID
    )
    case bodyUpdated(
        deleteCommandSequence: UInt64,
        createCommandSequence: UInt64,
        bodyID: SourcePhysicsBodyID
    )
    case bodyDeleted(
        commandSequence: UInt64,
        bodyID: SourcePhysicsBodyID
    )
    case bodyMutated(
        commandSequence: UInt64,
        command: SourcePhysicsBodyMutationCommand
    )
    case simulated(
        commandSequence: UInt64,
        simulationTick: UInt64
    )
    case queryCompleted(SourcePhysicsQueryResultSnapshot)

    public var fixedTimeStepSeconds: Float {
        SourcePhysicsContract.fixedTimeStepSeconds
    }
}

/// One immutable command/result boundary in a replay log.
public struct SourcePhysicsReplayFrame: Equatable, Sendable {
    public let commandBatch: SourcePhysicsCommandBatch
    public let environmentSnapshot: SourcePhysicsEnvironmentSnapshot
    public let events: [SourcePhysicsReplayEventSnapshot]

    public var bodySnapshots: [SourcePhysicsBodySnapshot] {
        environmentSnapshot.bodies
    }

    public var queryResultSnapshots: [SourcePhysicsQueryResultSnapshot] {
        environmentSnapshot.queryResults
    }

    fileprivate init(
        commandBatch: SourcePhysicsCommandBatch,
        environmentSnapshot: SourcePhysicsEnvironmentSnapshot,
        events: [SourcePhysicsReplayEventSnapshot]
    ) {
        self.commandBatch = commandBatch
        self.environmentSnapshot = environmentSnapshot
        self.events = events
    }
}

/// Decoded value transcript plus its canonical little-endian binary form.
public struct SourcePhysicsReplayLog: Equatable, Sendable {
    public static let formatVersion: UInt16 = 3

    public let fixedTimeStepSeconds: Float
    public let frames: [SourcePhysicsReplayFrame]
    public let canonicalBytes: [UInt8]

    /// Decodes and validates an untrusted cross-platform replay file.
    public init(
        canonicalBytes: [UInt8],
        budget: SourcePhysicsReplayBudget = .standard
    ) throws {
        let frames = try SourcePhysicsReplayCodec.decode(
            canonicalBytes,
            budget: budget
        )
        let validated = try SourcePhysicsReplayTranscriptValidator.validate(
            frames: frames,
            budget: budget
        )
        guard validated == frames else {
            throw SourcePhysicsReplayError.nonCanonicalEncoding
        }
        let encoded = try SourcePhysicsReplayCodec.encode(
            frames,
            budget: budget
        )
        guard encoded == canonicalBytes else {
            throw SourcePhysicsReplayError.nonCanonicalEncoding
        }
        fixedTimeStepSeconds = SourcePhysicsContract.fixedTimeStepSeconds
        self.frames = frames
        self.canonicalBytes = canonicalBytes
    }

    fileprivate init(
        validatedFrames: [SourcePhysicsReplayFrame],
        budget: SourcePhysicsReplayBudget
    ) throws {
        let canonicalBytes = try SourcePhysicsReplayCodec.encode(
            validatedFrames,
            budget: budget
        )
        fixedTimeStepSeconds = SourcePhysicsContract.fixedTimeStepSeconds
        frames = validatedFrames
        self.canonicalBytes = canonicalBytes
    }
}

public struct SourcePhysicsReplayComparison: Equatable, Sendable {
    public let frameCount: Int
    public let canonicalByteCount: Int
}

/// Synchronous harness which requires a real environment or an explicitly
/// scripted contract probe supplied by the caller. It owns no default solver.
public final class SourcePhysicsDeterministicReplayHarness {
    public let budget: SourcePhysicsReplayBudget

    public init(budget: SourcePhysicsReplayBudget = .standard) {
        self.budget = budget
    }

    public func record(
        commandBatches: [SourcePhysicsCommandBatch],
        using environment: SourcePhysicsEnvironment
    ) throws -> SourcePhysicsReplayLog {
        var validator = SourcePhysicsReplayTranscriptValidator(budget: budget)
        var frames: [SourcePhysicsReplayFrame] = []
        frames.reserveCapacity(min(commandBatches.count, budget.maximumFrames))
        for (frameIndex, batch) in commandBatches.enumerated() {
            try validator.prepare(batch: batch, frameIndex: frameIndex)
            let snapshot = try environment.execute(batch)
            let frame = try validator.finish(
                batch: batch,
                snapshot: snapshot,
                frameIndex: frameIndex
            )
            frames.append(frame)
        }
        return try SourcePhysicsReplayLog(
            validatedFrames: frames,
            budget: budget
        )
    }

    /// Executes the recorded inputs against another injected environment and
    /// requires an exact canonical value and byte match.
    @discardableResult
    public func replay(
        _ expected: SourcePhysicsReplayLog,
        using environment: SourcePhysicsEnvironment
    ) throws -> SourcePhysicsReplayComparison {
        guard expected.canonicalBytes.count <= budget.maximumBytes else {
            throw SourcePhysicsReplayError.budgetExceeded(
                field: "bytes",
                limit: budget.maximumBytes,
                attempted: expected.canonicalBytes.count
            )
        }
        let actual = try record(
            commandBatches: expected.frames.map(\.commandBatch),
            using: environment
        )
        try compare(expected, actual)
        return SourcePhysicsReplayComparison(
            frameCount: actual.frames.count,
            canonicalByteCount: actual.canonicalBytes.count
        )
    }

    public func compare(
        _ expected: SourcePhysicsReplayLog,
        _ actual: SourcePhysicsReplayLog
    ) throws {
        if expected.frames != actual.frames {
            let sharedCount = min(expected.frames.count, actual.frames.count)
            let mismatch = (0 ..< sharedCount).first {
                expected.frames[$0] != actual.frames[$0]
            } ?? sharedCount
            throw SourcePhysicsReplayError.deterministicValueMismatch(
                frame: mismatch
            )
        }
        guard expected.canonicalBytes == actual.canonicalBytes else {
            let sharedCount = min(
                expected.canonicalBytes.count,
                actual.canonicalBytes.count
            )
            let offset = (0 ..< sharedCount).first {
                expected.canonicalBytes[$0] != actual.canonicalBytes[$0]
            } ?? sharedCount
            throw SourcePhysicsReplayError.deterministicByteMismatch(
                offset: offset
            )
        }
    }
}

private struct SourcePhysicsReplayQueryExpectation {
    let command: SourcePhysicsQueryCommand
    let commandSequence: UInt64
    let simulationTick: UInt64
    let liveBodies: Set<SourcePhysicsBodyID>
}

private struct SourcePhysicsReplayUpdatePair {
    let deleteIndex: Int
    let deleteSequence: UInt64
    let createIndex: Int
    let createSequence: UInt64
}

private struct SourcePhysicsReplayPreparedFrame {
    let updatePairs: [SourcePhysicsBodyID: SourcePhysicsReplayUpdatePair]
    let queryExpectations: [SourcePhysicsReplayQueryExpectation]
    let eventsWithoutQueries: [Int: SourcePhysicsReplayEventSnapshot]
}

private struct SourcePhysicsReplayLiveBody {
    let creation: SourcePhysicsBodyCreationCommand
    var isMotionEnabled: Bool
    var isGravityEnabled: Bool
    var isCollisionEnabled: Bool

    init(creation: SourcePhysicsBodyCreationCommand) {
        self.creation = creation
        isMotionEnabled = creation.motionType != .staticBody
        isGravityEnabled = creation.isGravityEnabled
        isCollisionEnabled = creation.isCollisionEnabled
    }
}

private struct SourcePhysicsReplayTranscriptValidator {
    let budget: SourcePhysicsReplayBudget
    private var counter = SourcePhysicsReplayBudgetCounter()
    private var lastCommandSequence: UInt64?
    private var lastSimulationTick: UInt64?
    private var currentSimulationTick: UInt64?
    private var liveBodies: [
        SourcePhysicsBodyID: SourcePhysicsReplayLiveBody
    ] = [:]
    private var liveHandleByEntry: [Int: UInt32] = [:]
    private var everCreatedBodies = Set<SourcePhysicsBodyID>()
    private var retiredHandles = Set<UInt32>()
    private var usedQueryIDs = Set<UInt64>()
    private var preparedFrame: SourcePhysicsReplayPreparedFrame?

    init(budget: SourcePhysicsReplayBudget) {
        self.budget = budget
    }

    static func validate(
        frames: [SourcePhysicsReplayFrame],
        budget: SourcePhysicsReplayBudget
    ) throws -> [SourcePhysicsReplayFrame] {
        var validator = Self(budget: budget)
        var canonicalFrames: [SourcePhysicsReplayFrame] = []
        canonicalFrames.reserveCapacity(min(frames.count, budget.maximumFrames))
        for (frameIndex, frame) in frames.enumerated() {
            try validator.prepare(
                batch: frame.commandBatch,
                frameIndex: frameIndex
            )
            let canonical = try validator.finish(
                batch: frame.commandBatch,
                snapshot: frame.environmentSnapshot,
                frameIndex: frameIndex
            )
            guard canonical.events == frame.events else {
                throw SourcePhysicsReplayError.recordedEventsMismatch(
                    frame: frameIndex
                )
            }
            canonicalFrames.append(canonical)
        }
        return canonicalFrames
    }

    mutating func prepare(
        batch: SourcePhysicsCommandBatch,
        frameIndex: Int
    ) throws {
        guard preparedFrame == nil else {
            preconditionFailure("physics replay frame finished out of order")
        }
        guard !batch.commands.isEmpty else {
            throw SourcePhysicsReplayError.emptyCommandBatch(frame: frameIndex)
        }
        try counter.addFrame(budget: budget)
        try counter.addCommands(batch.commands.count, budget: budget)

        var deletes: [SourcePhysicsBodyID: (index: Int, sequence: UInt64)] = [:]
        var creates: [SourcePhysicsBodyID: (index: Int, sequence: UInt64)] = [:]
        for (commandIndex, command) in batch.commands.enumerated() {
            try validateSequence(command.sequence)
            switch command.payload {
            case let .createBody(creation):
                guard creates[creation.bodyID] == nil else {
                    throw SourcePhysicsReplayError.duplicateBodyCommand(
                        bodyID: creation.bodyID,
                        operation: "create"
                    )
                }
                creates[creation.bodyID] = (commandIndex, command.sequence)
                try counter.addShape(creation.shape, budget: budget)
            case let .deleteBody(deletion):
                guard deletes[deletion.bodyID] == nil else {
                    throw SourcePhysicsReplayError.duplicateBodyCommand(
                        bodyID: deletion.bodyID,
                        operation: "delete"
                    )
                }
                deletes[deletion.bodyID] = (commandIndex, command.sequence)
            case .mutateBody:
                break
            case let .simulate(simulate):
                try validateSimulationTick(simulate.simulationTick)
            case let .query(query):
                try counter.addIgnoredEntities(
                    query.ignoredEntities.count,
                    budget: budget
                )
            }
        }

        var updatePairs: [
            SourcePhysicsBodyID: SourcePhysicsReplayUpdatePair
        ] = [:]
        for (bodyID, deletion) in deletes {
            guard let creation = creates[bodyID] else { continue }
            guard deletion.index < creation.index else {
                throw SourcePhysicsReplayError.updateOrderInvalid(bodyID)
            }
            guard liveBodies[bodyID] != nil else {
                throw SourcePhysicsReplayError.bodyNotLive(bodyID)
            }
            let crossesBarrier = batch.commands[
                (deletion.index + 1) ..< creation.index
            ].contains { command in
                switch command.payload {
                case .simulate, .query:
                    return true
                case .createBody, .deleteBody, .mutateBody:
                    return false
                }
            }
            guard !crossesBarrier else {
                throw SourcePhysicsReplayError
                    .updateCrossesExecutionBarrier(bodyID)
            }
            updatePairs[bodyID] = SourcePhysicsReplayUpdatePair(
                deleteIndex: deletion.index,
                deleteSequence: deletion.sequence,
                createIndex: creation.index,
                createSequence: creation.sequence
            )
        }

        var pendingUpdates = Set<SourcePhysicsBodyID>()
        var queryExpectations: [SourcePhysicsReplayQueryExpectation] = []
        var events: [Int: SourcePhysicsReplayEventSnapshot] = [:]
        for (commandIndex, command) in batch.commands.enumerated() {
            switch command.payload {
            case let .createBody(creation):
                let bodyID = creation.bodyID
                if let update = updatePairs[bodyID] {
                    guard pendingUpdates.remove(bodyID) != nil else {
                        throw SourcePhysicsReplayError
                            .updateDidNotComplete(bodyID)
                    }
                    liveBodies[bodyID] = SourcePhysicsReplayLiveBody(
                        creation: creation
                    )
                    events[commandIndex] = .bodyUpdated(
                        deleteCommandSequence: update.deleteSequence,
                        createCommandSequence: update.createSequence,
                        bodyID: bodyID
                    )
                } else {
                    try insertNewBody(creation)
                    events[commandIndex] = .bodyCreated(
                        commandSequence: command.sequence,
                        bodyID: bodyID
                    )
                }
            case let .deleteBody(deletion):
                let bodyID = deletion.bodyID
                guard liveBodies.removeValue(forKey: bodyID) != nil else {
                    throw SourcePhysicsReplayError.bodyNotLive(bodyID)
                }
                if updatePairs[bodyID] != nil {
                    pendingUpdates.insert(bodyID)
                } else {
                    retireHandleIfNoBodiesRemain(bodyID.entityIdentity)
                    events[commandIndex] = .bodyDeleted(
                        commandSequence: command.sequence,
                        bodyID: bodyID
                    )
                }
            case let .mutateBody(mutation):
                try apply(mutation, toLiveBodyAt: mutation.bodyID)
                events[commandIndex] = .bodyMutated(
                    commandSequence: command.sequence,
                    command: mutation
                )
            case let .simulate(simulate):
                currentSimulationTick = simulate.simulationTick
                events[commandIndex] = .simulated(
                    commandSequence: command.sequence,
                    simulationTick: simulate.simulationTick
                )
            case let .query(query):
                guard let currentSimulationTick else {
                    throw SourcePhysicsReplayError
                        .simulationRequiredBeforeQuery(queryID: query.queryID)
                }
                guard usedQueryIDs.insert(query.queryID).inserted else {
                    throw SourcePhysicsReplayError.duplicateQueryID(query.queryID)
                }
                queryExpectations.append(SourcePhysicsReplayQueryExpectation(
                    command: query,
                    commandSequence: command.sequence,
                    simulationTick: currentSimulationTick,
                    liveBodies: Set(liveBodies.keys)
                ))
            }
        }
        if let incomplete = pendingUpdates.first {
            throw SourcePhysicsReplayError.updateDidNotComplete(incomplete)
        }
        preparedFrame = SourcePhysicsReplayPreparedFrame(
            updatePairs: updatePairs,
            queryExpectations: queryExpectations,
            eventsWithoutQueries: events
        )
    }

    mutating func finish(
        batch: SourcePhysicsCommandBatch,
        snapshot: SourcePhysicsEnvironmentSnapshot,
        frameIndex: Int
    ) throws -> SourcePhysicsReplayFrame {
        guard let prepared = preparedFrame else {
            preconditionFailure("physics replay frame was not prepared")
        }
        defer { preparedFrame = nil }
        guard let finalSequence = batch.commands.last?.sequence else {
            throw SourcePhysicsReplayError.emptyCommandBatch(frame: frameIndex)
        }
        guard snapshot.lastProcessedCommandSequence == finalSequence else {
            throw SourcePhysicsReplayError
                .environmentCommandSequenceMismatch(
                    expected: finalSequence,
                    received: snapshot.lastProcessedCommandSequence
                )
        }
        guard let currentSimulationTick else {
            throw SourcePhysicsReplayError
                .simulationRequiredBeforeSnapshot(frame: frameIndex)
        }
        guard snapshot.simulationTick == currentSimulationTick else {
            throw SourcePhysicsReplayError.environmentSimulationTickMismatch(
                expected: currentSimulationTick,
                received: snapshot.simulationTick
            )
        }

        try validateBodySnapshots(
            snapshot.bodies,
            simulationTick: currentSimulationTick
        )
        let queryEvents = try validateQueryResults(
            snapshot.queryResults,
            expectations: prepared.queryExpectations
        )
        var events: [SourcePhysicsReplayEventSnapshot] = []
        events.reserveCapacity(batch.commands.count)
        var queryIndex = 0
        for (commandIndex, command) in batch.commands.enumerated() {
            if case .query = command.payload {
                events.append(queryEvents[queryIndex])
                queryIndex += 1
            } else if let event = prepared.eventsWithoutQueries[commandIndex] {
                events.append(event)
            }
        }

        try counter.addBodies(snapshot.bodies.count, budget: budget)
        for body in snapshot.bodies {
            try counter.addShape(body.shape, budget: budget)
        }
        try counter.addQueryResults(snapshot.queryResults.count, budget: budget)
        try counter.addEvents(events.count, budget: budget)
        return SourcePhysicsReplayFrame(
            commandBatch: batch,
            environmentSnapshot: snapshot,
            events: events
        )
    }

    private mutating func validateSequence(_ sequence: UInt64) throws {
        if let lastCommandSequence {
            guard lastCommandSequence != UInt64.max else {
                throw SourcePhysicsReplayError
                    .commandSequenceOverflow(lastCommandSequence)
            }
            let expected = lastCommandSequence + 1
            guard sequence == expected else {
                throw SourcePhysicsReplayError.commandSequenceGap(
                    expected: expected,
                    received: sequence
                )
            }
        }
        lastCommandSequence = sequence
    }

    private mutating func validateSimulationTick(_ tick: UInt64) throws {
        if let lastSimulationTick {
            guard lastSimulationTick != UInt64.max else {
                throw SourcePhysicsReplayError
                    .simulationTickOverflow(lastSimulationTick)
            }
            let expected = lastSimulationTick + 1
            guard tick == expected else {
                throw SourcePhysicsReplayError.simulationTickGap(
                    expected: expected,
                    received: tick
                )
            }
        }
        lastSimulationTick = tick
    }

    private mutating func insertNewBody(
        _ creation: SourcePhysicsBodyCreationCommand
    ) throws {
        let bodyID = creation.bodyID
        guard liveBodies[bodyID] == nil else {
            throw SourcePhysicsReplayError.duplicateLiveBody(bodyID)
        }
        guard !everCreatedBodies.contains(bodyID) else {
            throw SourcePhysicsReplayError.retiredBodyReused(bodyID)
        }
        let identity = bodyID.entityIdentity
        let handle = identity.handle.rawValue
        guard !retiredHandles.contains(handle) else {
            throw SourcePhysicsReplayError
                .retiredEntityGenerationReused(handle)
        }
        if let liveHandle = liveHandleByEntry[identity.entryIndex] {
            guard liveHandle == handle else {
                throw SourcePhysicsReplayError.liveEntityGenerationConflict(
                    entryIndex: identity.entryIndex,
                    liveHandle: liveHandle,
                    attemptedHandle: handle
                )
            }
        } else {
            liveHandleByEntry[identity.entryIndex] = handle
        }
        liveBodies[bodyID] = SourcePhysicsReplayLiveBody(creation: creation)
        everCreatedBodies.insert(bodyID)
    }

    private mutating func apply(
        _ command: SourcePhysicsBodyMutationCommand,
        toLiveBodyAt bodyID: SourcePhysicsBodyID
    ) throws {
        guard var body = liveBodies[bodyID] else {
            throw SourcePhysicsReplayError.bodyNotLive(bodyID)
        }
        let supportsMotion = body.creation.motionType != .staticBody
        let requiresEnabledDynamicMotion: Bool
        switch command.mutation {
        case .wake,
             .sleep,
             .applyCenterForce,
             .applyForceOffset,
             .applyCenterImpulse:
            requiresEnabledDynamicMotion = true
        default:
            requiresEnabledDynamicMotion = false
        }
        if requiresEnabledDynamicMotion {
            guard body.creation.motionType == .dynamicBody else {
                throw SourcePhysicsReplayError.bodyMutationNotSupported(bodyID)
            }
            guard body.isMotionEnabled else {
                throw SourcePhysicsReplayError
                    .bodyMutationWhileMotionDisabled(bodyID)
            }
        }
        switch command.mutation {
        case let .setMotionEnabled(enabled):
            guard supportsMotion else {
                throw SourcePhysicsReplayError.bodyMutationNotSupported(bodyID)
            }
            body.isMotionEnabled = enabled
        case let .setGravityEnabled(enabled):
            body.isGravityEnabled = enabled
        case let .setCollisionEnabled(enabled):
            body.isCollisionEnabled = enabled
        case .setLinearVelocity,
             .addLinearVelocity,
             .setAngularVelocity,
             .addAngularVelocity:
            guard supportsMotion else {
                throw SourcePhysicsReplayError.bodyMutationNotSupported(bodyID)
            }
        case .wake,
             .sleep,
             .applyCenterForce,
             .applyForceOffset,
             .applyCenterImpulse:
            break
        }
        liveBodies[bodyID] = body
    }

    private mutating func retireHandleIfNoBodiesRemain(
        _ identity: SourceCanonicalEntityIdentity
    ) {
        let handle = identity.handle.rawValue
        let remains = liveBodies.keys.contains {
            $0.entityIdentity.handle.rawValue == handle
        }
        guard !remains else { return }
        liveHandleByEntry.removeValue(forKey: identity.entryIndex)
        retiredHandles.insert(handle)
    }

    private func validateBodySnapshots(
        _ bodies: [SourcePhysicsBodySnapshot],
        simulationTick: UInt64
    ) throws {
        if bodies.count > 1 {
            for index in 1 ..< bodies.count {
                let previous = bodies[index - 1].bodyID
                let current = bodies[index].bodyID
                guard sourcePhysicsReplayBodyIDPrecedes(previous, current) else {
                    throw SourcePhysicsReplayError
                        .environmentBodyOrderInvalid(
                            previous: previous,
                            current: current
                        )
                }
            }
        }
        let expected = liveBodies.keys.sorted(
            by: sourcePhysicsReplayBodyIDPrecedes
        )
        let received = bodies.map(\.bodyID)
        guard expected == received else {
            throw SourcePhysicsReplayError.environmentBodySetMismatch(
                expected: expected,
                received: received
            )
        }
        for body in bodies {
            guard let liveBody = liveBodies[body.bodyID] else {
                throw SourcePhysicsReplayError.environmentBodySetMismatch(
                    expected: expected,
                    received: received
                )
            }
            guard
                body.shape == liveBody.creation.shape,
                body.massProperties == liveBody.creation.massProperties,
                body.motionType == liveBody.creation.motionType,
                body.materialIndex == liveBody.creation.materialIndex,
                body.isMotionEnabled == liveBody.isMotionEnabled,
                body.isGravityEnabled == liveBody.isGravityEnabled,
                body.isCollisionEnabled == liveBody.isCollisionEnabled
            else {
                throw SourcePhysicsReplayError
                    .environmentBodyDefinitionMismatch(body.bodyID)
            }
            guard body.simulationTick == simulationTick else {
                throw SourcePhysicsReplayError.environmentBodyTickMismatch(
                    bodyID: body.bodyID,
                    expected: simulationTick,
                    received: body.simulationTick
                )
            }
        }
    }

    private func validateQueryResults(
        _ results: [SourcePhysicsQueryResultSnapshot],
        expectations: [SourcePhysicsReplayQueryExpectation]
    ) throws -> [SourcePhysicsReplayEventSnapshot] {
        guard results.count == expectations.count else {
            throw SourcePhysicsReplayError
                .environmentQueryResultCountMismatch(
                    expected: expectations.count,
                    received: results.count
                )
        }
        var events: [SourcePhysicsReplayEventSnapshot] = []
        events.reserveCapacity(results.count)
        for (index, pair) in zip(expectations, results).enumerated() {
            let expectation = pair.0
            let result = pair.1
            guard result.queryID == expectation.command.queryID else {
                throw SourcePhysicsReplayError
                    .environmentQueryResultOrderMismatch(
                        index: index,
                        expectedQueryID: expectation.command.queryID,
                        receivedQueryID: result.queryID
                    )
            }
            guard result.commandSequence == expectation.commandSequence else {
                throw SourcePhysicsReplayError.environmentQuerySequenceMismatch(
                    queryID: result.queryID,
                    expected: expectation.commandSequence,
                    received: result.commandSequence
                )
            }
            guard result.simulationTick == expectation.simulationTick else {
                throw SourcePhysicsReplayError.environmentQueryTickMismatch(
                    queryID: result.queryID,
                    expected: expectation.simulationTick,
                    received: result.simulationTick
                )
            }
            if let hit = result.hit,
               !expectation.liveBodies.contains(hit.bodyID) {
                throw SourcePhysicsReplayError.queryHitUnknownBody(
                    queryID: result.queryID,
                    bodyID: hit.bodyID
                )
            }
            events.append(.queryCompleted(result))
        }
        return events
    }
}

private struct SourcePhysicsReplayBudgetCounter {
    private var frames = 0
    private var commands = 0
    private var bodySnapshots = 0
    private var queryResults = 0
    private var events = 0
    private var meshParts = 0
    private var vertices = 0
    private var triangles = 0
    private var ignoredEntityReferences = 0

    mutating func addFrame(budget: SourcePhysicsReplayBudget) throws {
        frames = try adding(
            frames,
            1,
            field: "frames",
            limit: budget.maximumFrames
        )
    }

    mutating func addCommands(
        _ count: Int,
        budget: SourcePhysicsReplayBudget
    ) throws {
        commands = try adding(
            commands,
            count,
            field: "commands",
            limit: budget.maximumCommands
        )
    }

    mutating func addBodies(
        _ count: Int,
        budget: SourcePhysicsReplayBudget
    ) throws {
        bodySnapshots = try adding(
            bodySnapshots,
            count,
            field: "bodySnapshots",
            limit: budget.maximumBodySnapshots
        )
    }

    mutating func addQueryResults(
        _ count: Int,
        budget: SourcePhysicsReplayBudget
    ) throws {
        queryResults = try adding(
            queryResults,
            count,
            field: "queryResults",
            limit: budget.maximumQueryResults
        )
    }

    mutating func addEvents(
        _ count: Int,
        budget: SourcePhysicsReplayBudget
    ) throws {
        events = try adding(
            events,
            count,
            field: "events",
            limit: budget.maximumEvents
        )
    }

    mutating func addIgnoredEntities(
        _ count: Int,
        budget: SourcePhysicsReplayBudget
    ) throws {
        ignoredEntityReferences = try adding(
            ignoredEntityReferences,
            count,
            field: "ignoredEntityReferences",
            limit: budget.maximumIgnoredEntityReferences
        )
    }

    mutating func addShape(
        _ shape: SourcePhysicsShapeSnapshot,
        budget: SourcePhysicsReplayBudget
    ) throws {
        meshParts = try adding(
            meshParts,
            shape.parts.count,
            field: "meshParts",
            limit: budget.maximumMeshParts
        )
        for part in shape.parts {
            vertices = try adding(
                vertices,
                part.vertices.count,
                field: "vertices",
                limit: budget.maximumVertices
            )
            triangles = try adding(
                triangles,
                part.triangles.count,
                field: "triangles",
                limit: budget.maximumTriangles
            )
        }
    }

    private func adding(
        _ current: Int,
        _ amount: Int,
        field: String,
        limit: Int
    ) throws -> Int {
        guard amount >= 0, amount <= limit, current <= limit - amount else {
            let attempted = amount > Int.max - current
                ? Int.max
                : current + amount
            throw SourcePhysicsReplayError.budgetExceeded(
                field: field,
                limit: limit,
                attempted: attempted
            )
        }
        return current + amount
    }
}

private func sourcePhysicsReplayBodyIDPrecedes(
    _ lhs: SourcePhysicsBodyID,
    _ rhs: SourcePhysicsBodyID
) -> Bool {
    let leftHandle = lhs.entityIdentity.handle.rawValue
    let rightHandle = rhs.entityIdentity.handle.rawValue
    if leftHandle != rightHandle { return leftHandle < rightHandle }
    return lhs.solidIndex < rhs.solidIndex
}

private enum SourcePhysicsReplayCodec {
    private static let magic: [UInt8] = [0x53, 0x50, 0x52, 0x4c] // SPRL

    static func encode(
        _ frames: [SourcePhysicsReplayFrame],
        budget: SourcePhysicsReplayBudget
    ) throws -> [UInt8] {
        var encoder = SourcePhysicsReplayEncoder(budget: budget)
        try encoder.writeBytes(magic)
        try encoder.writeUInt16(SourcePhysicsReplayLog.formatVersion)
        try encoder.writeFloat(
            SourcePhysicsContract.fixedTimeStepSeconds,
            field: "fixedTimeStepSeconds"
        )
        try encoder.writeCount(frames.count, field: "frames")
        for frame in frames {
            try encoder.write(frame)
        }
        return encoder.bytes
    }

    static func decode(
        _ bytes: [UInt8],
        budget: SourcePhysicsReplayBudget
    ) throws -> [SourcePhysicsReplayFrame] {
        guard bytes.count <= budget.maximumBytes else {
            throw SourcePhysicsReplayError.budgetExceeded(
                field: "bytes",
                limit: budget.maximumBytes,
                attempted: bytes.count
            )
        }
        var decoder = SourcePhysicsReplayDecoder(
            bytes: bytes,
            budget: budget
        )
        guard try decoder.readBytes(count: magic.count) == magic else {
            throw SourcePhysicsReplayError.invalidMagic
        }
        let version = try decoder.readUInt16()
        guard version == SourcePhysicsReplayLog.formatVersion else {
            throw SourcePhysicsReplayError.unsupportedFormatVersion(version)
        }
        let fixedStep = try decoder.readFloat(field: "fixedTimeStepSeconds")
        let expectedBits = sourcePhysicsReplayCanonicalFloatBits(
            SourcePhysicsContract.fixedTimeStepSeconds
        )
        let receivedBits = sourcePhysicsReplayCanonicalFloatBits(fixedStep)
        guard receivedBits == expectedBits else {
            throw SourcePhysicsReplayError.fixedTimeStepMismatch(
                expectedBits: expectedBits,
                receivedBits: receivedBits
            )
        }
        let frameCount = try decoder.readCount(
            field: "frames",
            maximum: budget.maximumFrames
        )
        var frames: [SourcePhysicsReplayFrame] = []
        frames.reserveCapacity(frameCount)
        for _ in 0 ..< frameCount {
            frames.append(try decoder.readFrame())
        }
        guard decoder.remainingByteCount == 0 else {
            throw SourcePhysicsReplayError.trailingCanonicalBytes(
                count: decoder.remainingByteCount
            )
        }
        return frames
    }
}

private struct SourcePhysicsReplayEncoder {
    let budget: SourcePhysicsReplayBudget
    private(set) var bytes: [UInt8] = []

    mutating func write(_ frame: SourcePhysicsReplayFrame) throws {
        try writeCount(
            frame.commandBatch.commands.count,
            field: "frame.commands"
        )
        for command in frame.commandBatch.commands {
            try write(command)
        }
        try write(frame.environmentSnapshot)
        try writeCount(frame.events.count, field: "frame.events")
        for event in frame.events {
            try write(event)
        }
    }

    private mutating func write(_ command: SourcePhysicsCommand) throws {
        try writeUInt64(command.sequence)
        switch command.payload {
        case let .createBody(creation):
            try writeUInt8(0)
            try write(creation)
        case let .deleteBody(deletion):
            try writeUInt8(1)
            try write(deletion.bodyID)
        case let .mutateBody(mutation):
            try writeUInt8(4)
            try write(mutation)
        case let .simulate(simulate):
            try writeUInt8(2)
            try writeUInt64(simulate.simulationTick)
        case let .query(query):
            try writeUInt8(3)
            try write(query)
        }
    }

    private mutating func write(
        _ command: SourcePhysicsBodyMutationCommand
    ) throws {
        try write(command.bodyID)
        switch command.mutation {
        case .wake:
            try writeUInt8(0)
        case .sleep:
            try writeUInt8(1)
        case let .setMotionEnabled(enabled):
            try writeUInt8(2)
            try writeBool(enabled)
        case let .setGravityEnabled(enabled):
            try writeUInt8(3)
            try writeBool(enabled)
        case let .setCollisionEnabled(enabled):
            try writeUInt8(4)
            try writeBool(enabled)
        case let .setLinearVelocity(value):
            try writeUInt8(5)
            try write(value, field: "mutation.linearVelocity")
        case let .addLinearVelocity(value):
            try writeUInt8(6)
            try write(value, field: "mutation.linearVelocityDelta")
        case let .setAngularVelocity(value):
            try writeUInt8(7)
            try write(value, field: "mutation.angularVelocity")
        case let .addAngularVelocity(value):
            try writeUInt8(8)
            try write(value, field: "mutation.angularVelocityDelta")
        case let .applyCenterForce(value):
            try writeUInt8(9)
            try write(value, field: "mutation.centerForce")
        case let .applyCenterImpulse(value):
            try writeUInt8(10)
            try write(value, field: "mutation.centerImpulse")
        case let .applyForceOffset(force, worldPosition):
            try writeUInt8(11)
            try write(force, field: "mutation.offsetForce")
            try write(
                worldPosition,
                field: "mutation.offsetWorldPosition"
            )
        }
    }

    private mutating func write(
        _ creation: SourcePhysicsBodyCreationCommand
    ) throws {
        try write(creation.bodyID)
        try write(creation.shape)
        try write(creation.massProperties)
        try write(creation.transform)
        try write(creation.linearVelocity, field: "linearVelocity")
        try write(creation.angularVelocity, field: "angularVelocity")
        try write(creation.motionType)
        try writeNonnegativeInt(
            creation.materialIndex,
            field: "materialIndex"
        )
        try writeBool(creation.isGravityEnabled)
        try writeBool(creation.isCollisionEnabled)
        try writeBool(creation.startsAwake)
    }

    private mutating func write(_ query: SourcePhysicsQueryCommand) throws {
        try writeUInt64(query.queryID)
        switch query.geometry {
        case let .lineSegment(start, end):
            try writeUInt8(0)
            try write(start, field: "query.start")
            try write(end, field: "query.end")
        case let .sweptHull(start, end, minimums, maximums):
            try writeUInt8(1)
            try write(start, field: "query.start")
            try write(end, field: "query.end")
            try write(minimums, field: "query.minimums")
            try write(maximums, field: "query.maximums")
        }
        try writeUInt32(query.contentsMask)
        try writeUInt32(UInt32(bitPattern: query.collisionGroup))
        switch query.scope {
        case .everything: try writeUInt8(0)
        case .staticOnly: try writeUInt8(1)
        case .movingOnly: try writeUInt8(2)
        case .triggersOnly: try writeUInt8(3)
        case .staticAndMoving: try writeUInt8(4)
        }
        try writeCount(
            query.ignoredEntities.count,
            field: "query.ignoredEntities"
        )
        for identity in query.ignoredEntities {
            try write(identity)
        }
    }

    private mutating func write(
        _ snapshot: SourcePhysicsEnvironmentSnapshot
    ) throws {
        try writeUInt64(snapshot.simulationTick)
        if let sequence = snapshot.lastProcessedCommandSequence {
            try writeUInt8(1)
            try writeUInt64(sequence)
        } else {
            try writeUInt8(0)
        }
        try writeCount(snapshot.bodies.count, field: "snapshot.bodies")
        for body in snapshot.bodies {
            try write(body)
        }
        try writeCount(
            snapshot.queryResults.count,
            field: "snapshot.queryResults"
        )
        for result in snapshot.queryResults {
            try write(result)
        }
    }

    private mutating func write(_ body: SourcePhysicsBodySnapshot) throws {
        try write(body.bodyID)
        try write(body.shape)
        try write(body.massProperties)
        try write(body.transform)
        try write(body.linearVelocity, field: "body.linearVelocity")
        try write(body.angularVelocity, field: "body.angularVelocity")
        try write(body.motionType)
        try writeNonnegativeInt(
            body.materialIndex,
            field: "body.materialIndex"
        )
        try writeBool(body.isMotionEnabled)
        try writeBool(body.isGravityEnabled)
        try writeBool(body.isCollisionEnabled)
        try writeBool(body.isSleeping)
        try writeUInt64(body.simulationTick)
    }

    private mutating func write(
        _ result: SourcePhysicsQueryResultSnapshot
    ) throws {
        try writeUInt64(result.queryID)
        try writeUInt64(result.commandSequence)
        try writeUInt64(result.simulationTick)
        if let hit = result.hit {
            try writeUInt8(1)
            try write(hit)
        } else {
            try writeUInt8(0)
        }
    }

    private mutating func write(
        _ hit: SourcePhysicsQueryHitSnapshot
    ) throws {
        try write(hit.bodyID)
        try writeFloat(hit.fraction, field: "queryHit.fraction")
        try write(hit.position, field: "queryHit.position")
        try write(hit.normal, field: "queryHit.normal")
        if let materialIndex = hit.materialIndex {
            try writeUInt8(1)
            try writeNonnegativeInt(
                materialIndex,
                field: "queryHit.materialIndex"
            )
        } else {
            try writeUInt8(0)
        }
        try writeBool(hit.startedSolid)
        try writeBool(hit.allSolid)
    }

    private mutating func write(
        _ event: SourcePhysicsReplayEventSnapshot
    ) throws {
        switch event {
        case let .bodyCreated(commandSequence, bodyID):
            try writeUInt8(0)
            try writeUInt64(commandSequence)
            try write(bodyID)
        case let .bodyUpdated(deleteSequence, createSequence, bodyID):
            try writeUInt8(1)
            try writeUInt64(deleteSequence)
            try writeUInt64(createSequence)
            try write(bodyID)
        case let .bodyDeleted(commandSequence, bodyID):
            try writeUInt8(2)
            try writeUInt64(commandSequence)
            try write(bodyID)
        case let .bodyMutated(commandSequence, command):
            try writeUInt8(5)
            try writeUInt64(commandSequence)
            try write(command)
        case let .simulated(commandSequence, simulationTick):
            try writeUInt8(3)
            try writeUInt64(commandSequence)
            try writeUInt64(simulationTick)
        case let .queryCompleted(result):
            try writeUInt8(4)
            try write(result)
        }
    }

    private mutating func write(
        _ bodyID: SourcePhysicsBodyID
    ) throws {
        try write(bodyID.entityIdentity)
        try writeNonnegativeInt(bodyID.solidIndex, field: "solidIndex")
    }

    private mutating func write(
        _ identity: SourceCanonicalEntityIdentity
    ) throws {
        let entryIndex = identity.entryIndex
        guard entryIndex < SourceEntityConstants.numEntEntries else {
            throw SourcePhysicsReplayError
                .entityEntryIndexOutsideCanonicalRange(entryIndex)
        }
        try writeUInt32(identity.handle.rawValue)
    }

    private mutating func write(
        _ shape: SourcePhysicsShapeSnapshot
    ) throws {
        switch shape.topology {
        case .convexParts: try writeUInt8(0)
        case .triangleMesh: try writeUInt8(1)
        }
        try writeCount(shape.parts.count, field: "shape.parts")
        for part in shape.parts {
            try writeCount(part.vertices.count, field: "shape.vertices")
            for vertex in part.vertices {
                try write(vertex, field: "shape.vertex")
            }
            try writeCount(part.triangles.count, field: "shape.triangles")
            for triangle in part.triangles {
                try writeNonnegativeInt(triangle.first, field: "triangle.first")
                try writeNonnegativeInt(triangle.second, field: "triangle.second")
                try writeNonnegativeInt(triangle.third, field: "triangle.third")
                try writeNonnegativeInt(
                    triangle.materialIndex,
                    field: "triangle.materialIndex"
                )
            }
        }
    }

    private mutating func write(
        _ mass: SourcePhysicsMassProperties
    ) throws {
        try writeFloat(mass.massKilograms, field: "massKilograms")
        try write(mass.principalInertia, field: "principalInertia")
    }

    private mutating func write(
        _ transform: SourceEntityTransform
    ) throws {
        try write(transform.origin, field: "transform.origin")
        try writeFloat(transform.angles.pitch, field: "transform.angles.pitch")
        try writeFloat(transform.angles.yaw, field: "transform.angles.yaw")
        try writeFloat(transform.angles.roll, field: "transform.angles.roll")
    }

    private mutating func write(
        _ vector: SourceVector3,
        field: String
    ) throws {
        try writeFloat(vector.x, field: "\(field).x")
        try writeFloat(vector.y, field: "\(field).y")
        try writeFloat(vector.z, field: "\(field).z")
    }

    private mutating func write(
        _ motionType: SourcePhysicsMotionType
    ) throws {
        switch motionType {
        case .staticBody: try writeUInt8(0)
        case .dynamicBody: try writeUInt8(1)
        case .kinematicBody: try writeUInt8(2)
        }
    }

    mutating func writeCount(_ value: Int, field: String) throws {
        guard value >= 0, UInt64(value) <= UInt64(UInt32.max) else {
            throw SourcePhysicsReplayError.integerOutsideCanonicalRange(
                field: field,
                value: value
            )
        }
        try writeUInt32(UInt32(value))
    }

    private mutating func writeNonnegativeInt(
        _ value: Int,
        field: String
    ) throws {
        guard value >= 0, UInt64(value) <= UInt64(UInt32.max) else {
            throw SourcePhysicsReplayError.integerOutsideCanonicalRange(
                field: field,
                value: value
            )
        }
        try writeUInt32(UInt32(value))
    }

    private mutating func writeBool(_ value: Bool) throws {
        try writeUInt8(value ? 1 : 0)
    }

    mutating func writeFloat(_ value: Float, field: String) throws {
        guard value.isFinite else {
            throw SourcePhysicsReplayError.nonFinite(field: field)
        }
        try writeUInt32(sourcePhysicsReplayCanonicalFloatBits(value))
    }

    mutating func writeUInt8(_ value: UInt8) throws {
        try ensureCapacity(additional: 1)
        bytes.append(value)
    }

    mutating func writeUInt16(_ value: UInt16) throws {
        try ensureCapacity(additional: 2)
        bytes.append(UInt8(truncatingIfNeeded: value))
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
    }

    mutating func writeUInt32(_ value: UInt32) throws {
        try ensureCapacity(additional: 4)
        for shift in stride(from: 0, through: 24, by: 8) {
            bytes.append(UInt8(truncatingIfNeeded: value >> UInt32(shift)))
        }
    }

    mutating func writeUInt64(_ value: UInt64) throws {
        try ensureCapacity(additional: 8)
        for shift in stride(from: 0, through: 56, by: 8) {
            bytes.append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
        }
    }

    mutating func writeBytes(_ values: [UInt8]) throws {
        try ensureCapacity(additional: values.count)
        bytes.append(contentsOf: values)
    }

    private func ensureCapacity(additional: Int) throws {
        guard
            additional >= 0,
            additional <= budget.maximumBytes,
            bytes.count <= budget.maximumBytes - additional
        else {
            let attempted = additional > Int.max - bytes.count
                ? Int.max
                : bytes.count + additional
            throw SourcePhysicsReplayError.budgetExceeded(
                field: "bytes",
                limit: budget.maximumBytes,
                attempted: attempted
            )
        }
    }
}

private struct SourcePhysicsReplayDecoder {
    let bytes: [UInt8]
    let budget: SourcePhysicsReplayBudget
    private var offset = 0
    private var counter = SourcePhysicsReplayBudgetCounter()

    init(bytes: [UInt8], budget: SourcePhysicsReplayBudget) {
        self.bytes = bytes
        self.budget = budget
    }

    var remainingByteCount: Int { bytes.count - offset }

    mutating func readFrame() throws -> SourcePhysicsReplayFrame {
        try counter.addFrame(budget: budget)
        let commandCount = try readCount(
            field: "frame.commands",
            maximum: budget.maximumCommands
        )
        try counter.addCommands(commandCount, budget: budget)
        var commands: [SourcePhysicsCommand] = []
        commands.reserveCapacity(commandCount)
        for _ in 0 ..< commandCount {
            commands.append(try readCommand())
        }
        let batch = try SourcePhysicsCommandBatch(commands: commands)
        let snapshot = try readEnvironmentSnapshot()
        let eventCount = try readCount(
            field: "frame.events",
            maximum: budget.maximumEvents
        )
        try counter.addEvents(eventCount, budget: budget)
        var events: [SourcePhysicsReplayEventSnapshot] = []
        events.reserveCapacity(eventCount)
        for _ in 0 ..< eventCount {
            events.append(try readEvent())
        }
        return SourcePhysicsReplayFrame(
            commandBatch: batch,
            environmentSnapshot: snapshot,
            events: events
        )
    }

    private mutating func readCommand() throws -> SourcePhysicsCommand {
        let sequence = try readUInt64()
        let tag = try readUInt8()
        let payload: SourcePhysicsCommandPayload
        switch tag {
        case 0:
            payload = .createBody(try readCreation())
        case 1:
            payload = .deleteBody(SourcePhysicsBodyDeletionCommand(
                bodyID: try readBodyID()
            ))
        case 2:
            payload = .simulate(SourcePhysicsSimulateCommand(
                simulationTick: try readUInt64()
            ))
        case 3:
            payload = .query(try readQuery())
        case 4:
            payload = .mutateBody(try readBodyMutation())
        default:
            throw SourcePhysicsReplayError.invalidTag(
                field: "command",
                value: tag
            )
        }
        return SourcePhysicsCommand(sequence: sequence, payload: payload)
    }

    private mutating func readBodyMutation() throws
        -> SourcePhysicsBodyMutationCommand
    {
        let bodyID = try readBodyID()
        let tag = try readUInt8()
        let mutation: SourcePhysicsBodyMutation
        switch tag {
        case 0:
            mutation = .wake
        case 1:
            mutation = .sleep
        case 2:
            mutation = .setMotionEnabled(try readBool(
                field: "mutation.motionEnabled"
            ))
        case 3:
            mutation = .setGravityEnabled(try readBool(
                field: "mutation.gravityEnabled"
            ))
        case 4:
            mutation = .setCollisionEnabled(try readBool(
                field: "mutation.collisionEnabled"
            ))
        case 5:
            mutation = .setLinearVelocity(try readVector(
                field: "mutation.linearVelocity"
            ))
        case 6:
            mutation = .addLinearVelocity(try readVector(
                field: "mutation.linearVelocityDelta"
            ))
        case 7:
            mutation = .setAngularVelocity(try readVector(
                field: "mutation.angularVelocity"
            ))
        case 8:
            mutation = .addAngularVelocity(try readVector(
                field: "mutation.angularVelocityDelta"
            ))
        case 9:
            mutation = .applyCenterForce(try readVector(
                field: "mutation.centerForce"
            ))
        case 10:
            mutation = .applyCenterImpulse(try readVector(
                field: "mutation.centerImpulse"
            ))
        case 11:
            mutation = .applyForceOffset(
                force: try readVector(field: "mutation.offsetForce"),
                worldPosition: try readVector(
                    field: "mutation.offsetWorldPosition"
                )
            )
        default:
            throw SourcePhysicsReplayError.invalidTag(
                field: "bodyMutation",
                value: tag
            )
        }
        return try SourcePhysicsBodyMutationCommand(
            bodyID: bodyID,
            mutation: mutation
        )
    }

    private mutating func readCreation() throws
        -> SourcePhysicsBodyCreationCommand
    {
        try SourcePhysicsBodyCreationCommand(
            bodyID: readBodyID(),
            shape: readShape(),
            massProperties: readMassProperties(),
            transform: readTransform(),
            linearVelocity: readVector(field: "linearVelocity"),
            angularVelocity: readVector(field: "angularVelocity"),
            motionType: readMotionType(),
            materialIndex: readNonnegativeInt(field: "materialIndex"),
            isGravityEnabled: readBool(field: "isGravityEnabled"),
            isCollisionEnabled: readBool(field: "isCollisionEnabled"),
            startsAwake: readBool(field: "startsAwake")
        )
    }

    private mutating func readQuery() throws -> SourcePhysicsQueryCommand {
        let queryID = try readUInt64()
        let geometryTag = try readUInt8()
        let geometry: SourcePhysicsQueryGeometry
        switch geometryTag {
        case 0:
            geometry = .lineSegment(
                start: try readVector(field: "query.start"),
                end: try readVector(field: "query.end")
            )
        case 1:
            geometry = .sweptHull(
                start: try readVector(field: "query.start"),
                end: try readVector(field: "query.end"),
                minimums: try readVector(field: "query.minimums"),
                maximums: try readVector(field: "query.maximums")
            )
        default:
            throw SourcePhysicsReplayError.invalidTag(
                field: "query.geometry",
                value: geometryTag
            )
        }
        let contentsMask = try readUInt32()
        let collisionGroup = Int32(bitPattern: try readUInt32())
        let scopeTag = try readUInt8()
        let scope: SourcePhysicsQueryScope
        switch scopeTag {
        case 0: scope = .everything
        case 1: scope = .staticOnly
        case 2: scope = .movingOnly
        case 3: scope = .triggersOnly
        case 4: scope = .staticAndMoving
        default:
            throw SourcePhysicsReplayError.invalidTag(
                field: "query.scope",
                value: scopeTag
            )
        }
        let ignoredCount = try readCount(
            field: "query.ignoredEntities",
            maximum: budget.maximumIgnoredEntityReferences
        )
        try counter.addIgnoredEntities(ignoredCount, budget: budget)
        var ignored: [SourceCanonicalEntityIdentity] = []
        ignored.reserveCapacity(ignoredCount)
        for _ in 0 ..< ignoredCount {
            ignored.append(try readIdentity())
        }
        return try SourcePhysicsQueryCommand(
            queryID: queryID,
            geometry: geometry,
            contentsMask: contentsMask,
            collisionGroup: collisionGroup,
            scope: scope,
            ignoredEntities: ignored
        )
    }

    private mutating func readEnvironmentSnapshot() throws
        -> SourcePhysicsEnvironmentSnapshot
    {
        let simulationTick = try readUInt64()
        let sequence: UInt64?
        let sequenceTag = try readUInt8()
        switch sequenceTag {
        case 0: sequence = nil
        case 1: sequence = try readUInt64()
        default:
            throw SourcePhysicsReplayError.invalidTag(
                field: "snapshot.lastProcessedCommandSequence",
                value: sequenceTag
            )
        }
        let bodyCount = try readCount(
            field: "snapshot.bodies",
            maximum: budget.maximumBodySnapshots
        )
        try counter.addBodies(bodyCount, budget: budget)
        var bodies: [SourcePhysicsBodySnapshot] = []
        bodies.reserveCapacity(bodyCount)
        for _ in 0 ..< bodyCount {
            bodies.append(try readBodySnapshot())
        }
        let queryCount = try readCount(
            field: "snapshot.queryResults",
            maximum: budget.maximumQueryResults
        )
        try counter.addQueryResults(queryCount, budget: budget)
        var results: [SourcePhysicsQueryResultSnapshot] = []
        results.reserveCapacity(queryCount)
        for _ in 0 ..< queryCount {
            results.append(try readQueryResult())
        }
        return try SourcePhysicsEnvironmentSnapshot(
            simulationTick: simulationTick,
            lastProcessedCommandSequence: sequence,
            bodies: bodies,
            queryResults: results
        )
    }

    private mutating func readBodySnapshot() throws
        -> SourcePhysicsBodySnapshot
    {
        try SourcePhysicsBodySnapshot(
            bodyID: readBodyID(),
            shape: readShape(),
            massProperties: readMassProperties(),
            transform: readTransform(),
            linearVelocity: readVector(field: "body.linearVelocity"),
            angularVelocity: readVector(field: "body.angularVelocity"),
            motionType: readMotionType(),
            materialIndex: readNonnegativeInt(field: "body.materialIndex"),
            isMotionEnabled: readBool(field: "body.isMotionEnabled"),
            isGravityEnabled: readBool(field: "body.isGravityEnabled"),
            isCollisionEnabled: readBool(field: "body.isCollisionEnabled"),
            isSleeping: readBool(field: "body.isSleeping"),
            simulationTick: readUInt64()
        )
    }

    private mutating func readQueryResult() throws
        -> SourcePhysicsQueryResultSnapshot
    {
        let queryID = try readUInt64()
        let commandSequence = try readUInt64()
        let simulationTick = try readUInt64()
        let hit: SourcePhysicsQueryHitSnapshot?
        let hitTag = try readUInt8()
        switch hitTag {
        case 0: hit = nil
        case 1: hit = try readQueryHit()
        default:
            throw SourcePhysicsReplayError.invalidTag(
                field: "queryResult.hit",
                value: hitTag
            )
        }
        return SourcePhysicsQueryResultSnapshot(
            queryID: queryID,
            commandSequence: commandSequence,
            simulationTick: simulationTick,
            hit: hit
        )
    }

    private mutating func readQueryHit() throws
        -> SourcePhysicsQueryHitSnapshot
    {
        let bodyID = try readBodyID()
        let fraction = try readFloat(field: "queryHit.fraction")
        let position = try readVector(field: "queryHit.position")
        let normal = try readVector(field: "queryHit.normal")
        let materialIndex: Int?
        let materialTag = try readUInt8()
        switch materialTag {
        case 0: materialIndex = nil
        case 1:
            materialIndex = try readNonnegativeInt(
                field: "queryHit.materialIndex"
            )
        default:
            throw SourcePhysicsReplayError.invalidTag(
                field: "queryHit.materialIndex.present",
                value: materialTag
            )
        }
        return try SourcePhysicsQueryHitSnapshot(
            bodyID: bodyID,
            fraction: fraction,
            position: position,
            normal: normal,
            materialIndex: materialIndex,
            startedSolid: readBool(field: "queryHit.startedSolid"),
            allSolid: readBool(field: "queryHit.allSolid")
        )
    }

    private mutating func readEvent() throws
        -> SourcePhysicsReplayEventSnapshot
    {
        let tag = try readUInt8()
        switch tag {
        case 0:
            return .bodyCreated(
                commandSequence: try readUInt64(),
                bodyID: try readBodyID()
            )
        case 1:
            return .bodyUpdated(
                deleteCommandSequence: try readUInt64(),
                createCommandSequence: try readUInt64(),
                bodyID: try readBodyID()
            )
        case 2:
            return .bodyDeleted(
                commandSequence: try readUInt64(),
                bodyID: try readBodyID()
            )
        case 3:
            return .simulated(
                commandSequence: try readUInt64(),
                simulationTick: try readUInt64()
            )
        case 4:
            return .queryCompleted(try readQueryResult())
        case 5:
            return .bodyMutated(
                commandSequence: try readUInt64(),
                command: try readBodyMutation()
            )
        default:
            throw SourcePhysicsReplayError.invalidTag(
                field: "event",
                value: tag
            )
        }
    }

    private mutating func readBodyID() throws -> SourcePhysicsBodyID {
        try SourcePhysicsBodyID(
            entityIdentity: readIdentity(),
            solidIndex: readNonnegativeInt(field: "solidIndex")
        )
    }

    private mutating func readIdentity() throws
        -> SourceCanonicalEntityIdentity
    {
        let rawValue = try readUInt32()
        let handle = SourceBaseHandle.unsafeFromIndex(rawValue)
        guard handle.isValid else {
            throw SourcePhysicsReplayError.invalidEntityHandle(rawValue)
        }
        guard handle.entryIndex < SourceEntityConstants.numEntEntries else {
            throw SourcePhysicsReplayError
                .entityEntryIndexOutsideCanonicalRange(handle.entryIndex)
        }
        return SourceCanonicalEntityIdentity(handle: handle)
    }

    private mutating func readShape() throws -> SourcePhysicsShapeSnapshot {
        let topologyTag = try readUInt8()
        let topology: SourcePhysicsShapeTopology
        switch topologyTag {
        case 0: topology = .convexParts
        case 1: topology = .triangleMesh
        default:
            throw SourcePhysicsReplayError.invalidTag(
                field: "shape.topology",
                value: topologyTag
            )
        }
        let partCount = try readCount(
            field: "shape.parts",
            maximum: budget.maximumMeshParts
        )
        var parts: [SourcePhysicsMeshPartSnapshot] = []
        parts.reserveCapacity(partCount)
        for _ in 0 ..< partCount {
            let vertexCount = try readCount(
                field: "shape.vertices",
                maximum: budget.maximumVertices
            )
            var vertices: [SourceVector3] = []
            vertices.reserveCapacity(vertexCount)
            for _ in 0 ..< vertexCount {
                vertices.append(try readVector(field: "shape.vertex"))
            }
            let triangleCount = try readCount(
                field: "shape.triangles",
                maximum: budget.maximumTriangles
            )
            var triangles: [SourcePhysicsIndexedTriangle] = []
            triangles.reserveCapacity(triangleCount)
            for _ in 0 ..< triangleCount {
                triangles.append(try SourcePhysicsIndexedTriangle(
                    first: readNonnegativeInt(field: "triangle.first"),
                    second: readNonnegativeInt(field: "triangle.second"),
                    third: readNonnegativeInt(field: "triangle.third"),
                    materialIndex: readNonnegativeInt(
                        field: "triangle.materialIndex"
                    )
                ))
            }
            parts.append(try SourcePhysicsMeshPartSnapshot(
                vertices: vertices,
                triangles: triangles
            ))
        }
        let shape = try SourcePhysicsShapeSnapshot(
            topology: topology,
            parts: parts
        )
        try counter.addShape(shape, budget: budget)
        return shape
    }

    private mutating func readMassProperties() throws
        -> SourcePhysicsMassProperties
    {
        try SourcePhysicsMassProperties(
            massKilograms: readFloat(field: "massKilograms"),
            principalInertia: readVector(field: "principalInertia")
        )
    }

    private mutating func readTransform() throws -> SourceEntityTransform {
        SourceEntityTransform(
            origin: try readVector(field: "transform.origin"),
            angles: SourceQAngle(
                pitch: try readFloat(field: "transform.angles.pitch"),
                yaw: try readFloat(field: "transform.angles.yaw"),
                roll: try readFloat(field: "transform.angles.roll")
            )
        )
    }

    private mutating func readVector(field: String) throws -> SourceVector3 {
        SourceVector3(
            try readFloat(field: "\(field).x"),
            try readFloat(field: "\(field).y"),
            try readFloat(field: "\(field).z")
        )
    }

    private mutating func readMotionType() throws -> SourcePhysicsMotionType {
        let tag = try readUInt8()
        switch tag {
        case 0: return .staticBody
        case 1: return .dynamicBody
        case 2: return .kinematicBody
        default:
            throw SourcePhysicsReplayError.invalidTag(
                field: "motionType",
                value: tag
            )
        }
    }

    mutating func readCount(field: String, maximum: Int) throws -> Int {
        let value = try readUInt32()
        guard UInt64(value) <= UInt64(maximum) else {
            throw SourcePhysicsReplayError.budgetExceeded(
                field: field,
                limit: maximum,
                attempted: Int(clamping: UInt64(value))
            )
        }
        return Int(value)
    }

    private mutating func readNonnegativeInt(field: String) throws -> Int {
        let value = try readUInt32()
        guard UInt64(value) <= UInt64(Int.max) else {
            throw SourcePhysicsReplayError.integerOutsideCanonicalRange(
                field: field,
                value: Int.max
            )
        }
        return Int(value)
    }

    private mutating func readBool(field: String) throws -> Bool {
        let value = try readUInt8()
        switch value {
        case 0: return false
        case 1: return true
        default:
            throw SourcePhysicsReplayError.invalidBoolean(
                field: field,
                value: value
            )
        }
    }

    mutating func readFloat(field: String) throws -> Float {
        let value = Float(bitPattern: try readUInt32())
        guard value.isFinite else {
            throw SourcePhysicsReplayError.nonFinite(field: field)
        }
        return value
    }

    mutating func readUInt8() throws -> UInt8 {
        guard offset < bytes.count else {
            throw SourcePhysicsReplayError.truncatedCanonicalLog(offset: offset)
        }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func readUInt16() throws -> UInt16 {
        let values = try readBytes(count: 2)
        return UInt16(values[0]) | (UInt16(values[1]) << 8)
    }

    mutating func readUInt32() throws -> UInt32 {
        let values = try readBytes(count: 4)
        var result: UInt32 = 0
        for (index, value) in values.enumerated() {
            result |= UInt32(value) << UInt32(index * 8)
        }
        return result
    }

    mutating func readUInt64() throws -> UInt64 {
        let values = try readBytes(count: 8)
        var result: UInt64 = 0
        for (index, value) in values.enumerated() {
            result |= UInt64(value) << UInt64(index * 8)
        }
        return result
    }

    mutating func readBytes(count: Int) throws -> [UInt8] {
        guard count >= 0, count <= remainingByteCount else {
            throw SourcePhysicsReplayError.truncatedCanonicalLog(offset: offset)
        }
        let end = offset + count
        defer { offset = end }
        return Array(bytes[offset ..< end])
    }
}

private func sourcePhysicsReplayCanonicalFloatBits(_ value: Float) -> UInt32 {
    value == 0 ? 0 : value.bitPattern
}
