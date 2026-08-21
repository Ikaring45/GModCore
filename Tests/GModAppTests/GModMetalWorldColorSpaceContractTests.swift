import XCTest
@testable import GModMetal

final class GModMetalWorldColorSpaceContractTests: XCTestCase {
    func testIEC61966TransferBreakpointsAndRoundTrip() {
        XCTAssertEqual(
            GModMetalWorldColorSpaceContract.encodeLinearSDR(0),
            0,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            GModMetalWorldColorSpaceContract.encodeLinearSDR(0.003_130_8),
            0.040_449_936,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            GModMetalWorldColorSpaceContract.decodeDisplaySRGB(0.040_45),
            0.003_130_805,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            GModMetalWorldColorSpaceContract.encodeLinearSDR(1),
            1,
            accuracy: 0.000_001
        )

        for display: Float in [0, 0.02, 0.18, 0.5, 0.73, 1] {
            let linear = GModMetalWorldColorSpaceContract.decodeDisplaySRGB(
                display
            )
            XCTAssertEqual(
                GModMetalWorldColorSpaceContract.encodeLinearSDR(linear),
                display,
                accuracy: 0.000_002
            )
        }
    }

    func testSDRPolicyClampsHDRNegativeAndNonFiniteValues() {
        XCTAssertEqual(
            GModMetalWorldColorSpaceContract.encodeLinearSDR(4),
            1,
            accuracy: Float.ulpOfOne
        )
        XCTAssertEqual(
            GModMetalWorldColorSpaceContract.encodeLinearSDR(-0.5),
            0
        )
        XCTAssertEqual(
            GModMetalWorldColorSpaceContract.encodeLinearSDR(.infinity),
            1,
            accuracy: Float.ulpOfOne
        )
        XCTAssertEqual(
            GModMetalWorldColorSpaceContract.encodeLinearSDR(-.infinity),
            0
        )
        XCTAssertEqual(
            GModMetalWorldColorSpaceContract.encodeLinearSDR(.nan),
            0
        )
        XCTAssertEqual(
            GModMetalWorldColorSpaceContract.drawablePixelFormatName,
            "bgra8Unorm"
        )
    }

    func testSurfaceByteSemanticsRemainOutsideWorldTransfer() {
        XCTAssertTrue(
            GModMetalWorldColorSpaceContract.preservesSurfaceByteSemantics
        )
        XCTAssertEqual(
            GModMetalWorldColorSpaceContract.surfaceByteNormalized(0),
            0
        )
        XCTAssertEqual(
            GModMetalWorldColorSpaceContract.surfaceByteNormalized(128),
            Float(128) / 255,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            GModMetalWorldColorSpaceContract.surfaceByteNormalized(255),
            1
        )
        XCTAssertFalse(
            GModMetalWorldColorSpaceContract.metalShaderSupport.contains(
                "surface"
            )
        )
    }

    func testMetalSupportUsesTheSameExactTransferConstants() {
        let source = GModMetalWorldColorSpaceContract.metalShaderSupport
        XCTAssertTrue(source.contains("0.04045"))
        XCTAssertTrue(source.contains("0.0031308"))
        XCTAssertTrue(source.contains("12.92"))
        XCTAssertTrue(source.contains("1.055"))
        XCTAssertTrue(source.contains("1.0 / 2.4"))
        XCTAssertTrue(source.contains("gmodWorldOutput"))
    }
}
