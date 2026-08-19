import XCTest
import GModEngine

final class SourceVTFTests: XCTestCase {
    func testV71UsesOfficial64ByteHeaderAndImplicitUnitDepth() throws {
        let lowResolution = [UInt8](repeating: 0x3C, count: 8)
        let file = try SourceVTFFile(
            data: makeVTF(
                minor: 1,
                width: 1,
                height: 1,
                format: .rgba8888,
                imageData: [9, 8, 7, 6],
                lowResolutionFormat: .dxt1,
                lowResolutionWidth: 4,
                lowResolutionHeight: 4,
                lowResolutionData: lowResolution
            )
        )

        XCTAssertEqual(file.version, SourceVTFVersion(major: 7, minor: 1))
        XCTAssertEqual(file.headerSize, 64)
        XCTAssertEqual(file.depth, 1)
        XCTAssertEqual(file.lowResolutionDataRange, 64..<72)
        XCTAssertEqual(file.imageDataRange, 72..<76)
        XCTAssertEqual(
            try file.decodeRGBA8().pixel(x: 0, y: 0),
            SourceVTFColorRGBA8(red: 9, green: 8, blue: 7, alpha: 6)
        )
    }

    func testV72LegacyLowResolutionPlacementAndHeaderFields() throws {
        let lowResolution = [UInt8](repeating: 0xA5, count: 8)
        let fileData = makeVTF(
            minor: 2,
            width: 1,
            height: 1,
            format: .rgba8888,
            imageData: [1, 2, 3, 4],
            lowResolutionFormat: .dxt1,
            lowResolutionWidth: 4,
            lowResolutionHeight: 4,
            lowResolutionData: lowResolution
        )

        let file = try SourceVTFFile(data: fileData)
        XCTAssertEqual(file.version, SourceVTFVersion(major: 7, minor: 2))
        XCTAssertEqual(file.headerSize, 80)
        XCTAssertEqual(file.width, 1)
        XCTAssertEqual(file.height, 1)
        XCTAssertEqual(file.depth, 1)
        XCTAssertEqual(file.frameCount, 1)
        XCTAssertEqual(file.mipCount, 1)
        XCTAssertEqual(file.lowResolutionFormat, .dxt1)
        XCTAssertEqual(file.lowResolutionDataRange, 80..<88)
        XCTAssertEqual(file.imageDataRange, 88..<92)
        XCTAssertEqual(file.lowResolutionData(), Data(lowResolution))
        XCTAssertEqual(
            try file.decodeRGBA8().pixel(x: 0, y: 0),
            SourceVTFColorRGBA8(red: 1, green: 2, blue: 3, alpha: 4)
        )
    }

    func testUncompressedFormatsDecodeOnlyTheirDeclaredByteOrder() throws {
        let expected = SourceVTFColorRGBA8(red: 1, green: 2, blue: 3, alpha: 4)
        let cases: [(SourceVTFImageFormat, [UInt8], SourceVTFColorRGBA8)] = [
            (.rgba8888, [1, 2, 3, 4], expected),
            (.bgra8888, [3, 2, 1, 4], expected),
            (.abgr8888, [4, 3, 2, 1], expected),
            (.argb8888, [4, 1, 2, 3], expected),
            (
                .bgrx8888,
                [3, 2, 1, 0],
                SourceVTFColorRGBA8(red: 1, green: 2, blue: 3, alpha: 255)
            ),
            (
                .rgb888,
                [1, 2, 3],
                SourceVTFColorRGBA8(red: 1, green: 2, blue: 3, alpha: 255)
            ),
            (
                .bgr888,
                [3, 2, 1],
                SourceVTFColorRGBA8(red: 1, green: 2, blue: 3, alpha: 255)
            )
        ]

        for (format, encoded, expectedPixel) in cases {
            let file = try SourceVTFFile(
                data: makeVTF(
                    minor: 3,
                    width: 1,
                    height: 1,
                    format: format,
                    imageData: encoded
                )
            )
            XCTAssertEqual(
                try file.decodeRGBA8().pixel(x: 0, y: 0),
                expectedPixel,
                "format \(format)"
            )
        }
    }

