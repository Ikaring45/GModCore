import Foundation

/// Stock Sandbox sends these button numbers to `GM:CanTool` for the
/// No-Collide stool.
public enum SourceCanonicalNoCollideToolAction:
    UInt8,
    Equatable,
    Sendable
{
    case leftClick = 1
    case rightClick = 2
    case reload = 3
}

/// Source 2013's public collision-group values used verbatim by the bundled
/// stool's right-click toggle.
public enum SourceCanonicalNoCollideCollisionGroup {
    public static let none: Int32 = 0
    public static let world: Int32 = 20
}

/// The authoritative trace fields retained by the two-click selection. The
/// complete target EHANDLE and solid index become a `SourcePhysicsBodyID`;
/// hit data is retained because the stock stool keeps it in `SetObject` even
/// though `constraint.NoCollide` itself does not consume an anchor.
public struct SourceCanonicalNoCollideToolTrace: Equatable, Sendable {
    public let target: SourceCanonicalEntityIdentity
    public let hitPosition: SourceVector3
    public let hitNormal: SourceVector3
    public let physicsBone: Int

    public init(
        target: SourceCanonicalEntityIdentity,
        hitPosition: SourceVector3 = .zero,
        hitNormal: SourceVector3 = .zero,
        physicsBone: Int = 0
    ) {
        self.target = target
        self.hitPosition = hitPosition
        self.hitNormal = hitNormal
        self.physicsBone = physicsBone
    }
}

public struct SourceCanonicalNoCollideCanToolRequest:
    Equatable,
    Sendable
{
    public let actor: SourceCanonicalEntitySnapshot
    public let target: SourceCanonicalEntitySnapshot
    public let trace: SourceCanonicalNoCollideToolTrace
    public let mode: String
    public let action: SourceCanonicalNoCollideToolAction

    public init(
        actor: SourceCanonicalEntitySnapshot,
        target: SourceCanonicalEntitySnapshot,
        trace: SourceCanonicalNoCollideToolTrace,
        mode: String = "nocollide",
        action: SourceCanonicalNoCollideToolAction
    ) {
        self.actor = actor
        self.target = target
        self.trace = trace
        self.mode = mode
        self.action = action
    }
}

public typealias SourceCanonicalNoCollideCanTool =
    (SourceCanonicalNoCollideCanToolRequest) throws -> Bool

/// `Player:CheckLimit("constraints")` is configurable game state. It is a
/// required host callback instead of an inferred constant or an always-true
/// compatibility shim.
public typealias SourceCanonicalNoCollideConstraintLimitGate =
    (_ actor: SourceCanonicalEntitySnapshot) throws -> Bool

/// Narrow entity mutation surface used by the stool. The concrete runtime
/// adapter already satisfies every operation and keeps all mutations in its
/// authoritative Entity journal.
public protocol SourceCanonicalNoCollideEntityHost: AnyObject {
    func canonicalSnapshot(
        for identity: SourceCanonicalEntityIdentity
    ) -> SourceCanonicalEntitySnapshot?

    func createCanonicalEntity(
        kind: SourceCanonicalEntityKind,
        at entryIndex: Int?,
        state: SourceCanonicalEntityState?,
        playerUserID: Int?
    ) throws -> SourceCanonicalEntitySnapshot

    func updateCanonicalEntity(
        _ identity: SourceCanonicalEntityIdentity,
        _ mutation: (inout SourceCanonicalEntityState) throws -> Void
    ) throws -> SourceCanonicalEntitySnapshot

    func spawnCanonicalEntity(
        _ identity: SourceCanonicalEntityIdentity
    ) throws -> SourceCanonicalEntitySnapshot

    func activateCanonicalEntity(
        _ identity: SourceCanonicalEntityIdentity
    ) throws -> SourceCanonicalEntitySnapshot

    func markCanonicalEntityForRemoval(
        _ identity: SourceCanonicalEntityIdentity
    ) throws -> SourceCanonicalEntitySnapshot

