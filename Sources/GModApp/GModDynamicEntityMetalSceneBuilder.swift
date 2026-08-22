import Foundation
import GModEngine
import GModGameSession
import GModMetal

public struct GModDynamicEntityMetalSceneBuilderPolicy: Sendable, Equatable {
    public let metalScene: GModMetalDynamicEntityScenePolicy
    public let maximumRetainedBitmapByteCount: Int

    public init(
        metalScene: GModMetalDynamicEntityScenePolicy,
        maximumRetainedBitmapByteCount: Int
    ) {
        self.metalScene = metalScene
        self.maximumRetainedBitmapByteCount = maximumRetainedBitmapByteCount
    }

    public static let initialIpadPropScene = Self(
        metalScene: .initialIpadPropScene,
        maximumRetainedBitmapByteCount: 64 * 1_024 * 1_024
    )
}

/// One entity-to-pose assignment from the session animation cache. Different
/// entities sharing a bind-pose appearance may select different exact frames;
/// entities selecting the same complete animated resource still share one
/// immutable Metal allocation.
public struct GModDynamicEntityAnimatedMetalAssignment:
    Sendable,
    Equatable
{
    public let identity: SourceCanonicalEntityIdentity
    public let resource: GModStudioAnimatedRenderableModelResource

    public init(
        identity: SourceCanonicalEntityIdentity,
        resource: GModStudioAnimatedRenderableModelResource
    ) {
        self.identity = identity
        self.resource = resource
    }
}

/// Independently revisioned animation publication. Source entity projection
/// revisions need not advance when only an authored sequence/frame changes.
public struct GModDynamicEntityAnimatedMetalPublication:
    Sendable,
    Equatable
{
    public let revision: UInt64
    public let assignments: [GModDynamicEntityAnimatedMetalAssignment]

    public init(
        revision: UInt64,
        assignments: [GModDynamicEntityAnimatedMetalAssignment]
    ) {
        self.revision = revision
        self.assignments = assignments
    }
}

public enum GModDynamicEntityMetalSceneBuilderError:
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
    case duplicateAnimatedEntity(SourceCanonicalEntityIdentity)
    case animatedEntityUnavailable(SourceCanonicalEntityIdentity)
    case animatedBindPoseUnavailable(GModStudioRenderableModelResourceID)
    case conflictingBindPoseResource(GModStudioRenderableModelResourceID)
    case conflictingAnimatedResource(GModMetalDynamicEntityResourceID)
    case publicationRevisionExhausted
    case updateInvalidated

    public var description: String {
        switch self {
        case let .invalidBitmapRetentionByteCount(value):
            return "invalid dynamic prop bitmap retention cap \(value)"
        case let .invalidGeneration(field, value):
            return "invalid dynamic prop scene generation \(field)=\(value)"
        case .missingSourceConnectionGeneration:
            return "dynamic prop scene has no Source connection generation"
        case let .staleGeneration(previous, received):
            return "dynamic prop generation \(Self.describe(received)) precedes " +
                Self.describe(previous)
        case let .revisionNotIncreasing(previous, received):
            return "dynamic prop revision \(received) does not follow \(previous)"
        case let .invalidAnimationRevision(value):
            return "invalid dynamic prop animation revision \(value)"
        case let .animationRevisionWentBackwards(previous, received):
            return "dynamic prop animation revision \(received) precedes \(previous)"
        case let .duplicateAnimatedEntity(identity):
            return "duplicate animated dynamic entity EHANDLE \(identity.handle.rawValue)"
        case let .animatedEntityUnavailable(identity):
            return "animated dynamic entity EHANDLE \(identity.handle.rawValue) is absent"
        case let .animatedBindPoseUnavailable(id):
            return "animated dynamic bind pose \(id.normalizedModelPath) is absent"
        case let .conflictingBindPoseResource(id):
            return "dynamic bind pose \(id.normalizedModelPath) has conflicting payloads"
        case let .conflictingAnimatedResource(id):
            return "animated dynamic resource \(id.normalizedModelPath) has conflicting payloads"
        case .publicationRevisionExhausted:
            return "dynamic Metal publication revision is exhausted"
        case .updateInvalidated:
            return "dynamic prop scene build was invalidated"
        }
    }

    private static func describe(
        _ value: GModMetalDynamicEntitySceneGeneration
    ) -> String {
        "\(value.application)/\(value.lane)/" +
            "\(value.sourceConnection.rawValue)"
    }
}

