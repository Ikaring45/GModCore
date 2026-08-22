import Foundation
import GModEngine

/// One immutable first-person `gmod_hands` Studio resource selected from the
/// canonical CLIENT Player and the full EHANDLE stored in `Player.playerHands`.
/// The projection retains the authored skin/body selections; it never replaces
/// a missing c_arms asset with a synthetic mesh.
public struct GModFirstPersonHandsProjection: Sendable, Equatable {
    public let playerIdentity: SourceCanonicalEntityIdentity
    public let handsIdentity: SourceCanonicalEntityIdentity
    public let sourcePlayerRevision: UInt64
    public let sourceHandsRevision: UInt64
    public let viewModelSlot: Int32
    public let model: SourceEntityModelReference
    public let skinFamilyIndex: Int
    public let bodyValue: Int
    public let resource: GModStudioRenderableModelResource
}

/// Diagnosed publication state for the first-person hands renderer boundary.
/// Relationship and Studio failures are values, rather than permission to
/// retain an older scene or construct a placeholder.
public enum GModFirstPersonHandsProjectionStatus: Sendable, Equatable {
    case unavailableReset
    case unavailableNoLocalPlayer(entryIndex: Int)
    case unavailableLocalPlayerLifecycle(SourceCanonicalEntityIdentity)
    case unavailableNoHands(SourceCanonicalEntityIdentity)
    case unavailableHandsSnapshot(SourceCanonicalEntityIdentity)
    case unavailableHandsGenerationMismatch(
        expected: SourceCanonicalEntityIdentity,
        received: SourceCanonicalEntityIdentity
    )
    case unavailableInvalidHandsEntity(SourceCanonicalEntityIdentity)
    case unavailableHandsLifecycle(SourceCanonicalEntityIdentity)
    case unavailableNoOwner(SourceCanonicalEntityIdentity)
    case unavailableOwnerGenerationMismatch(
        expected: SourceCanonicalEntityIdentity,
        received: SourceCanonicalEntityIdentity
    )
    case unavailableOwnerMismatch(
        expected: SourceCanonicalEntityIdentity,
        received: SourceCanonicalEntityIdentity
    )
    case unavailableViewModelSlot(
        hands: SourceCanonicalEntityIdentity,
        received: Int32?
    )
    case unavailableNoModel(SourceCanonicalEntityIdentity)
    case unavailableInvalidSkin(
        hands: SourceCanonicalEntityIdentity,
        received: Int
    )
    case unavailableInvalidBodyValue(
        hands: SourceCanonicalEntityIdentity,
        received: Int
    )
    case unavailableStudio(
        model: SourceEntityModelReference,
        failure: GModStudioRenderableModelResolutionFailure
    )
    case available
}

/// A publication exists after every first accepted CLIENT cursor, including
/// diagnosed-unavailable states. Its cursor advances even when the visible
/// resource does not change, so removing Hands cannot leave a stale c_arms
/// resource merely because the active Weapon has no viewmodel.
public struct GModFirstPersonHandsSceneSnapshot: Sendable, Equatable {
    public let revision: UInt64
    public let sourceProjectionCursor: SourceEntityReplicationCursor?
    public let projection: GModFirstPersonHandsProjection?
    public let status: GModFirstPersonHandsProjectionStatus
}

public enum GModFirstPersonHandsSceneError: Error, Sendable, Equatable {
    case sourceCursorNotIncreasing(
        previous: SourceEntityReplicationCursor,
        received: SourceEntityReplicationCursor
    )
    case duplicateEntityIdentity(SourceCanonicalEntityIdentity)
    case duplicateEntityEntryIndex(Int)
    case resolvedResourceIdentityMismatch(
        expectedPath: String,
        received: GModStudioRenderableModelResourceID
    )
    case projectionInvalidated
    case revisionExhausted
}

/// Renderer-neutral projection boundary for stock first-person Hands. It
/// consumes the same immutable CLIENT entity snapshot batch and monotonically
/// increasing replication cursor as the Weapon viewmodel projector, but it is
/// deliberately independent of active-Weapon and SWEP definition state.
public final class GModFirstPersonHandsSceneProjector: @unchecked Sendable {
    /// The checked-in stock `gmod_hands.lua` attaches to `GetViewModel(0)`.
    public static let stockViewModelSlot: Int32 = 0

    private let lock = NSLock()
    private let resolver: any GModStudioRenderableModelResolving
    private var updateEpoch: UInt64 = 0
    private var sourceCursorStorage: SourceEntityReplicationCursor?
    private var snapshotStorage: GModFirstPersonHandsSceneSnapshot?

    public init(resolver: any GModStudioRenderableModelResolving) {
        self.resolver = resolver
    }

    public var sourceProjectionCursor: SourceEntityReplicationCursor? {
        lock.lock()
        defer { lock.unlock() }
        return sourceCursorStorage
    }

