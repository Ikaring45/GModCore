import Foundation
import XCTest
import GModEngine
import GModGameAssets
import GModMetal
@testable import GModApp
@testable import GModGameSession

final class GModWorldSceneAdapterTests: XCTestCase {
    func testMakeWorldSceneCarriesValidatedSkyCameraFogIntoMetal() throws {
        let sourceFog = GModWorldSky3DFog(
            blendsColors: true,
            sourcePrimaryDirection: SourceVector3(1, 0, 0),
            primaryDisplayRGB: SourceVector3(0.2, 0.4, 0.6),
            secondaryDisplayRGB: SourceVector3(0.1, 0.3, 0.5),
            start: -4_000,
            end: 320_000,
            maximumDensity: 0.75,
            isRadial: false
        )
        let mesh = GModWorldRenderMesh(
            vertices: [],
            indices: [],
            minimum: .zero,
            maximum: .zero,
            sky3D: GModWorldSky3D(
                origin: SourceVector3(64, 128, 256),
                scale: 16,
                area: 2,
                cluster: 3,
                sourceFaceCount: 4,
                fogStatus: .available(sourceFog)
            ),
            diagnostics: GModWorldRenderMeshDiagnostics(
                sourceFaceCount: 0,
                emittedFaceCount: 0,
                degenerateFaceCount: 0,
                displacementBaseFaceCount: 0
            )
        )

        let scene = try GModGameSessionModel.makeWorldScene(
            map: .construct,
            sessionGeneration: 19,
            mesh: mesh,
            playerOrigin: .zero,
            viewAngles: .zero,
            textureResolver: GModMetalSurfaceSourceMaterialResolver { _ in nil }
        )

        let sky = try XCTUnwrap(scene.sky3D)
        XCTAssertEqual(sky.sourceOrigin, SIMD3<Float>(64, 128, 256))
        XCTAssertEqual(sky.scale, 16)
        let fog = try XCTUnwrap(sky.fog)
        XCTAssertEqual(fog.blendsColors, sourceFog.blendsColors)
        XCTAssertEqual(
            fog.sourcePrimaryDirection,
            SIMD3<Float>(1, 0, 0)
        )
        XCTAssertEqual(fog.primaryDisplayRGB, SIMD3<Float>(0.2, 0.4, 0.6))
        XCTAssertEqual(fog.secondaryDisplayRGB, SIMD3<Float>(0.1, 0.3, 0.5))
        XCTAssertEqual(fog.start, sourceFog.start)
        XCTAssertEqual(fog.end, sourceFog.end)
        XCTAssertEqual(fog.maximumDensity, sourceFog.maximumDensity)
        XCTAssertEqual(fog.isRadial, sourceFog.isRadial)
    }

    func testMakeWorldSceneChargesWaterNormalAgainstSharedRetentionBudget() throws {
        let files: [String: Data] = [
            "materials/water/bounded.vmt": Data(
                """
                "Water"
                {
                    "$abovewater" "1"
                    "$fogcolor" "{ 7 58 66 }"
                    "$reflectamount" ".4"
                    "$normalmap" "water/normal"
                }
                """.utf8
            ),
            "materials/water/normal.vtf": makeRGBA8888VTF(
                pixels: [127, 127, 255, 255]
            ),
        ]
        let resolver = GModMetalSurfaceSourceMaterialResolver { logicalPath in
            files[logicalPath.lowercased()]
        }
        XCTAssertNotNil(
            try XCTUnwrap(
                resolver.resolveWaterMaterial(named: "water/bounded")
            ).normalBitmap
        )
        let mesh = GModWorldRenderMesh(
            vertices: [
                GModWorldRenderVertex(
                    position: SourceVector3(0, 0, 0),
                    normal: SourceVector3(0, 0, 1)
                ),
                GModWorldRenderVertex(
                    position: SourceVector3(1, 0, 0),
                    normal: SourceVector3(0, 0, 1)
                ),
                GModWorldRenderVertex(
                    position: SourceVector3(0, 1, 0),
                    normal: SourceVector3(0, 0, 1)
                ),
            ],
            indices: [0, 1, 2],
            minimum: SourceVector3(0, 0, 0),
            maximum: SourceVector3(1, 1, 0),
            materialRanges: [GModWorldMaterialRange(
                materialName: "water/bounded",
                firstIndex: 0,
                indexCount: 3,
                waterSurface: GModWorldWaterSurface(
                    surfaceZ: 0,
                    minimumZ: -64,
                    sourceTextureInfoIndex: 0
                )
            )],
            diagnostics: GModWorldRenderMeshDiagnostics(
                sourceFaceCount: 1,
                emittedFaceCount: 1,
                degenerateFaceCount: 0,
                displacementBaseFaceCount: 0
            )
        )

        let scene = try GModGameSessionModel.makeWorldScene(
            map: .construct,
            sessionGeneration: 18,
            mesh: mesh,
            playerOrigin: SourceVector3(0, 0, 64),
            viewAngles: SourceQAngle(pitch: 0, yaw: 0, roll: 0),
            textureResolver: resolver,
            maximumRetainedBitmapByteCount: 0
        )

        let range = try XCTUnwrap(scene.materialRanges.first)
        let water = try XCTUnwrap(range.waterMaterial)
        XCTAssertEqual(water.resourceIdentifier, "materials/water/bounded.vmt")
        XCTAssertEqual(water.reflectionAmount, 0.4)
        XCTAssertNil(water.normalBitmap)
        guard case let .retentionCapacityExceeded(
            requiredByteCount,
            retainedByteCount,
            maximumByteCount
        ) = range.materialResolution else {
            return XCTFail("expected water normal retention failure")
        }
        XCTAssertEqual(requiredByteCount, 4)
        XCTAssertEqual(retainedByteCount, 0)
        XCTAssertEqual(maximumByteCount, 0)
        XCTAssertEqual(
            scene.materialDiagnostics.retentionCapacityExceededMaterialNames,
            ["water/bounded"]
        )
        XCTAssertEqual(scene.materialDiagnostics.resolvedWaterMaterialRangeCount, 1)
    }