    @discardableResult
    func rollbackUnpublishedCanonicalEntity(
        _ identity: SourceCanonicalEntityIdentity
    ) throws -> SourceCanonicalEntitySnapshot
}

extension GMLuaSourceRuntimeAdapter: SourceCanonicalNoCollideEntityHost {}

/// Exact-body availability gate corresponding to
/// `util.IsValidPhysicsObject(entity, bone)`. Implementations must resolve the
/// complete body ID; an entry index alone is insufficient after slot reuse.
public protocol SourceCanonicalNoCollidePhysicsHost: AnyObject {
    func containsCanonicalNoCollidePhysicsBody(
        _ bodyID: SourcePhysicsBodyID
    ) -> Bool
}

extension GMLuaSourceRuntimeAdapter: SourceCanonicalNoCollidePhysicsHost {
    public func containsCanonicalNoCollidePhysicsBody(
        _ bodyID: SourcePhysicsBodyID
    ) -> Bool {
        canonicalPhysicsObject(for: bodyID)?.bodyID == bodyID
    }
}

public struct SourceCanonicalNoCollideEndpoint: Equatable, Sendable {
    public let entity: SourceCanonicalEntityIdentity
    public let bodyID: SourcePhysicsBodyID
    public let hitPosition: SourceVector3
    public let hitNormal: SourceVector3

    public init(
        entity: SourceCanonicalEntityIdentity,
        bodyID: SourcePhysicsBodyID,
        hitPosition: SourceVector3,
        hitNormal: SourceVector3
    ) {
        self.entity = entity
        self.bodyID = bodyID
        self.hitPosition = hitPosition
        self.hitNormal = hitNormal
    }
}

/// One live engine-owned `logic_collision_pair` equivalent. The generic
/// canonical constraint Entity provides EHANDLE/lifecycle/replication while
/// the typed physics constraint owns actual pair suppression.
public struct SourceCanonicalNoCollideBinding: Equatable, Sendable {
    public let graphRecord: SourceCanonicalConstraintRecord
    public let constraintEntity: SourceCanonicalEntityIdentity
    public let owner: SourceCanonicalEntityIdentity
    public let first: SourceCanonicalNoCollideEndpoint
    public let second: SourceCanonicalNoCollideEndpoint
    public let creationCommand:
        SourcePhysicsNoCollideConstraintCreationCommand
    public let creationSequence: UInt64
    public let disableOnRemove: Bool

    public init(
        graphRecord: SourceCanonicalConstraintRecord,
        constraintEntity: SourceCanonicalEntityIdentity,
        owner: SourceCanonicalEntityIdentity,
        first: SourceCanonicalNoCollideEndpoint,
        second: SourceCanonicalNoCollideEndpoint,
        creationCommand: SourcePhysicsNoCollideConstraintCreationCommand,
        creationSequence: UInt64,
        disableOnRemove: Bool = true
    ) {
        self.graphRecord = graphRecord
        self.constraintEntity = constraintEntity
        self.owner = owner
        self.first = first
        self.second = second
        self.creationCommand = creationCommand
        self.creationSequence = creationSequence
        self.disableOnRemove = disableOnRemove
    }

    public var constraintID: SourcePhysicsConstraintID {
        creationCommand.constraintID
    }
}

public struct SourceCanonicalNoCollideUndoRecord: Equatable, Sendable {
    public let identifier: UInt64
    public let name: String
    public let customUndoText: String
    public let player: SourceCanonicalEntityIdentity
    public let constraintEntity: SourceCanonicalEntityIdentity
    public let isLive: Bool

    public init(
        identifier: UInt64,
        player: SourceCanonicalEntityIdentity,
        constraintEntity: SourceCanonicalEntityIdentity,
        isLive: Bool
    ) {
        self.identifier = identifier
        name = "NoCollide"
        customUndoText = "Undone #tool.nocollide.name"
        self.player = player
        self.constraintEntity = constraintEntity
        self.isLive = isLive
    }
}

