import Foundation
import XCTest
import GModEngine
import GModGameAssets
import GModMetal
@testable import GModApp
@testable import GModGameSession

final class GModWorldSceneAdapterTests: XCTestCase {
    func testMakeWorldSceneCarriesAuthoredTerrainBlendInputs() throws {
        let files: [String: Data] = [
            "materials/terrain/blended.vmt": Data(
                """
                "WorldVertexTransition"
                {
                    "$basetexture" "terrain/base"
                    "$basetexture2" "terrain/rock"
                    "$blendmodulatetexture" "terrain/blend"
                    "$blendmasktransform" "center .5 .5 scale 2 3 rotate 0 translate .1 .2"
                    "$detail" "terrain/detail"
                    "$detailscale" "4"
                    "$detailblendfactor" ".5"
                    "$detailblendmode" "7"
                }
                """.utf8
            ),
            "materials/terrain/base.vtf": makeRGBA8888VTF(
                pixels: [10, 20, 30, 255]
            ),
            "materials/terrain/rock.vtf": makeRGBA8888VTF(
                pixels: [40, 50, 60, 255]
            ),
            "materials/terrain/blend.vtf": makeRGBA8888VTF(
                pixels: [70, 80, 90, 255]
            ),
            "materials/terrain/detail.vtf": makeRGBA8888VTF(
                pixels: [100, 110, 120, 255]
            ),
        ]
        let resolver = GModMetalSurfaceSourceMaterialResolver { path in
            files[path.lowercased()]
        }
        let vertices = [Float(0), 127.5, 255].enumerated().map { pair in
            let (index, alpha) = pair
            return GModWorldRenderVertex(
                position: SourceVector3(Float(index), 0, 0),
                normal: SourceVector3(0, 0, 1),
                sourceDisplacementAlpha: alpha
            )
        }
        let mesh = GModWorldRenderMesh(
            vertices: vertices,
            indices: [0, 1, 2],
            minimum: .zero,
            maximum: SourceVector3(2, 0, 0),
            materialRanges: [GModWorldMaterialRange(
                materialName: "terrain/blended",
                firstIndex: 0,
                indexCount: 3
            )],
            diagnostics: GModWorldRenderMeshDiagnostics(
                sourceFaceCount: 1,
                emittedFaceCount: 1,
                degenerateFaceCount: 0,
                displacementBaseFaceCount: 1
            )
        )

        let scene = try GModGameSessionModel.makeWorldScene(
            map: .construct,
            sessionGeneration: 21,
            mesh: mesh,
            playerOrigin: .zero,
            viewAngles: .zero,
            textureResolver: resolver
        )

        XCTAssertEqual(scene.sourceDisplacementAlphas, [0, 127.5, 255])
        let terrain = try XCTUnwrap(scene.materialRanges.first?.terrainMaterial)
        let detail = try XCTUnwrap(terrain.detail)
        XCTAssertEqual(detail.textureName, "materials/terrain/detail.vtf")
        XCTAssertNotNil(detail.bitmap)
        XCTAssertEqual(detail.blendFactor, 0.5)
        XCTAssertEqual(detail.blendMode, 7)
        XCTAssertEqual(detail.textureTransform.row0, SIMD3<Float>(4, 0, 0))
        XCTAssertEqual(detail.textureTransform.row1, SIMD3<Float>(0, 4, 0))
        let transition = try XCTUnwrap(terrain.vertexTransition)
        XCTAssertNotNil(transition.baseTexture2Bitmap)
        XCTAssertNotNil(transition.blendModulateBitmap)
        XCTAssertEqual(
            transition.blendMaskTransform.row0,
            SIMD3<Float>(2, 0, -0.4)
        )
        XCTAssertEqual(
            transition.blendMaskTransform.row1,
            SIMD3<Float>(0, 3, -0.8)
        )
    }

    func testMakeWorldSceneBridgesImmutableBSPVisibilityAndMetalBounds() throws {
        var visibilityData = Data()
        func appendInt32(_ value: Int32) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) {
                visibilityData.append(contentsOf: $0)
            }
        }
        appendInt32(1)
        appendInt32(12)
        appendInt32(12)
        visibilityData.append(0b0000_0001)
        let potentialVisibility = try XCTUnwrap(
            GModWorldPotentialVisibility(data: visibilityData)
        )
        let sourceVisibility = GModWorldVisibility(
            headNode: 0,
            planes: [GModWorldSkyVisibilityPlane(
                normal: SourceVector3(1, 0, 0),
                distance: 8
            )],
            nodes: [GModWorldSkyVisibilityNode(
                planeIndex: 0,
                frontChild: -1,
                backChild: -1
            )],
            leafClusters: [0],
            potentialVisibility: potentialVisibility,
            spans: [GModWorldVisibilitySpan(
                materialRangeIndex: 0,
                firstIndex: 0,
                indexCount: 3,
                minimum: SourceVector3(-4, -2, -3),
                maximum: SourceVector3(5, 7, 11),
                clusterStartIndex: 0,
                clusterCount: 1
            )],
            spanClusters: [0]
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
            minimum: .zero,
            maximum: SourceVector3(1, 1, 0),
            materialRanges: [GModWorldMaterialRange(
                materialName: "world/test",
                firstIndex: 0,
                indexCount: 3
            )],
            worldVisibility: sourceVisibility,
            diagnostics: GModWorldRenderMeshDiagnostics(
                sourceFaceCount: 1,
                emittedFaceCount: 1,
                degenerateFaceCount: 0,
                displacementBaseFaceCount: 0
            )
        )

        let scene = try GModGameSessionModel.makeWorldScene(
            map: .construct,
            sessionGeneration: 20,
            mesh: mesh,
            playerOrigin: .zero,
            viewAngles: .zero,
            textureResolver: GModMetalSurfaceSourceMaterialResolver { _ in nil }
        )
        let metalVisibility = try XCTUnwrap(scene.worldVisibility)
        XCTAssertEqual(metalVisibility.headNode, 0)
        XCTAssertEqual(
            metalVisibility.planes.first?.sourceNormal,
            SIMD3<Float>(1, 0, 0)
        )
        XCTAssertEqual(
            metalVisibility.potentialVisibility?.encodedBytes,
            potentialVisibility.encodedBytes
        )
        let span = try XCTUnwrap(metalVisibility.spans.first)
        XCTAssertEqual(span.materialRangeIndex, 0)
        XCTAssertEqual(span.firstIndex, 0)
        XCTAssertEqual(span.indexCount, 3)
        XCTAssertEqual(span.metalMinimum, SIMD3<Float>(-7, -3, -5))
        XCTAssertEqual(span.metalMaximum, SIMD3<Float>(2, 11, 4))
        XCTAssertEqual(metalVisibility.spanClusters, [0])
    }

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
        let sourceSkyVisibility = GModWorldSky3DVisibility(
            sourceVisibilityOrigin: SourceVector3(64, 128, 256),
            scale: 16,
            bspVisibility: GModWorldVisibility(
                headNode: 0,
                planes: [],
                nodes: [],
                leafClusters: [],
                potentialVisibility: nil,
                spans: [],
                spanClusters: []
            )
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
            sky3DVisibility: sourceSkyVisibility,
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
        let visibility = try XCTUnwrap(scene.sky3DVisibility)
        XCTAssertEqual(
            visibility.sourceVisibilityOrigin,
            SIMD3<Float>(64, 128, 256)
        )
        XCTAssertEqual(visibility.bspVisibility.headNode, 0)
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
