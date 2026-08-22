import XCTest
@testable import GModMetal
import GModEngine

final class GModMetalWaterSourceContractTests: XCTestCase {
    func testReflectedCameraKeepsReflectedRightDirection() {
        let forward = SIMD3<Float>(0.2, -0.5, 0.8)
        let up = SIMD3<Float>(0.1, 0.9, -0.3)
        let reflected = GModMetalWaterReflectionContract.reflectedCamera(
            eye: SIMD3<Float>(10, 300, 20),
            forward: forward,
            up: up,
            sourceSurfaceZ: 128
        )

        XCTAssertEqual(reflected.eye, SIMD3<Float>(10, -44, 20))
        XCTAssertEqual(reflected.forward, SIMD3<Float>(0.2, 0.5, 0.8))
        XCTAssertEqual(reflected.up, SIMD3<Float>(-0.1, 0.9, 0.3))

        let originalRight = cross(forward, up)
        let reflectedRight = cross(reflected.forward, reflected.up)
        XCTAssertEqual(
            reflectedRight,
            SIMD3<Float>(originalRight.x, -originalRight.y, originalRight.z)
        )
    }

    func testClipPlanesIncludeSourceTwoUnitFudge() {
        let aboveRefraction = GModMetalWaterClipPlaneContract.refraction(
            sourceSurfaceZ: 128,
            sourceCameraZ: 300
        )
        let aboveReflection = GModMetalWaterClipPlaneContract.reflection(
            sourceSurfaceZ: 128,
            sourceCameraZ: 300
        )
        let belowRefraction = GModMetalWaterClipPlaneContract.refraction(
            sourceSurfaceZ: 128,
            sourceCameraZ: 32
        )
        let belowReflection = GModMetalWaterClipPlaneContract.reflection(
            sourceSurfaceZ: 128,
            sourceCameraZ: 32
        )

        XCTAssertEqual(GModMetalWaterClipPlaneContract.sourceFudge, 2)
        XCTAssertEqual(
            GModMetalWaterClipPlaneContract.underwaterMain(
                sourceSurfaceZ: 128
            ),
            SIMD4<Float>(0, -1, 0, 130)
        )
        XCTAssertEqual(aboveRefraction, SIMD4<Float>(0, -1, 0, 130))
        XCTAssertEqual(aboveReflection, SIMD4<Float>(0, 1, 0, -126))
        XCTAssertEqual(belowRefraction, SIMD4<Float>(0, 1, 0, -126))
        XCTAssertEqual(belowReflection, SIMD4<Float>(0, -1, 0, 130))

        XCTAssertTrue(retains(sourceZ: 130, plane: aboveRefraction))
        XCTAssertFalse(retains(sourceZ: 130.01, plane: aboveRefraction))
        XCTAssertTrue(retains(sourceZ: 126, plane: aboveReflection))
        XCTAssertFalse(retains(sourceZ: 125.99, plane: aboveReflection))
        XCTAssertTrue(retains(sourceZ: 126, plane: belowRefraction))
        XCTAssertFalse(retains(sourceZ: 125.99, plane: belowRefraction))
        XCTAssertTrue(retains(sourceZ: 130, plane: belowReflection))
        XCTAssertFalse(retains(sourceZ: 130.01, plane: belowReflection))
    }

    func testRenderTargetPresenceUsesOptionalAmountKeysNotTheirSign() throws {
        let signedAmounts = material(
            reflectionAmount: -0.4,
            refractionAmount: 0
        )
        let plan = try XCTUnwrap(GModMetalWaterRenderTargetContract.plan(
            materialRanges: [range(material: signedAmounts)],
            cameraZ: 300
        ))

        XCTAssertTrue(plan.requiresReflection)
        XCTAssertTrue(plan.requiresRefraction)
        XCTAssertEqual(signedAmounts.reflectionAmount, -0.4)
        XCTAssertEqual(signedAmounts.refractionAmount, 0)

        XCTAssertNil(GModMetalWaterRenderTargetContract.plan(
            materialRanges: [range(material: material(
                reflectionAmount: nil,
                refractionAmount: nil
            ))],
            cameraZ: 300
        ))
    }

