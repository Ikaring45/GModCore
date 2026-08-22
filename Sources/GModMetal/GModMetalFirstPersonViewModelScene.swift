import Foundation
import GModEngine

/// GPU-ready first-person Studio viewmodel selected by the canonical CLIENT
/// Player/Weapon projection. Geometry is validated by the same strict Studio
/// boundary as dynamic Source entities, but it deliberately has no world
/// transform: authored `c_*.mdl` coordinates are consumed in camera space.
public struct GModMetalFirstPersonViewModelScene: Sendable, Equatable {
    public let generation: GModMetalDynamicEntitySceneGeneration
    public let revision: UInt64
    public let playerIdentity: SourceCanonicalEntityIdentity
    public let weaponIdentity: SourceCanonicalEntityIdentity
    public let weaponClassName: String
    public let sourceWeaponRevision: UInt64
    public let normalizedViewModelPath: String
    /// Raw Source `ViewModelFOV`: a horizontal angle for the 4:3 base view.
    public let sourceFieldOfViewDegrees: Float
    /// Canonical Source Player weapon-colour vector. It is evaluated only for
    /// draw ranges carrying the exact supported material-proxy binding.
    public let weaponColor: SourceVector3
    public let resource: GModMetalDynamicEntityResource
    public let retainedGeometryByteCount: Int
    public let retainedMetadataUTF8ByteCount: Int

    public init(
        generation: GModMetalDynamicEntitySceneGeneration,
        revision: UInt64,
        playerIdentity: SourceCanonicalEntityIdentity,
        weaponIdentity: SourceCanonicalEntityIdentity,
        weaponClassName: String,
        sourceWeaponRevision: UInt64,
        normalizedViewModelPath: String,
        sourceFieldOfViewDegrees: Float,
        weaponColor: SourceVector3,
        resource sourceResource: GModMetalDynamicEntityResourceInput,
        policy: GModMetalDynamicEntityScenePolicy = .initialIpadPropScene
    ) throws {
        guard revision > 0 else {
            throw GModMetalFirstPersonViewModelSceneError.invalidRevision(
                revision
            )
        }
        guard !weaponClassName.isEmpty,
              !weaponClassName.utf8.contains(0) else {
            throw GModMetalFirstPersonViewModelSceneError.invalidWeaponClass(
                weaponClassName
            )
        }
        guard GModMetalSourceFOVContract.verticalRadians(
            baseHorizontalDegrees: sourceFieldOfViewDegrees
        ) != nil else {
            throw GModMetalFirstPersonViewModelSceneError
                .invalidSourceFieldOfView(sourceFieldOfViewDegrees)
        }
        guard weaponColor.x.isFinite,
              weaponColor.y.isFinite,
              weaponColor.z.isFinite else {
            throw GModMetalFirstPersonViewModelSceneError
                .invalidWeaponColor(weaponColor)
        }
        guard normalizedViewModelPath ==
                sourceResource.id.normalizedModelPath else {
            throw GModMetalFirstPersonViewModelSceneError
                .viewModelResourceMismatch(
                    expected: normalizedViewModelPath,
                    received: sourceResource.id.normalizedModelPath
                )
        }

        // Reuse the established transactional resource validator/converter.
        // No synthetic entity instance or placeholder geometry is introduced.
        let validated = try GModMetalDynamicEntityScene(
            generation: generation,
            revision: revision,
            resources: [sourceResource],
            instances: [],
            policy: policy
        )
        guard let resource = validated.resources.first,
              validated.resources.count == 1 else {
            throw GModMetalFirstPersonViewModelSceneError
                .validatedResourceUnavailable
        }

        self.generation = generation
        self.revision = revision
        self.playerIdentity = playerIdentity
        self.weaponIdentity = weaponIdentity
        self.weaponClassName = weaponClassName
        self.sourceWeaponRevision = sourceWeaponRevision
        self.normalizedViewModelPath = normalizedViewModelPath
        self.sourceFieldOfViewDegrees = sourceFieldOfViewDegrees
        self.weaponColor = weaponColor
        self.resource = resource
        retainedGeometryByteCount = validated.retainedGeometryByteCount
        retainedMetadataUTF8ByteCount =
            validated.retainedMetadataUTF8ByteCount
    }
}

public enum GModMetalFirstPersonViewModelSceneError:
    Error,
    Sendable,
    Equatable,
    CustomStringConvertible
{
    case invalidRevision(UInt64)
    case invalidWeaponClass(String)
    case invalidSourceFieldOfView(Float)
    case invalidWeaponColor(SourceVector3)
    case viewModelResourceMismatch(expected: String, received: String)
    case validatedResourceUnavailable

    public var description: String {
        switch self {
        case let .invalidRevision(value):
            return "invalid first-person viewmodel revision \(value)"
        case let .invalidWeaponClass(value):
            return "invalid first-person Weapon class '\(value)'"
        case let .invalidSourceFieldOfView(value):
            return "invalid first-person Source ViewModelFOV \(value)"
        case let .invalidWeaponColor(value):
            return "invalid first-person Source weapon color \(value)"
        case let .viewModelResourceMismatch(expected, received):
            return "first-person viewmodel resource '\(received)' does not match '\(expected)'"
        case .validatedResourceUnavailable:
            return "validated first-person viewmodel resource is unavailable"
        }
    }
}

/// Test-visible invariants for the Source viewmodel pass. They make the
/// independent camera/depth lifetime and no-placeholder material policy
/// explicit without requiring a physical Metal device in core tests.
enum GModMetalFirstPersonViewModelRenderContract {
    static let clearsDepthAfterWorld = true
    static let rendersBeforeVGUI = true
    static let substitutesMissingSourceMaterials = false

    static func verticalFieldOfViewRadians(
        for scene: GModMetalFirstPersonViewModelScene
    ) -> Float? {
        GModMetalSourceFOVContract.verticalRadians(
            baseHorizontalDegrees: scene.sourceFieldOfViewDegrees
        )
    }

    /// Exact stock `player_weapon_color.lua` animation:
    /// `col + col * ((1 + sin(CurTime() * 5)) * 0.5)`.
    static func playerWeaponColorMultiplier(
        weaponColor: SourceVector3,
        sourceFixedTime: Float
    ) -> SIMD3<Float>? {
        guard weaponColor.x.isFinite,
              weaponColor.y.isFinite,
              weaponColor.z.isFinite,
              sourceFixedTime.isFinite else { return nil }
        let scale = 1.5 + 0.5 * sin(sourceFixedTime * 5)
        return SIMD3<Float>(
            weaponColor.x * scale,
            weaponColor.y * scale,
            weaponColor.z * scale
        )
    }
}
