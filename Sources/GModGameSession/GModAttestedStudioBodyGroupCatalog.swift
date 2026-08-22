import GModEngine

public enum GModAttestedStudioBodyGroupCatalogError: Error, Equatable,
    Sendable, CustomStringConvertible
{
    case duplicateIdentity(
        modelPath: String,
        mdlSHA256: String,
        studioChecksum: Int32
    )

    public var description: String {
        switch self {
        case let .duplicateIdentity(modelPath, mdlSHA256, studioChecksum):
            return "duplicate attested Studio body-group identity " +
                "\(modelPath) \(mdlSHA256) checksum \(studioChecksum)"
        }
    }
}

public enum GModAttestedStudioBodyGroupResolutionError: Error, Equatable,
    Sendable, CustomStringConvertible
{
    case propAssetInvalid(String)
    case propAssetUnavailable(String)
    case propAssetModelMismatch(requested: String, resolved: String)
    case exactMetadataMissing(
        modelPath: String,
        mdlSHA256: String,
        studioChecksum: Int32
    )
    case layout(SourceStudioBodyGroupLayoutError)
    case selection(SourceStudioBodyGroupSelectionError)

    public var description: String {
        switch self {
        case let .propAssetInvalid(modelPath):
            return "attested Studio body groups rejected invalid prop asset \(modelPath)"
        case let .propAssetUnavailable(modelPath):
            return "attested Studio body groups cannot access prop asset \(modelPath)"
        case let .propAssetModelMismatch(requested, resolved):
            return "attested prop asset \(resolved) does not match requested \(requested)"
        case let .exactMetadataMissing(modelPath, mdlSHA256, studioChecksum):
            return "no exact Studio body-group metadata for \(modelPath) " +
                "\(mdlSHA256) checksum \(studioChecksum)"
        case let .layout(error):
            return "attested Studio body-group layout failed: \(error)"
        case let .selection(error):
            return "attested Studio body-group selection failed: \(error)"
        }
    }
}

/// Immutable session catalog keyed by the complete attested MDL identity.
/// Multiple exact revisions of one logical model may coexist, but duplicate
/// entries for one path/hash/checksum triple are rejected.
public struct GModAttestedStudioBodyGroupCatalog: Sendable {
    private struct Identity: Hashable, Sendable {
        let modelPath: String
        let mdlSHA256: String
        let studioChecksum: Int32
    }

    private let metadataByIdentity:
        [Identity: SourceAttestedStudioBodyGroupMetadata]

    public init(
        metadata: [SourceAttestedStudioBodyGroupMetadata]
    ) throws {
        var indexed: [Identity: SourceAttestedStudioBodyGroupMetadata] = [:]
        for value in metadata {
            let identity = Identity(
                modelPath: value.normalizedModelPath,
                mdlSHA256: value.mdlSHA256,
                studioChecksum: value.studioChecksum
            )
            guard indexed.updateValue(value, forKey: identity) == nil else {
                throw GModAttestedStudioBodyGroupCatalogError
                    .duplicateIdentity(
                        modelPath: identity.modelPath,
                        mdlSHA256: identity.mdlSHA256,
                        studioChecksum: identity.studioChecksum
                    )
            }
        }
        metadataByIdentity = indexed
    }

    public func metadata(
        exactlyMatching asset: SourceAttestedPropPhysicsAsset
    ) -> SourceAttestedStudioBodyGroupMetadata? {
        metadataByIdentity[Identity(
            modelPath: asset.normalizedModelPath,
            mdlSHA256: asset.mdlSHA256,
            studioChecksum: asset.studioChecksum
        )]
    }

    public func bodyValue(
        for model: SourceEntityModelReference,
        resolvedPropAsset: SourceCanonicalPropPhysicsAssetResolution,
        applyingBodyGroups subModelIDs: String,
        to currentBodyValue: Int
    ) throws -> Int {
        let metadata = try resolvedMetadata(
            for: model,
            resolvedPropAsset: resolvedPropAsset
        )
        do {
            return try metadata.bodyValue(
                applyingBodyGroups: subModelIDs,
                to: currentBodyValue
            )
        } catch let error as SourceStudioBodyGroupSelectionError {
            throw GModAttestedStudioBodyGroupResolutionError.selection(error)
        }
    }