    func testUnderwaterViewDoesNotCreateSourceReflectionPass() throws {
        let beneath = material(
            isAboveWater: false,
            reflectionAmount: 0.4,
            refractionAmount: 1
        )
        let plan = try XCTUnwrap(GModMetalWaterRenderTargetContract.plan(
            materialRanges: [range(material: beneath)],
            cameraZ: 0
        ))

        XCTAssertFalse(plan.requiresReflection)
        XCTAssertTrue(plan.requiresRefraction)
        XCTAssertNil(plan.refractionFog)
        XCTAssertEqual(plan.targetFlags(for: beneath), 2)

        XCTAssertNil(GModMetalWaterRenderTargetContract.plan(
            materialRanges: [range(material: material(
                isAboveWater: false,
                reflectionAmount: 0.4,
                refractionAmount: nil
            ))],
            cameraZ: 0
        ))
    }

    func testAboveWaterRefractionCarriesOnlyOneAuthoredFogRange() throws {
        let top = material(
            fogEnabled: true,
            fogStart: 0,
            fogEnd: 1_024,
            reflectionAmount: 0.4,
            refractionAmount: 1
        )
        let plan = try XCTUnwrap(GModMetalWaterRenderTargetContract.plan(
            materialRanges: [range(material: top)],
            cameraZ: 300
        ))

        XCTAssertEqual(
            plan.refractionFog,
            GModMetalWaterRefractionFog(
                sourceSurfaceZ: 128,
                fogStart: 0,
                fogEnd: 1_024
            )
        )

        let conflicting = material(
            fogEnabled: true,
            fogStart: 16,
            fogEnd: 2_048,
            reflectionAmount: nil,
            refractionAmount: 1
        )
        XCTAssertNil(try XCTUnwrap(GModMetalWaterRenderTargetContract.plan(
            materialRanges: [
                range(material: top),
                range(material: conflicting),
            ],
            cameraZ: 300
        )).refractionFog)

        let missingEnable = material(
            fogStart: 0,
            fogEnd: 1_024,
            reflectionAmount: nil,
            refractionAmount: 1
        )
        XCTAssertNil(try XCTUnwrap(GModMetalWaterRenderTargetContract.plan(
            materialRanges: [range(material: missingEnable)],
            cameraZ: 300
        )).refractionFog)
    }

    func testRenderTargetFlagsIntersectMaterialKeysWithRenderedPasses() throws {
        let reflectionOnly = material(
            reflectionAmount: -0.4,
            refractionAmount: nil
        )
        let both = material(
            reflectionAmount: 0,
            refractionAmount: -1.2
        )
        let plan = try XCTUnwrap(GModMetalWaterRenderTargetContract.plan(
            materialRanges: [
                range(material: reflectionOnly),
                range(material: both),
            ],
            cameraZ: 300
        ))

        XCTAssertEqual(plan.targetFlags(for: reflectionOnly), 1)
        XCTAssertEqual(plan.targetFlags(for: both), 3)
    }

    func testAuthoredUnsupportedTargetDoesNotAliasOwnedRuntimeTarget() {
        let unsupported = material(
            reflectionAmount: 0.4,
            refractionAmount: nil,
            reflectionTextureBinding:
                .unsupportedAuthoredTexture("water/custom_reflection")
        )

        XCTAssertNil(GModMetalWaterRenderTargetContract.plan(
            materialRanges: [range(material: unsupported)],
            cameraZ: 300
        ))
    }

    func testSharedReflectionRejectsConflictingReflectEntitiesContracts() throws {
        let worldOnly = material(
            reflectionAmount: 0.4,
            refractionAmount: nil,
            reflectionEntityMode: .authored(false)
        )
        let withEntities = material(
            reflectionAmount: 0.4,
            refractionAmount: nil,
            reflectionEntityMode: .authored(true)
        )
        let entityPlan = try XCTUnwrap(
            GModMetalWaterRenderTargetContract.plan(
                materialRanges: [range(material: withEntities)],
                cameraZ: 300
            )
        )
        XCTAssertTrue(entityPlan.drawsReflectedDynamicEntities)
        XCTAssertNil(GModMetalWaterRenderTargetContract.plan(
            materialRanges: [
                range(material: worldOnly),
                range(material: withEntities),
            ],
            cameraZ: 300
        ))
    }

