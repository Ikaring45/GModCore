import Testing
@testable import GModEngine

@Suite("Deterministic Source fixed physics constraints")
struct SourcePhysicsFixedConstraintTests {
    @Test("contract retains full body identities and rejects invalid IDs")
    func contractValidation() throws {
        #expect(throws: SourcePhysicsContractError.invalidConstraintID(0)) {
            _ = try SourcePhysicsConstraintID(rawValue: 0)
        }

        let body = try makeBodyID(entry: 100, serial: 4)
        let constraintID = try SourcePhysicsConstraintID(rawValue: 41)
        #expect(throws: SourcePhysicsContractError.constraintReferencesSameBody(
            body
        )) {
            _ = try SourcePhysicsFixedConstraintCreationCommand(
                constraintID: constraintID,
                referenceBodyID: body,
                attachedBodyID: body
            )
        }

        let otherGeneration = try makeBodyID(entry: 100, serial: 5)
        let command = try SourcePhysicsFixedConstraintCreationCommand(
            constraintID: constraintID,
            referenceBodyID: body,
            attachedBodyID: otherGeneration
        )
        #expect(command.referenceBodyID.entityIdentity.handle.rawValue !=
            command.attachedBodyID.entityIdentity.handle.rawValue)
        #expect(command.referenceBodyID.solidIndex == 0)
        #expect(command.attachedBodyID.solidIndex == 0)
    }

    @Test("two dynamic bodies retain one relative pose across fixed ticks")
    func dynamicPairMovesAsOneBody() throws {
        let environment = SourceDeterministicPhysicsEnvironment(
            configuration: try .init(gravity: .zero)
        )
        let referenceID = try makeBodyID(entry: 101, serial: 7)
        let attachedID = try makeBodyID(entry: 102, serial: 7)
        let constraintID = try SourcePhysicsConstraintID(rawValue: 1)
        let relativeOrigin = SourceVector3(10, 2, 0)
        let relativeAngles = SourceQAngle(pitch: 5, yaw: 30, roll: -7)

        var snapshot = try environment.execute(
            SourcePhysicsCommandBatch(commands: [
                SourcePhysicsCommand(
                    sequence: 1,
                    payload: .createBody(try makeCreation(
                        bodyID: referenceID,
                        origin: .zero,
                        angles: .zero,
                        linearVelocity: SourceVector3(100, 0, 0),
                        angularVelocity: SourceVector3(0, 60, 0)
                    ))
                ),
                SourcePhysicsCommand(
                    sequence: 2,
                    payload: .createBody(try makeCreation(
                        bodyID: attachedID,
                        origin: relativeOrigin,
                        angles: relativeAngles,
                        linearVelocity: .zero,
                        angularVelocity: .zero
                    ))
                ),
                SourcePhysicsCommand(
                    sequence: 3,
                    payload: .createFixedConstraint(
                        try SourcePhysicsFixedConstraintCreationCommand(
                            constraintID: constraintID,
                            referenceBodyID: referenceID,
                            attachedBodyID: attachedID
                        )
                    )
                ),
                SourcePhysicsCommand(
                    sequence: 4,
                    payload: .simulate(.init(simulationTick: 1))
                ),
            ])
        )

        let published = try #require(snapshot.fixedConstraints.first)
        #expect(published.constraintID == constraintID)
        #expect(published.referenceBodyID == referenceID)
        #expect(published.attachedBodyID == attachedID)
        expectVectorClose(
            published.attachedPoseInReference.origin,
            relativeOrigin,
            tolerance: 0.0001
        )
        expectBasisClose(
            published.attachedPoseInReference.angles,
            relativeAngles,
            tolerance: 0.0001
        )
        #expect(published.simulationTick == 1)

        var bodies = Dictionary(
            uniqueKeysWithValues: snapshot.bodies.map { ($0.bodyID, $0) }
        )
        var reference = try #require(bodies[referenceID])
        var attached = try #require(bodies[attachedID])
        #expect(reference.transform.origin.x > 0)
        #expect(attached.transform.origin.x > relativeOrigin.x)
        #expect(reference.angularVelocity.y > 0)
        #expect(attached.angularVelocity.y > 0)
        expectRelativePose(
            reference: reference.transform,
            attached: attached.transform,
            expected: published.attachedPoseInReference,
            tolerance: 0.0002
        )

        snapshot = try environment.execute(
            SourcePhysicsCommandBatch(commands: [
                SourcePhysicsCommand(
                    sequence: 5,
                    payload: .simulate(.init(simulationTick: 2))
                ),
            ])
        )
        bodies = Dictionary(
            uniqueKeysWithValues: snapshot.bodies.map { ($0.bodyID, $0) }
        )
        reference = try #require(bodies[referenceID])
        attached = try #require(bodies[attachedID])
        expectRelativePose(
            reference: reference.transform,
            attached: attached.transform,
            expected: published.attachedPoseInReference,
            tolerance: 0.0002
        )
        #expect(snapshot.fixedConstraints.first?.simulationTick == 2)
    }

    @Test("constraint FIFO rolls back and rejects retired or stale endpoints")
    func lifecycleRollbackAndGenerationSafety() throws {
        let environment = SourceDeterministicPhysicsEnvironment(
            configuration: try .init(gravity: .zero)
        )
        let referenceID = try makeBodyID(entry: 110, serial: 1)
        let oldAttachedID = try makeBodyID(entry: 111, serial: 1)
        let newAttachedID = try makeBodyID(entry: 111, serial: 2)
        let constraintID = try SourcePhysicsConstraintID(rawValue: 9)
        let creation = try SourcePhysicsFixedConstraintCreationCommand(
            constraintID: constraintID,
            referenceBodyID: referenceID,
            attachedBodyID: oldAttachedID
        )

        _ = try environment.execute(SourcePhysicsCommandBatch(commands: [
            SourcePhysicsCommand(
                sequence: 1,
                payload: .createBody(try makeCreation(
                    bodyID: referenceID,
                    origin: .zero
                ))
            ),
            SourcePhysicsCommand(
                sequence: 2,
                payload: .createBody(try makeCreation(
                    bodyID: oldAttachedID,
                    origin: SourceVector3(8, 0, 0)
                ))
            ),
        ]))

        #expect(throws:
            SourceDeterministicPhysicsEnvironment.Error.bodyHasLiveConstraint(
                bodyID: oldAttachedID,
                constraintID: constraintID
            )
        ) {
            _ = try environment.execute(SourcePhysicsCommandBatch(commands: [
                SourcePhysicsCommand(
                    sequence: 3,
                    payload: .createFixedConstraint(creation)
                ),
                SourcePhysicsCommand(
                    sequence: 4,
                    payload: .deleteBody(.init(bodyID: oldAttachedID))
                ),
            ]))
        }

        var snapshot = try environment.execute(
            SourcePhysicsCommandBatch(commands: [
                SourcePhysicsCommand(
                    sequence: 3,
                    payload: .createFixedConstraint(creation)
                ),
                SourcePhysicsCommand(
                    sequence: 4,
                    payload: .simulate(.init(simulationTick: 1))
                ),
            ])
        )
        #expect(snapshot.fixedConstraints.map(\.constraintID) == [constraintID])

        snapshot = try environment.execute(
            SourcePhysicsCommandBatch(commands: [
                SourcePhysicsCommand(
                    sequence: 5,
                    payload: .deleteConstraint(.init(
                        constraintID: constraintID
                    ))
                ),
                SourcePhysicsCommand(
                    sequence: 6,
                    payload: .deleteBody(.init(bodyID: oldAttachedID))
                ),
                SourcePhysicsCommand(
                    sequence: 7,
                    payload: .createBody(try makeCreation(
                        bodyID: newAttachedID,
                        origin: SourceVector3(8, 0, 0)
                    ))
                ),
                SourcePhysicsCommand(
                    sequence: 8,
                    payload: .simulate(.init(simulationTick: 2))
                ),
            ])
        )
        #expect(snapshot.fixedConstraints.isEmpty)
        #expect(snapshot.bodies.map(\.bodyID).contains(newAttachedID))
        #expect(!snapshot.bodies.map(\.bodyID).contains(oldAttachedID))

        #expect(throws:
            SourceDeterministicPhysicsEnvironment.Error.constraintBodyMissing(
                constraintID: try SourcePhysicsConstraintID(rawValue: 10),
                bodyID: oldAttachedID
            )
        ) {
            _ = try environment.execute(SourcePhysicsCommandBatch(commands: [
                SourcePhysicsCommand(
                    sequence: 9,
                    payload: .createFixedConstraint(
                        try SourcePhysicsFixedConstraintCreationCommand(
                            constraintID: SourcePhysicsConstraintID(
                                rawValue: 10
                            ),
                            referenceBodyID: referenceID,
                            attachedBodyID: oldAttachedID
                        )
                    )
                ),
            ]))
        }

        _ = try environment.execute(SourcePhysicsCommandBatch(commands: [
            SourcePhysicsCommand(
                sequence: 9,
                payload: .simulate(.init(simulationTick: 3))
            ),
        ]))
        #expect(throws:
            SourceDeterministicPhysicsEnvironment.Error.retiredConstraint(
                constraintID
            )
        ) {
            _ = try environment.execute(SourcePhysicsCommandBatch(commands: [
                SourcePhysicsCommand(
                    sequence: 10,
                    payload: .createFixedConstraint(
                        try SourcePhysicsFixedConstraintCreationCommand(
                            constraintID: constraintID,
                            referenceBodyID: referenceID,
                            attachedBodyID: newAttachedID
                        )
                    )
                ),
            ]))
        }
        let afterRollback = try environment.execute(
            SourcePhysicsCommandBatch(commands: [
                SourcePhysicsCommand(
                    sequence: 10,
                    payload: .simulate(.init(simulationTick: 4))
                ),
            ])
        )
        #expect(afterRollback.fixedConstraints.isEmpty)
    }

    @Test("fixed-constraint create, solve, and delete replay exact bytes")
    func deterministicReplayRoundTrip() throws {
        let referenceID = try makeBodyID(entry: 120, serial: 3)
        let attachedID = try makeBodyID(entry: 121, serial: 3)
        let constraintID = try SourcePhysicsConstraintID(rawValue: 77)
        let batches = try [
            SourcePhysicsCommandBatch(commands: [
                SourcePhysicsCommand(
                    sequence: 1,
                    payload: .createBody(try makeCreation(
                        bodyID: referenceID,
                        origin: .zero,
                        linearVelocity: SourceVector3(20, 0, 0)
                    ))
                ),
                SourcePhysicsCommand(
                    sequence: 2,
                    payload: .createBody(try makeCreation(
                        bodyID: attachedID,
                        origin: SourceVector3(6, 1, 0)
                    ))
                ),
                SourcePhysicsCommand(
                    sequence: 3,
                    payload: .createFixedConstraint(
                        try .init(
                            constraintID: constraintID,
                            referenceBodyID: referenceID,
                            attachedBodyID: attachedID
                        )
                    )
                ),
                SourcePhysicsCommand(
                    sequence: 4,
                    payload: .simulate(.init(simulationTick: 1))
                ),
            ]),
            SourcePhysicsCommandBatch(commands: [
                SourcePhysicsCommand(
                    sequence: 5,
                    payload: .simulate(.init(simulationTick: 2))
                ),
            ]),
            SourcePhysicsCommandBatch(commands: [
                SourcePhysicsCommand(
                    sequence: 6,
                    payload: .deleteConstraint(.init(
                        constraintID: constraintID
                    ))
                ),
                SourcePhysicsCommand(
                    sequence: 7,
                    payload: .simulate(.init(simulationTick: 3))
                ),
            ]),
        ]
        let harness = SourcePhysicsDeterministicReplayHarness()
        let configuration = try SourceDeterministicPhysicsEnvironment
            .Configuration(gravity: .zero)
        let log = try harness.record(
            commandBatches: batches,
            using: SourceDeterministicPhysicsEnvironment(
                configuration: configuration
            )
        )
        #expect(SourcePhysicsReplayLog.formatVersion == 8)
        #expect(log.frames[0].environmentSnapshot.fixedConstraints.count == 1)
        #expect(log.frames[1].environmentSnapshot.fixedConstraints.count == 1)
        #expect(log.frames[2].environmentSnapshot.fixedConstraints.isEmpty)
        #expect(log.frames[0].events.contains {
            if case let .fixedConstraintCreated(sequence, command) = $0 {
                return sequence == 3 && command.constraintID == constraintID
            }
            return false
        })
        #expect(log.frames[2].events.contains {
            if case let .constraintDeleted(sequence, identifier) = $0 {
                return sequence == 6 && identifier == constraintID
            }
            return false
        })

        let decoded = try SourcePhysicsReplayLog(
            canonicalBytes: log.canonicalBytes
        )
        #expect(decoded == log)
        let comparison = try harness.replay(
            decoded,
            using: SourceDeterministicPhysicsEnvironment(
                configuration: configuration
            )
        )
        #expect(comparison.frameCount == 3)
        #expect(comparison.canonicalByteCount == log.canonicalBytes.count)
    }

    private func makeBodyID(
        entry: Int,
        serial: Int
    ) throws -> SourcePhysicsBodyID {
        try SourcePhysicsBodyID(
            entityIdentity: SourceCanonicalEntityIdentity(
                handle: SourceBaseHandle(
                    entryIndex: entry,
                    serialNumber: serial
                )
            ),
            solidIndex: 0
        )
    }

    private func makeCreation(
        bodyID: SourcePhysicsBodyID,
        origin: SourceVector3,
        angles: SourceQAngle = .zero,
        linearVelocity: SourceVector3 = .zero,
        angularVelocity: SourceVector3 = .zero
    ) throws -> SourcePhysicsBodyCreationCommand {
        try SourcePhysicsBodyCreationCommand(
            bodyID: bodyID,
            shape: makeShape(),
            massProperties: SourcePhysicsMassProperties(
                massKilograms: 10,
                principalInertia: SourceVector3(5, 5, 5)
            ),
            transform: SourceEntityTransform(origin: origin, angles: angles),
            linearVelocity: linearVelocity,
            angularVelocity: angularVelocity,
            damping: .zero,
            motionType: .dynamicBody,
            materialIndex: 1,
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
                    SourceVector3(0, 0, 0),
                    SourceVector3(1, 0, 0),
                    SourceVector3(0, 1, 0),
                    SourceVector3(0, 0, 1),
                ],
                triangles: [
                    try SourcePhysicsIndexedTriangle(
                        first: 0,
                        second: 1,
                        third: 2,
                        materialIndex: 1
                    ),
                    try SourcePhysicsIndexedTriangle(
                        first: 0,
                        second: 3,
                        third: 1,
                        materialIndex: 1
                    ),
                    try SourcePhysicsIndexedTriangle(
                        first: 0,
                        second: 2,
                        third: 3,
                        materialIndex: 1
                    ),
                    try SourcePhysicsIndexedTriangle(
                        first: 1,
                        second: 3,
                        third: 2,
                        materialIndex: 1
                    ),
                ]
            )]
        )
    }

    private func expectRelativePose(
        reference: SourceEntityTransform,
        attached: SourceEntityTransform,
        expected: SourceEntityTransform,
        tolerance: Float
    ) {
        expectVectorClose(
            reference.inverseTransformPointToLocal(attached.origin),
            expected.origin,
            tolerance: tolerance
        )
        let referenceRotation = SourcePhysicsConstraintQuaternion(
            reference.angles
        )
        let attachedRotation = SourcePhysicsConstraintQuaternion(
            attached.angles
        )
        expectBasisClose(
            (referenceRotation.inverse * attachedRotation).sourceAngles,
            expected.angles,
            tolerance: tolerance
        )
    }

    private func expectVectorClose(
        _ actual: SourceVector3,
        _ expected: SourceVector3,
        tolerance: Float
    ) {
        #expect(abs(actual.x - expected.x) <= tolerance)
        #expect(abs(actual.y - expected.y) <= tolerance)
        #expect(abs(actual.z - expected.z) <= tolerance)
    }

    private func expectBasisClose(
        _ actual: SourceQAngle,
        _ expected: SourceQAngle,
        tolerance: Float
    ) {
        let actualBasis = actual.sourceBasis
        let expectedBasis = expected.sourceBasis
        expectVectorClose(
            actualBasis.forward,
            expectedBasis.forward,
            tolerance: tolerance
        )
        expectVectorClose(
            actualBasis.right,
            expectedBasis.right,
            tolerance: tolerance
        )
        expectVectorClose(
            actualBasis.up,
            expectedBasis.up,
            tolerance: tolerance
        )
    }
}
