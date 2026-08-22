import GModEngine
@testable import GModMetal
import XCTest

final class GModMetalFirstPersonViewModelSceneTests: XCTestCase {
    func testConvertsActualStudioResourceWithoutWorldInstance() throws {
        let source = resourceInput()
        let scene = try GModMetalFirstPersonViewModelScene(
            generation: generation(),
            revision: 3,
            playerIdentity: identity(index: 1, serial: 2),
            weaponIdentity: identity(index: 18, serial: 4),
            weaponClassName: "gmod_tool",
            sourceWeaponRevision: 9,
            normalizedViewModelPath: source.id.normalizedModelPath,
            sourceFieldOfViewDegrees: 62,
            resource: source
        )

        XCTAssertEqual(scene.resource.id, source.id)
        XCTAssertEqual(scene.resource.vertices.count, 3)
        XCTAssertEqual(scene.resource.indices, [0, 1, 2])
        XCTAssertEqual(scene.resource.drawRanges.count, 1)
        XCTAssertEqual(scene.sourceFieldOfViewDegrees, 62)
        XCTAssertEqual(scene.sourceWeaponRevision, 9)
        XCTAssertGreaterThan(scene.retainedGeometryByteCount, 0)
        let vertical = try XCTUnwrap(
            GModMetalFirstPersonViewModelRenderContract
                .verticalFieldOfViewRadians(for: scene)
        )
        XCTAssertEqual(vertical * 180 / .pi, 48.517, accuracy: 0.001)
        XCTAssertTrue(
            GModMetalFirstPersonViewModelRenderContract.clearsDepthAfterWorld
        )
        XCTAssertTrue(
            GModMetalFirstPersonViewModelRenderContract.rendersBeforeVGUI
        )
        XCTAssertFalse(
            GModMetalFirstPersonViewModelRenderContract
                .substitutesMissingSourceMaterials
        )
    }

    func testRejectsResourceFromDifferentViewModel() throws {
        let source = resourceInput()
        XCTAssertThrowsError(try GModMetalFirstPersonViewModelScene(
            generation: generation(),
            revision: 1,
            playerIdentity: identity(index: 1, serial: 1),
            weaponIdentity: identity(index: 4, serial: 1),
            weaponClassName: "weapon_pistol",
            sourceWeaponRevision: 1,
            normalizedViewModelPath: "models/weapons/c_pistol.mdl",
            sourceFieldOfViewDegrees: 62,
            resource: source
        )) { error in
            XCTAssertEqual(
                error as? GModMetalFirstPersonViewModelSceneError,
                .viewModelResourceMismatch(
                    expected: "models/weapons/c_pistol.mdl",
                    received: "models/weapons/c_toolgun.mdl"
                )
            )
        }
    }

    func testRejectsNonSourceViewModelFOV() throws {
        let source = resourceInput()
        XCTAssertThrowsError(try GModMetalFirstPersonViewModelScene(
            generation: generation(),
            revision: 1,
            playerIdentity: identity(index: 1, serial: 1),
            weaponIdentity: identity(index: 4, serial: 1),
            weaponClassName: "weapon_pistol",
            sourceWeaponRevision: 1,
            normalizedViewModelPath: source.id.normalizedModelPath,
            sourceFieldOfViewDegrees: .nan,
            resource: source
        )) { error in
            guard case .invalidSourceFieldOfView =
                    error as? GModMetalFirstPersonViewModelSceneError else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    private func generation() -> GModMetalDynamicEntitySceneGeneration {
        GModMetalDynamicEntitySceneGeneration(
            application: 2,
            lane: 3,
            sourceConnection: SourceEntityReplicationConnectionGeneration(
                rawValue: 4
            )
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

    private func resourceInput() -> GModMetalDynamicEntityResourceInput {
        let id = GModMetalDynamicEntityResourceID(
            normalizedModelPath: "models/weapons/c_toolgun.mdl",
            checksum: 44,
            bodyValue: 0,
            skinFamilyIndex: 0
        )
        return GModMetalDynamicEntityResourceInput(
            id: id,
            checksum: 44,
            modelName: "models/weapons/c_toolgun.mdl",
            lodIndex: 0,
            bodyValue: 0,
            skinFamilyIndex: 0,
            vertices: [
                vertex(0, 0, 0),
                vertex(1, 0, 0),
                vertex(0, 1, 0),
            ],
            indices: [0, 1, 2],
            drawRanges: [GModMetalDynamicEntityDrawRange(
                bodyPartIndex: 0,
                submodelIndex: 0,
                meshIndex: 0,
                firstIndex: 0,
                indexCount: 3,
                material: GModMetalDynamicEntityMaterialBinding(
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
    }

    private func vertex(
        _ x: Float,
        _ y: Float,
        _ z: Float
    ) -> GModMetalDynamicEntitySourceVertex {
        GModMetalDynamicEntitySourceVertex(
            position: SourceVector3(x, y, z),
            normal: SourceVector3(0, 0, 1),
            textureCoordinate: SIMD2<Float>(x, y)
        )
    }
}
