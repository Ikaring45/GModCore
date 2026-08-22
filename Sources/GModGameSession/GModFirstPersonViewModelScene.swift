import Foundation
import GModEngine

/// The one immutable Studio resource selected by a replicated CLIENT Player's
/// canonical active Weapon and that Weapon's inherited SWEP definition.
public struct GModFirstPersonViewModelProjection: Sendable, Equatable {
    public let playerIdentity: SourceCanonicalEntityIdentity
    public let weaponIdentity: SourceCanonicalEntityIdentity
    public let weaponClassName: String
    public let sourceWeaponRevision: UInt64
    public let viewModel: SourceEntityModelReference
    public let worldModel: SourceEntityModelReference?
    public let viewModelFieldOfViewDegrees: Float
    /// Canonical `Player:GetWeaponColor()` value consumed only by materials
    /// that bind the stock `PlayerWeaponColor` proxy to `$color2`.
    public let weaponColor: SourceVector3
    public let resource: GModStudioRenderableModelResource
}

public enum GModFirstPersonViewModelProjectionStatus: Sendable, Equatable {
    case unavailableReset
    case unavailableNoLocalPlayer(entryIndex: Int)
    case unavailableLocalPlayerLifecycle(SourceCanonicalEntityIdentity)
    case unavailablePlayerColorState(SourceCanonicalEntityIdentity)
    case unavailableNoActiveWeapon(SourceCanonicalEntityIdentity)
    case unavailableActiveWeaponSnapshot(SourceCanonicalEntityIdentity)
    case unavailableInvalidActiveWeapon(SourceCanonicalEntityIdentity)
    case unavailableDefinition(className: String, reason: String)
    case unavailableNoViewModel(className: String)
    case unavailableStudio(
        model: SourceEntityModelReference,
        failure: GModStudioRenderableModelResolutionFailure
    )
    case available
}

/// A publication always exists after the first CLIENT cursor, including clear
/// and diagnosed-unavailable states. This prevents a removed/changed Weapon
/// from leaving a stale first-person model in the renderer.
public struct GModFirstPersonViewModelSceneSnapshot: Sendable, Equatable {
    public let revision: UInt64
    public let sourceProjectionCursor: SourceEntityReplicationCursor?
    public let projection: GModFirstPersonViewModelProjection?
    public let status: GModFirstPersonViewModelProjectionStatus
}

public enum GModFirstPersonViewModelSceneError:
    Error,
    Sendable,
    Equatable
{
    case sourceCursorNotIncreasing(
        previous: SourceEntityReplicationCursor,
        received: SourceEntityReplicationCursor
    )
    case duplicateEntityIdentity(SourceCanonicalEntityIdentity)
    case duplicateEntityEntryIndex(Int)
    case definitionClassMismatch(expected: String, received: String)
    case invalidDefinitionFieldOfView(Float)
    case resolvedResourceIdentityMismatch(
        expectedPath: String,
        received: GModStudioRenderableModelResourceID
    )
    case projectionInvalidated
    case revisionExhausted
}

/// Session-owned projection boundary. It consumes replicated CLIENT snapshots,
/// resolves inherited SWEP fields on the same serialized lane, and asks only
/// the real Studio repository/cache for geometry. It contains no fallback
/// model, placeholder mesh, or guessed FOV.
public final class GModFirstPersonViewModelSceneProjector:
    @unchecked Sendable
{
    public typealias DefinitionResolver = (
        _ weaponClassName: String
    ) throws -> GMLuaScriptedWeaponRenderDefinition

    /// A Source viewmodel entity begins with zero-initialized body and skin.
    /// Animation/bodygroup APIs are a later canonical viewmodel-state boundary.
    public static let initialBodyValue = 0
    public static let initialSkinFamilyIndex = 0

    private let lock = NSLock()
    private let resolver: any GModStudioRenderableModelResolving
    private var updateEpoch: UInt64 = 0
    private var sourceCursorStorage: SourceEntityReplicationCursor?
    private var snapshotStorage: GModFirstPersonViewModelSceneSnapshot?

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
        cursor: SourceEntityReplicationCursor,
        definitionResolver: DefinitionResolver
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
                throw GModFirstPersonViewModelSceneError
                    .duplicateEntityIdentity(entity.identity)
            }
            if let previous = identitiesByEntryIndex.updateValue(
                entity.identity,
                forKey: entity.identity.entryIndex
            ), previous != entity.identity {
                throw GModFirstPersonViewModelSceneError
                    .duplicateEntityEntryIndex(entity.identity.entryIndex)
            }
        }

        let candidate = try makeCandidate(
            entitiesByIdentity: entitiesByIdentity,
            identitiesByEntryIndex: identitiesByEntryIndex,
            localPlayerEntryIndex: localPlayerEntryIndex,
            definitionResolver: definitionResolver
        )

        lock.lock()
        defer { lock.unlock() }
        guard updateEpoch == capturedEpoch else {
            throw GModFirstPersonViewModelSceneError.projectionInvalidated
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
            throw GModFirstPersonViewModelSceneError.revisionExhausted
        }
        snapshotStorage = GModFirstPersonViewModelSceneSnapshot(
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
    ) -> GModFirstPersonViewModelSceneSnapshot? {
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
            throw GModFirstPersonViewModelSceneError.revisionExhausted
        }
        updateEpoch += 1
        sourceCursorStorage = nil
        guard let prior = snapshotStorage else { return false }
        let status = GModFirstPersonViewModelProjectionStatus.unavailableReset
        let changed = prior.projection != nil || prior.status != status
        if changed, prior.revision == UInt64.max {
            throw GModFirstPersonViewModelSceneError.revisionExhausted
        }
        snapshotStorage = GModFirstPersonViewModelSceneSnapshot(
            revision: changed ? prior.revision + 1 : prior.revision,
            sourceProjectionCursor: nil,
            projection: nil,
            status: status
        )
        return changed
    }
}

