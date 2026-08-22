import Testing
@testable import GModEngine

@Suite("Deterministic open-triangle static physics")
struct SourceDeterministicPhysicsOpenTriangleMeshTests {
    @Test("static mesh topology defaults closed and explicitly retains open")
    func topologyContract() throws {
        let vertices = terrainVertices
        let triangles = try terrainTriangles(material: 11)
        let compatibleDefault = try SourceDeterministicPhysicsStaticMeshPart(
            vertices: vertices,
            triangles: triangles
        )
        let displacement = try SourceDeterministicPhysicsStaticMeshPart(
            vertices: vertices,
            triangles: triangles,
            topology: .openTriangleMesh
        )

        #expect(compatibleDefault.topology == .closedConvexVolume)
        #expect(displacement.topology == .openTriangleMesh)
    }

    @Test("line and swept hull hit open terrain without plane-only false hits")
    func lineAndContinuousHullSAT() throws {
        let worldID = try bodyID(entry: 0, serial: 73)
        let environment = try makeEnvironment(worldID: worldID)
        let line = try SourcePhysicsQueryCommand(
            queryID: 1,
            geometry: .lineSegment(
                start: SourceVector3(-2, -2, 5),
                end: SourceVector3(-2, -2, -5)
            ),
            contentsMask: SourceContents.solid.rawValue,
            collisionGroup: 0,
            scope: .staticOnly,
            ignoredEntities: []
        )
        let hull = try SourcePhysicsQueryCommand(
            queryID: 2,
            geometry: .sweptHull(
                start: SourceVector3(-2, -2, 5),
                end: SourceVector3(-2, -2, -5),
                minimums: SourceVector3(-1, -1, -1),
                maximums: SourceVector3(1, 1, 1)
            ),
            contentsMask: SourceContents.solid.rawValue,
            collisionGroup: 0,
            scope: .staticOnly,
            ignoredEntities: []
        )
        // This box crosses the triangle's plane but stays beyond its diagonal.
        // A plane-only brush clip reports a false hit; the edge-cross SAT axes
        // must reject it.
        let outsideTriangle = try SourcePhysicsQueryCommand(
            queryID: 3,
            geometry: .sweptHull(
                start: SourceVector3(8, 8, 5),
                end: SourceVector3(8, 8, -5),
                minimums: SourceVector3(-0.5, -0.5, -0.5),
                maximums: SourceVector3(0.5, 0.5, 0.5)
            ),
            contentsMask: SourceContents.solid.rawValue,
            collisionGroup: 0,
            scope: .staticOnly,
            ignoredEntities: []
        )

        let snapshot = try environment.execute(SourcePhysicsCommandBatch(commands: [
            SourcePhysicsCommand(sequence: 1, payload: .query(line)),
            SourcePhysicsCommand(sequence: 2, payload: .query(hull)),
            SourcePhysicsCommand(sequence: 3, payload: .query(outsideTriangle)),
        ]))
        let lineHit = try #require(snapshot.queryResults[0].hit)
        #expect(lineHit.bodyID == worldID)
        #expect(abs(lineHit.fraction - 0.5) < 0.000_01)
        #expect(lineHit.normal == SourceVector3(0, 0, 1))
        #expect(lineHit.materialIndex == 11)

        let hullHit = try #require(snapshot.queryResults[1].hit)
        #expect(hullHit.bodyID == worldID)
        #expect(abs(hullHit.fraction - 0.4) < 0.000_01)
        #expect(hullHit.normal == SourceVector3(0, 0, 1))
        #expect(hullHit.materialIndex == 11)
        #expect(!hullHit.startedSolid)
        #expect(!hullHit.allSolid)
        #expect(snapshot.queryResults[2].hit == nil)
    }

    @Test("open triangle StartSolid and AllSolid use exact swept overlap")
    func startAndAllSolid() throws {
        let environment = try makeEnvironment(
            worldID: bodyID(entry: 0, serial: 91)
        )
        let stationary = try SourcePhysicsQueryCommand(
            queryID: 10,
            geometry: .sweptHull(
                start: SourceVector3(-2, -2, 0),
                end: SourceVector3(-2, -2, 0),
                minimums: SourceVector3(-1, -1, -1),
                maximums: SourceVector3(1, 1, 1)
            ),
            contentsMask: SourceContents.solid.rawValue,
            collisionGroup: 0,
            scope: .staticOnly,
            ignoredEntities: []
        )
        let leaving = try SourcePhysicsQueryCommand(
            queryID: 11,
            geometry: .sweptHull(
                start: SourceVector3(-2, -2, 0),
                end: SourceVector3(-2, -2, 5),
                minimums: SourceVector3(-1, -1, -1),
                maximums: SourceVector3(1, 1, 1)
            ),
            contentsMask: SourceContents.solid.rawValue,
            collisionGroup: 0,
            scope: .staticOnly,
            ignoredEntities: []
        )
        let snapshot = try environment.execute(SourcePhysicsCommandBatch(commands: [
            SourcePhysicsCommand(sequence: 10, payload: .query(stationary)),
            SourcePhysicsCommand(sequence: 11, payload: .query(leaving)),
        ]))

        let stationaryHit = try #require(snapshot.queryResults[0].hit)
        #expect(stationaryHit.fraction == 0)
        #expect(stationaryHit.startedSolid)
        #expect(stationaryHit.allSolid)
        #expect(stationaryHit.normal == .zero)
        #expect(stationaryHit.materialIndex == nil)

        let leavingHit = try #require(snapshot.queryResults[1].hit)
        #expect(leavingHit.fraction == 0)
        #expect(leavingHit.startedSolid)
        #expect(!leavingHit.allSolid)
        #expect(leavingHit.normal == .zero)
    }