    @discardableResult
    public func update(
        clientEntities: [SourceCanonicalEntitySnapshot],
        localPlayerEntryIndex: Int,
        cursor: SourceEntityReplicationCursor
    ) throws -> Bool {
        lock.lock()
        let priorCursor = sourceCursorStorage
        let capturedEpoch = updateEpoch
        lock.unlock()
        guard cursor != priorCursor else { return false }
        if let priorCursor {
            try requireIncreasing(cursor, after: priorCursor)
        }

        var entitiesByIdentity: [
            SourceCanonicalEntityIdentity: SourceCanonicalEntitySnapshot
        ] = [:]
        var identitiesByEntryIndex: [Int: SourceCanonicalEntityIdentity] = [:]
        for entity in clientEntities {
            guard entitiesByIdentity.updateValue(
                entity,
                forKey: entity.identity
            ) == nil else {
                throw GModFirstPersonHandsSceneError
                    .duplicateEntityIdentity(entity.identity)
            }
            if let previous = identitiesByEntryIndex.updateValue(
                entity.identity,
                forKey: entity.identity.entryIndex
            ), previous != entity.identity {
                throw GModFirstPersonHandsSceneError
                    .duplicateEntityEntryIndex(entity.identity.entryIndex)
            }
        }

        let candidate = try makeCandidate(
            entitiesByIdentity: entitiesByIdentity,
            identitiesByEntryIndex: identitiesByEntryIndex,
            localPlayerEntryIndex: localPlayerEntryIndex
        )

        lock.lock()
        defer { lock.unlock() }
        guard updateEpoch == capturedEpoch else {
            throw GModFirstPersonHandsSceneError.projectionInvalidated
        }
        if let currentCursor = sourceCursorStorage,
           currentCursor != priorCursor {
            try requireIncreasing(cursor, after: currentCursor)
        }
        let visualStateChanged = !Self.hasSameVisualState(
            snapshotStorage,
            projection: candidate.projection,
            status: candidate.status
        )
        let priorRevision = snapshotStorage?.revision ?? 0
        if visualStateChanged, priorRevision == UInt64.max {
            throw GModFirstPersonHandsSceneError.revisionExhausted
        }
        snapshotStorage = GModFirstPersonHandsSceneSnapshot(
            revision: visualStateChanged ? priorRevision + 1 : priorRevision,
            sourceProjectionCursor: cursor,
            projection: candidate.projection,
            status: candidate.status
        )
        sourceCursorStorage = cursor
        return visualStateChanged
    }

    public func snapshot(
        ifChangedFrom revision: UInt64?
    ) -> GModFirstPersonHandsSceneSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard let snapshotStorage,
              snapshotStorage.revision != revision else { return nil }
        return snapshotStorage
    }

    @discardableResult
    public func reset() throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard updateEpoch != UInt64.max else {
            throw GModFirstPersonHandsSceneError.revisionExhausted
        }
        updateEpoch += 1
        sourceCursorStorage = nil
        guard let prior = snapshotStorage else { return false }
        let status = GModFirstPersonHandsProjectionStatus.unavailableReset
        let changed = prior.projection != nil || prior.status != status
        if changed, prior.revision == UInt64.max {
            throw GModFirstPersonHandsSceneError.revisionExhausted
        }
        snapshotStorage = GModFirstPersonHandsSceneSnapshot(
            revision: changed ? prior.revision + 1 : prior.revision,
            sourceProjectionCursor: nil,
            projection: nil,
            status: status
        )
        return changed
    }
}

private extension GModFirstPersonHandsSceneProjector {
    struct Candidate {
        let projection: GModFirstPersonHandsProjection?
        let status: GModFirstPersonHandsProjectionStatus
    }

