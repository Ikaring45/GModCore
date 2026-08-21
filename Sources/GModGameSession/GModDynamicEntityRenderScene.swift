import Foundation
import GModEngine

public struct GModDynamicEntityRenderInstanceSnapshot: Sendable, Equatable {
    public let identity: SourceCanonicalEntityIdentity
    public let sourceEntityRevision: UInt64
    public let transform: SourceEntityTransform
    public let resourceID: GModStudioRenderableModelResourceID
}

public struct GModDynamicEntityRenderIssue: Sendable, Equatable {
    public let identity: SourceCanonicalEntityIdentity
    public let sourceEntityRevision: UInt64
    public let model: SourceEntityModelReference
    public let bodyValue: Int
    public let skinFamilyIndex: Int
    public let failure: GModStudioRenderableModelResolutionFailure
}

public struct GModDynamicEntityRenderSceneSnapshot: Sendable, Equatable {
    public let revision: UInt64
    public let sourceProjectionCursor: SourceEntityReplicationCursor?
    public let resources: [GModStudioRenderableModelResource]
    public let instances: [GModDynamicEntityRenderInstanceSnapshot]
    public let issues: [GModDynamicEntityRenderIssue]
}

public struct GModDynamicEntityRenderScenePolicy: Sendable, Equatable {
    public let maximumRenderablePropCount: Int

    public init(maximumRenderablePropCount: Int) {
        self.maximumRenderablePropCount = maximumRenderablePropCount
    }

    public static let initialIpad = Self(maximumRenderablePropCount: 1_024)
}

public enum GModDynamicEntityRenderSceneError: Error, Sendable, Equatable {
    case invalidPolicy(Int)
    case wrongProjectionKind(SourceCanonicalEntityKind)
    case wrongEntityKind(
        identity: SourceCanonicalEntityIdentity,
        kind: SourceCanonicalEntityKind
    )
    case sourceCursorNotIncreasing(
        previous: SourceEntityReplicationCursor,
        received: SourceEntityReplicationCursor
    )
    case entityOrderNotIncreasing(previous: Int, current: Int)
    case tooManyRenderableProps(requested: Int, cap: Int)
    case renderablePropMissingModel(SourceCanonicalEntityIdentity)
    case resolvedResourceIdentityMismatch(
        entity: SourceCanonicalEntityIdentity,
        expectedPath: String,
        expectedBody: Int,
        expectedSkin: Int,
        received: GModStudioRenderableModelResourceID
    )
    case conflictingResource(GModStudioRenderableModelResourceID)
    case projectionInvalidated
    case revisionExhausted
}

/// Session-owned projector. It accepts only the atomic CLIENT prop projection,
/// never SERVER entities or Lua userdata. Compiled resources remain shared by
/// every instance with the same model/body/skin appearance.
public final class GModDynamicEntityRenderSceneProjector: @unchecked Sendable {
    private let lock = NSLock()
    private let resolver: any GModStudioRenderableModelResolving
    private let policy: GModDynamicEntityRenderScenePolicy
    private var updateEpoch: UInt64 = 0
    private var sourceCursorStorage: SourceEntityReplicationCursor?
    private var snapshotStorage: GModDynamicEntityRenderSceneSnapshot?

    public init(
        resolver: any GModStudioRenderableModelResolving,
        policy: GModDynamicEntityRenderScenePolicy = .initialIpad
    ) throws {
        guard policy.maximumRenderablePropCount > 0 else {
            throw GModDynamicEntityRenderSceneError.invalidPolicy(
                policy.maximumRenderablePropCount
            )
        }
        self.resolver = resolver
        self.policy = policy
    }

    public var sourceProjectionCursor: SourceEntityReplicationCursor? {
        lock.lock()
        defer { lock.unlock() }
        return sourceCursorStorage
    }

