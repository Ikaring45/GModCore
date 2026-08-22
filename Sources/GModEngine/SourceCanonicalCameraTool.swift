import Foundation

public enum SourceCanonicalCameraToolAction: UInt8, Equatable, Sendable {
    case leftClick = 1
    case rightClick = 2
}

/// The bundled camera does not provide projection overrides. Its view uses the
/// engine/player projection selected by the normal CalcView path, so these
/// fields intentionally remain nil instead of inventing FOV or clip planes.
public struct SourceCanonicalCameraProjectionOverrides:
    Equatable,
    Sendable
{
    public let fieldOfViewDegrees: Float?
    public let nearClip: Float?
    public let farClip: Float?
    public let orthographicBounds: SourceCanonicalCameraOrthographicBounds?
    public let drawsViewer: Bool?

    private init(
        fieldOfViewDegrees: Float?,
        nearClip: Float?,
        farClip: Float?,
        orthographicBounds: SourceCanonicalCameraOrthographicBounds?,
        drawsViewer: Bool?
    ) {
        self.fieldOfViewDegrees = fieldOfViewDegrees
        self.nearClip = nearClip
        self.farClip = farClip
        self.orthographicBounds = orthographicBounds
        self.drawsViewer = drawsViewer
    }

    public static let bundledCameraTool = Self(
        fieldOfViewDegrees: nil,
        nearClip: nil,
        farClip: nil,
        orthographicBounds: nil,
        drawsViewer: nil
    )
}

/// Reserved typed shape for a future authenticated orthographic camera. The
/// bundled `gmod_cameraprop` never creates one, so no public initializer is
/// exposed by this slice.
public struct SourceCanonicalCameraOrthographicBounds:
    Equatable,
    Sendable
{
    public let left: Float
    public let right: Float
    public let top: Float
    public let bottom: Float

    fileprivate init(left: Float, right: Float, top: Float, bottom: Float) {
        self.left = left
        self.right = right
        self.top = top
        self.bottom = bottom
    }
}

public enum SourceCanonicalCameraCollisionGroup: Equatable, Sendable {
    case weapon
    case world
}

public struct SourceCanonicalCameraTrackingTargetSnapshot:
    Equatable,
    Sendable
{
    public let identity: SourceCanonicalEntityIdentity
    public let transform: SourceEntityTransform
    public let isWorld: Bool
    public let isPlayer: Bool
    public let playerViewOffset: SourceVector3

    public init(
        identity: SourceCanonicalEntityIdentity,
        transform: SourceEntityTransform,
        isWorld: Bool = false,
        isPlayer: Bool = false,
        playerViewOffset: SourceVector3 = .zero
    ) {
        self.identity = identity
        self.transform = transform
        self.isWorld = isWorld
        self.isPlayer = isPlayer
        self.playerViewOffset = playerViewOffset
    }

    public init(_ snapshot: SourceCanonicalEntitySnapshot) {
        self.init(
            identity: snapshot.identity,
            transform: snapshot.transform,
            isWorld: snapshot.kind == .world,
            isPlayer: snapshot.kind == .player,
            playerViewOffset: snapshot.viewOffset
        )
    }
}

public struct SourceCanonicalCameraTrace: Equatable, Sendable {
    public let startPosition: SourceVector3
    public let hitPosition: SourceVector3
    public let target: SourceCanonicalCameraTrackingTargetSnapshot?

    public init(
        startPosition: SourceVector3,
        hitPosition: SourceVector3,
        target: SourceCanonicalCameraTrackingTargetSnapshot?
    ) {
        self.startPosition = startPosition
        self.hitPosition = hitPosition
        self.target = target
    }
}

public struct SourceCanonicalCameraToolSettings: Equatable, Sendable {
    public let controlKey: Int32
    public let locked: Int32
    public let toggle: Int32

    public init(controlKey: Int32, locked: Int32, toggle: Int32) {
        self.controlKey = controlKey
        self.locked = locked
        self.toggle = toggle
    }

    public static let bundledDefaults = Self(
        controlKey: 37,
        locked: 0,
        toggle: 1
    )
}

