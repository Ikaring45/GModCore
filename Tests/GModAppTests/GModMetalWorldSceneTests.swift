import Foundation
import XCTest
import GModEngine
@testable import GModMetal

final class GModMetalWorldSceneTests: XCTestCase {
    func testSourceDefaultHorizontalFOVUsesVerticalProjectionAngle() throws {
        let vertical = try XCTUnwrap(
            GModMetalSourceFOVContract.verticalRadians(
                baseHorizontalDegrees: 75
            )
        )
        XCTAssertEqual(vertical * 180 / .pi, 59.840_44, accuracy: 0.000_1)
        XCTAssertEqual(
            GModMetalSourceFOVContract.defaultWorldVerticalRadians,
            vertical
        )
        XCTAssertNil(GModMetalSourceFOVContract.verticalRadians(
            baseHorizontalDegrees: 0
        ))
        XCTAssertNil(GModMetalSourceFOVContract.verticalRadians(
            baseHorizontalDegrees: 180
        ))

        let widened = try XCTUnwrap(
            GModMetalSourceFOVContract.verticalRadians(
                baseHorizontalDegrees: 100
            )
        )
        let scene = fixtureScene(materialRanges: []).updatingCamera(
            eye: SIMD3<Float>(1, 2, 3),
            forward: SIMD3<Float>(1, 0, 0),
            verticalFieldOfViewRadians: widened
        )
        XCTAssertEqual(scene.verticalFieldOfViewRadians, widened)
        XCTAssertEqual(
            scene.updatingCamera(
                eye: SIMD3<Float>(4, 5, 6),
                forward: SIMD3<Float>(0, 1, 0)
            ).verticalFieldOfViewRadians,
            widened
        )
    }

    func testWorldVisibilityWorkspacePreservesOrderCoalescesAndCachesView() {
        let visibility = fixtureWorldVisibility(
            potentialVisibility: GModMetalWorldPotentialVisibility(
                clusterCount: 2,
                encodedBytes: [0b0000_0001],
                pvsOffsets: [0, 0]
            )
        )
        let scene = fixtureVisibilityScene(visibility: visibility)
        let workspace = GModMetalWorldVisibilityWorkspace()

        XCTAssertTrue(workspace.update(
            scene: scene,
            sourceCameraEye: SIMD3<Float>(1, 0, 0),
            metalCameraEye: SIMD3<Float>(0, 0, -1),
            metalCameraForward: SIMD3<Float>(0, 0, -1),
            metalCameraUp: SIMD3<Float>(0, 1, 0),
            verticalFieldOfViewRadians:
                GModMetalSourceFOVContract.defaultWorldVerticalRadians,
            aspectRatio: 4.0 / 3.0,
            nearPlane: 1,
            farPlane: 65_536
        ))
        XCTAssertEqual(workspace.metrics, GModMetalWorldVisibilityMetrics(
            sourceSpanCount: 4,
            sourceIndexCount: 12,
            visibleSpanCount: 2,
            visibleIndexCount: 6,
            drawSpanCount: 1
        ))
        XCTAssertEqual(workspace.visibleDrawSpans, [
            GModMetalWorldVisibleIndexSpan(
                materialRangeIndex: 0,
                firstIndex: 0,
                indexCount: 6
            ),
        ])
        XCTAssertEqual(workspace.rebuildCount, 1)

        XCTAssertTrue(workspace.update(
            scene: scene,
            sourceCameraEye: SIMD3<Float>(1, 0, 0),
            metalCameraEye: SIMD3<Float>(0, 0, -1),
            metalCameraForward: SIMD3<Float>(0, 0, -1),
            metalCameraUp: SIMD3<Float>(0, 1, 0),
            verticalFieldOfViewRadians:
                GModMetalSourceFOVContract.defaultWorldVerticalRadians,
            aspectRatio: 4.0 / 3.0,
            nearPlane: 1,
            farPlane: 65_536
        ))
        XCTAssertEqual(workspace.rebuildCount, 1)
        XCTAssertEqual(
            scene.updatingCamera(
                eye: SIMD3<Float>(2, 0, 0),
                forward: SIMD3<Float>(1, 0, 0)
            ).worldVisibility,
            visibility
        )
    }

    func testWorldVisibilityWorkspaceFailsOpenWithoutUsablePVS() {
        let workspace = GModMetalWorldVisibilityWorkspace()
        let missingPVS = fixtureVisibilityScene(
            visibility: fixtureWorldVisibility(potentialVisibility: nil)
        )
        XCTAssertFalse(workspace.update(
            scene: missingPVS,
            sourceCameraEye: SIMD3<Float>(1, 0, 0),
            metalCameraEye: SIMD3<Float>(0, 0, -1),
            metalCameraForward: SIMD3<Float>(0, 0, -1),
            metalCameraUp: SIMD3<Float>(0, 1, 0),
            verticalFieldOfViewRadians:
                GModMetalSourceFOVContract.defaultWorldVerticalRadians,
            aspectRatio: 4.0 / 3.0,
            nearPlane: 1,
            farPlane: 65_536
        ))
        XCTAssertNil(workspace.metrics)
        XCTAssertTrue(workspace.visibleDrawSpans.isEmpty)
        XCTAssertEqual(workspace.rebuildCount, 1)
        XCTAssertFalse(workspace.update(
            scene: missingPVS,
            sourceCameraEye: SIMD3<Float>(1, 0, 0),
            metalCameraEye: SIMD3<Float>(0, 0, -1),
            metalCameraForward: SIMD3<Float>(0, 0, -1),
            metalCameraUp: SIMD3<Float>(0, 1, 0),
            verticalFieldOfViewRadians:
                GModMetalSourceFOVContract.defaultWorldVerticalRadians,
            aspectRatio: 4.0 / 3.0,
            nearPlane: 1,
            farPlane: 65_536
        ))
        XCTAssertEqual(workspace.rebuildCount, 1)

        let invalidLeaf = GModMetalWorldVisibility(
            headNode: 4,
            planes: missingPVS.worldVisibility?.planes ?? [],
            nodes: missingPVS.worldVisibility?.nodes ?? [],
            leafClusters: missingPVS.worldVisibility?.leafClusters ?? [],
            potentialVisibility: GModMetalWorldPotentialVisibility(
                clusterCount: 2,
                encodedBytes: [1],
                pvsOffsets: [0, 0]
            ),
            spans: missingPVS.worldVisibility?.spans ?? [],
            spanClusters: missingPVS.worldVisibility?.spanClusters ?? []
        )
        workspace.reset()
        XCTAssertFalse(workspace.update(
            scene: fixtureVisibilityScene(visibility: invalidLeaf),
            sourceCameraEye: SIMD3<Float>(1, 0, 0),
            metalCameraEye: SIMD3<Float>(0, 0, -1),
            metalCameraForward: SIMD3<Float>(0, 0, -1),
            metalCameraUp: SIMD3<Float>(0, 1, 0),
            verticalFieldOfViewRadians:
                GModMetalSourceFOVContract.defaultWorldVerticalRadians,
            aspectRatio: 4.0 / 3.0,
            nearPlane: 1,
            farPlane: 65_536
        ))
        XCTAssertEqual(workspace.rebuildCount, 2)
        XCTAssertNil(workspace.metrics)
        XCTAssertTrue(workspace.visibleDrawSpans.isEmpty)
    }