public struct SourceCanonicalNoCollideCreationResult:
    Equatable,
    Sendable
{
    public let binding: SourceCanonicalNoCollideBinding
    public let constraintEntity: SourceCanonicalEntitySnapshot
    public let undo: SourceCanonicalNoCollideUndoRecord
    public let countCategory: String
    public let cleanupCategory: String

    public init(
        binding: SourceCanonicalNoCollideBinding,
        constraintEntity: SourceCanonicalEntitySnapshot,
        undo: SourceCanonicalNoCollideUndoRecord
    ) {
        self.binding = binding
        self.constraintEntity = constraintEntity
        self.undo = undo
        countCategory = "constraints"
        cleanupCategory = "nocollide"
    }
}

public struct SourceCanonicalNoCollideRemovalResult:
    Equatable,
    Sendable
{
    public let bindings: [SourceCanonicalNoCollideBinding]
    public let deletionCommands: [SourcePhysicsCommand]
    public let constraintEntitiesMarkedForRemoval:
        [SourceCanonicalEntityIdentity]

    public init(
        bindings: [SourceCanonicalNoCollideBinding],
        deletionCommands: [SourcePhysicsCommand],
        constraintEntitiesMarkedForRemoval:
            [SourceCanonicalEntityIdentity]
    ) {
        self.bindings = bindings
        self.deletionCommands = deletionCommands
        self.constraintEntitiesMarkedForRemoval =
            constraintEntitiesMarkedForRemoval
    }

    public static let empty = SourceCanonicalNoCollideRemovalResult(
        bindings: [],
        deletionCommands: [],
        constraintEntitiesMarkedForRemoval: []
    )
}

public enum SourceCanonicalNoCollideHandledWithoutConstraint:
    Equatable,
    Sendable
{
    /// The first full EHANDLE/body ID stopped resolving between clicks.
    case firstSelectionBecameStale
    /// `constraint.NoCollide` rejects `Phys1 == Phys2`.
    case identicalPhysicsObjects
    /// `constraint.Find(..., "NoCollide", ...)` found an existing pair.
    case pairAlreadyConstrained
}

public enum SourceCanonicalNoCollideToolRejection:
    Equatable,
    Sendable
{
    case actorIsNotLivePlayer
    case targetIsNotLive
    case targetIsPlayer
    case targetIsPendingRemoval
    case canToolDenied
    case physicsObjectIsUnavailable
    case constraintLimitReached
    case noNoCollideConstraints
}

public enum SourceCanonicalNoCollideToolResult: Equatable, Sendable {
    case selected(SourceCanonicalNoCollideEndpoint)
    case created(SourceCanonicalNoCollideCreationResult)
    case collisionGroupChanged(SourceCanonicalEntitySnapshot)
    case constraintsRemoved(SourceCanonicalNoCollideRemovalResult)
    /// Stock returns true after the second click even when
    /// `constraint.NoCollide` itself returns false for these pair checks.
    case handledWithoutConstraint(
        SourceCanonicalNoCollideHandledWithoutConstraint
    )
    case rejected(SourceCanonicalNoCollideToolRejection)

    public var accepted: Bool {
        switch self {
        case .selected, .created, .collisionGroupChanged,
             .constraintsRemoved, .handledWithoutConstraint:
            true
        case .rejected:
            false
        }
    }
}

public enum SourceCanonicalNoCollideToolError:
    Error,
    Equatable,
    Sendable
{
    case undoIdentifierExhausted
    case physicsFIFOResultCount(expected: Int, actual: Int)
    case physicsFIFOSequenceIsZero
    case physicsFIFOPayloadMismatch
}

