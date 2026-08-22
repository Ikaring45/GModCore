import XCTest
import GModEngine
import GModGameAssets
@testable import GModMetal

final class GModMetalSky3DVisibilityTests: XCTestCase {
    func testAuthoredConstructVTFDrivesSkyMipSamplerLOD() throws {
        let bsp = try SourceBSP(
            data: GModGameAssets.data(for: .construct, kind: .bsp)
        )
        let pak = try SourceBSPPakFileSystem(bsp: bsp)
        let resolver = GModMetalSurfaceSourceMaterialResolver { path in
            try pak.data(for: path)
        }
        let bitmap = try XCTUnwrap(resolver.resolveWorldTexture(
            named: "maps/gm_construct/c1436_-571_-71"
        ))

        XCTAssertEqual(
            bitmap.mipLevels.map { [$0.width, $0.height] },
            [[32, 32], [16, 16], [8, 8], [4, 4], [2, 2], [1, 1]]
        )
        let sampler = GModMetalWorldSamplerConfiguration(
            bitmap: bitmap,
            renderLayer: .sky3D
        )
        XCTAssertEqual(sampler.mipFilter, .nearest)
        XCTAssertEqual(sampler.sAddressMode, .clampToEdge)
        XCTAssertEqual(sampler.tAddressMode, .clampToEdge)
        XCTAssertEqual(sampler.maximumAnisotropy, 1)
    }

    func testSkyWorkspaceUsesFixedSkyCameraPVSAndBakedFrustum() throws {
        let scene = makeScene()
        let skyVisibility = try XCTUnwrap(scene.sky3DVisibility)
        let workspace = GModMetalWorldVisibilityWorkspace()

        XCTAssertTrue(workspace.update(
            scene: scene,
            visibility: skyVisibility.bspVisibility,
            renderLayer: .sky3D,
            sourceCameraEye: skyVisibility.sourceVisibilityOrigin,
            metalCameraEye: .zero,
            metalCameraForward: SIMD3<Float>(0, 0, -1),
            metalCameraUp: SIMD3<Float>(0, 1, 0),
            verticalFieldOfViewRadians: .pi / 2,
            aspectRatio: 1,
            nearPlane: 1,
            farPlane: 100
        ))
        XCTAssertEqual(workspace.visibleDrawSpans, [
            GModMetalWorldVisibleIndexSpan(
                materialRangeIndex: 0,
                firstIndex: 0,
                indexCount: 3
            ),
        ])
        XCTAssertEqual(workspace.metrics, GModMetalWorldVisibilityMetrics(
            sourceSpanCount: 2,
            sourceIndexCount: 6,
            visibleSpanCount: 1,
            visibleIndexCount: 3,
            drawSpanCount: 1
        ))
    }

    func testSkyWorkspaceFailsOpenWhenMetadataTargetsWrongLayer() throws {
        let scene = makeScene()
        let visibility = try XCTUnwrap(scene.sky3DVisibility?.bspVisibility)
        let workspace = GModMetalWorldVisibilityWorkspace()

        XCTAssertFalse(workspace.update(
            scene: scene,
            visibility: visibility,
            renderLayer: .world,
            sourceCameraEye: SIMD3<Float>(1, 0, 0),
            metalCameraEye: .zero,
            metalCameraForward: SIMD3<Float>(0, 0, -1),
            metalCameraUp: SIMD3<Float>(0, 1, 0),
            verticalFieldOfViewRadians: .pi / 2,
            aspectRatio: 1,
            nearPlane: 1,
            farPlane: 100
        ))
        XCTAssertTrue(workspace.visibleDrawSpans.isEmpty)
        XCTAssertNil(workspace.metrics)
    }

    private func makeScene() -> GModMetalWorldScene {
        let visibility = GModMetalWorldVisibility(
            headNode: 0,
            planes: [GModMetalWorldVisibilityPlane(
                sourceNormal: SIMD3<Float>(1, 0, 0),
                distance: 0
            )],
            nodes: [GModMetalWorldVisibilityNode(
                planeIndex: 0,
                frontChild: -1,
                backChild: -2
            )],
            leafClusters: [0, 1],
            potentialVisibility: GModMetalWorldPotentialVisibility(
                clusterCount: 2,
                encodedBytes: [0b0000_0001, 0b0000_0010],
                pvsOffsets: [0, 1]
            ),
            spans: [
                GModMetalWorldVisibilitySpan(
                    materialRangeIndex: 0,
                    firstIndex: 0,
                    indexCount: 3,
                    metalMinimum: SIMD3<Float>(-1, -1, -12),
                    metalMaximum: SIMD3<Float>(1, 1, -10),
                    clusterStartIndex: 0,
                    clusterCount: 1
                ),
                GModMetalWorldVisibilitySpan(
                    materialRangeIndex: 1,
                    firstIndex: 3,
                    indexCount: 3,
                    metalMinimum: SIMD3<Float>(-1, -1, -12),
                    metalMaximum: SIMD3<Float>(1, 1, -10),
                    clusterStartIndex: 1,
                    clusterCount: 1
                ),
            ],
            spanClusters: [0, 1]
        )
        return GModMetalWorldScene(
            meshIdentifier: "sky-visibility-fixture",
            sourcePositions: Array(repeating: .zero, count: 6),
            sourceNormals: Array(
                repeating: SIMD3<Float>(0, 0, 1),
                count: 6
            ),
            indices: [0, 1, 2, 3, 4, 5],
            materialRanges: [
                GModMetalWorldMaterialRange(
                    materialName: "sky/visible",
                    firstIndex: 0,
                    indexCount: 3,
                    bitmap: nil,
                    renderLayer: .sky3D
                ),
                GModMetalWorldMaterialRange(
                    materialName: "sky/pvs-hidden",
                    firstIndex: 3,
                    indexCount: 3,
                    bitmap: nil,
                    renderLayer: .sky3D
                ),
            ],
            sky3D: GModMetalWorldSky3D(
                sourceOrigin: SIMD3<Float>(1, 0, 0),
                scale: 16
            ),
            sky3DVisibility: GModMetalSky3DVisibility(
                sourceVisibilityOrigin: SIMD3<Float>(1, 0, 0),
                bspVisibility: visibility
            ),
            skyboxVisibility: .sky3D,
            cameraEye: .zero,
            cameraForward: SIMD3<Float>(1, 0, 0)
        )
    }
}