    func testEnvSunDirectionAndGlowContractSurviveCameraUpdates() throws {
        let bitmap = try fixtureBitmap(named: "sun-core")
        let layer = GModMetalWorldSunSpriteLayer(
            materialName: "sprites/light_glow02_add_noz",
            displayRGB: SIMD3<Float>(1, 240.0 / 241.0, 199.0 / 241.0),
            size: 16,
            materialResolution: .resolved(bitmap)
        )
        let sun = GModMetalWorldSunSprite(
            sourceDirectionToSun: SIMD3<Float>(
                -0.3778211,
                0.5200261,
                0.76604444
            ),
            hdrColorScale: 1,
            core: layer,
            overlay: layer
        )
        let scene = fixtureScene(materialRanges: [], sunSprites: [sun])

        XCTAssertEqual(
            sun.metalDirectionToSun,
            SIMD3<Float>(-0.5200261, 0.76604444, 0.3778211)
        )
        XCTAssertEqual(
            scene.updatingCamera(
                eye: SIMD3<Float>(4, 8, 16),
                forward: SIMD3<Float>(-0.5200261, 0.76604444, 0.3778211)
            ).sunSprites,
            [sun]
        )
        let parameters = try XCTUnwrap(
            GModMetalSunSpriteRenderContract.parameters(
                sun: sun,
                layer: layer,
                role: .core,
                cameraEye: .zero,
                cameraForward: sun.metalDirectionToSun
            )
        )
        XCTAssertEqual(parameters.opacity, 1, accuracy: 0.0001)
        XCTAssertEqual(parameters.hdrColorScale, 1)
        XCTAssertEqual(parameters.basePosition.x, -52.00261, accuracy: 0.001)
        XCTAssertEqual(parameters.basePosition.y, 76.60444, accuracy: 0.001)
        XCTAssertEqual(parameters.basePosition.z, 37.78211, accuracy: 0.001)
        let rightLength = (
            parameters.rightExtent.x * parameters.rightExtent.x +
            parameters.rightExtent.y * parameters.rightExtent.y +
            parameters.rightExtent.z * parameters.rightExtent.z
        ).squareRoot()
        XCTAssertEqual(rightLength, 16, accuracy: 0.01)
        let overlay = try XCTUnwrap(
            GModMetalSunSpriteRenderContract.parameters(
                sun: sun,
                layer: layer,
                role: .overlay,
                cameraEye: .zero,
                cameraForward: sun.metalDirectionToSun
            )
        )
        XCTAssertEqual(overlay.opacity, 0.75, accuracy: 0.0001)
        let overlayRightLength = (
            overlay.rightExtent.x * overlay.rightExtent.x +
            overlay.rightExtent.y * overlay.rightExtent.y +
            overlay.rightExtent.z * overlay.rightExtent.z
        ).squareRoot()
        XCTAssertEqual(overlayRightLength, 16 * 6, accuracy: 0.01)
        XCTAssertNil(
            GModMetalSunSpriteRenderContract.parameters(
                sun: sun,
                layer: layer,
                role: .overlay,
                cameraEye: .zero,
                cameraForward: -sun.metalDirectionToSun
            )
        )
    }

    func testCompiledEnvironmentLightingConvertsDirectionAndSurvivesCameraUpdates() {
        let lighting = GModMetalWorldEnvironmentLighting(
            sourceDirectionFromLight: SIMD3<Float>(0.3287, -0.4524, -0.8290),
            directLinearRGB: SIMD3<Float>(1.5658, 1.4542, 1.2444),
            ambientLinearRGB: SIMD3<Float>(0.3083, 0.4545, 0.5474)
        )
        let scene = fixtureScene(
            materialRanges: [],
            environmentLighting: lighting
        )

        XCTAssertEqual(
            lighting.metalDirectionToLight,
            SIMD3<Float>(-0.4524, 0.8290, 0.3287)
        )
        XCTAssertEqual(scene.environmentLighting, lighting)
        XCTAssertEqual(
            scene.updatingCamera(
                eye: SIMD3<Float>(64, 32, 16),
                forward: SIMD3<Float>(0, 1, 0)
            ).environmentLighting,
            lighting
        )
    }

    func testSourceLeafSkyVisibilityGates2DAnd3DPasses() {
        XCTAssertFalse(
            GModMetalSkyVisibilityRenderContract.draws2D(.notVisible)
        )
        XCTAssertFalse(
            GModMetalSkyVisibilityRenderContract.draws3D(.notVisible)
        )
        XCTAssertTrue(GModMetalSkyVisibilityRenderContract.draws2D(.sky2D))
        XCTAssertFalse(GModMetalSkyVisibilityRenderContract.draws3D(.sky2D))
        XCTAssertTrue(GModMetalSkyVisibilityRenderContract.draws2D(.sky3D))
        XCTAssertTrue(GModMetalSkyVisibilityRenderContract.draws3D(.sky3D))
    }

    func testSourceSkyPassOrderClearsDepthBeforeOrdinaryWorld() {
        XCTAssertEqual(
            GModMetalWorldPassOrderContract.orderedLayers,
            [.sky2D, .sky3D, .world]
        )
        XCTAssertTrue(
            GModMetalWorldPassOrderContract.clearsDepthBetweenSkyAndWorld
        )
    }