/// Stateful App boundary between the replicated renderer-neutral Studio scene
/// and Metal-owned immutable inputs. Texture decoding happens only on an
/// appearance rebuild; transform-only updates retain the prior resources and
/// their authored mip chains through `updatingInstances`.
public final class GModDynamicEntityMetalSceneBuilder: @unchecked Sendable {
    public typealias MaterialResolver = @Sendable (
        _ orderedVMTCandidate: String
    ) throws -> GModMetalStudioMaterialCandidateResolution

    private struct State {
        let scene: GModMetalDynamicEntityScene
        let retainedBitmapByteCount: Int
        let sourceRevision: UInt64
        let animationRevision: UInt64?
        let bindPoseResources: [
            GModStudioRenderableModelResourceID: GModStudioRenderableModelResource
        ]
        let resolvedBindPoseInputs: [
            GModStudioRenderableModelResourceID:
                GModMetalDynamicEntityResourceInput
        ]
        let animatedResources: [
            GModMetalDynamicEntityResourceID:
                GModStudioAnimatedRenderableModelResource
        ]
    }

    private struct ResourcePlan {
        let bindPose: GModStudioRenderableModelResource
        let animated: GModStudioAnimatedRenderableModelResource?
    }

    private struct PlannedScene {
        let resources: [GModMetalDynamicEntityResourceID: ResourcePlan]
        let instances: [GModMetalDynamicEntityInstanceInput]
        let bindPoseResources: [
            GModStudioRenderableModelResourceID: GModStudioRenderableModelResource
        ]
        let animatedResources: [
            GModMetalDynamicEntityResourceID:
                GModStudioAnimatedRenderableModelResource
        ]
    }

    private let lock = NSLock()
    private let policy: GModDynamicEntityMetalSceneBuilderPolicy
    private let resolveMaterial: MaterialResolver
    private var epoch: UInt64 = 0
    private var state: State?

    public init(
        policy: GModDynamicEntityMetalSceneBuilderPolicy =
            .initialIpadPropScene,
        resolveMaterial: @escaping MaterialResolver
    ) throws {
        guard policy.maximumRetainedBitmapByteCount >= 0 else {
            throw GModDynamicEntityMetalSceneBuilderError
                .invalidBitmapRetentionByteCount(
                    policy.maximumRetainedBitmapByteCount
                )
        }
        self.policy = policy
        self.resolveMaterial = resolveMaterial
    }

    public convenience init(
        policy: GModDynamicEntityMetalSceneBuilderPolicy =
            .initialIpadPropScene,
        textureResolver: GModMetalSurfaceSourceMaterialResolver
    ) throws {
        try self.init(policy: policy) { [textureResolver] candidate in
            try textureResolver.resolveStudioMaterialCandidate(named: candidate)
        }
    }

    public var currentScene: GModMetalDynamicEntityScene? {
        lock.lock()
        defer { lock.unlock() }
        return state?.scene
    }

