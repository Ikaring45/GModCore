import GModEngine

/// Immutable visibility contract for Source's miniature 3D-sky world.
///
/// Source deliberately uses two camera origins in this pass: the fixed
/// `sky_camera` origin builds the BSP visibility set, while the rendered eye is
/// `sky_camera.origin + worldEye / scale`. `GModWorldRenderMesh` bakes the
/// inverse transform into its sky vertices, so frustum tests use `worldEye`
/// against the baked bounds without changing the fixed PVS origin.
public struct GModWorldSky3DVisibility: Sendable, Equatable {
    public let sourceVisibilityOrigin: SourceVector3
    public let scale: Float
    public let bspVisibility: GModWorldVisibility

    public init(
        sourceVisibilityOrigin: SourceVector3,
        scale: Float,
        bspVisibility: GModWorldVisibility
    ) {
        precondition(scale.isFinite && scale > 0)
        self.sourceVisibilityOrigin = sourceVisibilityOrigin
        self.scale = scale
        self.bspVisibility = bspVisibility
    }

    /// Camera passed to Source's miniature-world view before mesh baking.
    public func sourceCameraEye(
        forWorldEye worldEye: SourceVector3
    ) -> SourceVector3 {
        sourceVisibilityOrigin + worldEye / scale
    }

    /// Renderer-neutral oracle for the fixed-PVS/baked-frustum split.
    func selectionMetrics(
        worldCameraEye: SourceVector3,
        cameraForward: SourceVector3,
        cameraUp: SourceVector3,
        verticalFieldOfViewRadians: Float,
        aspectRatio: Float,
        nearPlane: Float,
        farPlane: Float
    ) -> GModWorldVisibilitySelectionMetrics? {
        bspVisibility.selectionMetrics(
            sourceVisibilityEye: sourceVisibilityOrigin,
            cameraEye: worldCameraEye,
            cameraForward: cameraForward,
            cameraUp: cameraUp,
            verticalFieldOfViewRadians: verticalFieldOfViewRadians,
            aspectRatio: aspectRatio,
            nearPlane: nearPlane,
            farPlane: farPlane
        )
    }
}
