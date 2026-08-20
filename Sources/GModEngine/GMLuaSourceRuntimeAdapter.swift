import Foundation
import GModLua

/// Source handle identity shared by the simulation list and each realm-local
/// Entity userdata mirror. The complete packed handle is the generation; it is
/// intentionally unrelated to SharedSession's connection generation.
public struct GMLuaSourceEntityIdentity: Equatable, Hashable, Sendable {
    public let handle: SourceBaseHandle

    public init(handle: SourceBaseHandle) {
        precondition(handle.isValid, "a Source mirror requires a valid handle")
        self.handle = handle
    }

    public var index: Int { handle.entryIndex }
    public var generation: UInt64 { UInt64(handle.rawValue) }
}

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
        }
    }
}

/// Opt-in bridge between one Source fixed-tick kernel and realm-local GLua
/// runtimes. The adapter, rather than GMLuaRuntime, owns simulation lifetime.
/// It never pumps net delivery; the M4 SharedSession pump remains host-driven.
public final class GMLuaSourceRuntimeAdapter: @unchecked Sendable {
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
    private let mutationLock = NSRecursiveLock()
    let mirrorOwner = GMLuaSourceMirrorOwner()
    private var clientAttachments: [WeakClientAttachment] = []
    private var nextClientAttachmentOrder = 0
    private var entityRecordsByHandle: [UInt32: EntityRecord] = [:]
    private var entityHandleOrder: [UInt32] = []
    private var isClosedStorage = false

    public convenience init(serverRuntime: GMLuaRuntime) throws {
        try self.init(
            serverRuntime: serverRuntime,
            initialEntitySerialNumber: nil
        )
    }

    deinit {
        netTransport.withExclusiveLifecycleBoundary {
            mutationLock.lock()
            defer { mutationLock.unlock() }
            teardownLocked()
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
        netTransport.withExclusiveLifecycleBoundary {
            mutationLock.lock()
            defer { mutationLock.unlock() }
            teardownLocked()
        }
    }

    /// Deterministic serial seeding is internal test support; production keeps
    /// SourceEntityList's independently randomized slot serials.
    init(
        serverRuntime: GMLuaRuntime,
        initialEntitySerialNumber: Int?
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
        kernel = SourceRuntimeKernel(
            entityList: SourceEntityList(
                initialSerialNumber: initialEntitySerialNumber
            )
        )
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
            kernel.entityList.markForDeletion(handle)
            _ = kernel.entityList.cleanupDeleteList(onRemove: { _, _ in })
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
        try netTransport.withExclusiveLifecycleBoundary {
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

    private func teardownLocked() {
        guard !isClosedStorage else { return }
        isClosedStorage = true

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
        _ = kernel.entityList.cleanupDeleteList(onRemove: { _, _ in })

        entityRecordsByHandle.removeAll(keepingCapacity: false)
        entityHandleOrder.removeAll(keepingCapacity: false)
        clientAttachments.removeAll(keepingCapacity: false)
        nextClientAttachmentOrder = 0
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
