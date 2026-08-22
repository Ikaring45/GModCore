import Foundation
import GModLua

/// The two stock Duplicator stool buttons which cross the authoritative
/// boundary. CLIENT prediction remains in the original stool; this core owns
/// only SERVER copy/paste state.
public enum SourceCanonicalDuplicatorToolAction: UInt8, Equatable, Sendable {
    case leftClickPaste = 1
    case rightClickCopy = 2
}

public enum SourceCanonicalDuplicatorRejection: Equatable, Sendable {
    case hostUnavailable
    case actorIsNotLivePlayer
    case targetIsNotLive
    case targetIsNotPropPhysics
    case targetIsPendingRemoval
    case modelIsUnavailable
    case physicsObjectIsUnavailable
}

/// Stock `PhysicsObject.Save` stores these three flags. The stock loader
/// restores Frozen and NoGrav, while its Sleep/Wake branch is deliberately
/// commented out. Retaining `wasSleeping` without applying it therefore
/// matches the shipped module instead of inventing a wake policy.
public struct SourceCanonicalDuplicatorPhysicsState: Equatable, Sendable {
    public let sourceBodyID: SourcePhysicsBodyID
    public let isFrozen: Bool
    public let noGravity: Bool
    public let wasSleeping: Bool

    public init(
        sourceBodyID: SourcePhysicsBodyID,
        isFrozen: Bool,
        noGravity: Bool,
        wasSleeping: Bool
    ) {
        self.sourceBodyID = sourceBodyID
        self.isFrozen = isFrozen
        self.noGravity = noGravity
        self.wasSleeping = wasSleeping
    }
}

/// Engine-owned equivalents of the stock generic entity fields and the
/// built-in colour/material modifiers. Arbitrary add-on Lua tables are not
/// serialized by this layer: claiming those callbacks ran without their
/// registered Lua functions would be a false success.
public enum SourceCanonicalDuplicatorEntityModifier: Equatable, Sendable {
    case renderState(SourceEntityRenderState)
    case material(SourceEntityMaterialOverride?)
    case skin(Int)
    case bodyGroups(Int)
    case sourceCreator(SourceCanonicalEntityIdentity?)
}

public struct SourceCanonicalDuplicatorEntityBlueprint: Equatable, Sendable {
    public let sourceIdentity: SourceCanonicalEntityIdentity
    public let relativeTransform: SourceEntityTransform
    public let model: SourceEntityModelReference
    public let collisionGroup: Int32
    public let isPersistent: Bool
    public let renderState: SourceEntityRenderState
    public let materialOverride: SourceEntityMaterialOverride?
    public let skin: Int
    public let bodyValue: Int
    public let physics: SourceCanonicalDuplicatorPhysicsState
    public let modifiers: [SourceCanonicalDuplicatorEntityModifier]

    public init(
        sourceIdentity: SourceCanonicalEntityIdentity,
        relativeTransform: SourceEntityTransform,
        model: SourceEntityModelReference,
        collisionGroup: Int32,
        isPersistent: Bool,
        renderState: SourceEntityRenderState,
        materialOverride: SourceEntityMaterialOverride?,
        skin: Int,
        bodyValue: Int,
        physics: SourceCanonicalDuplicatorPhysicsState,
        modifiers: [SourceCanonicalDuplicatorEntityModifier]
    ) {
        self.sourceIdentity = sourceIdentity
        self.relativeTransform = relativeTransform
        self.model = model
        self.collisionGroup = collisionGroup
        self.isPersistent = isPersistent
        self.renderState = renderState
        self.materialOverride = materialOverride
        self.skin = skin
        self.bodyValue = bodyValue
        self.physics = physics
        self.modifiers = modifiers
    }
}

/// A copied constraint is never dropped or reported as recreated merely
/// because its concrete backend is not connected to Duplicator yet.
public enum SourceCanonicalDuplicatorUnsupportedConstraintKind:
    String,
    Equatable,
    Sendable
{
    case canonicalGraph = "canonical_graph"
    case weld = "weld"
    case rope = "rope"
}

public struct SourceCanonicalDuplicatorUnsupportedConstraint:
    Equatable,
    Sendable
{
    public let kind: SourceCanonicalDuplicatorUnsupportedConstraintKind
    public let sourceRecord: SourceCanonicalConstraintRecord

    public init(
        kind: SourceCanonicalDuplicatorUnsupportedConstraintKind,
        sourceRecord: SourceCanonicalConstraintRecord
    ) {
        self.kind = kind
        self.sourceRecord = sourceRecord
    }
}