    func testMakeWorldSceneMapsEnvironmentAndSunMaterialOutcomes() throws {
        enum FixtureError: Error {
            case forcedDecodeFailure
        }

        let files: [String: Data] = [
            "materials/sprites/resolved.vmt": Data(
                (
                    "\"UnlitGeneric\" { \"$basetexture\" " +
                    "\"sprites/resolved_texture\" }"
                ).utf8
            ),
            "materials/sprites/resolved_texture.vtf": makeRGBA8888VTF(
                pixels: [20, 40, 80, 255]
            ),
        ]
        let resolver = GModMetalSurfaceSourceMaterialResolver { logicalPath in
            let normalized = logicalPath.lowercased()
            if normalized == "materials/sprites/failing.vmt" {
                throw FixtureError.forcedDecodeFailure
            }
            return files[normalized]
        }
        let environment = GModWorldEnvironmentLighting(
            sourceDirectionFromLight: SourceVector3(0.25, -0.5, -0.75),
            directLinearRGB: SourceVector3(1.5, 1.25, 1),
            ambientLinearRGB: SourceVector3(0.1, 0.2, 0.3),
            source: .highDynamicRange
        )
        let firstSun = GModWorldSunSprite(
            sourceDirectionToSun: SourceVector3(0.25, -0.5, 0.75),
            hdrColorScale: 1.5,
            core: GModWorldSunSpriteLayer(
                materialName: "sprites/resolved",
                displayRGB: SourceVector3(1, 0.75, 0.5),
                size: 16
            ),
            overlay: GModWorldSunSpriteLayer(
                materialName: "sprites/missing",
                displayRGB: SourceVector3(0.5, 0.75, 1),
                size: 32
            )
        )
        let secondSun = GModWorldSunSprite(
            sourceDirectionToSun: SourceVector3(-0.25, 0.5, 0.75),
            hdrColorScale: 2,
            core: GModWorldSunSpriteLayer(
                materialName: "sprites/failing",
                displayRGB: SourceVector3(1, 1, 1),
                size: 8
            ),
            overlay: GModWorldSunSpriteLayer(
                materialName: "sprites/resolved",
                displayRGB: SourceVector3(0.25, 0.5, 0.75),
                size: 24
            )
        )
        let materialRanges = [
            GModWorldMaterialRange(
                materialName: "sprites/resolved",
                firstIndex: 0,
                indexCount: 3
            ),
            GModWorldMaterialRange(
                materialName: "sprites/missing",
                firstIndex: 0,
                indexCount: 3
            ),
            GModWorldMaterialRange(
                materialName: "sprites/failing",
                firstIndex: 0,
                indexCount: 3
            ),
            GModWorldMaterialRange(
                materialName: nil,
                firstIndex: 0,
                indexCount: 3
            ),
        ]
        let mesh = GModWorldRenderMesh(
            vertices: [
                GModWorldRenderVertex(
                    position: SourceVector3(0, 0, 0),
                    normal: SourceVector3(0, 0, 1)
                ),
                GModWorldRenderVertex(
                    position: SourceVector3(1, 0, 0),
                    normal: SourceVector3(0, 0, 1)
                ),
                GModWorldRenderVertex(
                    position: SourceVector3(0, 1, 0),
                    normal: SourceVector3(0, 0, 1)
                ),
            ],
            indices: [0, 1, 2],
            minimum: SourceVector3(0, 0, 0),
            maximum: SourceVector3(1, 1, 0),
            materialRanges: materialRanges,
            environmentLighting: environment,
            sunSprites: [firstSun, secondSun],
            diagnostics: GModWorldRenderMeshDiagnostics(
                sourceFaceCount: 1,
                emittedFaceCount: 1,
                degenerateFaceCount: 0,
                displacementBaseFaceCount: 0
            )
        )

        let scene = try GModGameSessionModel.makeWorldScene(
            map: .construct,
            sessionGeneration: 17,
            mesh: mesh,
            playerOrigin: SourceVector3(4, 8, 12),
            viewAngles: SourceQAngle(pitch: 5, yaw: 90, roll: 0),
            textureResolver: resolver
        )

        let metalEnvironment = try XCTUnwrap(scene.environmentLighting)
        XCTAssertEqual(
            metalEnvironment.sourceDirectionFromLight,
            SIMD3<Float>(0.25, -0.5, -0.75)
        )
        XCTAssertEqual(
            metalEnvironment.metalDirectionToLight,
            SIMD3<Float>(-0.5, 0.75, 0.25)
        )
        XCTAssertEqual(
            metalEnvironment.directLinearRGB,
            SIMD3<Float>(1.5, 1.25, 1)
        )
        XCTAssertEqual(
            metalEnvironment.ambientLinearRGB,
            SIMD3<Float>(0.1, 0.2, 0.3)
        )

        XCTAssertEqual(scene.sunSprites.count, 2)
        XCTAssertEqual(
            scene.sunSprites[0].sourceDirectionToSun,
            SIMD3<Float>(0.25, -0.5, 0.75)
        )
        XCTAssertEqual(
            scene.sunSprites[0].metalDirectionToSun,
            SIMD3<Float>(0.5, 0.75, -0.25)
        )
        XCTAssertEqual(scene.sunSprites[0].hdrColorScale, 1.5)
        XCTAssertEqual(scene.sunSprites[0].core.materialName, "sprites/resolved")
        XCTAssertEqual(
            scene.sunSprites[0].core.displayRGB,
            SIMD3<Float>(1, 0.75, 0.5)
        )
        XCTAssertEqual(scene.sunSprites[0].core.size, 16)

        guard case let .resolved(worldBitmap) =
            scene.materialRanges[0].materialResolution else {
            return XCTFail("expected resolved world material")
        }
        guard case let .resolved(coreBitmap) =
            scene.sunSprites[0].core.materialResolution else {
            return XCTFail("expected resolved sun core")
        }
        guard case let .resolved(overlayBitmap) =
            scene.sunSprites[1].overlay.materialResolution else {
            return XCTFail("expected resolved second sun overlay")
        }
        XCTAssertEqual(coreBitmap, worldBitmap)
        XCTAssertEqual(overlayBitmap, worldBitmap)
        XCTAssertEqual(coreBitmap.alphaRepresentation, .straight)

        XCTAssertEqual(
            scene.materialRanges[1].materialResolution,
            .sourceMissing
        )
        XCTAssertEqual(
            scene.sunSprites[0].overlay.materialResolution,
            .sourceMissing
        )
        XCTAssertEqual(
            scene.materialRanges[3].materialResolution,
            .notApplicable
        )
        assertDecodeFailure(scene.materialRanges[2].materialResolution)
        assertDecodeFailure(scene.sunSprites[1].core.materialResolution)
    }