public struct SourceCanonicalCameraToolRequest: Equatable, Sendable {
    public let actor: SourceCanonicalEntitySnapshot
    public let action: SourceCanonicalCameraToolAction
    public let trace: SourceCanonicalCameraTrace
    public let settings: SourceCanonicalCameraToolSettings

    public init(
        actor: SourceCanonicalEntitySnapshot,
        action: SourceCanonicalCameraToolAction,
        trace: SourceCanonicalCameraTrace,
        settings: SourceCanonicalCameraToolSettings
    ) {
        self.actor = actor
        self.action = action
        self.trace = trace
        self.settings = settings
    }
}

public typealias SourceCanonicalCameraCanTool =
    (SourceCanonicalCameraToolRequest) throws -> Bool

/// `CheckLimit("cameras")` is host-owned and configurable. No limit value is
/// guessed here; the callback is consulted only when the original key/owner
/// replacement rule found no existing camera.
public typealias SourceCanonicalCameraLimitGate =
    (_ owner: SourceCanonicalEntityIdentity) throws -> Bool

public struct SourceCanonicalCameraSnapshot: Equatable, Sendable {
    public let identity: SourceCanonicalEntityIdentity
    public let className: String
    public let lifecycle: SourceCanonicalEntityLifecycle
    public let revision: UInt64
    public let transform: SourceEntityTransform
    public let model: SourceEntityModelReference
    public let owner: SourceCanonicalEntityIdentity
    public let controlKey: Int32
    public let locked: Int32
    public let toggle: Int32
    public let isOn: Bool
    public let usingPlayer: SourceCanonicalEntityIdentity?
    public let trackingEntity: SourceCanonicalEntityIdentity?
    public let trackingLocalPosition: SourceVector3
    public let moveType: SourceMoveType
    public let solidType: SourceEntitySolidType
    public let collisionGroup: SourceCanonicalCameraCollisionGroup
    public let drawsShadow: Bool
    public let physicsObjectStartsAsleep: Bool
    public let projectionOverrides: SourceCanonicalCameraProjectionOverrides

    public init(
        identity: SourceCanonicalEntityIdentity,
        lifecycle: SourceCanonicalEntityLifecycle,
        revision: UInt64,
        transform: SourceEntityTransform,
        owner: SourceCanonicalEntityIdentity,
        controlKey: Int32,
        locked: Int32,
        toggle: Int32,
        isOn: Bool,
        usingPlayer: SourceCanonicalEntityIdentity?,
        trackingEntity: SourceCanonicalEntityIdentity?,
        trackingLocalPosition: SourceVector3,
        moveType: SourceMoveType,
        solidType: SourceEntitySolidType,
        collisionGroup: SourceCanonicalCameraCollisionGroup
    ) {
        self.identity = identity
        className = "gmod_cameraprop"
        self.lifecycle = lifecycle
        self.revision = revision
        self.transform = transform
        model = SourceEntityModelReference("models/dav0r/camera.mdl")
        self.owner = owner
        self.controlKey = controlKey
        self.locked = locked
        self.toggle = toggle
        self.isOn = isOn
        self.usingPlayer = usingPlayer
        self.trackingEntity = trackingEntity
        self.trackingLocalPosition = trackingLocalPosition
        self.moveType = moveType
        self.solidType = solidType
        self.collisionGroup = collisionGroup
        drawsShadow = false
        physicsObjectStartsAsleep = true
        projectionOverrides = .bundledCameraTool
    }
}

public enum SourceCanonicalCameraReplicationOperation:
    Equatable,
    Sendable
{
    case create(SourceCanonicalCameraSnapshot)
    case update(SourceCanonicalCameraSnapshot)
    case remove(SourceCanonicalCameraSnapshot)
}

public struct SourceCanonicalCameraReplicationBatch: Equatable, Sendable {
    public let sequence: UInt64
    public let operations: [SourceCanonicalCameraReplicationOperation]

    public init(
        sequence: UInt64,
        operations: [SourceCanonicalCameraReplicationOperation]
    ) {
        self.sequence = sequence
        self.operations = operations
    }
}

