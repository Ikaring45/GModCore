import Foundation
import GModLua

public enum GMLuaSourceRuntimeRunKind: String, Equatable, Sendable {
    case serverFixedTick
    case clientFrame
    case clientFixedTick
}

public struct GMLuaSourceHookFailure: Equatable, Sendable {
    public let realm: GMLuaRealm
    public let event: String
    /// Stable attachment order for CLIENT failures; nil denotes SERVER.
    public let clientAttachmentOrder: Int?
    public let message: String
}

public struct GMLuaSourceTimerFailure: Equatable, Sendable {
    public let realm: GMLuaRealm
    public let identifier: String
    /// Stable attachment order for CLIENT failures; nil denotes SERVER.
    public let clientAttachmentOrder: Int?
    public let message: String
}

public struct GMLuaSourceRuntimeRunReport: Equatable, Sendable {
    public let kind: GMLuaSourceRuntimeRunKind
    public let serverPhases: [SourceServerPhase]
    public let addonHooks: [SourceAddonHookPhase]
    public let hookFailures: [GMLuaSourceHookFailure]
    public let timerFailures: [GMLuaSourceTimerFailure]
    public let removedEntities: [GMLuaSourceEntityIdentity]
}

public enum GMLuaSourceRuntimeAdapterError: Error, CustomStringConvertible {
    case invalidServerRealm(GMLuaRealm)
    case invalidClientRealm(GMLuaRealm)
    case closedRuntime(GMLuaRealm)
    case transportMismatch(GMLuaRealm)
    case missingRuntimeSurface(GMLuaRealm, String)
    case timerClockMismatch(GMLuaRealm, expected: Double, actual: Double)
    case closedAdapter
    case clientAlreadyAttached
    case clientNotAttached
    case reentrantRun(String)
    case unknownEntity(GMLuaSourceEntityIdentity)
    case canonicalRemovalProjectionMissing(SourceCanonicalEntityIdentity)
    case canonicalMutationJournalCapacityExceeded(maximum: Int)
    case canonicalBodyGroupResolverUnavailable
    case canonicalBodyGroupLayoutResolverUnavailable
    case canonicalBodyGroupLayoutUnavailable(SourceEntityModelReference)
    case canonicalBodyGroupModelMissing(SourceCanonicalEntityIdentity)
    case canonicalAppearanceUnavailable(SourceEntityModelReference)
    case canonicalSkinModelMissing(SourceCanonicalEntityIdentity)
    case canonicalMaterialOverrideResolverUnavailable
    case canonicalPhysicsBodyAlreadyRegistered(SourcePhysicsBodyID)
    case canonicalPhysicsBodyMissing(SourcePhysicsBodyID)
    case canonicalPhysicsBodySetMismatch
    case canonicalPhysicsTickMismatch(expected: UInt64, received: UInt64)
    case forwardedConsoleCommandTransactionOutsidePump
    case forwardedConsoleCommandTransactionCheckpointChanged

    public var description: String {
        switch self {
        case let .invalidServerRealm(realm):
            return "Source adapter requires SERVER, got \(realm.rawValue)"
        case let .invalidClientRealm(realm):
            return "Source adapter attachment requires CLIENT, got \(realm.rawValue)"
        case let .closedRuntime(realm):
            return "Source adapter cannot use closed \(realm.rawValue) runtime"
        case let .transportMismatch(realm):
            return "\(realm.rawValue) runtime does not share the Source adapter transport"
        case let .missingRuntimeSurface(realm, surface):
            return "\(realm.rawValue) runtime has no \(surface)"
        case let .timerClockMismatch(realm, expected, actual):
            return "\(realm.rawValue) timer clock is \(actual), expected Source time \(expected)"
        case .closedAdapter:
            return "Source runtime adapter is closed"
        case .clientAlreadyAttached:
            return "CLIENT runtime is already attached to the Source adapter"
        case .clientNotAttached:
            return "CLIENT runtime is not attached to the Source adapter"
        case let .reentrantRun(operation):
            return "Source adapter cannot re-enter \(operation) on the active host thread"
        case let .unknownEntity(identity):
            return "Source entity handle \(identity.handle.rawValue) is stale or unknown"
        case let .canonicalRemovalProjectionMissing(identity):
            return "SERVER canonical removal did not match EHANDLE \(identity.handle.rawValue)"
        case let .canonicalMutationJournalCapacityExceeded(maximum):
            return "SERVER canonical mutation journal reached its bounded capacity of \(maximum) operations"
        case .canonicalBodyGroupResolverUnavailable:
            return "canonical Studio body-group resolver is unavailable"
        case .canonicalBodyGroupLayoutResolverUnavailable:
            return "canonical Studio body-group layout resolver is unavailable"
        case let .canonicalBodyGroupLayoutUnavailable(model):
            return "canonical Studio body-group layout is unavailable for \(model.path)"
        case let .canonicalBodyGroupModelMissing(identity):
            return "Source entity EHANDLE \(identity.handle.rawValue) has no Studio model for body-group resolution"
        case let .canonicalAppearanceUnavailable(model):
            return "canonical Studio appearance metadata is unavailable for \(model.path)"
        case let .canonicalSkinModelMissing(identity):
            return "Source entity EHANDLE \(identity.handle.rawValue) has no Studio model for skin-family resolution"
        case .canonicalMaterialOverrideResolverUnavailable:
            return "canonical Source GAME material override resolver is unavailable"
        case let .canonicalPhysicsBodyAlreadyRegistered(bodyID):
            return "canonical physics body \(bodyID.entityIdentity.handle.rawValue):\(bodyID.solidIndex) is already registered"
        case let .canonicalPhysicsBodyMissing(bodyID):
            return "canonical physics body \(bodyID.entityIdentity.handle.rawValue):\(bodyID.solidIndex) is unavailable"
        case .canonicalPhysicsBodySetMismatch:
            return "solver physics body set does not match the authoritative canonical prop set"
        case let .canonicalPhysicsTickMismatch(expected, received):
            return "solver physics tick \(received) does not match SERVER tick \(expected)"
        case .forwardedConsoleCommandTransactionOutsidePump:
            return "forwarded console command transaction requires the active transport pump boundary"
        case .forwardedConsoleCommandTransactionCheckpointChanged:
            return "forwarded console command changed a pre-existing canonical transaction prefix"
        }
    }
}

private struct GMLuaForwardedConsoleCommandCheckpoint {
    let journalPrefix: [SourceEntityReplicationOperation]
    let canonicalHandlePrefix: [UInt32]
    let canonicalPhysicsBodyPrefix: [
        SourcePhysicsBodyID: SourceCanonicalPropPhysicsBodyDefinition
    ]
    let canonicalPhysicsQueuedCreationPrefix: Set<SourcePhysicsBodyID>
    let cleanupJournalReservations: Int
}

private struct GMLuaForwardedConsoleCommandActionFailure: Error {
    let outcome: GMLuaRemoteConsoleCommandDispatchOutcome
}

private struct GMLuaForwardedConsoleCommandRollbackFailure:
    Error,
    CustomStringConvertible
{
    let original: Error?
    let rollback: Error

    var description: String {
        if let original {
            return "forwarded console command failed with \(original); " +
                "canonical rollback also failed with \(rollback)"
        }
        return "forwarded console command canonical rollback failed with \(rollback)"
    }
}

/// Opt-in bridge between one Source fixed-tick kernel and realm-local GLua
/// runtimes. The adapter, rather than GMLuaRuntime, owns simulation lifetime.
/// It never pumps net delivery; the M4 SharedSession pump remains host-driven.
public final class GMLuaSourceRuntimeAdapter: @unchecked Sendable {
    /// Host allocation guard for mutations produced between fixed-tick FIFO
    /// publication boundaries. This is not presented as a Source engine
    /// protocol value; it bounds a stalled host on iPad.
    public static let maximumPendingCanonicalEntityOperations =
        SourceEntityConstants.maxEdicts * 16

    private final class WeakClientAttachment {
        weak var runtime: GMLuaRuntime?
        let registry: GMLuaEntityRegistry
        let order: Int
        let timerOrigin: Double
        var fixedTickCount: Int32 = 0

        init(
            runtime: GMLuaRuntime,
            registry: GMLuaEntityRegistry,
            order: Int,
            timerOrigin: Double
        ) {
            self.runtime = runtime
            self.registry = registry
            self.order = order
            self.timerOrigin = timerOrigin
        }
    }

    private struct EntityRecord {
        let identity: GMLuaSourceEntityIdentity
        let entity: SourceEntity
        let kind: GMLuaEntityKind
        let userID: Int?
        let semanticValidity: Bool
    }

    public let serverRuntime: GMLuaRuntime
    public let netTransport: GMLuaNetTransport

    private let kernel: SourceRuntimeKernel
    private let canonicalEntities: SourceCanonicalEntityStore
    private let canonicalBodyGroupResolver: SourceCanonicalBodyGroupResolver?
    private let canonicalBodyGroupLayoutResolver:
        SourceCanonicalBodyGroupLayoutResolver?
    private let canonicalMaterialOverrideResolver:
        SourceCanonicalMaterialOverrideResolver?
    private let canonicalPropPhysicsAssetResolver:
        SourceCanonicalPropPhysicsAssetResolver
    private let mutationLock = NSRecursiveLock()
    let mirrorOwner = GMLuaSourceMirrorOwner()
    private var clientAttachments: [WeakClientAttachment] = []
    private var nextClientAttachmentOrder = 0
    private var entityRecordsByHandle: [UInt32: EntityRecord] = [:]
    private var entityHandleOrder: [UInt32] = []
    private var canonicalEntityHandleOrder: [UInt32] = []
    private let canonicalMutationJournalCapacity: Int
    private var canonicalMutationJournal: [SourceEntityReplicationOperation] = []
    /// Verified body definitions waiting for the authoritative solver, keyed
    /// by complete EHANDLE generation and solid index.
    private var canonicalPhysicsBodyDefinitions: [
        SourcePhysicsBodyID: SourceCanonicalPropPhysicsBodyDefinition
    ] = [:]
    /// Once a solver is connected its latest snapshot takes precedence over
    /// the immutable post-Spawn pending view. No synthetic solver state is
    /// inserted by this adapter.
    private var canonicalPhysicsBodySnapshots: [
        SourcePhysicsBodyID: SourcePhysicsBodySnapshot
    ] = [:]
    /// Bodies whose verified creation command already precedes queued PhysObj
    /// mutations in the shared global FIFO, but has not reached a fixed step.
    private var canonicalPhysicsQueuedCreationBodyIDs =
        Set<SourcePhysicsBodyID>()
    private var canonicalPhysicsObjectLuaBridge:
        SourceCanonicalPhysicsObjectGLuaBridge?
    /// Slots reserved for final `.remove` records at cleanup phases in the
    /// active SERVER tick. Ordinary hook mutations cannot consume them.
    private var canonicalCleanupJournalReservations = 0
    private var isRunningCanonicalServerTick = false
    private var isClosedStorage = false

    public convenience init(
        serverRuntime: GMLuaRuntime,
        canonicalNetworkVariableAllocationPolicy:
            SourceNetworkVariableAllocationPolicy = .default
    ) throws {
        try self.init(
            serverRuntime: serverRuntime,
            initialEntitySerialNumber: nil,
            canonicalNetworkVariableAllocationPolicy:
                canonicalNetworkVariableAllocationPolicy
        )
    }

    /// Installs the real filesystem/Studio validation boundary used before a
    /// canonical `prop_physics` may cross DispatchSpawn. The validator is not
    /// replaced with a permissive fallback when omitted.
    public convenience init(
        serverRuntime: GMLuaRuntime,
        canonicalModelValidator: SourceCanonicalModelValidator?,
        canonicalBodyGroupResolver: SourceCanonicalBodyGroupResolver? = nil,
        canonicalBodyGroupLayoutResolver:
            SourceCanonicalBodyGroupLayoutResolver? = nil,
        canonicalMaterialOverrideResolver:
            SourceCanonicalMaterialOverrideResolver? = nil,
        canonicalPropPhysicsAssetResolver:
            SourceCanonicalPropPhysicsAssetResolver? = nil,
        canonicalNetworkVariableAllocationPolicy:
            SourceNetworkVariableAllocationPolicy = .default
    ) throws {
        try self.init(
            serverRuntime: serverRuntime,
            initialEntitySerialNumber: nil,
            canonicalModelValidator: canonicalModelValidator,
            canonicalBodyGroupResolver: canonicalBodyGroupResolver,
            canonicalBodyGroupLayoutResolver:
                canonicalBodyGroupLayoutResolver,
            canonicalMaterialOverrideResolver:
                canonicalMaterialOverrideResolver,
            canonicalPropPhysicsAssetResolver:
                canonicalPropPhysicsAssetResolver,
            canonicalNetworkVariableAllocationPolicy:
                canonicalNetworkVariableAllocationPolicy
        )
    }