    func testPacked16FormatsUseSourceLeastSignificantComponentOrder() throws {
        let cases: [(SourceVTFImageFormat, [UInt8], SourceVTFColorRGBA8)] = [
            // Source names the least-significant component first. The same
            // 0x001F word is therefore red in RGB565 and blue in BGR565.
            (
                .rgb565,
                [0x1F, 0x00],
                SourceVTFColorRGBA8(red: 255, green: 0, blue: 0, alpha: 255)
            ),
            (
                .bgr565,
                [0x1F, 0x00],
                SourceVTFColorRGBA8(red: 0, green: 0, blue: 255, alpha: 255)
            ),
            // Generic packed UNORM conversion is normalized requantization;
            // five-bit red value 3 maps to round(3 * 255 / 31) = 25.
            (
                .bgr565,
                [0x00, 0x18],
                SourceVTFColorRGBA8(red: 25, green: 0, blue: 0, alpha: 255)
            ),
            // A=10, R=11, G=12, B=13. Four-bit UNORM expands exactly by
            // nibble replication (0xA -> 0xAA, and so on).
            (
                .bgra4444,
                [0xCD, 0xAB],
                SourceVTFColorRGBA8(red: 0xBB, green: 0xCC, blue: 0xDD, alpha: 0xAA)
            ),
            // The high X bit is padding and must not become alpha.
            (
                .bgrx5551,
                [0x00, 0x7C],
                SourceVTFColorRGBA8(red: 255, green: 0, blue: 0, alpha: 255)
            ),
            // The corresponding BGRA form gives bit 15 alpha semantics.
            (
                .bgra5551,
                [0x00, 0xFC],
                SourceVTFColorRGBA8(red: 255, green: 0, blue: 0, alpha: 255)
            ),
            (
                .bgra5551,
                [0x00, 0x7C],
                SourceVTFColorRGBA8(red: 255, green: 0, blue: 0, alpha: 0)
            )
        ]

        for (format, encoded, expectedPixel) in cases {
            let file = try SourceVTFFile(
                data: makeVTF(
                    minor: 3,
                    width: 1,
                    height: 1,
                    format: format,
                    imageData: encoded
                )
            )
            XCTAssertEqual(
                try file.decodeRGBA8().pixel(x: 0, y: 0),
                expectedPixel,
                "format \(format)"
            )
        }
    }

    func testIntensityAndAlphaFormatsHaveSourceSamplingSemantics() throws {
        let cases: [(SourceVTFImageFormat, [UInt8], SourceVTFColorRGBA8)] = [
            (
                .i8,
                [0x7F],
                SourceVTFColorRGBA8(red: 0x7F, green: 0x7F, blue: 0x7F, alpha: 255)
            ),
            (
                .ia88,
                [0x7F, 0x40],
                SourceVTFColorRGBA8(red: 0x7F, green: 0x7F, blue: 0x7F, alpha: 0x40)
            ),
            // D3DFMT_A8 is the explicit exception where absent RGB reads 0.
            (
                .a8,
                [0x40],
                SourceVTFColorRGBA8(red: 0, green: 0, blue: 0, alpha: 0x40)
            )
        ]

        for (format, encoded, expectedPixel) in cases {
            let file = try SourceVTFFile(
                data: makeVTF(
                    minor: 3,
                    width: 1,
                    height: 1,
                    format: format,
                    imageData: encoded
                )
            )
            XCTAssertEqual(
                try file.decodeRGBA8().pixel(x: 0, y: 0),
                expectedPixel,
                "format \(format)"
            )
        }
    }

