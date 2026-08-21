import Foundation

/// The first engine-owned entity classes being unified behind one
/// `SourceEntityList` and one EHANDLE lifetime contract.
///
/// The raw values are the canonical Source/GMod class names. A later GLua
/// adapter can therefore route `ents.Create("prop_physics")` without owning a
/// second class-name or lifetime registry.
public enum SourceCanonicalEntityKind: String, CaseIterable, Equatable, Hashable, Sendable {
    case world = "worldspawn"
    case player = "player"
    case propPhysics = "prop_physics"

    public var className: String { rawValue }
}

/// Engine-owned pose. Source simulation remains Float based; renderers may
/// convert a snapshot, but must not become the owner of these values.
public struct SourceEntityTransform: Equatable, Sendable {
    public var origin: SourceVector3
    public var angles: SourceQAngle

    public init(origin: SourceVector3 = .zero, angles: SourceQAngle = .zero) {
        self.origin = origin
        self.angles = angles
    }

    public static let identity = SourceEntityTransform()

    fileprivate var isFinite: Bool {
        origin.x.isFinite && origin.y.isFinite && origin.z.isFinite &&
            angles.pitch.isFinite && angles.yaw.isFinite && angles.roll.isFinite
    }
}

/// Engine-owned motion state shared by Player movement and future rigid-body
/// entities. Position and view angles remain in ``SourceEntityTransform`` so
/// there is still exactly one authoritative pose.
public struct SourceEntityMotionState: Equatable, Sendable {
    public var linearVelocity: SourceVector3
    public var angularVelocity: SourceVector3
    public var baseVelocity: SourceVector3
    public var outputWishVelocity: SourceVector3
    public var isOnGround: Bool
    public var entityGravity: Float
    public var surfaceFriction: Float
    public var waterJumpTime: Float
    public var isAlive: Bool

    public init(
        linearVelocity: SourceVector3 = .zero,
        angularVelocity: SourceVector3 = .zero,
        baseVelocity: SourceVector3 = .zero,
        outputWishVelocity: SourceVector3 = .zero,
        isOnGround: Bool = false,
        entityGravity: Float = 0,
        surfaceFriction: Float = 1,
        waterJumpTime: Float = 0,
        isAlive: Bool = true
    ) {
        self.linearVelocity = linearVelocity
        self.angularVelocity = angularVelocity
        self.baseVelocity = baseVelocity
        self.outputWishVelocity = outputWishVelocity
        self.isOnGround = isOnGround
        self.entityGravity = entityGravity
        self.surfaceFriction = surfaceFriction
        self.waterJumpTime = waterJumpTime
        self.isAlive = isAlive
    }

    fileprivate var isFinite: Bool {
        Self.isFinite(linearVelocity) &&
            Self.isFinite(angularVelocity) &&
            Self.isFinite(baseVelocity) &&
            Self.isFinite(outputWishVelocity) &&
            entityGravity.isFinite &&
            surfaceFriction.isFinite && surfaceFriction >= 0 &&
            waterJumpTime.isFinite && waterJumpTime >= 0
    }

    private static func isFinite(_ vector: SourceVector3) -> Bool {
        vector.x.isFinite && vector.y.isFinite && vector.z.isFinite
    }
}

/// A requested Source model name, not proof that an MDL exists.
///
/// Existence is deliberately decided by `SourceCanonicalModelValidator`. This
/// keeps an unavailable filesystem/Studio implementation from being mistaken
/// for a valid prop model.
public struct SourceEntityModelReference: Equatable, Hashable, Sendable {
    public let path: String

    public init(_ path: String) {
        self.path = path
    }
}

/// Numeric `SolidType_t` values from Source SDK 2013 `const.h`.
public enum SourceEntitySolidType: UInt8, CaseIterable, Equatable, Sendable {
    case none = 0
    case bsp = 1
    case boundingBox = 2
    case orientedBoundingBox = 3
    case orientedBoundingBoxYaw = 4
    case custom = 5
    case vPhysics = 6
}