public struct SourceCanonicalCameraUndoRecord: Equatable, Sendable {
    public let identifier: UInt64
    public let name: String
    public let player: SourceCanonicalEntityIdentity
    public let camera: SourceCanonicalEntityIdentity
    public let isLive: Bool

    public init(
        identifier: UInt64,
        player: SourceCanonicalEntityIdentity,
        camera: SourceCanonicalEntityIdentity,
        isLive: Bool
    ) {
        self.identifier = identifier
        name = "gmod_cameraprop"
        self.player = player
        self.camera = camera
        self.isLive = isLive
    }
}

public struct SourceCanonicalCameraSpawnResult: Equatable, Sendable {
    public let camera: SourceCanonicalCameraSnapshot
    public let replacedCameras: [SourceCanonicalEntityIdentity]
    public let undo: SourceCanonicalCameraUndoRecord
    public let cleanupCategory: String

    public init(
        camera: SourceCanonicalCameraSnapshot,
        replacedCameras: [SourceCanonicalEntityIdentity],
        undo: SourceCanonicalCameraUndoRecord
    ) {
        self.camera = camera
        self.replacedCameras = replacedCameras
        self.undo = undo
        cleanupCategory = "cameras"
    }
}

public enum SourceCanonicalCameraToolRejection: Equatable, Sendable {
    case actorIsNotLivePlayer
    case controlKeyDisabled
    case canToolDenied
    case cameraLimitReached
    case rightClickTargetUnavailable
}

public enum SourceCanonicalCameraToolResult: Equatable, Sendable {
    case spawned(SourceCanonicalCameraSpawnResult)
    case rejected(SourceCanonicalCameraToolRejection)
}

public enum SourceCanonicalCameraInputAction: Equatable, Sendable {
    case activate
    case deactivate
    case toggle
}

/// A touch surface supplies an opaque action identifier. The engine does not
/// guess a gesture or key code; both key and touch sources resolve to the same
/// explicit activate/deactivate/toggle action.
public enum SourceCanonicalCameraInputSource: Equatable, Sendable {
    case controlKey(Int32)
    case touch(actionIdentifier: UInt64)
}

public struct SourceCanonicalCameraInput: Equatable, Sendable {
    public let player: SourceCanonicalEntityIdentity
    public let camera: SourceCanonicalEntityIdentity
    public let action: SourceCanonicalCameraInputAction
    public let source: SourceCanonicalCameraInputSource

    public init(
        player: SourceCanonicalEntityIdentity,
        camera: SourceCanonicalEntityIdentity,
        action: SourceCanonicalCameraInputAction,
        source: SourceCanonicalCameraInputSource
    ) {
        self.player = player
        self.camera = camera
        self.action = action
        self.source = source
    }
}

public struct SourceCanonicalCameraViewSnapshot: Equatable, Sendable {
    public let camera: SourceCanonicalEntityIdentity
    public let player: SourceCanonicalEntityIdentity
    public let origin: SourceVector3
    public let angles: SourceQAngle
    public let projectionOverrides: SourceCanonicalCameraProjectionOverrides

    public init(
        camera: SourceCanonicalEntityIdentity,
        player: SourceCanonicalEntityIdentity,
        origin: SourceVector3,
        angles: SourceQAngle,
        projectionOverrides: SourceCanonicalCameraProjectionOverrides
    ) {
        self.camera = camera
        self.player = player
        self.origin = origin
        self.angles = angles
        self.projectionOverrides = projectionOverrides
    }
}

public enum SourceCanonicalCameraError: Error, Equatable, Sendable {
    case noFreeNetworkableSlot
    case unknownCamera(SourceCanonicalEntityIdentity)
    case invalidLifecycle(SourceCanonicalEntityLifecycle)
    case ticketSpaceExhausted
    case replicationSequence(expected: UInt64, actual: UInt64)
    case replicationSlotOccupied(Int)
    case replicationIdentityMismatch(SourceCanonicalEntityIdentity)
    case replicationRevision(expected: UInt64, actual: UInt64)
}

private final class SourceCanonicalCameraEntityStorage: SourceEntity {
    init() {
        super.init(className: "gmod_cameraprop")
    }
}