    func testMaterialResolutionPreservesMissingDecodeAndRetentionOutcomes() throws {
        let resolved = try fixtureBitmap(named: "resolved-outcome")
        let ranges = [
            GModMetalWorldMaterialRange(
                materialName: "resolved/material",
                firstIndex: 0,
                indexCount: 3,
                materialResolution: .resolved(resolved)
            ),
            GModMetalWorldMaterialRange(
                materialName: "missing/material",
                firstIndex: 3,
                indexCount: 3,
                materialResolution: .sourceMissing
            ),
            GModMetalWorldMaterialRange(
                materialName: "broken/material",
                firstIndex: 6,
                indexCount: 3,
                materialResolution: .decodeFailed("invalid VTF header")
            ),
            GModMetalWorldMaterialRange(
                materialName: "large/material",
                firstIndex: 9,
                indexCount: 3,
                materialResolution: .retentionCapacityExceeded(
                    requiredByteCount: 16,
                    retainedByteCount: 128,
                    maximumByteCount: 128
                )
            ),
        ]
        let scene = fixtureScene(materialRanges: ranges)

        XCTAssertEqual(ranges[0].bitmap, resolved)
        XCTAssertNil(ranges[1].bitmap)
        XCTAssertNil(ranges[2].bitmap)
        XCTAssertNil(ranges[3].bitmap)
        XCTAssertEqual(
            scene.materialDiagnostics.sourceMissingMaterialNames,
            ["missing/material"]
        )
        XCTAssertEqual(
            scene.materialDiagnostics.decodeFailedMaterialNames,
            ["broken/material"]
        )
        XCTAssertEqual(
            scene.materialDiagnostics.retentionCapacityExceededMaterialNames,
            ["large/material"]
        )
        XCTAssertEqual(scene.materialDiagnostics.missingWorldMaterialRangeCount, 3)
    }

    func testRendererFailureRetainsMeshAndTypedDiagnostic() {
        let failure = GModMetalWorldRendererFailure(
            meshIdentifier: "session-9:gm_construct",
            reason: .textureUploadFailed(
                resourceIdentifier: "materials/brick/wall.vtf",
                byteCount: 1_024,
                detail: "MTLDevice.makeTexture returned nil"
            )
        )
        let event = GModMetalWorldFrameEvent.failed(failure)

        XCTAssertEqual(event, .failed(failure))
        XCTAssertEqual(failure.meshIdentifier, "session-9:gm_construct")
        XCTAssertEqual(
            failure.reason.diagnosticDescription,
            "Metal texture upload failed for materials/brick/wall.vtf " +
                "(1024 bytes): MTLDevice.makeTexture returned nil"
        )
    }

    func testSkyboxMaterialBindingsAndMissingMaterialDiagnosticsStayExplicit() throws {
        let bitmap = try fixtureBitmap(named: "resolved")
        var ranges = [
            GModMetalWorldMaterialRange(
                materialName: "brick/wall",
                firstIndex: 0,
                indexCount: 3,
                bitmap: bitmap
            ),
            GModMetalWorldMaterialRange(
                materialName: "missing/wall",
                firstIndex: 3,
                indexCount: 3,
                bitmap: nil
            ),
        ]
        for (offset, face) in GModMetalSkyboxFace.allCases.enumerated() {
            ranges.append(GModMetalWorldMaterialRange(
                materialName: "skybox/painted\(face.rawValue)",
                firstIndex: 6 + offset * 3,
                indexCount: 3,
                bitmap: offset < 2 ? bitmap : nil,
                renderLayer: .sky2D
            ))
        }

        XCTAssertEqual(ranges[2].skyboxName, "painted")
        XCTAssertEqual(ranges[2].skyboxFace, .right)
        XCTAssertNil(ranges[0].skyboxName)
        XCTAssertNil(ranges[0].skyboxFace)

        let scene = fixtureScene(materialRanges: ranges)
        XCTAssertEqual(scene.materialDiagnostics.worldMaterialRangeCount, 2)
        XCTAssertEqual(scene.materialDiagnostics.resolvedWorldMaterialRangeCount, 1)
        XCTAssertEqual(scene.materialDiagnostics.missingWorldMaterialRangeCount, 1)
        XCTAssertEqual(scene.materialDiagnostics.unnamedWorldFallbackRangeCount, 0)
        XCTAssertEqual(scene.materialDiagnostics.unresolvedWorldMaterialNames, ["missing/wall"])
        XCTAssertEqual(scene.materialDiagnostics.skyboxName, "painted")
        XCTAssertEqual(scene.materialDiagnostics.skyboxFaceRangeCount, 6)
        XCTAssertEqual(scene.materialDiagnostics.resolvedSkyboxFaceCount, 2)
        XCTAssertEqual(
            scene.materialDiagnostics.missingSkyboxMaterialNames,
            [
                "skybox/painteddn", "skybox/paintedft",
                "skybox/paintedlf", "skybox/paintedup",
            ]
        )
    }