/// SERVER-lane owner of the bundled No-Collide stool's authoritative state.
///
/// Selection, Entity lifetime, graph topology, undo/cleanup bookkeeping and
/// backend pair suppression are committed with complete identities. CLIENT
/// prediction may report the stock click boolean but cannot enter this owner
/// or mutate its state.
public final class SourceCanonicalNoCollideToolCoordinator {
    private let entityHost: any SourceCanonicalNoCollideEntityHost
    private let physicsHost: any SourceCanonicalNoCollidePhysicsHost
    private let commandQueue: any SourceCanonicalPhysicsConstraintCommandQueue
    private let constraintGraph: SourceCanonicalConstraintGraph
    private let constraintLimitGate:
        SourceCanonicalNoCollideConstraintLimitGate

    private var selectionByPlayer: [
        SourceCanonicalEntityIdentity: SourceCanonicalNoCollideEndpoint
    ] = [:]
    private var bindingsByConstraintHandle: [
        UInt32: SourceCanonicalNoCollideBinding
    ] = [:]
    private var cleanupByPlayer: [
        SourceCanonicalEntityIdentity: Set<SourceCanonicalEntityIdentity>
    ] = [:]
    private var undoStorage: [SourceCanonicalNoCollideUndoRecord] = []
    private var nextUndoIdentifier: UInt64 = 1

    public init(
        entityHost: any SourceCanonicalNoCollideEntityHost,
        physicsHost: any SourceCanonicalNoCollidePhysicsHost,
        commandQueue: any SourceCanonicalPhysicsConstraintCommandQueue,
        constraintGraph: SourceCanonicalConstraintGraph,
        constraintLimitGate:
            @escaping SourceCanonicalNoCollideConstraintLimitGate
    ) {
        self.entityHost = entityHost
        self.physicsHost = physicsHost
        self.commandQueue = commandQueue
        self.constraintGraph = constraintGraph
        self.constraintLimitGate = constraintLimitGate
    }

    public var bindings: [SourceCanonicalNoCollideBinding] {
        bindingsByConstraintHandle.values.sorted {
            $0.graphRecord.identifier < $1.graphRecord.identifier
        }
    }

    public var undoRecords: [SourceCanonicalNoCollideUndoRecord] {
        undoStorage
    }

    public func selection(
        for player: SourceCanonicalEntityIdentity
    ) -> SourceCanonicalNoCollideEndpoint? {
        selectionByPlayer[player]
    }

    public func cleanupConstraints(
        for player: SourceCanonicalEntityIdentity
    ) -> [SourceCanonicalEntityIdentity] {
        Array(cleanupByPlayer[player] ?? []).sorted(by: Self.identityOrder)
    }

    /// SERVER authoritative action for one stool button.
    @discardableResult
    public func perform(
        actor actorIdentity: SourceCanonicalEntityIdentity,
        action: SourceCanonicalNoCollideToolAction,
        trace: SourceCanonicalNoCollideToolTrace,
        canTool: SourceCanonicalNoCollideCanTool
    ) throws -> SourceCanonicalNoCollideToolResult {
        guard let actor = liveSnapshot(actorIdentity),
              actor.kind == .player else {
            return .rejected(.actorIsNotLivePlayer)
        }
        guard let target = liveSnapshot(trace.target) else {
            return .rejected(.targetIsNotLive)
        }
        guard target.kind != .player else {
            return .rejected(.targetIsPlayer)
        }
        guard target.lifecycle != .pendingRemoval else {
            return .rejected(.targetIsPendingRemoval)
        }
        guard try canTool(SourceCanonicalNoCollideCanToolRequest(
            actor: actor,
            target: target,
            trace: trace,
            action: action
        )) else {
            return .rejected(.canToolDenied)
        }

        switch action {
        case .leftClick:
            return try performLeftClick(
                actor: actor,
                target: target,
                trace: trace
            )
        case .rightClick:
            return try performRightClick(target: target)
        case .reload:
            return try performReload(target: target)
        }
    }

