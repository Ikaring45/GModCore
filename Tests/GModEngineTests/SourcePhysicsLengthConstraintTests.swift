import Testing
@testable import GModEngine

@Suite("Deterministic Source length physics constraints")
struct SourcePhysicsLengthConstraintTests {
    @Test("flexible rope clamps a dynamic body to the immutable world body")
    func dynamicBodyToStaticWorld() throws {
        let worldID = try bodyID(entry: 0, serial: 1)
        let propID = try bodyID(entry: 120, serial: 9)
        let scene = try SourceDeterministicPhysicsStaticScene(
            bodyID: worldID,
            geometry: staticFloor(),
            contents: .solid
        )
        let environment = SourceDeterministicPhysicsEnvironment(
            configuration: try .init(gravity: .zero),
            staticCollisionScene: scene
        )
        let constraintID = try SourcePhysicsConstraintID(rawValue: 91)
        let creation = try SourcePhysicsLengthConstraintCreationCommand(
            constraintID: constraintID,
            reference: SourcePhysicsLengthConstraintEndpoint(
                bodyID: worldID,
                kind: .staticWorld,
                localAnchor: SourceVector3(0, 0, 5)
            ),
            attached: SourcePhysicsLengthConstraintEndpoint(
                bodyID: propID,
                kind: .body,
                localAnchor: .zero
            ),
            minimumLength: 0,
            maximumLength: 10
        )
        let snapshot = try environment.execute(
            SourcePhysicsCommandBatch(commands: [
                SourcePhysicsCommand(
                    sequence: 1,
                    payload: .createBody(try bodyCreation(
                        bodyID: propID,
                        origin: SourceVector3(20, 0, 5)
                    ))
                ),
                SourcePhysicsCommand(
                    sequence: 2,
                    payload: .createLengthConstraint(creation)
                ),
                SourcePhysicsCommand(
                    sequence: 3,
                    payload: .simulate(.init(simulationTick: 1))
                ),
            ])
        )

        let prop = try #require(snapshot.bodies.first)
        #expect(abs(prop.transform.origin.x - 10) < 0.001)
        #expect(snapshot.lengthConstraints == [
            SourcePhysicsLengthConstraintSnapshot(
                creation: creation,
                simulationTick: 1
            ),
        ])
        #expect(snapshot.fixedConstraints.isEmpty)
    }

    @Test("positive break limit remains an explicit unsupported boundary")
    func breakableConstraintIsNotApproximated() throws {
        let first = try bodyID(entry: 121, serial: 1)
        let second = try bodyID(entry: 122, serial: 1)
        let constraintID = try SourcePhysicsConstraintID(rawValue: 92)
        let creation = try SourcePhysicsLengthConstraintCreationCommand(
            constraintID: constraintID,
            reference: SourcePhysicsLengthConstraintEndpoint(
                bodyID: first,
                kind: .body,
                localAnchor: .zero
            ),
            attached: SourcePhysicsLengthConstraintEndpoint(
                bodyID: second,
                kind: .body,
                localAnchor: .zero
            ),
            minimumLength: 0,
            maximumLength: 8,
            forceLimitKilogramInchesPerSecond: 1
        )
        let environment = SourceDeterministicPhysicsEnvironment(
            configuration: try .init(gravity: .zero)
        )
        #expect(throws: SourceDeterministicPhysicsEnvironment.Error
            .breakableLengthConstraintUnavailable(constraintID)) {
            _ = try environment.execute(SourcePhysicsCommandBatch(commands: [
                SourcePhysicsCommand(
                    sequence: 1,
                    payload: .createBody(try bodyCreation(
                        bodyID: first,
                        origin: .zero
                    ))
                ),
                SourcePhysicsCommand(
                    sequence: 2,
                    payload: .createBody(try bodyCreation(
                        bodyID: second,
                        origin: SourceVector3(8, 0, 0)
                    ))
                ),
                SourcePhysicsCommand(
                    sequence: 3,
                    payload: .createLengthConstraint(creation)
                ),
            ]))
        }
    }

    private func bodyID(entry: Int, serial: Int) throws
        -> SourcePhysicsBodyID
    {
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

    private func bodyCreation(
        bodyID: SourcePhysicsBodyID,
        origin: SourceVector3
    ) throws -> SourcePhysicsBodyCreationCommand {
        try SourcePhysicsBodyCreationCommand(
            bodyID: bodyID,
            shape: cubeShape(),
            massProperties: SourcePhysicsMassProperties(
                massKilograms: 10,
                principalInertia: SourceVector3(5, 5, 5)
            ),
            transform: SourceEntityTransform(origin: origin, angles: .zero),
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

    private func cubeShape() throws -> SourcePhysicsShapeSnapshot {
        let vertices = [
            SourceVector3(-1, -1, -1), SourceVector3(1, -1, -1),
            SourceVector3(1, 1, -1), SourceVector3(-1, 1, -1),
            SourceVector3(-1, -1, 1), SourceVector3(1, -1, 1),
            SourceVector3(1, 1, 1), SourceVector3(-1, 1, 1),
        ]
        let indices = [
            (0, 2, 1), (0, 3, 2), (4, 5, 6), (4, 6, 7),
            (0, 1, 5), (0, 5, 4), (1, 2, 6), (1, 6, 5),
            (2, 3, 7), (2, 7, 6), (3, 0, 4), (3, 4, 7),
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
                        materialIndex: 0
                    )
                }
            )]
        )
    }

    private func staticFloor() throws
        -> SourceDeterministicPhysicsStaticGeometry
    {
        try SourceDeterministicPhysicsStaticGeometry(parts: [
            SourceDeterministicPhysicsStaticMeshPart(
                vertices: [
                    SourceVector3(-32, -32, 0),
                    SourceVector3(32, -32, 0),
                    SourceVector3(32, 32, 0),
                    SourceVector3(-32, 32, 0),
                ],
                triangles: [
                    try SourceDeterministicPhysicsStaticTriangle(
                        first: 0, second: 1, third: 2
                    ),
                    try SourceDeterministicPhysicsStaticTriangle(
                        first: 0, second: 2, third: 3
                    ),
                ]
            ),
        ])
    }
}
