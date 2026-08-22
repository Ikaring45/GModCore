import Foundation
import GModEngine
@testable import GModApp
@testable import GModGameSession
import GModMetal
import XCTest

final class GModFirstPersonViewModelMetalSceneBuilderTests: XCTestCase {
    func testBuildUsesExactProjectionResourceAndDiagnosesMissingMaterial() throws {
        let probe = ViewModelMaterialProbe()
        let builder = try GModFirstPersonViewModelMetalSceneBuilder(
            resolveMaterial: { [probe] candidate in
                probe.resolve(candidate)
            }
        )
        let projection = makeProjection()
        let scene = try XCTUnwrap(builder.build(
            from: GModFirstPersonViewModelSceneSnapshot(
                revision: 1,
                sourceProjectionCursor: cursor(sequence: 7),
                projection: projection,
                status: .available
            ),
            applicationGeneration: 2,
            laneGeneration: 3
        ))

        XCTAssertEqual(scene.playerIdentity, projection.playerIdentity)
        XCTAssertEqual(scene.weaponIdentity, projection.weaponIdentity)
        XCTAssertEqual(scene.normalizedViewModelPath, projection.viewModel.path)
        XCTAssertEqual(scene.sourceFieldOfViewDegrees, 62)
        XCTAssertEqual(
            scene.resource.drawRanges.first?.materialResolution,
            .sourceMissing
        )
        XCTAssertEqual(
            probe.calls,
            ["materials/models/weapons/v_toolgun.vmt"]
        )
    }

    func testClearProjectionRemovesPreviouslyPublishedViewModel() throws {
        let builder = try GModFirstPersonViewModelMetalSceneBuilder {
            _ in .materialMissing
        }
        _ = try builder.build(
            from: GModFirstPersonViewModelSceneSnapshot(
                revision: 1,
                sourceProjectionCursor: cursor(sequence: 1),
                projection: makeProjection(),
                status: .available
            ),
            applicationGeneration: 1,
            laneGeneration: 1
        )

        let cleared = try builder.build(
            from: GModFirstPersonViewModelSceneSnapshot(
                revision: 2,
                sourceProjectionCursor: cursor(sequence: 2),
                projection: nil,
                status: .unavailableNoActiveWeapon(
                    identity(index: 1, serial: 1)
                )
            ),
            applicationGeneration: 1,
            laneGeneration: 1
        )

        XCTAssertNil(cleared)
        XCTAssertNil(builder.currentScene)
    }

    private func makeProjection() -> GModFirstPersonViewModelProjection {
        let path = "models/weapons/c_toolgun.mdl"
        let checksum: Int32 = 33
        let resource = GModStudioRenderableModelResource(
            id: GModStudioRenderableModelResourceID(
                normalizedModelPath: path,
                checksum: checksum,
                bodyValue: 0,
                skinFamilyIndex: 0
            ),
            model: GModStudioRenderableModelSnapshot(
                checksum: checksum,
                modelName: path,
                lodIndex: 0,
                bodyValue: 0,
                skinFamilyIndex: 0,
                vertices: [
                    vertex(0, 0), vertex(1, 0), vertex(0, 1),
                ],
                indices: [0, 1, 2],
                drawRanges: [GModStudioRenderableDrawRange(
                    bodyPartIndex: 0,
                    submodelIndex: 0,
                    meshIndex: 0,
                    firstIndex: 0,
                    indexCount: 3,
                    material: GModStudioRenderableMaterial(
                        sourceMaterialIndex: 0,
                        skinFamilyIndex: 0,
                        textureIndex: 0,
                        textureName: "toolgun",
                        vmtCandidates: [
                            "materials/models/weapons/v_toolgun.vmt",
                        ]
                    )
                )]
            )
        )
        return GModFirstPersonViewModelProjection(
            playerIdentity: identity(index: 1, serial: 1),
            weaponIdentity: identity(index: 18, serial: 2),
            weaponClassName: "gmod_tool",
            sourceWeaponRevision: 5,
            viewModel: SourceEntityModelReference(path),
            worldModel: SourceEntityModelReference(
                "models/weapons/w_toolgun.mdl"
            ),
            viewModelFieldOfViewDegrees: 62,
            resource: resource
        )
    }

    private func vertex(_ x: Float, _ y: Float) -> GModDynamicModelVertex {
        GModDynamicModelVertex(
            position: SourceVector3(x, y, 0),
            normal: SourceVector3(0, 0, 1),
            textureCoordinate: SourceStudioTextureCoordinate(u: x, v: y)
        )
    }

    private func cursor(
        sequence: UInt64
    ) -> SourceEntityReplicationCursor {
        SourceEntityReplicationCursor(
            connectionGeneration: SourceEntityReplicationConnectionGeneration(
                rawValue: 4
            ),
            sequence: sequence
        )
    }

    private func identity(
        index: Int,
        serial: Int
    ) -> SourceCanonicalEntityIdentity {
        SourceCanonicalEntityIdentity(handle: SourceBaseHandle(
            entryIndex: index,
            serialNumber: serial
        ))
    }
}

private final class ViewModelMaterialProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var callsStorage: [String] = []

    var calls: [String] {
        lock.lock()
        defer { lock.unlock() }
        return callsStorage
    }

    func resolve(
        _ candidate: String
    ) -> GModMetalStudioMaterialCandidateResolution {
        lock.lock()
        callsStorage.append(candidate)
        lock.unlock()
        return .materialMissing
    }
}