    /// `TOOL:Holster` clears only this player's staged objects.
    public func holster(player: SourceCanonicalEntityIdentity) {
        selectionByPlayer.removeValue(forKey: player)
    }

    /// Latest live `undo.Create("NoCollide")` entry for this player.
    @discardableResult
    public func undoLatest(
        for player: SourceCanonicalEntityIdentity
    ) throws -> SourceCanonicalNoCollideRemovalResult {
        guard let undoIndex = undoStorage.lastIndex(where: {
            $0.player == player && $0.isLive
        }) else { return .empty }
        let record = undoStorage[undoIndex]
        guard let binding = binding(for: record.constraintEntity) else {
            markUndoDead(constraintEntity: record.constraintEntity)
            return .empty
        }
        return try remove([binding])
    }

    /// Implements `Player:AddCleanup("nocollide", constraint)` by deleting
    /// every still-live binding registered to the player's cleanup category.
    @discardableResult
    public func removeCleanupConstraints(
        for player: SourceCanonicalEntityIdentity
    ) throws -> SourceCanonicalNoCollideRemovalResult {
        let selected = cleanupConstraints(for: player).compactMap(binding)
        return try remove(selected)
    }

    /// Read-only CLIENT acceptance used before SERVER authority responds. It
    /// mirrors only the stool's `IsValid`/player/lifecycle checks and never
    /// claims that the physics object or limit passed on the server.
    public static func predictsAcceptance(
        target: SourceCanonicalEntitySnapshot?
    ) -> Bool {
        guard let target,
              target.kind != .player,
              target.lifecycle != .pendingRemoval,
              target.lifecycle != .removed else { return false }
        return true
    }

    private func performLeftClick(
        actor: SourceCanonicalEntitySnapshot,
        target: SourceCanonicalEntitySnapshot,
        trace: SourceCanonicalNoCollideToolTrace
    ) throws -> SourceCanonicalNoCollideToolResult {
        guard let endpoint = endpoint(target: target, trace: trace) else {
            return .rejected(.physicsObjectIsUnavailable)
        }
        guard let first = selectionByPlayer[actor.identity] else {
            selectionByPlayer[actor.identity] = endpoint
            return .selected(endpoint)
        }

        // `ClearObjects` runs after every valid second object attempt.
        selectionByPlayer.removeValue(forKey: actor.identity)
        guard endpointIsLive(first) else {
            return .handledWithoutConstraint(.firstSelectionBecameStale)
        }
        guard first.bodyID != endpoint.bodyID else {
            return .handledWithoutConstraint(.identicalPhysicsObjects)
        }
        guard !containsPair(first.bodyID, endpoint.bodyID) else {
            return .handledWithoutConstraint(.pairAlreadyConstrained)
        }
        guard try constraintLimitGate(actor) else {
            return .rejected(.constraintLimitReached)
        }
        guard nextUndoIdentifier != UInt64.max else {
            throw SourceCanonicalNoCollideToolError.undoIdentifierExhausted
        }

        let graphRecord = try constraintGraph.insert(entities: [
            first.entity,
            endpoint.entity,
        ])
        let creation = try SourcePhysicsNoCollideConstraintCreationCommand(
            constraintID: SourcePhysicsConstraintID(
                rawValue: graphRecord.identifier
            ),
            firstBodyID: first.bodyID,
            secondBodyID: endpoint.bodyID
        )
        var createdEntity: SourceCanonicalEntitySnapshot?
        var queued: [SourcePhysicsCommand] = []
        do {
            let created = try entityHost.createCanonicalEntity(
                kind: .physicsConstraint,
                at: nil,
                state: nil,
                playerUserID: nil
            )
            createdEntity = created
            queued = try commandQueue
                .enqueueCanonicalPhysicsConstraintCommands([
                    .createNoCollide(creation),
                ])
            try validate(
                queued,
                expected: [.createNoCollide(creation)]
            )
            _ = try entityHost.spawnCanonicalEntity(created.identity)
            let active = try entityHost.activateCanonicalEntity(
                created.identity
            )
            let undo = SourceCanonicalNoCollideUndoRecord(
                identifier: nextUndoIdentifier,
                player: actor.identity,
                constraintEntity: active.identity,
                isLive: true
            )
            nextUndoIdentifier += 1
            let binding = SourceCanonicalNoCollideBinding(
                graphRecord: graphRecord,
                constraintEntity: active.identity,
                owner: actor.identity,
                first: first,
                second: endpoint,
                creationCommand: creation,
                creationSequence: queued[0].sequence
            )
            bindingsByConstraintHandle[active.identity.handle.rawValue] =
                binding
            cleanupByPlayer[actor.identity, default: []].insert(
                active.identity
            )
            undoStorage.append(undo)
            return .created(SourceCanonicalNoCollideCreationResult(
                binding: binding,
                constraintEntity: active,
                undo: undo
            ))
        } catch {
            if !queued.isEmpty {
                commandQueue.rollbackCanonicalPhysicsConstraintCommands(
                    queued
                )
            }
            if let createdEntity {
                _ = try? entityHost.rollbackUnpublishedCanonicalEntity(
                    createdEntity.identity
                )
            }
            _ = constraintGraph.remove(identifier: graphRecord.identifier)
            throw error
        }
    }

