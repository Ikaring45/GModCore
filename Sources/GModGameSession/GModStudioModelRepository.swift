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

/// Fail-closed reasons a validated Studio asset could not supply the exact
/// body-part table required by GLua `Entity:SetBodyGroups`.
public enum GModStudioBodyGroupResolutionError: Error, Sendable, Equatable,
    CustomStringConvertible
{
    case assetUnavailable(SourceStudioModelAssetUnavailable)
    case unsupportedMetadata(SourceStudioMeshUnsupportedFeature)
    case meshDecode(SourceStudioModelMeshDecodeError)
    case materialDecode(SourceStudioModelMaterialDecodeError)
    case appearance(SourceStudioModelAppearanceLayoutError)
    case inconsistentChecksum(expected: Int32, actual: Int32)
    case inconsistentModelName(expected: String, actual: String)
    case layout(SourceStudioBodyGroupLayoutError)
    case selection(SourceStudioBodyGroupSelectionError)
    case unexpected(type: String)

    public var description: String {
        switch self {
        case let .assetUnavailable(reason):
            return "Studio body-group asset is unavailable: \(reason)"
        case let .unsupportedMetadata(feature):
            return "unsupported Studio body-group metadata: \(feature)"
        case let .meshDecode(error):
            return "Studio body-group mesh decode failed: \(error)"
        case let .materialDecode(error):
            return "Studio appearance material decode failed: \(error)"
        case let .appearance(error):
            return "Studio appearance metadata failed: \(error)"
        case let .inconsistentChecksum(expected, actual):
            return "Studio body-group checksum \(actual) does not match \(expected)"
        case let .inconsistentModelName(expected, actual):
            return "Studio body-group model '\(actual)' does not match '\(expected)'"
        case let .layout(error):
            return "Studio body-group layout failed: \(error)"
        case let .selection(error):
            return "Studio body-group selection failed: \(error)"
        case let .unexpected(type):
            return "Studio body-group resolution failed with unexpected \(type)"
        }
    }
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
    private let decodeRootMesh: @Sendable (
        SourceStudioImmutableRenderPayload,
        SourceStudioMeshDecodeBudget
    ) throws -> SourceStudioModelMeshSnapshot
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
        decodeRootMesh = { payload, meshBudget in
            try SourceStudioModelMeshDecoder.decodeRootLOD(
                payload,
                budget: meshBudget
            )
        }
    }

    init(
        variant: GModStudioModelVTXVariant = .directX90,
        cachePolicy: GModStudioModelRepositoryCachePolicy = .initialIpadProp,
        decodeRootMesh: @escaping @Sendable (
            SourceStudioImmutableRenderPayload,
            SourceStudioMeshDecodeBudget
        ) throws -> SourceStudioModelMeshSnapshot = { payload, meshBudget in
            try SourceStudioModelMeshDecoder.decodeRootLOD(
                payload,
                budget: meshBudget
            )
        },
        loadAsset: @escaping @Sendable (
            SourceStudioModelAssetPaths,
            SourceStudioModelAssetRequirement
        ) -> SourceStudioModelAssetLoadOutcome
    ) {
        self.variant = variant
        self.cachePolicy = cachePolicy
        self.decodeRootMesh = decodeRootMesh
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

    /// Resolves Source's packed `m_nBody` exclusively from the validated MDL,
    /// VVD, and selected VTX hierarchy. It does not infer decimal places or
    /// accept header-only/model-name evidence as body-part metadata.
    public func bodyValue(
        for model: SourceEntityModelReference,
        applyingBodyGroups subModelIDs: String,
        to currentBodyValue: Int,
        compilePolicy: GModStudioRenderableModelCompilePolicy =
            .initialIpadProp
    ) throws -> Int {
        let mesh = try validatedBodyGroupMesh(
            for: model,
            compilePolicy: compilePolicy
        )

        do {
            return try mesh.bodyValue(
                applyingBodyGroups: subModelIDs,
                to: currentBodyValue
            )
        } catch let error as SourceStudioBodyGroupSelectionError {
            throw GModStudioBodyGroupResolutionError.selection(error)
        } catch {
            throw GModStudioBodyGroupResolutionError.unexpected(
                type: String(reflecting: type(of: error))
            )
        }
    }

    /// Returns the exact ordered Studio body-part layout only after the same
    /// MDL/VVD/VTX validation used by `bodyValue`. A model path alone never
    /// supplies body-group counts or selection bases.
    public func bodyGroupLayout(
        for model: SourceEntityModelReference,
        compilePolicy: GModStudioRenderableModelCompilePolicy =
            .initialIpadProp
    ) throws -> SourceStudioBodyGroupLayout {
        let mesh = try validatedBodyGroupMesh(
            for: model,
            compilePolicy: compilePolicy
        )
        let asset = try validatedBodyGroupAsset(for: model)
        let materials: SourceStudioModelMaterialTableSnapshot
        do {
            materials = try SourceStudioModelMaterialDecoder.decode(
                asset.renderPayload,
                budget: compilePolicy.materialDecodeBudget
            )
        } catch let error as SourceStudioModelMaterialDecodeError {
            throw GModStudioBodyGroupResolutionError.materialDecode(error)
        }
        let appearance: SourceStudioModelAppearanceLayout
        do {
            appearance = try SourceStudioModelAppearanceLayout(
                mesh: mesh,
                materials: materials
            )
        } catch let error as SourceStudioModelAppearanceLayoutError {
            throw GModStudioBodyGroupResolutionError.appearance(error)
        }
        do {
            return try SourceStudioBodyGroupLayout(
                bodyParts: mesh.bodyParts.map {
                    SourceStudioBodyGroupSelectionDescriptor(
                        modelSelectionBase: $0.modelSelectionBase,
                        modelCount: $0.models.count
                    )
                },
                appearance: appearance
            )
        } catch let error as SourceStudioBodyGroupLayoutError {
            throw GModStudioBodyGroupResolutionError.layout(error)
        } catch {
            throw GModStudioBodyGroupResolutionError.unexpected(
                type: String(reflecting: type(of: error))
            )
        }
    }

    private func validatedBodyGroupMesh(
        for model: SourceEntityModelReference,
        compilePolicy: GModStudioRenderableModelCompilePolicy
    ) throws -> SourceStudioModelMeshSnapshot {
        let asset = try validatedBodyGroupAsset(for: model)

        let mesh: SourceStudioModelMeshSnapshot
        do {
            mesh = try decodeRootMesh(
                asset.renderPayload,
                compilePolicy.meshDecodeBudget
            )
        } catch let error as SourceStudioModelMeshDecodeError {
            if case let .unsupported(feature) = error {
                throw GModStudioBodyGroupResolutionError
                    .unsupportedMetadata(feature)
            }
            throw GModStudioBodyGroupResolutionError.meshDecode(error)
        } catch {
            throw GModStudioBodyGroupResolutionError.unexpected(
                type: String(reflecting: type(of: error))
            )
        }

        let expectedChecksum = asset.validation.checksum
        guard mesh.checksum == expectedChecksum else {
            throw GModStudioBodyGroupResolutionError.inconsistentChecksum(
                expected: expectedChecksum,
                actual: mesh.checksum
            )
        }
        let expectedName = asset.renderPayload.model.header.name
        guard mesh.modelName == expectedName else {
            throw GModStudioBodyGroupResolutionError.inconsistentModelName(
                expected: expectedName,
                actual: mesh.modelName
            )
        }
        return mesh
    }

    private func validatedBodyGroupAsset(
        for model: SourceEntityModelReference
    ) throws -> SourceStudioModelAsset {
        switch renderAsset(for: model) {
        case let .loaded(asset):
            return asset
        case let .unavailable(reason):
            throw GModStudioBodyGroupResolutionError.assetUnavailable(reason)
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