    public var retainedBitmapByteCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return state?.retainedBitmapByteCount ?? 0
    }

    /// Builds and transactionally publishes one immutable scene. A fresh empty
    /// reset snapshot has no connection cursor and needs no Metal publication;
    /// after a visible scene, that same reset reuses only the exact prior
    /// App/lane connection identity to publish removal of stale instances.
    @discardableResult
    public func build(
        from snapshot: GModDynamicEntityRenderSceneSnapshot,
        applicationGeneration: UInt64,
        laneGeneration: UInt64,
        animatedPublication:
            GModDynamicEntityAnimatedMetalPublication? = nil
    ) throws -> GModMetalDynamicEntityScene? {
        guard applicationGeneration > 0 else {
            throw GModDynamicEntityMetalSceneBuilderError.invalidGeneration(
                field: "application",
                value: applicationGeneration
            )
        }
        guard laneGeneration > 0 else {
            throw GModDynamicEntityMetalSceneBuilderError.invalidGeneration(
                field: "lane",
                value: laneGeneration
            )
        }
        if let animatedPublication,
           animatedPublication.revision == 0 {
            throw GModDynamicEntityMetalSceneBuilderError
                .invalidAnimationRevision(animatedPublication.revision)
        }

        lock.lock()
        let capturedEpoch = epoch
        let previous = state
        lock.unlock()

        guard let generation = try Self.generation(
            snapshot: snapshot,
            application: applicationGeneration,
            lane: laneGeneration,
            previous: previous?.scene.generation
        ) else {
            return nil
        }
        if let previous,
           Self.precedes(generation, previous.scene.generation) {
            throw GModDynamicEntityMetalSceneBuilderError.staleGeneration(
                previous: previous.scene.generation,
                received: generation
            )
        }

        let planned = try Self.plan(
            snapshot: snapshot,
            animatedPublication: animatedPublication
        )
        let resourceIDs = planned.resources.keys.sorted()
        let animationRevision = animatedPublication?.revision
        let candidate: State
        if let previous,
           previous.scene.generation == generation {
            guard snapshot.revision >= previous.sourceRevision else {
                throw GModDynamicEntityMetalSceneBuilderError
                    .revisionNotIncreasing(
                        previous: previous.sourceRevision,
                        received: snapshot.revision
                    )
            }
            let priorAnimationRevision = previous.animationRevision ?? 0
            let receivedAnimationRevision = animationRevision ?? 0
            guard receivedAnimationRevision >= priorAnimationRevision else {
                throw GModDynamicEntityMetalSceneBuilderError
                    .animationRevisionWentBackwards(
                        previous: priorAnimationRevision,
                        received: receivedAnimationRevision
                    )
            }
            for (id, bindPose) in planned.bindPoseResources {
                if let prior = previous.bindPoseResources[id],
                   prior != bindPose {
                    throw GModDynamicEntityMetalSceneBuilderError
                        .conflictingBindPoseResource(id)
                }
            }
            for (id, animated) in planned.animatedResources {
                if let prior = previous.animatedResources[id],
                   prior != animated {
                    throw GModDynamicEntityMetalSceneBuilderError
                        .conflictingAnimatedResource(id)
                }
            }
            let sameResources = previous.scene.resources.map(\.id) ==
                resourceIDs
            let sameInstances = Self.hasSameVisualInstances(
                previous.scene.instances,
                planned.instances
            )
            if sameResources && sameInstances {
                candidate = State(
                    scene: previous.scene,
                    retainedBitmapByteCount:
                        previous.retainedBitmapByteCount,
                    sourceRevision: snapshot.revision,
                    animationRevision: animationRevision,
                    bindPoseResources: planned.bindPoseResources,
                    resolvedBindPoseInputs:
                        previous.resolvedBindPoseInputs,
                    animatedResources: planned.animatedResources
                )
            } else {
                guard snapshot.revision > previous.sourceRevision ||
                        receivedAnimationRevision > priorAnimationRevision else {
                    if !sameResources {
                        throw GModDynamicEntityMetalSceneBuilderError
                            .animationRevisionWentBackwards(
                                previous: priorAnimationRevision,
                                received: receivedAnimationRevision
                            )
                    }
                    throw GModDynamicEntityMetalSceneBuilderError
                        .revisionNotIncreasing(
                            previous: previous.sourceRevision,
                            received: snapshot.revision
                        )
                }
                let publicationRevision = try Self.nextPublicationRevision(
                    after: previous.scene.revision
                )
                if sameResources {
                    candidate = State(
                        scene: try previous.scene.updatingInstances(
                            revision: publicationRevision,
                            instances: planned.instances
                        ),
                        retainedBitmapByteCount:
                            previous.retainedBitmapByteCount,
                        sourceRevision: snapshot.revision,
                        animationRevision: animationRevision,
                        bindPoseResources: planned.bindPoseResources,
                        resolvedBindPoseInputs:
                            previous.resolvedBindPoseInputs,
                        animatedResources: planned.animatedResources
                    )
                } else {
                    candidate = try makeState(
                        generation: generation,
                        publicationRevision: publicationRevision,
                        sourceRevision: snapshot.revision,
                        animationRevision: animationRevision,
                        planned: planned,
                        reusableState: previous
                    )
                }
            }
        } else {
            candidate = try makeState(
                generation: generation,
                publicationRevision: snapshot.revision,
                sourceRevision: snapshot.revision,
                animationRevision: animationRevision,
                planned: planned,
                reusableState: nil
            )
        }

        lock.lock()
        defer { lock.unlock() }
        guard epoch == capturedEpoch else {
            throw GModDynamicEntityMetalSceneBuilderError.updateInvalidated
        }
        state = candidate
        epoch &+= 1
        return candidate.scene
    }

    public func reset() {
        lock.lock()
        state = nil
        epoch &+= 1
        lock.unlock()
    }
}