    func testWaterAdapterKeepsUV88AsDuDvDistortion() throws {
        let files: [String: Data] = [
            "materials/water/dudv_contract.vmt": Data(
                """
                "Water"
                {
                    "$abovewater" "1"
                    "$fogcolor" "{ 7 58 66 }"
                    "$reflectamount" ".4"
                    "$refractamount" "1"
                    "$reflecttexture" "_rt_WaterReflection"
                    "$refracttexture" "_rt_WaterRefraction"
                    "$reflectentities" "1"
                    "$dudvmap" "water/dudv_contract"
                    "Proxies"
                    {
                        "TextureScroll"
                        {
                            "texturescrollvar" "$dudvmaptransform"
                            "texturescrollrate" ".03"
                            "texturescrollangle" "90"
                        }
                    }
                }
                """.utf8
            ),
            "materials/water/dudv_contract.vtf": makeWaterUV88VTF(
                u: 16,
                v: 240
            ),
        ]
        let resolver = GModMetalSurfaceSourceMaterialResolver { path in
            files[path.lowercased()]
        }
        let water = try XCTUnwrap(
            resolver.resolveWaterMaterial(named: "water/dudv_contract")
        )

        XCTAssertEqual(water.distortionEncoding, .duDvRG)
        XCTAssertEqual(
            water.normalBitmap?.rgbaBytes,
            Data([16, 240, 0, 255])
        )
        XCTAssertEqual(
            water.reflectionTextureBinding,
            .authoredRuntimeTarget("_rt_WaterReflection")
        )
        XCTAssertEqual(
            water.refractionTextureBinding,
            .authoredRuntimeTarget("_rt_WaterRefraction")
        )
        XCTAssertEqual(water.reflectionEntityMode, .authored(true))
        XCTAssertEqual(water.textureScrollRate, 0.03)
        XCTAssertEqual(water.textureScrollAngleDegrees, 90)
        XCTAssertNil(water.unsupportedDuDvTextureFormat)
    }

    func testSourceFresnelUsesFifthPowerOfOneMinusSaturatedNDotV() {
        XCTAssertEqual(
            GModMetalWaterSamplingContract.fresnel(
                normal: SIMD3<Float>(0, 0, 1),
                normalizedEyeVector: SIMD3<Float>(0, 0, 1)
            ),
            0
        )
        XCTAssertEqual(
            GModMetalWaterSamplingContract.fresnel(
                normal: SIMD3<Float>(0, 0, 1),
                normalizedEyeVector: SIMD3<Float>(1, 0, 0)
            ),
            1
        )
        XCTAssertEqual(
            GModMetalWaterSamplingContract.fresnel(
                normal: SIMD3<Float>(0, 0, 1),
                normalizedEyeVector: SIMD3<Float>(0.866_025_4, 0, 0.5)
            ),
            0.03125,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            GModMetalWaterSamplingContract.fresnel(
                normal: SIMD3<Float>(0, 0, 1),
                normalizedEyeVector: SIMD3<Float>(0, 0, -1)
            ),
            1
        )
    }

    func testDependentUVKeepsSeparateSignedAmountsWithoutViewportScaling() {
        let coordinates = GModMetalWaterSamplingContract
            .dependentTextureCoordinates(
                reflectionBase: SIMD2<Float>(0.25, 0.75),
                refractionBase: SIMD2<Float>(0.6, 0.2),
                decodedNormal: SIMD4<Float>(0.5, -0.25, 1, 0.8),
                reflectionAmount: -0.4,
                refractionAmount: 1.2
            )

        XCTAssertEqual(coordinates.reflection.x, 0.09, accuracy: 0.000_001)
        XCTAssertEqual(coordinates.reflection.y, 0.83, accuracy: 0.000_001)
        XCTAssertEqual(coordinates.refraction.x, 1.08, accuracy: 0.000_001)
        XCTAssertEqual(coordinates.refraction.y, -0.04, accuracy: 0.000_001)
    }

