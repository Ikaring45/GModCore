public enum SourceAttestedStudioBodyGroupMetadataError: Error, Equatable,
    Sendable, CustomStringConvertible
{
    case nonCanonicalModelPath(String)
    case invalidMDLSHA256(String)
    case emptyAttestationReference
    case invalidModelCount(bodyGroupID: Int, value: Int)
    case invalidModelSelectionBase(bodyGroupID: Int, value: Int32)

    public var description: String {
        switch self {
        case let .nonCanonicalModelPath(path):
            return "Studio body-group model path is not canonical: \(path)"
        case let .invalidMDLSHA256(value):
            return "Studio body-group MDL SHA-256 is not 64 lowercase hex digits: \(value)"
        case .emptyAttestationReference:
            return "Studio body-group attestation reference is empty"
        case let .invalidModelCount(bodyGroupID, value):
            return "Studio body group \(bodyGroupID) has invalid model count \(value)"
        case let .invalidModelSelectionBase(bodyGroupID, value):
            return "Studio body group \(bodyGroupID) has invalid selection base \(value)"
        }
    }
}

/// Exact immutable `mstudiobodyparts_t` selection metadata for one MDL byte
/// identity. It contains no render mesh or model binary and cannot match a
/// different spelling, digest, or Studio checksum.
public struct SourceAttestedStudioBodyGroupMetadata: Equatable, Sendable {
    public let normalizedModelPath: String
    public let mdlSHA256: String
    public let studioChecksum: Int32
    public let bodyParts: [SourceStudioBodyGroupSelectionDescriptor]
    public let attestationReference: String

    public init(
        normalizedModelPath: String,
        mdlSHA256: String,
        studioChecksum: Int32,
        bodyParts: [SourceStudioBodyGroupSelectionDescriptor],
        attestationReference: String
    ) throws {
        let normalized = try? SourceLogicalPath.normalize(
            normalizedModelPath,
            allowEmpty: false
        )
        guard normalized == normalizedModelPath,
              normalizedModelPath == normalizedModelPath.lowercased(),
              normalizedModelPath.utf8.count < 260,
              !normalizedModelPath.contains(":"),
              normalizedModelPath.hasPrefix("models/"),
              normalizedModelPath.hasSuffix(".mdl") else {
            throw SourceAttestedStudioBodyGroupMetadataError
                .nonCanonicalModelPath(normalizedModelPath)
        }
        let digestBytes = Array(mdlSHA256.utf8)
        guard digestBytes.count == 64,
              digestBytes.allSatisfy({ byte in
                  (0x30 ... 0x39).contains(byte) ||
                    (0x61 ... 0x66).contains(byte)
              }) else {
            throw SourceAttestedStudioBodyGroupMetadataError
                .invalidMDLSHA256(mdlSHA256)
        }
        guard !attestationReference.isEmpty else {
            throw SourceAttestedStudioBodyGroupMetadataError
                .emptyAttestationReference
        }
        for (bodyGroupID, bodyPart) in bodyParts.enumerated() {
            guard bodyPart.modelCount > 0 else {
                throw SourceAttestedStudioBodyGroupMetadataError
                    .invalidModelCount(
                        bodyGroupID: bodyGroupID,
                        value: bodyPart.modelCount
                    )
            }
            guard bodyPart.modelSelectionBase > 0 else {
                throw SourceAttestedStudioBodyGroupMetadataError
                    .invalidModelSelectionBase(
                        bodyGroupID: bodyGroupID,
                        value: bodyPart.modelSelectionBase
                    )
            }
        }

        self.normalizedModelPath = normalizedModelPath
        self.mdlSHA256 = mdlSHA256
        self.studioChecksum = studioChecksum
        self.bodyParts = bodyParts
        self.attestationReference = attestationReference
    }

    public func exactlyMatches(_ asset: SourceAttestedPropPhysicsAsset) -> Bool {
        asset.normalizedModelPath == normalizedModelPath &&
            asset.mdlSHA256 == mdlSHA256 &&
            asset.studioChecksum == studioChecksum
    }

    public func bodyValue(
        applyingBodyGroups subModelIDs: String,
        to currentBodyValue: Int
    ) throws -> Int {
        try SourceStudioBodyGroupSelection.bodyValue(
            applyingBodyGroups: subModelIDs,
            to: currentBodyValue,
            bodyParts: bodyParts
        )
    }
}