    deinit {
        netTransport.withExclusiveLifecycleBoundary {
            mutationLock.lock()
            defer { mutationLock.unlock() }
            _ = teardownLocked()
        }
    }

    public var isClosed: Bool {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        return isClosedStorage
    }

    /// Idempotently releases every Source handle and realm-local mirror owned
    /// by this adapter. A close attempted recursively from an adapter callback
    /// is rejected so teardown can never invalidate an entity mid-operation.
    public func close() throws {
        guard !isAdapterOperationActiveOnCurrentThread else {
            throw GMLuaSourceRuntimeAdapterError.reentrantRun("adapter close")
        }
        let cleanupError = netTransport.withExclusiveLifecycleBoundary {
            mutationLock.lock()
            defer { mutationLock.unlock() }
            return teardownLocked()
        }
        if let cleanupError {
            throw cleanupError
        }
    }

    /// Deterministic serial seeding is internal test support; production keeps
    /// SourceEntityList's independently randomized slot serials.
    init(
        serverRuntime: GMLuaRuntime,
        initialEntitySerialNumber: Int?,
        canonicalModelValidator: SourceCanonicalModelValidator? = nil,
        canonicalBodyGroupResolver: SourceCanonicalBodyGroupResolver? = nil,
        canonicalBodyGroupLayoutResolver:
            SourceCanonicalBodyGroupLayoutResolver? = nil,
        canonicalMaterialOverrideResolver:
            SourceCanonicalMaterialOverrideResolver? = nil,
        canonicalPropPhysicsAssetResolver:
            SourceCanonicalPropPhysicsAssetResolver? = nil,
        canonicalNetworkVariableAllocationPolicy:
            SourceNetworkVariableAllocationPolicy = .default,
        canonicalMutationJournalCapacity: Int =
            GMLuaSourceRuntimeAdapter.maximumPendingCanonicalEntityOperations
    ) throws {
        guard serverRuntime.realm == .server else {
            throw GMLuaSourceRuntimeAdapterError.invalidServerRealm(serverRuntime.realm)
        }
        guard !serverRuntime.isClosed else {
            throw GMLuaSourceRuntimeAdapterError.closedRuntime(.server)
        }
        guard let transport = serverRuntime.netTransport else {
            throw GMLuaSourceRuntimeAdapterError.missingRuntimeSurface(.server, "net transport")
        }
        guard serverRuntime.entityRegistry != nil else {
            throw GMLuaSourceRuntimeAdapterError.missingRuntimeSurface(.server, "Entity registry")
        }
        guard let timerScheduler = serverRuntime.timerScheduler else {
            throw GMLuaSourceRuntimeAdapterError.missingRuntimeSurface(.server, "timer scheduler")
        }
        guard let consoleDispatcher = serverRuntime.consoleCommandDispatcher else {
            throw GMLuaSourceRuntimeAdapterError.missingRuntimeSurface(
                .server,
                "console dispatcher"
            )
        }
        let initialSourceTime = Double(SourceGlobalVars().currentTime)
        let initialTimerTime = timerScheduler.currentTime
        guard initialTimerTime == initialSourceTime else {
            throw GMLuaSourceRuntimeAdapterError.timerClockMismatch(
                .server,
                expected: initialSourceTime,
                actual: initialTimerTime
            )
        }
        self.serverRuntime = serverRuntime
        netTransport = transport
        precondition(canonicalMutationJournalCapacity > 0)
        self.canonicalMutationJournalCapacity = canonicalMutationJournalCapacity
        let entityList = SourceEntityList(
            initialSerialNumber: initialEntitySerialNumber
        )
        kernel = SourceRuntimeKernel(entityList: entityList)
        canonicalEntities = SourceCanonicalEntityStore(
            entityList: entityList,
            modelValidator: canonicalModelValidator,
            networkVariableAllocationPolicy:
                canonicalNetworkVariableAllocationPolicy
        )
        self.canonicalBodyGroupResolver = canonicalBodyGroupResolver
        self.canonicalBodyGroupLayoutResolver =
            canonicalBodyGroupLayoutResolver
        self.canonicalMaterialOverrideResolver =
            canonicalMaterialOverrideResolver
        self.canonicalPropPhysicsAssetResolver =
            canonicalPropPhysicsAssetResolver ?? { _ in .unavailable }
        consoleDispatcher.connectForwardedCommandTransactionHost(self)
    }

    public var attachedClientCount: Int {
        netTransport.withExclusiveLifecycleBoundary {
            mutationLock.lock()
            defer { mutationLock.unlock() }
            pruneClientAttachmentsLocked()
            return clientAttachments.count
        }
    }

    /// Read-only fixed-tick globals snapshot. The mutable kernel/entity list is
    /// deliberately not exposed.
    public var serverGlobals: SourceGlobalVars {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        return kernel.globals
    }

    /// Stable canonical snapshots for the next SERVER-owned replication
    /// packet. CLIENT registries are intentionally absent from this API; their
    /// only canonical source is the SharedSession FIFO.
    public var canonicalEntitySnapshots: [SourceCanonicalEntitySnapshot] {
        netTransport.withExclusiveLifecycleBoundary {
            mutationLock.lock()
            defer { mutationLock.unlock() }
            guard !isClosedStorage, !serverRuntime.isClosed else { return [] }
            return canonicalEntities.orderedSnapshots
        }
    }

    /// Number of authoritative operations not yet committed to the shared
    /// transport FIFO. Direct SERVER Lua between ticks only grows this value;
    /// it never mutates CLIENT state synchronously.
    public var pendingCanonicalEntityOperationCount: Int {
        netTransport.withExclusiveLifecycleBoundary {
            mutationLock.lock()
            defer { mutationLock.unlock() }
            guard !isClosedStorage, !serverRuntime.isClosed else { return 0 }
            return canonicalMutationJournal.count
        }
    }

    /// Publishes the exact pending prefix as one ordered delta transaction.
    /// A throwing publisher leaves the prefix byte-for-byte intact for retry.
    @discardableResult
    public func publishPendingCanonicalEntityOperations(
        using publisher: ([SourceEntityReplicationOperation]) throws -> Int
    ) throws -> Int {
        try withMutationBoundary {
            guard !canonicalMutationJournal.isEmpty else { return 0 }
            let pendingPrefix = canonicalMutationJournal
            let result = try publisher(pendingPrefix)
            canonicalMutationJournal.removeFirst(pendingPrefix.count)
            return result
        }
    }

    /// Startup uses one full canonical snapshot rather than replaying the
    /// world/Player construction history as deltas. Callers discard only after
    /// that snapshot has been successfully enqueued.
    @discardableResult
    public func discardPendingCanonicalEntityOperations() throws -> Int {
        try withMutationBoundary {
            let discarded = canonicalMutationJournal.count
            canonicalMutationJournal.removeAll(keepingCapacity: true)
            return discarded
        }
    }

    public func canonicalSnapshot(
        for identity: SourceCanonicalEntityIdentity
    ) -> SourceCanonicalEntitySnapshot? {
        netTransport.withExclusiveLifecycleBoundary {
            mutationLock.lock()
            defer { mutationLock.unlock() }
            guard !isClosedStorage, !serverRuntime.isClosed else { return nil }
            return canonicalEntities.snapshot(for: identity)
        }
    }

    public func primaryCanonicalPhysicsObject(
        for entity: SourceCanonicalEntityIdentity
    ) -> SourceCanonicalPhysicsObjectSnapshot? {
        netTransport.withExclusiveLifecycleBoundary {
            mutationLock.lock()
            defer { mutationLock.unlock() }
            guard !isClosedStorage, !serverRuntime.isClosed else { return nil }
            let bodyID = canonicalPhysicsBodyDefinitions.keys
                .filter { $0.entityIdentity == entity }
                .min { $0.solidIndex < $1.solidIndex }
            guard let bodyID else { return nil }
            return canonicalPhysicsObjectLocked(for: bodyID)
        }
    }

    public func canonicalPhysicsObject(
        for bodyID: SourcePhysicsBodyID
    ) -> SourceCanonicalPhysicsObjectSnapshot? {
        netTransport.withExclusiveLifecycleBoundary {
            mutationLock.lock()
            defer { mutationLock.unlock() }
            guard !isClosedStorage, !serverRuntime.isClosed else { return nil }
            return canonicalPhysicsObjectLocked(for: bodyID)
        }
    }

    public func enqueueCanonicalPhysicsObjectMutation(
        _ command: SourcePhysicsBodyMutationCommand
    ) throws {
        try withMutationBoundary {
            let bodyID = command.bodyID
            guard let definition = canonicalPhysicsBodyDefinitions[bodyID],
                  let entity = canonicalEntities.snapshot(
                      for: bodyID.entityIdentity
                  ),
                  entity.kind == .propPhysics,
                  entity.lifecycle == .spawned || entity.lifecycle == .active
            else {
                throw GMLuaSourceRuntimeAdapterError
                    .canonicalPhysicsBodyMissing(bodyID)
            }

            var queued: [SourceCanonicalQueuedPhysicsBodyCommand] = []
            let needsCreation = canonicalPhysicsBodySnapshots[bodyID] == nil &&
                !canonicalPhysicsQueuedCreationBodyIDs.contains(bodyID)
            if needsCreation {
                queued.append(.create(try SourcePhysicsBodyCreationCommand(
                    bodyID: bodyID,
                    shape: definition.shape,
                    massProperties: definition.massProperties,
                    transform: entity.transform,
                    linearVelocity: entity.motion.linearVelocity,
                    angularVelocity: entity.motion.angularVelocity,
                    damping: definition.damping,
                    motionType: definition.motionType,
                    materialIndex: definition.materialIndex,
                    isGravityEnabled: definition.isGravityEnabled,
                    isCollisionEnabled: definition.isCollisionEnabled,
                    startsAwake: definition.startsAwake
                )))
            }
            queued.append(.mutate(command))
            _ = try netTransport.enqueueCanonicalPhysicsBodyCommands(queued)
            if needsCreation {
                canonicalPhysicsQueuedCreationBodyIDs.insert(bodyID)
            }
        }
    }

    /// Captures the exact authoritative prop set for one solver step.
    ///
    /// The mutation journal is preflighted for the worst case (every live body
    /// moves) before the environment advances. This prevents an already-
    /// committed rigid-body step from discovering that its Entity snapshots
    /// cannot be queued for CLIENT replication.
    public func prepareCanonicalPropPhysicsStep() throws
        -> [SourceCanonicalPropPhysicsInput]
    {
        try withMutationBoundary {
            var inputs: [SourceCanonicalPropPhysicsInput] = []
            inputs.reserveCapacity(canonicalPhysicsBodyDefinitions.count)
            var liveBodyCount = 0
            for rawHandle in canonicalEntityHandleOrder {
                let identity = SourceCanonicalEntityIdentity(
                    handle: SourceBaseHandle.unsafeFromIndex(rawHandle)
                )
                guard let entity = canonicalEntities.snapshot(for: identity),
                      entity.kind == .propPhysics else { continue }
                let definitionEntry = canonicalPhysicsBodyDefinitions
                    .filter { $0.key.entityIdentity == identity }
                    .min { $0.key.solidIndex < $1.key.solidIndex }
                let definition: SourceCanonicalPropPhysicsBodyDefinition?
                switch entity.lifecycle {
                case .spawned, .active:
                    guard let definitionEntry else {
                        throw GMLuaSourceRuntimeAdapterError
                            .canonicalPhysicsBodyMissing(try SourcePhysicsBodyID(
                                entityIdentity: identity,
                                solidIndex: 0
                            ))
                    }
                    if entity.moveType == .none, entity.isNotSolid {
                        // Stock remover keeps the Entity alive for its effect
                        // timer, but it must leave neither a traceable nor a
                        // simulated rigid body during that interval.
                        definition = nil
                    } else {
                        definition = try effectiveCanonicalPhysicsDefinition(
                            definitionEntry.value,
                            for: entity
                        )
                        liveBodyCount += 1
                    }
                case .created, .pendingRemoval, .removed:
                    definition = nil
                }
                inputs.append(try SourceCanonicalPropPhysicsInput(
                    entity: entity,
                    bodyDefinition: definition
                ))
            }
            try preflightCanonicalMutationJournalLocked(
                additionalOperations: liveBodyCount
            )
            return inputs
        }
    }

