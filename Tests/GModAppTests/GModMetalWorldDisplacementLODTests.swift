import Foundation
import XCTest
import GModEngine
import GModGameAssets
@testable import GModApp
@testable import GModGameSession
@testable import GModMetal

final class GModMetalWorldDisplacementLODTests: XCTestCase {
    func testValveAuthoredDisplacementAlphaOvershootSaturatesAtRenderBoundary() {
        XCTAssertEqual(
            GModMetalDisplacementAlphaContract.normalized(255.003),
            1
        )
        XCTAssertEqual(
            GModMetalDisplacementAlphaContract.normalized(-0.001),
            0
        )
        XCTAssertEqual(
            GModMetalDisplacementAlphaContract.normalized(127.5),
            0.5
        )
        XCTAssertNil(
            GModMetalDisplacementAlphaContract.normalized(.infinity)
        )
        XCTAssertNil(GModMetalDisplacementAlphaContract.normalized(.nan))
    }

    func testDisplacementTerrainUsesAuthoredMipsAndHighQualityFiltering() throws {
        let ordinaryBitmap = try makeMippedBitmap(flags: [])
        let ordinary = GModMetalWorldSamplerConfiguration(
            bitmap: ordinaryBitmap,
            renderLayer: .world
        )
        XCTAssertEqual(ordinary.mipFilter, .nearest)
        XCTAssertEqual(ordinary.maximumAnisotropy, 1)

        let terrain = GModMetalWorldSamplerConfiguration(
            bitmap: ordinaryBitmap,
            renderLayer: .world,
            usage: .displacementTerrain
        )
        XCTAssertEqual(terrain.minFilter, .linear)
        XCTAssertEqual(terrain.magFilter, .linear)
        XCTAssertEqual(terrain.mipFilter, .linear)
        XCTAssertEqual(terrain.maximumAnisotropy, 16)

        let noLOD = GModMetalWorldSamplerConfiguration(
            bitmap: try makeMippedBitmap(flags: [.noLOD]),
            renderLayer: .world,
            usage: .displacementTerrain
        )
        XCTAssertEqual(
            noLOD.mipFilter,
            .linear,
            "NOLOD prevents Source picmip reduction; it does not discard runtime mips"
        )

        let pointNoMip = GModMetalWorldSamplerConfiguration(
            bitmap: try makeMippedBitmap(flags: [.pointSample, .noMip]),
            renderLayer: .world,
            usage: .displacementTerrain
        )
        XCTAssertEqual(pointNoMip.minFilter, .nearest)
        XCTAssertEqual(pointNoMip.magFilter, .nearest)
        XCTAssertEqual(pointNoMip.mipFilter, .notMipmapped)
        XCTAssertEqual(pointNoMip.maximumAnisotropy, 1)
    }

    func testOnlyOrdinaryWorldDisplacementSelectsTerrainLOD() throws {
        let bitmap = try makeMippedBitmap(flags: [])
        func range(
            layer: GModMetalWorldRenderLayer,
            isDisplacement: Bool,
            water: GModMetalWorldWaterSurface? = nil
        ) -> GModMetalWorldMaterialRange {
            GModMetalWorldMaterialRange(
                materialName: "gm_construct/flatgrass",
                firstIndex: 0,
                indexCount: 3,
                bitmap: bitmap,
                waterSurface: water,
                renderLayer: layer,
                isDisplacement: isDisplacement
            )
        }

        let terrain = range(layer: .world, isDisplacement: true)
        XCTAssertEqual(terrain.textureUsage, .displacementTerrain)
        XCTAssertEqual(terrain.samplerConfiguration?.mipFilter, .linear)

        XCTAssertEqual(
            range(layer: .world, isDisplacement: false).textureUsage,
            .standard
        )
        XCTAssertEqual(
            range(layer: .sky3D, isDisplacement: true).textureUsage,
            .standard
        )
        XCTAssertEqual(
            range(layer: .sky2D, isDisplacement: true).textureUsage,
            .standard
        )
        XCTAssertEqual(
            range(
                layer: .world,
                isDisplacement: true,
                water: .init(surfaceZ: 0, minimumZ: -64)
            ).textureUsage,
            .standard
        )
    }

