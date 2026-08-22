import XCTest
@testable import GModEngine
@testable import GModGameSession

final class GModDynamicModelMeshTests: XCTestCase {
    func testBuildsDefaultBodyModelsAndExpandsTriangleStripWinding() throws {
        let first = makeSubmodel(index: 0, material: 3, topology: .triangleList)
        let selected = makeSubmodel(index: 1, material: 7, topology: .triangleStrip)
        let snapshot = SourceStudioModelMeshSnapshot(
            checksum: 42,
            modelName: "models/props/test.mdl",
            lodIndex: 0,
            bodyParts: [SourceStudioBodyPartMeshSnapshot(
                index: 0,
                name: "body",
                modelSelectionBase: 1,
                models: [first, selected]
            )]
        )

        let mesh = try GModDynamicModelMeshBuilder.build(
            from: snapshot,
            bodyValue: 1
        )

        XCTAssertEqual(mesh.vertices.count, 4)
        XCTAssertEqual(mesh.indices, [0, 1, 2, 2, 1, 3])
        XCTAssertEqual(mesh.ranges.map(\.materialIndex), [7])
        XCTAssertEqual(mesh.ranges.first?.submodelIndex, 1)
    }

    func testDegenerateStripTrianglesAreSkipped() throws {
        let group = makeStripGroup(
            topology: .triangleStrip,
            rawIndices: [0, 1, 1, 2, 3]
        )
        let snapshot = makeSnapshot(group: group)

        let mesh = try GModDynamicModelMeshBuilder.build(from: snapshot)

        XCTAssertEqual(mesh.indices, [1, 2, 3])
        XCTAssertEqual(mesh.ranges.first?.indexCount, 3)
    }

    func testRejectsIndexAndBudgetViolationsWithoutPartialResult() throws {
        let invalid = makeStripGroup(
            topology: .triangleList,
            rawIndices: [0, 1, 9]
        )
        XCTAssertThrowsError(try GModDynamicModelMeshBuilder.build(
            from: makeSnapshot(group: invalid)
        )) { error in
            XCTAssertEqual(
                error as? GModDynamicModelMeshBuildError,
                .invalidVertexIndex(value: 9, available: 4)
            )
        }

        XCTAssertThrowsError(try GModDynamicModelMeshBuilder.build(
            from: makeSnapshot(group: makeStripGroup(
                topology: .triangleList,
                rawIndices: [0, 1, 2]
            )),
            policy: GModDynamicModelMeshBuildPolicy(
                maximumVertices: 3,
                maximumIndices: 16
            )
        )) { error in
            XCTAssertEqual(
                error as? GModDynamicModelMeshBuildError,
                .vertexBudgetExceeded(requested: 4, cap: 3)
            )
        }
    }

    private func makeSnapshot(
        group: SourceStudioStripGroupSnapshot
    ) -> SourceStudioModelMeshSnapshot {
        SourceStudioModelMeshSnapshot(
            checksum: 1,
            modelName: "models/props/test.mdl",
            lodIndex: 0,
            bodyParts: [SourceStudioBodyPartMeshSnapshot(
                index: 0,
                name: "body",
                modelSelectionBase: 1,
                models: [SourceStudioSubmodelSnapshot(
                    index: 0,
                    name: "model",
                    type: 0,
                    boundingRadius: 1,
                    rootLODVertexCount: 4,
                    meshes: [SourceStudioMeshSnapshot(
                        index: 0,
                        materialIndex: 2,
                        meshID: 0,
                        center: .zero,
                        rootLODVertexCount: 4,
                        stripGroups: [group]
                    )]
                )]
            )]
        )
    }

    private func makeSubmodel(
        index: Int,
        material: Int32,
        topology: SourceStudioMeshTopology
    ) -> SourceStudioSubmodelSnapshot {
        SourceStudioSubmodelSnapshot(
            index: index,
            name: "model\(index)",
            type: 0,
            boundingRadius: 1,
            rootLODVertexCount: 4,
            meshes: [SourceStudioMeshSnapshot(
                index: 0,
                materialIndex: material,
                meshID: Int32(index),
                center: .zero,
                rootLODVertexCount: 4,
                stripGroups: [makeStripGroup(
                    topology: topology,
                    rawIndices: topology == .triangleList
                        ? [0, 1, 2]
                        : [0, 1, 2, 3]
                )]
            )]
        )
    }

    private func makeStripGroup(
        topology: SourceStudioMeshTopology,
        rawIndices: [UInt16]
    ) -> SourceStudioStripGroupSnapshot {
        let vertices = (0..<4).map { index in
            SourceStudioMeshVertexSnapshot(
                stripGroupVertexIndex: index,
                originalMeshVertexIndex: index,
                rootLODVertexIndex: index,
                sourceVVDVertexIndex: index,
                position: SourceVector3(Float(index), 0, 0),
                normal: SourceVector3(0, 0, 1),
                textureCoordinate: SourceStudioTextureCoordinate(
                    u: Float(index) / 3,
                    v: 0
                ),
                tangent: nil,
                boneInfluences: [],
                optimizedBoneReferences: []
            )
        }
        return SourceStudioStripGroupSnapshot(
            index: 0,
            flags: 0,
            vertices: vertices,
            indices: rawIndices,
            strips: [SourceStudioStripSnapshot(
                index: 0,
                topology: topology,
                indexRange: SourceStudioMeshRange(
                    offset: 0,
                    count: rawIndices.count
                ),
                vertexRange: SourceStudioMeshRange(
                    offset: 0,
                    count: vertices.count
                ),
                boneCount: 0,
                boneStateChanges: []
            )]
        )
    }
}