    /// Commits one validated solver result back to canonical Entity state.
    /// Only solver-authored pose/velocity fields change; identical sleeping
    /// bodies do not consume revisions or replication operations.
    public func commitCanonicalPropPhysicsStep(
        _ step: SourceCanonicalPropPhysicsStepSnapshot
    ) throws {
        try withMutationBoundary {
            let expectedTick = UInt64(max(kernel.globals.tickCount, 0))
            guard step.simulationTick == expectedTick else {
                throw GMLuaSourceRuntimeAdapterError.canonicalPhysicsTickMismatch(
                    expected: expectedTick,
                    received: step.simulationTick
                )
            }

            let expectedBodyIDs = Set(canonicalPhysicsBodyDefinitions.keys.filter {
                bodyID in
                guard let entity = canonicalEntities.snapshot(
                    for: bodyID.entityIdentity
                ), entity.kind == .propPhysics,
                   entity.lifecycle == .spawned || entity.lifecycle == .active
                else { return false }
                return entity.moveType == .vPhysics
            })
            let receivedBodyIDs = Set(step.bodies.map(\.bodyID))
            guard expectedBodyIDs == receivedBodyIDs else {
                throw GMLuaSourceRuntimeAdapterError
                    .canonicalPhysicsBodySetMismatch
            }

            var bodySnapshots: [SourcePhysicsBodyID: SourcePhysicsBodySnapshot] = [:]
            bodySnapshots.reserveCapacity(step.bodies.count)
            var changedMotions: [SourceCanonicalPropPhysicsMotionSnapshot] = []
            changedMotions.reserveCapacity(step.bodies.count)
            for motion in step.bodies {
                guard let definition = canonicalPhysicsBodyDefinitions[motion.bodyID],
                      let entity = canonicalEntities.snapshot(
                        for: motion.bodyID.entityIdentity
                      ), entity.kind == .propPhysics,
                      entity.lifecycle == .spawned || entity.lifecycle == .active else {
                    throw GMLuaSourceRuntimeAdapterError
                        .canonicalPhysicsBodyMissing(motion.bodyID)
                }
                bodySnapshots[motion.bodyID] = try SourcePhysicsBodySnapshot(
                    bodyID: motion.bodyID,
                    shape: definition.shape,
                    massProperties: motion.massProperties,
                    transform: motion.transform,
                    linearVelocity: motion.linearVelocity,
                    angularVelocity: motion.angularVelocity,
                    damping: motion.damping,
                    motionType: definition.motionType,
                    materialIndex: motion.materialIndex,
                    isMotionEnabled: motion.isMotionEnabled,
                    isGravityEnabled: motion.isGravityEnabled,
                    isCollisionEnabled: motion.isCollisionEnabled,
                    isSleeping: motion.isSleeping,
                    simulationTick: motion.simulationTick,
                    isDragEnabled: motion.isDragEnabled,
                    buoyancyRatio: motion.buoyancyRatio
                )
                if entity.transform != motion.transform ||
                    entity.motion.linearVelocity != motion.linearVelocity ||
                    entity.motion.angularVelocity != motion.angularVelocity {
                    changedMotions.append(motion)
                }
            }
            try preflightCanonicalMutationJournalLocked(
                additionalOperations: changedMotions.count
            )
            for motion in changedMotions {
                _ = try canonicalEntities.update(
                    motion.bodyID.entityIdentity,
                    { state in motion.apply(to: &state) },
                    publishing: { [unowned self] snapshot in
                        _ = try self.requiredServerRegistryLocked()
                            .applyAuthoritativeSnapshot(snapshot)
                        self.canonicalMutationJournal.append(.update(snapshot))
                    }
                )
            }
            canonicalPhysicsBodySnapshots = bodySnapshots
            canonicalPhysicsQueuedCreationBodyIDs.removeAll(
                keepingCapacity: true
            )
        }
    }

    /// Returns the injected filesystem/Studio verdict. A closed adapter or an
    /// omitted validator remains unavailable and is never promoted to valid.
    public func validateCanonicalModel(
        _ model: SourceEntityModelReference,
        for kind: SourceCanonicalEntityKind
    ) -> SourceCanonicalModelValidation {
        netTransport.withExclusiveLifecycleBoundary {
            mutationLock.lock()
            defer { mutationLock.unlock() }
            guard !isClosedStorage, !serverRuntime.isClosed else {
                return .unavailable
            }
            return canonicalEntities.validateModel(model, for: kind)
        }
    }

    /// Exact-byte, independently attested `util.IsValidProp` verdict. This is
    /// deliberately separate from render-only Studio model validation.
    public func validateCanonicalPropPhysicsModel(
        _ model: SourceEntityModelReference
    ) -> SourceCanonicalModelValidation {
        netTransport.withExclusiveLifecycleBoundary {
            mutationLock.lock()
            defer { mutationLock.unlock() }
            guard !isClosedStorage, !serverRuntime.isClosed else {
                return .unavailable
            }
            return canonicalPropPhysicsAssetResolver(model).modelValidation
        }
    }

    /// Installs the SERVER native ABI only when the host explicitly connects
    /// this adapter. Runtime construction by itself still cannot fake Entity
    /// mutation support.
    public func installCanonicalEntityLuaBridge() throws {
        try withMutationBoundary {
            try SourceCanonicalEntityGLuaBridge.install(
                into: serverRuntime,
                host: self
            )
            try SourceCanonicalEntityNetworkVariableGLuaBridge.install(
                into: serverRuntime,
                serverHost: self
            )
            try SourceCanonicalEntitySpawnMetadataGLuaBridge.install(
                into: serverRuntime,
                serverHost: self
            )
        }
    }

    /// Installs and retains the realm-local full-EHANDLE PhysObj userdata
    /// cache. Runtime construction alone does not imply a physics host.
    public func installCanonicalPhysicsObjectLuaBridge(
        materialNames: SourcePhysicsMaterialNameTable? = nil
    ) throws {
        try withMutationBoundary {
            guard canonicalPhysicsObjectLuaBridge == nil else { return }
            canonicalPhysicsObjectLuaBridge = try
                SourceCanonicalPhysicsObjectGLuaBridge.install(
                    into: serverRuntime,
                    host: self,
                    materialNames: materialNames
                )
        }
    }

    /// Creates one engine-owned world, Player, or prop in the exact entity
    /// list driven by this adapter's SourceRuntimeKernel. Only SERVER receives
    /// the immediate authoritative projection.
    @discardableResult
    public func createCanonicalEntity(
        kind: SourceCanonicalEntityKind,
        at entryIndex: Int? = nil,
        state: SourceCanonicalEntityState? = nil,
        playerUserID: Int? = nil
    ) throws -> SourceCanonicalEntitySnapshot {
        try withMutationBoundary {
            try preflightCanonicalMutationJournalLocked(additionalOperations: 1)
            var initialState = state ?? .defaults(for: kind)
            initialState.creationTime = kernel.globals.currentTime
            let snapshot = try canonicalEntities.create(
                kind: kind,
                at: entryIndex,
                state: initialState,
                publishing: { [unowned self] snapshot in
                    _ = try self.requiredServerRegistryLocked()
                        .applyAuthoritativeSnapshot(
                            snapshot,
                            userID: playerUserID
                        )
                    self.canonicalMutationJournal.append(.create(snapshot))
                }
            )
            canonicalEntityHandleOrder.append(snapshot.identity.handle.rawValue)
            return snapshot
        }
    }

    /// Creates an unowned world SWEP from the exact registered class and
    /// validated inherited WorldModel. Unlike Player:Give, this route does not
    /// enter a Player inventory and therefore remains solid/traceable for
    /// authoritative +use/contact pickup.
    @discardableResult
    public func createCanonicalWorldWeapon(
        className: String,
        worldModel: SourceEntityModelReference
    ) throws -> SourceCanonicalEntitySnapshot {
        try withMutationBoundary {
            guard SourceCanonicalEntityKind
                .isStructurallyValidWeaponClassName(className) else {
                throw SourceCanonicalEntityError.invalidClassName(
                    kind: .weapon,
                    className: className
                )
            }
            switch canonicalEntities.validateModel(worldModel, for: .weapon) {
            case .valid:
                break
            case .invalid:
                throw SourceCanonicalEntityError.modelRejected(worldModel)
            case .unavailable:
                throw SourceCanonicalEntityError
                    .modelValidationUnavailable(worldModel)
            }

            try preflightCanonicalMutationJournalLocked(
                additionalOperations: 1
            )
            var state = SourceCanonicalEntityState.defaults(for: .weapon)
            state.creationTime = kernel.globals.currentTime
            state.model = worldModel
            state.isNotSolid = false
            let snapshot = try canonicalEntities.create(
                kind: .weapon,
                className: className,
                state: state,
                publishing: { [unowned self] snapshot in
                    _ = try self.requiredServerRegistryLocked()
                        .applyAuthoritativeSnapshot(snapshot)
                    self.canonicalMutationJournal.append(.create(snapshot))
                }
            )
            canonicalEntityHandleOrder.append(
                snapshot.identity.handle.rawValue
            )
            return snapshot
        }
    }

    /// Applies one atomic engine state mutation and republishes that immutable
    /// snapshot to SERVER without creating a second realm-owned state object.
    @discardableResult
    public func updateCanonicalEntity(
        _ identity: SourceCanonicalEntityIdentity,
        _ mutation: (inout SourceCanonicalEntityState) throws -> Void
    ) throws -> SourceCanonicalEntitySnapshot {
        try withMutationBoundary {
            try requireCanonicalServerProjectionLocked(identity)
            try preflightCanonicalMutationJournalLocked(additionalOperations: 1)
            return try canonicalEntities.update(
                identity,
                mutation,
                publishing: { [unowned self] snapshot in
                    _ = try self.requiredServerRegistryLocked()
                        .applyAuthoritativeSnapshot(snapshot)
                    self.canonicalMutationJournal.append(.update(snapshot))
                }
            )
        }
    }

    /// Validates a public GLua material name against the mounted Source GAME
    /// filesystem, then commits only the resolver-produced canonical value.
    /// Reapplying the same normalized VMT is a true no-op.
    @discardableResult
    public func setCanonicalMaterialOverride(
        _ materialName: String,
        for identity: SourceCanonicalEntityIdentity
    ) throws -> SourceCanonicalEntitySnapshot {
        try withMutationBoundary {
            try requireCanonicalServerProjectionLocked(identity)
            guard let current = canonicalEntities.snapshot(for: identity) else {
                throw GMLuaSourceRuntimeAdapterError.unknownEntity(identity)
            }
            guard let resolver = canonicalMaterialOverrideResolver else {
                throw GMLuaSourceRuntimeAdapterError
                    .canonicalMaterialOverrideResolverUnavailable
            }
            let resolved = try resolver(materialName)
            guard resolved != current.materialOverride else { return current }
            try preflightCanonicalMutationJournalLocked(additionalOperations: 1)
            return try canonicalEntities.update(
                identity,
                { candidate in
                    candidate.materialOverride = resolved
                },
                publishing: { [unowned self] snapshot in
                    _ = try self.requiredServerRegistryLocked()
                        .applyAuthoritativeSnapshot(snapshot)
                    self.canonicalMutationJournal.append(.update(snapshot))
                }
            )
        }
    }

    /// Implements Player:Give as one engine-owned Weapon allocation followed
    /// by one Player inventory snapshot update. Every step uses the canonical
    /// SourceEntityList EHANDLE and the ordinary SERVER replication journal;
    /// no realm-local gameplay mirror participates.
    @discardableResult
    public func giveCanonicalWeapon(
        className: String,
        to player: SourceCanonicalEntityIdentity
    ) throws -> SourceCanonicalEntitySnapshot {
        try withMutationBoundary {
            try requireCanonicalServerProjectionLocked(player)
            guard let currentPlayer = canonicalEntities.snapshot(for: player),
                  currentPlayer.kind == .player else {
                throw GMLuaSourceRuntimeAdapterError.unknownEntity(player)
            }
            if let existing = currentPlayer.weaponInventory.weapon(
                className: className
            ) {
                guard let weapon = canonicalEntities.snapshot(
                    for: existing.identity
                ), weapon.kind == .weapon,
                   weapon.className.caseInsensitiveCompare(existing.className)
                    == .orderedSame,
                   weapon.lifecycle != .pendingRemoval,
                   weapon.lifecycle != .removed else {
                    throw SourceCanonicalEntityError.invalidWeaponInventory(
                        "stored Weapon class does not resolve to its live full EHANDLE"
                    )
                }
                return weapon
            }

            guard SourceCanonicalEntityKind
                .isStructurallyValidWeaponClassName(className) else {
                throw SourceCanonicalEntityError.invalidClassName(
                    kind: .weapon,
                    className: className
                )
            }
            // Create, DispatchSpawn, Activate, then Player inventory update.
            // All four immutable snapshots retain FIFO order.
            try preflightCanonicalMutationJournalLocked(additionalOperations: 4)
            let journalCheckpoint = canonicalMutationJournal.count
            var state = SourceCanonicalEntityState.defaults(for: .weapon)
            state.creator = player
            state.creationTime = kernel.globals.currentTime
            // Inventory-owned weapons do not participate in world traces.
            // DropWeapon explicitly reverses this flag on the same EHANDLE.
            state.isNotSolid = true
            let registry = try requiredServerRegistryLocked()
            let created = try canonicalEntities.create(
                kind: .weapon,
                className: className,
                state: state,
                publishing: { [unowned self] snapshot in
                    _ = try registry.applyAuthoritativeSnapshot(snapshot)
                    self.canonicalMutationJournal.append(.create(snapshot))
                }
            )
            canonicalEntityHandleOrder.append(created.identity.handle.rawValue)

            do {
                _ = try canonicalEntities.spawn(
                    created.identity,
                    publishing: { [unowned self] snapshot in
                        _ = try registry.applyAuthoritativeSnapshot(snapshot)
                        self.canonicalMutationJournal.append(.update(snapshot))
                    }
                )
                let active = try canonicalEntities.activate(
                    created.identity,
                    publishing: { [unowned self] snapshot in
                        _ = try registry.applyAuthoritativeSnapshot(snapshot)
                        self.canonicalMutationJournal.append(.update(snapshot))
                    }
                )
                _ = try canonicalEntities.update(
                    player,
                    { candidate in
                        let inserted = candidate.weaponInventory.insert(
                            SourceCanonicalWeaponRecord(
                                identity: active.identity,
                                className: active.className
                            )
                        )
                        guard inserted else {
                            throw SourceCanonicalEntityError.invalidWeaponInventory(
                                "duplicate Weapon class or EHANDLE"
                            )
                        }
                    },
                    publishing: { [unowned self] snapshot in
                        _ = try registry.applyAuthoritativeSnapshot(snapshot)
                        self.canonicalMutationJournal.append(.update(snapshot))
                    }
                )
                return active
            } catch {
                // Nothing has left the pending host journal. Remove only this
                // exact new handle and its journal suffix; pre-existing Player
                // state remains untouched because store update publishes
                // before it commits.
                _ = try canonicalEntities.rollbackUnpublished(
                    created.identity,
                    publishing: { removal in
                        guard try registry.applyAuthoritativeRemoval(removal) else {
                            throw GMLuaSourceRuntimeAdapterError
                                .canonicalRemovalProjectionMissing(removal.identity)
                        }
                    }
                )
                guard canonicalEntityHandleOrder.last ==
                        created.identity.handle.rawValue else {
                    throw GMLuaSourceRuntimeAdapterError
                        .forwardedConsoleCommandTransactionCheckpointChanged
                }
                canonicalEntityHandleOrder.removeLast()
                canonicalMutationJournal.removeLast(
                    canonicalMutationJournal.count - journalCheckpoint
                )
                throw error
            }
        }
    }