    func testDXT3UsesExplicitAlphaFourColorModeAndCropsEdgeBlock() throws {
        // Width 2 still occupies one complete 4x4 BC2 block. Alpha nibbles
        // for the visible texels are 0 and 15. color0 <= color1, while index 3
        // verifies that BC2 does not select BC1's transparent entry.
        var block = [UInt8](repeating: 0, count: 8)
        block[0] = 0xF0
        block.append(contentsOf: [0x00, 0x00, 0xFF, 0xFF])
        appendLittleEndian(UInt32(0x0000_0003), to: &block)

        let file = try SourceVTFFile(
            data: makeVTF(
                minor: 3,
                width: 2,
                height: 1,
                format: .dxt3,
                imageData: block
            )
        )
        let decoded = try file.decodeRGBA8()
        XCTAssertEqual(decoded.rgbaBytes.count, 2 * 4)
        XCTAssertEqual(
            decoded.pixel(x: 0, y: 0),
            SourceVTFColorRGBA8(red: 170, green: 170, blue: 170, alpha: 0)
        )
        XCTAssertEqual(
            decoded.pixel(x: 1, y: 0),
            SourceVTFColorRGBA8(red: 0, green: 0, blue: 0, alpha: 255)
        )
    }

    func testATI1NAndATI2NUseBC4AndBC5UNORMInterpolation() throws {
        // Visible edge-block texels use two different packed indices. The
        // remaining 14 physical texels are deliberately outside virtual width.
        let redIndices = UInt64(2) | (UInt64(1) << 3)
        let greenIndices = UInt64(2) | (UInt64(7) << 3)
        var redBlock: [UInt8] = [255, 0]
        appendSixByteLittleEndian(redIndices, to: &redBlock)

        let bc4 = try SourceVTFFile(
            data: makeVTF(
                minor: 5,
                width: 2,
                height: 1,
                format: .ati1N,
                imageData: redBlock
            )
        )
        XCTAssertEqual(
            try bc4.decodeRGBA8().pixel(x: 0, y: 0),
            SourceVTFColorRGBA8(red: 219, green: 0, blue: 0, alpha: 255)
        )
        XCTAssertEqual(
            try bc4.decodeRGBA8().pixel(x: 1, y: 0),
            SourceVTFColorRGBA8(red: 0, green: 0, blue: 0, alpha: 255)
        )

        // endpoint0 <= endpoint1 selects BC4's four-intermediate branch:
        // round((4 * 0 + 1 * 3) / 5) = 1 for palette index 2.
        var greenBlock: [UInt8] = [0, 3]
        appendSixByteLittleEndian(greenIndices, to: &greenBlock)
        let bc5 = try SourceVTFFile(
            data: makeVTF(
                minor: 5,
                width: 2,
                height: 1,
                format: .ati2N,
                imageData: redBlock + greenBlock
            )
        )
        XCTAssertEqual(
            try bc5.decodeRGBA8().pixel(x: 0, y: 0),
            SourceVTFColorRGBA8(red: 219, green: 1, blue: 0, alpha: 255)
        )
        XCTAssertEqual(
            try bc5.decodeRGBA8().pixel(x: 1, y: 0),
            SourceVTFColorRGBA8(red: 0, green: 255, blue: 0, alpha: 255)
        )
    }

    func testDXT1Decodes565PaletteAndTwoBitIndices() throws {
        var indices: UInt32 = 0
        for pixel in 0..<16 {
            indices |= UInt32(pixel % 4) << UInt32(pixel * 2)
        }
        var block: [UInt8] = [0x00, 0xF8, 0xE0, 0x07]
        appendLittleEndian(indices, to: &block)

        let file = try SourceVTFFile(
            data: makeVTF(
                minor: 3,
                width: 4,
                height: 4,
                format: .dxt1,
                imageData: block
            )
        )
        let decoded = try file.decodeRGBA8()
        XCTAssertEqual(
            decoded.pixel(x: 0, y: 0),
            SourceVTFColorRGBA8(red: 255, green: 0, blue: 0, alpha: 255)
        )
        XCTAssertEqual(
            decoded.pixel(x: 1, y: 0),
            SourceVTFColorRGBA8(red: 0, green: 255, blue: 0, alpha: 255)
        )
        XCTAssertEqual(
            decoded.pixel(x: 2, y: 0),
            SourceVTFColorRGBA8(red: 170, green: 85, blue: 0, alpha: 255)
        )
        XCTAssertEqual(
            decoded.pixel(x: 3, y: 0),
            SourceVTFColorRGBA8(red: 85, green: 170, blue: 0, alpha: 255)
        )
    }

