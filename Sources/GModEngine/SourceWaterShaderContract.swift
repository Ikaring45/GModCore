import Foundation

/// CPU reference for the depth/fog terms in Source SDK 2013's
/// `common_ps_fxc.h` and `water_ps2x_helper.h`.
///
/// The renderer mirrors these operations in Metal. Keeping the arithmetic in
/// the platform-neutral engine target gives Windows XCTest an exact contract
/// for the authored Water VMT inputs without pretending a DuDv texture is a
/// tangent-space normal map.
public enum SourceWaterShaderContract {
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