private extension GModDynamicEntityMetalSceneBuilder {
    func makeState(
        generation: GModMetalDynamicEntitySceneGeneration,
        publicationRevision: UInt64,
        sourceRevision: UInt64,
        animationRevision: UInt64?,
        planned: PlannedScene,
        reusableState: State?
    ) throws -> State {
        let resolvedBindPoseInputs: [
            GModStudioRenderableModelResourceID:
                GModMetalDynamicEntityResourceInput
        ]
        let retainedBitmapByteCount: Int
        if let reusableState,
           reusableState.bindPoseResources == planned.bindPoseResources {
            resolvedBindPoseInputs = reusableState.resolvedBindPoseInputs
            retainedBitmapByteCount =
                reusableState.retainedBitmapByteCount
        } else {
            var retentionBudget = GModMetalWorldBitmapRetentionBudget(
                maximumByteCount: policy.maximumRetainedBitmapByteCount
            )
            var resolved: [
                GModStudioRenderableModelResourceID:
                    GModMetalDynamicEntityResourceInput
            ] = [:]
            for id in planned.bindPoseResources.keys.sorted() {
                guard let bindPose = planned.bindPoseResources[id] else {
                    continue
                }
                resolved[id] = Self.resourceInput(
                    bindPose,
                    retentionBudget: &retentionBudget,
                    resolveMaterial: resolveMaterial
                )
            }
            resolvedBindPoseInputs = resolved
            retainedBitmapByteCount = retentionBudget.retainedByteCount
        }

        var resources: [GModMetalDynamicEntityResourceInput] = []
        resources.reserveCapacity(planned.resources.count)
        for (_, plan) in planned.resources.sorted(by: { $0.key < $1.key }) {
            guard let resolvedBindPose =
                    resolvedBindPoseInputs[plan.bindPose.id] else {
                throw GModDynamicEntityMetalSceneBuilderError
                    .animatedBindPoseUnavailable(plan.bindPose.id)
            }
            if let animated = plan.animated {
                resources.append(
                    try GModStudioAnimatedMetalResourceAdapter.resourceInput(
                        animated: animated,
                        bindPose: plan.bindPose,
                        resolvedBindPose: resolvedBindPose
                    )
                )
            } else {
                resources.append(resolvedBindPose)
            }
        }
        return State(
            scene: try GModMetalDynamicEntityScene(
                generation: generation,
                revision: publicationRevision,
                resources: resources,
                instances: planned.instances,
                policy: policy.metalScene
            ),
            retainedBitmapByteCount: retainedBitmapByteCount,
            sourceRevision: sourceRevision,
            animationRevision: animationRevision,
            bindPoseResources: planned.bindPoseResources,
            resolvedBindPoseInputs: resolvedBindPoseInputs,
            animatedResources: planned.animatedResources
        )
    }