    func testDXT5DecodesIndependentAlphaIndices() throws {
        var alphaIndices: UInt64 = 0
        for pixel in 0..<16 {
            alphaIndices |= UInt64(pixel % 8) << UInt64(pixel * 3)
        }
        var block: [UInt8] = [255, 0]
        for byte in 0..<6 {
            block.append(UInt8(truncatingIfNeeded: alphaIndices >> UInt64(byte * 8)))
        }
        block.append(contentsOf: [0x00, 0xF8, 0xE0, 0x07])
        appendLittleEndian(UInt32(0), to: &block)

        let file = try SourceVTFFile(
            data: makeVTF(
                minor: 5,
                width: 4,
                height: 4,
                format: .dxt5,
                imageData: block
            )
        )
        let decoded = try file.decodeRGBA8()
        XCTAssertEqual(decoded.pixel(x: 0, y: 0)?.alpha, 255)
        XCTAssertEqual(decoded.pixel(x: 1, y: 0)?.alpha, 0)
        XCTAssertEqual(decoded.pixel(x: 2, y: 0)?.alpha, 219)
        XCTAssertEqual(decoded.pixel(x: 3, y: 0)?.alpha, 182)
        XCTAssertEqual(decoded.pixel(x: 3, y: 1)?.alpha, 36)
        XCTAssertEqual(decoded.pixel(x: 0, y: 0)?.red, 255)
    }

    func testBC1AndBC3InterpolationRoundsToNearestUNORMCodePoint() throws {
        var colorIndices: UInt32 = 0
        var alphaIndices: UInt64 = 0
        for pixel in 0..<16 {
            colorIndices |= UInt32(2) << UInt32(pixel * 2)
            alphaIndices |= UInt64(2) << UInt64(pixel * 3)
        }

        // RGB565 endpoints decode to red 255 and 8. Palette entry 2 is
        // round((2 * 255 + 8) / 3) = 173, not the truncated value 172.
        var bc1Block: [UInt8] = [0x00, 0xF8, 0x00, 0x08]
        appendLittleEndian(colorIndices, to: &bc1Block)
        let bc1 = try SourceVTFFile(
            data: makeVTF(
                minor: 3,
                width: 4,
                height: 4,
                format: .dxt1,
                imageData: bc1Block
            )
        )
        XCTAssertEqual(
            try bc1.decodeRGBA8().pixel(x: 0, y: 0),
            SourceVTFColorRGBA8(red: 173, green: 0, blue: 0, alpha: 255)
        )

        // The same color block is used by BC3. Alpha entry 2 is
        // round((6 * 255) / 7) = 219, not 218.
        var bc3Block: [UInt8] = [255, 0]
        for byte in 0..<6 {
            bc3Block.append(UInt8(truncatingIfNeeded: alphaIndices >> UInt64(byte * 8)))
        }
        bc3Block.append(contentsOf: [0x00, 0xF8, 0x00, 0x08])
        appendLittleEndian(colorIndices, to: &bc3Block)
        let bc3 = try SourceVTFFile(
            data: makeVTF(
                minor: 5,
                width: 4,
                height: 4,
                format: .dxt5,
                imageData: bc3Block
            )
        )
        XCTAssertEqual(
            try bc3.decodeRGBA8().pixel(x: 0, y: 0),
            SourceVTFColorRGBA8(red: 173, green: 0, blue: 0, alpha: 219)
        )

        // Exercise the four-intermediate-alpha branch too:
        // round((4 * 0 + 3) / 5) = 1, while truncation produced 0.
        var fourStepBlock: [UInt8] = [0, 3]
        for byte in 0..<6 {
            fourStepBlock.append(UInt8(truncatingIfNeeded: alphaIndices >> UInt64(byte * 8)))
        }
        fourStepBlock.append(contentsOf: [0x00, 0xF8, 0x00, 0x08])
        appendLittleEndian(colorIndices, to: &fourStepBlock)
        let fourStep = try SourceVTFFile(
            data: makeVTF(
                minor: 5,
                width: 4,
                height: 4,
                format: .dxt5,
                imageData: fourStepBlock
            )
        )
        XCTAssertEqual(try fourStep.decodeRGBA8().pixel(x: 0, y: 0)?.alpha, 1)

        var endpointOneIndices: UInt32 = 0
        for pixel in 0..<16 {
            endpointOneIndices |= UInt32(1) << UInt32(pixel * 2)
        }
        // BC endpoint promotion uses MSB extension, not a generic normalized
        // requantization: five-bit value 3 becomes 0b00011000 (24).
        var promotedEndpointBlock: [UInt8] = [0x00, 0xF8, 0x00, 0x18]
        appendLittleEndian(endpointOneIndices, to: &promotedEndpointBlock)
        let promotedEndpoint = try SourceVTFFile(
            data: makeVTF(
                minor: 3,
                width: 4,
                height: 4,
                format: .dxt1,
                imageData: promotedEndpointBlock
            )
        )
        XCTAssertEqual(
            try promotedEndpoint.decodeRGBA8().pixel(x: 0, y: 0)?.red,
            24
        )
    }