    func testWorldSamplerUsesAuthoredVTFMipsAndFlags() throws {
        func bitmap(
            _ flags: SourceVTFTextureFlags
        ) throws -> GModMetalSurfaceBitmap {
            let base = Data(repeating: 255, count: 4 * 4 * 4)
            return try GModMetalSurfaceBitmap(
                resourceIdentifier: "sampler-\(flags.rawValue)",
                width: 4,
                height: 4,
                premultipliedRGBA8: base,
                mipLevels: [
                    .init(width: 4, height: 4, premultipliedRGBA8: base),
                    .init(
                        width: 2,
                        height: 2,
                        premultipliedRGBA8: Data(repeating: 128, count: 16)
                    ),
                    .init(
                        width: 1,
                        height: 1,
                        premultipliedRGBA8: Data([64, 64, 64, 255])
                    ),
                ],
                sourceTextureFlags: flags
            )
        }

        let bilinear = GModMetalWorldSamplerConfiguration(
            bitmap: try bitmap([]),
            renderLayer: .world
        )
        XCTAssertEqual(bilinear.minFilter, .linear)
        XCTAssertEqual(bilinear.magFilter, .linear)
        XCTAssertEqual(bilinear.mipFilter, .nearest)
        XCTAssertEqual(bilinear.sAddressMode, .repeat)
        XCTAssertEqual(bilinear.tAddressMode, .repeat)
        XCTAssertEqual(bilinear.maximumAnisotropy, 1)

        let trilinear = GModMetalWorldSamplerConfiguration(
            bitmap: try bitmap([.trilinear, .clampS]),
            renderLayer: .world
        )
        XCTAssertEqual(trilinear.mipFilter, .linear)
        XCTAssertEqual(trilinear.sAddressMode, .clampToEdge)
        XCTAssertEqual(trilinear.tAddressMode, .repeat)

        let pointNoMip = GModMetalWorldSamplerConfiguration(
            bitmap: try bitmap([.pointSample, .noMip, .clampT]),
            renderLayer: .world
        )
        XCTAssertEqual(pointNoMip.minFilter, .nearest)
        XCTAssertEqual(pointNoMip.magFilter, .nearest)
        XCTAssertEqual(pointNoMip.mipFilter, .notMipmapped)
        XCTAssertEqual(pointNoMip.tAddressMode, .clampToEdge)

        let anisotropicSky = GModMetalWorldSamplerConfiguration(
            bitmap: try bitmap([.anisotropic]),
            renderLayer: .sky2D
        )
        XCTAssertEqual(anisotropicSky.mipFilter, .linear)
        XCTAssertEqual(anisotropicSky.maximumAnisotropy, 16)
        XCTAssertEqual(anisotropicSky.sAddressMode, .clampToEdge)
        XCTAssertEqual(anisotropicSky.tAddressMode, .clampToEdge)
    }

    func testSky3DBakedProjectionMatchesValveMiniatureSpace() {
        let sky = GModMetalWorldSky3D(
            sourceOrigin: SIMD3<Float>(-1_428, 1_645, 10_991.2),
            scale: 16
        )
        let planes = GModMetalSky3DProjectionContract.bakedClipPlanes(
            scale: sky.scale
        )

        XCTAssertEqual(planes.near / sky.scale, 2, accuracy: 0.0001)
        XCTAssertEqual(
            planes.far / sky.scale,
            Float(3).squareRoot() * 2 * 16_384,
            accuracy: 0.01
        )
        XCTAssertEqual(
            GModMetalSky3DProjectionContract.sourceCameraEye(
                worldEye: SIMD3<Float>(704, 132, -79),
                sky: sky
            ),
            sky.sourceOrigin + SIMD3<Float>(704, 132, -79) / 16
        )
    }

    func testSky3DFogMatchesSourceDirectionBlendAndRangeCurve() throws {
        let fog = GModMetalWorldSky3DFog(
            blendsColors: true,
            sourcePrimaryDirection: SIMD3<Float>(1, 0, 0),
            primaryDisplayRGB: SIMD3<Float>(1, 0.25, 0),
            secondaryDisplayRGB: SIMD3<Float>(0, 0.5, 1),
            start: 100,
            end: 300,
            maximumDensity: 0.75,
            isRadial: false
        )

        XCTAssertEqual(
            GModMetalSky3DFogContract.resolvedDisplayRGB(
                fog: fog,
                sourceCameraForward: SIMD3<Float>(1, 0, 0)
            ),
            fog.primaryDisplayRGB
        )
        XCTAssertEqual(
            GModMetalSky3DFogContract.resolvedDisplayRGB(
                fog: fog,
                sourceCameraForward: SIMD3<Float>(-1, 0, 0)
            ),
            fog.secondaryDisplayRGB
        )
        XCTAssertEqual(
            GModMetalSky3DFogContract.resolvedDisplayRGB(
                fog: fog,
                sourceCameraForward: SIMD3<Float>(0, 1, 0)
            ),
            (fog.primaryDisplayRGB + fog.secondaryDisplayRGB) * 0.5
        )
        let rawDirectionFog = GModMetalWorldSky3DFog(
            blendsColors: true,
            sourcePrimaryDirection: SIMD3<Float>(2, 0, 0),
            primaryDisplayRGB: SIMD3<Float>(1, 0, 0),
            secondaryDisplayRGB: SIMD3<Float>(0, 0, 1),
            start: 0,
            end: 1,
            maximumDensity: 1,
            isRadial: false
        )
        XCTAssertEqual(
            GModMetalSky3DFogContract.resolvedDisplayRGB(
                fog: rawDirectionFog,
                sourceCameraForward: SIMD3<Float>(1, 0, 0)
            ),
            SIMD3<Float>(1.5, 0, -0.5),
            "Source uses the raw FIELD_VECTOR fog direction without normalization"
        )
        XCTAssertEqual(
            try XCTUnwrap(GModMetalSky3DFogContract.sourceShaderMixFactor(
                distance: 100,
                fog: fog
            )),
            0,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            try XCTUnwrap(GModMetalSky3DFogContract.sourceShaderMixFactor(
                distance: 200,
                fog: fog
            )),
            0.25,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            try XCTUnwrap(GModMetalSky3DFogContract.sourceShaderMixFactor(
                distance: 300,
                fog: fog
            )),
            0.5625,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            try XCTUnwrap(GModMetalSky3DFogContract.sourceShaderMixFactor(
                distance: 1_000,
                fog: fog
            )),
            0.5625,
            accuracy: 0.000_001
        )

        let uniforms = try XCTUnwrap(GModMetalSky3DFogContract.uniforms(
            fog: fog,
            sourceCameraForward: SIMD3<Float>(1, 0, 0),
            metalCameraEye: SIMD3<Float>(4, 5, 6),
            metalCameraForward: SIMD3<Float>(0, 0, -2)
        ))
        XCTAssertEqual(
            uniforms.linearRGB,
            GModMetalWorldColorSpaceContract.decodeDisplaySRGB(
                fog.primaryDisplayRGB
            )
        )
        XCTAssertEqual(uniforms.start, 100)
        XCTAssertEqual(uniforms.end, 300)
        XCTAssertEqual(uniforms.maximumDensity, 0.75)
        XCTAssertFalse(uniforms.isRadial)
        XCTAssertEqual(uniforms.metalCameraEye, SIMD3<Float>(4, 5, 6))
        XCTAssertEqual(uniforms.metalCameraForward, SIMD3<Float>(0, 0, -1))

        let sky = GModMetalWorldSky3D(
            sourceOrigin: .zero,
            scale: 16,
            fog: fog
        )
        XCTAssertEqual(sky.fog, fog)
        XCTAssertEqual(
            uniforms.start,
            fog.start,
            "baked sky geometry uses authored fog distances without a second scale"
        )

        let invalidRange = GModMetalWorldSky3DFog(
            blendsColors: false,
            sourcePrimaryDirection: .zero,
            primaryDisplayRGB: .zero,
            secondaryDisplayRGB: .zero,
            start: 300,
            end: 300,
            maximumDensity: 1,
            isRadial: true
        )
        XCTAssertNil(GModMetalSky3DFogContract.uniforms(
            fog: invalidRange,
            sourceCameraForward: SIMD3<Float>(1, 0, 0),
            metalCameraEye: .zero,
            metalCameraForward: SIMD3<Float>(0, 0, -1)
        ))
    }