/// Explicit lifetime stages shared by world, Player, and prop entities.
public enum SourceCanonicalEntityLifecycle: UInt8, CaseIterable, Equatable, Sendable {
    case created
    case spawned
    case active
    case pendingRemoval
    case removed
}

/// Mutable state used by one atomic engine-owned update transaction.
///
/// Lifecycle and EHANDLE identity are intentionally absent. Callers may alter
/// gameplay state, while only `SourceCanonicalEntityStore` can transition
/// lifetime or generation.
public struct SourceCanonicalEntityState: Equatable, Sendable {
    public var transform: SourceEntityTransform
    public var motion: SourceEntityMotionState
    public var model: SourceEntityModelReference?
    public var solidType: SourceEntitySolidType
    public var moveType: SourceMoveType
    /// Studio skin-family selection. Range validation against the loaded MDL
    /// remains the responsibility of the real Studio asset boundary.
    public var skin: Int
    /// Source `m_nBody` value. Bodypart decomposition remains owned by the
    /// decoded MDL; this canonical value is not guessed from a submodel index.
    public var bodyValue: Int
    /// Local eye offset used by `CBasePlayer::EyePosition`/`GetShootPos`.
    /// Keeping this beside the authoritative origin avoids a Lua-owned eye
    /// position that can drift away from movement state.
    public var viewOffset: SourceVector3
    /// Full EHANDLE relationships. A nil vehicle is the truthful on-foot
    /// state; neither relationship is reduced to an entry index.
    public var vehicle: SourceCanonicalEntityIdentity?
    public var creator: SourceCanonicalEntityIdentity?

    public init(
        transform: SourceEntityTransform = .identity,
        motion: SourceEntityMotionState = SourceEntityMotionState(),
        model: SourceEntityModelReference? = nil,
        solidType: SourceEntitySolidType = .none,
        moveType: SourceMoveType = .none,
        skin: Int = 0,
        bodyValue: Int = 0,
        viewOffset: SourceVector3 = .zero,
        vehicle: SourceCanonicalEntityIdentity? = nil,
        creator: SourceCanonicalEntityIdentity? = nil
    ) {
        self.transform = transform
        self.motion = motion
        self.model = model
        self.solidType = solidType
        self.moveType = moveType
        self.skin = skin
        self.bodyValue = bodyValue
        self.viewOffset = viewOffset
        self.vehicle = vehicle
        self.creator = creator
    }

    /// Converts the canonical Player state into the existing movement core's
    /// value input without transferring ownership to the host session.
    public var playerWalkState: SourceWorldWalkState {
        SourceWorldWalkState(
            movement: SourceMoveData(
                origin: transform.origin,
                velocity: motion.linearVelocity,
                baseVelocity: motion.baseVelocity,
                outputWishVelocity: motion.outputWishVelocity,
                isOnGround: motion.isOnGround,
                entityGravity: motion.entityGravity,
                surfaceFriction: motion.surfaceFriction,
                waterJumpTime: motion.waterJumpTime,
                isDead: !motion.isAlive
            ),
            viewAngles: transform.angles,
            moveType: moveType
        )
    }

    /// Commits one completed movement tick back into the canonical entity
    /// candidate. The enclosing store transaction performs validation before
    /// this state becomes visible.
    public mutating func applyPlayerWalkState(_ walkState: SourceWorldWalkState) {
        transform.origin = walkState.movement.origin
        transform.angles = walkState.viewAngles
        motion.linearVelocity = walkState.movement.velocity
        motion.baseVelocity = walkState.movement.baseVelocity
        motion.outputWishVelocity = walkState.movement.outputWishVelocity
        motion.isOnGround = walkState.movement.isOnGround
        motion.entityGravity = walkState.movement.entityGravity
        motion.surfaceFriction = walkState.movement.surfaceFriction
        motion.waterJumpTime = walkState.movement.waterJumpTime
        motion.isAlive = !walkState.movement.isDead
        moveType = walkState.moveType
    }

