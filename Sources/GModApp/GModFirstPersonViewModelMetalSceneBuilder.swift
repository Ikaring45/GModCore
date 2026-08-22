import Foundation
import GModEngine
import GModGameSession
import GModMetal

public struct GModFirstPersonViewModelMetalSceneBuilderPolicy:
    Sendable,
    Equatable
{
    public let metalScene: GModMetalDynamicEntityScenePolicy
    public let maximumRetainedBitmapByteCount: Int

    public init(
        metalScene: GModMetalDynamicEntityScenePolicy,
        maximumRetainedBitmapByteCount: Int
    ) {
        self.metalScene = metalScene
        self.maximumRetainedBitmapByteCount = maximumRetainedBitmapByteCount
    }

    public static let initialIpadViewModel = Self(
        metalScene: .initialIpadPropScene,
        maximumRetainedBitmapByteCount: 16 * 1_024 * 1_024
    )
}

public enum GModFirstPersonViewModelMetalSceneBuilderError:
    Error,
    Sendable,
    Equatable,
    CustomStringConvertible
{
    case invalidBitmapRetentionByteCount(Int)
    case invalidGeneration(field: String, value: UInt64)
    case missingSourceConnectionGeneration
    case staleGeneration(
        previous: GModMetalDynamicEntitySceneGeneration,
        received: GModMetalDynamicEntitySceneGeneration
    )
    case revisionNotIncreasing(previous: UInt64, received: UInt64)
    case resourceIdentityMismatch(expected: String, received: String)
    case updateInvalidated

    public var description: String {
        switch self {
        case let .invalidBitmapRetentionByteCount(value):
            return "invalid viewmodel bitmap retention cap \(value)"
        case let .invalidGeneration(field, value):
            return "invalid viewmodel scene generation \(field)=\(value)"
        case .missingSourceConnectionGeneration:
            return "viewmodel projection has no Source connection generation"
        case let .staleGeneration(previous, received):
            return "viewmodel generation \(received) precedes \(previous)"
        case let .revisionNotIncreasing(previous, received):
            return "viewmodel revision \(received) does not follow \(previous)"
        case let .resourceIdentityMismatch(expected, received):
            return "viewmodel Studio resource '\(received)' does not match '\(expected)'"
        case .updateInvalidated:
            return "viewmodel scene build was invalidated"
        }
    }
}