    /// Source SelectWeapon is a no-op when the Player does not own the class.
    /// A real selection changes only the canonical Player snapshot and enters
    /// the same ordered FIFO as the preceding Weapon creation.
    @discardableResult
    public func selectCanonicalWeapon(
        className: String,
        for player: SourceCanonicalEntityIdentity
    ) throws -> SourceCanonicalEntitySnapshot {
        try withMutationBoundary {
            try requireCanonicalServerProjectionLocked(player)
            guard let current = canonicalEntities.snapshot(for: player),
                  current.kind == .player else {
                throw GMLuaSourceRuntimeAdapterError.unknownEntity(player)
            }
            guard let record = current.weaponInventory.weapon(
                className: className
            ), let weapon = canonicalEntities.snapshot(for: record.identity),
               weapon.kind == .weapon,
               weapon.className.caseInsensitiveCompare(record.className)
                == .orderedSame,
               weapon.lifecycle != .pendingRemoval,
               weapon.lifecycle != .removed else { return current }
            guard current.weaponInventory.activeWeapon != record.identity else {
                return current
            }
            try preflightCanonicalMutationJournalLocked(additionalOperations: 1)
            return try canonicalEntities.update(
                player,
                { candidate in
                    guard candidate.weaponInventory.select(
                        className: className
                    ) else {
                        throw SourceCanonicalEntityError.invalidWeaponInventory(
                            "selected Weapon class disappeared during transaction"
                        )
                    }
                },
                publishing: { [unowned self] snapshot in
                    _ = try self.requiredServerRegistryLocked()
                        .applyAuthoritativeSnapshot(snapshot)
                    self.canonicalMutationJournal.append(.update(snapshot))
                }
            )
        }
    }

    /// Commits one legacy NW string through the same prospective
    /// snapshot/registry/journal transaction as every canonical Entity field.
    /// Repeating the exact key/value bytes is a no-op and consumes neither a
    /// revision nor a replication operation.
    @discardableResult
    public func setCanonicalNetworkedString(
        _ value: SourceNetworkVariableString,
        forKey key: SourceNetworkVariableString,
        on identity: SourceCanonicalEntityIdentity
    ) throws -> SourceCanonicalEntitySnapshot {
        try withMutationBoundary {
            try requireCanonicalServerProjectionLocked(identity)
            guard let current = canonicalEntities.snapshot(for: identity) else {
                throw GMLuaSourceRuntimeAdapterError.unknownEntity(identity)
            }
            guard current.networkVariables.string(forKey: key) != value else {
                return current
            }
            try preflightCanonicalMutationJournalLocked(additionalOperations: 1)
            return try canonicalEntities.update(
                identity,
                { candidate in
                    _ = candidate.networkVariables.setString(value, forKey: key)
                },
                publishing: { [unowned self] snapshot in
                    _ = try self.requiredServerRegistryLocked()
                        .applyAuthoritativeSnapshot(snapshot)
                    self.canonicalMutationJournal.append(.update(snapshot))
                }
            )
        }
    }

    /// `SetNWInt` stores the documented Source float bits without rounding.
    /// An identical bit pattern is a no-op; a changed value is published
    /// atomically to SERVER and the pending FIFO journal.
    @discardableResult
    public func setCanonicalNetworkedInt(
        _ value: SourceNetworkedIntValue,
        forKey key: SourceNetworkVariableString,
        on identity: SourceCanonicalEntityIdentity
    ) throws -> SourceCanonicalEntitySnapshot {
        try withMutationBoundary {
            try requireCanonicalServerProjectionLocked(identity)
            guard let current = canonicalEntities.snapshot(for: identity) else {
                throw GMLuaSourceRuntimeAdapterError.unknownEntity(identity)
            }
            guard current.networkVariables.int(forKey: key) != value else {
                return current
            }
            try preflightCanonicalMutationJournalLocked(additionalOperations: 1)
            return try canonicalEntities.update(
                identity,
                { candidate in
                    _ = candidate.networkVariables.setInt(value, forKey: key)
                },
                publishing: { [unowned self] snapshot in
                    _ = try self.requiredServerRegistryLocked()
                        .applyAuthoritativeSnapshot(snapshot)
                    self.canonicalMutationJournal.append(.update(snapshot))
                }
            )
        }
    }

    /// Publishes the engine spawn-effect bit in the same canonical Entity
    /// stream as lifecycle and transform state. The bit is consumed by CLIENT
    /// only when that EHANDLE generation first appears over replication.
    @discardableResult
    public func setCanonicalSpawnEffect(
        _ enabled: Bool,
        on identity: SourceCanonicalEntityIdentity
    ) throws -> SourceCanonicalEntitySnapshot {
        try withMutationBoundary {
            try requireCanonicalServerProjectionLocked(identity)
            guard let current = canonicalEntities.snapshot(for: identity) else {
                throw GMLuaSourceRuntimeAdapterError.unknownEntity(identity)
            }
            guard current.spawnEffect != enabled else { return current }
            try preflightCanonicalMutationJournalLocked(additionalOperations: 1)
            return try canonicalEntities.update(
                identity,
                { candidate in
                    candidate.spawnEffect = enabled
                },
                publishing: { [unowned self] snapshot in
                    _ = try self.requiredServerRegistryLocked()
                        .applyAuthoritativeSnapshot(snapshot)
                    self.canonicalMutationJournal.append(.update(snapshot))
                }
            )
        }
    }

    /// Installs or clears one already validated collision property through the
    /// same copy/validate/publish transaction as every canonical state change.
    /// The caller remains responsible for sourcing non-nil values from an
    /// authoritative collision/physics asset.
    @discardableResult
    public func setCanonicalCollisionProperty(
        _ property: SourceCollisionProperty?,
        for identity: SourceCanonicalEntityIdentity
    ) throws -> SourceCanonicalEntitySnapshot {
        try updateCanonicalEntity(identity) { candidate in
            candidate.collisionProperty = property
        }
    }

    /// Validates raw local collision bounds before entering the adapter
    /// mutation boundary. Rejected bounds therefore consume no revision,
    /// registry publication, or SERVER replication-journal entry.
    @discardableResult
    public func setCanonicalCollisionBounds(
        mins: SourceVector3,
        maxs: SourceVector3,
        for identity: SourceCanonicalEntityIdentity
    ) throws -> SourceCanonicalEntitySnapshot {
        let property = try SourceCollisionProperty(mins: mins, maxs: maxs)
        return try setCanonicalCollisionProperty(property, for: identity)
    }

    /// Returns the exact Studio bodypart bases/counts for one validated model.
    /// An absent resolver or absent bytes remains an explicit unsupported
    /// boundary; it is not equivalent to a model with zero bodyparts.
    public func canonicalBodyGroupLayout(
        for model: SourceEntityModelReference
    ) throws -> SourceStudioBodyGroupLayout {
        try netTransport.withExclusiveLifecycleBoundary {
            mutationLock.lock()
            defer { mutationLock.unlock() }
            try ensureOpenLocked()
            return try resolvedCanonicalBodyGroupLayoutLocked(for: model)
        }
    }

    /// Returns names, submodel names, and skin-family count from the exact
    /// Studio asset already selected by the body-group resolver. An attested
    /// base/count-only layout cannot be promoted to full appearance metadata.
    public func canonicalModelAppearance(
        for model: SourceEntityModelReference
    ) throws -> SourceStudioModelAppearanceLayout {
        try netTransport.withExclusiveLifecycleBoundary {
            mutationLock.lock()
            defer { mutationLock.unlock() }
            try ensureOpenLocked()
            let layout = try resolvedCanonicalBodyGroupLayoutLocked(for: model)
            guard let appearance = layout.appearance else {
                throw GMLuaSourceRuntimeAdapterError
                    .canonicalAppearanceUnavailable(model)
            }
            return appearance
        }
    }

    /// Validates one Studio skin-family index against the current model before
    /// committing the canonical state and its SERVER replication journal.
    /// Rejected values consume neither a revision nor a FIFO operation.
    @discardableResult
    public func setCanonicalSkin(
        _ skinFamily: Int,
        for identity: SourceCanonicalEntityIdentity
    ) throws -> SourceCanonicalEntitySnapshot {
        try withMutationBoundary {
            try requireCanonicalServerProjectionLocked(identity)
            guard let current = canonicalEntities.snapshot(for: identity) else {
                throw GMLuaSourceRuntimeAdapterError.unknownEntity(identity)
            }
            guard let model = current.model else {
                throw GMLuaSourceRuntimeAdapterError
                    .canonicalSkinModelMissing(identity)
            }
            let layout = try resolvedCanonicalBodyGroupLayoutLocked(for: model)
            guard let appearance = layout.appearance else {
                throw GMLuaSourceRuntimeAdapterError
                    .canonicalAppearanceUnavailable(model)
            }
            try appearance.validateSkinFamily(skinFamily)
            guard current.skin != skinFamily else { return current }

            try preflightCanonicalMutationJournalLocked(additionalOperations: 1)
            return try canonicalEntities.update(
                identity,
                { candidate in
                    candidate.skin = skinFamily
                },
                publishing: { [unowned self] snapshot in
                    _ = try self.requiredServerRegistryLocked()
                        .applyAuthoritativeSnapshot(snapshot)
                    self.canonicalMutationJournal.append(.update(snapshot))
                }
            )
        }
    }

    /// Applies Source SDK `SetBodygroup` packing to canonical `m_nBody` and
    /// publishes only when the requested group actually changes the value.
    /// Invalid group IDs and selections above the Studio model count are the
    /// Source-defined no-op; missing model metadata remains a hard boundary.
    @discardableResult
    public func setCanonicalBodyGroup(
        _ bodyGroupID: Int,
        selection: Int,
        for identity: SourceCanonicalEntityIdentity
    ) throws -> SourceCanonicalEntitySnapshot {
        try withMutationBoundary {
            try requireCanonicalServerProjectionLocked(identity)
            guard let current = canonicalEntities.snapshot(for: identity) else {
                throw GMLuaSourceRuntimeAdapterError.unknownEntity(identity)
            }
            guard let model = current.model else {
                throw GMLuaSourceRuntimeAdapterError
                    .canonicalBodyGroupModelMissing(identity)
            }
            let layout = try resolvedCanonicalBodyGroupLayoutLocked(for: model)
            let updatedBodyValue = try layout.bodyValue(
                settingBodyGroupID: bodyGroupID,
                to: selection,
                currentBodyValue: current.bodyValue
            )
            guard updatedBodyValue != current.bodyValue else { return current }

            try preflightCanonicalMutationJournalLocked(additionalOperations: 1)
            return try canonicalEntities.update(
                identity,
                { candidate in
                    candidate.bodyValue = updatedBodyValue
                },
                publishing: { [unowned self] snapshot in
                    _ = try self.requiredServerRegistryLocked()
                        .applyAuthoritativeSnapshot(snapshot)
                    self.canonicalMutationJournal.append(.update(snapshot))
                }
            )
        }
    }