private struct SourceCanonicalCameraMutableState {
    var lifecycle: SourceCanonicalEntityLifecycle
    var revision: UInt64
    var transform: SourceEntityTransform
    let owner: SourceCanonicalEntityIdentity
    let controlKey: Int32
    let locked: Int32
    let toggle: Int32
    var isOn: Bool
    var usingPlayer: SourceCanonicalEntityIdentity?
    var trackingEntity: SourceCanonicalEntityIdentity?
    var trackingLocalPosition: SourceVector3
    var moveType: SourceMoveType
    var solidType: SourceEntitySolidType
    var collisionGroup: SourceCanonicalCameraCollisionGroup
}

/// SERVER-lane authoritative coordinator for the bundled camera entity and
/// tool. It allocates from one SourceEntityList and journals immutable camera
/// snapshots; it owns no CLIENT mirror and performs no rendering directly.
public final class SourceCanonicalCameraToolCoordinator {
    public let entityList: SourceEntityList

    private let limitGate: SourceCanonicalCameraLimitGate
    private var statesByHandle: [UInt32: SourceCanonicalCameraMutableState] = [:]
    private var cameraOrder: [UInt32] = []
    private var cleanupByPlayer: [
        SourceCanonicalEntityIdentity: Set<SourceCanonicalEntityIdentity>
    ] = [:]
    private var undoStorage: [SourceCanonicalCameraUndoRecord] = []
    private var nextUndoIdentifier: UInt64 = 1
    private var pendingReplication: [
        SourceCanonicalCameraReplicationOperation
    ] = []
    private var nextReplicationSequence: UInt64 = 1

    public init(
        entityList: SourceEntityList = SourceEntityList(),
        limitGate: @escaping SourceCanonicalCameraLimitGate
    ) {
        self.entityList = entityList
        self.limitGate = limitGate
    }

    public var snapshots: [SourceCanonicalCameraSnapshot] {
        cameraOrder.compactMap { raw in
            let identity = SourceCanonicalEntityIdentity(
                handle: SourceBaseHandle.unsafeFromIndex(raw)
            )
            return snapshot(for: identity)
        }
    }

    public var undoRecords: [SourceCanonicalCameraUndoRecord] {
        undoStorage
    }

    public func cleanupCameras(
        for player: SourceCanonicalEntityIdentity
    ) -> [SourceCanonicalEntityIdentity] {
        Array(cleanupByPlayer[player] ?? []).sorted(by: Self.identityOrder)
    }

    public func snapshot(
        for identity: SourceCanonicalEntityIdentity
    ) -> SourceCanonicalCameraSnapshot? {
        guard let state = statesByHandle[identity.handle.rawValue],
              entityList.entity(for: identity.handle) is
                SourceCanonicalCameraEntityStorage else { return nil }
        return makeSnapshot(identity: identity, state: state)
    }