/// App-owned material/Metal conversion for one real Studio viewmodel. A clear
/// projection clears the prior scene; missing/failed Source materials retain
/// their diagnosed state and never become a fabricated texture.
public final class GModFirstPersonViewModelMetalSceneBuilder:
    @unchecked Sendable
{
    public typealias MaterialResolver = @Sendable (
        _ orderedVMTCandidate: String
    ) throws -> GModMetalStudioMaterialCandidateResolution

    private struct State {
        let scene: GModMetalFirstPersonViewModelScene
        let retainedBitmapByteCount: Int
    }

    private let lock = NSLock()
    private let policy: GModFirstPersonViewModelMetalSceneBuilderPolicy
    private let resolveMaterial: MaterialResolver
    private var epoch: UInt64 = 0
    private var state: State?

    public init(
        policy: GModFirstPersonViewModelMetalSceneBuilderPolicy =
            .initialIpadViewModel,
        resolveMaterial: @escaping MaterialResolver
    ) throws {
        guard policy.maximumRetainedBitmapByteCount >= 0 else {
            throw GModFirstPersonViewModelMetalSceneBuilderError
                .invalidBitmapRetentionByteCount(
                    policy.maximumRetainedBitmapByteCount
                )
        }
        self.policy = policy
        self.resolveMaterial = resolveMaterial
    }

    public convenience init(
        policy: GModFirstPersonViewModelMetalSceneBuilderPolicy =
            .initialIpadViewModel,
        textureResolver: GModMetalSurfaceSourceMaterialResolver
    ) throws {
        try self.init(policy: policy) { [textureResolver] candidate in
            try textureResolver.resolveStudioMaterialCandidate(named: candidate)
        }
    }

    public var currentScene: GModMetalFirstPersonViewModelScene? {
        lock.lock()
        defer { lock.unlock() }
        return state?.scene
    }

    public var retainedBitmapByteCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return state?.retainedBitmapByteCount ?? 0
    }

    @discardableResult
    public func build(
        from snapshot: GModFirstPersonViewModelSceneSnapshot,
        applicationGeneration: UInt64,
        laneGeneration: UInt64
    ) throws -> GModMetalFirstPersonViewModelScene? {
        guard applicationGeneration > 0 else {
            throw GModFirstPersonViewModelMetalSceneBuilderError
                .invalidGeneration(
                    field: "application",
                    value: applicationGeneration
                )
        }
        guard laneGeneration > 0 else {
            throw GModFirstPersonViewModelMetalSceneBuilderError
                .invalidGeneration(field: "lane", value: laneGeneration)
        }

        lock.lock()
        let capturedEpoch = epoch
        let previous = state
        lock.unlock()

        guard let cursor = snapshot.sourceProjectionCursor else {
            guard snapshot.projection == nil else {
                throw GModFirstPersonViewModelMetalSceneBuilderError
                    .missingSourceConnectionGeneration
            }
            return try publish(candidate: nil, capturedEpoch: capturedEpoch)
        }
        let generation = GModMetalDynamicEntitySceneGeneration(
            application: applicationGeneration,
            lane: laneGeneration,
            sourceConnection: cursor.connectionGeneration
        )
        if let previous,
           Self.precedes(generation, previous.scene.generation) {
            throw GModFirstPersonViewModelMetalSceneBuilderError
                .staleGeneration(
                    previous: previous.scene.generation,
                    received: generation
                )
        }
        if let previous,
           generation == previous.scene.generation,
           snapshot.revision <= previous.scene.revision {
            if snapshot.revision == previous.scene.revision,
               let projection = snapshot.projection,
               Self.matches(
                   scene: previous.scene,
                   projection: projection
               ) {
                return previous.scene
            }
            throw GModFirstPersonViewModelMetalSceneBuilderError
                .revisionNotIncreasing(
                    previous: previous.scene.revision,
                    received: snapshot.revision
                )
        }

        guard let projection = snapshot.projection else {
            return try publish(candidate: nil, capturedEpoch: capturedEpoch)
        }
        let expectedViewModelPath = projection.viewModel.path
            .replacingOccurrences(of: "\\", with: "/")
            .lowercased()
        guard projection.resource.id.normalizedModelPath ==
                expectedViewModelPath else {
            throw GModFirstPersonViewModelMetalSceneBuilderError
                .resourceIdentityMismatch(
                    expected: expectedViewModelPath,
                    received: projection.resource.id.normalizedModelPath
                )
        }

        var retentionBudget = GModMetalWorldBitmapRetentionBudget(
            maximumByteCount: policy.maximumRetainedBitmapByteCount
        )
        let resource = Self.resourceInput(
            projection.resource,
            retentionBudget: &retentionBudget,
            resolveMaterial: resolveMaterial
        )
        let candidate = State(
            scene: try GModMetalFirstPersonViewModelScene(
                generation: generation,
                revision: snapshot.revision,
                playerIdentity: projection.playerIdentity,
                weaponIdentity: projection.weaponIdentity,
                weaponClassName: projection.weaponClassName,
                sourceWeaponRevision: projection.sourceWeaponRevision,
                normalizedViewModelPath:
                    projection.resource.id.normalizedModelPath,
                sourceFieldOfViewDegrees:
                    projection.viewModelFieldOfViewDegrees,
                resource: resource,
                policy: policy.metalScene
            ),
            retainedBitmapByteCount: retentionBudget.retainedByteCount
        )
        return try publish(
            candidate: candidate,
            capturedEpoch: capturedEpoch
        )
    }

    public func reset() {
        lock.lock()
        state = nil
        epoch &+= 1
        lock.unlock()
    }
}

private extension GModFirstPersonViewModelMetalSceneBuilder {
    private func publish(
        candidate: State?,
        capturedEpoch: UInt64
    ) throws -> GModMetalFirstPersonViewModelScene? {
        lock.lock()
        defer { lock.unlock() }
        guard epoch == capturedEpoch else {
            throw GModFirstPersonViewModelMetalSceneBuilderError
                .updateInvalidated
        }
        state = candidate
        epoch &+= 1
        return candidate?.scene
    }

    static func precedes(
        _ lhs: GModMetalDynamicEntitySceneGeneration,
        _ rhs: GModMetalDynamicEntitySceneGeneration
    ) -> Bool {
        if lhs.application != rhs.application {
            return lhs.application < rhs.application
        }
        if lhs.lane != rhs.lane { return lhs.lane < rhs.lane }
        return lhs.sourceConnection < rhs.sourceConnection
    }

