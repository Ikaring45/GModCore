import Foundation
import GModEngine

/// One exact authored Studio animation lookup. The host must supply all three
/// indices; this value does not derive a sequence from an activity, a blend
/// from pose parameters, or a frame from wall-clock time.
public struct GModStudioAnimationFrameSelection:
    Sendable,
    Equatable,
    Hashable
{
    public let sequenceIndex: Int
    public let blendIndex: Int
    public let frame: Int

    public init(sequenceIndex: Int, blendIndex: Int, frame: Int) {
        self.sequenceIndex = sequenceIndex
        self.blendIndex = blendIndex
        self.frame = frame
    }
}

public enum GModStudioAnimatedRenderablePreparationStage:
    String,
    Sendable,
    Equatable
{
    case bindPoseRenderable
    case weightedMesh
    case animationModel
}

/// Fail-closed errors while preparing the exact MDL/VVD/VTX set retained by
/// the session animation cache.
public enum GModStudioAnimatedRenderablePreparationError:
    Error,
    Sendable,
    Equatable,
    CustomStringConvertible
{
    case bindPoseRenderable(GModStudioRenderableModelCompileError)
    case weightedMesh(SourceStudioModelMeshDecodeError)
    case animationStudio(SourceStudioError)
    case animationModel(SourceStudioAnimationError)
    case identity(GModStudioAnimatedRenderableModelError)
    case invalidModelPath(String)
    case modelPathMismatch(expected: String, actual: String)
    case unexpected(
        stage: GModStudioAnimatedRenderablePreparationStage,
        type: String
    )

    public var description: String {
        switch self {
        case let .bindPoseRenderable(error):
            return "animated Studio bind-pose preparation failed: \(error)"
        case let .weightedMesh(error):
            return "animated Studio weighted mesh decode failed: \(error)"
        case let .animationStudio(error):
            return "animated Studio MDL decode failed: \(error)"
        case let .animationModel(error):
            return "animated Studio sequence decode failed: \(error)"
        case let .identity(error):
            return "animated Studio prepared identity failed: \(error)"
        case let .invalidModelPath(path):
            return "invalid animated Studio preparation path '\(path)'"
        case let .modelPathMismatch(expected, actual):
            return "animated Studio asset path '\(actual)' does not match '\(expected)'"
        case let .unexpected(stage, type):
            return "animated Studio \(stage.rawValue) preparation failed with unexpected \(type)"
        }
    }
}

/// Immutable decoded inputs shared by every explicitly requested frame of one
/// model/body/skin/LOD appearance. Raw bytes remain owned by the repository;
/// this value retains only the validated Studio model, weighted mesh,
/// animation tables, and bind-pose renderable needed for CPU skinning.
public struct GModStudioPreparedAnimatedRenderableModel: Sendable {
    public let normalizedModelPath: String
    public let checksum: Int32
    public let lodIndex: Int
    public let bodyValue: Int
    public let skinFamilyIndex: Int

    let renderable: GModStudioRenderableModelSnapshot
    let weightedMesh: SourceStudioModelMeshSnapshot
    let studioModel: SourceStudioModel
    let animationModel: SourceStudioAnimationModel
    let retainedVertexCount: Int

    init(
        normalizedModelPath: String,
        renderable: GModStudioRenderableModelSnapshot,
        weightedMesh: SourceStudioModelMeshSnapshot,
        studioModel: SourceStudioModel,
        animationModel: SourceStudioAnimationModel,
        retainedVertexCount: Int
    ) {
        self.normalizedModelPath = normalizedModelPath
        checksum = renderable.checksum
        lodIndex = renderable.lodIndex
        bodyValue = renderable.bodyValue
        skinFamilyIndex = renderable.skinFamilyIndex
        self.renderable = renderable
        self.weightedMesh = weightedMesh
        self.studioModel = studioModel
        self.animationModel = animationModel
        self.retainedVertexCount = retainedVertexCount
    }