    private func performRightClick(
        target: SourceCanonicalEntitySnapshot
    ) throws -> SourceCanonicalNoCollideToolResult {
        let next = target.collisionGroup ==
            SourceCanonicalNoCollideCollisionGroup.world
            ? SourceCanonicalNoCollideCollisionGroup.none
            : SourceCanonicalNoCollideCollisionGroup.world
        let updated = try entityHost.updateCanonicalEntity(target.identity) {
            $0.collisionGroup = next
        }
        return .collisionGroupChanged(updated)
    }

    private func performReload(
        target: SourceCanonicalEntitySnapshot
    ) throws -> SourceCanonicalNoCollideToolResult {
        let matching = bindings.filter {
            $0.first.entity == target.identity ||
                $0.second.entity == target.identity
        }
        guard !matching.isEmpty else {
            return .rejected(.noNoCollideConstraints)
        }
        return .constraintsRemoved(try remove(matching))
    }

    private func remove(
        _ candidates: [SourceCanonicalNoCollideBinding]
    ) throws -> SourceCanonicalNoCollideRemovalResult {
        var removed: [SourceCanonicalNoCollideBinding] = []
        var commands: [SourcePhysicsCommand] = []
        var entities: [SourceCanonicalEntityIdentity] = []
        for candidate in candidates.sorted(by: Self.bindingOrder) {
            guard let current = binding(for: candidate.constraintEntity),
                  current == candidate else { continue }
            let expected: [SourceCanonicalQueuedPhysicsConstraintCommand] = [
                .delete(SourcePhysicsConstraintDeletionCommand(
                    constraintID: current.constraintID
                )),
            ]
            let queued = try commandQueue
                .enqueueCanonicalPhysicsConstraintCommands(expected)
            do {
                try validate(queued, expected: expected)
                _ = try entityHost.markCanonicalEntityForRemoval(
                    current.constraintEntity
                )
            } catch {
                commandQueue.rollbackCanonicalPhysicsConstraintCommands(
                    queued
                )
                throw error
            }
            bindingsByConstraintHandle.removeValue(
                forKey: current.constraintEntity.handle.rawValue
            )
            _ = constraintGraph.remove(
                identifier: current.graphRecord.identifier
            )
            cleanupByPlayer[current.owner]?.remove(current.constraintEntity)
            if cleanupByPlayer[current.owner]?.isEmpty == true {
                cleanupByPlayer.removeValue(forKey: current.owner)
            }
            markUndoDead(constraintEntity: current.constraintEntity)
            removed.append(current)
            commands.append(contentsOf: queued)
            entities.append(current.constraintEntity)
        }
        return SourceCanonicalNoCollideRemovalResult(
            bindings: removed,
            deletionCommands: commands,
            constraintEntitiesMarkedForRemoval: entities
        )
    }

