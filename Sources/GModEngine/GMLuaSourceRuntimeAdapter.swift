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
    case canonicalBodyGroupModelMissing(SourceCanonicalEntityIdentity)
    case canonicalPhysicsBodyAlreadyRegistered(SourcePhysicsBodyID)
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
        case let .canonicalBodyGroupModelMissing(identity):
            return "Source entity EHANDLE \(identity.handle.rawValue) has no Studio model for body-group resolution"
        case let .canonicalPhysicsBodyAlreadyRegistered(bodyID):
            return "canonical physics body \(bodyID.entityIdentity.handle.rawValue):\(bodyID.solidIndex) is already registered"
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
    public func installCanonicalPhysicsObjectLuaBridge() throws {
        try withMutationBoundary {
            guard canonicalPhysicsObjectLuaBridge == nil else { return }
            canonicalPhysicsObjectLuaBridge = try
                SourceCanonicalPhysicsObjectGLuaBridge.install(
                    into: serverRuntime,
                    host: self
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
            guard !subModelIDs.isEmpty else {
                guard let current = canonicalEntities.snapshot(for: identity) else {
                    throw GMLuaSourceRuntimeAdapterError.unknownEntity(identity)
                }
                return current
            }
            guard let resolver = canonicalBodyGroupResolver else {
                throw GMLuaSourceRuntimeAdapterError
                    .canonicalBodyGroupResolverUnavailable
            }
            try preflightCanonicalMutationJournalLocked(additionalOperations: 1)
            return try canonicalEntities.update(
                identity,
                { candidate in
                    guard let model = candidate.model else {
                        throw GMLuaSourceRuntimeAdapterError
                            .canonicalBodyGroupModelMissing(identity)
                    }
                    candidate.bodyValue = try resolver(
                        model,
                        subModelIDs,
                        candidate.bodyValue
                    )
                },
                publishing: { [unowned self] snapshot in
                    _ = try self.requiredServerRegistryLocked()
                        .applyAuthoritativeSnapshot(snapshot)
                    self.canonicalMutationJournal.append(.update(snapshot))
                }
            )
        }
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
            try SourceCanonicalEntityGLuaBridge.install(into: client)
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
                        entity: entity
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
        entity: SourceEntity
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
        return try? SourceCanonicalPhysicsObjectSnapshot(
            pendingEntity: entity,
            definition: definition
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

    private var operationThreadMarkerKey: String {
        "GMLuaSourceRuntimeAdapter.operation.\(ObjectIdentifier(self))"
    }

    private var runThreadMarkerKey: String {
        "GMLuaSourceRuntimeAdapter.run.\(ObjectIdentifier(self))"
    }
}

extension GMLuaSourceRuntimeAdapter:
    SourceCanonicalEntityLuaHost,
    SourceCanonicalPhysicsObjectLuaHost,
    GMLuaForwardedConsoleCommandTransactionHost
{}