    /// Produces a fresh immutable vertex snapshot for the exact authored table
    /// entry and integer frame. No prior frame is mutated in place.
    public func snapshot(
        selection: GModStudioAnimationFrameSelection
    ) throws -> GModStudioAnimatedRenderableModelSnapshot {
        try GModStudioAnimatedRenderableModelCompiler.compile(
            renderable: renderable,
            sourceMesh: weightedMesh,
            studioModel: studioModel,
            animationModel: animationModel,
            sequenceIndex: selection.sequenceIndex,
            blendIndex: selection.blendIndex,
            frame: selection.frame
        )
    }
}

/// Production preparation boundary for one repository-owned Studio asset.
/// Every decoded component comes from the same validated MDL/VVD/VTX payload;
/// neither model paths nor header metadata are used to fabricate geometry.
public enum GModStudioAnimatedRenderableAssetLoader {
    public static func prepare(
        asset: SourceStudioModelAsset,
        normalizedModelPath: String,
        bodyValue: Int,
        skinFamilyIndex: Int,
        lodIndex: Int = 0,
        policy: GModStudioRenderableModelCompilePolicy
    ) throws -> GModStudioPreparedAnimatedRenderableModel {
        guard let cachePath = GModStudioModelPath.cacheKey(normalizedModelPath) else {
            throw GModStudioAnimatedRenderablePreparationError.invalidModelPath(
                normalizedModelPath
            )
        }
        let assetPath = asset.validation.paths.mdl
            .replacingOccurrences(of: "\\", with: "/")
            .lowercased()
        guard assetPath == cachePath else {
            throw GModStudioAnimatedRenderablePreparationError.modelPathMismatch(
                expected: cachePath,
                actual: asset.validation.paths.mdl
            )
        }
        let renderable: GModStudioRenderableModelSnapshot
        do {
            renderable = try GModStudioRenderableModelCompiler.compile(
                asset: asset,
                bodyValue: bodyValue,
                skinFamilyIndex: skinFamilyIndex,
                lodIndex: lodIndex,
                policy: policy
            )
        } catch let error as GModStudioRenderableModelCompileError {
            throw GModStudioAnimatedRenderablePreparationError
                .bindPoseRenderable(error)
        } catch {
            throw GModStudioAnimatedRenderablePreparationError.unexpected(
                stage: .bindPoseRenderable,
                type: String(reflecting: type(of: error))
            )
        }

        let weightedMesh: SourceStudioModelMeshSnapshot
        do {
            weightedMesh = try SourceStudioModelMeshDecoder.decodeLOD(
                asset.renderPayload,
                lodIndex: lodIndex,
                budget: policy.meshDecodeBudget
            )
        } catch let error as SourceStudioModelMeshDecodeError {
            throw GModStudioAnimatedRenderablePreparationError.weightedMesh(error)
        } catch {
            throw GModStudioAnimatedRenderablePreparationError.unexpected(
                stage: .weightedMesh,
                type: String(reflecting: type(of: error))
            )
        }

        let animationModel: SourceStudioAnimationModel
        do {
            animationModel = try SourceStudioAnimationDecoder.decode(
                mdlData: asset.renderPayload.mdlData,
                expectedChecksum: asset.validation.checksum
            )
        } catch let error as SourceStudioAnimationError {
            throw GModStudioAnimatedRenderablePreparationError.animationModel(error)
        } catch let error as SourceStudioError {
            throw GModStudioAnimatedRenderablePreparationError.animationStudio(error)
        } catch {
            throw GModStudioAnimatedRenderablePreparationError.unexpected(
                stage: .animationModel,
                type: String(reflecting: type(of: error))
            )
        }

        let retainedVertexCount = try checkedRetainedVertexCount(
            renderable: renderable,
            weightedMesh: weightedMesh
        )
        try validatePreparedIdentity(
            renderable: renderable,
            weightedMesh: weightedMesh,
            studioModel: asset.renderPayload.model,
            animationModel: animationModel
        )
        return GModStudioPreparedAnimatedRenderableModel(
            normalizedModelPath: cachePath,
            renderable: renderable,
            weightedMesh: weightedMesh,
            studioModel: asset.renderPayload.model,
            animationModel: animationModel,
            retainedVertexCount: retainedVertexCount
        )
    }