    /// Resolves and commits `m_nBody` as one canonical copy/validate/publish
    /// transaction. Any missing model/provider, malformed selection, decode
    /// failure, or rejected publication leaves state, revision, and journal
    /// byte-for-byte unchanged.
    @discardableResult
    public func setCanonicalBodyGroups(
        _ subModelIDs: String,
        for identity: SourceCanonicalEntityIdentity
    ) throws -> SourceCanonicalEntitySnapshot {
        try withMutationBoundary {
            try requireCanonicalServerProjectionLocked(identity)
            guard let current = canonicalEntities.snapshot(for: identity) else {
                throw GMLuaSourceRuntimeAdapterError.unknownEntity(identity)
            }
            guard !subModelIDs.isEmpty else { return current }
            guard let model = current.model else {
                throw GMLuaSourceRuntimeAdapterError
                    .canonicalBodyGroupModelMissing(identity)
            }
            let layout = try resolvedCanonicalBodyGroupLayoutLocked(for: model)
            let updatedBodyValue = try SourceStudioBodyGroupSelection.bodyValue(
                applyingBodyGroups: subModelIDs,
                to: current.bodyValue,
                bodyParts: layout.bodyParts
            )
            guard updatedBodyValue != current.bodyValue else { return current }
            try preflightCanonicalMutationJournalLocked(additionalOperations: 1)
            return try canonicalEntities.update(
                identity,
                { candidate in
                    candidate.bodyValue = updatedBodyValue
                },
                publishing: { [unowned self] snapshot in
                    _ = try self.requiredServerRegistryLocked()
                        .applyAuthoritativeSnapshot(snapshot)
                    self.canonicalMutationJournal.append(.update(snapshot))
                }
            )
        }
    }

    private func resolvedCanonicalBodyGroupLayoutLocked(
        for model: SourceEntityModelReference
    ) throws -> SourceStudioBodyGroupLayout {
        guard let resolver = canonicalBodyGroupLayoutResolver else {
            throw GMLuaSourceRuntimeAdapterError
                .canonicalBodyGroupLayoutResolverUnavailable
        }
        guard let layout = try resolver(model) else {
            throw GMLuaSourceRuntimeAdapterError
                .canonicalBodyGroupLayoutUnavailable(model)
        }
        return layout
    }

    @discardableResult
    public func spawnCanonicalEntity(
        _ identity: SourceCanonicalEntityIdentity
    ) throws -> SourceCanonicalEntitySnapshot {
        try withMutationBoundary {
            try requireCanonicalServerProjectionLocked(identity)
            try preflightCanonicalMutationJournalLocked(additionalOperations: 1)
            guard let current = canonicalEntities.snapshot(for: identity) else {
                throw GMLuaSourceRuntimeAdapterError.unknownEntity(identity)
            }

            guard current.kind == .propPhysics else {
                return try canonicalEntities.spawn(
                    identity,
                    publishing: { [unowned self] snapshot in
                        _ = try self.requiredServerRegistryLocked()
                            .applyAuthoritativeSnapshot(snapshot)
                        self.canonicalMutationJournal.append(.update(snapshot))
                    }
                )
            }

            guard let model = current.model else {
                throw SourceCanonicalEntityError.modelRequired(.propPhysics)
            }
            let asset: SourceAttestedPropPhysicsAsset
            switch canonicalPropPhysicsAssetResolver(model) {
            case let .valid(resolved):
                let normalized = try? SourceLogicalPath
                    .normalize(model.path, allowEmpty: false)
                    .lowercased()
                guard normalized == resolved.normalizedModelPath else {
                    throw SourceCanonicalEntityError.modelRejected(model)
                }
                asset = resolved
            case .invalid:
                throw SourceCanonicalEntityError.modelRejected(model)
            case .unavailable:
                throw SourceCanonicalEntityError
                    .modelValidationUnavailable(model)
            }

            let bodyID = try SourcePhysicsBodyID(
                entityIdentity: identity,
                solidIndex: asset.bodyDefinition.solidIndex
            )
            guard canonicalPhysicsBodyDefinitions[bodyID] == nil,
                  canonicalPhysicsBodySnapshots[bodyID] == nil else {
                throw GMLuaSourceRuntimeAdapterError
                    .canonicalPhysicsBodyAlreadyRegistered(bodyID)
            }

            let spawned = try canonicalEntities.spawn(
                identity,
                mutating: { candidate in
                    candidate.collisionProperty = asset.collisionProperty
                    candidate.solidType = .vPhysics
                    candidate.moveType = .vPhysics
                },
                publishing: { [unowned self] snapshot in
                    _ = try self.requiredServerRegistryLocked()
                        .applyAuthoritativeSnapshot(snapshot)
                    self.canonicalMutationJournal.append(.update(snapshot))
                }
            )
            // No throwing operation follows the canonical commit. The body
            // map becomes visible under the same mutation lock as state and
            // journal publication.
            canonicalPhysicsBodyDefinitions[bodyID] = asset.bodyDefinition
            return spawned
        }
    }

    @discardableResult
    public func activateCanonicalEntity(
        _ identity: SourceCanonicalEntityIdentity
    ) throws -> SourceCanonicalEntitySnapshot {
        try withMutationBoundary {
            try requireCanonicalServerProjectionLocked(identity)
            try preflightCanonicalMutationJournalLocked(additionalOperations: 1)
            return try canonicalEntities.activate(
                identity,
                publishing: { [unowned self] snapshot in
                    _ = try self.requiredServerRegistryLocked()
                        .applyAuthoritativeSnapshot(snapshot)
                    self.canonicalMutationJournal.append(.update(snapshot))
                }
            )
        }
    }

    /// Schedules UTIL_Remove semantics. The SERVER userdata stays valid until
    /// the Kernel reaches an actual cleanup phase and reports this full handle.
    @discardableResult
    public func markCanonicalEntityForRemoval(
        _ identity: SourceCanonicalEntityIdentity
    ) throws -> SourceCanonicalEntitySnapshot {
        try withMutationBoundary {
            try requireCanonicalServerProjectionLocked(identity)
            return try markCanonicalEntityForRemovalLocked(identity)
        }
    }

    /// Reverses only a still-created canonical entity. This is used when a
    /// multi-call GLua creation sequence cannot cross DispatchSpawn.
    @discardableResult
    public func rollbackCanonicalEntityCreation(
        _ identity: SourceCanonicalEntityIdentity
    ) throws -> SourceCanonicalEntitySnapshot {
        try withMutationBoundary {
            try requireCanonicalServerProjectionLocked(identity)
            let hasUnpublishedCreate = canonicalMutationJournal.contains {
                guard case let .create(snapshot) = $0 else { return false }
                return snapshot.identity == identity
            }
            if !hasUnpublishedCreate {
                try preflightCanonicalMutationJournalLocked(additionalOperations: 1)
            }
            let snapshot = try canonicalEntities.rollbackCreated(
                identity,
                publishing: { [unowned self] removal in
                    guard try self.requiredServerRegistryLocked()
                        .applyAuthoritativeRemoval(removal) else {
                        throw GMLuaSourceRuntimeAdapterError
                            .canonicalRemovalProjectionMissing(removal.identity)
                    }
                    if hasUnpublishedCreate {
                        self.canonicalMutationJournal.removeAll {
                            Self.canonicalIdentity(of: $0) == identity
                        }
                    } else {
                        self.canonicalMutationJournal.append(.remove(removal))
                    }
                }
            )
            removeCanonicalPhysicsBodiesLocked(for: identity)
            if let index = canonicalEntityHandleOrder.firstIndex(
                of: identity.handle.rawValue
            ) {
                canonicalEntityHandleOrder.remove(at: index)
            }
            return snapshot
        }
    }

    /// Reverses one entity whose complete create/spawn/activate history is
    /// still the tail of the unpublished canonical journal. This narrow seam
    /// lets multi-step engine bridges compensate an enqueue failure without
    /// turning a half-created helper entity into visible Source state.
    @discardableResult
    public func rollbackUnpublishedCanonicalEntity(
        _ identity: SourceCanonicalEntityIdentity
    ) throws -> SourceCanonicalEntitySnapshot {
        try withMutationBoundary {
            try requireCanonicalServerProjectionLocked(identity)
            guard let firstIndex = canonicalMutationJournal.firstIndex(where: {
                guard case let .create(snapshot) = $0 else { return false }
                return snapshot.identity == identity
            }), canonicalMutationJournal[firstIndex...].allSatisfy({
                Self.canonicalIdentity(of: $0) == identity
            }), canonicalEntityHandleOrder.last == identity.handle.rawValue else {
                throw GMLuaSourceRuntimeAdapterError
                    .forwardedConsoleCommandTransactionCheckpointChanged
            }
            let registry = try requiredServerRegistryLocked()
            let snapshot = try canonicalEntities.rollbackUnpublished(
                identity,
                publishing: { removal in
                    guard try registry.applyAuthoritativeRemoval(removal) else {
                        throw GMLuaSourceRuntimeAdapterError
                            .canonicalRemovalProjectionMissing(removal.identity)
                    }
                }
            )
            removeCanonicalPhysicsBodiesLocked(for: identity)
            canonicalEntityHandleOrder.removeLast()
            canonicalMutationJournal.removeSubrange(firstIndex...)
            return snapshot
        }
    }

    /// Stages Entity delivery and physics commands emitted by one stock
    /// Duplicator paste. The Duplicator coordinator compensates its fresh
    /// canonical handles before rethrowing; a thrown body then discards this
    /// staged transport suffix without touching unrelated FIFO work.
    public func withCanonicalDuplicatorPasteTransaction(
        _ body: () throws -> [SourceCanonicalDuplicatorPastedEntity]
    ) throws -> [SourceCanonicalDuplicatorPastedEntity] {
        try netTransport.withStagedForwardedConsoleDeliveries(body)
    }

    /// Runs one outer CLIENT-originated SERVER command under the narrow host
    /// transaction used by the stock `gm_spawn` vertical. Lua globals, timers,
    /// hooks, ConVars, undo, and mutations of pre-existing canonical entities
    /// are intentionally outside this current guarantee. A body failure does
    /// remove every canonical entity created after the checkpoint, its SERVER
    /// projection, its journal suffix, and transport work staged by the same
    /// command. A Lua `pcall` that catches its own error returns `.handled` and
    /// therefore commits normally.
    func withForwardedConsoleCommandTransaction(
        _ body: () throws -> GMLuaRemoteConsoleCommandDispatchOutcome
    ) throws -> GMLuaRemoteConsoleCommandDispatchOutcome {
        guard netTransport.isPumpingOnCurrentThread() else {
            throw GMLuaSourceRuntimeAdapterError
                .forwardedConsoleCommandTransactionOutsidePump
        }
        let checkpoint = try makeForwardedConsoleCommandCheckpoint()

        do {
            return try netTransport.withStagedForwardedConsoleDeliveries {
                let result: Result<GMLuaRemoteConsoleCommandDispatchOutcome, Error>
                do {
                    result = .success(try body())
                } catch {
                    result = .failure(error)
                }

                switch result {
                case .success(.handled):
                    return .handled
                case let .success(outcome):
                    do {
                        try rollbackForwardedConsoleCommand(to: checkpoint)
                    } catch {
                        throw GMLuaForwardedConsoleCommandRollbackFailure(
                            original: nil,
                            rollback: error
                        )
                    }
                    // Throwing this private control value makes the transport
                    // staging scope discard its deliveries/count. The value is
                    // converted back to the reporting outcome outside it.
                    throw GMLuaForwardedConsoleCommandActionFailure(
                        outcome: outcome
                    )
                case let .failure(original):
                    do {
                        try rollbackForwardedConsoleCommand(to: checkpoint)
                    } catch {
                        throw GMLuaForwardedConsoleCommandRollbackFailure(
                            original: original,
                            rollback: error
                        )
                    }
                    throw original
                }
            }
        } catch let actionFailure as GMLuaForwardedConsoleCommandActionFailure {
            return actionFailure.outcome
        }
    }

