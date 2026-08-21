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
        laneGeneration: UInt64
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

        let resourceIDs = snapshot.resources.map(Self.resourceID).sorted()
        let instanceInputs = snapshot.instances.map(Self.instanceInput)
        let candidate: State
        if let previous,
           previous.scene.generation == generation,
           previous.scene.resources.map(\.id) == resourceIDs {
            if snapshot.revision == previous.scene.revision {
                guard Self.hasSameVisualInstances(
                    previous.scene.instances,
                    instanceInputs
                ) else {
                    throw GModDynamicEntityMetalSceneBuilderError
                        .revisionNotIncreasing(
                            previous: previous.scene.revision,
                            received: snapshot.revision
                        )
                }
                return previous.scene
            }
            guard snapshot.revision > previous.scene.revision else {
                throw GModDynamicEntityMetalSceneBuilderError
                    .revisionNotIncreasing(
                        previous: previous.scene.revision,
                        received: snapshot.revision
                    )
            }
            candidate = State(
                scene: try previous.scene.updatingInstances(
                    revision: snapshot.revision,
                    instances: instanceInputs
                ),
                retainedBitmapByteCount: previous.retainedBitmapByteCount
            )
        } else {
            if let previous, previous.scene.generation == generation,
               snapshot.revision <= previous.scene.revision {
                throw GModDynamicEntityMetalSceneBuilderError
                    .revisionNotIncreasing(
                        previous: previous.scene.revision,
                        received: snapshot.revision
                    )
            }
            var retentionBudget = GModMetalWorldBitmapRetentionBudget(
                maximumByteCount: policy.maximumRetainedBitmapByteCount
            )
            let resources = snapshot.resources.map {
                Self.resourceInput(
                    $0,
                    retentionBudget: &retentionBudget,
                    resolveMaterial: resolveMaterial
                )
            }
            candidate = State(
                scene: try GModMetalDynamicEntityScene(
                    generation: generation,
                    revision: snapshot.revision,
                    resources: resources,
                    instances: instanceInputs,
                    policy: policy.metalScene
                ),
                retainedBitmapByteCount: retentionBudget.retainedByteCount
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
        _ source: GModDynamicEntityRenderInstanceSnapshot
    ) -> GModMetalDynamicEntityInstanceInput {
        GModMetalDynamicEntityInstanceInput(
            identity: source.identity,
            sourceEntityRevision: source.sourceEntityRevision,
            transform: source.transform,
            resourceID: GModMetalDynamicEntityResourceID(
                normalizedModelPath: source.resourceID.normalizedModelPath,
                checksum: source.resourceID.checksum,
                bodyValue: source.resourceID.bodyValue,
                skinFamilyIndex: source.resourceID.skinFamilyIndex
            )
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
                old.resourceID == new.resourceID
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