    static func plan(
        snapshot: GModDynamicEntityRenderSceneSnapshot,
        animatedPublication: GModDynamicEntityAnimatedMetalPublication?
    ) throws -> PlannedScene {
        var bindPoseByID: [
            GModStudioRenderableModelResourceID: GModStudioRenderableModelResource
        ] = [:]
        for resource in snapshot.resources {
            if let prior = bindPoseByID.updateValue(
                resource,
                forKey: resource.id
            ), prior != resource {
                throw GModDynamicEntityMetalSceneBuilderError
                    .conflictingBindPoseResource(resource.id)
            }
        }
        let instanceIdentities = Set(snapshot.instances.map(\.identity))
        var assignmentByIdentity: [
            SourceCanonicalEntityIdentity:
                GModStudioAnimatedRenderableModelResource
        ] = [:]
        for assignment in animatedPublication?.assignments ?? [] {
            guard instanceIdentities.contains(assignment.identity) else {
                throw GModDynamicEntityMetalSceneBuilderError
                    .animatedEntityUnavailable(assignment.identity)
            }
            guard assignmentByIdentity.updateValue(
                assignment.resource,
                forKey: assignment.identity
            ) == nil else {
                throw GModDynamicEntityMetalSceneBuilderError
                    .duplicateAnimatedEntity(assignment.identity)
            }
        }

        var plans: [GModMetalDynamicEntityResourceID: ResourcePlan] = [:]
        var referencedBindPoseIDs = Set<GModStudioRenderableModelResourceID>()
        var animatedResources: [
            GModMetalDynamicEntityResourceID:
                GModStudioAnimatedRenderableModelResource
        ] = [:]
        var instances: [GModMetalDynamicEntityInstanceInput] = []
        instances.reserveCapacity(snapshot.instances.count)
        for source in snapshot.instances {
            guard let bindPose = bindPoseByID[source.resourceID] else {
                throw GModDynamicEntityMetalSceneBuilderError
                    .animatedBindPoseUnavailable(source.resourceID)
            }
            referencedBindPoseIDs.insert(bindPose.id)
            let animated = assignmentByIdentity[source.identity]
            if let animated {
                try GModStudioAnimatedMetalResourceAdapter.validate(
                    animated: animated,
                    bindPose: bindPose
                )
            }
            let id = animated.map(
                GModStudioAnimatedMetalResourceAdapter.resourceID
            ) ?? resourceID(bindPose)
            if let prior = plans[id],
               prior.bindPose != bindPose || prior.animated != animated {
                throw GModDynamicEntityMetalSceneBuilderError
                    .conflictingAnimatedResource(id)
            }
            plans[id] = ResourcePlan(
                bindPose: bindPose,
                animated: animated
            )
            if let animated {
                if let prior = animatedResources.updateValue(
                    animated,
                    forKey: id
                ), prior != animated {
                    throw GModDynamicEntityMetalSceneBuilderError
                        .conflictingAnimatedResource(id)
                }
            }
            instances.append(instanceInput(source, resourceID: id))
        }
        // Preserve the established static path for an explicitly published but
        // currently unreferenced resource. A bind pose used exclusively by
        // animated instances is omitted because those instances already point
        // at their exact immutable pose resources.
        for (id, bindPose) in bindPoseByID where
            !referencedBindPoseIDs.contains(id) {
            plans[resourceID(bindPose)] = ResourcePlan(
                bindPose: bindPose,
                animated: nil
            )
        }
        return PlannedScene(
            resources: plans,
            instances: instances,
            bindPoseResources: bindPoseByID,
            animatedResources: animatedResources
        )
    }

    static func nextPublicationRevision(after previous: UInt64) throws -> UInt64 {
        guard previous != UInt64.max else {
            throw GModDynamicEntityMetalSceneBuilderError
                .publicationRevisionExhausted
        }
        return previous + 1
    }