    /// Adds a CLIENT in deterministic attachment order and transactionally
    /// installs every existing Source mirror into that realm.
    public func attach(client: GMLuaRuntime) throws {
        try withMutationBoundary(additionalRuntimes: [client]) {
            try validateClientLocked(client)
            pruneClientAttachmentsLocked()
            guard !clientAttachments.contains(where: { $0.runtime === client }) else {
                throw GMLuaSourceRuntimeAdapterError.clientAlreadyAttached
            }
            guard let registry = client.entityRegistry else {
                throw GMLuaSourceRuntimeAdapterError.missingRuntimeSurface(.client, "Entity registry")
            }
            // CLIENT receives the same read-only, exact-byte model validation
            // host used by SERVER. The bridge itself withholds every mutation
            // API outside SERVER, while stock ghostentity.lua can safely call
            // util.IsValidModel/IsValidProp in its native realm.
            try SourceCanonicalEntityGLuaBridge.install(into: client, host: self)
            try SourceCanonicalEntityNetworkVariableGLuaBridge.install(
                into: client
            )
            try SourceCanonicalEntitySpawnMetadataGLuaBridge.install(
                into: client
            )

            var registered: [GMLuaSourceEntityIdentity] = []
            do {
                for rawHandle in entityHandleOrder {
                    guard let record = entityRecordsByHandle[rawHandle] else { continue }
                    _ = try registerMirror(record, in: registry)
                    registered.append(record.identity)
                }
            } catch {
                for identity in registered.reversed() {
                    registry.unregisterSourceMirror(
                        owner: mirrorOwner,
                        identity: identity
                    )
                }
                throw error
            }

            nextClientAttachmentOrder &+= 1
            let timerOrigin = try requiredTimerScheduler(in: client).currentTime
            clientAttachments.append(
                WeakClientAttachment(
                    runtime: client,
                    registry: registry,
                    order: nextClientAttachmentOrder,
                    timerOrigin: timerOrigin
                )
            )
        }
    }

    /// Detaches only Source-owned mirrors; SharedSession player connection
    /// generations and legacy registry entries are untouched.
    public func detach(client: GMLuaRuntime) throws {
        try withMutationBoundary(additionalRuntimes: [client]) {
            pruneClientAttachmentsLocked()
            guard let index = clientAttachments.firstIndex(where: { $0.runtime === client }) else {
                throw GMLuaSourceRuntimeAdapterError.clientNotAttached
            }
            if !client.isClosed, let registry = client.entityRegistry {
                for rawHandle in entityHandleOrder.reversed() {
                    guard let record = entityRecordsByHandle[rawHandle] else { continue }
                    registry.unregisterSourceMirror(
                        owner: mirrorOwner,
                        identity: record.identity
                    )
                }
            }
            clientAttachments.remove(at: index)
        }
    }

    /// Registers an edict-backed Source entity and all Lua mirrors as one
    /// transaction. A realm collision rolls back both mirrors and the Source
    /// slot; the slot serial still advances, so failed identities cannot revive.
    @discardableResult
    public func spawnNetworkableEntity(
        _ entity: SourceEntity,
        at entryIndex: Int,
        kind: GMLuaEntityKind = .entity,
        userID: Int? = nil,
        semanticValidity: Bool? = nil
    ) throws -> GMLuaSourceEntityIdentity {
        try withMutationBoundary {
            let handle = try kernel.entityList.addNetworkableEntity(entity, at: entryIndex)
            return try finishSpawnLocked(
                entity: entity,
                handle: handle,
                kind: kind,
                userID: resolvedUserID(kind: kind, requested: userID, index: entryIndex),
                semanticValidity: semanticValidity ?? (entryIndex != 0)
            )
        }
    }

    /// Non-edict entities retain the same handle/mirror generation contract.
    @discardableResult
    public func spawnNonNetworkableEntity(
        _ entity: SourceEntity,
        kind: GMLuaEntityKind = .entity,
        userID: Int? = nil,
        semanticValidity: Bool = true
    ) throws -> GMLuaSourceEntityIdentity {
        try withMutationBoundary {
            let handle = try kernel.entityList.addNonNetworkableEntity(entity)
            return try finishSpawnLocked(
                entity: entity,
                handle: handle,
                kind: kind,
                userID: resolvedUserID(kind: kind, requested: userID, index: handle.entryIndex),
                semanticValidity: semanticValidity
            )
        }
    }

    /// Schedules Source-compatible deferred deletion. Realm mirrors deliberately
    /// remain live until one of the kernel's actual cleanup phases removes it.
    @discardableResult
    public func markForDeletion(_ identity: GMLuaSourceEntityIdentity) throws -> Bool {
        try withMutationBoundary {
            if canonicalEntities.entity(for: identity) != nil {
                try requireCanonicalServerProjectionLocked(identity)
                _ = try markCanonicalEntityForRemovalLocked(identity)
                return true
            }
            guard kernel.entityList.entity(for: identity.handle) != nil else { return false }
            kernel.entityList.markForDeletion(identity.handle)
            return true
        }
    }

    /// Performs host mutations while the Source kernel and net delivery share
    /// one exclusive lifecycle boundary.
    @discardableResult
    public func withEntityMutation<T>(
        _ identity: GMLuaSourceEntityIdentity,
        _ body: (SourceEntity) throws -> T
    ) throws -> T {
        try withMutationBoundary {
            guard let entity = kernel.entityList.entity(for: identity.handle) else {
                throw GMLuaSourceRuntimeAdapterError.unknownEntity(identity)
            }
            return try body(entity)
        }
    }

    public func contains(_ identity: GMLuaSourceEntityIdentity) -> Bool {
        netTransport.withExclusiveLifecycleBoundary {
            mutationLock.lock()
            defer { mutationLock.unlock() }
            guard !isClosedStorage, !serverRuntime.isClosed else { return false }
            return kernel.entityList.entity(for: identity.handle) != nil
        }
    }

    /// Runs only the SERVER fixed-tick kernel. Timer time advances exactly once
    /// immediately before the gameStartFrame Think hook; net delivery is never
    /// pumped here.
    @discardableResult
    public func runServerFixedTick() throws -> GMLuaSourceRuntimeRunReport {
        try withRunBoundary(operation: "SERVER fixed tick") {
            try validateServerLocked()
            let removalsDueForCleanup = canonicalEntityHandleOrder.compactMap {
                rawHandle -> SourceCanonicalEntityIdentity? in
                let identity = SourceCanonicalEntityIdentity(
                    handle: SourceBaseHandle.unsafeFromIndex(rawHandle)
                )
                if canonicalEntities.snapshot(for: identity)?.lifecycle == .pendingRemoval {
                    return identity
                }
                return nil
            }
            try preflightCanonicalMutationJournalLocked(
                additionalOperations: removalsDueForCleanup.count
            )
            try preflightCanonicalCleanupRegistryLocked(removalsDueForCleanup)
            canonicalCleanupJournalReservations = removalsDueForCleanup.count
            isRunningCanonicalServerTick = true
            defer {
                isRunningCanonicalServerTick = false
                canonicalCleanupJournalReservations = 0
            }
            var hookFailures: [GMLuaSourceHookFailure] = []
            var timerFailures: [GMLuaSourceTimerFailure] = []
            var removedEntities: [GMLuaSourceEntityIdentity] = []

            kernel.runServerTick(
                onAddonHook: { [unowned self] phase in
                    if phase == .think {
                        self.advanceTimer(
                            in: self.serverRuntime,
                            to: Double(self.kernel.globals.currentTime),
                            clientAttachmentOrder: nil,
                            failures: &timerFailures
                        )
                    }
                    self.dispatchHook(
                        phase.rawValue,
                        in: self.serverRuntime,
                        clientAttachmentOrder: nil,
                        failures: &hookFailures
                    )
                },
                onEntityRemoved: { [unowned self] handle, entity in
                    if let identity = self.didCleanupCanonicalEntityLocked(
                        handle: handle,
                        entity: entity,
                        hookFailures: &hookFailures
                    ) {
                        removedEntities.append(identity)
                        return
                    }
                    if let identity = self.didCleanupEntityLocked(handle: handle, entity: entity) {
                        removedEntities.append(identity)
                    }
                }
            )

            return GMLuaSourceRuntimeRunReport(
                kind: .serverFixedTick,
                serverPhases: kernel.lastPhaseTrace,
                addonHooks: kernel.lastAddonHookTrace,
                hookFailures: hookFailures,
                timerFailures: timerFailures,
                removedEntities: removedEntities
            )
        }
    }

    /// Dispatches CLIENT Think once per attached render frame without advancing
    /// the fixed clock or running SERVER entity simulation. This milestone does
    /// not model render FrameTime; the host must not infer a fake frame delta.
    @discardableResult
    public func runClientFrame() throws -> GMLuaSourceRuntimeRunReport {
        try withRunBoundary(operation: "CLIENT frame") {
            var hookFailures: [GMLuaSourceHookFailure] = []
            for attachment in liveClientAttachmentsLocked() {
                guard let client = attachment.runtime else { continue }
                dispatchHook(
                    SourceAddonHookPhase.think.rawValue,
                    in: client,
                    clientAttachmentOrder: attachment.order,
                    failures: &hookFailures
                )
            }
            return GMLuaSourceRuntimeRunReport(
                kind: .clientFrame,
                serverPhases: [],
                addonHooks: [.think],
                hookFailures: hookFailures,
                timerFailures: [],
                removedEntities: []
            )
        }
    }

    /// Advances each CLIENT timer clock to its Float-derived Source fixed time
    /// and then dispatches Tick. While attached, the adapter owns this fixed
    /// clock; an external scheduler advance is rejected before any CLIENT is
    /// mutated. No SERVER entity simulation is impersonated on CLIENT.
    @discardableResult
    public func runClientFixedTick() throws -> GMLuaSourceRuntimeRunReport {
        try withRunBoundary(operation: "CLIENT fixed tick") {
            var hookFailures: [GMLuaSourceHookFailure] = []
            var timerFailures: [GMLuaSourceTimerFailure] = []
            let attachments = liveClientAttachmentsLocked()
            for attachment in attachments {
                guard let client = attachment.runtime else { continue }
                let scheduler = try requiredTimerScheduler(in: client)
                let expectedTime = attachment.timerOrigin + Double(
                    Float(attachment.fixedTickCount) * SourceGlobalVars.intervalPerTick
                )
                let actualTime = scheduler.currentTime
                guard actualTime == expectedTime else {
                    throw GMLuaSourceRuntimeAdapterError.timerClockMismatch(
                        .client,
                        expected: expectedTime,
                        actual: actualTime
                    )
                }
            }
            for attachment in attachments {
                guard let client = attachment.runtime else { continue }
                attachment.fixedTickCount &+= 1
                let sourceElapsedTime = Double(
                    Float(attachment.fixedTickCount) * SourceGlobalVars.intervalPerTick
                )
                advanceTimer(
                    in: client,
                    to: attachment.timerOrigin + sourceElapsedTime,
                    clientAttachmentOrder: attachment.order,
                    failures: &timerFailures
                )
                dispatchHook(
                    SourceAddonHookPhase.tick.rawValue,
                    in: client,
                    clientAttachmentOrder: attachment.order,
                    failures: &hookFailures
                )
            }
            return GMLuaSourceRuntimeRunReport(
                kind: .clientFixedTick,
                serverPhases: [],
                addonHooks: [.tick],
                hookFailures: hookFailures,
                timerFailures: timerFailures,
                removedEntities: []
            )
        }
    }

    private func finishSpawnLocked(
        entity: SourceEntity,
        handle: SourceBaseHandle,
        kind: GMLuaEntityKind,
        userID: Int?,
        semanticValidity: Bool
    ) throws -> GMLuaSourceEntityIdentity {
        let identity = GMLuaSourceEntityIdentity(handle: handle)
        let record = EntityRecord(
            identity: identity,
            entity: entity,
            kind: kind,
            userID: userID,
            semanticValidity: semanticValidity
        )
        var registered: [GMLuaEntityRegistry] = []
        do {
            for registry in try mirrorRegistriesLocked() {
                _ = try registerMirror(record, in: registry)
                registered.append(registry)
            }
        } catch {
            for registry in registered.reversed() {
                registry.unregisterSourceMirror(
                    owner: mirrorOwner,
                    identity: identity
                )
            }
            precondition(
                kernel.entityList.rollbackUnpublishedAddition(handle, entity: entity),
                "legacy Source mirror rollback lost its exact EHANDLE"
            )
            throw error
        }
        entityRecordsByHandle[handle.rawValue] = record
        entityHandleOrder.append(handle.rawValue)
        return identity
    }

    private func registerMirror(
        _ record: EntityRecord,
        in registry: GMLuaEntityRegistry
    ) throws -> LuaValue {
        try registry.registerSourceMirror(
            owner: mirrorOwner,
            identity: record.identity,
            kind: record.kind,
            userID: record.userID,
            semanticValidity: record.semanticValidity,
            className: record.entity.className
        )
    }

    private func didCleanupEntityLocked(
        handle: SourceBaseHandle,
        entity: SourceEntity
    ) -> GMLuaSourceEntityIdentity? {
        guard let record = entityRecordsByHandle[handle.rawValue],
              record.entity === entity else { return nil }
        entityRecordsByHandle.removeValue(forKey: handle.rawValue)
        if let orderIndex = entityHandleOrder.firstIndex(of: handle.rawValue) {
            entityHandleOrder.remove(at: orderIndex)
        }
        for registry in currentMirrorRegistriesLocked() {
            registry.unregisterSourceMirror(
                owner: mirrorOwner,
                identity: record.identity
            )
        }
        return record.identity
    }