    func testV75SubresourceOffsetsFollowCoarsestMipFrameFaceSliceDiskOrder() throws {
        var imageBytes: [UInt8] = []

        // Mip 1: 1x1x1, two frames, six cubemap faces.
        for ordinal in 0..<12 {
            imageBytes.append(contentsOf: [UInt8(ordinal), 0, 0, 255])
        }

        // Mip 0: 2x2x2, two frames, six faces, two slices per face.
        for ordinal in 0..<24 {
            for _ in 0..<4 {
                imageBytes.append(contentsOf: [UInt8(100 + ordinal), 1, 2, 255])
            }
        }

        let file = try SourceVTFFile(
            data: makeVTF(
                minor: 5,
                width: 2,
                height: 2,
                depth: 2,
                flags: [.environmentMap],
                frames: 2,
                firstFrame: 0,
                mipCount: 2,
                format: .rgba8888,
                imageData: imageBytes
            )
        )

        XCTAssertEqual(file.faceCount, 6)
        XCTAssertEqual(file.imageDataRange, 88..<520)

        let coarse = try file.subresource(mipLevel: 1, frame: 1, face: 5)
        XCTAssertEqual(coarse.width, 1)
        XCTAssertEqual(coarse.height, 1)
        XCTAssertEqual(coarse.mipDepth, 1)
        XCTAssertEqual(coarse.fileRange, 132..<136)
        XCTAssertEqual(coarse.data, Data([11, 0, 0, 255]))

        let largest = try file.subresource(
            mipLevel: 0,
            frame: 1,
            face: 5,
            slice: 1
        )
        XCTAssertEqual(largest.width, 2)
        XCTAssertEqual(largest.height, 2)
        XCTAssertEqual(largest.mipDepth, 2)
        XCTAssertEqual(largest.fileRange, 504..<520)
        XCTAssertEqual(largest.data.first, 123)
        XCTAssertEqual(
            try file.decodeRGBA8(
                mipLevel: 0,
                frame: 1,
                face: 5,
                slice: 1
            ).pixel(x: 1, y: 1),
            SourceVTFColorRGBA8(red: 123, green: 1, blue: 2, alpha: 255)
        )

        XCTAssertThrowsError(try file.subresource(mipLevel: 0, slice: 2)) { error in
            guard case SourceVTFError.subresourceOutOfRange = error else {
                return XCTFail("expected subresourceOutOfRange, got \(error)")
            }
        }
    }

    func testLegacyCubemapHasSeventhSpheremapFaceOnlyBeforeV75() throws {
        let oldFile = try SourceVTFFile(
            data: makeVTF(
                minor: 3,
                width: 1,
                height: 1,
                flags: [.environmentMap],
                firstFrame: 0,
                format: .rgba8888,
                imageData: [UInt8](repeating: 0, count: 7 * 4)
            )
        )
        let oldFileWithoutSphere = try SourceVTFFile(
            data: makeVTF(
                minor: 4,
                width: 1,
                height: 1,
                flags: [.environmentMap],
                firstFrame: UInt16.max,
                format: .rgba8888,
                imageData: [UInt8](repeating: 0, count: 6 * 4)
            )
        )
        let newFile = try SourceVTFFile(
            data: makeVTF(
                minor: 5,
                width: 1,
                height: 1,
                flags: [.environmentMap],
                firstFrame: 0,
                format: .rgba8888,
                imageData: [UInt8](repeating: 0, count: 6 * 4)
            )
        )

        XCTAssertEqual(oldFile.faceCount, 7)
        XCTAssertEqual(oldFileWithoutSphere.faceCount, 6)
        XCTAssertEqual(newFile.faceCount, 6)
    }