private extension GModFirstPersonViewModelSceneProjector {
    struct Candidate {
        let projection: GModFirstPersonViewModelProjection?
        let status: GModFirstPersonViewModelProjectionStatus
    }

    func makeCandidate(
        entitiesByIdentity: [
            SourceCanonicalEntityIdentity: SourceCanonicalEntitySnapshot
        ],
        identitiesByEntryIndex: [Int: SourceCanonicalEntityIdentity],
        localPlayerEntryIndex: Int,
        definitionResolver: DefinitionResolver
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
        guard let playerColorState = player.playerColorState else {
            return Candidate(
                projection: nil,
                status: .unavailablePlayerColorState(player.identity)
            )
        }
        guard let weaponIdentity = player.weaponInventory.activeWeapon else {
            return Candidate(
                projection: nil,
                status: .unavailableNoActiveWeapon(player.identity)
            )
        }
        guard let weapon = entitiesByIdentity[weaponIdentity] else {
            return Candidate(
                projection: nil,
                status: .unavailableActiveWeaponSnapshot(weaponIdentity)
            )
        }
        guard weapon.kind == .weapon,
              isRenderable(weapon),
              let inventoryRecord = player.weaponInventory.weapon(
                identity: weaponIdentity
              ),
              inventoryRecord.className.caseInsensitiveCompare(
                weapon.className
              ) == .orderedSame else {
            return Candidate(
                projection: nil,
                status: .unavailableInvalidActiveWeapon(weaponIdentity)
            )
        }

        let definition: GMLuaScriptedWeaponRenderDefinition
        do {
            definition = try definitionResolver(weapon.className)
        } catch {
            return Candidate(
                projection: nil,
                status: .unavailableDefinition(
                    className: weapon.className,
                    reason: String(describing: error)
                )
            )
        }
        guard definition.className.caseInsensitiveCompare(weapon.className)
                == .orderedSame else {
            throw GModFirstPersonViewModelSceneError.definitionClassMismatch(
                expected: weapon.className,
                received: definition.className
            )
        }
        guard definition.viewModelFieldOfViewDegrees.isFinite,
              definition.viewModelFieldOfViewDegrees > 0,
              definition.viewModelFieldOfViewDegrees < 180 else {
            throw GModFirstPersonViewModelSceneError
                .invalidDefinitionFieldOfView(
                    definition.viewModelFieldOfViewDegrees
                )
        }
        guard let viewModel = definition.viewModel else {
            return Candidate(
                projection: nil,
                status: .unavailableNoViewModel(className: weapon.className)
            )
        }
        let resolution = resolver.resolve(
            model: viewModel,
            bodyValue: Self.initialBodyValue,
            skinFamilyIndex: Self.initialSkinFamilyIndex
        )
        switch resolution {
        case let .failed(failure):
            return Candidate(
                projection: nil,
                status: .unavailableStudio(
                    model: viewModel,
                    failure: failure
                )
            )
        case let .resolved(resource):
            let expectedPath = GModStudioModelPath.cacheKey(viewModel.path) ??
                viewModel.path.lowercased()
            guard resource.id.normalizedModelPath == expectedPath,
                  resource.id.bodyValue == Self.initialBodyValue,
                  resource.id.skinFamilyIndex == Self.initialSkinFamilyIndex,
                  resource.id.checksum == resource.model.checksum,
                  resource.model.bodyValue == Self.initialBodyValue,
                  resource.model.skinFamilyIndex ==
                    Self.initialSkinFamilyIndex else {
                throw GModFirstPersonViewModelSceneError
                    .resolvedResourceIdentityMismatch(
                        expectedPath: expectedPath,
                        received: resource.id
                    )
            }
            return Candidate(
                projection: GModFirstPersonViewModelProjection(
                    playerIdentity: player.identity,
                    weaponIdentity: weapon.identity,
                    weaponClassName: weapon.className,
                    sourceWeaponRevision: weapon.revision,
                    viewModel: viewModel,
                    worldModel: definition.worldModel,
                    viewModelFieldOfViewDegrees:
                        definition.viewModelFieldOfViewDegrees,
                    weaponColor: playerColorState.weaponColor,
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
            throw GModFirstPersonViewModelSceneError
                .sourceCursorNotIncreasing(
                    previous: previous,
                    received: cursor
                )
        }
    }

    static func hasSameVisualState(
        _ prior: GModFirstPersonViewModelSceneSnapshot?,
        projection: GModFirstPersonViewModelProjection?,
        status: GModFirstPersonViewModelProjectionStatus
    ) -> Bool {
        guard let prior, prior.status == status else { return false }
        switch (prior.projection, projection) {
        case (nil, nil):
            return true
        case let (old?, new?):
            return old.playerIdentity == new.playerIdentity &&
                old.weaponIdentity == new.weaponIdentity &&
                old.weaponClassName == new.weaponClassName &&
                old.viewModel == new.viewModel &&
                old.worldModel == new.worldModel &&
                old.viewModelFieldOfViewDegrees ==
                    new.viewModelFieldOfViewDegrees &&
                old.weaponColor == new.weaponColor &&
                old.resource.id == new.resource.id
        case (nil, _?), (_?, nil):
            return false
        }
    }
}
