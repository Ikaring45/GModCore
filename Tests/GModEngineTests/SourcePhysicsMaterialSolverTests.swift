import Testing
@testable import GModEngine

@Suite("Source physics material-pair solver")
struct SourcePhysicsMaterialSolverTests {
    @Test("material interactions are canonical, validated, and fail closed")
    func materialTableContract() throws {
        let coefficients = try SourcePhysicsContactMaterialCoefficients(
            staticFriction: 0.8,
            dynamicFriction: 0.4,
            restitution: 0.25
        )
        let table = try SourcePhysicsMaterialTable(interactions: [
            SourcePhysicsMaterialInteraction(
                firstMaterialIndex: 9,
                secondMaterialIndex: 3,
                coefficients: coefficients
            )
        ])

        #expect(table.interactionCount == 1)
        #expect(try table.coefficients(
            firstMaterialIndex: 3,
            secondMaterialIndex: 9
        ) == coefficients)
        #expect(throws: SourcePhysicsMaterialTableError
            .unregisteredInteraction(
                firstMaterialIndex: 3,
                secondMaterialIndex: 10
            )) {
            _ = try table.coefficients(
                firstMaterialIndex: 10,
                secondMaterialIndex: 3
            )
        }
        #expect(throws: SourcePhysicsMaterialTableError
            .duplicateInteraction(
                firstMaterialIndex: 3,
                secondMaterialIndex: 9
            )) {
            _ = try SourcePhysicsMaterialTable(interactions: [
                SourcePhysicsMaterialInteraction(
                    firstMaterialIndex: 3,
                    secondMaterialIndex: 9,
                    coefficients: coefficients
                ),
                SourcePhysicsMaterialInteraction(
                    firstMaterialIndex: 9,
                    secondMaterialIndex: 3,
                    coefficients: coefficients
                )
            ])
        }
        #expect(throws: SourcePhysicsMaterialTableError.invalidCoefficient(
            field: "restitution",
            value: -.infinity
        )) {
            _ = try SourcePhysicsContactMaterialCoefficients(
                staticFriction: 0,
                dynamicFriction: 0,
                restitution: -.infinity
            )
        }
    }

    @Test("unregistered pair aborts the complete command batch")
    func unregisteredPairIsTransactional() throws {
        let worldID = try makeBodyID(entry: 0, serial: 4)
        let propID = try makeBodyID(entry: 12, serial: 4)
        let environment = SourceDeterministicPhysicsEnvironment(
            configuration: try .init(gravity: .zero),
            staticCollisionScene: try makeFloorScene(
                bodyID: worldID,
                materialIndex: 3
            )
        )
        let creation = try makeCreation(
            bodyID: propID,
            materialIndex: 7,
            velocity: SourceVector3(0, 0, -10)
        )

        #expect(throws: SourcePhysicsMaterialTableError
            .unregisteredInteraction(
                firstMaterialIndex: 3,
                secondMaterialIndex: 7
            )) {
            _ = try environment.execute(try createAndSimulateBatch(
                creation: creation
            ))
        }

        let snapshot = try environment.execute(SourcePhysicsCommandBatch(
            commands: [SourcePhysicsCommand(
                sequence: 1,
                payload: .createBody(creation)
            )]
        ))
        #expect(snapshot.bodies.map(\.bodyID) == [propID])
        #expect(environment.latestContacts.isEmpty)
    }

    @Test("missing triangle material aborts instead of selecting a default")
    func missingStaticMaterialFailsClosed() throws {
        let worldID = try makeBodyID(entry: 0, serial: 5)
        let propID = try makeBodyID(entry: 13, serial: 5)
        let environment = SourceDeterministicPhysicsEnvironment(
            configuration: try .init(gravity: .zero),
            staticCollisionScene: try makeFloorScene(
                bodyID: worldID,
                materialIndex: nil
            ),
            materialTable: try makeTable(
                first: 3,
                second: 7,
                staticFriction: 0,
                dynamicFriction: 0,
                restitution: 0
            )
        )

        #expect(throws: SourcePhysicsMaterialTableError
            .missingContactMaterialIndex(bodyID: worldID)) {
            _ = try environment.execute(try createAndSimulateBatch(
                creation: makeCreation(
                    bodyID: propID,
                    materialIndex: 7,
                    velocity: SourceVector3(0, 0, -10)
                )
            ))
        }
    }

    @Test("attested restitution changes normal velocity")
    func restitutionImpulse() throws {
        let result = try simulateImpact(
            velocity: SourceVector3(0, 0, -10),
            staticFriction: 0,
            dynamicFriction: 0,
            restitution: 0.5
        )

        #expect(abs(result.body.linearVelocity.x) < 0.0001)
        #expect(abs(result.body.linearVelocity.z - 5) < 0.001)
        #expect(result.contact.firstMaterialIndex == 3)
        #expect(result.contact.secondMaterialIndex == 7)
    }

    @Test("body materials select the same fail-closed pair solver")
    func bodyToBodyMaterialPair() throws {
        let staticID = try makeBodyID(entry: 30, serial: 2)
        let dynamicID = try makeBodyID(entry: 31, serial: 2)
        let environment = SourceDeterministicPhysicsEnvironment(
            configuration: try .init(gravity: .zero),
            materialTable: try makeTable(
                first: 3,
                second: 7,
                staticFriction: 0,
                dynamicFriction: 0,
                restitution: 0.5
            )
        )
        let snapshot = try environment.execute(SourcePhysicsCommandBatch(
            commands: [
                SourcePhysicsCommand(
                    sequence: 1,
                    payload: .createBody(try makeCreation(
                        bodyID: staticID,
                        materialIndex: 3,
                        velocity: .zero,
                        origin: .zero,
                        motionType: .staticBody
                    ))
                ),
                SourcePhysicsCommand(
                    sequence: 2,
                    payload: .createBody(try makeCreation(
                        bodyID: dynamicID,
                        materialIndex: 7,
                        velocity: SourceVector3(0, 0, -10),
                        origin: SourceVector3(0, 0, 1)
                    ))
                ),
                SourcePhysicsCommand(
                    sequence: 3,
                    payload: .simulate(SourcePhysicsSimulateCommand(
                        simulationTick: 1
                    ))
                ),
            ]
        ))

        let dynamic = try #require(snapshot.bodies.first {
            $0.bodyID == dynamicID
        })
        #expect(abs(dynamic.linearVelocity.z - 5) < 0.001)
        let contact = try #require(environment.latestContacts.first)
        #expect(contact.firstMaterialIndex == 3)
        #expect(contact.secondMaterialIndex == 7)
    }

    @Test("static friction cancels a tangential contact velocity inside its limit")
    func staticFrictionImpulse() throws {
        let result = try simulateImpact(
            velocity: SourceVector3(0.2, 0, -10),
            staticFriction: 0.05,
            dynamicFriction: 0.01,
            restitution: 0
        )

        let contactOffset = result.contact.position -
            result.body.transform.origin
        let angularVelocityRadians = result.body.angularVelocity *
            (Float.pi / 180)
        let contactPointVelocity = result.body.linearVelocity +
            cross(angularVelocityRadians, contactOffset)
        #expect(abs(contactPointVelocity.x) < 0.0001)
        #expect(abs(result.body.linearVelocity.z) < 0.0001)
    }

    @Test("dynamic friction uses its independently attested Coulomb limit")
    func dynamicFrictionImpulse() throws {
        let result = try simulateImpact(
            velocity: SourceVector3(20, 0, -10),
            staticFriction: 0.05,
            dynamicFriction: 0.25,
            restitution: 0
        )

        #expect(abs(result.body.linearVelocity.x - 17.5) < 0.001)
        #expect(abs(result.body.linearVelocity.z) < 0.0001)
    }

    private func simulateImpact(
        velocity: SourceVector3,
        staticFriction: Float,
        dynamicFriction: Float,
        restitution: Float
    ) throws -> (
        body: SourcePhysicsBodySnapshot,
        contact: SourceDeterministicPhysicsEnvironment.ContactSnapshot
    ) {
        let worldID = try makeBodyID(entry: 0, serial: 20)
        let propID = try makeBodyID(entry: 20, serial: 20)
        let environment = SourceDeterministicPhysicsEnvironment(
            configuration: try .init(gravity: .zero),
            staticCollisionScene: try makeFloorScene(
                bodyID: worldID,
                materialIndex: 3
            ),
            materialTable: try makeTable(
                first: 3,
                second: 7,
                staticFriction: staticFriction,
                dynamicFriction: dynamicFriction,
                restitution: restitution
            )
        )
        let snapshot = try environment.execute(try createAndSimulateBatch(
            creation: makeCreation(
                bodyID: propID,
                materialIndex: 7,
                velocity: velocity
            )
        ))
        return (
            try #require(snapshot.bodies.first { $0.bodyID == propID }),
            try #require(environment.latestContacts.first)
        )
    }

    private func makeTable(
        first: Int,
        second: Int,
        staticFriction: Float,
        dynamicFriction: Float,
        restitution: Float
    ) throws -> SourcePhysicsMaterialTable {
        try SourcePhysicsMaterialTable(interactions: [
            SourcePhysicsMaterialInteraction(
                firstMaterialIndex: first,
                secondMaterialIndex: second,
                coefficients: SourcePhysicsContactMaterialCoefficients(
                    staticFriction: staticFriction,
                    dynamicFriction: dynamicFriction,
                    restitution: restitution
                )
            )
        ])
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
        materialIndex: Int,
        velocity: SourceVector3,
        origin: SourceVector3 = SourceVector3(0, 0, 0.5),
        motionType: SourcePhysicsMotionType = .dynamicBody
    ) throws -> SourcePhysicsBodyCreationCommand {
        try SourcePhysicsBodyCreationCommand(
            bodyID: bodyID,
            shape: makeTetrahedronShape(),
            massProperties: SourcePhysicsMassProperties(
                massKilograms: 1,
                principalInertia: SourceVector3(1, 1, 1)
            ),
            transform: SourceEntityTransform(
                origin: origin,
                angles: .zero
            ),
            linearVelocity: velocity,
            angularVelocity: .zero,
            motionType: motionType,
            materialIndex: materialIndex,
            isGravityEnabled: false,
            isCollisionEnabled: true,
            startsAwake: true
        )
    }

    private func makeTetrahedronShape() throws -> SourcePhysicsShapeSnapshot {
        let vertices = [
            SourceVector3(0, 0, -0.5),
            SourceVector3(1, 0, 0.5),
            SourceVector3(-0.5, 0.866_025_4, 0.5),
            SourceVector3(-0.5, -0.866_025_4, 0.5),
        ]
        let triangles = try [
            (0, 2, 1),
            (0, 3, 2),
            (0, 1, 3),
            (1, 2, 3),
        ].map {
            try SourcePhysicsIndexedTriangle(
                first: $0.0,
                second: $0.1,
                third: $0.2,
                materialIndex: 7
            )
        }
        return try SourcePhysicsShapeSnapshot(
            topology: .convexParts,
            parts: [SourcePhysicsMeshPartSnapshot(
                vertices: vertices,
                triangles: triangles
            )]
        )
    }

    private func makeFloorScene(
        bodyID: SourcePhysicsBodyID,
        materialIndex: Int?
    ) throws -> SourceDeterministicPhysicsStaticScene {
        let vertices = [
            SourceVector3(-20, -20, 0),
            SourceVector3(20, -20, 0),
            SourceVector3(0, 20, 0),
        ]
        let triangle = try SourceDeterministicPhysicsStaticTriangle(
            first: 0,
            second: 1,
            third: 2,
            materialIndex: materialIndex
        )
        let geometry = try SourceDeterministicPhysicsStaticGeometry(parts: [
            SourceDeterministicPhysicsStaticMeshPart(
                vertices: vertices,
                triangles: [triangle],
                topology: .openTriangleMesh
            )
        ])
        return try SourceDeterministicPhysicsStaticScene(
            bodyID: bodyID,
            geometry: geometry,
            contents: .solid
        )
    }

    private func createAndSimulateBatch(
        creation: SourcePhysicsBodyCreationCommand
    ) throws -> SourcePhysicsCommandBatch {
        try SourcePhysicsCommandBatch(commands: [
            SourcePhysicsCommand(
                sequence: 1,
                payload: .createBody(creation)
            ),
            SourcePhysicsCommand(
                sequence: 2,
                payload: .simulate(SourcePhysicsSimulateCommand(
                    simulationTick: 1
                ))
            )
        ])
    }

    private func cross(
        _ first: SourceVector3,
        _ second: SourceVector3
    ) -> SourceVector3 {
        SourceVector3(
            first.y * second.z - first.z * second.y,
            first.z * second.x - first.x * second.z,
            first.x * second.y - first.y * second.x
        )
    }
}