    /// Builds and commits one candidate. A duplicate source cursor is a no-op;
    /// any throw leaves both the prior cursor and scene intact.
    @discardableResult
    public func update(
        from projection: SourceCanonicalEntityKindProjection
    ) throws -> Bool {
        lock.lock()
        let priorCursor = sourceCursorStorage
        let capturedEpoch = updateEpoch
        lock.unlock()
        guard projection.kind == .propPhysics else {
            throw GModDynamicEntityRenderSceneError.wrongProjectionKind(
                projection.kind
            )
        }
        guard projection.cursor != priorCursor else { return false }
        if let priorCursor {
            guard projection.cursor.connectionGeneration.rawValue >
                    priorCursor.connectionGeneration.rawValue ||
                    (
                        projection.cursor.connectionGeneration ==
                            priorCursor.connectionGeneration &&
                        projection.cursor.sequence > priorCursor.sequence
                    ) else {
                throw GModDynamicEntityRenderSceneError.sourceCursorNotIncreasing(
                    previous: priorCursor,
                    received: projection.cursor
                )
            }
        }

        var priorIndex: Int?
        for entity in projection.entities {
            guard entity.kind == .propPhysics else {
                throw GModDynamicEntityRenderSceneError.wrongEntityKind(
                    identity: entity.identity,
                    kind: entity.kind
                )
            }
            if let priorIndex, entity.identity.entryIndex <= priorIndex {
                throw GModDynamicEntityRenderSceneError.entityOrderNotIncreasing(
                    previous: priorIndex,
                    current: entity.identity.entryIndex
                )
            }
            priorIndex = entity.identity.entryIndex
        }
        let renderable = projection.entities.filter {
            $0.isNetworkable &&
                ($0.lifecycle == .spawned || $0.lifecycle == .active)
        }
        guard renderable.count <= policy.maximumRenderablePropCount else {
            throw GModDynamicEntityRenderSceneError.tooManyRenderableProps(
                requested: renderable.count,
                cap: policy.maximumRenderablePropCount
            )
        }

        var resourcesByID: [
            GModStudioRenderableModelResourceID: GModStudioRenderableModelResource
        ] = [:]
        struct AppearanceKey: Hashable {
            let normalizedModelPath: String
            let bodyValue: Int
            let skinFamilyIndex: Int
        }
        var resolutionsByAppearance:
            [AppearanceKey: GModStudioRenderableModelResolution] = [:]
        var instances: [GModDynamicEntityRenderInstanceSnapshot] = []
        var issues: [GModDynamicEntityRenderIssue] = []
        instances.reserveCapacity(renderable.count)
        issues.reserveCapacity(renderable.count)
        for entity in renderable {
            guard let model = entity.model else {
                throw GModDynamicEntityRenderSceneError
                    .renderablePropMissingModel(entity.identity)
            }
            let normalizedPath = GModStudioModelPath.cacheKey(model.path) ??
                model.path.lowercased()
            let appearance = AppearanceKey(
                normalizedModelPath: normalizedPath,
                bodyValue: entity.bodyValue,
                skinFamilyIndex: entity.skin
            )
            let resolution: GModStudioRenderableModelResolution
            if let cached = resolutionsByAppearance[appearance] {
                resolution = cached
            } else {
                let resolved = resolver.resolve(
                    model: model,
                    bodyValue: entity.bodyValue,
                    skinFamilyIndex: entity.skin
                )
                resolutionsByAppearance[appearance] = resolved
                resolution = resolved
            }
            switch resolution {
            case let .failed(failure):
                issues.append(GModDynamicEntityRenderIssue(
                    identity: entity.identity,
                    sourceEntityRevision: entity.revision,
                    model: model,
                    bodyValue: entity.bodyValue,
                    skinFamilyIndex: entity.skin,
                    failure: failure
                ))
            case let .resolved(resource):
                guard resource.id.normalizedModelPath == normalizedPath,
                      resource.id.bodyValue == entity.bodyValue,
                      resource.id.skinFamilyIndex == entity.skin,
                      resource.id.checksum == resource.model.checksum,
                      resource.model.bodyValue == entity.bodyValue,
                      resource.model.skinFamilyIndex == entity.skin else {
                    throw GModDynamicEntityRenderSceneError
                        .resolvedResourceIdentityMismatch(
                            entity: entity.identity,
                            expectedPath: normalizedPath,
                            expectedBody: entity.bodyValue,
                            expectedSkin: entity.skin,
                            received: resource.id
                        )
                }
                resourcesByID[resource.id] = resource
                instances.append(GModDynamicEntityRenderInstanceSnapshot(
                    identity: entity.identity,
                    sourceEntityRevision: entity.revision,
                    transform: entity.transform,
                    resourceID: resource.id
                ))
            }
        }

        let resources = resourcesByID.values.sorted { $0.id < $1.id }
        lock.lock()
        defer { lock.unlock() }
        guard updateEpoch == capturedEpoch else {
            throw GModDynamicEntityRenderSceneError.projectionInvalidated
        }
        if let currentCursor = sourceCursorStorage,
           currentCursor != priorCursor {
            guard projection.cursor.connectionGeneration.rawValue >
                    currentCursor.connectionGeneration.rawValue ||
                    (
                        projection.cursor.connectionGeneration ==
                            currentCursor.connectionGeneration &&
                        projection.cursor.sequence > currentCursor.sequence
                    ) else {
                throw GModDynamicEntityRenderSceneError.sourceCursorNotIncreasing(
                    previous: currentCursor,
                    received: projection.cursor
                )
            }
        }
        let visualStateChanged = !Self.hasSameVisualState(
            snapshotStorage,
            resources: resources,
            instances: instances,
            issues: issues
        )
        let priorRevision = snapshotStorage?.revision ?? 0
        if visualStateChanged && priorRevision == UInt64.max {
            throw GModDynamicEntityRenderSceneError.revisionExhausted
        }
        let candidate = GModDynamicEntityRenderSceneSnapshot(
            revision: visualStateChanged ? priorRevision + 1 : priorRevision,
            sourceProjectionCursor: projection.cursor,
            resources: resources,
            instances: instances,
            issues: issues
        )
        sourceCursorStorage = projection.cursor
        snapshotStorage = candidate
        return visualStateChanged
    }