    public static func defaults(for kind: SourceCanonicalEntityKind) -> Self {
        switch kind {
        case .world:
            return Self(
                model: SourceEntityModelReference("*0"),
                solidType: .bsp,
                moveType: .none
            )
        case .player:
            // Source SDK's standing VEC_VIEW is 64 units above the player
            // origin. Ducking can later authoritatively change this value.
            return Self(
                solidType: .boundingBox,
                moveType: .walk,
                viewOffset: SourceVector3(0, 0, 64)
            )
        case .propPhysics:
            return Self(solidType: .vPhysics, moveType: .vPhysics)
        }
    }
}

/// Stable Source identity. `generation` is the complete packed EHANDLE value;
/// `serialNumber` exposes the slot generation without inventing another ID.
public struct SourceCanonicalEntityIdentity: Equatable, Hashable, Sendable {
    public let handle: SourceBaseHandle

    public init(handle: SourceBaseHandle) {
        precondition(handle.isValid, "canonical entity identity requires a valid EHANDLE")
        self.handle = handle
    }

    public var entryIndex: Int { handle.entryIndex }
    /// Compatibility spelling used by the existing GLua Entity registry.
    public var index: Int { entryIndex }
    public var serialNumber: Int { handle.serialNumber }
    public var generation: UInt64 { UInt64(handle.rawValue) }
}

/// Legacy API spelling retained while Runtime/Registry call sites migrate.
/// Both names now denote the same full Source EHANDLE identity.
public typealias GMLuaSourceEntityIdentity = SourceCanonicalEntityIdentity

/// Immutable handoff shared by Lua replication and Metal model rendering.
///
/// The renderer and realm registries consume this value; neither receives a
/// mutable entity reference or owns entity lifetime.
public struct SourceCanonicalEntitySnapshot: Equatable, Sendable {
    public let identity: SourceCanonicalEntityIdentity
    public let kind: SourceCanonicalEntityKind
    public let className: String
    public let transform: SourceEntityTransform
    public let motion: SourceEntityMotionState
    public let model: SourceEntityModelReference?
    public let solidType: SourceEntitySolidType
    public let moveType: SourceMoveType
    public let skin: Int
    public let bodyValue: Int
    public let viewOffset: SourceVector3
    public let vehicle: SourceCanonicalEntityIdentity?
    public let creator: SourceCanonicalEntityIdentity?
    public let lifecycle: SourceCanonicalEntityLifecycle
    public let isNetworkable: Bool
    public let revision: UInt64

    public init(
        identity: SourceCanonicalEntityIdentity,
        kind: SourceCanonicalEntityKind,
        className: String,
        transform: SourceEntityTransform,
        motion: SourceEntityMotionState,
        model: SourceEntityModelReference?,
        solidType: SourceEntitySolidType,
        moveType: SourceMoveType,
        lifecycle: SourceCanonicalEntityLifecycle,
        isNetworkable: Bool,
        revision: UInt64,
        skin: Int = 0,
        bodyValue: Int = 0,
        viewOffset: SourceVector3 = .zero,
        vehicle: SourceCanonicalEntityIdentity? = nil,
        creator: SourceCanonicalEntityIdentity? = nil
    ) {
        self.identity = identity
        self.kind = kind
        self.className = className
        self.transform = transform
        self.motion = motion
        self.model = model
        self.solidType = solidType
        self.moveType = moveType
        self.skin = skin
        self.bodyValue = bodyValue
        self.viewOffset = viewOffset
        self.vehicle = vehicle
        self.creator = creator
        self.lifecycle = lifecycle
        self.isNetworkable = isNetworkable
        self.revision = revision
    }
}

/// Result of the real filesystem/Studio validation boundary.
public enum SourceCanonicalModelValidation: Equatable, Sendable {
    case valid
    case invalid
    case unavailable
}

public typealias SourceCanonicalModelValidator = (
    _ model: SourceEntityModelReference,
    _ kind: SourceCanonicalEntityKind
) -> SourceCanonicalModelValidation

/// Resolves GLua body-group selections against one already validated Studio
/// model. The Engine owns the atomic entity-state transaction while the host
/// supplies filesystem-backed model metadata; omission never implies a
/// permissive fallback.
public typealias SourceCanonicalBodyGroupResolver = (
    _ model: SourceEntityModelReference,
    _ subModelIDs: String,
    _ currentBodyValue: Int
) throws -> Int

