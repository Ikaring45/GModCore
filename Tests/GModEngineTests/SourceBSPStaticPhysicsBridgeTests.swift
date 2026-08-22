import GModGameAssets
import Testing
@testable import GModEngine

@Suite("Real BSP static physics bridge")
struct SourceBSPStaticPhysicsBridgeTests {
    @Test("gm_construct queries work and unattested contact fails closed")
    func constructWorldQueriesAndLanding() throws {
        let data = try GModGameAssets.data(for: .construct, kind: .bsp)
        let bsp = try SourceBSP(data: data)
        let manifest = try GModGameAssets.manifest()
        let manifestEntry = try #require(manifest.assets.first {
            $0.logicalPath == "maps/gm_construct.bsp"
        })
        let asset = try SourceBSPStaticPhysicsBridge.build(
            bsp: bsp,
            bspSHA256: manifestEntry.sha256,
            contentsMask: SourceMasks.playerSolidBrushOnly
        )

        #expect(asset.bspSHA256 == manifestEntry.sha256)
        #expect(asset.bspVersion == bsp.header.version)
        #expect(asset.mapRevision == bsp.header.mapRevision)
        #expect(!asset.includedBrushIndices.isEmpty)
        #expect(!asset.includedDisplacementFaceIndices.isEmpty)
        #expect(
            asset.geometry.parts.count ==
                asset.includedBrushIndices.count +
                asset.includedDisplacementFaceIndices.count
        )
        #expect(asset.triangleCount > 0)
        #expect(asset.triangleCount == asset.brushTriangleCount +
            asset.displacementTriangleCount)
        #expect(asset.displacementTriangleCount > 0)
        #expect(
            asset.geometry.parts
                .suffix(asset.includedDisplacementFaceIndices.count)
                .allSatisfy { $0.topology == .openTriangleMesh }
        )
        #expect(asset.skippedBrushes.allSatisfy {
            !asset.includedBrushIndices.contains($0.brushIndex)
        })
        #expect(asset.geometry.parts.flatMap(\.triangles).allSatisfy {
            $0.materialIndex == nil
        })

        // Canonical world serials belong to the entity-list lifetime. They are
        // not a constant zero, so retain the full EHANDLE through every hit.
        let worldIdentity = SourceCanonicalEntityIdentity(
            handle: SourceBaseHandle(entryIndex: 0, serialNumber: 41)
        )
        let scene = try asset.makeStaticScene(worldIdentity: worldIdentity)
        #expect(scene.bodyID.entityIdentity == worldIdentity)
        #expect(scene.bodyID.entityIdentity.serialNumber == 41)

        let spawn = try firstPlayerStart(in: bsp)
        let start = spawn + SourceVector3(0, 0, 512)
        let end = spawn + SourceVector3(0, 0, -4_096)
        let sourceLine = try bsp.traceWorld(
            SourceRay(start: start, end: end),
            mask: SourceMasks.playerSolidBrushOnly
        )
        #expect(sourceLine.didHitWorld)

        let lineQuery = try SourcePhysicsQueryCommand(
            queryID: 900,
            geometry: .lineSegment(start: start, end: end),
            contentsMask: SourceMasks.playerSolidBrushOnly.rawValue,
            collisionGroup: 0,
            scope: .staticOnly,
            ignoredEntities: []
        )
        let hullQuery = try SourcePhysicsQueryCommand(
            queryID: 901,
            geometry: .sweptHull(
                start: start,
                end: end,
                minimums: SourceVector3(-16, -16, 0),
                maximums: SourceVector3(16, 16, 72)
            ),
            contentsMask: SourceMasks.playerSolidBrushOnly.rawValue,
            collisionGroup: 0,
            scope: .staticOnly,
            ignoredEntities: []
        )
        let environment = SourceDeterministicPhysicsEnvironment(
            configuration: try .init(sleepAfterSettledTicks: 4),
            staticCollisionScene: scene
        )
        var snapshot = try environment.execute(
            SourcePhysicsCommandBatch(commands: [
                SourcePhysicsCommand(sequence: 1, payload: .query(lineQuery)),
                SourcePhysicsCommand(sequence: 2, payload: .query(hullQuery)),
            ])
        )
        #expect(snapshot.bodies.isEmpty)
        let lineHit = try #require(snapshot.queryResults[0].hit)
        #expect(lineHit.bodyID == scene.bodyID)
        #expect(lineHit.bodyID.entityIdentity.serialNumber == 41)
        #expect(lineHit.materialIndex == nil)
        #expect(lineHit.normal.z > 0.9)
        // BSP tracing intentionally backs an impact off by Source's 1/32-unit
        // epsilon; the exact triangle query reaches the same real plane.
        #expect(abs(lineHit.position.z - sourceLine.endPosition.z) < 0.04)

        let hullHit = try #require(snapshot.queryResults[1].hit)
        #expect(hullHit.bodyID == scene.bodyID)
        #expect(hullHit.materialIndex == nil)
        #expect(hullHit.normal.z > 0.9)
        #expect(abs(hullHit.position.z - sourceLine.endPosition.z) < 0.04)
        #expect(
            environment.latestStaticBroadphaseDiagnostics.candidatePartCount <
                asset.geometry.parts.count
        )

        let propID = try SourcePhysicsBodyID(
            entityIdentity: SourceCanonicalEntityIdentity(
                handle: SourceBaseHandle(entryIndex: 72, serialNumber: 9)
            ),
            solidIndex: 0
        )
        let creation = try SourcePhysicsBodyCreationCommand(
            bodyID: propID,
            shape: makeCubeShape(),
            massProperties: SourcePhysicsMassProperties(
                massKilograms: 12,
                principalInertia: SourceVector3(8, 8, 8)
            ),
            transform: SourceEntityTransform(
                origin: SourceVector3(
                    spawn.x,
                    spawn.y,
                    sourceLine.endPosition.z + 32
                ),
                angles: .zero
            ),
            linearVelocity: .zero,
            angularVelocity: .zero,
            motionType: .dynamicBody,
            materialIndex: 7,
            isGravityEnabled: true,
            isCollisionEnabled: true,
            startsAwake: true
        )
        var commands = [
            SourcePhysicsCommand(sequence: 3, payload: .createBody(creation)),
        ]
        for tick in 1 ... 80 {
            commands.append(SourcePhysicsCommand(
                sequence: UInt64(tick + 3),
                payload: .simulate(SourcePhysicsSimulateCommand(
                    simulationTick: UInt64(tick)
                ))
            ))
        }
        #expect(throws: SourcePhysicsMaterialTableError
            .missingContactMaterialIndex(bodyID: scene.bodyID)) {
            _ = try environment.execute(
                SourcePhysicsCommandBatch(commands: commands)
            )
        }

        // The create and all preceding simulation commands belonged to the
        // same FIFO slice, so an unattested surface rolls back the whole batch.
        snapshot = try environment.execute(SourcePhysicsCommandBatch(commands: [
            SourcePhysicsCommand(sequence: 3, payload: .query(lineQuery))
        ]))
        #expect(snapshot.bodies.isEmpty)
    }

    @Test("gm_flatgrass referenced brushes also produce usable world geometry")
    func flatgrassGeometryAndQuery() throws {
        let data = try GModGameAssets.data(for: .flatgrass, kind: .bsp)
        let bsp = try SourceBSP(data: data)
        let manifest = try GModGameAssets.manifest()
        let manifestEntry = try #require(manifest.assets.first {
            $0.logicalPath == "maps/gm_flatgrass.bsp"
        })
        let asset = try SourceBSPStaticPhysicsBridge.build(
            bsp: bsp,
            bspSHA256: manifestEntry.sha256,
            contentsMask: SourceMasks.playerSolidBrushOnly
        )
        #expect(!asset.geometry.parts.isEmpty)
        #expect(asset.triangleCount > 0)
        #expect(asset.displacementTriangleCount > 0)
        #expect(!asset.includedDisplacementFaceIndices.isEmpty)

        let worldIdentity = SourceCanonicalEntityIdentity(
            handle: SourceBaseHandle(entryIndex: 0, serialNumber: 73)
        )
        let scene = try asset.makeStaticScene(worldIdentity: worldIdentity)
        let spawn = try firstPlayerStart(in: bsp)
        let start = spawn + SourceVector3(0, 0, 512)
        let end = spawn + SourceVector3(0, 0, -4_096)
        let environment = SourceDeterministicPhysicsEnvironment(
            staticCollisionScene: scene
        )
        let query = try SourcePhysicsQueryCommand(
            queryID: 902,
            geometry: .lineSegment(start: start, end: end),
            contentsMask: SourceMasks.playerSolidBrushOnly.rawValue,
            collisionGroup: 0,
            scope: .staticOnly,
            ignoredEntities: []
        )
        let snapshot = try environment.execute(SourcePhysicsCommandBatch(
            commands: [SourcePhysicsCommand(sequence: 1, payload: .query(query))]
        ))
        let hit = try #require(snapshot.queryResults.first?.hit)
        #expect(hit.bodyID == scene.bodyID)
        #expect(hit.bodyID.entityIdentity.serialNumber == 73)
        #expect(hit.normal.z > 0.9)
        #expect(hit.materialIndex == nil)
        #expect(
            environment.latestStaticBroadphaseDiagnostics.candidatePartCount <
                asset.geometry.parts.count
        )
    }

    private enum FixtureError: Error {
        case missingPlayerStart
        case invalidOrigin(String)
    }

    private func firstPlayerStart(in bsp: SourceBSP) throws -> SourceVector3 {
        guard let entity = try bsp.entities.parsedEntities().first(where: {
            $0.value(forKey: "classname") == "info_player_start"
        }) else {
            throw FixtureError.missingPlayerStart
        }
        let origin = try #require(entity.value(forKey: "origin"))
        let components = origin.split(whereSeparator: \.isWhitespace)
        guard components.count == 3,
              let x = Float(components[0]),
              let y = Float(components[1]),
              let z = Float(components[2]) else {
            throw FixtureError.invalidOrigin(origin)
        }
        return SourceVector3(x, y, z)
    }

    private func makeCubeShape() throws -> SourcePhysicsShapeSnapshot {
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
}