    /// Returns an exact layout only when the separately resolved prop asset
    /// matches the catalog's full path/hash/checksum identity.
    public func bodyGroupLayout(
        for model: SourceEntityModelReference,
        resolvedPropAsset: SourceCanonicalPropPhysicsAssetResolution
    ) throws -> SourceStudioBodyGroupLayout {
        let metadata = try resolvedMetadata(
            for: model,
            resolvedPropAsset: resolvedPropAsset
        )
        do {
            return try SourceStudioBodyGroupLayout(
                bodyParts: metadata.bodyParts
            )
        } catch let error as SourceStudioBodyGroupLayoutError {
            throw GModAttestedStudioBodyGroupResolutionError.layout(error)
        }
    }

    private func resolvedMetadata(
        for model: SourceEntityModelReference,
        resolvedPropAsset: SourceCanonicalPropPhysicsAssetResolution
    ) throws -> SourceAttestedStudioBodyGroupMetadata {
        let asset: SourceAttestedPropPhysicsAsset
        switch resolvedPropAsset {
        case let .valid(value):
            asset = value
        case .invalid:
            throw GModAttestedStudioBodyGroupResolutionError
                .propAssetInvalid(model.path)
        case .unavailable:
            throw GModAttestedStudioBodyGroupResolutionError
                .propAssetUnavailable(model.path)
        }
        guard asset.normalizedModelPath == model.path else {
            throw GModAttestedStudioBodyGroupResolutionError
                .propAssetModelMismatch(
                    requested: model.path,
                    resolved: asset.normalizedModelPath
                )
        }
        guard let metadata = metadata(exactlyMatching: asset) else {
            throw GModAttestedStudioBodyGroupResolutionError
                .exactMetadataMissing(
                    modelPath: asset.normalizedModelPath,
                    mdlSHA256: asset.mdlSHA256,
                    studioChecksum: asset.studioChecksum
                )
        }
        return metadata
    }
}

/// Checked-in body-group evidence for owned Source content. This is not a
/// model/physics allowlist: a session may consume an entry only after the
/// separate prop resolver has validated the exact MDL/PHY asset.
public enum GModOwnedAttestedStudioBodyGroupMetadata {
    public static func initialCatalog()
        throws -> GModAttestedStudioBodyGroupCatalog
    {
        try GModAttestedStudioBodyGroupCatalog(metadata: [
            button06(),
        ])
    }

    public static func button06()
        throws -> SourceAttestedStudioBodyGroupMetadata
    {
        // Bounded owned-content extraction recorded in
        // Tools/SourceOracle/VPhysicsAttestation-Button06-AllowlistMetadata.json:
        // selected model files total 21,333 bytes; exact MDL is 2,540 bytes.
        // studiohdr_t offsets 232/236 contain numbodyparts=1 and index=1736.
        // The sole 16-byte mstudiobodyparts_t at 1736 contains
        // nummodels=1 and base=1. No GMod or VPhysics execution supplied these
        // Studio header values.
        try SourceAttestedStudioBodyGroupMetadata(
            normalizedModelPath: "models/maxofs2d/button_06.mdl",
            mdlSHA256:
                "85dca39870932c39dd1bcd51afbb0fc0" +
                "9aaf8d90fadfeb222e7b49cd784e0f07",
            studioChecksum: -1_817_891_700,
            bodyParts: [
                SourceStudioBodyGroupSelectionDescriptor(
                    modelSelectionBase: 1,
                    modelCount: 1
                ),
            ],
            attestationReference:
                "user-owned-playable-manifest-sha256:" +
                "2755c232b55cfe6f466555c4e63d2c5" +
                "b1c3a4c300910aaffdee5701a7e492045;" +
                "app-4020-x86-64-build-24721267;" +
                "bounded-mdl-bytes-2540-bodypart-offset-1736"
        )
    }
}
