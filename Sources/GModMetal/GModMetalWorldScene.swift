import Foundation

/// Immutable renderer input for one static Source world mesh and its camera.
///
/// Source coordinates use +X forward, +Y left, and +Z up. Metal coordinates
/// use +X right, +Y up, and -Z forward. Both representations are retained so
/// the host/renderer boundary stays explicit and auditable.
public struct GModMetalWorldScene: Sendable, Equatable {
    /// Stable identity for the geometry. Change this value whenever any mesh
    /// position, normal, or index changes so the renderer refreshes its cache.
    public let meshIdentifier: String

    public let sourcePositions: [SIMD3<Float>]
    public let sourceNormals: [SIMD3<Float>]
    public let metalPositions: [SIMD3<Float>]
    public let metalNormals: [SIMD3<Float>]
    public let indices: [UInt32]

    /// Camera values in Source coordinates.
    public let cameraEye: SIMD3<Float>
    public let cameraForward: SIMD3<Float>

    /// Camera values converted to Metal coordinates.
    public let metalCameraEye: SIMD3<Float>
    public let metalCameraForward: SIMD3<Float>

    public init(
        meshIdentifier: String,
        sourcePositions: [SIMD3<Float>],
        sourceNormals: [SIMD3<Float>],
        indices: [UInt32],
        cameraEye: SIMD3<Float>,
        cameraForward: SIMD3<Float>
    ) {
        self.meshIdentifier = meshIdentifier
        self.sourcePositions = sourcePositions
        self.sourceNormals = sourceNormals
        self.metalPositions = sourcePositions.map(Self.convertSourceVector)
        self.metalNormals = sourceNormals.map(Self.convertSourceVector)
        self.indices = indices
        self.cameraEye = cameraEye
        self.cameraForward = cameraForward
        self.metalCameraEye = Self.convertSourceVector(cameraEye)
        self.metalCameraForward = Self.convertSourceVector(cameraForward)
    }

    /// Returns a camera-updated value while sharing the immutable mesh array
    /// storage. This avoids reconverting every vertex for player motion.
    public func updatingCamera(
        eye: SIMD3<Float>,
        forward: SIMD3<Float>
    ) -> Self {
        Self(
            meshIdentifier: meshIdentifier,
            sourcePositions: sourcePositions,
            sourceNormals: sourceNormals,
            metalPositions: metalPositions,
            metalNormals: metalNormals,
            indices: indices,
            cameraEye: eye,
            cameraForward: forward
        )
    }

    /// Converts either a position or a direction because this coordinate
    /// change is a translation-free orthonormal basis change.
    public static func convertSourceVector(
        _ value: SIMD3<Float>
    ) -> SIMD3<Float> {
        SIMD3<Float>(-value.y, value.z, -value.x)
    }

    private init(
        meshIdentifier: String,
        sourcePositions: [SIMD3<Float>],
        sourceNormals: [SIMD3<Float>],
        metalPositions: [SIMD3<Float>],
        metalNormals: [SIMD3<Float>],
        indices: [UInt32],
        cameraEye: SIMD3<Float>,
        cameraForward: SIMD3<Float>
    ) {
        self.meshIdentifier = meshIdentifier
        self.sourcePositions = sourcePositions
        self.sourceNormals = sourceNormals
        self.metalPositions = metalPositions
        self.metalNormals = metalNormals
        self.indices = indices
        self.cameraEye = cameraEye
        self.cameraForward = cameraForward
        self.metalCameraEye = Self.convertSourceVector(cameraEye)
        self.metalCameraForward = Self.convertSourceVector(cameraForward)
    }
}