    private static func checkedRetainedVertexCount(
        renderable: GModStudioRenderableModelSnapshot,
        weightedMesh: SourceStudioModelMeshSnapshot
    ) throws -> Int {
        var count = renderable.vertices.count
        for bodyPart in weightedMesh.bodyParts {
            for model in bodyPart.models {
                for mesh in model.meshes {
                    for group in mesh.stripGroups {
                        let (next, overflow) = count.addingReportingOverflow(
                            group.vertices.count
                        )
                        guard !overflow else {
                            throw GModStudioAnimatedRenderablePreparationError
                                .unexpected(
                                    stage: .weightedMesh,
                                    type: "retained vertex count overflow"
                                )
                        }
                        count = next
                    }
                }
            }
        }
        return count
    }

    private static func validatePreparedIdentity(
        renderable: GModStudioRenderableModelSnapshot,
        weightedMesh: SourceStudioModelMeshSnapshot,
        studioModel: SourceStudioModel,
        animationModel: SourceStudioAnimationModel
    ) throws {
        let error: GModStudioAnimatedRenderableModelError?
        if weightedMesh.checksum != renderable.checksum {
            error = .checksumMismatch(
                input: .sourceMesh,
                expected: renderable.checksum,
                actual: weightedMesh.checksum
            )
        } else if weightedMesh.modelName != renderable.modelName {
            error = .modelNameMismatch(
                input: .sourceMesh,
                expected: renderable.modelName,
                actual: weightedMesh.modelName
            )
        } else if weightedMesh.lodIndex != renderable.lodIndex {
            error = .lodMismatch(
                expected: renderable.lodIndex,
                actual: weightedMesh.lodIndex
            )
        } else if studioModel.header.checksum != renderable.checksum {
            error = .checksumMismatch(
                input: .studioModel,
                expected: renderable.checksum,
                actual: studioModel.header.checksum
            )
        } else if studioModel.header.name != renderable.modelName {
            error = .modelNameMismatch(
                input: .studioModel,
                expected: renderable.modelName,
                actual: studioModel.header.name
            )
        } else if animationModel.header.checksum != renderable.checksum {
            error = .checksumMismatch(
                input: .animationModel,
                expected: renderable.checksum,
                actual: animationModel.header.checksum
            )
        } else if animationModel.header.name != renderable.modelName {
            error = .modelNameMismatch(
                input: .animationModel,
                expected: renderable.modelName,
                actual: animationModel.header.name
            )
        } else if studioModel.bones.count != animationModel.skeleton.bones.count {
            error = .boneCountMismatch(
                studio: studioModel.bones.count,
                animation: animationModel.skeleton.bones.count
            )
        } else {
            error = studioModel.bones.indices.first(where: { index in
                let studio = studioModel.bones[index]
                let animation = animationModel.skeleton.bones[index]
                let parent = studio.parent >= 0 ? Int(studio.parent) : nil
                return studio.name != animation.name ||
                    parent != animation.parentIndex
            }).map(GModStudioAnimatedRenderableModelError.boneIdentityMismatch)
        }
        if let error {
            throw GModStudioAnimatedRenderablePreparationError.identity(error)
        }
    }
}