    private func assertDecodeFailure(
        _ resolution: GModMetalWorldMaterialResolution,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .decodeFailed(message) = resolution else {
            return XCTFail("expected decode failure", file: file, line: line)
        }
        XCTAssertFalse(message.isEmpty, file: file, line: line)
    }
}

private func makeRGBA8888VTF(pixels: [UInt8]) -> Data {
    precondition(pixels.count == 4)
    var bytes = [UInt8](repeating: 0, count: 80)
    func write(_ value: UInt16, at offset: Int) {
        bytes[offset] = UInt8(truncatingIfNeeded: value)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }
    func write(_ value: UInt32, at offset: Int) {
        bytes[offset] = UInt8(truncatingIfNeeded: value)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        bytes[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
        bytes[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
    }
    bytes.replaceSubrange(0..<4, with: [0x56, 0x54, 0x46, 0x00])
    write(UInt32(7), at: 4)
    write(UInt32(2), at: 8)
    write(UInt32(80), at: 12)
    write(UInt16(1), at: 16)
    write(UInt16(1), at: 18)
    write(UInt16(1), at: 24)
    write(Float(1).bitPattern, at: 48)
    write(UInt32(bitPattern: SourceVTFImageFormat.rgba8888.rawValue), at: 52)
    bytes[56] = 1
    write(UInt32(bitPattern: SourceVTFImageFormat.unknown.rawValue), at: 57)
    write(UInt16(1), at: 63)
    bytes.append(contentsOf: pixels)
    return Data(bytes)
}