public enum SourceCanonicalEntityError: Error, Equatable, CustomStringConvertible {
    case entityList(SourceEntityListError)
    case noFreeNetworkableSlot
    case unknownEntity(SourceCanonicalEntityIdentity)
    case invalidWorldEntryIndex(Int)
    case invalidTransform
    case invalidMotion
    case invalidSkin(Int)
    case invalidBodyValue(Int)
    case invalidModelPath(String)
    case modelRequired(SourceCanonicalEntityKind)
    case modelValidationUnavailable(SourceEntityModelReference)
    case modelRejected(SourceEntityModelReference)
    case invalidLifecycleTransition(
        from: SourceCanonicalEntityLifecycle,
        to: SourceCanonicalEntityLifecycle
    )

    public var description: String {
        switch self {
        case let .entityList(error):
            return "Source entity list rejected the transaction: \(error)"
        case .noFreeNetworkableSlot:
            return "no free networkable Source entity slot is available"
        case let .unknownEntity(identity):
            return "Source entity EHANDLE \(identity.handle.rawValue) is stale or unknown"
        case let .invalidWorldEntryIndex(index):
            return "worldspawn must use Source entity index 0, got \(index)"
        case .invalidTransform:
            return "Source entity transform contains a non-finite component"
        case .invalidMotion:
            return "Source entity motion contains a non-finite or invalid component"
        case let .invalidSkin(skin):
            return "Source entity Studio skin index is invalid: \(skin)"
        case let .invalidBodyValue(value):
            return "Source entity Studio body value is invalid: \(value)"
        case let .invalidModelPath(path):
            return "Source entity model path is structurally invalid: \(path)"
        case let .modelRequired(kind):
            return "\(kind.className) requires a model before Spawn"
        case let .modelValidationUnavailable(model):
            return "model validation is unavailable for \(model.path)"
        case let .modelRejected(model):
            return "model validation rejected \(model.path)"
        case let .invalidLifecycleTransition(from, to):
            return "invalid Source entity lifecycle transition \(from) -> \(to)"
        }
    }
}

/// One canonical engine entity type for world, Player, and prop state.
///
/// State setters are fileprivate so GLua, Metal, and App code cannot establish
/// competing mirrors. They receive `snapshot` values instead.
public final class SourceCanonicalEntity: SourceEntity {
    public let kind: SourceCanonicalEntityKind

    private var stateStorage: SourceCanonicalEntityState
    public fileprivate(set) var lifecycle: SourceCanonicalEntityLifecycle
    public fileprivate(set) var revision: UInt64

    fileprivate init(
        kind: SourceCanonicalEntityKind,
        state: SourceCanonicalEntityState,
        lifecycle: SourceCanonicalEntityLifecycle = .created,
        revision: UInt64 = 0
    ) {
        self.kind = kind
        stateStorage = state
        self.lifecycle = lifecycle
        self.revision = revision
        super.init(className: kind.className)
    }

    public var state: SourceCanonicalEntityState { stateStorage }

    public var snapshot: SourceCanonicalEntitySnapshot? {
        guard refHandle.isValid else { return nil }
        return makeSnapshot(identity: SourceCanonicalEntityIdentity(handle: refHandle))
    }

    fileprivate func commit(_ state: SourceCanonicalEntityState) {
        stateStorage = state
        revision &+= 1
    }

    fileprivate func transition(to lifecycle: SourceCanonicalEntityLifecycle) {
        self.lifecycle = lifecycle
        revision &+= 1
    }

    fileprivate func makeSnapshot(
        identity: SourceCanonicalEntityIdentity,
        state overrideState: SourceCanonicalEntityState? = nil,
        lifecycle overrideLifecycle: SourceCanonicalEntityLifecycle? = nil,
        revision overrideRevision: UInt64? = nil
    ) -> SourceCanonicalEntitySnapshot {
        let state = overrideState ?? stateStorage
        return SourceCanonicalEntitySnapshot(
            identity: identity,
            kind: kind,
            className: className,
            transform: state.transform,
            motion: state.motion,
            model: state.model,
            solidType: state.solidType,
            moveType: state.moveType,
            lifecycle: overrideLifecycle ?? lifecycle,
            isNetworkable: true,
            revision: overrideRevision ?? revision,
            skin: state.skin,
            bodyValue: state.bodyValue,
            viewOffset: state.viewOffset,
            vehicle: state.vehicle,
            creator: state.creator
        )
    }
}