    func testWorldBitmapRetentionChargesSharedRangeIdentityOnce() throws {
        let shared = try fixtureBitmap(named: "shared")
        let other = try fixtureBitmap(named: "other")
        var budget = GModMetalWorldBitmapRetentionBudget(maximumByteCount: 4)

        XCTAssertTrue(budget.retain(shared))
        XCTAssertEqual(budget.retainedByteCount, 4)
        XCTAssertTrue(budget.retain(shared))
        XCTAssertEqual(
            budget.retainedByteCount,
            4,
            "world and sky3D ranges sharing one bitmap must not double-charge bytes"
        )
        XCTAssertFalse(budget.retain(other))
        XCTAssertEqual(budget.retainedByteCount, 4)
    }

    func testWorldTextureCacheDropsOnlyBindingsAbsentFromReplacementScene() throws {
        let base = try fixtureBitmap(named: "base")
        let normal = try fixtureBitmap(named: "normal")
        let sunBitmap = try fixtureBitmap(named: "sun")
        let water = GModMetalWorldWaterMaterial(
            resourceIdentifier: "materials/water/cache.vmt",
            isAboveWater: true,
            fogColor: .zero,
            fogStart: nil,
            fogEnd: nil,
            reflectionAmount: 0.4,
            refractionAmount: 1,
            normalBitmap: normal,
            textureScrollRate: nil,
            textureScrollAngleDegrees: nil,
            unsupportedBumpTextureFormat: nil
        )
        let sunLayer = GModMetalWorldSunSpriteLayer(
            materialName: "sprites/cache",
            displayRGB: SIMD3<Float>(repeating: 1),
            size: 16,
            materialResolution: .resolved(sunBitmap)
        )
        let scene = fixtureScene(
            materialRanges: [
                GModMetalWorldMaterialRange(
                    materialName: "world/base",
                    firstIndex: 0,
                    indexCount: 3,
                    bitmap: base
                ),
                GModMetalWorldMaterialRange(
                    materialName: "water/cache",
                    firstIndex: 0,
                    indexCount: 3,
                    bitmap: nil,
                    waterSurface: GModMetalWorldWaterSurface(
                        surfaceZ: 0,
                        minimumZ: -64
                    ),
                    waterMaterial: water
                ),
            ],
            sunSprites: [GModMetalWorldSunSprite(
                sourceDirectionToSun: SIMD3<Float>(0, 0, 1),
                hdrColorScale: 1,
                core: sunLayer,
                overlay: sunLayer
            )]
        )
        let retainedKeys = GModMetalWorldTextureCacheContract.retainedKeys(
            for: scene
        )
        XCTAssertEqual(retainedKeys, Set([
            "srgb:\(base.cacheIdentifier)",
            "linear:\(normal.cacheIdentifier)",
            "srgb:\(sunBitmap.cacheIdentifier)",
        ]))
        XCTAssertEqual(
            GModMetalWorldTextureCacheContract.staleKeys(
                cachedKeys: retainedKeys.union(["srgb:removed"]),
                for: scene
            ),
            Set(["srgb:removed"])
        )
    }

    func testMovingCameraBeyondSkyCubeCannotIntroduceSkyTranslationOrParallax() {
        let original = fixtureScene(materialRanges: [])
        let moved = original.updatingCamera(
            eye: SIMD3<Float>(100_000, -200_000, 300_000),
            forward: SIMD3<Float>(0, 1, 0)
        )

        XCTAssertNotEqual(moved.metalCameraEye, original.metalCameraEye)
        XCTAssertEqual(moved.metalSkyboxCameraEye, .zero)
        XCTAssertEqual(original.metalSkyboxCameraEye, .zero)
        XCTAssertEqual(moved.sourcePositions, original.sourcePositions)
        XCTAssertEqual(moved.metalPositions, original.metalPositions)
        XCTAssertEqual(
            moved.sourceLightmapTextureCoordinates,
            original.sourceLightmapTextureCoordinates
        )
        XCTAssertEqual(moved.lightmapAtlas, original.lightmapAtlas)
        XCTAssertEqual(moved.lightmapDiagnostics, original.lightmapDiagnostics)
        XCTAssertEqual(moved.indices, original.indices)
        XCTAssertEqual(moved.materialRanges, original.materialRanges)
        XCTAssertTrue(GModMetalSkyboxRenderContract.depthCompareAlwaysPasses)
        XCTAssertFalse(GModMetalSkyboxRenderContract.depthWritesEnabled)
    }

