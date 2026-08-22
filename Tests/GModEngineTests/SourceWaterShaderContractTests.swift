import XCTest
import GModEngine

final class SourceWaterShaderContractTests: XCTestCase {
    func testProjectedDepthMatchesWorldPerspectiveClipZ() throws {
        XCTAssertEqual(
            try XCTUnwrap(SourceWaterShaderContract.projectedDepth(
                forwardDistance: 1
            )),
            0,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            try XCTUnwrap(SourceWaterShaderContract.projectedDepth(
                forwardDistance: 65_536
            )),
            65_536,
            accuracy: 0.01
        )
        XCTAssertNil(SourceWaterShaderContract.projectedDepth(
            forwardDistance: 10,
            near: 1,
            far: 1
        ))
    }

    func testRefractionTargetAlphaUsesUnderwaterRayFractionAndFogRange() throws {
        let alpha = try XCTUnwrap(
            SourceWaterShaderContract.refractionDepthAlpha(
                waterZ: 0,
                eyeZ: 128,
                worldZ: -128,
                projectedDepth: 512,
                fogStart: 0,
                fogEnd: 1_024
            )
        )
        XCTAssertEqual(alpha, 0.25, accuracy: 0.000_001)

        XCTAssertEqual(
            try XCTUnwrap(SourceWaterShaderContract.refractionDepthAlpha(
                waterZ: 0,
                eyeZ: 64,
                worldZ: -2_048,
                projectedDepth: 4_096,
                fogStart: 0,
                fogEnd: 1_024
            )),
            1
        )
        XCTAssertNil(SourceWaterShaderContract.refractionDepthAlpha(
            waterZ: 0,
            eyeZ: 0,
            worldZ: 0,
            projectedDepth: 1,
            fogStart: 0,
            fogEnd: 1_024
        ))
    }

    func testAboveWaterDepthAlphaDrivesFogAndFresnelGates() throws {
        XCTAssertEqual(
            try XCTUnwrap(SourceWaterShaderContract.aboveWaterFogFactor(
                depthAlpha: 0.05
            )),
            0
        )
        XCTAssertEqual(
            try XCTUnwrap(SourceWaterShaderContract.aboveWaterFogFactor(
                depthAlpha: 0.55
            )),
            0.5,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            try XCTUnwrap(
                SourceWaterShaderContract.aboveWaterFresnelDepthFactor(
                    depthAlpha: 0.05
                )
            ),
            0
        )
        XCTAssertEqual(
            try XCTUnwrap(
                SourceWaterShaderContract.aboveWaterFresnelDepthFactor(
                    depthAlpha: 0.075
                )
            ),
            0.5,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            try XCTUnwrap(
                SourceWaterShaderContract.aboveWaterFresnelDepthFactor(
                    depthAlpha: 0.1
                )
            ),
            1
        )
    }

    func testUnderwaterFogUsesAuthoredStartAndEnd() throws {
        XCTAssertEqual(
            try XCTUnwrap(SourceWaterShaderContract.underwaterFogFactor(
                projectedDepth: -1_024,
                fogStart: -1_024,
                fogEnd: 2_048
            )),
            0
        )
        XCTAssertEqual(
            try XCTUnwrap(SourceWaterShaderContract.underwaterFogFactor(
                projectedDepth: 512,
                fogStart: -1_024,
                fogEnd: 2_048
            )),
            0.5,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            try XCTUnwrap(SourceWaterShaderContract.underwaterFogFactor(
                projectedDepth: 4_096,
                fogStart: -1_024,
                fogEnd: 2_048
            )),
            1
        )
    }
}