    static func matches(
        scene: GModMetalFirstPersonViewModelScene,
        projection: GModFirstPersonViewModelProjection
    ) -> Bool {
        scene.playerIdentity == projection.playerIdentity &&
            scene.weaponIdentity == projection.weaponIdentity &&
            scene.weaponClassName == projection.weaponClassName &&
            scene.normalizedViewModelPath ==
                projection.resource.id.normalizedModelPath &&
            scene.sourceFieldOfViewDegrees ==
                projection.viewModelFieldOfViewDegrees &&
            scene.resource.id.normalizedModelPath ==
                projection.resource.id.normalizedModelPath
    }

    static func resourceInput(
        _ source: GModStudioRenderableModelResource,
        retentionBudget: inout GModMetalWorldBitmapRetentionBudget,
        resolveMaterial: MaterialResolver
    ) -> GModMetalDynamicEntityResourceInput {
        let id = GModMetalDynamicEntityResourceID(
            normalizedModelPath: source.id.normalizedModelPath,
            checksum: source.id.checksum,
            bodyValue: source.id.bodyValue,
            skinFamilyIndex: source.id.skinFamilyIndex
        )
        let vertices = source.model.vertices.map {
            GModMetalDynamicEntitySourceVertex(
                position: $0.position,
                normal: $0.normal,
                textureCoordinate: SIMD2<Float>(
                    $0.textureCoordinate.u,
                    $0.textureCoordinate.v
                )
            )
        }
        let ranges = source.model.drawRanges.map { range in
            GModMetalDynamicEntityDrawRange(
                bodyPartIndex: range.bodyPartIndex,
                submodelIndex: range.submodelIndex,
                meshIndex: range.meshIndex,
                firstIndex: range.firstIndex,
                indexCount: range.indexCount,
                material: GModMetalDynamicEntityMaterialBinding(
                    sourceMaterialIndex: range.material.sourceMaterialIndex,
                    skinFamilyIndex: range.material.skinFamilyIndex,
                    textureIndex: range.material.textureIndex,
                    textureName: range.material.textureName,
                    vmtCandidates: range.material.vmtCandidates
                ),
                materialResolution: materialResolution(
                    candidates: range.material.vmtCandidates,
                    retentionBudget: &retentionBudget,
                    resolveMaterial: resolveMaterial
                )
            )
        }
        return GModMetalDynamicEntityResourceInput(
            id: id,
            checksum: source.model.checksum,
            modelName: source.model.modelName,
            lodIndex: source.model.lodIndex,
            bodyValue: source.model.bodyValue,
            skinFamilyIndex: source.model.skinFamilyIndex,
            vertices: vertices,
            indices: source.model.indices,
            drawRanges: ranges
        )
    }

    static func materialResolution(
        candidates: [String],
        retentionBudget: inout GModMetalWorldBitmapRetentionBudget,
        resolveMaterial: MaterialResolver
    ) -> GModMetalDynamicEntityMaterialResolution {
        for candidate in candidates {
            do {
                let resolution = try resolveMaterial(candidate)
                guard case let .resolved(bitmap) = resolution else {
                    switch resolution {
                    case .materialMissing:
                        continue
                    case .materialWithoutBaseTexture:
                        return .materialWithoutBaseTexture(candidate: candidate)
                    case .baseTextureMissing:
                        return .baseTextureMissing(candidate: candidate)
                    case .resolved:
                        preconditionFailure("handled above")
                    }
                }
                guard bitmap.alphaRepresentation == .straight else {
                    return .decodeFailed(
                        candidate: candidate,
                        detail: "material resolver returned non-straight alpha"
                    )
                }
                let required = bitmap.totalByteCount
                guard retentionBudget.retain(bitmap) else {
                    return .retentionCapacityExceeded(
                        candidate: candidate,
                        requiredByteCount: required,
                        retainedByteCount: retentionBudget.retainedByteCount,
                        maximumByteCount: retentionBudget.maximumByteCount
                    )
                }
                return .resolved(candidate: candidate, bitmap: bitmap)
            } catch {
                return .decodeFailed(
                    candidate: candidate,
                    detail: boundedDescription(error)
                )
            }
        }
        return .sourceMissing
    }

    static func boundedDescription(_ error: Error) -> String {
        let source = String(describing: error)
        let maximum = 4_096
        var output = ""
        var bytes = 0
        for scalar in source.unicodeScalars {
            let text = String(scalar)
            guard bytes <= maximum - text.utf8.count else { break }
            output.unicodeScalars.append(scalar)
            bytes += text.utf8.count
        }
        return output.isEmpty ? "unknown material decode failure" : output
    }
}
