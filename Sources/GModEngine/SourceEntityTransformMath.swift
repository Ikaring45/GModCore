/// Source entity local-to-world transform using the same QAngle basis as
/// `AngleVectors`. Source local +Y is left, while `AngleVectors` publishes a
/// right vector, so the second matrix column is `-right`.
public extension SourceEntityTransform {
    func transformDirectionFromLocal(
        _ local: SourceVector3
    ) -> SourceVector3 {
        let basis = angles.sourceBasis
        return basis.forward * local.x - basis.right * local.y + basis.up * local.z
    }

    func transformPointFromLocal(_ local: SourceVector3) -> SourceVector3 {
        origin + transformDirectionFromLocal(local)
    }

    /// Inverse of the orthonormal Source QAngle basis. This is not a generic
    /// matrix inversion and therefore cannot hide a scale/shear approximation.
    func inverseTransformDirectionToLocal(
        _ world: SourceVector3
    ) -> SourceVector3 {
        let basis = angles.sourceBasis
        return SourceVector3(
            sourceTransformDot(world, basis.forward),
            sourceTransformDot(world, -basis.right),
            sourceTransformDot(world, basis.up)
        )
    }

    func inverseTransformPointToLocal(_ world: SourceVector3) -> SourceVector3 {
        inverseTransformDirectionToLocal(world - origin)
    }
}

private func sourceTransformDot(
    _ lhs: SourceVector3,
    _ rhs: SourceVector3
) -> Float {
    lhs.x * rhs.x + lhs.y * rhs.y + lhs.z * rhs.z
}
