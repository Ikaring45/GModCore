import Foundation
import GModEngine

/// The optimized Studio mesh variant selected by the shipped Metal host.
///
/// This is deployment policy, not fallback probing. A missing `.dx90.vtx`
/// remains unavailable instead of silently selecting a different optimized
/// format whose renderer contract has not been validated.
public enum GModStudioModelVTXVariant: String, Sendable, Equatable {
    case directX90 = "dx90"
}

/// Bounded host policy for one Studio model set on iPad.
///
/// These limits are allocation guards rather than Source format claims. They
/// stay injectable so real-device measurements can tune them without changing
/// the decoder or accepting an unbounded asset.
public enum GModStudioModelLoadingPolicy {
    public static let initialIpadProp = SourceStudioModelAssetBudget(
        maximumBytesByKind: [
            .mdl: 16 * 1_024 * 1_024,
            .vvd: 32 * 1_024 * 1_024,
            .vtx: 16 * 1_024 * 1_024,
            .phy: 32 * 1_024 * 1_024,
        ],
        maximumTotalBytes: 64 * 1_024 * 1_024,
        maximumVVDVertices: 65_536,
        maximumVVDFixups: 65_536,
        maximumVTXBodyParts: 1_024,
        maximumDeclaredPHYSolids: 256
    )
}

/// Session-local raw companion retention guard. This is intentionally
/// separate from the renderer-neutral geometry cache because MDL/VVD/VTX/PHY
/// bytes and compiled vertices have different lifetimes and costs.
public struct GModStudioModelRepositoryCachePolicy: Sendable, Equatable {
    public let maximumEntryCount: Int
    public let maximumRawByteCount: Int

    public init(maximumEntryCount: Int, maximumRawByteCount: Int) {
        self.maximumEntryCount = maximumEntryCount
        self.maximumRawByteCount = maximumRawByteCount
    }

    public static let initialIpadProp = Self(
        maximumEntryCount: 64,
        maximumRawByteCount: 64 * 1_024 * 1_024
    )
}

/// Session-owned, bounded Studio asset cache.
///
/// The repository resolves one explicit companion set and retains the exact
/// loader outcome. Missing or malformed data is a stable invalid-model result;
/// I/O and host-budget failures remain unavailable and are never promoted to a
/// valid `util.IsValidModel` answer.
public final class GModStudioModelRepository: @unchecked Sendable {
    private struct CacheKey: Hashable {
        let normalizedModelPath: String
        let requirementDiscriminator: UInt8
    }

    private struct CacheEntry {
        let outcome: SourceStudioModelAssetLoadOutcome
        let rawByteCount: Int
    }

    private let lock = NSLock()
    private let variant: GModStudioModelVTXVariant
    private let cachePolicy: GModStudioModelRepositoryCachePolicy
    private let loadAsset: @Sendable (
        SourceStudioModelAssetPaths,
        SourceStudioModelAssetRequirement
    ) -> SourceStudioModelAssetLoadOutcome
    private var cache: [CacheKey: CacheEntry] = [:]
    private var leastToMostRecent: [CacheKey] = []
    private var retainedRawByteCount = 0

    public init(
        reader: any SourceStudioBoundedAssetReading,
        budget: SourceStudioModelAssetBudget =
            GModStudioModelLoadingPolicy.initialIpadProp,
        variant: GModStudioModelVTXVariant = .directX90,
        cachePolicy: GModStudioModelRepositoryCachePolicy = .initialIpadProp
    ) {
        let loader = SourceStudioModelAssetLoader(reader: reader, budget: budget)
        self.variant = variant
        self.cachePolicy = cachePolicy
        loadAsset = { paths, requirement in
            loader.load(paths: paths, requirement: requirement)
        }
    }

    init(
        variant: GModStudioModelVTXVariant = .directX90,
        cachePolicy: GModStudioModelRepositoryCachePolicy = .initialIpadProp,
        loadAsset: @escaping @Sendable (
            SourceStudioModelAssetPaths,
            SourceStudioModelAssetRequirement
        ) -> SourceStudioModelAssetLoadOutcome
    ) {
        self.variant = variant
        self.cachePolicy = cachePolicy
        self.loadAsset = loadAsset
    }

    public func renderAsset(
        for model: SourceEntityModelReference
    ) -> SourceStudioModelAssetLoadOutcome {
        outcome(for: model, requirement: .render)
    }

