import XCTest
@testable import GModEngine

final class SourceStudioBodyGroupSelectionTests: XCTestCase {
    func testAppliesSelectionsWithStudioBasesAndRetainsOmittedGroups() throws {
        let mesh = makeMesh(modelCounts: [2, 3, 1], bases: [1, 2, 6])

        XCTAssertEqual(
            try mesh.bodyValue(applyingBodyGroups: "120", to: 0),
            5
        )
        XCTAssertEqual(
            try mesh.bodyValue(applyingBodyGroups: "0", to: 5),
            4
        )
        XCTAssertEqual(
            try mesh.bodyValue(applyingBodyGroups: "000000000", to: 0),
            0
        )
    }

    func testDecodesAlphabeticalSubModelIDs() throws {
        let mesh = makeMesh(modelCounts: [12], bases: [1])
        XCTAssertEqual(
            try mesh.bodyValue(applyingBodyGroups: "b", to: 0),
            11
        )
    }

    func testRejectsInvalidCharacterSelectionAndLayout() throws {
        let mesh = makeMesh(modelCounts: [2], bases: [1])
        XCTAssertThrowsError(
            try mesh.bodyValue(applyingBodyGroups: "A", to: 0)
        ) { error in
            XCTAssertEqual(
                error as? SourceStudioBodyGroupSelectionError,
                .invalidCharacter("A", bodyGroupID: 0)
            )
        }
        XCTAssertThrowsError(
            try mesh.bodyValue(applyingBodyGroups: "2", to: 0)
        ) { error in
            XCTAssertEqual(
                error as? SourceStudioBodyGroupSelectionError,
                .invalidSelection(bodyGroupID: 0, selection: 2, modelCount: 2)
            )
        }

        let invalidLayout = makeMesh(modelCounts: [2], bases: [0])
        XCTAssertThrowsError(
            try invalidLayout.bodyValue(applyingBodyGroups: "1", to: 0)
        ) { error in
            XCTAssertEqual(
                error as? SourceStudioBodyGroupSelectionError,
                .invalidModelSelectionBase(bodyGroupID: 0, base: 0)
            )
        }
    }

    func testDecodesButIgnoresBodyGroupIDsOutsideStudioTable() throws {
        let mesh = makeMesh(modelCounts: [2], bases: [1])
        XCTAssertEqual(
            try mesh.bodyValue(applyingBodyGroups: "100000000", to: 0),
            1
        )
        XCTAssertThrowsError(
            try mesh.bodyValue(applyingBodyGroups: "10?", to: 0)
        )
    }

    private func makeMesh(
        modelCounts: [Int],
        bases: [Int32]
    ) -> SourceStudioModelMeshSnapshot {
        precondition(modelCounts.count == bases.count)
        return SourceStudioModelMeshSnapshot(
            checksum: 17,
            modelName: "bodygroup_test",
            lodIndex: 0,
            bodyParts: modelCounts.indices.map { bodyPartIndex in
                SourceStudioBodyPartMeshSnapshot(
                    index: bodyPartIndex,
                    name: "body_\(bodyPartIndex)",
                    modelSelectionBase: bases[bodyPartIndex],
                    models: (0..<modelCounts[bodyPartIndex]).map { modelIndex in
                        SourceStudioSubmodelSnapshot(
                            index: modelIndex,
                            name: "model_\(modelIndex)",
                            type: 0,
                            boundingRadius: 1,
                            rootLODVertexCount: 0,
                            meshes: []
                        )
                    }
                )
            }
        )
    }
}