    @discardableResult
    public func perform(
        _ request: SourceCanonicalCameraToolRequest,
        canTool: SourceCanonicalCameraCanTool
    ) throws -> SourceCanonicalCameraToolResult {
        guard let actorEntity = entityList.entity(
            for: request.actor.identity.handle
        ) as? SourceCanonicalEntity,
              actorEntity.kind == .player,
              let actor = actorEntity.snapshot,
              actor.identity == request.actor.identity,
              actor.lifecycle != .pendingRemoval,
              actor.lifecycle != .removed else {
            return .rejected(.actorIsNotLivePlayer)
        }
        let authoritativeRequest = SourceCanonicalCameraToolRequest(
            actor: actor,
            action: request.action,
            trace: request.trace,
            settings: request.settings
        )
        guard try canTool(authoritativeRequest) else {
            return .rejected(.canToolDenied)
        }
        guard request.settings.controlKey != -1 else {
            return .rejected(.controlKeyDisabled)
        }
        if request.action == .rightClick,
           (request.trace.target == nil ||
                entityList.entity(
                    for: request.trace.target!.identity.handle
                ) == nil) {
            return .rejected(.rightClickTargetUnavailable)
        }

        let replacements = snapshots.filter {
            ($0.owner == actor.identity ||
                !isLiveCanonicalPlayer($0.owner)) &&
                $0.controlKey == request.settings.controlKey &&
                $0.lifecycle != .pendingRemoval &&
                $0.lifecycle != .removed
        }
        let isWithinLimit = !replacements.isEmpty
            ? true
            : try limitGate(actor.identity)
        guard isWithinLimit else {
            return .rejected(.cameraLimitReached)
        }
        guard nextUndoIdentifier != UInt64.max else {
            throw SourceCanonicalCameraError.ticketSpaceExhausted
        }

        var state = SourceCanonicalCameraMutableState(
            lifecycle: .created,
            revision: 0,
            transform: SourceEntityTransform(
                origin: request.trace.startPosition,
                angles: actor.transform.angles
            ),
            owner: actor.identity,
            controlKey: request.settings.controlKey,
            locked: request.settings.locked,
            toggle: request.settings.toggle,
            isOn: false,
            usingPlayer: nil,
            trackingEntity: nil,
            trackingLocalPosition: .zero,
            moveType: .vPhysics,
            solidType: .vPhysics,
            collisionGroup: .weapon
        )
        if request.action == .rightClick,
           let target = request.trace.target {
            let normalizedTarget: SourceCanonicalCameraTrackingTargetSnapshot
            let worldHit: SourceVector3
            if target.isWorld {
                normalizedTarget = SourceCanonicalCameraTrackingTargetSnapshot(
                    actor
                )
                worldHit = actor.transform.origin
            } else if target.isPlayer {
                normalizedTarget = target
                worldHit = target.transform.origin
            } else {
                normalizedTarget = target
                worldHit = request.trace.hitPosition
            }
            state.trackingEntity = normalizedTarget.identity
            state.trackingLocalPosition = normalizedTarget.transform
                .inverseTransformPointToLocal(worldHit)
            state.moveType = .none
            state.solidType = .boundingBox
        }
        if request.settings.locked == 1 {
            state.moveType = .none
            state.solidType = .boundingBox
            state.collisionGroup = .world
        }

        let entryIndex = try firstFreeNetworkableEntryIndex()
        let camera = SourceCanonicalCameraEntityStorage()
        let handle = try entityList.addNetworkableEntity(camera, at: entryIndex)
        let identity = SourceCanonicalEntityIdentity(handle: handle)
        do {
            for existing in replacements {
                _ = try markForRemoval(existing.identity)
            }
        } catch {
            precondition(
                entityList.rollbackUnpublishedAddition(handle, entity: camera),
                "camera creation rollback lost its exact fresh EHANDLE"
            )
            throw error
        }
        statesByHandle[handle.rawValue] = state
        cameraOrder.append(handle.rawValue)
        pendingReplication.append(.create(makeSnapshot(
            identity: identity,
            state: state
        )))
        state.lifecycle = .spawned
        state.revision = 1
        statesByHandle[handle.rawValue] = state
        let spawned = makeSnapshot(identity: identity, state: state)
        pendingReplication.append(.update(spawned))
        cleanupByPlayer[actor.identity, default: []].insert(identity)
        let undo = SourceCanonicalCameraUndoRecord(
            identifier: nextUndoIdentifier,
            player: actor.identity,
            camera: identity,
            isLive: true
        )
        nextUndoIdentifier += 1
        undoStorage.append(undo)
        return .spawned(SourceCanonicalCameraSpawnResult(
            camera: spawned,
            replacedCameras: replacements.map(\.identity).sorted(
                by: Self.identityOrder
            ),
            undo: undo
        ))
    }