public struct SourceCanonicalDuplicatorCopy: Equatable, Sendable {
    public let anchor: SourceEntityTransform
    public let entities: [SourceCanonicalDuplicatorEntityBlueprint]
    public let unsupportedConstraints:
        [SourceCanonicalDuplicatorUnsupportedConstraint]
    public let minimums: SourceVector3
    public let maximums: SourceVector3

    public init(
        anchor: SourceEntityTransform,
        entities: [SourceCanonicalDuplicatorEntityBlueprint],
        unsupportedConstraints:
            [SourceCanonicalDuplicatorUnsupportedConstraint],
        minimums: SourceVector3,
        maximums: SourceVector3
    ) {
        self.anchor = anchor
        self.entities = entities
        self.unsupportedConstraints = unsupportedConstraints
        self.minimums = minimums
        self.maximums = maximums
    }
}

public struct SourceCanonicalDuplicatorCopyResult: Equatable, Sendable {
    public let copy: SourceCanonicalDuplicatorCopy?
    public let rejection: SourceCanonicalDuplicatorRejection?

    public var accepted: Bool { copy != nil && rejection == nil }

    fileprivate static func rejected(
        _ rejection: SourceCanonicalDuplicatorRejection
    ) -> Self {
        Self(copy: nil, rejection: rejection)
    }
}

public struct SourceCanonicalDuplicatorPastedEntity: Equatable, Sendable {
    public let sourceIdentity: SourceCanonicalEntityIdentity
    public let pasted: SourceCanonicalEntitySnapshot

    public init(
        sourceIdentity: SourceCanonicalEntityIdentity,
        pasted: SourceCanonicalEntitySnapshot
    ) {
        self.sourceIdentity = sourceIdentity
        self.pasted = pasted
    }
}

public struct SourceCanonicalDuplicatorUndoToken:
    Equatable,
    Hashable,
    Sendable
{
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }
}

public struct SourceCanonicalDuplicatorPasteResult: Equatable, Sendable {
    public let entities: [SourceCanonicalDuplicatorPastedEntity]
    public let unsupportedConstraints:
        [SourceCanonicalDuplicatorUnsupportedConstraint]
    public let undoToken: SourceCanonicalDuplicatorUndoToken
    /// Exact source sleep flags retained but intentionally not applied because
    /// the stock module's Sleep/Wake loader is disabled.
    public let sleepingPhysicsObjectsNotApplied:
        [SourceCanonicalEntityIdentity]
}

public struct SourceCanonicalDuplicatorUndoResult: Equatable, Sendable {
    public let scheduledForRemoval: [SourceCanonicalEntityIdentity]
    public let alreadyPendingRemoval: [SourceCanonicalEntityIdentity]
    public let staleOrRemoved: [SourceCanonicalEntityIdentity]

    public static let empty = SourceCanonicalDuplicatorUndoResult(
        scheduledForRemoval: [],
        alreadyPendingRemoval: [],
        staleOrRemoved: []
    )
}

/// Read-only constraint capture seam. Concrete weld/rope stores can classify
/// their records; the generic topology graph truthfully labels its records as
/// unsupported canonical graph entries.
public protocol SourceCanonicalDuplicatorConstraintSource: AnyObject {
    func connectedEntitiesForDuplicator(
        startingAt entity: SourceCanonicalEntityIdentity
    ) -> [SourceCanonicalEntityIdentity]

    func unsupportedConstraintsForDuplicator(
        involving entities: Set<SourceCanonicalEntityIdentity>
    ) -> [SourceCanonicalDuplicatorUnsupportedConstraint]
}

extension SourceCanonicalConstraintGraph:
    SourceCanonicalDuplicatorConstraintSource
{
    public func connectedEntitiesForDuplicator(
        startingAt entity: SourceCanonicalEntityIdentity
    ) -> [SourceCanonicalEntityIdentity] {
        allConstrainedEntities(startingAt: entity)
    }

    public func unsupportedConstraintsForDuplicator(
        involving entities: Set<SourceCanonicalEntityIdentity>
    ) -> [SourceCanonicalDuplicatorUnsupportedConstraint] {
        records.filter { record in
            record.entities.contains { entities.contains($0) }
        }.map {
            SourceCanonicalDuplicatorUnsupportedConstraint(
                kind: .canonicalGraph,
                sourceRecord: $0
            )
        }
    }
}

