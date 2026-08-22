import Foundation
import XCTest
@testable import GModEngine

final class SourceWorldEnvironmentEntitiesTests: XCTestCase {
    func testCompilesVRADHDRLightEnvironmentAndAmbientFallback() throws {
        let state = try compile(
            """
            {
            "classname" "light_environment"
            "angles" "-30 60 0"
            "_light" "255 255 255 255"
            "_lightHDR" "128 64 32 510"
            "_lightscaleHDR" "2"
            "_AmbientScaleHDR" "3"
            "SunSpreadAngle" "5"
            }
            {
            "classname" "light_environment"
            "_light" "1"
            }
            """,
            mode: .highDynamicRange
        )
        let light = try XCTUnwrap(state.lightEnvironment)
        XCTAssertEqual(light.sourceEntityIndex, 0)
        XCTAssertEqual(light.directKey, "_lightHDR")
        XCTAssertNil(light.ambientKey)
        XCTAssertEqual(light.ignoredAdditionalEntityCount, 1)
        assertVector(
            light.sourceDirectionFromLight,
            SourceVector3(0.4330127, 0.75, -0.5)
        )
        let directBeforeScale = SourceVector3(
            vradChannel(128, scalar: 510),
            vradChannel(64, scalar: 510),
            vradChannel(32, scalar: 510)
        )
        assertVector(light.directLinearRGB, directBeforeScale * 2)
        assertVector(light.ambientLinearRGB, directBeforeScale * 3)
        XCTAssertEqual(light.sunSpreadAngleDegrees, 5)
        XCTAssertEqual(
            try XCTUnwrap(light.sunAngularExtent),
            sin(Float(5) * .pi / 180),
            accuracy: 0.000_001
        )
    }

    func testCompilesAngleAndTargetDrivenSunUsingSDKDefaults() throws {
        let state = try compile(
            """
            {
            "classname" "info_target"
            "targetname" "sun_focus"
            "origin" "10 0 0"
            }
            {
            "classname" "env_sun"
            "origin" "10 10 0"
            "target" "sun_focus"
            "rendercolor" "0 0 0"
            }
            {
            "classname" "env_sun"
            "use_angles" "1"
            "angles" "-60 180 0"
            "overlaycolor" "128 64 32 255"
            "HDRColorScale" "2"
            }
            """,
            mode: .standardDynamicRange
        )
        XCTAssertEqual(state.suns.count, 2)
        let targetSun = state.suns[0]
        XCTAssertFalse(targetSun.usesAngles)
        XCTAssertEqual(targetSun.resolvedTargetEntityIndex, 0)
        assertVector(targetSun.sourceDirectionToSun, SourceVector3(0, 1, 0))
        XCTAssertEqual(targetSun.core.displayRGB, SourceVector3(1, 1, 1))
        XCTAssertEqual(targetSun.core.size, 16)
        XCTAssertEqual(targetSun.overlay.size, 16)
        XCTAssertEqual(targetSun.core.materialName, "sprites/light_glow02_add_noz")
        XCTAssertEqual(targetSun.overlay.materialName, "sprites/light_glow02_add_noz")
        XCTAssertEqual(targetSun.hdrColorScale, 0)
        XCTAssertTrue(targetSun.isInitiallyOn)

        let angleSun = state.suns[1]
        assertVector(
            angleSun.sourceDirectionToSun,
            SourceVector3(0.5, 0, 0.8660254)
        )
        assertVector(
            angleSun.overlay.displayRGB,
            SourceVector3(128.0 / 255, 64.0 / 255, 32.0 / 255)
        )
        XCTAssertEqual(angleSun.hdrColorScale, 2)
    }

    func testCompilesSkyCameraScaleOriginAndActivatedFogDirection() throws {
        let state = try compile(
            """
            {
            "classname" "sky_camera"
            "origin" "100 200 300"
            "scale" "16"
            "use_angles" "1"
            "angles" "0 90 0"
            "fogenable" "1"
            "fogblend" "1"
            "fogcolor" "64 128 255 255"
            "fogcolor2" "10 20 30 128"
            "fogstart" "10"
            "fogend" "1000"
            "fogmaxdensity" "0.75"
            "fogradial" "1"
            }
            """,
            mode: .standardDynamicRange
        )
        let sky = try XCTUnwrap(state.skyCameras.first)
        XCTAssertEqual(sky.sourceOrigin, SourceVector3(100, 200, 300))
        XCTAssertEqual(sky.scale, 16)
        XCTAssertTrue(sky.fog.isEnabled)
        XCTAssertTrue(sky.fog.blendsColors)
        assertVector(sky.fog.sourcePrimaryDirection, SourceVector3(0, -1, 0))
        XCTAssertEqual(sky.fog.primaryDisplayRGBA.x, 64.0 / 255, accuracy: 0.000_001)
        XCTAssertEqual(sky.fog.primaryDisplayRGBA.y, 128.0 / 255, accuracy: 0.000_001)
        XCTAssertEqual(sky.fog.primaryDisplayRGBA.z, 1, accuracy: 0.000_001)
        XCTAssertEqual(sky.fog.secondaryDisplayRGBA.w, 128.0 / 255, accuracy: 0.000_001)
        XCTAssertEqual(sky.fog.start, 10)
        XCTAssertEqual(sky.fog.end, 1_000)
        XCTAssertEqual(sky.fog.maximumDensity, 0.75)
        XCTAssertTrue(sky.fog.isRadial)
    }

    func testDynamicSunTargetAndInvalidSkyScaleRemainTypedFailures() throws {
        XCTAssertThrowsError(try compile(
            """
            {
            "classname" "env_sun"
            "target" "!activator"
            }
            """,
            mode: .standardDynamicRange
        )) { error in
            XCTAssertEqual(
                error as? SourceWorldEnvironmentEntityError,
                .unsupportedDynamicTarget(entityIndex: 0, target: "!activator")
            )
        }

        XCTAssertThrowsError(try compile(
            """
            {
            "classname" "sky_camera"
            "origin" "0 0 0"
            "scale" "0"
            }
            """,
            mode: .standardDynamicRange
        )) { error in
            XCTAssertEqual(
                error as? SourceWorldEnvironmentEntityError,
                .invalidValue(
                    entityIndex: 0,
                    className: "sky_camera",
                    key: "scale",
                    value: "0"
                )
            )
        }
    }

    private func compile(
        _ entityText: String,
        mode: SourceWorldEnvironmentLightingMode
    ) throws -> SourceWorldEnvironmentEntityState {
        let parsed = try SourceBSPEntityText(
            rawBytes: Data((entityText + "\n\0").utf8)
        ).parsedEntities()
        return try SourceWorldEnvironmentEntityCompiler.compile(
            parsedEntities: parsed,
            lightingMode: mode
        )
    }

    private func vradChannel(_ channel: Double, scalar: Double) -> Float {
        Float(pow(channel / 255, 2.2) * 255 * (scalar / 255))
    }

    private func assertVector(
        _ actual: SourceVector3,
        _ expected: SourceVector3,
        accuracy: Float = 0.000_01,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.x, expected.x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.y, expected.y, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.z, expected.z, accuracy: accuracy, file: file, line: line)
    }
}