    func testCameraUpdateCarriesContinuousSourceUpThroughVerticalPitch() {
        func dot(_ lhs: SIMD3<Float>, _ rhs: SIMD3<Float>) -> Float {
            lhs.x * rhs.x + lhs.y * rhs.y + lhs.z * rhs.z
        }
        func crossLengthSquared(
            _ lhs: SIMD3<Float>,
            _ rhs: SIMD3<Float>
        ) -> Float {
            let value = SIMD3<Float>(
                lhs.y * rhs.z - lhs.z * rhs.y,
                lhs.z * rhs.x - lhs.x * rhs.z,
                lhs.x * rhs.y - lhs.y * rhs.x
            )
            return dot(value, value)
        }
        let original = fixtureScene(materialRanges: [])
        let below = SourceQAngle(pitch: 87.43, yaw: 90).sourceBasis
        let above = SourceQAngle(pitch: 87.45, yaw: 90).sourceBasis
        let belowScene = original.updatingCamera(
            eye: .zero,
            forward: SIMD3<Float>(
                below.forward.x,
                below.forward.y,
                below.forward.z
            ),
            up: SIMD3<Float>(below.up.x, below.up.y, below.up.z)
        )
        let aboveScene = original.updatingCamera(
            eye: .zero,
            forward: SIMD3<Float>(
                above.forward.x,
                above.forward.y,
                above.forward.z
            ),
            up: SIMD3<Float>(above.up.x, above.up.y, above.up.z)
        )

        XCTAssertGreaterThan(
            dot(belowScene.metalCameraUp, aboveScene.metalCameraUp),
            0.999_999
        )
        XCTAssertGreaterThan(
            crossLengthSquared(
                aboveScene.metalCameraForward,
                aboveScene.metalCameraUp
            ),
            0.999_99
        )
        XCTAssertEqual(
            aboveScene.metalCameraUp,
            GModMetalWorldScene.convertSourceVector(aboveScene.cameraUp)
        )
    }

    func testCameraUpdateRetainsBoundedLinearLightmapAtlasAndSecondUVStream() {
        let atlasBytes = Data(repeating: 0, count: 2 * 2 * 8)
        let atlas = GModMetalWorldLightmapAtlas(
            identifier: "fixture:lightmap",
            width: 2,
            height: 2,
            linearRGBA16Float: atlasBytes
        )
        let coordinates = [
            SIMD2<Float>(0.25, 0.25),
            SIMD2<Float>(0.75, 0.25),
            SIMD2<Float>(0.25, 0.75),
        ]
        let diagnostics = GModMetalWorldLightmapDiagnostics(
            atlasStatus: .built(width: 2, height: 2, byteCount: atlasBytes.count),
            ignoredAdditionalLightStyleFaceCount: 7,
            ignoredBumpLightFaceCount: 11,
            clampedChannelCount: 0
        )
        let scene = fixtureScene(
            materialRanges: [],
            lightmapCoordinates: coordinates,
            lightmapAtlas: atlas,
            lightmapDiagnostics: diagnostics
        )
        let moved = scene.updatingCamera(
            eye: SIMD3<Float>(4_096, -8_192, 16_384),
            forward: SIMD3<Float>(0, 1, 0)
        )

        XCTAssertEqual(scene.sourceLightmapTextureCoordinates, coordinates)
        XCTAssertEqual(scene.lightmapAtlas, atlas)
        XCTAssertEqual(scene.lightmapDiagnostics, diagnostics)
        XCTAssertEqual(moved.sourceLightmapTextureCoordinates, coordinates)
        XCTAssertEqual(moved.lightmapAtlas, atlas)
        XCTAssertEqual(moved.lightmapDiagnostics, diagnostics)
        XCTAssertEqual(GModMetalWorldLightmapAtlas.maximumWidth, 2_048)
        XCTAssertEqual(GModMetalWorldLightmapAtlas.maximumHeight, 4_096)
        XCTAssertEqual(GModMetalWorldLightmapAtlas.maximumByteCount, 64 * 1_024 * 1_024)
    }

    func testLightmapCapacityFallbackKeepsExactMeasuredRequirement() {
        let status = GModMetalWorldLightmapAtlasStatus.capacityExceeded(
            requiredWidth: 2_048,
            requiredHeight: 4_097,
            requiredByteCount: 67_125_248,
            maximumWidth: 2_048,
            maximumHeight: 4_096,
            maximumByteCount: 67_108_864
        )
        let diagnostics = GModMetalWorldLightmapDiagnostics(atlasStatus: status)
        let scene = fixtureScene(
            materialRanges: [],
            lightmapDiagnostics: diagnostics
        )

        XCTAssertNil(scene.lightmapAtlas)
        XCTAssertEqual(scene.lightmapDiagnostics.atlasStatus, status)
        XCTAssertEqual(
            GModMetalWorldLightmapRenderContract.fallbackReason(for: status),
            "lightmap atlas requires 2048x4097 / 67125248 bytes; " +
                "cap is 2048x4096 / 67108864 bytes"
        )
        XCTAssertNil(
            GModMetalWorldLightmapRenderContract.fallbackReason(
                for: .unavailableNoLightmaps
            )
        )
        XCTAssertEqual(
            GModMetalWorldLightmapRenderContract.fallbackReason(
                for: .built(width: 2_048, height: 10, byteCount: 163_840)
            ),
            "scene reports a built 2048x10 / 163840-byte lightmap atlas " +
                "but supplied no atlas data"
        )
    }

