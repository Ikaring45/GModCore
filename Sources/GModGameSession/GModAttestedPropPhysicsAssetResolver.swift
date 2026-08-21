import Foundation
import GModEngine
import GModGameAssets

public enum GModAttestedPropPhysicsAssetCatalogError: Error, Equatable,
    Sendable, CustomStringConvertible
{
    case duplicateModelPath(String)

    public var description: String {
        switch self {
        case let .duplicateModelPath(path):
            return "multiple attested prop assets claim model path '\(path)'"
        }
    }
}

public enum GModAttestedPropPhysicsAssetInvalidReason: Error, Equatable,
    Sendable, CustomStringConvertible
{
    case invalidModelPath(String)
    case notAttested(String)
    case missingOpaquePHY(String)
    case observedModelPath(expected: String, actual: String)
    case mdlSHA256(expected: String, actual: String)
    case phySHA256(expected: String, actual: String)
    case studioChecksum(expected: Int32, actual: Int32)

    public var description: String {
        switch self {
        case let .invalidModelPath(path):
            return "prop model path is invalid: \(path)"
        case let .notAttested(path):
            return "prop model is not independently attested: \(path)"
        case let .missingOpaquePHY(path):
            return "validated Studio asset has no PHY companion: \(path)"
        case let .observedModelPath(expected, actual):
            return "loaded model path '\(actual)' does not match attested path '\(expected)'"
        case let .mdlSHA256(expected, actual):
            return "MDL SHA-256 \(actual) does not match attested \(expected)"
        case let .phySHA256(expected, actual):
            return "PHY SHA-256 \(actual) does not match attested \(expected)"
        case let .studioChecksum(expected, actual):
            return "Studio checksum \(actual) does not match attested \(expected)"
        }
    }
}

/// Exact result of resolving one Source model against immutable, independently
/// attested physics data.
///
/// `invalid` is stable content evidence. `unavailable` preserves host I/O and
/// allocation failures instead of turning them into a fabricated negative
/// Source verdict.
public enum GModAttestedPropPhysicsAssetResolution: Equatable, Sendable {
    case valid(SourceAttestedPropPhysicsAsset)
    case invalid(GModAttestedPropPhysicsAssetInvalidReason)
    case unavailable(SourceStudioModelAssetUnavailable)

    public var asset: SourceAttestedPropPhysicsAsset? {
        guard case let .valid(asset) = self else { return nil }
        return asset
    }

    public var modelValidation: SourceCanonicalModelValidation {
        switch self {
        case .valid:
            return .valid
        case .invalid:
            return .invalid
        case .unavailable:
            return .unavailable
        }
    }
}

struct GModObservedPropPhysicsAsset: Sendable {
    let normalizedModelPath: String
    let mdlData: Data
    let phyData: Data
    let studioChecksum: Int32
}

enum GModObservedPropPhysicsAssetOutcome: Sendable {
    case loaded(GModObservedPropPhysicsAsset)
    case invalid(GModAttestedPropPhysicsAssetInvalidReason)
    case unavailable(SourceStudioModelAssetUnavailable)
}

/// Session-owned exact-byte gate between Studio/filesystem loading and Source
/// `util.IsValidProp` or canonical prop creation.
///
/// The allowlist contains fully constructed attested assets, not paths or
/// format-decoder guesses. For a listed model, the resolver loads the exact
/// MDL/PHY pair, hashes both byte streams once, checks the Studio checksum, and
/// only then returns the body/collision contract. Unlisted paths do not touch
/// the filesystem. Results are cached for the immutable content-pack lifetime.
public final class GModAttestedPropPhysicsAssetResolver: @unchecked Sendable {
    private let lock = NSLock()
    private let assetsByModelPath: [String: SourceAttestedPropPhysicsAsset]
    private let loadObservedAsset: @Sendable (
        SourceEntityModelReference
    ) -> GModObservedPropPhysicsAssetOutcome
    private var cachedResolutions: [
        String: GModAttestedPropPhysicsAssetResolution
    ] = [:]