    private func didCleanupCanonicalEntityLocked(
        handle: SourceBaseHandle,
        entity: SourceEntity,
        hookFailures: inout [GMLuaSourceHookFailure]
    ) -> SourceCanonicalEntityIdentity? {
        guard let snapshot = canonicalEntities.didCleanup(
            capturedHandle: handle,
            entity: entity
        ) else { return nil }
        removeCanonicalPhysicsBodiesLocked(for: snapshot.identity)
        precondition(
            canonicalCleanupJournalReservations > 0,
            "canonical cleanup must reserve its final replication operation"
        )
        canonicalCleanupJournalReservations -= 1
        if let orderIndex = canonicalEntityHandleOrder.firstIndex(of: handle.rawValue) {
            canonicalEntityHandleOrder.remove(at: orderIndex)
        }
        canonicalMutationJournal.append(.remove(snapshot))
        guard let registry = serverRuntime.entityRegistry else {
            preconditionFailure(
                "preflighted SERVER canonical registry disappeared during cleanup"
            )
        }
        let luaEntity = registry.entity(at: snapshot.identity.entryIndex)
        if registry.canonicalIdentity(for: luaEntity) == snapshot.identity,
           let message = serverRuntime.dispatchContainedHostHook(
               named: "EntityRemoved",
               arguments: [luaEntity, .boolean(false)]
           ) {
            hookFailures.append(GMLuaSourceHookFailure(
                realm: .server,
                event: "EntityRemoved",
                clientAttachmentOrder: nil,
                message: message
            ))
        }
        let applied = try? registry.applyAuthoritativeRemoval(snapshot)
        precondition(
            applied == true,
            "preflighted SERVER canonical removal projection changed during cleanup"
        )
        return snapshot.identity
    }

    private func markCanonicalEntityForRemovalLocked(
        _ identity: SourceCanonicalEntityIdentity
    ) throws -> SourceCanonicalEntitySnapshot {
        let prior = canonicalEntities.snapshot(for: identity)
        let changesLifecycle = prior?.lifecycle != .pendingRemoval
        if changesLifecycle {
            try preflightCanonicalMutationJournalLocked(
                additionalOperations: isRunningCanonicalServerTick ? 2 : 1
            )
        }
        let snapshot = try canonicalEntities.markForRemoval(
            identity,
            publishing: { [unowned self] snapshot in
                _ = try self.requiredServerRegistryLocked()
                    .applyAuthoritativeSnapshot(snapshot)
                if changesLifecycle {
                    self.canonicalMutationJournal.append(.update(snapshot))
                    if self.isRunningCanonicalServerTick {
                        self.canonicalCleanupJournalReservations += 1
                    }
                }
            }
        )
        removeCanonicalPhysicsBodiesLocked(for: identity)
        return snapshot
    }

    private func makeForwardedConsoleCommandCheckpoint() throws
        -> GMLuaForwardedConsoleCommandCheckpoint
    {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        try ensureOpenLocked()
        return GMLuaForwardedConsoleCommandCheckpoint(
            journalPrefix: canonicalMutationJournal,
            canonicalHandlePrefix: canonicalEntityHandleOrder,
            canonicalPhysicsBodyPrefix: canonicalPhysicsBodyDefinitions,
            canonicalPhysicsQueuedCreationPrefix:
                canonicalPhysicsQueuedCreationBodyIDs,
            cleanupJournalReservations: canonicalCleanupJournalReservations
        )
    }

    private func rollbackForwardedConsoleCommand(
        to checkpoint: GMLuaForwardedConsoleCommandCheckpoint
    ) throws {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        try ensureOpenLocked()

        guard canonicalMutationJournal.count >= checkpoint.journalPrefix.count,
              Array(
                  canonicalMutationJournal.prefix(checkpoint.journalPrefix.count)
              ) == checkpoint.journalPrefix,
              canonicalEntityHandleOrder.count >=
                checkpoint.canonicalHandlePrefix.count,
              Array(
                  canonicalEntityHandleOrder.prefix(
                      checkpoint.canonicalHandlePrefix.count
                  )
              ) == checkpoint.canonicalHandlePrefix,
              canonicalCleanupJournalReservations ==
                checkpoint.cleanupJournalReservations else {
            throw GMLuaSourceRuntimeAdapterError
                .forwardedConsoleCommandTransactionCheckpointChanged
        }

        let newHandles = Array(
            canonicalEntityHandleOrder.dropFirst(
                checkpoint.canonicalHandlePrefix.count
            )
        )
        let newHandleSet = Set(newHandles)
        guard checkpoint.canonicalPhysicsBodyPrefix.allSatisfy({
            canonicalPhysicsBodyDefinitions[$0.key] == $0.value
        }), canonicalPhysicsBodyDefinitions.allSatisfy({ bodyID, definition in
            checkpoint.canonicalPhysicsBodyPrefix[bodyID] == definition ||
                newHandleSet.contains(bodyID.entityIdentity.handle.rawValue)
        }), canonicalPhysicsQueuedCreationBodyIDs.allSatisfy({ bodyID in
            checkpoint.canonicalPhysicsQueuedCreationPrefix.contains(bodyID) ||
                newHandleSet.contains(bodyID.entityIdentity.handle.rawValue)
        }) else {
            throw GMLuaSourceRuntimeAdapterError
                .forwardedConsoleCommandTransactionCheckpointChanged
        }
        let journalSuffix = canonicalMutationJournal.dropFirst(
            checkpoint.journalPrefix.count
        )
        guard journalSuffix.allSatisfy({
            newHandleSet.contains(Self.canonicalIdentity(of: $0).handle.rawValue)
        }) else {
            // Restoring arbitrary pre-existing entity state requires a fully
            // general Lua/engine transaction and is outside the gm_spawn
            // vertical. Never truncate such a mutation into inconsistency.
            throw GMLuaSourceRuntimeAdapterError
                .forwardedConsoleCommandTransactionCheckpointChanged
        }

        let registry = try requiredServerRegistryLocked()
        for rawHandle in newHandles {
            let identity = SourceCanonicalEntityIdentity(
                handle: SourceBaseHandle.unsafeFromIndex(rawHandle)
            )
            guard canonicalEntities.entity(for: identity) != nil,
                  registry.canonicalIdentity(at: identity.entryIndex) == identity else {
                throw GMLuaSourceRuntimeAdapterError
                    .forwardedConsoleCommandTransactionCheckpointChanged
            }
        }

        for rawHandle in newHandles.reversed() {
            let identity = SourceCanonicalEntityIdentity(
                handle: SourceBaseHandle.unsafeFromIndex(rawHandle)
            )
            _ = try canonicalEntities.rollbackUnpublished(
                identity,
                publishing: { removal in
                    guard try registry.applyAuthoritativeRemoval(removal) else {
                        throw GMLuaSourceRuntimeAdapterError
                            .canonicalRemovalProjectionMissing(removal.identity)
                    }
                }
            )
            removeCanonicalPhysicsBodiesLocked(for: identity)
            guard canonicalEntityHandleOrder.last == rawHandle else {
                throw GMLuaSourceRuntimeAdapterError
                    .forwardedConsoleCommandTransactionCheckpointChanged
            }
            canonicalEntityHandleOrder.removeLast()
        }
        canonicalMutationJournal.removeLast(
            canonicalMutationJournal.count - checkpoint.journalPrefix.count
        )
        guard canonicalPhysicsBodyDefinitions ==
                checkpoint.canonicalPhysicsBodyPrefix else {
            throw GMLuaSourceRuntimeAdapterError
                .forwardedConsoleCommandTransactionCheckpointChanged
        }
        canonicalPhysicsQueuedCreationBodyIDs =
            checkpoint.canonicalPhysicsQueuedCreationPrefix
    }

    private func preflightCanonicalMutationJournalLocked(
        additionalOperations: Int
    ) throws {
        precondition(additionalOperations >= 0)
        guard canonicalMutationJournal.count <= canonicalMutationJournalCapacity,
              canonicalCleanupJournalReservations <= canonicalMutationJournalCapacity,
              additionalOperations <= canonicalMutationJournalCapacity,
              canonicalMutationJournal.count + canonicalCleanupJournalReservations <=
                canonicalMutationJournalCapacity - additionalOperations else {
            throw GMLuaSourceRuntimeAdapterError
                .canonicalMutationJournalCapacityExceeded(
                    maximum: canonicalMutationJournalCapacity
                )
        }
    }

    private func preflightCanonicalCleanupRegistryLocked(
        _ identities: [SourceCanonicalEntityIdentity]
    ) throws {
        guard !identities.isEmpty else { return }
        let registry = try requiredServerRegistryLocked()
        for identity in identities where
            registry.canonicalIdentity(at: identity.entryIndex) != identity
        {
            throw GMLuaSourceRuntimeAdapterError
                .canonicalRemovalProjectionMissing(identity)
        }
    }

    private static func canonicalIdentity(
        of operation: SourceEntityReplicationOperation
    ) -> SourceCanonicalEntityIdentity {
        switch operation {
        case let .create(snapshot),
             let .update(snapshot),
             let .remove(snapshot):
            return snapshot.identity
        }
    }

    private func requiredServerRegistryLocked() throws -> GMLuaEntityRegistry {
        guard let registry = serverRuntime.entityRegistry else {
            throw GMLuaSourceRuntimeAdapterError.missingRuntimeSurface(
                .server,
                "Entity registry"
            )
        }
        return registry
    }

    private func canonicalPhysicsObjectLocked(
        for bodyID: SourcePhysicsBodyID
    ) -> SourceCanonicalPhysicsObjectSnapshot? {
        guard let definition = canonicalPhysicsBodyDefinitions[bodyID],
              let entity = canonicalEntities.snapshot(
                  for: bodyID.entityIdentity
              ) else { return nil }
        if let solver = canonicalPhysicsBodySnapshots[bodyID] {
            return try? SourceCanonicalPhysicsObjectSnapshot(body: solver)
        }
        let effectiveDefinition = try? effectiveCanonicalPhysicsDefinition(
            definition,
            for: entity
        )
        guard let effectiveDefinition else { return nil }
        return try? SourceCanonicalPhysicsObjectSnapshot(
            pendingEntity: entity,
            definition: effectiveDefinition
        )
    }

    /// Applies authoritative Entity solid flags without changing the trusted
    /// shape, mass, inertia, or material extracted from the attested asset.
    private func effectiveCanonicalPhysicsDefinition(
        _ definition: SourceCanonicalPropPhysicsBodyDefinition,
        for entity: SourceCanonicalEntitySnapshot
    ) throws -> SourceCanonicalPropPhysicsBodyDefinition {
        let collisionEnabled = definition.isCollisionEnabled &&
            !entity.isNotSolid
        guard collisionEnabled != definition.isCollisionEnabled else {
            return definition
        }
        return try SourceCanonicalPropPhysicsBodyDefinition(
            solidIndex: definition.solidIndex,
            shape: definition.shape,
            massProperties: definition.massProperties,
            damping: definition.damping,
            motionType: definition.motionType,
            materialIndex: definition.materialIndex,
            isGravityEnabled: definition.isGravityEnabled,
            isCollisionEnabled: collisionEnabled,
            startsAwake: definition.startsAwake
        )
    }

    private func removeCanonicalPhysicsBodiesLocked(
        for identity: SourceCanonicalEntityIdentity
    ) {
        let bodyIDs = canonicalPhysicsBodyDefinitions.keys.filter {
            $0.entityIdentity == identity
        }
        for bodyID in bodyIDs {
            canonicalPhysicsBodyDefinitions.removeValue(forKey: bodyID)
            canonicalPhysicsBodySnapshots.removeValue(forKey: bodyID)
        }
    }

    private func requireCanonicalServerProjectionLocked(
        _ identity: SourceCanonicalEntityIdentity
    ) throws {
        guard canonicalEntities.entity(for: identity) != nil,
              try requiredServerRegistryLocked().canonicalIdentity(
                  at: identity.entryIndex
              ) == identity else {
            throw GMLuaSourceRuntimeAdapterError.unknownEntity(identity)
        }
    }

    private func mirrorRegistriesLocked() throws -> [GMLuaEntityRegistry] {
        try validateServerLocked()
        guard let serverRegistry = serverRuntime.entityRegistry else {
            throw GMLuaSourceRuntimeAdapterError.missingRuntimeSurface(.server, "Entity registry")
        }
        var registries = [serverRegistry]
        for attachment in liveClientAttachmentsLocked() {
            guard let client = attachment.runtime else { continue }
            guard let registry = client.entityRegistry else {
                throw GMLuaSourceRuntimeAdapterError.missingRuntimeSurface(.client, "Entity registry")
            }
            registries.append(registry)
        }
        return registries
    }

    private func currentMirrorRegistriesLocked() -> [GMLuaEntityRegistry] {
        var registries: [GMLuaEntityRegistry] = []
        if let registry = serverRuntime.entityRegistry {
            registries.append(registry)
        }
        for attachment in clientAttachments {
            registries.append(attachment.registry)
        }
        return registries
    }