/// Owns canonical gameplay state while reusing SourceEntityList's exact slot,
/// serial, think, and deferred-destruction behavior.
///
/// This class intentionally has no realm, renderer, or transport dependency.
/// A later adapter may enqueue its snapshots into the same host FIFO as net and
/// console delivery without restoring direct realm mirrors.
public final class SourceCanonicalEntityStore {
    public let entityList: SourceEntityList

    private let modelValidator: SourceCanonicalModelValidator
    private var entitiesByHandle: [UInt32: SourceCanonicalEntity] = [:]
    private var handleOrder: [UInt32] = []

    public init(
        entityList: SourceEntityList = SourceEntityList(),
        modelValidator: SourceCanonicalModelValidator? = nil
    ) {
        self.entityList = entityList
        self.modelValidator = modelValidator ?? { _, _ in .unavailable }
    }

    public var count: Int { entitiesByHandle.count }

    /// Consults the injected filesystem/Studio boundary without manufacturing
    /// success when that boundary is absent. Structural path rejection is also
    /// reported as invalid, before any asset lookup occurs.
    public func validateModel(
        _ model: SourceEntityModelReference,
        for kind: SourceCanonicalEntityKind
    ) -> SourceCanonicalModelValidation {
        do {
            try validateModelPath(model, kind: kind)
        } catch {
            return .invalid
        }
        return modelValidator(model, kind)
    }

    /// Creates a networkable canonical entity. All validation occurs before the
    /// Source slot is touched, and SourceEntityList itself performs the final
    /// atomic occupied/generation check.
    @discardableResult
    public func create(
        kind: SourceCanonicalEntityKind,
        at requestedEntryIndex: Int? = nil,
        state requestedState: SourceCanonicalEntityState? = nil
    ) throws -> SourceCanonicalEntitySnapshot {
        try create(
            kind: kind,
            at: requestedEntryIndex,
            state: requestedState,
            publishing: { _ in }
        )
    }

    /// Publishes the immutable creation snapshot before the new entity becomes
    /// part of this store. A failed publisher rolls back only the exact fresh
    /// EHANDLE and advances its slot serial, leaving every deferred deletion
    /// and removal callback untouched.
    @discardableResult
    func create(
        kind: SourceCanonicalEntityKind,
        at requestedEntryIndex: Int? = nil,
        state requestedState: SourceCanonicalEntityState? = nil,
        publishing publish: (SourceCanonicalEntitySnapshot) throws -> Void
    ) throws -> SourceCanonicalEntitySnapshot {
        let entryIndex = try resolveEntryIndex(for: kind, requested: requestedEntryIndex)
        let state = requestedState ?? .defaults(for: kind)
        try validate(state: state, kind: kind, lifecycle: .created)

        let entity = SourceCanonicalEntity(kind: kind, state: state)
        let handle: SourceBaseHandle
        do {
            handle = try entityList.addNetworkableEntity(entity, at: entryIndex)
        } catch let error as SourceEntityListError {
            throw SourceCanonicalEntityError.entityList(error)
        }

        let identity = SourceCanonicalEntityIdentity(handle: handle)
        let snapshot = entity.makeSnapshot(identity: identity)
        do {
            try publish(snapshot)
        } catch {
            precondition(
                entityList.rollbackUnpublishedAddition(handle, entity: entity),
                "fresh canonical entity rollback lost its exact EHANDLE"
            )
            throw error
        }

        entitiesByHandle[handle.rawValue] = entity
        handleOrder.append(handle.rawValue)
        return snapshot
    }

    public func entity(
        for identity: SourceCanonicalEntityIdentity
    ) -> SourceCanonicalEntity? {
        guard let entity = entitiesByHandle[identity.handle.rawValue],
              entityList.entity(for: identity.handle) === entity else { return nil }
        return entity
    }

