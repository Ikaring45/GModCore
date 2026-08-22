import Foundation

/// Renderer-facing BSP visibility for the 3D-sky pass.
///
/// `sourceVisibilityOrigin` remains the authored `sky_camera` origin because
/// Source builds sky world lists from that fixed point. Frustum selection uses
/// the ordinary Metal camera against sky vertices that were baked by
/// `(vertex - sky_camera.origin) * scale`.
public struct GModMetalSky3DVisibility: Sendable, Equatable {
    public let sourceVisibilityOrigin: SIMD3<Float>
    public let bspVisibility: GModMetalWorldVisibility

    public init(
        sourceVisibilityOrigin: SIMD3<Float>,
        bspVisibility: GModMetalWorldVisibility
    ) {
        self.sourceVisibilityOrigin = sourceVisibilityOrigin
        self.bspVisibility = bspVisibility
    }
}