    @discardableResult
    public func handleInput(
        _ input: SourceCanonicalCameraInput
    ) throws -> SourceCanonicalCameraSnapshot? {
        guard var state = statesByHandle[input.camera.handle.rawValue],
              entityList.entity(for: input.camera.handle) is
                SourceCanonicalCameraEntityStorage,
              state.owner == input.player,
              isLiveCanonicalPlayer(input.player),
              state.lifecycle != .pendingRemoval,
              state.lifecycle != .removed else { return nil }
        if case let .controlKey(key) = input.source,
           key != state.controlKey { return nil }

        switch input.action {
        case .activate:
            deactivateOtherCamera(for: input.player, except: input.camera)
            state.isOn = true
            state.usingPlayer = input.player
        case .deactivate:
            guard state.usingPlayer == input.player else { return nil }
            state.isOn = false
            state.usingPlayer = nil
        case .toggle:
            if state.usingPlayer == input.player {
                state.isOn = false
                state.usingPlayer = nil
            } else {
                deactivateOtherCamera(for: input.player, except: input.camera)
                state.isOn = true
                state.usingPlayer = input.player
            }
        }
        state.revision &+= 1
        statesByHandle[input.camera.handle.rawValue] = state
        let snapshot = makeSnapshot(identity: input.camera, state: state)
        pendingReplication.append(.update(snapshot))
        return snapshot
    }

    public func inputActionForBinding(
        camera identity: SourceCanonicalEntityIdentity,
        pressed: Bool
    ) throws -> SourceCanonicalCameraInputAction? {
        guard let camera = snapshot(for: identity) else {
            throw SourceCanonicalCameraError.unknownCamera(identity)
        }
        if camera.toggle == 1 {
            return pressed ? .toggle : nil
        }
        return pressed ? .activate : .deactivate
    }

    /// Mirrors `gmod_cameraprop:CanTool`: a camera made static either by
    /// tracking or by the locked option rejects tools, while a free VPhysics
    /// camera accepts them. The lookup validates the complete EHANDLE.
    public func canUseTool(
        onCamera identity: SourceCanonicalEntityIdentity
    ) throws -> Bool {
        guard let camera = snapshot(for: identity) else {
            throw SourceCanonicalCameraError.unknownCamera(identity)
        }
        return camera.moveType != .none
    }

    @discardableResult
    public func undoLatestCamera(
        for player: SourceCanonicalEntityIdentity
    ) throws -> SourceCanonicalEntityIdentity? {
        guard let index = undoStorage.lastIndex(where: {
            $0.player == player && $0.isLive && snapshot(for: $0.camera) != nil
        }) else { return nil }
        let record = undoStorage[index]
        _ = try markForRemoval(record.camera)
        undoStorage[index] = SourceCanonicalCameraUndoRecord(
            identifier: record.identifier,
            player: record.player,
            camera: record.camera,
            isLive: false
        )
        return record.camera
    }

    @discardableResult
    public func markCleanupForRemoval(
        player: SourceCanonicalEntityIdentity
    ) throws -> [SourceCanonicalEntityIdentity] {
        let identities = cleanupCameras(for: player)
        for identity in identities {
            _ = try markForRemoval(identity)
        }
        return identities
    }

    @discardableResult
    public func markForRemoval(
        _ identity: SourceCanonicalEntityIdentity
    ) throws -> SourceCanonicalCameraSnapshot {
        guard var state = statesByHandle[identity.handle.rawValue],
              entityList.entity(for: identity.handle) is
                SourceCanonicalCameraEntityStorage else {
            throw SourceCanonicalCameraError.unknownCamera(identity)
        }
        if state.lifecycle == .pendingRemoval {
            return makeSnapshot(identity: identity, state: state)
        }
        guard state.lifecycle != .removed else {
            throw SourceCanonicalCameraError.invalidLifecycle(state.lifecycle)
        }
        state.lifecycle = .pendingRemoval
        state.revision &+= 1
        statesByHandle[identity.handle.rawValue] = state
        let pending = makeSnapshot(identity: identity, state: state)
        pendingReplication.append(.update(pending))
        entityList.markForDeletion(identity.handle)
        return pending
    }