    static func generation(
        snapshot: GModDynamicEntityRenderSceneSnapshot,
        application: UInt64,
        lane: UInt64,
        previous: GModMetalDynamicEntitySceneGeneration?
    ) throws -> GModMetalDynamicEntitySceneGeneration? {
        if let connection = snapshot.sourceProjectionCursor?
            .connectionGeneration {
            return GModMetalDynamicEntitySceneGeneration(
                application: application,
                lane: lane,
                sourceConnection: connection
            )
        }
        guard snapshot.resources.isEmpty,
              snapshot.instances.isEmpty,
              snapshot.issues.isEmpty else {
            throw GModDynamicEntityMetalSceneBuilderError
                .missingSourceConnectionGeneration
        }
        guard let previous else { return nil }
        guard previous.application == application,
              previous.lane == lane else {
            throw GModDynamicEntityMetalSceneBuilderError
                .missingSourceConnectionGeneration
        }
        return previous
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

    static func resourceInput(
        _ source: GModStudioRenderableModelResource,
        retentionBudget: inout GModMetalWorldBitmapRetentionBudget,
        resolveMaterial: MaterialResolver
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
        let drawRanges = source.model.drawRanges.map { range in
            let binding = GModMetalDynamicEntityMaterialBinding(
                sourceMaterialIndex: range.material.sourceMaterialIndex,
                skinFamilyIndex: range.material.skinFamilyIndex,
                textureIndex: range.material.textureIndex,
                textureName: range.material.textureName,
                vmtCandidates: range.material.vmtCandidates
            )
            return GModMetalDynamicEntityDrawRange(
                bodyPartIndex: range.bodyPartIndex,
                submodelIndex: range.submodelIndex,
                meshIndex: range.meshIndex,
                firstIndex: range.firstIndex,
                indexCount: range.indexCount,
                material: binding,
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
            drawRanges: drawRanges
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
                        detail: "world material resolver returned non-straight alpha"
                    )
                }
                let requiredByteCount = bitmap.totalByteCount
                guard retentionBudget.retain(bitmap) else {
                    return .retentionCapacityExceeded(
                        candidate: candidate,
                        requiredByteCount: requiredByteCount,
                        retainedByteCount: retentionBudget.retainedByteCount,
                        maximumByteCount: retentionBudget.maximumByteCount
                    )
                }
                return .resolved(candidate: candidate, bitmap: bitmap)
            } catch {
                return .decodeFailed(
                    candidate: candidate,
                    detail: boundedErrorDescription(error)
                )
            }
        }
        return .sourceMissing
    }

    static func instanceInput(
        _ source: GModDynamicEntityRenderInstanceSnapshot,
        resourceID: GModMetalDynamicEntityResourceID? = nil
    ) -> GModMetalDynamicEntityInstanceInput {
        GModMetalDynamicEntityInstanceInput(
            identity: source.identity,
            sourceEntityRevision: source.sourceEntityRevision,
            transform: source.transform,
            resourceID: resourceID ?? GModMetalDynamicEntityResourceID(
                normalizedModelPath: source.resourceID.normalizedModelPath,
                checksum: source.resourceID.checksum,
                lodIndex: source.resourceID.lodIndex,
                bodyValue: source.resourceID.bodyValue,
                skinFamilyIndex: source.resourceID.skinFamilyIndex
            ),
            colorModulation: source.colorModulation,
            renderMode: source.renderMode,
            renderFX: source.renderFX
        )
    }

    static func hasSameVisualInstances(
        _ prior: [GModMetalDynamicEntityInstance],
        _ received: [GModMetalDynamicEntityInstanceInput]
    ) -> Bool {
        guard prior.count == received.count else { return false }
        let sorted = received.sorted {
            if $0.identity.entryIndex != $1.identity.entryIndex {
                return $0.identity.entryIndex < $1.identity.entryIndex
            }
            return $0.identity.handle.rawValue < $1.identity.handle.rawValue
        }
        return zip(prior, sorted).allSatisfy { old, new in
            old.identity == new.identity &&
                old.sourceTransform == new.transform &&
                old.resourceID == new.resourceID &&
                old.colorModulation == new.colorModulation &&
                old.renderMode == new.renderMode &&
                old.renderFX == new.renderFX
        }
    }

    static func boundedErrorDescription(_ error: Error) -> String {
        let source = String(describing: error)
        let maximumUTF8ByteCount = 4_096
        var result = ""
        var byteCount = 0
        for scalar in source.unicodeScalars {
            let scalarText = String(scalar)
            let scalarBytes = scalarText.utf8.count
            guard byteCount <= maximumUTF8ByteCount - scalarBytes else { break }
            result.unicodeScalars.append(scalar)
            byteCount += scalarBytes
        }
        return result.isEmpty ? "unknown material decode failure" : result
    }
}