    func testAboveWaterDepthAlphaScalesBothDependentUVAmounts() {
        let coordinates = GModMetalWaterSamplingContract
            .dependentTextureCoordinates(
                reflectionBase: SIMD2<Float>(0.25, 0.75),
                refractionBase: SIMD2<Float>(0.6, 0.2),
                decodedNormal: SIMD4<Float>(0.5, -0.25, 1, 0.8),
                reflectionAmount: -0.4,
                refractionAmount: 1.2,
                unwarpedRefractionDepth: 0.25
            )

        XCTAssertEqual(coordinates.reflection.x, 0.21, accuracy: 0.000_001)
        XCTAssertEqual(coordinates.reflection.y, 0.77, accuracy: 0.000_001)
        XCTAssertEqual(coordinates.refraction.x, 0.72, accuracy: 0.000_001)
        XCTAssertEqual(coordinates.refraction.y, 0.14, accuracy: 0.000_001)
    }

    func testMetalReflectionRenderTargetInvertsScreenYOnly() {
        let bases = GModMetalWaterSamplingContract.renderTargetBases(
            screenUV: SIMD2<Float>(0.25, 0.75)
        )

        XCTAssertEqual(bases.reflection, SIMD2<Float>(0.25, 0.25))
        XCTAssertEqual(bases.refraction, SIMD2<Float>(0.25, 0.75))
    }

    private func material(
        isAboveWater: Bool = true,
        fogEnabled: Bool? = nil,
        fogStart: Float? = nil,
        fogEnd: Float? = nil,
        reflectionAmount: Float?,
        refractionAmount: Float?,
        reflectionTextureBinding: GModMetalWaterRenderTargetBinding =
            .sourceShaderDefaultRuntimeTarget("_rt_WaterReflection"),
        reflectionEntityMode: GModMetalWaterReflectionEntityMode =
            .sourceShaderDefaultDisabled
    ) -> GModMetalWorldWaterMaterial {
        GModMetalWorldWaterMaterial(
            resourceIdentifier: "materials/water/source_contract.vmt",
            isAboveWater: isAboveWater,
            fogColor: .zero,
            fogEnabled: fogEnabled,
            fogStart: fogStart,
            fogEnd: fogEnd,
            reflectionAmount: reflectionAmount,
            refractionAmount: refractionAmount,
            normalBitmap: nil,
            textureScrollRate: nil,
            textureScrollAngleDegrees: nil,
            unsupportedBumpTextureFormat: nil,
            reflectionTextureBinding: reflectionTextureBinding,
            reflectionEntityMode: reflectionEntityMode
        )
    }

    private func range(
        material: GModMetalWorldWaterMaterial
    ) -> GModMetalWorldMaterialRange {
        GModMetalWorldMaterialRange(
            materialName: "water/source_contract",
            firstIndex: 0,
            indexCount: 3,
            bitmap: nil,
            waterSurface: GModMetalWorldWaterSurface(
                surfaceZ: 128,
                minimumZ: -512
            ),
            waterMaterial: material
        )
    }

    private func retains(
        sourceZ: Float,
        plane: SIMD4<Float>
    ) -> Bool {
        GModMetalWaterClipPlaneContract.retains(
            metalPosition: SIMD3<Float>(0, sourceZ, 0),
            plane: plane
        )
    }

    private func cross(
        _ lhs: SIMD3<Float>,
        _ rhs: SIMD3<Float>
    ) -> SIMD3<Float> {
        SIMD3<Float>(
            lhs.y * rhs.z - lhs.z * rhs.y,
            lhs.z * rhs.x - lhs.x * rhs.z,
            lhs.x * rhs.y - lhs.y * rhs.x
        )
    }
}

private func makeWaterUV88VTF(u: UInt8, v: UInt8) -> Data {
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
    write(UInt32(bitPattern: SourceVTFImageFormat.uv88.rawValue), at: 52)
    bytes[56] = 1
    write(UInt32(bitPattern: SourceVTFImageFormat.unknown.rawValue), at: 57)
    write(UInt16(1), at: 63)
    bytes.append(contentsOf: [u, v])
    return Data(bytes)
}