    /// Called after the shared SourceEntityList cleanup boundary. Only an
    /// exact pending full handle whose slot is now empty/reused can publish a
    /// camera removal.
    @discardableResult
    public func acknowledgeCleanup(
        _ identity: SourceCanonicalEntityIdentity
    ) throws -> SourceCanonicalCameraSnapshot? {
        guard var state = statesByHandle[identity.handle.rawValue],
              state.lifecycle == .pendingRemoval else { return nil }
        guard entityList.entity(for: identity.handle) == nil else { return nil }
        state.lifecycle = .removed
        state.revision &+= 1
        statesByHandle.removeValue(forKey: identity.handle.rawValue)
        cameraOrder.removeAll { $0 == identity.handle.rawValue }
        cleanupByPlayer[state.owner]?.remove(identity)
        if cleanupByPlayer[state.owner]?.isEmpty == true {
            cleanupByPlayer.removeValue(forKey: state.owner)
        }
        for index in undoStorage.indices
            where undoStorage[index].camera == identity &&
                undoStorage[index].isLive
        {
            let record = undoStorage[index]
            undoStorage[index] = SourceCanonicalCameraUndoRecord(
                identifier: record.identifier,
                player: record.player,
                camera: record.camera,
                isLive: false
            )
        }
        let removed = makeSnapshot(identity: identity, state: state)
        pendingReplication.append(.remove(removed))
        return removed
    }

    public func drainReplicationBatch()
        throws -> SourceCanonicalCameraReplicationBatch?
    {
        guard !pendingReplication.isEmpty else { return nil }
        guard nextReplicationSequence != UInt64.max else {
            throw SourceCanonicalCameraError.ticketSpaceExhausted
        }
        let batch = SourceCanonicalCameraReplicationBatch(
            sequence: nextReplicationSequence,
            operations: pendingReplication
        )
        nextReplicationSequence += 1
        pendingReplication.removeAll(keepingCapacity: true)
        return batch
    }

    private func deactivateOtherCamera(
        for player: SourceCanonicalEntityIdentity,
        except camera: SourceCanonicalEntityIdentity
    ) {
        for raw in cameraOrder where raw != camera.handle.rawValue {
            guard var state = statesByHandle[raw],
                  state.usingPlayer == player else { continue }
            state.isOn = false
            state.usingPlayer = nil
            state.revision &+= 1
            statesByHandle[raw] = state
            let identity = SourceCanonicalEntityIdentity(
                handle: SourceBaseHandle.unsafeFromIndex(raw)
            )
            pendingReplication.append(.update(makeSnapshot(
                identity: identity,
                state: state
            )))
        }
    }

    private func firstFreeNetworkableEntryIndex() throws -> Int {
        for index in 1..<SourceEntityConstants.maxEdicts
            where entityList.entity(at: index) == nil {
            return index
        }
        throw SourceCanonicalCameraError.noFreeNetworkableSlot
    }

    private func isLiveCanonicalPlayer(
        _ identity: SourceCanonicalEntityIdentity
    ) -> Bool {
        guard let entity = entityList.entity(for: identity.handle) as?
                SourceCanonicalEntity else { return false }
        return entity.kind == .player &&
            entity.lifecycle != .pendingRemoval &&
            entity.lifecycle != .removed
    }

    private func makeSnapshot(
        identity: SourceCanonicalEntityIdentity,
        state: SourceCanonicalCameraMutableState
    ) -> SourceCanonicalCameraSnapshot {
        SourceCanonicalCameraSnapshot(
            identity: identity,
            lifecycle: state.lifecycle,
            revision: state.revision,
            transform: state.transform,
            owner: state.owner,
            controlKey: state.controlKey,
            locked: state.locked,
            toggle: state.toggle,
            isOn: state.isOn,
            usingPlayer: state.usingPlayer,
            trackingEntity: state.trackingEntity,
            trackingLocalPosition: state.trackingLocalPosition,
            moveType: state.moveType,
            solidType: state.solidType,
            collisionGroup: state.collisionGroup
        )
    }

    private static func identityOrder(
        _ lhs: SourceCanonicalEntityIdentity,
        _ rhs: SourceCanonicalEntityIdentity
    ) -> Bool {
        lhs.handle.rawValue < rhs.handle.rawValue
    }
}

/// CLIENT-owned immutable projection fed only by ordered SERVER batches.
public final class SourceCanonicalCameraClientProjection {
    private var nextSequence: UInt64 = 1
    private var snapshotsByHandle: [UInt32: SourceCanonicalCameraSnapshot] = [:]
    private var handleByEntry: [Int: UInt32] = [:]