    public func snapshot(
        for identity: SourceCanonicalEntityIdentity
    ) -> SourceCanonicalEntitySnapshot? {
        entity(for: identity)?.snapshot
    }

    /// Stable creation order for initial CLIENT replication. Entities already
    /// queued for deferred removal are omitted: a newly attached CLIENT must
    /// never observe a create packet whose lifecycle the replication protocol
    /// rejects. Their existing realms retain the EHANDLE until cleanup emits
    /// the final removed snapshot.
    public var orderedSnapshots: [SourceCanonicalEntitySnapshot] {
        handleOrder.compactMap { rawHandle in
            guard let snapshot = entitiesByHandle[rawHandle]?.snapshot,
                  snapshot.lifecycle != .pendingRemoval,
                  snapshot.lifecycle != .removed else { return nil }
            return snapshot
        }
    }

    /// Applies gameplay state as a copy/validate/commit transaction. A thrown
    /// body or failed validation leaves all entity state and revision unchanged.
    @discardableResult
    public func update(
        _ identity: SourceCanonicalEntityIdentity,
        _ mutation: (inout SourceCanonicalEntityState) throws -> Void
    ) throws -> SourceCanonicalEntitySnapshot {
        try update(identity, mutation, publishing: { _ in })
    }

    /// Validates and publishes a prospective snapshot before committing its
    /// state. A throwing publisher therefore leaves state and revision exact.
    @discardableResult
    func update(
        _ identity: SourceCanonicalEntityIdentity,
        _ mutation: (inout SourceCanonicalEntityState) throws -> Void,
        publishing publish: (SourceCanonicalEntitySnapshot) throws -> Void
    ) throws -> SourceCanonicalEntitySnapshot {
        let entity = try requireEntity(identity)
        guard entity.lifecycle != .pendingRemoval, entity.lifecycle != .removed else {
            throw SourceCanonicalEntityError.invalidLifecycleTransition(
                from: entity.lifecycle,
                to: entity.lifecycle
            )
        }

        var candidate = entity.state
        try mutation(&candidate)
        try validate(state: candidate, kind: entity.kind, lifecycle: entity.lifecycle)
        let snapshot = entity.makeSnapshot(
            identity: identity,
            state: candidate,
            revision: entity.revision &+ 1
        )
        try publish(snapshot)
        entity.commit(candidate)
        return snapshot
    }

    /// Mirrors `DispatchSpawn`: a prop cannot cross this boundary until a real
    /// filesystem/Studio validator confirms its MDL.
    @discardableResult
    public func spawn(
        _ identity: SourceCanonicalEntityIdentity
    ) throws -> SourceCanonicalEntitySnapshot {
        try spawn(identity, publishing: { _ in })
    }

    @discardableResult
    func spawn(
        _ identity: SourceCanonicalEntityIdentity,
        publishing publish: (SourceCanonicalEntitySnapshot) throws -> Void
    ) throws -> SourceCanonicalEntitySnapshot {
        let entity = try requireEntity(identity)
        guard entity.lifecycle == .created else {
            throw SourceCanonicalEntityError.invalidLifecycleTransition(
                from: entity.lifecycle,
                to: .spawned
            )
        }
        try validate(state: entity.state, kind: entity.kind, lifecycle: .spawned)
        let snapshot = entity.makeSnapshot(
            identity: identity,
            lifecycle: .spawned,
            revision: entity.revision &+ 1
        )
        try publish(snapshot)
        entity.transition(to: .spawned)
        return snapshot
    }

    @discardableResult
    public func activate(
        _ identity: SourceCanonicalEntityIdentity
    ) throws -> SourceCanonicalEntitySnapshot {
        try activate(identity, publishing: { _ in })
    }

