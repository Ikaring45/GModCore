import Testing
@testable import GModEngine

@Suite("Deterministic Source no-collide constraints")
struct SourcePhysicsNoCollideConstraintTests {
    @Test("a live constraint suppresses only its dynamic contact pair")
    func pairExclusionAndRemoval() throws {
        let firstID = try makeBodyID(entry: 301, serial: 7)
        let secondID = try makeBodyID(entry: 302, serial: 7)
        let constraintID = try SourcePhysicsConstraintID(rawValue: 91)
        let environment = SourceDeterministicPhysicsEnvironment(
            configuration: try .init(gravity: .zero),
            materialTable: try makeMaterialTable(first: 1, second: 2)
        )

        var snapshot = try environment.execute(SourcePhysicsCommandBatch(
            commands: [
                SourcePhysicsCommand(
                    sequence: 1,
                    payload: .createBody(try makeCreation(
                        bodyID: firstID,
                        origin: .zero,
                        materialIndex: 1
                    ))
                ),
                SourcePhysicsCommand(
                    sequence: 2,
                    payload: .createBody(try makeCreation(
                        bodyID: secondID,
                        origin: SourceVector3(1, 0, 0),
                        materialIndex: 2
                    ))
                ),
                SourcePhysicsCommand(
                    sequence: 3,
                    payload: .createNoCollideConstraint(
                        try SourcePhysicsNoCollideConstraintCreationCommand(
                            constraintID: constraintID,
                            firstBodyID: firstID,
                            secondBodyID: secondID
                        )
                    )
                ),
                SourcePhysicsCommand(
                    sequence: 4,
                    payload: .simulate(.init(simulationTick: 1))
                ),
            ]
        ))

        let published = try #require(snapshot.noCollideConstraints.first)
        #expect(published.constraintID == constraintID)
        #expect(published.creation.firstBodyID == firstID)
        #expect(published.creation.secondBodyID == secondID)
        #expect(published.simulationTick == 1)
        #expect(environment.latestContacts.isEmpty)

        snapshot = try environment.execute(SourcePhysicsCommandBatch(commands: [
            SourcePhysicsCommand(
                sequence: 5,
                payload: .deleteConstraint(.init(constraintID: constraintID))
            ),
            SourcePhysicsCommand(
                sequence: 6,
                payload: .simulate(.init(simulationTick: 2))
            ),
        ]))

        #expect(snapshot.noCollideConstraints.isEmpty)
        #expect(environment.latestContacts.contains {
            $0.firstBodyID == firstID && $0.secondBodyID == secondID
        })
    }

    @Test("full body identities govern lifecycle and retired IDs")
    func lifecycleAndGenerationSafety() throws {
        let firstID = try makeBodyID(entry: 311, serial: 1)
        let secondID = try makeBodyID(entry: 312, serial: 1)
        let reusedSecondID = try makeBodyID(entry: 312, serial: 2)
        let constraintID = try SourcePhysicsConstraintID(rawValue: 92)
        let environment = SourceDeterministicPhysicsEnvironment(
            configuration: try .init(gravity: .zero)
        )
        let creation = try SourcePhysicsNoCollideConstraintCreationCommand(
            constraintID: constraintID,
            firstBodyID: firstID,
            secondBodyID: secondID
        )

        _ = try environment.execute(SourcePhysicsCommandBatch(commands: [
            SourcePhysicsCommand(
                sequence: 1,
                payload: .createBody(try makeCreation(
                    bodyID: firstID,
                    origin: .zero,
                    materialIndex: 1
                ))
            ),
            SourcePhysicsCommand(
                sequence: 2,
                payload: .createBody(try makeCreation(
                    bodyID: secondID,
                    origin: SourceVector3(4, 0, 0),
                    materialIndex: 1
                ))
            ),
            SourcePhysicsCommand(
                sequence: 3,
                payload: .createNoCollideConstraint(creation)
            ),
        ]))

        #expect(throws:
            SourceDeterministicPhysicsEnvironment.Error.bodyHasLiveConstraint(
                bodyID: secondID,
                constraintID: constraintID
            )
        ) {
            _ = try environment.execute(SourcePhysicsCommandBatch(commands: [
                SourcePhysicsCommand(
                    sequence: 4,
                    payload: .deleteBody(.init(bodyID: secondID))
                ),
            ]))
        }

        _ = try environment.execute(SourcePhysicsCommandBatch(commands: [
            SourcePhysicsCommand(
                sequence: 4,
                payload: .deleteConstraint(.init(constraintID: constraintID))
            ),
            SourcePhysicsCommand(
                sequence: 5,
                payload: .deleteBody(.init(bodyID: secondID))
            ),
            SourcePhysicsCommand(
                sequence: 6,
                payload: .createBody(try makeCreation(
                    bodyID: reusedSecondID,
                    origin: SourceVector3(4, 0, 0),
                    materialIndex: 1
                ))
            ),
        ]))

        let reusedCreation = try SourcePhysicsNoCollideConstraintCreationCommand(
            constraintID: constraintID,
            firstBodyID: firstID,
            secondBodyID: reusedSecondID
        )
        #expect(throws:
            SourceDeterministicPhysicsEnvironment.Error.retiredConstraint(
                constraintID
            )
        ) {
            _ = try environment.execute(SourcePhysicsCommandBatch(commands: [
                SourcePhysicsCommand(
                    sequence: 7,
                    payload: .createNoCollideConstraint(reusedCreation)
                ),
            ]))
        }
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
        materialIndex: Int
    ) throws -> SourcePhysicsBodyCreationCommand {
        try SourcePhysicsBodyCreationCommand(
            bodyID: bodyID,
            shape: makeCubeShape(),
            massProperties: SourcePhysicsMassProperties(
                massKilograms: 10,
                principalInertia: SourceVector3(5, 5, 5)
            ),
            transform: SourceEntityTransform(origin: origin, angles: .zero),
            linearVelocity: .zero,
            angularVelocity: .zero,
            damping: .zero,
            motionType: .dynamicBody,
            materialIndex: materialIndex,
            isGravityEnabled: false,
            isCollisionEnabled: true,
            startsAwake: true
        )
    }

    private func makeCubeShape() throws -> SourcePhysicsShapeSnapshot {
        let vertices = [
            SourceVector3(-1, -1, -1),
            SourceVector3(1, -1, -1),
            SourceVector3(1, 1, -1),
            SourceVector3(-1, 1, -1),
            SourceVector3(-1, -1, 1),
            SourceVector3(1, -1, 1),
            SourceVector3(1, 1, 1),
            SourceVector3(-1, 1, 1),
        ]
        let indices = [
            (0, 2, 1), (0, 3, 2),
            (4, 5, 6), (4, 6, 7),
            (0, 1, 5), (0, 5, 4),
            (1, 2, 6), (1, 6, 5),
            (2, 3, 7), (2, 7, 6),
            (3, 0, 4), (3, 4, 7),
        ]
        return try SourcePhysicsShapeSnapshot(
            topology: .convexParts,
            parts: [SourcePhysicsMeshPartSnapshot(
                vertices: vertices,
                triangles: try indices.map {
                    try SourcePhysicsIndexedTriangle(
                        first: $0.0,
                        second: $0.1,
                        third: $0.2,
                        materialIndex: 1
                    )
                }
            )]
        )
    }

    private func makeMaterialTable(
        first: Int,
        second: Int
    ) throws -> SourcePhysicsMaterialTable {
        let coefficients = try SourcePhysicsContactMaterialCoefficients(
            staticFriction: 0,
            dynamicFriction: 0,
            restitution: 0
        )
        return try SourcePhysicsMaterialTable(interactions: [
            try SourcePhysicsMaterialInteraction(
                firstMaterialIndex: first,
                secondMaterialIndex: second,
                coefficients: coefficients
            ),
        ])
    }
}