    func testWaterSelectsOneSourceSideAndFreezesAnimationWithSourceTime() throws {
        let normal = try fixtureBitmap(named: "water-normal")
        let surface = GModMetalWorldWaterSurface(
            surfaceZ: -160,
            minimumZ: -960
        )
        let top = GModMetalWorldWaterMaterial(
            resourceIdentifier: "materials/gm_construct/water_13.vmt",
            isAboveWater: true,
            fogColor: SIMD3<Float>(7, 58, 66) / 255,
            fogStart: 0,
            fogEnd: 1_024,
            reflectionAmount: 0.4,
            refractionAmount: 1,
            normalBitmap: normal,
            textureScrollRate: 0.02,
            textureScrollAngleDegrees: 25,
            unsupportedBumpTextureFormat: "uv88"
        )
        let beneath = GModMetalWorldWaterMaterial(
            resourceIdentifier: "materials/gm_construct/water_13_beneath.vmt",
            isAboveWater: false,
            fogColor: SIMD3<Float>(24, 64, 72) / 255,
            fogStart: -1_024,
            fogEnd: 2_048,
            reflectionAmount: nil,
            refractionAmount: 1,
            normalBitmap: normal,
            textureScrollRate: 0.05,
            textureScrollAngleDegrees: 45,
            unsupportedBumpTextureFormat: "uv88"
        )
        let scene = fixtureScene(materialRanges: [
            GModMetalWorldMaterialRange(
                materialName: "gm_construct/water_13",
                firstIndex: 0,
                indexCount: 3,
                bitmap: nil,
                waterSurface: surface,
                waterMaterial: top
            ),
            GModMetalWorldMaterialRange(
                materialName: "gm_construct/water_13_beneath",
                firstIndex: 3,
                indexCount: 3,
                bitmap: nil,
                waterSurface: surface,
                waterMaterial: beneath
            ),
        ])

        XCTAssertTrue(
            GModMetalWaterRenderContract.shouldRender(
                top,
                surface: surface,
                cameraZ: 64
            )
        )
        XCTAssertFalse(
            GModMetalWaterRenderContract.shouldRender(
                beneath,
                surface: surface,
                cameraZ: 64
            )
        )
        XCTAssertFalse(
            GModMetalWaterRenderContract.shouldRender(
                top,
                surface: surface,
                cameraZ: -200
            )
        )
        XCTAssertTrue(
            GModMetalWaterRenderContract.shouldRender(
                beneath,
                surface: surface,
                cameraZ: -200
            )
        )
        XCTAssertEqual(scene.materialDiagnostics.waterMaterialRangeCount, 2)
        XCTAssertEqual(scene.materialDiagnostics.resolvedWaterMaterialRangeCount, 2)
        XCTAssertEqual(scene.materialDiagnostics.missingWorldMaterialRangeCount, 0)
        XCTAssertEqual(
            scene.materialDiagnostics.unsupportedWaterBumpTextureNames,
            [
                "gm_construct/water_13",
                "gm_construct/water_13_beneath",
            ]
        )

        let frozen = scene.updatingCamera(
            eye: SIMD3<Float>(0, 0, 64),
            forward: SIMD3<Float>(1, 0, 0)
        )
        let advanced = scene.updatingCamera(
            eye: SIMD3<Float>(0, 0, 64),
            forward: SIMD3<Float>(1, 0, 0),
            sourceFixedTime: 3.75
        )
        XCTAssertEqual(frozen.sourceFixedTime, 0)
        XCTAssertEqual(advanced.sourceFixedTime, 3.75)
        XCTAssertEqual(advanced.materialRanges, scene.materialRanges)
    }

    func testWaterAdapterUsesOnlyExplicitVMTValues() throws {
        let vmt = Data(
            """
            "Water"
            {
                "$abovewater" "1"
                "$fogenable" "1"
                "$fogcolor" "{ 7 58 66 }"
                "$fogstart" "0"
                "$fogend" "1024"
                "$reflectamount" ".4"
                "$refractamount" "1"
                "Proxies"
                {
                    "TextureScroll"
                    {
                        "texturescrollvar" "$bumptransform"
                        "texturescrollrate" ".02"
                        "texturescrollangle" "25"
                    }
                }
            }
            """.utf8
        )
        let resolver = GModMetalSurfaceSourceMaterialResolver { logicalPath in
            logicalPath == "materials/gm_construct/test_water.vmt" ? vmt : nil
        }
        let water = try XCTUnwrap(
            resolver.resolveWaterMaterial(named: "gm_construct/test_water")
        )

        XCTAssertTrue(water.isAboveWater)
        XCTAssertEqual(water.fogColor, SIMD3<Float>(7, 58, 66) / 255)
        XCTAssertEqual(water.fogEnabled, true)
        XCTAssertEqual(water.fogStart, 0)
        XCTAssertEqual(water.fogEnd, 1_024)
        XCTAssertEqual(water.reflectionAmount, 0.4)
        XCTAssertEqual(water.refractionAmount, 1)
        XCTAssertNil(water.normalBitmap)
        XCTAssertEqual(water.textureScrollRate, 0.02)
        XCTAssertEqual(water.textureScrollAngleDegrees, 25)
        XCTAssertNil(water.unsupportedBumpTextureFormat)
    }

    private func fixtureScene(
        materialRanges: [GModMetalWorldMaterialRange],
        lightmapCoordinates: [SIMD2<Float>] = [],
        lightmapAtlas: GModMetalWorldLightmapAtlas? = nil,
        lightmapDiagnostics: GModMetalWorldLightmapDiagnostics = .init(),
        environmentLighting: GModMetalWorldEnvironmentLighting? = nil,
        sunSprites: [GModMetalWorldSunSprite] = [],
        worldVisibility: GModMetalWorldVisibility? = nil
    ) -> GModMetalWorldScene {
        GModMetalWorldScene(
            meshIdentifier: "sky-contract",
            sourcePositions: [
                SIMD3<Float>(1, 0, 0),
                SIMD3<Float>(1, 1, 0),
                SIMD3<Float>(1, 0, 1),
            ],
            sourceNormals: Array(repeating: SIMD3<Float>(-1, 0, 0), count: 3),
            sourceTextureCoordinates: [
                SIMD2<Float>(0, 0),
                SIMD2<Float>(1, 0),
                SIMD2<Float>(0, 1),
            ],
            sourceLightmapTextureCoordinates: lightmapCoordinates,
            indices: [0, 1, 2],
            materialRanges: materialRanges,
            lightmapAtlas: lightmapAtlas,
            lightmapDiagnostics: lightmapDiagnostics,
            environmentLighting: environmentLighting,
            sunSprites: sunSprites,
            worldVisibility: worldVisibility,
            cameraEye: SIMD3<Float>(0, 0, 64),
            cameraForward: SIMD3<Float>(1, 0, 0)
        )
    }

    private func fixtureVisibilityScene(
        visibility: GModMetalWorldVisibility
    ) -> GModMetalWorldScene {
        GModMetalWorldScene(
            meshIdentifier: "world-visibility",
            sourcePositions: [
                SIMD3<Float>(1, 0, 0),
                SIMD3<Float>(1, 1, 0),
                SIMD3<Float>(1, 0, 1),
            ],
            sourceNormals: Array(
                repeating: SIMD3<Float>(-1, 0, 0),
                count: 3
            ),
            indices: [
                0, 1, 2, 0, 1, 2,
                0, 1, 2, 0, 1, 2,
            ],
            materialRanges: [
                GModMetalWorldMaterialRange(
                    materialName: "world/first",
                    firstIndex: 0,
                    indexCount: 6,
                    bitmap: nil
                ),
                GModMetalWorldMaterialRange(
                    materialName: "world/second",
                    firstIndex: 6,
                    indexCount: 6,
                    bitmap: nil
                ),
            ],
            worldVisibility: visibility,
            cameraEye: SIMD3<Float>(1, 0, 0),
            cameraForward: SIMD3<Float>(1, 0, 0)
        )
    }