/// Narrow SERVER host used by the canonical Duplicator core. The transaction
/// stages the existing transport FIFO, so an error can compensate every fresh
/// full EHANDLE and discard every queued physics mutation as one paste.
public protocol SourceCanonicalDuplicatorHost: AnyObject {
    func canonicalSnapshot(
        for identity: SourceCanonicalEntityIdentity
    ) -> SourceCanonicalEntitySnapshot?

    func primaryCanonicalPhysicsObject(
        for entity: SourceCanonicalEntityIdentity
    ) -> SourceCanonicalPhysicsObjectSnapshot?

    func createCanonicalEntity(
        kind: SourceCanonicalEntityKind,
        at entryIndex: Int?,
        state: SourceCanonicalEntityState?,
        playerUserID: Int?
    ) throws -> SourceCanonicalEntitySnapshot

    func spawnCanonicalEntity(
        _ identity: SourceCanonicalEntityIdentity
    ) throws -> SourceCanonicalEntitySnapshot

    func activateCanonicalEntity(
        _ identity: SourceCanonicalEntityIdentity
    ) throws -> SourceCanonicalEntitySnapshot

    func rollbackUnpublishedCanonicalEntity(
        _ identity: SourceCanonicalEntityIdentity
    ) throws -> SourceCanonicalEntitySnapshot

    func enqueueCanonicalPhysicsObjectMutation(
        _ command: SourcePhysicsBodyMutationCommand
    ) throws

    func markCanonicalEntityForRemoval(
        _ identity: SourceCanonicalEntityIdentity
    ) throws -> SourceCanonicalEntitySnapshot

    func withCanonicalDuplicatorPasteTransaction(
        _ body: () throws -> [SourceCanonicalDuplicatorPastedEntity]
    ) throws -> [SourceCanonicalDuplicatorPastedEntity]
}

extension GMLuaSourceRuntimeAdapter: SourceCanonicalDuplicatorHost {}

public enum SourceCanonicalDuplicatorError:
    Error,
    Equatable,
    CustomStringConvertible,
    Sendable
{
    case rejected(SourceCanonicalDuplicatorRejection)
    case transactionRollbackFailed(String)
    case undoTokenSpaceExhausted

    public var description: String {
        switch self {
        case let .rejected(rejection):
            return "canonical Duplicator rejected action: \(rejection)"
        case let .transactionRollbackFailed(message):
            return "canonical Duplicator rollback failed: \(message)"
        case .undoTokenSpaceExhausted:
            return "canonical Duplicator undo token space is exhausted"
        }
    }
}