    /// Loads the header-matched PHY companion for a later collision decoder.
    /// This outcome alone is deliberately not a `util.IsValidProp` verdict.
    public func renderAssetWithOpaquePHY(
        for model: SourceEntityModelReference
    ) -> SourceStudioModelAssetLoadOutcome {
        outcome(for: model, requirement: .renderWithOpaquePHYCompanion)
    }

    public func validation(
        for model: SourceEntityModelReference,
        kind: SourceCanonicalEntityKind
    ) -> SourceCanonicalModelValidation {
        guard kind == .propPhysics else { return .unavailable }
        switch renderAsset(for: model) {
        case .loaded:
            return .valid
        case let .unavailable(reason):
            switch reason {
            case .missing, .malformed:
                return .invalid
            case .invalidRequest, .readFailed, .byteBudgetExceeded,
                    .totalByteBudgetExceeded:
                return .unavailable
            }
        }
    }

    private func outcome(
        for model: SourceEntityModelReference,
        requirement: SourceStudioModelAssetRequirement
    ) -> SourceStudioModelAssetLoadOutcome {
        guard cachePolicy.maximumEntryCount > 0,
              cachePolicy.maximumRawByteCount > 0 else {
            return .unavailable(.invalidRequest(
                "Studio repository cache policy must have positive caps"
            ))
        }
        guard let paths = paths(for: model, includePHY: requirement.requiresPHY) else {
            return .unavailable(.invalidRequest(
                "model path must be a relative models/*.mdl path"
            ))
        }
        let key = CacheKey(
            normalizedModelPath: paths.mdl.lowercased(),
            requirementDiscriminator: requirement.requiresPHY ? 1 : 0
        )

        lock.lock()
        if let cached = cache[key] {
            touch(key)
            lock.unlock()
            return cached.outcome
        }
        lock.unlock()

        // File reads and Studio validation are external work. They must not
        // block an unrelated cache hit or diagnostics read.
        let loaded = loadAsset(paths, requirement)
        let rawByteCount = loaded.asset?.validation.totalByteCount ?? 0

        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[key] {
            touch(key)
            return cached.outcome
        }
        guard rawByteCount <= cachePolicy.maximumRawByteCount else {
            return loaded
        }
        evictToFit(rawByteCount)
        cache[key] = CacheEntry(outcome: loaded, rawByteCount: rawByteCount)
        leastToMostRecent.append(key)
        retainedRawByteCount += rawByteCount
        return loaded
    }

    public var cachedEntryCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return cache.count
    }

    public var cachedRawByteCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return retainedRawByteCount
    }

    public func removeAllCachedAssets() {
        lock.lock()
        cache.removeAll(keepingCapacity: false)
        leastToMostRecent.removeAll(keepingCapacity: false)
        retainedRawByteCount = 0
        lock.unlock()
    }

    private func touch(_ key: CacheKey) {
        if let index = leastToMostRecent.firstIndex(of: key) {
            leastToMostRecent.remove(at: index)
        }
        leastToMostRecent.append(key)
    }

    private func evictToFit(_ rawByteCount: Int) {
        while !leastToMostRecent.isEmpty && (
            cache.count >= cachePolicy.maximumEntryCount ||
                retainedRawByteCount >
                    cachePolicy.maximumRawByteCount - rawByteCount
        ) {
            let key = leastToMostRecent.removeFirst()
            guard let removed = cache.removeValue(forKey: key) else { continue }
            retainedRawByteCount -= removed.rawByteCount
        }
    }

    private func paths(
        for model: SourceEntityModelReference,
        includePHY: Bool
    ) -> SourceStudioModelAssetPaths? {
        guard let normalized = GModStudioModelPath
            .normalizedRelativeModelPath(model.path) else { return nil }
        let stem = String(normalized.dropLast(4))
        return SourceStudioModelAssetPaths(
            mdl: normalized,
            vvd: "\(stem).vvd",
            vtx: "\(stem).\(variant.rawValue).vtx",
            phy: includePHY ? "\(stem).phy" : nil
        )
    }
}

private extension SourceStudioModelAssetRequirement {
    var requiresPHY: Bool {
        switch self {
        case .render: return false
        case .renderWithOpaquePHYCompanion: return true
        }
    }
}
