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

    func testUV88DecoderKeepsDuDvOutOfNormalSemantics() throws {
        let image = try SourceWaterDuDvTextureDecoder.decodeUV88(
            data: Data([0, 255, 128, 64]),
            width: 2,
            height: 1,
            allocationLimits: SourceVTFAllocationLimits(
                maximumEncodedBytes: 4,
                maximumPixelCount: 2,
                maximumDecodedBytes: 8
            )
        )

        XCTAssertEqual(image.width, 2)
        XCTAssertEqual(image.height, 1)
        XCTAssertEqual(
            Array(image.rgbaBytes),
            [0, 255, 0, 255, 128, 64, 0, 255]
        )
        XCTAssertThrowsError(try SourceWaterDuDvTextureDecoder.decodeUV88(
            data: Data([0, 1]),
            width: 2,
            height: 1
        )) { error in
            XCTAssertEqual(
                error as? SourceWaterDuDvDecodeError,
                .invalidEncodedByteCount(expected: 4, actual: 2)
            )
        }
    }

    func testWaterResolverRetainsTargetProvenanceAndDecodesUV88() throws {
        let files: [String: Data] = [
            "materials/water/contract.vmt": Data(
                """
                "Water"
                {
                    "$reflecttexture" "_rt_WaterReflection"
                    "$refracttexture" "water/custom_refraction"
                    "$reflectentities" "1"
                    "$dudvmap" "water/contract_dudv"
                }
                """.utf8
            ),
            "materials/water/contract_dudv.vtf": makeUV88VTF(
                u: 32,
                v: 224
            ),
            "materials/water/defaults.vmt": Data(
                """
                "Water"
                {
                    "$abovewater" "1"
                }
                """.utf8
            ),
        ]
        let resolver = GMLuaSourceMaterialResolver { path in
            files[path.lowercased()]
        }
        let authored = try XCTUnwrap(
            resolver.resolveWater(named: "water/contract")
        )
        XCTAssertEqual(
            authored.reflectionTexture,
            .authored("_rt_WaterReflection")
        )
        XCTAssertEqual(
            authored.refractionTexture,
            .authored("water/custom_refraction")
        )
        XCTAssertEqual(authored.reflectEntities, true)
        XCTAssertEqual(authored.duDvTexture?.status, .decoded)
        XCTAssertEqual(
            authored.duDvTexture?.rgbaBytes.map { Array($0) },
            [32, 224, 0, 255]
        )

        let defaults = try XCTUnwrap(
            resolver.resolveWater(named: "water/defaults")
        )
        XCTAssertEqual(
            defaults.reflectionTexture,
            .sourceShaderDefault(
                SourceWaterShaderContract.reflectionRenderTargetName
            )
        )
        XCTAssertEqual(
            defaults.refractionTexture,
            .sourceShaderDefault(
                SourceWaterShaderContract.refractionRenderTargetName
            )
        )
        XCTAssertNil(defaults.reflectEntities)
    }
}

private func makeUV88VTF(u: UInt8, v: UInt8) -> Data {
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