/// SERVER-authoritative core behind the original stool's right-click Copy and
/// left-click Paste calls.
public final class SourceCanonicalDuplicatorCoordinator:
    @unchecked Sendable
{
    private weak var host: (any SourceCanonicalDuplicatorHost)?
    private let constraintSource:
        (any SourceCanonicalDuplicatorConstraintSource)?
    private let lock = NSLock()
    private var nextUndoToken: UInt64 = 1
    private var undoEntitiesByToken: [
        SourceCanonicalDuplicatorUndoToken: [SourceCanonicalEntityIdentity]
    ] = [:]

    public init(
        host: any SourceCanonicalDuplicatorHost,
        constraintSource:
            (any SourceCanonicalDuplicatorConstraintSource)? = nil
    ) {
        self.host = host
        self.constraintSource = constraintSource
    }

    public var pendingUndoCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return undoEntitiesByToken.count
    }

    /// Stock right click. The supplied anchor is the stool's temporary
    /// `duplicator.SetLocalPos/SetLocalAng` transform.
    public func copy(
        target targetIdentity: SourceCanonicalEntityIdentity,
        anchor: SourceEntityTransform
    ) -> SourceCanonicalDuplicatorCopyResult {
        guard let host else { return .rejected(.hostUnavailable) }
        guard let target = liveSnapshot(targetIdentity) else {
            return .rejected(.targetIsNotLive)
        }
        guard target.kind == .propPhysics else {
            return .rejected(.targetIsNotPropPhysics)
        }
        guard target.lifecycle == .spawned || target.lifecycle == .active else {
            return .rejected(.targetIsPendingRemoval)
        }

        let connected = constraintSource?.connectedEntitiesForDuplicator(
            startingAt: target.identity
        ) ?? [target.identity]
        var blueprints: [SourceCanonicalDuplicatorEntityBlueprint] = []
        for identity in Array(Set(connected)).sorted(by: Self.identityOrder) {
            guard let snapshot = liveSnapshot(identity),
                  snapshot.kind == .propPhysics,
                  snapshot.lifecycle == .spawned ||
                    snapshot.lifecycle == .active else { continue }
            guard let model = snapshot.model else {
                return .rejected(.modelIsUnavailable)
            }
            guard let physics = host.primaryCanonicalPhysicsObject(
                for: snapshot.identity
            ), physics.bodyID.entityIdentity == snapshot.identity else {
                return .rejected(.physicsObjectIsUnavailable)
            }
            let relativePose = SourcePhysicsFixedConstraintPose(
                reference: anchor,
                attached: snapshot.transform
            ).snapshotTransform
            blueprints.append(SourceCanonicalDuplicatorEntityBlueprint(
                sourceIdentity: snapshot.identity,
                relativeTransform: relativePose,
                model: model,
                collisionGroup: snapshot.collisionGroup,
                isPersistent: snapshot.isPersistent,
                renderState: snapshot.renderState,
                materialOverride: snapshot.materialOverride,
                skin: snapshot.skin,
                bodyValue: snapshot.bodyValue,
                physics: SourceCanonicalDuplicatorPhysicsState(
                    sourceBodyID: physics.bodyID,
                    isFrozen: !physics.isMotionEnabled,
                    noGravity: !physics.isGravityEnabled,
                    wasSleeping: physics.isSleeping
                ),
                modifiers: [
                    .renderState(snapshot.renderState),
                    .material(snapshot.materialOverride),
                    .skin(snapshot.skin),
                    .bodyGroups(snapshot.bodyValue),
                    .sourceCreator(snapshot.creator),
                ]
            ))
        }
        guard !blueprints.isEmpty else {
            return .rejected(.targetIsNotLive)
        }

        let copiedIdentities = Set(blueprints.map(\.sourceIdentity))
        let constraints = constraintSource?
            .unsupportedConstraintsForDuplicator(
                involving: copiedIdentities
            ) ?? []
        let bounds = Self.bounds(of: blueprints, host: host)
        return SourceCanonicalDuplicatorCopyResult(
            copy: SourceCanonicalDuplicatorCopy(
                anchor: anchor,
                entities: blueprints,
                unsupportedConstraints: constraints,
                minimums: bounds.minimums,
                maximums: bounds.maximums
            ),
            rejection: nil
        )
    }

    /// Stock left click. Every Entity create/spawn/activate and Frozen/NoGrav
    /// mutation is staged under one transport transaction. Any thrown step
    /// rolls back fresh full handles in reverse allocation order.
    public func paste(
        actor actorIdentity: SourceCanonicalEntityIdentity,
        copy: SourceCanonicalDuplicatorCopy,
        anchor: SourceEntityTransform
    ) throws -> SourceCanonicalDuplicatorPasteResult {
        guard let host else {
            throw SourceCanonicalDuplicatorError.rejected(.hostUnavailable)
        }
        guard let actor = liveSnapshot(actorIdentity), actor.kind == .player,
              actor.lifecycle == .spawned || actor.lifecycle == .active else {
            throw SourceCanonicalDuplicatorError.rejected(
                .actorIsNotLivePlayer
            )
        }

        let undoToken = try reserveUndoToken()
        let pasted: [SourceCanonicalDuplicatorPastedEntity]
        do {
            pasted = try host.withCanonicalDuplicatorPasteTransaction {
                var created: [SourceCanonicalDuplicatorPastedEntity] = []
                do {
                    for blueprint in copy.entities {
                        let relative = SourcePhysicsFixedConstraintPose(
                            reference: .identity,
                            attached: blueprint.relativeTransform
                        )
                        var state = SourceCanonicalEntityState.defaults(
                            for: .propPhysics
                        )
                        state.transform = relative.desiredAttachedTransform(
                            reference: anchor
                        )
                        state.model = blueprint.model
                        state.collisionGroup = blueprint.collisionGroup
                        state.isPersistent = blueprint.isPersistent
                        state.renderState = blueprint.renderState
                        state.materialOverride = blueprint.materialOverride
                        state.skin = blueprint.skin
                        state.bodyValue = blueprint.bodyValue
                        state.creator = actor.identity
                        state.spawnEffect = false

                        let fresh = try host.createCanonicalEntity(
                            kind: .propPhysics,
                            at: nil,
                            state: state,
                            playerUserID: nil
                        )
                        created.append(SourceCanonicalDuplicatorPastedEntity(
                            sourceIdentity: blueprint.sourceIdentity,
                            pasted: fresh
                        ))
                        _ = try host.spawnCanonicalEntity(fresh.identity)
                        let active = try host.activateCanonicalEntity(
                            fresh.identity
                        )
                        created[created.count - 1] =
                            SourceCanonicalDuplicatorPastedEntity(
                                sourceIdentity: blueprint.sourceIdentity,
                                pasted: active
                            )
                    }

                    for (blueprint, pastedEntity) in zip(
                        copy.entities,
                        created
                    ) {
                        guard let body = host.primaryCanonicalPhysicsObject(
                            for: pastedEntity.pasted.identity
                        ), body.bodyID.entityIdentity ==
                            pastedEntity.pasted.identity else {
                            throw SourceCanonicalDuplicatorError.rejected(
                                .physicsObjectIsUnavailable
                            )
                        }
                        if blueprint.physics.isFrozen {
                            try host.enqueueCanonicalPhysicsObjectMutation(
                                try SourcePhysicsBodyMutationCommand(
                                    bodyID: body.bodyID,
                                    mutation: .setMotionEnabled(false)
                                )
                            )
                        }
                        if blueprint.physics.noGravity {
                            try host.enqueueCanonicalPhysicsObjectMutation(
                                try SourcePhysicsBodyMutationCommand(
                                    bodyID: body.bodyID,
                                    mutation: .setGravityEnabled(false)
                                )
                            )
                        }
                    }
                    return created
                } catch {
                    do {
                        for entity in created.reversed() {
                            _ = try host.rollbackUnpublishedCanonicalEntity(
                                entity.pasted.identity
                            )
                        }
                    } catch let rollbackError {
                        throw SourceCanonicalDuplicatorError
                            .transactionRollbackFailed(
                                String(describing: rollbackError)
                            )
                    }
                    throw error
                }
            }
        } catch {
            cancelUndoToken(undoToken)
            throw error
        }

        commitUndoToken(
            undoToken,
            identities: pasted.map { $0.pasted.identity }
        )
        return SourceCanonicalDuplicatorPasteResult(
            entities: pasted,
            unsupportedConstraints: copy.unsupportedConstraints,
            undoToken: undoToken,
            sleepingPhysicsObjectsNotApplied: zip(copy.entities, pasted)
                .compactMap { blueprint, entity in
                    blueprint.physics.wasSleeping
                        ? entity.pasted.identity
                        : nil
                }
        )
    }

    /// Engine-side equivalent of the stock undo entry. The complete EHANDLE
    /// is revalidated, so recycling one EntIndex cannot remove its replacement.
    public func undo(
        _ token: SourceCanonicalDuplicatorUndoToken
    ) throws -> SourceCanonicalDuplicatorUndoResult {
        guard let host else {
            throw SourceCanonicalDuplicatorError.rejected(.hostUnavailable)
        }
        lock.lock()
        let identities = undoEntitiesByToken.removeValue(forKey: token)
        lock.unlock()
        guard let identities else { return .empty }

        var scheduled: [SourceCanonicalEntityIdentity] = []
        var pending: [SourceCanonicalEntityIdentity] = []
        var stale: [SourceCanonicalEntityIdentity] = []
        for identity in identities.sorted(by: Self.identityOrder) {
            guard let snapshot = host.canonicalSnapshot(for: identity),
                  snapshot.identity == identity else {
                stale.append(identity)
                continue
            }
            switch snapshot.lifecycle {
            case .created, .spawned, .active:
                _ = try host.markCanonicalEntityForRemoval(identity)
                scheduled.append(identity)
            case .pendingRemoval:
                pending.append(identity)
            case .removed:
                stale.append(identity)
            }
        }
        return SourceCanonicalDuplicatorUndoResult(
            scheduledForRemoval: scheduled,
            alreadyPendingRemoval: pending,
            staleOrRemoved: stale
        )
    }

    private func liveSnapshot(
        _ identity: SourceCanonicalEntityIdentity
    ) -> SourceCanonicalEntitySnapshot? {
        guard let host,
              let snapshot = host.canonicalSnapshot(for: identity),
              snapshot.identity == identity,
              snapshot.lifecycle != .removed,
              snapshot.lifecycle != .pendingRemoval else { return nil }
        return snapshot
    }

    private func reserveUndoToken() throws
        -> SourceCanonicalDuplicatorUndoToken
    {
        lock.lock()
        defer { lock.unlock() }
        guard nextUndoToken != UInt64.max else {
            throw SourceCanonicalDuplicatorError.undoTokenSpaceExhausted
        }
        let token = SourceCanonicalDuplicatorUndoToken(
            rawValue: nextUndoToken
        )
        nextUndoToken += 1
        undoEntitiesByToken[token] = []
        return token
    }

    private func commitUndoToken(
        _ token: SourceCanonicalDuplicatorUndoToken,
        identities: [SourceCanonicalEntityIdentity]
    ) {
        lock.lock()
        precondition(
            undoEntitiesByToken[token] != nil,
            "canonical Duplicator lost its reserved undo token"
        )
        undoEntitiesByToken[token] = identities
        lock.unlock()
    }

    private func cancelUndoToken(
        _ token: SourceCanonicalDuplicatorUndoToken
    ) {
        lock.lock()
        undoEntitiesByToken.removeValue(forKey: token)
        lock.unlock()
    }

    private static func identityOrder(
        _ lhs: SourceCanonicalEntityIdentity,
        _ rhs: SourceCanonicalEntityIdentity
    ) -> Bool {
        lhs.handle.rawValue < rhs.handle.rawValue
    }

    private static func bounds(
        of entities: [SourceCanonicalDuplicatorEntityBlueprint],
        host: any SourceCanonicalDuplicatorHost
    ) -> (minimums: SourceVector3, maximums: SourceVector3) {
        var points: [SourceVector3] = []
        for entity in entities {
            guard let physics = host.primaryCanonicalPhysicsObject(
                for: entity.sourceIdentity
            ) else { continue }
            let mins = physics.localAxisAlignedBounds.mins
            let maxs = physics.localAxisAlignedBounds.maxs
            for x in [mins.x, maxs.x] {
                for y in [mins.y, maxs.y] {
                    for z in [mins.z, maxs.z] {
                        points.append(entity.relativeTransform
                            .transformPointFromLocal(SourceVector3(x, y, z)))
                    }
                }
            }
        }
        guard let first = points.first else {
            return (SourceVector3(-1, -1, -1), SourceVector3(1, 1, 1))
        }
        var minimums = first
        var maximums = first
        for point in points.dropFirst() {
            minimums.x = min(minimums.x, point.x)
            minimums.y = min(minimums.y, point.y)
            minimums.z = min(minimums.z, point.z)
            maximums.x = max(maximums.x, point.x)
            maximums.y = max(maximums.y, point.y)
            maximums.z = max(maximums.z, point.z)
        }
        return (minimums, maximums)
    }
}