    private func validateServerLocked() throws {
        try ensureOpenLocked()
        guard !serverRuntime.isClosed else {
            throw GMLuaSourceRuntimeAdapterError.closedRuntime(.server)
        }
        guard serverRuntime.netTransport === netTransport else {
            throw GMLuaSourceRuntimeAdapterError.transportMismatch(.server)
        }
        guard serverRuntime.entityRegistry != nil else {
            throw GMLuaSourceRuntimeAdapterError.missingRuntimeSurface(.server, "Entity registry")
        }
        guard let timerScheduler = serverRuntime.timerScheduler else {
            throw GMLuaSourceRuntimeAdapterError.missingRuntimeSurface(.server, "timer scheduler")
        }
        let expectedTime = Double(kernel.globals.currentTime)
        let actualTime = timerScheduler.currentTime
        guard actualTime == expectedTime else {
            throw GMLuaSourceRuntimeAdapterError.timerClockMismatch(
                .server,
                expected: expectedTime,
                actual: actualTime
            )
        }
    }

    private func validateClientLocked(_ client: GMLuaRuntime) throws {
        try ensureOpenLocked()
        guard client.realm == .client else {
            throw GMLuaSourceRuntimeAdapterError.invalidClientRealm(client.realm)
        }
        guard !client.isClosed else {
            throw GMLuaSourceRuntimeAdapterError.closedRuntime(.client)
        }
        guard client.netTransport === netTransport else {
            throw GMLuaSourceRuntimeAdapterError.transportMismatch(.client)
        }
        guard client.entityRegistry != nil else {
            throw GMLuaSourceRuntimeAdapterError.missingRuntimeSurface(.client, "Entity registry")
        }
        guard client.timerScheduler != nil else {
            throw GMLuaSourceRuntimeAdapterError.missingRuntimeSurface(.client, "timer scheduler")
        }
    }

    private func liveClientAttachmentsLocked() -> [WeakClientAttachment] {
        pruneClientAttachmentsLocked()
        return clientAttachments
    }

    private func pruneClientAttachmentsLocked() {
        var liveAttachments: [WeakClientAttachment] = []
        liveAttachments.reserveCapacity(clientAttachments.count)
        for attachment in clientAttachments {
            if let runtime = attachment.runtime, !runtime.isClosed {
                liveAttachments.append(attachment)
            } else {
                unregisterAllMirrorsLocked(in: attachment.registry)
            }
        }
        clientAttachments = liveAttachments
    }

    private func unregisterAllMirrorsLocked(in registry: GMLuaEntityRegistry) {
        for rawHandle in entityHandleOrder.reversed() {
            guard let record = entityRecordsByHandle[rawHandle] else { continue }
            registry.unregisterSourceMirror(
                owner: mirrorOwner,
                identity: record.identity
            )
        }
    }

    private func resolvedUserID(
        kind: GMLuaEntityKind,
        requested: Int?,
        index: Int
    ) -> Int? {
        kind == .player ? (requested ?? index) : nil
    }

    private func dispatchHook(
        _ event: String,
        in runtime: GMLuaRuntime,
        clientAttachmentOrder: Int?,
        failures: inout [GMLuaSourceHookFailure]
    ) {
        do {
            try runtime.dispatchHostHook(named: event)
        } catch {
            failures.append(
                GMLuaSourceHookFailure(
                    realm: runtime.realm,
                    event: event,
                    clientAttachmentOrder: clientAttachmentOrder,
                    message: GMLuaRuntime.describe(error)
                )
            )
        }
    }

    private func advanceTimer(
        in runtime: GMLuaRuntime,
        to targetTime: Double,
        clientAttachmentOrder: Int?,
        failures: inout [GMLuaSourceTimerFailure]
    ) {
        guard let scheduler = runtime.timerScheduler else {
            failures.append(
                GMLuaSourceTimerFailure(
                    realm: runtime.realm,
                    identifier: "<scheduler>",
                    clientAttachmentOrder: clientAttachmentOrder,
                    message: "timer scheduler is unavailable"
                )
            )
            return
        }
        do {
            for failure in try scheduler.advance(to: targetTime) {
                failures.append(
                    GMLuaSourceTimerFailure(
                        realm: runtime.realm,
                        identifier: failure.identifier,
                        clientAttachmentOrder: clientAttachmentOrder,
                        message: failure.message
                    )
                )
            }
        } catch {
            failures.append(
                GMLuaSourceTimerFailure(
                    realm: runtime.realm,
                    identifier: "<scheduler>",
                    clientAttachmentOrder: clientAttachmentOrder,
                    message: GMLuaRuntime.describe(error)
                )
            )
        }
    }

    private func requiredTimerScheduler(
        in runtime: GMLuaRuntime
    ) throws -> GMLuaTimerScheduler {
        guard let scheduler = runtime.timerScheduler else {
            throw GMLuaSourceRuntimeAdapterError.missingRuntimeSurface(
                runtime.realm,
                "timer scheduler"
            )
        }
        return scheduler
    }

    private func withMutationBoundary<T>(
        additionalRuntimes: [GMLuaRuntime] = [],
        _ body: () throws -> T
    ) throws -> T {
        // SERVER timer/Think callbacks execute inside `runServerFixedTick` while
        // this adapter already owns both lifecycle locks and runtime execution
        // markers. Source permits those callbacks to mutate entities. Reusing
        // the established boundary avoids recursively locking NSLock while the
        // ordinary mutation-to-mutation reentrancy guard remains intact.
        if isRunActiveOnCurrentThread {
            precondition(isAdapterOperationActiveOnCurrentThread)
            guard !isInlineRunMutationActiveOnCurrentThread else {
                throw GMLuaSourceRuntimeAdapterError
                    .reentrantRun("entity mutation")
            }
            try ensureOpenLocked()
            let threadDictionary = Thread.current.threadDictionary
            threadDictionary[inlineRunMutationThreadMarkerKey] = true
            defer {
                threadDictionary.removeObject(
                    forKey: inlineRunMutationThreadMarkerKey
                )
            }
            return try body()
        }
        guard !isAdapterOperationActiveOnCurrentThread else {
            throw GMLuaSourceRuntimeAdapterError.reentrantRun("entity mutation")
        }
        return try netTransport.withExclusiveLifecycleBoundary {
            mutationLock.lock()
            defer { mutationLock.unlock() }
            try ensureOpenLocked()
            return try withAdapterOperationMarker {
                try withRuntimeExecutionMarkers(
                    sourceExecutionRuntimesLocked(additional: additionalRuntimes)[...],
                    body
                )
            }
        }
    }

    private func withRunBoundary<T>(
        operation: String,
        _ body: () throws -> T
    ) throws -> T {
        let threadDictionary = Thread.current.threadDictionary
        guard threadDictionary[runThreadMarkerKey] as? Bool != true else {
            throw GMLuaSourceRuntimeAdapterError.reentrantRun(operation)
        }
        return try netTransport.withExclusiveLifecycleBoundary {
            mutationLock.lock()
            defer { mutationLock.unlock() }
            try ensureOpenLocked()
            threadDictionary[runThreadMarkerKey] = true
            defer { threadDictionary.removeObject(forKey: runThreadMarkerKey) }
            return try withAdapterOperationMarker {
                try withRuntimeExecutionMarkers(
                    sourceExecutionRuntimesLocked()[...],
                    body
                )
            }
        }
    }

    private func ensureOpenLocked() throws {
        guard !isClosedStorage else {
            throw GMLuaSourceRuntimeAdapterError.closedAdapter
        }
        guard !serverRuntime.isClosed else {
            throw GMLuaSourceRuntimeAdapterError.closedRuntime(.server)
        }
    }

    private func teardownLocked() -> Error? {
        guard !isClosedStorage else { return nil }
        isClosedStorage = true
        serverRuntime.consoleCommandDispatcher?
            .disconnectForwardedCommandTransactionHost(self)
        var firstCleanupError: Error?

        let records = entityHandleOrder.compactMap { entityRecordsByHandle[$0] }
        let registries = currentMirrorRegistriesLocked()
        for record in records.reversed() {
            for registry in registries {
                registry.unregisterSourceMirror(
                    owner: mirrorOwner,
                    identity: record.identity
                )
            }
        }
        for record in records {
            kernel.entityList.markForDeletion(record.identity.handle)
        }
        for rawHandle in canonicalEntityHandleOrder {
            let identity = SourceCanonicalEntityIdentity(
                handle: SourceBaseHandle.unsafeFromIndex(rawHandle)
            )
            do {
                _ = try canonicalEntities.markForRemoval(identity)
            } catch {
                if firstCleanupError == nil {
                    firstCleanupError = error
                }
            }
        }
        let canonicalStore = canonicalEntities
        let serverRegistry = serverRuntime.entityRegistry
        _ = kernel.entityList.cleanupDeleteList { handle, entity in
            guard let snapshot = canonicalStore.didCleanup(
                capturedHandle: handle,
                entity: entity
            ) else { return }
            guard let registry = serverRegistry else {
                if firstCleanupError == nil {
                    firstCleanupError = GMLuaSourceRuntimeAdapterError
                        .missingRuntimeSurface(.server, "Entity registry")
                }
                return
            }
            do {
                guard try registry.applyAuthoritativeRemoval(snapshot) else {
                    throw GMLuaSourceRuntimeAdapterError
                        .canonicalRemovalProjectionMissing(snapshot.identity)
                }
            } catch {
                if firstCleanupError == nil {
                    firstCleanupError = error
                }
            }
        }

        entityRecordsByHandle.removeAll(keepingCapacity: false)
        entityHandleOrder.removeAll(keepingCapacity: false)
        canonicalEntityHandleOrder.removeAll(keepingCapacity: false)
        canonicalMutationJournal.removeAll(keepingCapacity: false)
        canonicalPhysicsBodyDefinitions.removeAll(keepingCapacity: false)
        canonicalPhysicsBodySnapshots.removeAll(keepingCapacity: false)
        canonicalPhysicsQueuedCreationBodyIDs.removeAll(keepingCapacity: false)
        canonicalPhysicsObjectLuaBridge = nil
        canonicalCleanupJournalReservations = 0
        isRunningCanonicalServerTick = false
        clientAttachments.removeAll(keepingCapacity: false)
        nextClientAttachmentOrder = 0
        return firstCleanupError
    }

    private func sourceExecutionRuntimesLocked(
        additional: [GMLuaRuntime] = []
    ) -> [GMLuaRuntime] {
        var runtimes: [GMLuaRuntime] = []
        var identities: Set<ObjectIdentifier> = []
        func appendUnique(_ runtime: GMLuaRuntime) {
            guard identities.insert(ObjectIdentifier(runtime)).inserted else { return }
            runtimes.append(runtime)
        }
        appendUnique(serverRuntime)
        for attachment in liveClientAttachmentsLocked() {
            if let runtime = attachment.runtime {
                appendUnique(runtime)
            }
        }
        for runtime in additional {
            appendUnique(runtime)
        }
        return runtimes
    }

    private func withRuntimeExecutionMarkers<T>(
        _ runtimes: ArraySlice<GMLuaRuntime>,
        _ body: () throws -> T
    ) rethrows -> T {
        guard let runtime = runtimes.first else { return try body() }
        return try runtime.withSourceAdapterExecutionBoundary {
            try withRuntimeExecutionMarkers(runtimes.dropFirst(), body)
        }
    }

    private func withAdapterOperationMarker<T>(
        _ body: () throws -> T
    ) rethrows -> T {
        let threadDictionary = Thread.current.threadDictionary
        let key = operationThreadMarkerKey
        let priorDepth = threadDictionary[key] as? Int ?? 0
        threadDictionary[key] = priorDepth + 1
        defer {
            if priorDepth == 0 {
                threadDictionary.removeObject(forKey: key)
            } else {
                threadDictionary[key] = priorDepth
            }
        }
        return try body()
    }

    private var isAdapterOperationActiveOnCurrentThread: Bool {
        (Thread.current.threadDictionary[operationThreadMarkerKey] as? Int ?? 0) > 0
    }

    private var isRunActiveOnCurrentThread: Bool {
        Thread.current.threadDictionary[runThreadMarkerKey] as? Bool == true
    }

    private var isInlineRunMutationActiveOnCurrentThread: Bool {
        Thread.current.threadDictionary[inlineRunMutationThreadMarkerKey]
            as? Bool == true
    }

    private var operationThreadMarkerKey: String {
        "GMLuaSourceRuntimeAdapter.operation.\(ObjectIdentifier(self))"
    }

    private var runThreadMarkerKey: String {
        "GMLuaSourceRuntimeAdapter.run.\(ObjectIdentifier(self))"
    }

    private var inlineRunMutationThreadMarkerKey: String {
        "GMLuaSourceRuntimeAdapter.inlineMutation.\(ObjectIdentifier(self))"
    }
}

extension GMLuaSourceRuntimeAdapter:
    SourceCanonicalEntityLuaHost,
    SourceCanonicalPhysicsObjectLuaHost,
    GMLuaForwardedConsoleCommandTransactionHost
{}
