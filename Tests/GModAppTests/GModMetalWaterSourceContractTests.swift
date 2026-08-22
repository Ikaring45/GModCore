import XCTest
@testable import GModMetal

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

    func testMetalReflectionRenderTargetInvertsScreenYOnly() {
        let bases = GModMetalWaterSamplingContract.renderTargetBases(
            screenUV: SIMD2<Float>(0.25, 0.75)
        )

        XCTAssertEqual(bases.reflection, SIMD2<Float>(0.25, 0.25))
        XCTAssertEqual(bases.refraction, SIMD2<Float>(0.25, 0.75))
    }

    private func material(
        isAboveWater: Bool = true,
        reflectionAmount: Float?,
        refractionAmount: Float?
    ) -> GModMetalWorldWaterMaterial {
        GModMetalWorldWaterMaterial(
            resourceIdentifier: "materials/water/source_contract.vmt",
            isAboveWater: isAboveWater,
            fogColor: .zero,
            fogStart: nil,
            fogEnd: nil,
            reflectionAmount: reflectionAmount,
            refractionAmount: refractionAmount,
            normalBitmap: nil,
            textureScrollRate: nil,
            textureScrollAngleDegrees: nil,
            unsupportedBumpTextureFormat: nil
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
