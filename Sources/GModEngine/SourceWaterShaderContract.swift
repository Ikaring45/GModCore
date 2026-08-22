import Foundation

/// CPU reference for the depth/fog terms in Source SDK 2013's
/// `common_ps_fxc.h` and `water_ps2x_helper.h`.
///
/// The renderer mirrors these operations in Metal. Keeping the arithmetic in
/// the platform-neutral engine target gives Windows XCTest an exact contract
/// for the authored Water VMT inputs without pretending a DuDv texture is a
/// tangent-space normal map.
public enum SourceWaterShaderContract {
    /// Shader-declared Source SDK Water runtime targets. These are retained as
    /// typed defaults so a VMT omission is distinguishable from a fabricated
    /// renderer fallback and from an explicitly authored custom texture.
    public static let reflectionRenderTargetName = "_rt_WaterReflection"
    public static let refractionRenderTargetName = "_rt_WaterRefraction"

    public static let defaultNearPlane: Float = 1
    public static let defaultFarPlane: Float = 65_536
    public static let refractionFogBias: Float = 0.05
    public static let fresnelDepthScale: Float = 20

    /// Reconstructs the projected Z passed by Source's Water vertex shader for
    /// the right-handed perspective used by the Metal world renderer.
    public static func projectedDepth(
        forwardDistance: Float,
        near: Float = defaultNearPlane,
        far: Float = defaultFarPlane
    ) -> Float? {
        guard forwardDistance.isFinite,
              near.isFinite,
              far.isFinite,
              near > 0,
              far > near else { return nil }
        return (forwardDistance * far - near * far) / (far - near)
    }

    /// Mirrors `CalcWaterFogAlpha`: the refraction view stores the fraction of
    /// the eye-to-fragment ray below the water plane, multiplied by projected
    /// depth and the inverse authored Water fog range.
    public static func refractionDepthAlpha(
        waterZ: Float,
        eyeZ: Float,
        worldZ: Float,
        projectedDepth: Float,
        fogStart: Float,
        fogEnd: Float
    ) -> Float? {
        guard waterZ.isFinite,
              eyeZ.isFinite,
              worldZ.isFinite,
              projectedDepth.isFinite,
              fogStart.isFinite,
              fogEnd.isFinite,
              fogEnd > fogStart else { return nil }
        let depthFromEye = eyeZ - worldZ
        guard abs(depthFromEye) > Float.ulpOfOne else { return nil }
        let fractionBelowWater = saturate((waterZ - worldZ) / depthFromEye)
        return saturate(
            fractionBelowWater * projectedDepth / (fogEnd - fogStart)
        )
    }

    /// Above water, Source uses the refraction target's encoded alpha both to
    /// fade toward `$fogcolor` and to keep near-shore refraction clear.
    public static func aboveWaterFogFactor(depthAlpha: Float) -> Float? {
        guard depthAlpha.isFinite else { return nil }
        return saturate(depthAlpha - refractionFogBias)
    }

    /// Source additionally gates the reflection Fresnel term over the first
    /// 0.05 of encoded water depth.
    public static func aboveWaterFresnelDepthFactor(
        depthAlpha: Float
    ) -> Float? {
        guard depthAlpha.isFinite else { return nil }
        return saturate(
            (depthAlpha - refractionFogBias) * fresnelDepthScale
        )
    }

    /// Under water, the Water shader uses projected distance and the authored
    /// `$fogstart` / `$fogend` pair directly because the out-of-water
    /// refraction view does not carry valid depth alpha.
    public static func underwaterFogFactor(
        projectedDepth: Float,
        fogStart: Float,
        fogEnd: Float
    ) -> Float? {
        guard projectedDepth.isFinite,
              fogStart.isFinite,
              fogEnd.isFinite,
              fogEnd > fogStart else { return nil }
        return saturate(
            (projectedDepth - fogStart) / (fogEnd - fogStart)
        )
    }

    private static func saturate(_ value: Float) -> Float {
        Swift.min(1, Swift.max(0, value))
    }
}

public enum SourceWaterDuDvDecodeError: Error, Sendable, Equatable {
    case invalidDimensions(width: Int, height: Int)
    case invalidEncodedByteCount(expected: Int, actual: Int)
}

/// Water-only decoder for Source's `IMAGE_FORMAT_UV88` displacement maps.
///
/// Generic VTF decoding intentionally continues to reject UV88: its two
/// biased vector components are not a colour image and must not be presented
/// as a tangent-space normal. The Metal Water shader consumes only R/G from
/// this RGBA8 transport image and reconstructs the signed DuDv offset there.
public enum SourceWaterDuDvTextureDecoder {
    public static func decodeUV88(
        data: Data,
        width: Int,
        height: Int,
        allocationLimits: SourceVTFAllocationLimits = .default
    ) throws -> SourceVTFDecodedImage {
        guard width > 0, height > 0 else {
            throw SourceWaterDuDvDecodeError.invalidDimensions(
                width: width,
                height: height
            )
        }
        guard data.count <= allocationLimits.maximumEncodedBytes else {
            throw SourceVTFError.allocationLimitExceeded(
                context: "Water UV88 encoded bytes",
                limit: allocationLimits.maximumEncodedBytes,
                actual: data.count
            )
        }
        let pixels = width.multipliedReportingOverflow(by: height)
        guard !pixels.overflow else {
            throw SourceVTFError.arithmeticOverflow(
                "Water UV88 pixel count"
            )
        }
        guard pixels.partialValue <= allocationLimits.maximumPixelCount else {
            throw SourceVTFError.allocationLimitExceeded(
                context: "Water UV88 pixel count",
                limit: allocationLimits.maximumPixelCount,
                actual: pixels.partialValue
            )
        }
        let encodedBytes = pixels.partialValue.multipliedReportingOverflow(by: 2)
        let decodedBytes = pixels.partialValue.multipliedReportingOverflow(by: 4)
        guard !encodedBytes.overflow, !decodedBytes.overflow else {
            throw SourceVTFError.arithmeticOverflow(
                "Water UV88 byte count"
            )
        }
        guard data.count == encodedBytes.partialValue else {
            throw SourceWaterDuDvDecodeError.invalidEncodedByteCount(
                expected: encodedBytes.partialValue,
                actual: data.count
            )
        }
        guard decodedBytes.partialValue <=
                allocationLimits.maximumDecodedBytes else {
            throw SourceVTFError.allocationLimitExceeded(
                context: "Water UV88 decoded RGBA8 bytes",
                limit: allocationLimits.maximumDecodedBytes,
                actual: decodedBytes.partialValue
            )
        }

        var rgba = Data(count: decodedBytes.partialValue)
        rgba.withUnsafeMutableBytes { rawOutput in
            let output = rawOutput.bindMemory(to: UInt8.self)
            data.withUnsafeBytes { rawInput in
                let input = rawInput.bindMemory(to: UInt8.self)
                for pixel in 0..<pixels.partialValue {
                    output[pixel * 4] = input[pixel * 2]
                    output[pixel * 4 + 1] = input[pixel * 2 + 1]
                    // B/A are transport lanes only. DuDv never enters the
                    // tangent-normal path, so no synthetic Z is implied.
                    output[pixel * 4 + 2] = 0
                    output[pixel * 4 + 3] = 255
                }
            }
        }
        return SourceVTFDecodedImage(
            width: width,
            height: height,
            rgbaBytes: rgba
        )
    }
}