    func testGameSessionAdapterCarriesBSPDisplacementProvenance() throws {
        let mesh = GModWorldRenderMesh(
            vertices: [
                .init(position: .zero, normal: SourceVector3(0, 0, 1)),
                .init(
                    position: SourceVector3(1, 0, 0),
                    normal: SourceVector3(0, 0, 1)
                ),
                .init(
                    position: SourceVector3(0, 1, 0),
                    normal: SourceVector3(0, 0, 1)
                ),
            ],
            indices: [0, 1, 2],
            minimum: .zero,
            maximum: SourceVector3(1, 1, 0),
            materialRanges: [.init(
                materialName: "gm_construct/flatgrass",
                firstIndex: 0,
                indexCount: 3,
                isDisplacement: true
            )],
            diagnostics: .init(
                sourceFaceCount: 1,
                emittedFaceCount: 1,
                degenerateFaceCount: 0,
                displacementBaseFaceCount: 1
            )
        )
        let scene = try GModGameSessionModel.makeWorldScene(
            map: .construct,
            sessionGeneration: 1,
            mesh: mesh,
            playerOrigin: .zero,
            viewAngles: .zero,
            textureResolver: GModMetalSurfaceSourceMaterialResolver { _ in nil }
        )

        let range = try XCTUnwrap(scene.materialRanges.first)
        XCTAssertTrue(range.isDisplacement)
        XCTAssertEqual(range.renderLayer, .world)
        XCTAssertEqual(range.textureUsage, .displacementTerrain)
    }

    func testDetailBlendModeSelectsSourceLinearOrSRGBRead() throws {
        let bitmap = try makeMippedBitmap(flags: [])
        func detail(mode: Int) -> GModMetalWorldDetailMaterial {
            .init(
                textureName: "materials/gm_construct/grass_clouds.vtf",
                textureResolution: .resolved(bitmap),
                textureTransform: .identity,
                blendFactor: 0.5,
                blendMode: mode
            )
        }
        XCTAssertFalse(detail(mode: 0).samplesAsSRGB)
        XCTAssertTrue(detail(mode: 1).samplesAsSRGB)

        func retainedKeys(mode: Int) -> Set<String> {
            let range = GModMetalWorldMaterialRange(
                materialName: "gm_construct/grass_13",
                firstIndex: 0,
                indexCount: 3,
                bitmap: nil,
                terrainMaterial: .init(detail: detail(mode: mode)),
                isDisplacement: true
            )
            let scene = GModMetalWorldScene(
                meshIdentifier: "detail-color-space-\(mode)",
                sourcePositions: [],
                sourceNormals: [],
                indices: [],
                materialRanges: [range],
                cameraEye: .zero,
                cameraForward: SIMD3<Float>(1, 0, 0)
            )
            return GModMetalWorldTextureCacheContract.retainedKeys(for: scene)
        }

        XCTAssertEqual(
            retainedKeys(mode: 0),
            ["linear:\(bitmap.cacheIdentifier)"]
        )
        XCTAssertEqual(
            retainedKeys(mode: 1),
            ["srgb:\(bitmap.cacheIdentifier)"]
        )
    }

    private func makeMippedBitmap(
        flags: SourceVTFTextureFlags
    ) throws -> GModMetalSurfaceBitmap {
        let levels = (0..<4).map { level -> GModMetalSurfaceMipLevel in
            let dimension = 8 >> level
            return .init(
                width: dimension,
                height: dimension,
                premultipliedRGBA8: Data(
                    repeating: UInt8(255 - level * 40),
                    count: dimension * dimension * 4
                )
            )
        }
        return try GModMetalSurfaceBitmap(
            resourceIdentifier: "terrain-\(flags.rawValue)",
            width: 8,
            height: 8,
            premultipliedRGBA8: levels[0].premultipliedRGBA8,
            mipLevels: levels,
            sourceTextureFlags: flags
        )
    }
}
