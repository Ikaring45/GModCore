/// A file whose bytes participate in one attested prop-physics asset.
public enum SourceAttestedPropPhysicsFile: String, Equatable, Hashable, Sendable {
    case mdl
    case phy
}

public enum SourceAttestedPropPhysicsAssetError: Error, Equatable, Sendable,
    CustomStringConvertible
{
    case nonCanonicalModelPath(String)
    case invalidSHA256(file: SourceAttestedPropPhysicsFile, value: String)
    case unattestedVPhysicsCollisionSnapshot
    case physicsContract(SourcePhysicsContractError)

    public var description: String {
        switch self {
        case let .nonCanonicalModelPath(path):
            return "prop physics model path is not canonical: \(path)"
        case let .invalidSHA256(file, value):
            return "\(file.rawValue.uppercased()) SHA-256 is not 64 lowercase hex digits: \(value)"
        case .unattestedVPhysicsCollisionSnapshot:
            return "a structurally decoded, unattested VPhysics snapshot cannot become a prop physics asset"
        case let .physicsContract(error):
            return "prop physics asset violates the backend-neutral physics contract: \(error)"
        }
    }
}

/// Canonical Source model identity used by an attested prop asset.
///
/// This is stricter than a filesystem lookup request: it is already folded to
/// lowercase, uses `/`, contains no reducible path components, and names an
/// MDL below `models/`. Consequently two spellings of one Source path cannot
/// create different attestation identities.
public struct SourceAttestedPropModelPath: Equatable, Hashable, Sendable {
    public let value: String

    public init(_ value: String) throws {
        let normalized = try? SourceLogicalPath.normalize(value, allowEmpty: false)
        let isCanonical = normalized == value
            && value == value.lowercased()
            && value.utf8.count < 260
            && !value.contains(":")
            && value.hasPrefix("models/")
            && value.hasSuffix(".mdl")
        guard isCanonical else {
            throw SourceAttestedPropPhysicsAssetError
                .nonCanonicalModelPath(value)
        }
        self.value = value
    }
}

/// Canonical textual SHA-256. The exact lowercase 64-hex representation is
/// retained; prefixes, whitespace, uppercase, and shortened digests fail.
public struct SourceAttestedPropPhysicsSHA256: Equatable, Hashable, Sendable {
    public let file: SourceAttestedPropPhysicsFile
    public let hex: String

    public init(
        _ hex: String,
        file: SourceAttestedPropPhysicsFile
    ) throws {
        let bytes = Array(hex.utf8)
        let isLowercaseHex = bytes.count == 64 && bytes.allSatisfy {
            (0x30 ... 0x39).contains($0) || (0x61 ... 0x66).contains($0)
        }
        guard isLowercaseHex else {
            throw SourceAttestedPropPhysicsAssetError.invalidSHA256(
                file: file,
                value: hex
            )
        }
        self.file = file
        self.hex = hex
    }
}

/// Explicit creation behavior recovered and attested alongside the physical
/// model. None of these values has a default at the asset boundary.
public struct SourceAttestedPropPhysicsBodyBehavior: Equatable, Hashable, Sendable {
    public let motionType: SourcePhysicsMotionType
    public let isGravityEnabled: Bool
    public let isCollisionEnabled: Bool
    public let startsAwake: Bool

    public init(
        motionType: SourcePhysicsMotionType,
        isGravityEnabled: Bool,
        isCollisionEnabled: Bool,
        startsAwake: Bool
    ) {
        self.motionType = motionType
        self.isGravityEnabled = isGravityEnabled
        self.isCollisionEnabled = isCollisionEnabled
        self.startsAwake = startsAwake
    }
}

/// Provenance identity for exactly one solid in exact MDL and PHY byte
/// streams. It is composed only of canonical, stable values and never uses a
/// process-random UUID or Swift's randomized hash output.
public struct SourceAttestedPropPhysicsAssetIdentity: Equatable, Hashable, Sendable {
    public let modelPath: SourceAttestedPropModelPath
    public let mdlSHA256: SourceAttestedPropPhysicsSHA256
    public let phySHA256: SourceAttestedPropPhysicsSHA256
    public let studioChecksum: Int32
    public let solidIndex: Int
    public let materialIndex: Int
    public let bodyBehavior: SourceAttestedPropPhysicsBodyBehavior

