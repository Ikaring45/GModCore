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

/// Independently revisioned first-person animation publication. A nil resource
/// explicitly returns the current projection to its authored bind pose; an
/// absent publication means no animation channel has been connected.
public struct GModFirstPersonViewModelAnimatedMetalPublication:
    Sendable,
    Equatable
{
    public let revision: UInt64
    public let resource: GModStudioAnimatedRenderableModelResource?

    public init(
        revision: UInt64,
        resource: GModStudioAnimatedRenderableModelResource?
    ) {
        self.revision = revision
        self.resource = resource
    }
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
    case invalidAnimationRevision(UInt64)
    case animationRevisionWentBackwards(previous: UInt64, received: UInt64)
    case resourceIdentityMismatch(expected: String, received: String)
    case animatedProjectionUnavailable
    case conflictingBindPoseResource(GModStudioRenderableModelResourceID)
    case conflictingAnimatedResource(GModMetalDynamicEntityResourceID)
    case publicationRevisionExhausted
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
        case let .invalidAnimationRevision(value):
            return "invalid viewmodel animation revision \(value)"
        case let .animationRevisionWentBackwards(previous, received):
            return "viewmodel animation revision \(received) precedes \(previous)"
        case let .resourceIdentityMismatch(expected, received):
            return "viewmodel Studio resource '\(received)' does not match '\(expected)'"
        case .animatedProjectionUnavailable:
            return "animated viewmodel resource has no current bind-pose projection"
        case let .conflictingBindPoseResource(id):
            return "viewmodel bind pose \(id.normalizedModelPath) has conflicting payloads"
        case let .conflictingAnimatedResource(id):
            return "viewmodel animated resource \(id.normalizedModelPath) has conflicting payloads"
        case .publicationRevisionExhausted:
            return "viewmodel Metal publication revision is exhausted"
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
    public typealias EntityColorProxyResolver = @Sendable (
        _ resolvedVMTCandidate: String
    ) throws -> [GMLuaSourceEntityColorProxy]

    private struct State {
        let scene: GModMetalFirstPersonViewModelScene
        let retainedBitmapByteCount: Int
        let sourceRevision: UInt64
        let animationRevision: UInt64?
        let bindPoseResource: GModStudioRenderableModelResource
        let resolvedBindPoseInput: GModMetalDynamicEntityResourceInput
        let animatedResource: GModStudioAnimatedRenderableModelResource?
    }

    private let lock = NSLock()
    private let policy: GModFirstPersonViewModelMetalSceneBuilderPolicy
    private let resolveMaterial: MaterialResolver
    private let resolveEntityColorProxies: EntityColorProxyResolver
    private var epoch: UInt64 = 0
    private var state: State?

    public init(
        policy: GModFirstPersonViewModelMetalSceneBuilderPolicy =
            .initialIpadViewModel,
        resolveMaterial: @escaping MaterialResolver,
        resolveEntityColorProxies: @escaping EntityColorProxyResolver = { _ in [] }
    ) throws {
        guard policy.maximumRetainedBitmapByteCount >= 0 else {
            throw GModFirstPersonViewModelMetalSceneBuilderError
                .invalidBitmapRetentionByteCount(
                    policy.maximumRetainedBitmapByteCount
                )
        }
        self.policy = policy
        self.resolveMaterial = resolveMaterial
        self.resolveEntityColorProxies = resolveEntityColorProxies
    }

    public convenience init(
        policy: GModFirstPersonViewModelMetalSceneBuilderPolicy =
            .initialIpadViewModel,
        textureResolver: GModMetalSurfaceSourceMaterialResolver
    ) throws {
        try self.init(
            policy: policy,
            resolveMaterial: { [textureResolver] candidate in
                try textureResolver.resolveStudioMaterialCandidate(
                    named: candidate
                )
            },
            resolveEntityColorProxies: { [textureResolver] candidate in
                try textureResolver.resolveStudioEntityColorProxies(
                    named: candidate
                )
            }
        )
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
        laneGeneration: UInt64,
        animatedPublication:
            GModFirstPersonViewModelAnimatedMetalPublication? = nil
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
        if let animatedPublication,
           animatedPublication.revision == 0 {
            throw GModFirstPersonViewModelMetalSceneBuilderError
                .invalidAnimationRevision(animatedPublication.revision)
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
        guard let projection = snapshot.projection else {
            if animatedPublication?.resource != nil {
                throw GModFirstPersonViewModelMetalSceneBuilderError
                    .animatedProjectionUnavailable
            }
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
        let animatedResource = animatedPublication?.resource
        if let animatedResource {
            try GModStudioAnimatedMetalResourceAdapter.validate(
                animated: animatedResource,
                bindPose: projection.resource
            )
        }
        let effectiveResourceID = animatedResource.map(
            GModStudioAnimatedMetalResourceAdapter.resourceID
        ) ?? Self.resourceID(projection.resource)
        let animationRevision = animatedPublication?.revision

        let candidate: State
        if let previous,
           generation == previous.scene.generation {
            guard snapshot.revision >= previous.sourceRevision else {
                throw GModFirstPersonViewModelMetalSceneBuilderError
                    .revisionNotIncreasing(
                        previous: previous.sourceRevision,
                        received: snapshot.revision
                    )
            }
            let priorAnimationRevision = previous.animationRevision ?? 0
            let receivedAnimationRevision = animationRevision ?? 0
            guard receivedAnimationRevision >= priorAnimationRevision else {
                throw GModFirstPersonViewModelMetalSceneBuilderError
                    .animationRevisionWentBackwards(
                        previous: priorAnimationRevision,
                        received: receivedAnimationRevision
                    )
            }
            if previous.bindPoseResource.id == projection.resource.id,
               previous.bindPoseResource != projection.resource {
                throw GModFirstPersonViewModelMetalSceneBuilderError
                    .conflictingBindPoseResource(projection.resource.id)
            }
            if let animatedResource,
               let priorAnimated = previous.animatedResource,
               GModStudioAnimatedMetalResourceAdapter.resourceID(
                   priorAnimated
               ) == effectiveResourceID,
               priorAnimated != animatedResource {
                throw GModFirstPersonViewModelMetalSceneBuilderError
                    .conflictingAnimatedResource(effectiveResourceID)
            }

            if Self.matches(
                scene: previous.scene,
                projection: projection,
                resourceID: effectiveResourceID
            ) {
                candidate = State(
                    scene: previous.scene,
                    retainedBitmapByteCount:
                        previous.retainedBitmapByteCount,
                    sourceRevision: snapshot.revision,
                    animationRevision: animationRevision,
                    bindPoseResource: projection.resource,
                    resolvedBindPoseInput:
                        previous.resolvedBindPoseInput,
                    animatedResource: animatedResource
                )
            } else {
                guard snapshot.revision > previous.sourceRevision ||
                        receivedAnimationRevision > priorAnimationRevision else {
                    if effectiveResourceID != previous.scene.resource.id {
                        throw GModFirstPersonViewModelMetalSceneBuilderError
                            .animationRevisionWentBackwards(
                                previous: priorAnimationRevision,
                                received: receivedAnimationRevision
                            )
                    }
                    throw GModFirstPersonViewModelMetalSceneBuilderError
                        .revisionNotIncreasing(
                            previous: previous.sourceRevision,
                            received: snapshot.revision
                        )
                }
                candidate = try makeState(
                    generation: generation,
                    publicationRevision: try Self.nextPublicationRevision(
                        after: previous.scene.revision
                    ),
                    sourceRevision: snapshot.revision,
                    animationRevision: animationRevision,
                    projection: projection,
                    animatedResource: animatedResource,
                    reusableState: previous
                )
            }
        } else {
            candidate = try makeState(
                generation: generation,
                publicationRevision: snapshot.revision,
                sourceRevision: snapshot.revision,
                animationRevision: animationRevision,
                projection: projection,
                animatedResource: animatedResource,
                reusableState: nil
            )
        }
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
    private func makeState(
        generation: GModMetalDynamicEntitySceneGeneration,
        publicationRevision: UInt64,
        sourceRevision: UInt64,
        animationRevision: UInt64?,
        projection: GModFirstPersonViewModelProjection,
        animatedResource: GModStudioAnimatedRenderableModelResource?,
        reusableState: State?
    ) throws -> State {
        let resolvedBindPoseInput: GModMetalDynamicEntityResourceInput
        let retainedBitmapByteCount: Int
        if let reusableState,
           reusableState.scene.generation == generation,
           reusableState.bindPoseResource == projection.resource {
            resolvedBindPoseInput = reusableState.resolvedBindPoseInput
            retainedBitmapByteCount = reusableState.retainedBitmapByteCount
        } else {
            var retentionBudget = GModMetalWorldBitmapRetentionBudget(
                maximumByteCount: policy.maximumRetainedBitmapByteCount
            )
            resolvedBindPoseInput = Self.resourceInput(
                projection.resource,
                retentionBudget: &retentionBudget,
                resolveMaterial: resolveMaterial,
                resolveEntityColorProxies: resolveEntityColorProxies
            )
            retainedBitmapByteCount = retentionBudget.retainedByteCount
        }
        let resourceInput: GModMetalDynamicEntityResourceInput
        if let animatedResource {
            resourceInput = try GModStudioAnimatedMetalResourceAdapter
                .resourceInput(
                    animated: animatedResource,
                    bindPose: projection.resource,
                    resolvedBindPose: resolvedBindPoseInput
                )
        } else {
            resourceInput = resolvedBindPoseInput
        }
        return State(
            scene: try GModMetalFirstPersonViewModelScene(
                generation: generation,
                revision: publicationRevision,
                playerIdentity: projection.playerIdentity,
                weaponIdentity: projection.weaponIdentity,
                weaponClassName: projection.weaponClassName,
                sourceWeaponRevision: projection.sourceWeaponRevision,
                normalizedViewModelPath:
                    projection.resource.id.normalizedModelPath,
                sourceFieldOfViewDegrees:
                    projection.viewModelFieldOfViewDegrees,
                weaponColor: projection.weaponColor,
                resource: resourceInput,
                policy: policy.metalScene
            ),
            retainedBitmapByteCount: retainedBitmapByteCount,
            sourceRevision: sourceRevision,
            animationRevision: animationRevision,
            bindPoseResource: projection.resource,
            resolvedBindPoseInput: resolvedBindPoseInput,
            animatedResource: animatedResource
        )
    }

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

    static func nextPublicationRevision(after previous: UInt64) throws -> UInt64 {
        guard previous != UInt64.max else {
            throw GModFirstPersonViewModelMetalSceneBuilderError
                .publicationRevisionExhausted
        }
        return previous + 1
    }

    static func resourceID(
        _ source: GModStudioRenderableModelResource
    ) -> GModMetalDynamicEntityResourceID {
        GModMetalDynamicEntityResourceID(
            normalizedModelPath: source.id.normalizedModelPath,
            checksum: source.id.checksum,
            lodIndex: source.id.lodIndex,
            bodyValue: source.id.bodyValue,
            skinFamilyIndex: source.id.skinFamilyIndex
        )
    }

    static func matches(
        scene: GModMetalFirstPersonViewModelScene,
        projection: GModFirstPersonViewModelProjection,
        resourceID: GModMetalDynamicEntityResourceID
    ) -> Bool {
        scene.playerIdentity == projection.playerIdentity &&
            scene.weaponIdentity == projection.weaponIdentity &&
            scene.weaponClassName == projection.weaponClassName &&
            scene.sourceWeaponRevision == projection.sourceWeaponRevision &&
            scene.normalizedViewModelPath ==
                projection.resource.id.normalizedModelPath &&
            scene.sourceFieldOfViewDegrees ==
                projection.viewModelFieldOfViewDegrees &&
            scene.weaponColor == projection.weaponColor &&
            scene.resource.id == resourceID
    }

    static func resourceInput(
        _ source: GModStudioRenderableModelResource,
        retentionBudget: inout GModMetalWorldBitmapRetentionBudget,
        resolveMaterial: MaterialResolver,
        resolveEntityColorProxies: EntityColorProxyResolver
    ) -> GModMetalDynamicEntityResourceInput {
        let id = resourceID(source)
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
            let resolved = materialResolution(
                candidates: range.material.vmtCandidates,
                retentionBudget: &retentionBudget,
                resolveMaterial: resolveMaterial,
                resolveEntityColorProxies: resolveEntityColorProxies
            )
            return GModMetalDynamicEntityDrawRange(
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
                materialResolution: resolved.resolution,
                usesPlayerWeaponColor: resolved.usesPlayerWeaponColor
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
        resolveMaterial: MaterialResolver,
        resolveEntityColorProxies: EntityColorProxyResolver
    ) -> (
        resolution: GModMetalDynamicEntityMaterialResolution,
        usesPlayerWeaponColor: Bool
    ) {
        for candidate in candidates {
            do {
                let resolution = try resolveMaterial(candidate)
                guard case let .resolved(bitmap) = resolution else {
                    switch resolution {
                    case .materialMissing:
                        continue
                    case .materialWithoutBaseTexture:
                        return (
                            .materialWithoutBaseTexture(candidate: candidate),
                            false
                        )
                    case .baseTextureMissing:
                        return (.baseTextureMissing(candidate: candidate), false)
                    case .resolved:
                        preconditionFailure("handled above")
                    }
                }
                guard bitmap.alphaRepresentation == .straight else {
                    return (
                        .decodeFailed(
                            candidate: candidate,
                            detail: "material resolver returned non-straight alpha"
                        ),
                        false
                    )
                }
                let usesPlayerWeaponColor = try resolveEntityColorProxies(
                    candidate
                ).contains {
                    $0.kind == .playerWeaponColor &&
                        $0.resultVariable.caseInsensitiveCompare("$color2") ==
                            .orderedSame
                }
                let required = bitmap.totalByteCount
                guard retentionBudget.retain(bitmap) else {
                    return (
                        .retentionCapacityExceeded(
                            candidate: candidate,
                            requiredByteCount: required,
                            retainedByteCount: retentionBudget.retainedByteCount,
                            maximumByteCount: retentionBudget.maximumByteCount
                        ),
                        false
                    )
                }
                return (
                    .resolved(candidate: candidate, bitmap: bitmap),
                    usesPlayerWeaponColor
                )
            } catch {
                return (
                    .decodeFailed(
                        candidate: candidate,
                        detail: boundedDescription(error)
                    ),
                    false
                )
            }
        }
        return (.sourceMissing, false)
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
