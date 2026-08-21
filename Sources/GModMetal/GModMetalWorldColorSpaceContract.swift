import Foundation

#if canImport(Metal)
import Metal
#endif

/// Explicit SDR transfer contract for the shared `.bgra8Unorm` drawable.
///
/// World/base/sky textures are sampled from sRGB Metal textures into linear
/// working values, lightmaps are already linear, and world shaders encode the
/// composed result back to display sRGB. Values outside SDR are clamped rather
/// than implicitly exposed as EDR/HDR; a future HDR target must introduce a
/// separate pixel format, tone mapper, and validation oracle.
///
/// VGUI/Surface deliberately does not use this transfer. Its `.rgba8Unorm`
/// uploads and fragment outputs preserve the existing byte-normalized color
/// semantics on the same `.bgra8Unorm` target.
public enum GModMetalWorldColorSpaceContract: Sendable {
    public static let drawablePixelFormatName = "bgra8Unorm"
    public static let preservesSurfaceByteSemantics = true

    public static func decodeDisplaySRGB(_ value: Float) -> Float {
        let display = finiteSDR(value)
        if display <= 0.04045 {
            return display / 12.92
        }
        return Float(pow(Double((display + 0.055) / 1.055), 2.4))
    }

    public static func encodeLinearSDR(_ value: Float) -> Float {
        let linear = finiteSDR(value)
        if linear <= 0.0031308 {
            return linear * 12.92
        }
        return 1.055 * Float(pow(Double(linear), 1.0 / 2.4)) - 0.055
    }

    public static func decodeDisplaySRGB(
        _ value: SIMD3<Float>
    ) -> SIMD3<Float> {
        SIMD3<Float>(
            decodeDisplaySRGB(value.x),
            decodeDisplaySRGB(value.y),
            decodeDisplaySRGB(value.z)
        )
    }

    public static func encodeLinearSDR(
        _ value: SIMD3<Float>
    ) -> SIMD3<Float> {
        SIMD3<Float>(
            encodeLinearSDR(value.x),
            encodeLinearSDR(value.y),
            encodeLinearSDR(value.z)
        )
    }

    /// Surface colors remain byte-normalized values; this is intentionally not
    /// routed through either transfer function above.
    public static func surfaceByteNormalized(_ value: UInt8) -> Float {
        Float(value) / 255
    }

    private static func finiteSDR(_ value: Float) -> Float {
        guard value.isFinite else {
            return value == .infinity ? 1 : 0
        }
        return Swift.max(0, Swift.min(1, value))
    }

    /// Kept beside the CPU oracle so constants and transfer math cannot drift
    /// independently from the runtime-compiled Metal source.
    static let metalShaderSupport =
    """
    inline float gmodDecodeDisplaySRGB(float value)
    {
        float display = isfinite(value) ? clamp(value, 0.0, 1.0) :
            (value > 0.0 ? 1.0 : 0.0);
        return display <= 0.04045
            ? display / 12.92
            : pow((display + 0.055) / 1.055, 2.4);
    }

    inline float3 gmodDecodeDisplaySRGB(float3 value)
    {
        return float3(
            gmodDecodeDisplaySRGB(value.r),
            gmodDecodeDisplaySRGB(value.g),
            gmodDecodeDisplaySRGB(value.b)
        );
    }

    inline float gmodEncodeLinearSDR(float value)
    {
        float linear = isfinite(value) ? clamp(value, 0.0, 1.0) :
            (value > 0.0 ? 1.0 : 0.0);
        return linear <= 0.0031308
            ? linear * 12.92
            : 1.055 * pow(linear, 1.0 / 2.4) - 0.055;
    }

    inline float3 gmodEncodeLinearSDR(float3 value)
    {
        return float3(
            gmodEncodeLinearSDR(value.r),
            gmodEncodeLinearSDR(value.g),
            gmodEncodeLinearSDR(value.b)
        );
    }

    inline float4 gmodWorldOutput(float3 linearRGB, float alpha)
    {
        return float4(
            gmodEncodeLinearSDR(linearRGB),
            isfinite(alpha) ? clamp(alpha, 0.0, 1.0) : 0.0
        );
    }

    """
}

#if canImport(Metal)
public extension GModMetalWorldColorSpaceContract {
    static let drawablePixelFormat: MTLPixelFormat = .bgra8Unorm
}
#endif