    private func fixtureWorldVisibility(
        potentialVisibility: GModMetalWorldPotentialVisibility?
    ) -> GModMetalWorldVisibility {
        GModMetalWorldVisibility(
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
            potentialVisibility: potentialVisibility,
            spans: [
                GModMetalWorldVisibilitySpan(
                    materialRangeIndex: 0,
                    firstIndex: 0,
                    indexCount: 3,
                    metalMinimum: SIMD3<Float>(-1, -1, -10),
                    metalMaximum: SIMD3<Float>(1, 1, -9),
                    clusterStartIndex: 0,
                    clusterCount: 1
                ),
                GModMetalWorldVisibilitySpan(
                    materialRangeIndex: 0,
                    firstIndex: 3,
                    indexCount: 3,
                    metalMinimum: SIMD3<Float>(-1, -1, -11),
                    metalMaximum: SIMD3<Float>(1, 1, -10),
                    clusterStartIndex: 1,
                    clusterCount: 1
                ),
                GModMetalWorldVisibilitySpan(
                    materialRangeIndex: 1,
                    firstIndex: 6,
                    indexCount: 3,
                    metalMinimum: SIMD3<Float>(-1, -1, -12),
                    metalMaximum: SIMD3<Float>(1, 1, -11),
                    clusterStartIndex: 2,
                    clusterCount: 1
                ),
                GModMetalWorldVisibilitySpan(
                    materialRangeIndex: 1,
                    firstIndex: 9,
                    indexCount: 3,
                    metalMinimum: SIMD3<Float>(-1, -1, 9),
                    metalMaximum: SIMD3<Float>(1, 1, 10),
                    clusterStartIndex: 3,
                    clusterCount: 1
                ),
            ],
            spanClusters: [0, 0, 1, 0]
        )
    }

    func testWaterRenderTargetsUseOnlyOneVisibleSourcePlane() throws {
        let material = GModMetalWorldWaterMaterial(
            resourceIdentifier: "materials/water/test.vmt",
            isAboveWater: true,
            fogColor: SIMD3<Float>(0.1, 0.2, 0.3),
            fogStart: nil,
            fogEnd: nil,
            reflectionAmount: 0.4,
            refractionAmount: 1,
            normalBitmap: nil,
            textureScrollRate: nil,
            textureScrollAngleDegrees: nil,
            unsupportedBumpTextureFormat: nil
        )
        func range(at surfaceZ: Float) -> GModMetalWorldMaterialRange {
            GModMetalWorldMaterialRange(
                materialName: "water/test",
                firstIndex: 0,
                indexCount: 3,
                bitmap: nil,
                waterSurface: GModMetalWorldWaterSurface(
                    surfaceZ: surfaceZ,
                    minimumZ: surfaceZ - 64
                ),
                waterMaterial: material
            )
        }

        XCTAssertEqual(
            GModMetalWaterRenderTargetContract.plan(
                materialRanges: [range(at: 128)],
                cameraZ: 256
            ),
            GModMetalWaterRenderTargetPlan(
                sourceSurfaceZ: 128,
                requiresReflection: true,
                requiresRefraction: true
            )
        )
        XCTAssertNil(
            GModMetalWaterRenderTargetContract.plan(
                materialRanges: [range(at: 128), range(at: 256)],
                cameraZ: 512
            )
        )
    }

    func testWaterReflectionMirrorsSourceZMappedMetalCameraBasis() {
        let reflected = GModMetalWaterReflectionContract.reflectedCamera(
            eye: SIMD3<Float>(10, 300, 20),
            forward: SIMD3<Float>(0.2, -0.5, 0.8),
            up: SIMD3<Float>(0, 1, 0),
            sourceSurfaceZ: 128
        )

        XCTAssertEqual(reflected.eye, SIMD3<Float>(10, -44, 20))
        XCTAssertEqual(reflected.forward, SIMD3<Float>(0.2, 0.5, 0.8))
        XCTAssertEqual(reflected.up, SIMD3<Float>(0, 1, 0))
    }

    func testWaterRenderTargetClipPlanesRetainCorrectSourceHalfSpaces() {
        let aboveRefraction = GModMetalWaterClipPlaneContract.refraction(
            sourceSurfaceZ: 128,
            sourceCameraZ: 300
        )
        let aboveReflection = GModMetalWaterClipPlaneContract.reflection(
            sourceSurfaceZ: 128,
            sourceCameraZ: 300
        )
        XCTAssertTrue(GModMetalWaterClipPlaneContract.retains(
            metalPosition: SIMD3<Float>(0, 64, 0),
            plane: aboveRefraction
        ))
        XCTAssertFalse(GModMetalWaterClipPlaneContract.retains(
            metalPosition: SIMD3<Float>(0, 192, 0),
            plane: aboveRefraction
        ))
        XCTAssertTrue(GModMetalWaterClipPlaneContract.retains(
            metalPosition: SIMD3<Float>(0, 192, 0),
            plane: aboveReflection
        ))
        XCTAssertFalse(GModMetalWaterClipPlaneContract.retains(
            metalPosition: SIMD3<Float>(0, 64, 0),
            plane: aboveReflection
        ))

        let belowRefraction = GModMetalWaterClipPlaneContract.refraction(
            sourceSurfaceZ: 128,
            sourceCameraZ: 32
        )
        let belowReflection = GModMetalWaterClipPlaneContract.reflection(
            sourceSurfaceZ: 128,
            sourceCameraZ: 32
        )
        XCTAssertTrue(GModMetalWaterClipPlaneContract.retains(
            metalPosition: SIMD3<Float>(0, 192, 0),
            plane: belowRefraction
        ))
        XCTAssertTrue(GModMetalWaterClipPlaneContract.retains(
            metalPosition: SIMD3<Float>(0, 64, 0),
            plane: belowReflection
        ))
        XCTAssertTrue(GModMetalWaterClipPlaneContract.retains(
            metalPosition: SIMD3<Float>(0, -10_000, 0),
            plane: GModMetalWaterClipPlaneContract.disabled
        ))
    }

    private func fixtureBitmap(named name: String) throws -> GModMetalSurfaceBitmap {
        try GModMetalSurfaceBitmap(
            resourceIdentifier: name,
            width: 1,
            height: 1,
            premultipliedRGBA8: Data([255, 255, 255, 255])
        )
    }
}