    public init(
        repository: GModStudioModelRepository,
        attestedAssets: [SourceAttestedPropPhysicsAsset]
    ) throws {
        assetsByModelPath = try Self.index(attestedAssets)
        loadObservedAsset = { model in
            switch repository.renderAssetWithOpaquePHY(for: model) {
            case let .unavailable(reason):
                return .unavailable(reason)
            case let .loaded(loaded):
                guard let phy = loaded.opaquePHYCompanion else {
                    return .invalid(.missingOpaquePHY(model.path))
                }
                return .loaded(GModObservedPropPhysicsAsset(
                    normalizedModelPath: loaded.validation.paths.mdl.lowercased(),
                    mdlData: loaded.renderPayload.mdlData,
                    phyData: phy.data,
                    studioChecksum: loaded.validation.checksum
                ))
            }
        }
    }

    init(
        attestedAssets: [SourceAttestedPropPhysicsAsset],
        loadObservedAsset: @escaping @Sendable (
            SourceEntityModelReference
        ) -> GModObservedPropPhysicsAssetOutcome
    ) throws {
        assetsByModelPath = try Self.index(attestedAssets)
        self.loadObservedAsset = loadObservedAsset
    }

    public func resolve(
        _ model: SourceEntityModelReference
    ) -> GModAttestedPropPhysicsAssetResolution {
        guard let normalizedPath = GModStudioModelPath.cacheKey(model.path) else {
            return .invalid(.invalidModelPath(model.path))
        }
        guard let attested = assetsByModelPath[normalizedPath] else {
            return .invalid(.notAttested(normalizedPath))
        }

        lock.lock()
        if let cached = cachedResolutions[normalizedPath] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let outcome = loadObservedAsset(SourceEntityModelReference(normalizedPath))
        let resolution: GModAttestedPropPhysicsAssetResolution
        switch outcome {
        case let .unavailable(reason):
            resolution = .unavailable(reason)
        case let .invalid(reason):
            resolution = .invalid(reason)
        case let .loaded(observed):
            resolution = Self.verify(observed, against: attested)
        }

        lock.lock()
        if let cached = cachedResolutions[normalizedPath] {
            lock.unlock()
            return cached
        }
        cachedResolutions[normalizedPath] = resolution
        lock.unlock()
        return resolution
    }

    public var cachedResolutionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return cachedResolutions.count
    }

    public func removeAllCachedResolutions() {
        lock.lock()
        cachedResolutions.removeAll(keepingCapacity: false)
        lock.unlock()
    }

    private static func index(
        _ assets: [SourceAttestedPropPhysicsAsset]
    ) throws -> [String: SourceAttestedPropPhysicsAsset] {
        var indexed: [String: SourceAttestedPropPhysicsAsset] = [:]
        indexed.reserveCapacity(assets.count)
        for asset in assets {
            let path = asset.normalizedModelPath
            guard indexed[path] == nil else {
                throw GModAttestedPropPhysicsAssetCatalogError
                    .duplicateModelPath(path)
            }
            indexed[path] = asset
        }
        return indexed
    }

    private static func verify(
        _ observed: GModObservedPropPhysicsAsset,
        against attested: SourceAttestedPropPhysicsAsset
    ) -> GModAttestedPropPhysicsAssetResolution {
        let expectedPath = attested.normalizedModelPath
        guard observed.normalizedModelPath == expectedPath else {
            return .invalid(.observedModelPath(
                expected: expectedPath,
                actual: observed.normalizedModelPath
            ))
        }

        let mdlDigest = digest(observed.mdlData)
        guard mdlDigest == attested.mdlSHA256 else {
            return .invalid(.mdlSHA256(
                expected: attested.mdlSHA256,
                actual: mdlDigest
            ))
        }
        let phyDigest = digest(observed.phyData)
        guard phyDigest == attested.phySHA256 else {
            return .invalid(.phySHA256(
                expected: attested.phySHA256,
                actual: phyDigest
            ))
        }
        guard observed.studioChecksum == attested.studioChecksum else {
            return .invalid(.studioChecksum(
                expected: attested.studioChecksum,
                actual: observed.studioChecksum
            ))
        }
        return .valid(attested)
    }

    private static func digest(_ data: Data) -> String {
        var hasher = GModContentSHA256()
        hasher.update(data)
        return hasher.hexadecimalDigest()
    }
}