    func testResourceDictionarySeparatesChunkAndInlineResources() throws {
        let genericType: UInt32 = 0x000010
        let inlineType: UInt32 = 0x000011
        let headerSize = 104
        let genericChunk = [UInt8](arrayLiteral: 4, 0, 0, 0, 9, 8, 7, 6)
        let file = try SourceVTFFile(
            data: makeVTF(
                minor: 3,
                width: 1,
                height: 1,
                format: .rgba8888,
                imageData: [1, 2, 3, 4],
                additionalResources: [
                    (rawType: genericType, dataOrOffset: UInt32(headerSize)),
                    (rawType: 0x0200_0000 | inlineType, dataOrOffset: 0x1234_5678)
                ],
                bytesBeforeImage: genericChunk
            )
        )

        XCTAssertEqual(file.headerSize, headerSize)
        XCTAssertEqual(file.resources.map(\.type), [0x30, genericType, inlineType])
        XCTAssertFalse(file.resources[1].hasNoDataChunk)
        XCTAssertTrue(file.resources[2].hasNoDataChunk)
        XCTAssertEqual(file.resources[2].dataOrOffset, 0x1234_5678)
        XCTAssertEqual(file.resourceData(for: genericType), Data([9, 8, 7, 6]))
        XCTAssertNil(file.resourceData(for: inlineType))
        XCTAssertEqual(file.imageDataRange, 112..<116)
    }

    func testMalformedTruncatedUnknownUnsupportedAndOverflowAreExplicit() throws {
        var unsupportedV70 = Array(makeVTF(
            minor: 1,
            width: 1,
            height: 1,
            format: .rgba8888,
            imageData: [0, 0, 0, 0]
        ))
        write(UInt32(0), at: 8, in: &unsupportedV70)
        XCTAssertThrowsError(try SourceVTFFile(data: Data(unsupportedV70))) { error in
            XCTAssertEqual(
                error as? SourceVTFError,
                .unsupportedVersion(SourceVTFVersion(major: 7, minor: 0))
            )
        }

        var invalidSignature = makeVTF(
            minor: 2,
            width: 1,
            height: 1,
            format: .rgba8888,
            imageData: [0, 0, 0, 0]
        )
        invalidSignature[0] = 0
        XCTAssertThrowsError(try SourceVTFFile(data: invalidSignature)) { error in
            guard case SourceVTFError.invalidSignature = error else {
                return XCTFail("expected invalidSignature, got \(error)")
            }
        }

        var undersizedV72Header = Array(makeVTF(
            minor: 2,
            width: 1,
            height: 1,
            format: .rgba8888,
            imageData: [0, 0, 0, 0]
        ))
        write(UInt32(65), at: 12, in: &undersizedV72Header)
        XCTAssertThrowsError(try SourceVTFFile(data: Data(undersizedV72Header))) { error in
            XCTAssertEqual(error as? SourceVTFError, .invalidHeaderSize(65, minimum: 80))
        }

        var truncated = makeVTF(
            minor: 2,
            width: 1,
            height: 1,
            format: .rgba8888,
            imageData: [0, 0, 0, 0]
        )
        truncated.removeLast()
        XCTAssertThrowsError(try SourceVTFFile(data: truncated)) { error in
            guard case SourceVTFError.truncated(context: "image data", _, _) = error else {
                return XCTFail("expected image-data truncation, got \(error)")
            }
        }

        let unknown = makeVTF(
            minor: 3,
            width: 1,
            height: 1,
            rawImageFormat: 999,
            imageData: []
        )
        XCTAssertThrowsError(try SourceVTFFile(data: unknown)) { error in
            XCTAssertEqual(error as? SourceVTFError, .unknownImageFormat(999))
        }

        let unsupportedFile = try SourceVTFFile(
            data: makeVTF(
                minor: 3,
                width: 1,
                height: 1,
                format: .uv88,
                imageData: [0, 0]
            )
        )
        XCTAssertThrowsError(try unsupportedFile.decodeRGBA8()) { error in
            XCTAssertEqual(error as? SourceVTFError, .unsupportedImageFormat(.uv88))
        }

        let overflowing = makeVTF(
            minor: 5,
            width: 65_535,
            height: 65_535,
            depth: 65_535,
            frames: 65_535,
            format: .rgba8888,
            imageData: []
        )
        XCTAssertThrowsError(try SourceVTFFile(data: overflowing)) { error in
            guard case SourceVTFError.arithmeticOverflow = error else {
                return XCTFail("expected arithmeticOverflow, got \(error)")
            }
        }
    }