public struct GModStudioAnimatedRenderableModelResourceID:
    Sendable,
    Equatable,
    Hashable,
    Comparable
{
    public let normalizedModelPath: String
    public let checksum: Int32
    public let lodIndex: Int
    public let bodyValue: Int
    public let skinFamilyIndex: Int
    public let sequenceIndex: Int
    public let blendIndex: Int
    public let animationIndex: Int
    public let frame: Int

    public init(
        normalizedModelPath: String,
        checksum: Int32,
        lodIndex: Int,
        bodyValue: Int,
        skinFamilyIndex: Int,
        sequenceIndex: Int,
        blendIndex: Int,
        animationIndex: Int,
        frame: Int
    ) {
        self.normalizedModelPath = normalizedModelPath
        self.checksum = checksum
        self.lodIndex = lodIndex
        self.bodyValue = bodyValue
        self.skinFamilyIndex = skinFamilyIndex
        self.sequenceIndex = sequenceIndex
        self.blendIndex = blendIndex
        self.animationIndex = animationIndex
        self.frame = frame
    }

    public static func < (
        lhs: GModStudioAnimatedRenderableModelResourceID,
        rhs: GModStudioAnimatedRenderableModelResourceID
    ) -> Bool {
        if lhs.normalizedModelPath != rhs.normalizedModelPath {
            return lhs.normalizedModelPath < rhs.normalizedModelPath
        }
        if lhs.checksum != rhs.checksum { return lhs.checksum < rhs.checksum }
        if lhs.lodIndex != rhs.lodIndex { return lhs.lodIndex < rhs.lodIndex }
        if lhs.bodyValue != rhs.bodyValue { return lhs.bodyValue < rhs.bodyValue }
        if lhs.skinFamilyIndex != rhs.skinFamilyIndex {
            return lhs.skinFamilyIndex < rhs.skinFamilyIndex
        }
        if lhs.sequenceIndex != rhs.sequenceIndex {
            return lhs.sequenceIndex < rhs.sequenceIndex
        }
        if lhs.blendIndex != rhs.blendIndex {
            return lhs.blendIndex < rhs.blendIndex
        }
        if lhs.animationIndex != rhs.animationIndex {
            return lhs.animationIndex < rhs.animationIndex
        }
        return lhs.frame < rhs.frame
    }
}

public struct GModStudioAnimatedRenderableModelResource: Sendable, Equatable {
    public let id: GModStudioAnimatedRenderableModelResourceID
    public let model: GModStudioAnimatedRenderableModelSnapshot
}

public struct GModStudioAnimatedRenderableModelCachePolicy: Sendable, Equatable {
    public let maximumPreparedEntryCount: Int
    /// Exact count of bind-pose plus weighted-mesh vertices retained across
    /// prepared entries. Per-entry decode allocations are separately bounded
    /// by `GModStudioRenderableModelCompilePolicy`.
    public let maximumRetainedVertexCount: Int

    public init(
        maximumPreparedEntryCount: Int,
        maximumRetainedVertexCount: Int
    ) {
        self.maximumPreparedEntryCount = maximumPreparedEntryCount
        self.maximumRetainedVertexCount = maximumRetainedVertexCount
    }

    public static let initialIpad = Self(
        maximumPreparedEntryCount: 32,
        maximumRetainedVertexCount: 1_048_576
    )
}

public enum GModStudioAnimatedRenderableModelCacheError:
    Error,
    Sendable,
    Equatable,
    CustomStringConvertible
{
    case invalidPolicy(entries: Int, vertices: Int)
    case invalidModelPath(String)
    case retainedVertexCountExceedsCache(model: String, requested: Int, cap: Int)

    public var description: String {
        switch self {
        case let .invalidPolicy(entries, vertices):
            return "invalid animated Studio cache policy entries=\(entries) vertices=\(vertices)"
        case let .invalidModelPath(path):
            return "invalid animated Studio model path '\(path)'"
        case let .retainedVertexCountExceedsCache(model, requested, cap):
            return "animated Studio preparation '\(model)' retains \(requested) vertices; cache cap is \(cap)"
        }
    }
}

public enum GModStudioAnimatedRenderableModelResolutionFailure:
    Error,
    Sendable,
    Equatable
{
    case assetUnavailable(SourceStudioModelAssetUnavailable)
    case preparation(GModStudioAnimatedRenderablePreparationError)
    case animation(GModStudioAnimatedRenderableModelError)
    case cache(GModStudioAnimatedRenderableModelCacheError)
    case unexpected(String)
}

public enum GModStudioAnimatedRenderableModelResolution: Sendable, Equatable {
    case resolved(GModStudioAnimatedRenderableModelResource)
    case failed(GModStudioAnimatedRenderableModelResolutionFailure)
}