    @discardableResult
    func activate(
        _ identity: SourceCanonicalEntityIdentity,
        publishing publish: (SourceCanonicalEntitySnapshot) throws -> Void
    ) throws -> SourceCanonicalEntitySnapshot {
        let entity = try requireEntity(identity)
        guard entity.lifecycle == .spawned else {
            throw SourceCanonicalEntityError.invalidLifecycleTransition(
                from: entity.lifecycle,
                to: .active
            )
        }
        let snapshot = entity.makeSnapshot(
            identity: identity,
            lifecycle: .active,
            revision: entity.revision &+ 1
        )
        try publish(snapshot)
        entity.transition(to: .active)
        return snapshot
    }

    /// UTIL_Remove-compatible scheduling. The EHANDLE and snapshots remain
    /// resolvable until SourceEntityList reaches an actual cleanup boundary.
    @discardableResult
    public func markForRemoval(
        _ identity: SourceCanonicalEntityIdentity
    ) throws -> SourceCanonicalEntitySnapshot {
        try markForRemoval(identity, publishing: { _ in })
    }

    @discardableResult
    func markForRemoval(
        _ identity: SourceCanonicalEntityIdentity,
        publishing publish: (SourceCanonicalEntitySnapshot) throws -> Void
    ) throws -> SourceCanonicalEntitySnapshot {
        let entity = try requireEntity(identity)
        if entity.lifecycle == .pendingRemoval {
            let snapshot = entity.makeSnapshot(identity: identity)
            try publish(snapshot)
            return snapshot
        }
        guard entity.lifecycle != .removed else {
            throw SourceCanonicalEntityError.invalidLifecycleTransition(
                from: .removed,
                to: .pendingRemoval
            )
        }
        let snapshot = entity.makeSnapshot(
            identity: identity,
            lifecycle: .pendingRemoval,
            revision: entity.revision &+ 1
        )
        try publish(snapshot)
        entity.transition(to: .pendingRemoval)
        entityList.markForDeletion(identity.handle)
        return snapshot
    }

    /// Reverses an `ents.Create` transaction that has not crossed Spawn. The
    /// exact full handle is removed immediately only after its published realm
    /// projection accepts the matching final removal snapshot. No unrelated
    /// deferred deletion is drained.
    @discardableResult
    public func rollbackCreated(
        _ identity: SourceCanonicalEntityIdentity
    ) throws -> SourceCanonicalEntitySnapshot {
        try rollbackCreated(identity, publishing: { _ in })
    }

    @discardableResult
    func rollbackCreated(
        _ identity: SourceCanonicalEntityIdentity,
        publishing publish: (SourceCanonicalEntitySnapshot) throws -> Void
    ) throws -> SourceCanonicalEntitySnapshot {
        let entity = try requireEntity(identity)
        guard entity.lifecycle == .created else {
            throw SourceCanonicalEntityError.invalidLifecycleTransition(
                from: entity.lifecycle,
                to: .removed
            )
        }
        let snapshot = entity.makeSnapshot(
            identity: identity,
            lifecycle: .removed,
            revision: entity.revision &+ 1
        )
        try publish(snapshot)
        precondition(
            entityList.rollbackUnpublishedAddition(identity.handle, entity: entity),
            "created canonical entity rollback lost its exact EHANDLE"
        )
        entity.transition(to: .removed)
        entitiesByHandle.removeValue(forKey: identity.handle.rawValue)
        if let index = handleOrder.firstIndex(of: identity.handle.rawValue) {
            handleOrder.remove(at: index)
        }
        return snapshot
    }

    /// Standalone cleanup boundary for dedicated tests and future hosts that do
    /// not yet use SourceRuntimeKernel. Integrated runtimes should call
    /// `didCleanup(capturedHandle:entity:)` from the kernel's removal callback.
    @discardableResult
    public func cleanupDeferredRemovals() -> [SourceCanonicalEntitySnapshot] {
        var removed: [SourceCanonicalEntitySnapshot] = []
        _ = entityList.cleanupDeleteList { [unowned self] handle, entity in
            if let snapshot = self.didCleanup(capturedHandle: handle, entity: entity) {
                removed.append(snapshot)
            }
        }
        return removed
    }