    func testEncodedPixelAndDecodedAllocationBudgetsAreIndependent() throws {
        let data = makeVTF(
            minor: 3,
            width: 2,
            height: 2,
            format: .rgba8888,
            imageData: [UInt8](repeating: 0, count: 16)
        )

        XCTAssertThrowsError(
            try SourceVTFFile(
                data: data,
                allocationLimits: SourceVTFAllocationLimits(
                    maximumEncodedBytes: data.count - 1
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? SourceVTFError,
                .allocationLimitExceeded(
                    context: "encoded file bytes",
                    limit: data.count - 1,
                    actual: data.count
                )
            )
        }

        let pixelLimited = try SourceVTFFile(
            data: data,
            allocationLimits: SourceVTFAllocationLimits(maximumPixelCount: 3)
        )
        XCTAssertThrowsError(try pixelLimited.decodeRGBA8()) { error in
            XCTAssertEqual(
                error as? SourceVTFError,
                .allocationLimitExceeded(
                    context: "decoded pixel count",
                    limit: 3,
                    actual: 4
                )
            )
        }

        let byteLimited = try SourceVTFFile(
            data: data,
            allocationLimits: SourceVTFAllocationLimits(
                maximumPixelCount: 4,
                maximumDecodedBytes: 15
            )
        )
        XCTAssertThrowsError(try byteLimited.decodeRGBA8()) { error in
            XCTAssertEqual(
                error as? SourceVTFError,
                .allocationLimitExceeded(
                    context: "decoded RGBA8 bytes",
                    limit: 15,
                    actual: 16
                )
            )
        }

        let compactBC1 = try SourceVTFFile(
            data: makeVTF(
                minor: 3,
                width: 8,
                height: 8,
                format: .dxt1,
                imageData: [UInt8](repeating: 0, count: 32)
            ),
            allocationLimits: SourceVTFAllocationLimits(
                maximumPixelCount: 64,
                maximumDecodedBytes: 255
            )
        )
        XCTAssertThrowsError(try compactBC1.decodeRGBA8()) { error in
            XCTAssertEqual(
                error as? SourceVTFError,
                .allocationLimitExceeded(
                    context: "decoded RGBA8 bytes",
                    limit: 255,
                    actual: 256
                )
            )
        }
    }

    private func appendSixByteLittleEndian(_ value: UInt64, to bytes: inout [UInt8]) {
        for byte in 0..<6 {
            bytes.append(UInt8(truncatingIfNeeded: value >> UInt64(byte * 8)))
        }
    }

    private func makeVTF(
        minor: Int,
        width: Int,
        height: Int,
        depth: Int = 1,
        flags: SourceVTFTextureFlags = [],
        frames: Int = 1,
        firstFrame: UInt16 = 0,
        mipCount: Int = 1,
        format: SourceVTFImageFormat,
        imageData: [UInt8],
        lowResolutionFormat: SourceVTFImageFormat = .unknown,
        lowResolutionWidth: Int = 0,
        lowResolutionHeight: Int = 0,
        lowResolutionData: [UInt8] = [],
        additionalResources: [(rawType: UInt32, dataOrOffset: UInt32)] = [],
        bytesBeforeImage: [UInt8] = []
    ) -> Data {
        makeVTF(
            minor: minor,
            width: width,
            height: height,
            depth: depth,
            flags: flags,
            frames: frames,
            firstFrame: firstFrame,
            mipCount: mipCount,
            rawImageFormat: format.rawValue,
            imageData: imageData,
            lowResolutionFormat: lowResolutionFormat,
            lowResolutionWidth: lowResolutionWidth,
            lowResolutionHeight: lowResolutionHeight,
            lowResolutionData: lowResolutionData,
            additionalResources: additionalResources,
            bytesBeforeImage: bytesBeforeImage
        )
    }

    private func makeVTF(
        minor: Int,
        width: Int,
        height: Int,
        depth: Int = 1,
        flags: SourceVTFTextureFlags = [],
        frames: Int = 1,
        firstFrame: UInt16 = 0,
        mipCount: Int = 1,
        rawImageFormat: Int32,
        imageData: [UInt8],
        lowResolutionFormat: SourceVTFImageFormat = .unknown,
        lowResolutionWidth: Int = 0,
        lowResolutionHeight: Int = 0,
        lowResolutionData: [UInt8] = [],
        additionalResources: [(rawType: UInt32, dataOrOffset: UInt32)] = [],
        bytesBeforeImage: [UInt8] = []
    ) -> Data {
        let resourceCount = minor >= 3 ? 1 + additionalResources.count : 0
        let fixedHeaderSize = minor == 1 ? 64 : 80
        let headerSize = minor >= 3 ? 80 + resourceCount * 8 : fixedHeaderSize
        let imageOffset = headerSize + bytesBeforeImage.count
        var bytes = [UInt8](repeating: 0, count: headerSize)

        bytes.replaceSubrange(0..<4, with: [0x56, 0x54, 0x46, 0x00])
        write(UInt32(7), at: 4, in: &bytes)
        write(UInt32(minor), at: 8, in: &bytes)
        write(UInt32(headerSize), at: 12, in: &bytes)
        write(UInt16(truncatingIfNeeded: width), at: 16, in: &bytes)
        write(UInt16(truncatingIfNeeded: height), at: 18, in: &bytes)
        write(flags.rawValue, at: 20, in: &bytes)
        write(UInt16(truncatingIfNeeded: frames), at: 24, in: &bytes)
        write(firstFrame, at: 26, in: &bytes)
        write(Float(1).bitPattern, at: 48, in: &bytes)
        write(UInt32(bitPattern: rawImageFormat), at: 52, in: &bytes)
        bytes[56] = UInt8(truncatingIfNeeded: mipCount)
        write(UInt32(bitPattern: lowResolutionFormat.rawValue), at: 57, in: &bytes)
        bytes[61] = UInt8(truncatingIfNeeded: lowResolutionWidth)
        bytes[62] = UInt8(truncatingIfNeeded: lowResolutionHeight)
        if minor >= 2 {
            write(UInt16(truncatingIfNeeded: depth), at: 63, in: &bytes)
        }

        if minor >= 3 {
            write(UInt32(resourceCount), at: 68, in: &bytes)
            write(UInt32(0x30), at: 80, in: &bytes)
            write(UInt32(imageOffset), at: 84, in: &bytes)
            for (index, resource) in additionalResources.enumerated() {
                let offset = 88 + index * 8
                write(resource.rawType, at: offset, in: &bytes)
                write(resource.dataOrOffset, at: offset + 4, in: &bytes)
            }
            bytes.append(contentsOf: bytesBeforeImage)
        } else {
            bytes.append(contentsOf: lowResolutionData)
        }
        bytes.append(contentsOf: imageData)
        return Data(bytes)
    }

    private func write(_ value: UInt16, at offset: Int, in bytes: inout [UInt8]) {
        bytes[offset] = UInt8(truncatingIfNeeded: value)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }

    private func write(_ value: UInt32, at offset: Int, in bytes: inout [UInt8]) {
        bytes[offset] = UInt8(truncatingIfNeeded: value)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        bytes[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
        bytes[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
    }

    private func appendLittleEndian(_ value: UInt32, to bytes: inout [UInt8]) {
        bytes.append(UInt8(truncatingIfNeeded: value))
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
        bytes.append(UInt8(truncatingIfNeeded: value >> 16))
        bytes.append(UInt8(truncatingIfNeeded: value >> 24))
    }
}