    fileprivate init(
        modelPath: SourceAttestedPropModelPath,
        mdlSHA256: SourceAttestedPropPhysicsSHA256,
        phySHA256: SourceAttestedPropPhysicsSHA256,
        studioChecksum: Int32,
        solidIndex: Int,
        materialIndex: Int,
        bodyBehavior: SourceAttestedPropPhysicsBodyBehavior
    ) {
        self.modelPath = modelPath
        self.mdlSHA256 = mdlSHA256
        self.phySHA256 = phySHA256
        self.studioChecksum = studioChecksum
        self.solidIndex = solidIndex
        self.materialIndex = materialIndex
        self.bodyBehavior = bodyBehavior
    }
}

/// Geometry evidence accepted by ``SourceAttestedPropPhysicsAsset``.
///
/// The structural VPhysics decoder deliberately publishes `.unattested`.
/// Keeping that state distinct here prevents decoded bytes from silently
/// crossing the independent-attestation boundary.
public enum SourceAttestedPropPhysicsShapeEvidence: Equatable, Sendable {
    case independentlyAttested(SourcePhysicsShapeSnapshot)
    case decodedVPhysics(
        shape: SourcePhysicsShapeSnapshot,
        verification: SourceVPhysicsCollisionVerification
    )
}

/// Immutable, fail-closed physical asset for one Source `prop_physics` solid.
///
/// The caller is the independent attestation boundary. It must bind exact MDL
/// and PHY byte identities to verified collision geometry, bounds, mass,
/// inertia, material selection, and body behavior. This value performs no
/// filesystem or JSON parsing and supplies no fallback values.
public struct SourceAttestedPropPhysicsAsset: Equatable, Sendable {
    public let identity: SourceAttestedPropPhysicsAssetIdentity
    public let collisionProperty: SourceCollisionProperty
    public let bodyDefinition: SourceCanonicalPropPhysicsBodyDefinition

    public var normalizedModelPath: String { identity.modelPath.value }
    public var mdlSHA256: String { identity.mdlSHA256.hex }
    public var phySHA256: String { identity.phySHA256.hex }
    public var studioChecksum: Int32 { identity.studioChecksum }

    public init(
        normalizedModelPath: String,
        mdlSHA256: String,
        phySHA256: String,
        studioChecksum: Int32,
        collisionProperty: SourceCollisionProperty,
        shapeEvidence: SourceAttestedPropPhysicsShapeEvidence,
        massProperties: SourcePhysicsMassProperties,
        solidIndex: Int,
        materialIndex: Int,
        bodyBehavior: SourceAttestedPropPhysicsBodyBehavior
    ) throws {
        let modelPath = try SourceAttestedPropModelPath(normalizedModelPath)
        let mdlDigest = try SourceAttestedPropPhysicsSHA256(
            mdlSHA256,
            file: .mdl
        )
        let phyDigest = try SourceAttestedPropPhysicsSHA256(
            phySHA256,
            file: .phy
        )

        let shape: SourcePhysicsShapeSnapshot
        switch shapeEvidence {
        case let .independentlyAttested(attestedShape):
            shape = attestedShape
        case .decodedVPhysics(_, .unattested):
            throw SourceAttestedPropPhysicsAssetError
                .unattestedVPhysicsCollisionSnapshot
        }

        let bodyDefinition: SourceCanonicalPropPhysicsBodyDefinition
        do {
            bodyDefinition = try SourceCanonicalPropPhysicsBodyDefinition(
                solidIndex: solidIndex,
                shape: shape,
                massProperties: massProperties,
                motionType: bodyBehavior.motionType,
                materialIndex: materialIndex,
                isGravityEnabled: bodyBehavior.isGravityEnabled,
                isCollisionEnabled: bodyBehavior.isCollisionEnabled,
                startsAwake: bodyBehavior.startsAwake
            )
        } catch let error as SourcePhysicsContractError {
            throw SourceAttestedPropPhysicsAssetError.physicsContract(error)
        }

        self.identity = SourceAttestedPropPhysicsAssetIdentity(
            modelPath: modelPath,
            mdlSHA256: mdlDigest,
            phySHA256: phyDigest,
            studioChecksum: studioChecksum,
            solidIndex: solidIndex,
            materialIndex: materialIndex,
            bodyBehavior: bodyBehavior
        )
        self.collisionProperty = collisionProperty
        self.bodyDefinition = bodyDefinition
    }
}