    /// Consumes the exact pre-invalidation handle reported by SourceEntityList.
    /// A stale callback cannot remove a later occupant of a reused slot.
    @discardableResult
    public func didCleanup(
        capturedHandle: SourceBaseHandle,
        entity removedEntity: SourceEntity
    ) -> SourceCanonicalEntitySnapshot? {
        guard let entity = entitiesByHandle[capturedHandle.rawValue],
              entity === removedEntity else { return nil }
        let identity = SourceCanonicalEntityIdentity(handle: capturedHandle)
        let removedRevision = entity.revision &+ 1
        entity.transition(to: .removed)
        entitiesByHandle.removeValue(forKey: capturedHandle.rawValue)
        if let index = handleOrder.firstIndex(of: capturedHandle.rawValue) {
            handleOrder.remove(at: index)
        }
        return entity.makeSnapshot(
            identity: identity,
            lifecycle: .removed,
            revision: removedRevision
        )
    }

    private func resolveEntryIndex(
        for kind: SourceCanonicalEntityKind,
        requested: Int?
    ) throws -> Int {
        if kind == .world {
            let entryIndex = requested ?? 0
            guard entryIndex == 0 else {
                throw SourceCanonicalEntityError.invalidWorldEntryIndex(entryIndex)
            }
            return entryIndex
        }

        if let requested { return requested }
        for entryIndex in 1..<SourceEntityConstants.maxEdicts
            where entityList.entity(at: entryIndex) == nil {
            return entryIndex
        }
        throw SourceCanonicalEntityError.noFreeNetworkableSlot
    }

    private func requireEntity(
        _ identity: SourceCanonicalEntityIdentity
    ) throws -> SourceCanonicalEntity {
        guard let entity = entity(for: identity) else {
            throw SourceCanonicalEntityError.unknownEntity(identity)
        }
        return entity
    }

    private func validate(
        state: SourceCanonicalEntityState,
        kind: SourceCanonicalEntityKind,
        lifecycle: SourceCanonicalEntityLifecycle
    ) throws {
        guard state.transform.isFinite else {
            throw SourceCanonicalEntityError.invalidTransform
        }
        guard state.motion.isFinite else {
            throw SourceCanonicalEntityError.invalidMotion
        }
        guard state.skin >= 0, state.skin <= Int(Int32.max) else {
            throw SourceCanonicalEntityError.invalidSkin(state.skin)
        }
        guard state.bodyValue >= 0, state.bodyValue <= Int(Int32.max) else {
            throw SourceCanonicalEntityError.invalidBodyValue(state.bodyValue)
        }
        guard state.viewOffset.x.isFinite,
              state.viewOffset.y.isFinite,
              state.viewOffset.z.isFinite else {
            throw SourceCanonicalEntityError.invalidTransform
        }

        for relationship in [state.vehicle, state.creator].compactMap({ $0 }) {
            guard entity(for: relationship) != nil else {
                throw SourceCanonicalEntityError.unknownEntity(relationship)
            }
        }

        if let model = state.model {
            try validateModelPath(model, kind: kind)
        }

        guard lifecycle == .spawned || lifecycle == .active else { return }
        if kind == .propPhysics {
            guard let model = state.model else {
                throw SourceCanonicalEntityError.modelRequired(kind)
            }
            switch validateModel(model, for: kind) {
            case .valid:
                break
            case .invalid:
                throw SourceCanonicalEntityError.modelRejected(model)
            case .unavailable:
                throw SourceCanonicalEntityError.modelValidationUnavailable(model)
            }
        }
    }

    private func validateModelPath(
        _ model: SourceEntityModelReference,
        kind: SourceCanonicalEntityKind
    ) throws {
        let path = model.path
        let lowercased = path.lowercased()
        let hasForbiddenComponent = path.isEmpty ||
            path.utf8.count >= 260 ||
            path.contains("\\") ||
            path.contains(":") ||
            path.contains("\0") ||
            path.split(separator: "/", omittingEmptySubsequences: false).contains("..")

        if kind == .world, path == "*0" { return }
        guard !hasForbiddenComponent,
              lowercased.hasPrefix("models/"),
              lowercased.hasSuffix(".mdl") else {
            throw SourceCanonicalEntityError.invalidModelPath(path)
        }
    }
}
