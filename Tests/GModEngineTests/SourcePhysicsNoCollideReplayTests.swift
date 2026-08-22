import Testing
@testable import GModEngine

@Suite("Source no-collide deterministic replay")
struct SourcePhysicsNoCollideReplayTests {
    @Test("command, snapshot, event, and deletion round-trip in replay v10")
    func canonicalRoundTripRetainsFullAuthoredBodyIDs() throws {
        // Deliberately author the endpoints in descending handle order and use
        // nonzero solid indices. No-collide matching is symmetric, but the
        // replay contract must not reorder or truncate either body identity.
        let authoredFirst = try makeBodyID(
            entry: 502,
            serial: 17,
            solidIndex: 4
        )
        let authoredSecond = try makeBodyID(
            entry: 501,
            serial: 23,
            solidIndex: 9
        )
        let constraintID = try SourcePhysicsConstraintID(rawValue: 0x1_0203)
        let creation = try SourcePhysicsNoCollideConstraintCreationCommand(
            constraintID: constraintID,
            firstBodyID: authoredFirst,
            secondBodyID: authoredSecond
        )
        let batches = try makeBatches(
            firstBodyID: authoredFirst,
            secondBodyID: authoredSecond,
            creation: creation
        )
        let harness = SourcePhysicsDeterministicReplayHarness()

        let log = try harness.record(
            commandBatches: batches,
            using: try makeEnvironment()
        )

        #expect(SourcePhysicsReplayLog.formatVersion == 10)
        #expect(Array(log.canonicalBytes[4 ... 5]) == [10, 0])
        #expect(log.frames.count == 2)
        #expect(log.frames[0].environmentSnapshot.noCollideConstraints == [
            SourcePhysicsNoCollideConstraintSnapshot(
                creation: creation,
                simulationTick: 1
            ),
        ])
        #expect(log.frames[0].events[2] == .noCollideConstraintCreated(
            commandSequence: 3,
            command: creation
        ))
        #expect(log.frames[1].environmentSnapshot.noCollideConstraints.isEmpty)
        #expect(log.frames[1].events[0] == .constraintDeleted(
            commandSequence: 5,
            constraintID: constraintID
        ))

        let decoded = try SourcePhysicsReplayLog(
            canonicalBytes: log.canonicalBytes
        )
        #expect(decoded == log)
        guard case let .createNoCollideConstraint(decodedCreation) =
                decoded.frames[0].commandBatch.commands[2].payload else {
            Issue.record("decoded replay lost the no-collide command")
            return
        }
        #expect(decodedCreation.firstBodyID == authoredFirst)
        #expect(decodedCreation.secondBodyID == authoredSecond)
        #expect(decodedCreation.firstBodyID.solidIndex == 4)
        #expect(decodedCreation.secondBodyID.solidIndex == 9)

        let comparison = try harness.replay(
            decoded,
            using: try makeEnvironment()
        )
        #expect(comparison.frameCount == 2)
        #expect(comparison.canonicalByteCount == log.canonicalBytes.count)
    }

    @Test("symmetric solver pairs retain authored order in canonical bytes")
    func authoredEndpointOrderIsNotCanonicalizedAway() throws {
        let first = try makeBodyID(entry: 511, serial: 8, solidIndex: 2)
        let second = try makeBodyID(entry: 512, serial: 13, solidIndex: 7)
        let constraintID = try SourcePhysicsConstraintID(rawValue: 0x2_0304)
        let forward = try SourcePhysicsNoCollideConstraintCreationCommand(
            constraintID: constraintID,
            firstBodyID: first,
            secondBodyID: second
        )
        let reversed = try SourcePhysicsNoCollideConstraintCreationCommand(
            constraintID: constraintID,
            firstBodyID: second,
            secondBodyID: first
        )
        let harness = SourcePhysicsDeterministicReplayHarness()
        let forwardLog = try harness.record(
            commandBatches: [makeCreationBatch(
                firstBodyID: first,
                secondBodyID: second,
                creation: forward
            )],
            using: try makeEnvironment()
        )
        let reversedLog = try harness.record(
            commandBatches: [makeCreationBatch(
                firstBodyID: first,
                secondBodyID: second,
                creation: reversed
            )],
            using: try makeEnvironment()
        )

        #expect(forwardLog.canonicalBytes != reversedLog.canonicalBytes)
        let decodedReversed = try SourcePhysicsReplayLog(
            canonicalBytes: reversedLog.canonicalBytes
        )
        let snapshot = try #require(
            decodedReversed.frames[0].environmentSnapshot
                .noCollideConstraints.first
        )
        #expect(snapshot.creation.firstBodyID == second)
        #expect(snapshot.creation.secondBodyID == first)

        var priorVersionBytes = forwardLog.canonicalBytes
        priorVersionBytes[4] = 9
        priorVersionBytes[5] = 0
        #expect(throws: SourcePhysicsReplayError.unsupportedFormatVersion(9)) {
            _ = try SourcePhysicsReplayLog(canonicalBytes: priorVersionBytes)
        }
    }

    private func makeBatches(
        firstBodyID: SourcePhysicsBodyID,
        secondBodyID: SourcePhysicsBodyID,
        creation: SourcePhysicsNoCollideConstraintCreationCommand
    ) throws -> [SourcePhysicsCommandBatch] {
        [
            try makeCreationBatch(
                firstBodyID: firstBodyID,
                secondBodyID: secondBodyID,
                creation: creation
            ),
            try SourcePhysicsCommandBatch(commands: [
                SourcePhysicsCommand(
                    sequence: 5,
                    payload: .deleteConstraint(.init(
                        constraintID: creation.constraintID
                    ))
                ),
                SourcePhysicsCommand(
                    sequence: 6,
                    payload: .simulate(.init(simulationTick: 2))
                ),
            ]),
        ]
    }

    private func makeCreationBatch(
        firstBodyID: SourcePhysicsBodyID,
        secondBodyID: SourcePhysicsBodyID,
        creation: SourcePhysicsNoCollideConstraintCreationCommand
    ) throws -> SourcePhysicsCommandBatch {
        try SourcePhysicsCommandBatch(commands: [
            SourcePhysicsCommand(
                sequence: 1,
                payload: .createBody(try makeBodyCreation(firstBodyID))
            ),
            SourcePhysicsCommand(
                sequence: 2,
                payload: .createBody(try makeBodyCreation(secondBodyID))
            ),
            SourcePhysicsCommand(
                sequence: 3,
                payload: .createNoCollideConstraint(creation)
            ),
            SourcePhysicsCommand(
                sequence: 4,
                payload: .simulate(.init(simulationTick: 1))
            ),
        ])
    }

    private func makeEnvironment() throws
        -> SourceDeterministicPhysicsEnvironment
    {
        SourceDeterministicPhysicsEnvironment(
            configuration: try .init(gravity: .zero)
        )
    }

    private func makeBodyID(
        entry: Int,
        serial: Int,
        solidIndex: Int
    ) throws -> SourcePhysicsBodyID {
        try SourcePhysicsBodyID(
            entityIdentity: SourceCanonicalEntityIdentity(
                handle: SourceBaseHandle(
                    entryIndex: entry,
                    serialNumber: serial
                )
            ),
            solidIndex: solidIndex
        )
    }

    private func makeBodyCreation(
        _ bodyID: SourcePhysicsBodyID
    ) throws -> SourcePhysicsBodyCreationCommand {
        try SourcePhysicsBodyCreationCommand(
            bodyID: bodyID,
            shape: makeShape(),
            massProperties: SourcePhysicsMassProperties(
                massKilograms: 8,
                principalInertia: SourceVector3(4, 4, 4)
            ),
            transform: .identity,
            linearVelocity: .zero,
            angularVelocity: .zero,
            damping: .zero,
            motionType: .dynamicBody,
            materialIndex: 0,
            isGravityEnabled: false,
            isCollisionEnabled: false,
            startsAwake: true
        )
    }

    private func makeShape() throws -> SourcePhysicsShapeSnapshot {
        try SourcePhysicsShapeSnapshot(
            topology: .convexParts,
            parts: [SourcePhysicsMeshPartSnapshot(
                vertices: [
                    SourceVector3(-1, -1, -1),
                    SourceVector3(1, -1, -1),
                    SourceVector3(0, 1, -1),
                    SourceVector3(0, 0, 1),
                ],
                triangles: [
                    try SourcePhysicsIndexedTriangle(
                        first: 0,
                        second: 2,
                        third: 1,
                        materialIndex: 0
                    ),
                    try SourcePhysicsIndexedTriangle(
                        first: 0,
                        second: 1,
                        third: 3,
                        materialIndex: 0
                    ),
                    try SourcePhysicsIndexedTriangle(
                        first: 1,
                        second: 2,
                        third: 3,
                        materialIndex: 0
                    ),
                    try SourcePhysicsIndexedTriangle(
                        first: 2,
                        second: 0,
                        third: 3,
                        materialIndex: 0
                    ),
                ]
            )]
        )
    }
}