    @Test("boundary contact is not StartSolid and downward motion hits at zero")
    func restingBoundaryContact() throws {
        let environment = try makeEnvironment(
            worldID: bodyID(entry: 0, serial: 92)
        )
        let stationary = try SourcePhysicsQueryCommand(
            queryID: 12,
            geometry: .sweptHull(
                start: SourceVector3(-2, -2, 1),
                end: SourceVector3(-2, -2, 1),
                minimums: SourceVector3(-1, -1, -1),
                maximums: SourceVector3(1, 1, 1)
            ),
            contentsMask: SourceContents.solid.rawValue,
            collisionGroup: 0,
            scope: .staticOnly,
            ignoredEntities: []
        )
        let intoSurface = try SourcePhysicsQueryCommand(
            queryID: 13,
            geometry: .sweptHull(
                start: SourceVector3(-2, -2, 1),
                end: SourceVector3(-2, -2, 0.5),
                minimums: SourceVector3(-1, -1, -1),
                maximums: SourceVector3(1, 1, 1)
            ),
            contentsMask: SourceContents.solid.rawValue,
            collisionGroup: 0,
            scope: .staticOnly,
            ignoredEntities: []
        )
        let snapshot = try environment.execute(SourcePhysicsCommandBatch(
            commands: [
                SourcePhysicsCommand(sequence: 12, payload: .query(stationary)),
                SourcePhysicsCommand(sequence: 13, payload: .query(intoSurface)),
            ]
        ))

        #expect(snapshot.queryResults[0].hit == nil)
        let contact = try #require(snapshot.queryResults[1].hit)
        #expect(contact.fraction == 0)
        #expect(!contact.startedSolid)
        #expect(!contact.allSolid)
        #expect(contact.normal == SourceVector3(0, 0, 1))
    }

    @Test("fast verified prop CCD lands on an open displacement triangle")
    func dynamicCCDAndContact() throws {
        let worldID = try bodyID(entry: 0, serial: 117)
        let propID = try bodyID(entry: 44, serial: 9)
        let environment = try makeEnvironment(worldID: worldID)
        let creation = try SourcePhysicsBodyCreationCommand(
            bodyID: propID,
            shape: cubeShape(),
            massProperties: SourcePhysicsMassProperties(
                massKilograms: 10,
                principalInertia: SourceVector3(5, 5, 5)
            ),
            transform: SourceEntityTransform(
                origin: SourceVector3(-2, -2, 3),
                angles: .zero
            ),
            linearVelocity: SourceVector3(0, 0, -300),
            angularVelocity: .zero,
            motionType: .dynamicBody,
            materialIndex: 4,
            isGravityEnabled: false,
            isCollisionEnabled: true,
            startsAwake: true
        )
        let snapshot = try environment.execute(SourcePhysicsCommandBatch(commands: [
            SourcePhysicsCommand(sequence: 20, payload: .createBody(creation)),
            SourcePhysicsCommand(
                sequence: 21,
                payload: .simulate(SourcePhysicsSimulateCommand(simulationTick: 1))
            ),
        ]))

        let prop = try #require(snapshot.bodies.first { $0.bodyID == propID })
        #expect(prop.transform.origin.z >= 0.999)
        #expect(environment.latestContacts.contains {
            $0.firstBodyID == worldID && $0.secondBodyID == propID
        })
    }
}

private extension SourceDeterministicPhysicsOpenTriangleMeshTests {
    var terrainVertices: [SourceVector3] {
        [
            SourceVector3(-10, -10, 0),
            SourceVector3(10, -10, 0),
            SourceVector3(-10, 10, 0),
        ]
    }

    func terrainTriangles(material: Int)
        throws -> [SourceDeterministicPhysicsStaticTriangle]
    {
        [try SourceDeterministicPhysicsStaticTriangle(
            first: 0,
            second: 1,
            third: 2,
            materialIndex: material
        )]
    }

    func makeEnvironment(worldID: SourcePhysicsBodyID) throws
        -> SourceDeterministicPhysicsEnvironment
    {
        let part = try SourceDeterministicPhysicsStaticMeshPart(
            vertices: terrainVertices,
            triangles: terrainTriangles(material: 11),
            topology: .openTriangleMesh
        )
        let geometry = try SourceDeterministicPhysicsStaticGeometry(parts: [part])
        let scene = try SourceDeterministicPhysicsStaticScene(
            bodyID: worldID,
            geometry: geometry,
            contents: .solid
        )
        let coefficients = try SourcePhysicsContactMaterialCoefficients(
            staticFriction: 0,
            dynamicFriction: 0,
            restitution: 0
        )
        let materials = try SourcePhysicsMaterialTable(interactions: [
            SourcePhysicsMaterialInteraction(
                firstMaterialIndex: 4,
                secondMaterialIndex: 11,
                coefficients: coefficients
            )
        ])
        return SourceDeterministicPhysicsEnvironment(
            staticCollisionScene: scene,
            materialTable: materials
        )
    }

    func bodyID(entry: Int, serial: Int) throws -> SourcePhysicsBodyID {
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

    func cubeShape() throws -> SourcePhysicsShapeSnapshot {
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
        let triangles = try indices.map {
            try SourcePhysicsIndexedTriangle(
                first: $0.0,
                second: $0.1,
                third: $0.2,
                materialIndex: 4
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
}