    func makeCandidate(
        entitiesByIdentity: [
            SourceCanonicalEntityIdentity: SourceCanonicalEntitySnapshot
        ],
        identitiesByEntryIndex: [Int: SourceCanonicalEntityIdentity],
        localPlayerEntryIndex: Int
    ) throws -> Candidate {
        guard let playerIdentity = identitiesByEntryIndex[
            localPlayerEntryIndex
        ], let player = entitiesByIdentity[playerIdentity],
           player.kind == .player else {
            return Candidate(
                projection: nil,
                status: .unavailableNoLocalPlayer(
                    entryIndex: localPlayerEntryIndex
                )
            )
        }
        guard isRenderable(player) else {
            return Candidate(
                projection: nil,
                status: .unavailableLocalPlayerLifecycle(player.identity)
            )
        }
        guard let handsIdentity = player.playerHands else {
            return Candidate(
                projection: nil,
                status: .unavailableNoHands(player.identity)
            )
        }
        guard let hands = entitiesByIdentity[handsIdentity] else {
            if let received = identitiesByEntryIndex[
                handsIdentity.entryIndex
            ] {
                return Candidate(
                    projection: nil,
                    status: .unavailableHandsGenerationMismatch(
                        expected: handsIdentity,
                        received: received
                    )
                )
            }
            return Candidate(
                projection: nil,
                status: .unavailableHandsSnapshot(handsIdentity)
            )
        }
        guard hands.kind == .playerHands,
              hands.className == SourceCanonicalEntityKind
                .playerHands.className else {
            return Candidate(
                projection: nil,
                status: .unavailableInvalidHandsEntity(hands.identity)
            )
        }
        guard isRenderable(hands) else {
            return Candidate(
                projection: nil,
                status: .unavailableHandsLifecycle(hands.identity)
            )
        }
        guard let ownerIdentity = hands.handsOwner else {
            return Candidate(
                projection: nil,
                status: .unavailableNoOwner(hands.identity)
            )
        }
        guard ownerIdentity == player.identity else {
            if ownerIdentity.entryIndex == player.identity.entryIndex {
                return Candidate(
                    projection: nil,
                    status: .unavailableOwnerGenerationMismatch(
                        expected: player.identity,
                        received: ownerIdentity
                    )
                )
            }
            return Candidate(
                projection: nil,
                status: .unavailableOwnerMismatch(
                    expected: player.identity,
                    received: ownerIdentity
                )
            )
        }
        guard hands.handsViewModelIndex == Self.stockViewModelSlot else {
            return Candidate(
                projection: nil,
                status: .unavailableViewModelSlot(
                    hands: hands.identity,
                    received: hands.handsViewModelIndex
                )
            )
        }
        guard let model = hands.model else {
            return Candidate(
                projection: nil,
                status: .unavailableNoModel(hands.identity)
            )
        }
        guard hands.skin >= 0 else {
            return Candidate(
                projection: nil,
                status: .unavailableInvalidSkin(
                    hands: hands.identity,
                    received: hands.skin
                )
            )
        }
        guard hands.bodyValue >= 0 else {
            return Candidate(
                projection: nil,
                status: .unavailableInvalidBodyValue(
                    hands: hands.identity,
                    received: hands.bodyValue
                )
            )
        }

        switch resolver.resolve(
            model: model,
            bodyValue: hands.bodyValue,
            skinFamilyIndex: hands.skin
        ) {
        case let .failed(failure):
            return Candidate(
                projection: nil,
                status: .unavailableStudio(
                    model: model,
                    failure: failure
                )
            )
        case let .resolved(resource):
            let expectedPath = GModStudioModelPath.cacheKey(model.path) ??
                model.path.lowercased()
            guard resource.id.normalizedModelPath == expectedPath,
                  resource.id.bodyValue == hands.bodyValue,
                  resource.id.skinFamilyIndex == hands.skin,
                  resource.id.checksum == resource.model.checksum,
                  resource.model.bodyValue == hands.bodyValue,
                  resource.model.skinFamilyIndex == hands.skin else {
                throw GModFirstPersonHandsSceneError
                    .resolvedResourceIdentityMismatch(
                        expectedPath: expectedPath,
                        received: resource.id
                    )
            }
            return Candidate(
                projection: GModFirstPersonHandsProjection(
                    playerIdentity: player.identity,
                    handsIdentity: hands.identity,
                    sourcePlayerRevision: player.revision,
                    sourceHandsRevision: hands.revision,
                    viewModelSlot: Self.stockViewModelSlot,
                    model: model,
                    skinFamilyIndex: hands.skin,
                    bodyValue: hands.bodyValue,
                    resource: resource
                ),
                status: .available
            )
        }
    }

    func isRenderable(_ entity: SourceCanonicalEntitySnapshot) -> Bool {
        entity.isNetworkable &&
            (entity.lifecycle == .spawned || entity.lifecycle == .active)
    }

    func requireIncreasing(
        _ cursor: SourceEntityReplicationCursor,
        after previous: SourceEntityReplicationCursor
    ) throws {
        guard cursor.connectionGeneration.rawValue >
                previous.connectionGeneration.rawValue ||
                (
                    cursor.connectionGeneration ==
                        previous.connectionGeneration &&
                    cursor.sequence > previous.sequence
                ) else {
            throw GModFirstPersonHandsSceneError
                .sourceCursorNotIncreasing(
                    previous: previous,
                    received: cursor
                )
        }
    }

    static func hasSameVisualState(
        _ prior: GModFirstPersonHandsSceneSnapshot?,
        projection: GModFirstPersonHandsProjection?,
        status: GModFirstPersonHandsProjectionStatus
    ) -> Bool {
        guard let prior, prior.status == status else { return false }
        switch (prior.projection, projection) {
        case (nil, nil):
            return true
        case let (old?, new?):
            return old.playerIdentity == new.playerIdentity &&
                old.handsIdentity == new.handsIdentity &&
                old.viewModelSlot == new.viewModelSlot &&
                old.model == new.model &&
                old.skinFamilyIndex == new.skinFamilyIndex &&
                old.bodyValue == new.bodyValue &&
                old.resource.id == new.resource.id
        case (nil, _?), (_?, nil):
            return false
        }
    }
}