private final class SourceCanonicalDuplicatorWeakRuntime:
    @unchecked Sendable
{
    weak var value: GMLuaRuntime?

    init(_ value: GMLuaRuntime) { self.value = value }
}

/// Native spelling bridge installed after the bundled duplicator module. It
/// keeps the original stool route (`SetLocal* -> Copy`, then `SetLocal* ->
/// Paste`) while the returned tables carry engine-owned blueprints out of Lua.
public final class SourceCanonicalDuplicatorGLuaBridge:
    @unchecked Sendable
{
    public let coordinator: SourceCanonicalDuplicatorCoordinator

    private let lock = NSLock()
    private var localTransform = SourceEntityTransform.identity
    private var copyByEntitiesTable: [
        ObjectIdentifier: SourceCanonicalDuplicatorCopy
    ] = [:]
    public private(set) var lastPasteResult:
        SourceCanonicalDuplicatorPasteResult?

    private init(coordinator: SourceCanonicalDuplicatorCoordinator) {
        self.coordinator = coordinator
    }

    @discardableResult
    public static func install(
        into runtime: GMLuaRuntime,
        host: any SourceCanonicalDuplicatorHost,
        constraintSource:
            (any SourceCanonicalDuplicatorConstraintSource)? = nil
    ) throws -> SourceCanonicalDuplicatorGLuaBridge {
        guard runtime.realm == .server,
              let registry = runtime.entityRegistry,
              let typeSystem = runtime.typeSystem else {
            throw LuaError.runtime(
                "canonical Duplicator bridge requires SERVER Entity types"
            )
        }
        let state = runtime.state
        let coordinator = SourceCanonicalDuplicatorCoordinator(
            host: host,
            constraintSource: constraintSource
        )
        let bridge = SourceCanonicalDuplicatorGLuaBridge(
            coordinator: coordinator
        )
        let runtimeBox = SourceCanonicalDuplicatorWeakRuntime(runtime)
        let duplicator: LuaTable
        if case let .table(existing) = state.getGlobal("duplicator") {
            duplicator = existing
        } else {
            duplicator = LuaTable()
        }

        func native(
            _ name: String,
            _ body: @escaping LuaNativeFunction
        ) -> LuaValue {
            .nativeFunction(LuaNativeFunctionBox(body, debugName: name))
        }

        func installFunction(
            _ name: String,
            _ body: @escaping LuaNativeFunction
        ) throws {
            try state.setRawTableValue(
                native("duplicator.\(name)", body),
                for: .string(LuaString(name)),
                in: duplicator
            )
        }

        try installFunction("SetLocalPos") { arguments in
            guard let value = arguments.first else {
                throw LuaError.runtime(
                    "bad argument #1 to 'duplicator.SetLocalPos' (Vector expected)"
                )
            }
            let vector = try sourceVector(
                value,
                function: "duplicator.SetLocalPos"
            )
            bridge.lock.lock()
            bridge.localTransform.origin = vector
            bridge.lock.unlock()
            return []
        }

        try installFunction("SetLocalAng") { arguments in
            guard let value = arguments.first else {
                throw LuaError.runtime(
                    "bad argument #1 to 'duplicator.SetLocalAng' (Angle expected)"
                )
            }
            let angle = try sourceAngle(
                value,
                function: "duplicator.SetLocalAng"
            )
            bridge.lock.lock()
            bridge.localTransform.angles = angle
            bridge.lock.unlock()
            return []
        }

        try installFunction("Copy") { arguments in
            guard let value = arguments.first,
                  let target = registry.canonicalIdentity(for: value) else {
                return [.nilValue]
            }
            bridge.lock.lock()
            let anchor = bridge.localTransform
            bridge.lock.unlock()
            let result = bridge.coordinator.copy(
                target: target,
                anchor: anchor
            )
            guard let copy = result.copy else { return [.nilValue] }

            let entities = LuaTable()
            for blueprint in copy.entities {
                let data = LuaTable()
                try state.setRawTableValue(
                    .string(LuaString("prop_physics")),
                    for: .string("Class"),
                    in: data
                )
                try state.setRawTableValue(
                    .string(LuaString(blueprint.model.path)),
                    for: .string("Model"),
                    in: data
                )
                try state.setRawTableValue(
                    try luaVector(
                        blueprint.relativeTransform.origin,
                        typeSystem: typeSystem
                    ),
                    for: .string("Pos"),
                    in: data
                )
                try state.setRawTableValue(
                    try luaAngle(
                        blueprint.relativeTransform.angles,
                        typeSystem: typeSystem
                    ),
                    for: .string("Angle"),
                    in: data
                )
                try state.setRawTableValue(
                    .table(data),
                    for: .number(Double(
                        blueprint.sourceIdentity.entryIndex
                    )),
                    in: entities
                )
            }
            let constraints = LuaTable()
            for constraint in copy.unsupportedConstraints {
                let data = LuaTable()
                try state.setRawTableValue(
                    .string(LuaString(constraint.kind.rawValue)),
                    for: .string("UnsupportedType"),
                    in: data
                )
                try state.setRawTableValue(
                    .number(Double(constraint.sourceRecord.identifier)),
                    for: .string("Identifier"),
                    in: data
                )
                try state.setRawTableValue(
                    .table(data),
                    for: .number(Double(
                        constraint.sourceRecord.identifier
                    )),
                    in: constraints
                )
            }
            let dupe = LuaTable()
            try state.setRawTableValue(
                .table(entities),
                for: .string("Entities"),
                in: dupe
            )
            try state.setRawTableValue(
                .table(constraints),
                for: .string("Constraints"),
                in: dupe
            )
            try state.setRawTableValue(
                try luaVector(copy.minimums, typeSystem: typeSystem),
                for: .string("Mins"),
                in: dupe
            )
            try state.setRawTableValue(
                try luaVector(copy.maximums, typeSystem: typeSystem),
                for: .string("Maxs"),
                in: dupe
            )
            bridge.lock.lock()
            bridge.copyByEntitiesTable[ObjectIdentifier(entities)] = copy
            bridge.lock.unlock()
            return [.table(dupe)]
        }

        try installFunction("Paste") { arguments in
            guard arguments.count >= 3,
                  let actor = registry.canonicalIdentity(for: arguments[0]),
                  case let .table(entitiesTable) = arguments[1] else {
                throw LuaError.runtime(
                    "duplicator.Paste requires Player, Entities, Constraints"
                )
            }
            bridge.lock.lock()
            let copy = bridge.copyByEntitiesTable[
                ObjectIdentifier(entitiesTable)
            ]
            let anchor = bridge.localTransform
            bridge.lock.unlock()
            guard let copy else {
                throw LuaError.runtime(
                    "duplicator.Paste received an unowned Entities table"
                )
            }
            let result = try bridge.coordinator.paste(
                actor: actor,
                copy: copy,
                anchor: anchor
            )
            guard let liveRuntime = runtimeBox.value,
                  !liveRuntime.isClosed else {
                throw LuaError.runtime(
                    "canonical Duplicator runtime closed during paste"
                )
            }
            let created = LuaTable()
            for entity in result.entities {
                let value = registry.entity(
                    at: entity.pasted.identity.entryIndex
                )
                guard registry.canonicalIdentity(for: value) ==
                    entity.pasted.identity else {
                    throw LuaError.runtime(
                        "canonical Duplicator pasted Entity projection is unavailable"
                    )
                }
                try state.setRawTableValue(
                    value,
                    for: .number(Double(
                        entity.sourceIdentity.entryIndex
                    )),
                    in: created
                )
            }
            bridge.lock.lock()
            bridge.lastPasteResult = result
            bridge.lock.unlock()
            // Constraints remain typed unsupported; never return fabricated
            // constraint Entities in the second stock result.
            return [.table(created), .table(LuaTable())]
        }

        state.setGlobal("duplicator", value: .table(duplicator))
        return bridge
    }

    private static func sourceVector(
        _ value: LuaValue,
        function: String
    ) throws -> SourceVector3 {
        let components = try GMLuaVectorAngle.networkVectorComponents(
            from: value,
            function: function
        )
        guard components.0.isFinite, components.1.isFinite,
              components.2.isFinite else {
            throw LuaError.runtime("\(function) requires a finite Vector")
        }
        return SourceVector3(
            Float(components.0),
            Float(components.1),
            Float(components.2)
        )
    }

    private static func sourceAngle(
        _ value: LuaValue,
        function: String
    ) throws -> SourceQAngle {
        let components = try GMLuaVectorAngle.networkAngleComponents(
            from: value,
            function: function
        )
        guard components.0.isFinite, components.1.isFinite,
              components.2.isFinite else {
            throw LuaError.runtime("\(function) requires a finite Angle")
        }
        return SourceQAngle(
            pitch: Float(components.0),
            yaw: Float(components.1),
            roll: Float(components.2)
        )
    }

    private static func luaVector(
        _ value: SourceVector3,
        typeSystem: GMLuaTypeSystem
    ) throws -> LuaValue {
        try GMLuaVectorAngle.makeNetworkVector(
            Double(value.x),
            Double(value.y),
            Double(value.z),
            typeSystem: typeSystem
        )
    }

    private static func luaAngle(
        _ value: SourceQAngle,
        typeSystem: GMLuaTypeSystem
    ) throws -> LuaValue {
        try GMLuaVectorAngle.makeNetworkAngle(
            Double(value.pitch),
            Double(value.yaw),
            Double(value.roll),
            typeSystem: typeSystem
        )
    }
}