    private func endpoint(
        target: SourceCanonicalEntitySnapshot,
        trace: SourceCanonicalNoCollideToolTrace
    ) -> SourceCanonicalNoCollideEndpoint? {
        guard let bodyID = try? SourcePhysicsBodyID(
            entityIdentity: target.identity,
            solidIndex: trace.physicsBone
        ), physicsHost.containsCanonicalNoCollidePhysicsBody(bodyID) else {
            return nil
        }
        return SourceCanonicalNoCollideEndpoint(
            entity: target.identity,
            bodyID: bodyID,
            hitPosition: trace.hitPosition,
            hitNormal: trace.hitNormal
        )
    }

    private func endpointIsLive(
        _ endpoint: SourceCanonicalNoCollideEndpoint
    ) -> Bool {
        guard let snapshot = liveSnapshot(endpoint.entity),
              snapshot.kind != .player,
              snapshot.lifecycle != .pendingRemoval else { return false }
        return physicsHost.containsCanonicalNoCollidePhysicsBody(
            endpoint.bodyID
        )
    }

    private func containsPair(
        _ first: SourcePhysicsBodyID,
        _ second: SourcePhysicsBodyID
    ) -> Bool {
        bindingsByConstraintHandle.values.contains {
            ($0.first.bodyID == first && $0.second.bodyID == second) ||
                ($0.first.bodyID == second && $0.second.bodyID == first)
        }
    }

    private func binding(
        for identity: SourceCanonicalEntityIdentity
    ) -> SourceCanonicalNoCollideBinding? {
        let value = bindingsByConstraintHandle[identity.handle.rawValue]
        return value?.constraintEntity == identity ? value : nil
    }

    private func liveSnapshot(
        _ identity: SourceCanonicalEntityIdentity
    ) -> SourceCanonicalEntitySnapshot? {
        guard let snapshot = entityHost.canonicalSnapshot(for: identity),
              snapshot.identity == identity,
              snapshot.lifecycle != .removed else { return nil }
        return snapshot
    }

    private func markUndoDead(
        constraintEntity: SourceCanonicalEntityIdentity
    ) {
        for index in undoStorage.indices
            where undoStorage[index].constraintEntity == constraintEntity &&
                undoStorage[index].isLive
        {
            let record = undoStorage[index]
            undoStorage[index] = SourceCanonicalNoCollideUndoRecord(
                identifier: record.identifier,
                player: record.player,
                constraintEntity: record.constraintEntity,
                isLive: false
            )
        }
    }

    private func validate(
        _ queued: [SourcePhysicsCommand],
        expected: [SourceCanonicalQueuedPhysicsConstraintCommand]
    ) throws {
        guard queued.count == expected.count else {
            throw SourceCanonicalNoCollideToolError.physicsFIFOResultCount(
                expected: expected.count,
                actual: queued.count
            )
        }
        for (actual, expectedCommand) in zip(queued, expected) {
            guard actual.sequence != 0 else {
                throw SourceCanonicalNoCollideToolError
                    .physicsFIFOSequenceIsZero
            }
            guard actual.payload == expectedCommand.payload else {
                throw SourceCanonicalNoCollideToolError
                    .physicsFIFOPayloadMismatch
            }
        }
    }

    private static func identityOrder(
        _ lhs: SourceCanonicalEntityIdentity,
        _ rhs: SourceCanonicalEntityIdentity
    ) -> Bool {
        lhs.handle.rawValue < rhs.handle.rawValue
    }

    private static func bindingOrder(
        _ lhs: SourceCanonicalNoCollideBinding,
        _ rhs: SourceCanonicalNoCollideBinding
    ) -> Bool {
        lhs.graphRecord.identifier < rhs.graphRecord.identifier
    }
}
