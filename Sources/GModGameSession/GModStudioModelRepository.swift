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

    private let lock = NSLock()
    private let variant: GModStudioModelVTXVariant
    private let loadAsset: @Sendable (
        SourceStudioModelAssetPaths,
        SourceStudioModelAssetRequirement
    ) -> SourceStudioModelAssetLoadOutcome
    private var cache: [CacheKey: SourceStudioModelAssetLoadOutcome] = [:]

    public init(
        reader: any SourceStudioBoundedAssetReading,
        budget: SourceStudioModelAssetBudget =
            GModStudioModelLoadingPolicy.initialIpadProp,
        variant: GModStudioModelVTXVariant = .directX90
    ) {
        let loader = SourceStudioModelAssetLoader(reader: reader, budget: budget)
        self.variant = variant
        loadAsset = { paths, requirement in
            loader.load(paths: paths, requirement: requirement)
        }
    }

    init(
        variant: GModStudioModelVTXVariant = .directX90,
        loadAsset: @escaping @Sendable (
            SourceStudioModelAssetPaths,
            SourceStudioModelAssetRequirement
        ) -> SourceStudioModelAssetLoadOutcome
    ) {
        self.variant = variant
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
        defer { lock.unlock() }
        if let cached = cache[key] { return cached }
        let loaded = loadAsset(paths, requirement)
        cache[key] = loaded
        return loaded
    }

    private func paths(
        for model: SourceEntityModelReference,
        includePHY: Bool
    ) -> SourceStudioModelAssetPaths? {
        let normalized = model.path.replacingOccurrences(of: "\\", with: "/")
        guard !normalized.isEmpty,
              normalized == normalized.trimmingCharacters(in: .whitespacesAndNewlines),
              normalized.lowercased().hasPrefix("models/"),
              normalized.lowercased().hasSuffix(".mdl"),
              !normalized.hasPrefix("/"),
              !normalized.split(separator: "/").contains(".."),
              !normalized.utf8.contains(0) else {
            return nil
        }
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