    private static func hasSameVisualState(
        _ prior: GModDynamicEntityRenderSceneSnapshot?,
        resources: [GModStudioRenderableModelResource],
        instances: [GModDynamicEntityRenderInstanceSnapshot],
        issues: [GModDynamicEntityRenderIssue]
    ) -> Bool {
        guard let prior,
              prior.resources.map(\.id) == resources.map(\.id),
              prior.instances.count == instances.count,
              prior.issues.count == issues.count else { return false }
        let sameInstances = zip(prior.instances, instances).allSatisfy {
            old, new in
            old.identity == new.identity &&
                old.transform == new.transform &&
                old.resourceID == new.resourceID
        }
        guard sameInstances else { return false }
        return zip(prior.issues, issues).allSatisfy { old, new in
            old.identity == new.identity &&
                old.model == new.model &&
                old.bodyValue == new.bodyValue &&
                old.skinFamilyIndex == new.skinFamilyIndex &&
                old.failure == new.failure
        }
    }

    /// Returns the latest immutable scene only when the caller has not already
    /// consumed its revision.
    public func snapshot(
        ifChangedFrom revision: UInt64?
    ) -> GModDynamicEntityRenderSceneSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard let snapshotStorage,
              snapshotStorage.revision != revision else { return nil }
        return snapshotStorage
    }

    /// Disconnect/session replacement boundary. A visible scene publishes one
    /// final empty revision; an already-empty scene only drops its source
    /// cursor because the renderer has no stale instance to remove.
    @discardableResult
    public func reset() throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard updateEpoch != UInt64.max else {
            throw GModDynamicEntityRenderSceneError.revisionExhausted
        }
        updateEpoch += 1
        sourceCursorStorage = nil
        guard let prior = snapshotStorage else { return false }
        let visualStateChanged = !prior.resources.isEmpty ||
            !prior.instances.isEmpty || !prior.issues.isEmpty
        if visualStateChanged && prior.revision == UInt64.max {
            throw GModDynamicEntityRenderSceneError.revisionExhausted
        }
        snapshotStorage = GModDynamicEntityRenderSceneSnapshot(
            revision: visualStateChanged ? prior.revision + 1 : prior.revision,
            sourceProjectionCursor: nil,
            resources: [],
            instances: [],
            issues: []
        )
        return visualStateChanged
    }
}
