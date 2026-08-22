import GModGameAssets
import Testing
@testable import GModEngine

@Suite("Real BSP displacement physics geometry")
struct SourceBSPDisplacementPhysicsGeometryTests {
    @Test(
        "world displacements preserve compiled vertices tags and topology",
        arguments: [GModBundledMap.construct, GModBundledMap.flatgrass]
    )
    func realMapGeometry(asset: GModBundledMap) throws {
        let bsp = try SourceBSP(data: GModGameAssets.data(for: asset, kind: .bsp))
        let geometry = try SourceBSPDisplacementPhysicsGeometryBuilder.build(
            bsp: bsp,
            contentsMask: SourceMasks.playerSolidBrushOnly
        )
        #expect(!geometry.meshes.isEmpty)
        #expect(geometry.triangleCount > 0)

        let world = try #require(bsp.models.first)
        let worldFaces = Int(world.firstFace) ..<
            Int(world.firstFace + world.faceCount)
        for mesh in geometry.meshes {
            #expect(worldFaces.contains(mesh.faceIndex))
            let info = bsp.displacementInfo[mesh.displacementInfoIndex]
            #expect(mesh.faceIndex == Int(info.mapFaceIndex))
            #expect(mesh.vertices.count == info.vertexCount)
            #expect(
                mesh.triangles.count + mesh.removedTriangleCount +
                    mesh.degenerateTriangleCount == info.triangleCount
            )
            #expect(mesh.triangles.allSatisfy { $0.materialIndex == nil })
            #expect(mesh.triangles.allSatisfy {
                mesh.vertices.indices.contains($0.first) &&
                    mesh.vertices.indices.contains($0.second) &&
                    mesh.vertices.indices.contains($0.third)
            })
        }
    }

    @Test("renderer and physics share every Source recursive terrain index")
    func topologyCounts() {
        for power in 2 ... 4 {
            let indices = SourceBSPDisplacementTopology.triangleIndices(
                power: power
            )
            let sideCells = 1 << power
            #expect(indices.count == sideCells * sideCells * 2 * 3)
            #expect(indices.allSatisfy {
                Int($0) < (sideCells + 1) * (sideCells + 1)
            })
        }
    }
}