    public init() {}

    public var snapshots: [SourceCanonicalCameraSnapshot] {
        snapshotsByHandle.values.sorted {
            $0.identity.handle.rawValue < $1.identity.handle.rawValue
        }
    }

    public func snapshot(
        for identity: SourceCanonicalEntityIdentity
    ) -> SourceCanonicalCameraSnapshot? {
        snapshotsByHandle[identity.handle.rawValue]
    }

    public func apply(
        _ batch: SourceCanonicalCameraReplicationBatch
    ) throws {
        guard batch.sequence == nextSequence else {
            throw SourceCanonicalCameraError.replicationSequence(
                expected: nextSequence,
                actual: batch.sequence
            )
        }
        var nextByHandle = snapshotsByHandle
        var nextByEntry = handleByEntry
        for operation in batch.operations {
            switch operation {
            case let .create(snapshot):
                let entry = snapshot.identity.entryIndex
                if let occupied = nextByEntry[entry],
                   occupied != snapshot.identity.handle.rawValue {
                    throw SourceCanonicalCameraError.replicationSlotOccupied(
                        entry
                    )
                }
                nextByHandle[snapshot.identity.handle.rawValue] = snapshot
                nextByEntry[entry] = snapshot.identity.handle.rawValue
            case let .update(snapshot):
                guard let previous = nextByHandle[
                    snapshot.identity.handle.rawValue
                ] else {
                    throw SourceCanonicalCameraError
                        .replicationIdentityMismatch(snapshot.identity)
                }
                let expected = previous.revision &+ 1
                guard snapshot.revision == expected else {
                    throw SourceCanonicalCameraError.replicationRevision(
                        expected: expected,
                        actual: snapshot.revision
                    )
                }
                nextByHandle[snapshot.identity.handle.rawValue] = snapshot
            case let .remove(snapshot):
                guard let previous = nextByHandle[
                    snapshot.identity.handle.rawValue
                ], previous.identity == snapshot.identity else {
                    throw SourceCanonicalCameraError
                        .replicationIdentityMismatch(snapshot.identity)
                }
                let expected = previous.revision &+ 1
                guard snapshot.revision == expected else {
                    throw SourceCanonicalCameraError.replicationRevision(
                        expected: expected,
                        actual: snapshot.revision
                    )
                }
                nextByHandle.removeValue(
                    forKey: snapshot.identity.handle.rawValue
                )
                nextByEntry.removeValue(forKey: snapshot.identity.entryIndex)
            }
        }
        snapshotsByHandle = nextByHandle
        handleByEntry = nextByEntry
        nextSequence &+= 1
    }

    public func activeView(
        for player: SourceCanonicalEntityIdentity,
        target: (
            SourceCanonicalEntityIdentity
        ) -> SourceCanonicalCameraTrackingTargetSnapshot?
    ) -> SourceCanonicalCameraViewSnapshot? {
        guard let camera = snapshots.first(where: {
            $0.usingPlayer == player && $0.isOn
        }) else { return nil }
        var angles = camera.transform.angles
        if let trackingIdentity = camera.trackingEntity,
           let tracked = target(trackingIdentity) {
            var position = tracked.transform.transformPointFromLocal(
                camera.trackingLocalPosition
            )
            if tracked.isPlayer {
                position += tracked.playerViewOffset * 0.85
            }
            let direction = position - camera.transform.origin
            if direction.lengthSquared > 0 {
                let horizontal = (direction.x * direction.x +
                    direction.y * direction.y).squareRoot()
                let radiansToDegrees = Float(180) / Float.pi
                angles = SourceQAngle(
                    pitch: atan2(-direction.z, horizontal) *
                        radiansToDegrees,
                    yaw: atan2(direction.y, direction.x) *
                        radiansToDegrees,
                    roll: 0
                )
            }
        }
        return SourceCanonicalCameraViewSnapshot(
            camera: camera.identity,
            player: player,
            origin: camera.transform.origin,
            angles: angles,
            projectionOverrides: camera.projectionOverrides
        )
    }
}