public protocol GModStudioAnimatedRenderableModelResolving: Sendable {
    func resolve(
        model: SourceEntityModelReference,
        bodyValue: Int,
        skinFamilyIndex: Int,
        lodIndex: Int,
        selection: GModStudioAnimationFrameSelection
    ) -> GModStudioAnimatedRenderableModelResolution
}

enum GModStudioPreparedAnimatedRenderableResolution: Sendable {
    case prepared(GModStudioPreparedAnimatedRenderableModel)
    case failed(GModStudioAnimatedRenderableModelResolutionFailure)
}

/// Session-local two-stage animation cache. It caches the expensive validated
/// asset/decode/bind-pose preparation, then emits a new immutable CPU-skinned
/// resource for each exact frame request. Animated vertex arrays themselves
/// are not accumulated across frames.
public final class GModStudioAnimatedRenderableModelCache:
    GModStudioAnimatedRenderableModelResolving,
    @unchecked Sendable
{
    private struct Key: Hashable {
        let normalizedModelPath: String
        let lodIndex: Int
        let bodyValue: Int
        let skinFamilyIndex: Int
    }

    private struct Entry {
        let resolution: GModStudioPreparedAnimatedRenderableResolution
        let retainedVertexCount: Int
    }

    private let lock = NSLock()
    private let policy: GModStudioAnimatedRenderableModelCachePolicy
    private let prepare: @Sendable (
        SourceEntityModelReference,
        String,
        Int,
        Int,
        Int
    ) -> GModStudioPreparedAnimatedRenderableResolution
    private var entries: [Key: Entry] = [:]
    private var leastToMostRecent: [Key] = []
    private var retainedVertexCountStorage = 0

    public convenience init(
        repository: GModStudioModelRepository,
        compilePolicy: GModStudioRenderableModelCompilePolicy = .initialIpadProp,
        cachePolicy: GModStudioAnimatedRenderableModelCachePolicy = .initialIpad
    ) throws {
        try self.init(policy: cachePolicy) {
            model, normalizedPath, bodyValue, skinFamilyIndex, lodIndex in
            switch repository.renderAsset(for: model) {
            case let .unavailable(error):
                return .failed(.assetUnavailable(error))
            case let .loaded(asset):
                do {
                    return .prepared(
                        try GModStudioAnimatedRenderableAssetLoader.prepare(
                            asset: asset,
                            normalizedModelPath: normalizedPath,
                            bodyValue: bodyValue,
                            skinFamilyIndex: skinFamilyIndex,
                            lodIndex: lodIndex,
                            policy: compilePolicy
                        )
                    )
                } catch let error as GModStudioAnimatedRenderablePreparationError {
                    return .failed(.preparation(error))
                } catch {
                    return .failed(.unexpected(String(reflecting: type(of: error))))
                }
            }
        }
    }

    init(
        policy: GModStudioAnimatedRenderableModelCachePolicy,
        prepare: @escaping @Sendable (
            SourceEntityModelReference,
            String,
            Int,
            Int,
            Int
        ) -> GModStudioPreparedAnimatedRenderableResolution
    ) throws {
        guard policy.maximumPreparedEntryCount > 0,
              policy.maximumRetainedVertexCount > 0 else {
            throw GModStudioAnimatedRenderableModelCacheError.invalidPolicy(
                entries: policy.maximumPreparedEntryCount,
                vertices: policy.maximumRetainedVertexCount
            )
        }
        self.policy = policy
        self.prepare = prepare
    }

    public func resolve(
        model: SourceEntityModelReference,
        bodyValue: Int,
        skinFamilyIndex: Int,
        lodIndex: Int = 0,
        selection: GModStudioAnimationFrameSelection
    ) -> GModStudioAnimatedRenderableModelResolution {
        guard let normalizedPath = GModStudioModelPath.cacheKey(model.path) else {
            return .failed(.cache(.invalidModelPath(model.path)))
        }
        let key = Key(
            normalizedModelPath: normalizedPath,
            lodIndex: lodIndex,
            bodyValue: bodyValue,
            skinFamilyIndex: skinFamilyIndex
        )
        let preparation = preparedResolution(
            key: key,
            model: model,
            normalizedPath: normalizedPath,
            bodyValue: bodyValue,
            skinFamilyIndex: skinFamilyIndex,
            lodIndex: lodIndex
        )
        switch preparation {
        case let .failed(failure):
            return .failed(failure)
        case let .prepared(prepared):
            do {
                let snapshot = try prepared.snapshot(selection: selection)
                return .resolved(GModStudioAnimatedRenderableModelResource(
                    id: GModStudioAnimatedRenderableModelResourceID(
                        normalizedModelPath: normalizedPath,
                        checksum: snapshot.checksum,
                        lodIndex: snapshot.lodIndex,
                        bodyValue: snapshot.bodyValue,
                        skinFamilyIndex: snapshot.skinFamilyIndex,
                        sequenceIndex: snapshot.sequenceIndex,
                        blendIndex: snapshot.blendIndex,
                        animationIndex: snapshot.animationIndex,
                        frame: snapshot.frame
                    ),
                    model: snapshot
                ))
            } catch let error as GModStudioAnimatedRenderableModelError {
                return .failed(.animation(error))
            } catch {
                return .failed(.unexpected(String(reflecting: type(of: error))))
            }
        }
    }

    public var cachedPreparedEntryCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    public var cachedRetainedVertexCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return retainedVertexCountStorage
    }

    public func removeAll() {
        lock.lock()
        entries.removeAll(keepingCapacity: false)
        leastToMostRecent.removeAll(keepingCapacity: false)
        retainedVertexCountStorage = 0
        lock.unlock()
    }

    private func preparedResolution(
        key: Key,
        model: SourceEntityModelReference,
        normalizedPath: String,
        bodyValue: Int,
        skinFamilyIndex: Int,
        lodIndex: Int
    ) -> GModStudioPreparedAnimatedRenderableResolution {
        lock.lock()
        if let cached = entries[key] {
            touch(key)
            lock.unlock()
            return cached.resolution
        }
        lock.unlock()

        let candidate = prepare(
            model,
            normalizedPath,
            bodyValue,
            skinFamilyIndex,
            lodIndex
        )
        let retainedVertexCount: Int
        let resolution: GModStudioPreparedAnimatedRenderableResolution
        switch candidate {
        case let .prepared(prepared):
            if prepared.retainedVertexCount > policy.maximumRetainedVertexCount {
                retainedVertexCount = 0
                resolution = .failed(.cache(.retainedVertexCountExceedsCache(
                    model: model.path,
                    requested: prepared.retainedVertexCount,
                    cap: policy.maximumRetainedVertexCount
                )))
            } else {
                retainedVertexCount = prepared.retainedVertexCount
                resolution = candidate
            }
        case .failed:
            retainedVertexCount = 0
            resolution = candidate
        }

        lock.lock()
        defer { lock.unlock() }
        if let cached = entries[key] {
            touch(key)
            return cached.resolution
        }
        evictToFit(retainedVertexCount)
        entries[key] = Entry(
            resolution: resolution,
            retainedVertexCount: retainedVertexCount
        )
        leastToMostRecent.append(key)
        retainedVertexCountStorage += retainedVertexCount
        return resolution
    }

    private func touch(_ key: Key) {
        if let index = leastToMostRecent.firstIndex(of: key) {
            leastToMostRecent.remove(at: index)
        }
        leastToMostRecent.append(key)
    }

    private func evictToFit(_ vertices: Int) {
        while !leastToMostRecent.isEmpty && (
            entries.count >= policy.maximumPreparedEntryCount ||
                retainedVertexCountStorage >
                    policy.maximumRetainedVertexCount - vertices
        ) {
            let key = leastToMostRecent.removeFirst()
            guard let removed = entries.removeValue(forKey: key) else { continue }
            retainedVertexCountStorage -= removed.retainedVertexCount
        }
    }
}
