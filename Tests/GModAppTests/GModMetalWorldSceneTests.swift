import Foundation
import XCTest
@testable import GModMetal

final class GModMetalWorldSceneTests: XCTestCase {
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
                bitmap: offset < 2 ? bitmap : nil
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
        XCTAssertEqual(GModMetalWaterRenderContract.fallbackAlpha(top), 0.4)
        XCTAssertEqual(
            GModMetalWaterRenderContract.fallbackAlpha(beneath),
            1
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
        lightmapDiagnostics: GModMetalWorldLightmapDiagnostics = .init()
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
            cameraEye: SIMD3<Float>(0, 0, 64),
            cameraForward: SIMD3<Float>(1, 0, 0)
        )
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
