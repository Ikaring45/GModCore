import Foundation
import GModLua

/// Opaque ownership identity for one Source runtime adapter's realm mirrors.
/// Object identity, rather than handle equality, prevents independent kernels
/// that happen to allocate the same packed handle from sharing cleanup rights.
final class GMLuaSourceMirrorOwner: @unchecked Sendable {}

public enum GMLuaEntityKind: String, Sendable {
    case entity = "Entity"
    case player = "Player"
    case weapon = "Weapon"
    case vehicle = "Vehicle"
}

public enum GMLuaCanonicalEntityRegistryError: Error, Equatable, Sendable {
    case serverRealmRequired
    case clientRealmRequired
    case invalidEntityIndex(kind: SourceCanonicalEntityKind, index: Int)
    case nonNetworkableEntity(SourceBaseHandle)
    case classNameKindMismatch(
        handle: SourceBaseHandle,
        expected: String,
        received: String
    )
    case authoritativeSnapshotIsRemoved(SourceBaseHandle)
    case authoritativeRemovalIsNotRemoved(
        handle: SourceBaseHandle,
        lifecycle: SourceCanonicalEntityLifecycle
    )
    case occupiedLegacyEntityIndex(Int)
    case identityKindMismatch(
        handle: SourceBaseHandle,
        existing: GMLuaEntityKind,
        incoming: GMLuaEntityKind
    )
    case playerUserIDConflict(Int)
}

private final class GMLuaEntityValue: @unchecked Sendable {
    let index: Int
    let kind: GMLuaEntityKind
    let generation: UInt64
    let userID: Int?
    let semanticValidity: Bool
    let sourceOwner: GMLuaSourceMirrorOwner?
    var className: String
    var inputButtons: SourceInputButtons = []
    var luaTable: LuaTable? = LuaTable()
    var canonicalSnapshot: SourceCanonicalEntitySnapshot?

    init(
        index: Int,
        kind: GMLuaEntityKind,
        generation: UInt64,
        userID: Int?,
        semanticValidity: Bool,
        sourceOwner: GMLuaSourceMirrorOwner?,
        className: String,
        canonicalSnapshot: SourceCanonicalEntitySnapshot? = nil
    ) {
        self.index = index
        self.kind = kind
        self.generation = generation
        self.userID = userID
        self.semanticValidity = semanticValidity
        self.sourceOwner = sourceOwner
        self.className = className
        self.canonicalSnapshot = canonicalSnapshot
    }
}

/// State-local identity registry for engine-backed Entity userdata.
///
/// The registry is deliberately empty until the host engine registers real
/// objects. Missing indices return canonical `NULL`; no fake Lua-table entity
/// is manufactured to make discovery appear successful.
public final class GMLuaEntityRegistry: @unchecked Sendable {
    private let state: LuaState
    private let typeSystem: GMLuaTypeSystem
    private let realm: GMLuaRealm
    private let nullValue: LuaValue
    private let semanticIndex: LuaValue
    private let lock = NSLock()
    private var values: [Int: LuaValue] = [:]
    private var playerIdentityByUserID: [Int: (index: Int, generation: UInt64)] = [:]
    private var localPlayerIdentity: (index: Int, generation: UInt64)?
    private var entityReplicationState = SourceEntityReplicationClientState()
    private var entityReplicationPlayerUserIDs: [Int: Int] = [:]
    /// Serializes the two-phase CLIENT apply boundary while EntityRemoved Lua
    /// observes the still-live userdata immediately before invalidation.
    private let entityReplicationMutationLock = NSLock()
    /// Detached userdata prepared for the accepted packet must remain rooted
    /// if an EntityRemoved callback explicitly runs Lua collection before the
    /// projection becomes registry-visible.
    private var entityReplicationPendingReferences: [LuaValue] = []

    private init(
        state: LuaState,
        typeSystem: GMLuaTypeSystem,
        realm: GMLuaRealm,
        nullValue: LuaValue,
        semanticIndex: LuaValue
    ) {
        self.state = state
        self.typeSystem = typeSystem
        self.realm = realm
        self.nullValue = nullValue
        self.semanticIndex = semanticIndex
    }

    @discardableResult
    public func register(
        index: Int,
        kind: GMLuaEntityKind = .entity,
        className: String
    ) throws -> LuaValue {
        try register(
            index: index,
            kind: kind,
            generation: 0,
            userID: kind == .player ? index : nil,
            semanticValidity: true,
            sourceOwner: nil,
            replaceExisting: true,
            className: className
        )
    }

    @discardableResult
    func registerPlayerMirror(
        index: Int,
        generation: UInt64,
        userID: Int,
        className: String
    ) throws -> LuaValue {
        try register(
            index: index,
            kind: .player,
            generation: generation,
            userID: userID,
            semanticValidity: true,
            sourceOwner: nil,
            replaceExisting: true,
            className: className
        )
    }

    /// Registers one Source-owned identity without replacing a legacy or
    /// SharedSession-owned userdata at the same entity index. Re-registering
    /// the exact identity is idempotent so transactional realm attachment can
    /// safely retry after a host-side interruption.
    @discardableResult
    func registerSourceMirror(
        owner: GMLuaSourceMirrorOwner,
        identity: GMLuaSourceEntityIdentity,
        kind: GMLuaEntityKind,
        userID: Int?,
        semanticValidity: Bool,
        className: String
    ) throws -> LuaValue {
        lock.lock()
        if let existing = values[identity.index],
           let object = GMLuaTypeSystem.typedObject(from: existing),
           object.isValid,
           let payload = object.payload as? GMLuaEntityValue,
           payload.generation == identity.generation,
           payload.kind == kind,
           payload.userID == userID,
           payload.semanticValidity == semanticValidity,
           payload.sourceOwner === owner,
           payload.className == className {
            lock.unlock()
            return existing
        }
        if values[identity.index] != nil {
            lock.unlock()
            throw LuaError.runtime(
                "entity index \(identity.index) is owned by another mirror generation"
            )
        }
        lock.unlock()

        return try register(
            index: identity.index,
            kind: kind,
            generation: identity.generation,
            userID: userID,
            semanticValidity: semanticValidity,
            sourceOwner: owner,
            replaceExisting: false,
            className: className
        )
    }

    private func register(
        index: Int,
        kind: GMLuaEntityKind,
        generation: UInt64,
        userID: Int?,
        semanticValidity: Bool,
        sourceOwner: GMLuaSourceMirrorOwner?,
        replaceExisting: Bool,
        className: String
    ) throws -> LuaValue {
        guard index >= 0 else {
            throw LuaError.runtime("entity index must be non-negative")
        }
        if kind == .player {
            guard let userID, userID > 0 else {
                throw LuaError.runtime("Player user ID must be positive")
            }
        }
        let payload = GMLuaEntityValue(
            index: index,
            kind: kind,
            generation: generation,
            userID: userID,
            semanticValidity: semanticValidity,
            sourceOwner: sourceOwner,
            className: className
        )
        let value = try typeSystem.makeObject(metaName: kind.rawValue, payload: payload)
        lock.lock()
        if !replaceExisting, values[index] != nil {
            lock.unlock()
            throw LuaError.runtime(
                "entity index \(index) is owned by another mirror generation"
            )
        }
        if let userID,
           let mapped = playerIdentityByUserID[userID],
           mapped.index != index {
            lock.unlock()
            throw LuaError.runtime("Player user ID \(userID) is already registered")
        }
        if let old = values[index], let oldObject = GMLuaTypeSystem.typedObject(from: old) {
            oldObject.isValid = false
            if let oldPayload = oldObject.payload as? GMLuaEntityValue {
                oldPayload.luaTable = nil
                removePlayerUserIDMapping(for: oldPayload)
            }
        }
        values[index] = value
        if let userID {
            playerIdentityByUserID[userID] = (index, generation)
        }
        lock.unlock()
        state.refreshGarbageCollectionRootProviders()
        return value
    }

    public func unregister(index: Int) {
        lock.lock()
        let removed = values.removeValue(forKey: index)
        if let object = GMLuaTypeSystem.typedObject(from: removed ?? .nilValue) {
            object.isValid = false
            if let payload = object.payload as? GMLuaEntityValue {
                payload.luaTable = nil
                removePlayerUserIDMapping(for: payload)
                if localPlayerIdentity?.index == index,
                   localPlayerIdentity?.generation == payload.generation {
                    localPlayerIdentity = nil
                }
            }
        }
        lock.unlock()
    }

    func unregisterPlayerMirror(index: Int, generation: UInt64) {
        lock.lock()
        let current = values[index]
        let payload = current
            .flatMap(GMLuaTypeSystem.typedObject(from:))?
            .payload as? GMLuaEntityValue
        if payload?.kind == .player, payload?.generation == generation {
            let removed = values.removeValue(forKey: index)
            GMLuaTypeSystem.typedObject(from: removed ?? .nilValue)?.isValid = false
            payload?.luaTable = nil
            if let payload { removePlayerUserIDMapping(for: payload) }
            if localPlayerIdentity?.index == index,
               localPlayerIdentity?.generation == generation {
                localPlayerIdentity = nil
            }
        }
        lock.unlock()
    }

    /// Removes only the exact Source handle generation. A stale cleanup or
    /// rollback can therefore never invalidate a later occupant of the slot.
    func unregisterSourceMirror(
        owner: GMLuaSourceMirrorOwner,
        identity: GMLuaSourceEntityIdentity
    ) {
        lock.lock()
        let current = values[identity.index]
        let payload = current
            .flatMap(GMLuaTypeSystem.typedObject(from:))?
            .payload as? GMLuaEntityValue
        if payload?.sourceOwner === owner,
           payload?.generation == identity.generation {
            let removed = values.removeValue(forKey: identity.index)
            GMLuaTypeSystem.typedObject(from: removed ?? .nilValue)?.isValid = false
            payload?.luaTable = nil
            if let payload { removePlayerUserIDMapping(for: payload) }
            if localPlayerIdentity?.index == identity.index,
               localPlayerIdentity?.generation == identity.generation {
                localPlayerIdentity = nil
            }
        }
        lock.unlock()
    }

    /// Returns the current canonical Source identity for a realm-local value.
    /// Lifetime validity and GLua semantic validity are deliberately separate:
    /// the world entity has a live identity even though `world:IsValid()` is
    /// false in Garry's Mod.
    func sourceMirrorIdentity(for value: LuaValue) -> GMLuaSourceEntityIdentity? {
        guard case let .userdata(userdata) = value,
              let object = GMLuaTypeSystem.typedObject(from: value),
              object.isValid,
              let payload = object.payload as? GMLuaEntityValue,
              payload.sourceOwner != nil,
              payload.generation <= UInt64(UInt32.max) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard case let .userdata(canonical)? = values[payload.index],
              canonical === userdata else { return nil }
        return GMLuaSourceEntityIdentity(
            handle: SourceBaseHandle.unsafeFromIndex(UInt32(truncatingIfNeeded: payload.generation))
        )
    }

    func sourceMirrorIdentity(at index: Int) -> GMLuaSourceEntityIdentity? {
        lock.lock()
        let value = values[index]
        lock.unlock()
        guard let value else { return nil }
        return sourceMirrorIdentity(for: value)
    }

    /// Projects one engine-owned SERVER snapshot into this realm. Updating the
    /// same complete EHANDLE mutates only the snapshot payload, preserving the
    /// userdata and its Lua sidecar table. Reusing an entry with a new serial
    /// invalidates the old userdata before publishing the replacement.
    @discardableResult
    public func applyAuthoritativeSnapshot(
        _ snapshot: SourceCanonicalEntitySnapshot,
        userID: Int? = nil
    ) throws -> LuaValue {
        guard realm == .server else {
            throw GMLuaCanonicalEntityRegistryError.serverRealmRequired
        }
        try Self.validateCanonicalSnapshot(snapshot, isRemoval: false)

        lock.lock()
        do {
            var target = canonicalSnapshotsByIndexLocked()
            target[snapshot.identity.entryIndex] = snapshot
            let projection = try prepareCanonicalProjectionLocked(
                target: target,
                preferredPlayerUserIDs: userID.map {
                    [snapshot.identity.entryIndex: $0]
                } ?? [:]
            )
            commitCanonicalProjectionLocked(projection)
            guard let value = values[snapshot.identity.entryIndex] else {
                preconditionFailure("canonical projection omitted its target entity")
            }
            lock.unlock()
            state.refreshGarbageCollectionRootProviders()
            return value
        } catch {
            lock.unlock()
            throw error
        }
    }

    /// Applies the final SERVER removal snapshot only to its exact EHANDLE.
    /// A delayed removal for an older serial is harmless to a replacement slot.
    @discardableResult
    public func applyAuthoritativeRemoval(
        _ snapshot: SourceCanonicalEntitySnapshot
    ) throws -> Bool {
        guard realm == .server else {
            throw GMLuaCanonicalEntityRegistryError.serverRealmRequired
        }
        try Self.validateCanonicalSnapshot(snapshot, isRemoval: true)

        lock.lock()
        guard let current = values[snapshot.identity.entryIndex],
              let object = GMLuaTypeSystem.typedObject(from: current),
              object.isValid,
              let payload = object.payload as? GMLuaEntityValue,
              payload.generation == snapshot.identity.generation else {
            lock.unlock()
            return false
        }
        values.removeValue(forKey: snapshot.identity.entryIndex)
        removePlayerUserIDMapping(for: payload)
        if localPlayerIdentity?.index == snapshot.identity.entryIndex,
           localPlayerIdentity?.generation == snapshot.identity.generation {
            localPlayerIdentity = nil
        }
        object.isValid = false
        payload.canonicalSnapshot = nil
        payload.luaTable = nil
        lock.unlock()
        state.refreshGarbageCollectionRootProviders()
        return true
    }

    /// Starts a fresh CLIENT entity stream. A newer connection atomically
    /// drops every userdata owned by the previous replicated snapshot.
    @discardableResult
    public func beginEntityReplication(
        generation: SourceEntityReplicationConnectionGeneration,
        playerUserIDs: [Int: Int] = [:]
    ) throws -> Bool {
        guard realm == .client else {
            throw GMLuaCanonicalEntityRegistryError.clientRealmRequired
        }
        for (index, userID) in playerUserIDs {
            guard index > 0 else {
                throw GMLuaCanonicalEntityRegistryError.invalidEntityIndex(
                    kind: .player,
                    index: index
                )
            }
            guard userID > 0 else {
                throw GMLuaCanonicalEntityRegistryError.playerUserIDConflict(
                    userID
                )
            }
        }

        entityReplicationMutationLock.lock()
        defer { entityReplicationMutationLock.unlock() }

        lock.lock()
        do {
            var candidateState = entityReplicationState
            guard candidateState.connect(generation: generation) else {
                lock.unlock()
                return false
            }
            let projection = try prepareCanonicalProjectionLocked(target: [:])
            commitCanonicalProjectionLocked(projection)
            entityReplicationState = candidateState
            entityReplicationPlayerUserIDs = playerUserIDs
            lock.unlock()
            state.refreshGarbageCollectionRootProviders()
            return true
        } catch {
            lock.unlock()
            throw error
        }
    }

    /// Validates a CLIENT packet and prepares every required userdata against
    /// copies first. Registry storage, sidecar lifetime, and replication
    /// sequence advance together only after the complete projection succeeds.
    @discardableResult
    public func applyEntityReplicationPacket(
        _ packet: SourceEntityReplicationPacket
    ) throws -> SourceEntityReplicationApplyResult {
        try applyEntityReplicationPacket(packet, beforeRemoving: { _ in })
    }

    /// Applies one validated packet while exposing its exact remove operations
    /// immediately before the affected realm-local userdata is invalidated.
    /// The callback is deliberately nonthrowing: addon failures are contained
    /// by the host dispatcher so an accepted FIFO packet cannot be replayed.
    @discardableResult
    func applyEntityReplicationPacket(
        _ packet: SourceEntityReplicationPacket,
        beforeRemoving: ([LuaValue]) -> Void
    ) throws -> SourceEntityReplicationApplyResult {
        guard realm == .client else {
            throw GMLuaCanonicalEntityRegistryError.clientRealmRequired
        }

        entityReplicationMutationLock.lock()
        defer { entityReplicationMutationLock.unlock() }

        lock.lock()
        do {
            var candidateState = entityReplicationState
            let result = candidateState.apply(packet)
            guard case let .applied(clientSnapshot) = result else {
                lock.unlock()
                return result
            }

            var target: [Int: SourceCanonicalEntitySnapshot] = [:]
            for snapshot in clientSnapshot.entities {
                try Self.validateCanonicalSnapshot(snapshot, isRemoval: false)
                target[snapshot.identity.entryIndex] = snapshot
            }
            let projection = try prepareCanonicalProjectionLocked(
                target: target,
                preferredPlayerUserIDs: entityReplicationPlayerUserIDs
            )

            let removedValues = removalIdentities(in: packet).compactMap {
                identity -> LuaValue? in
                guard let value = values[identity.entryIndex],
                      let payload = GMLuaTypeSystem.typedObject(from: value)?
                        .payload as? GMLuaEntityValue,
                      payload.canonicalSnapshot?.identity == identity else {
                    return nil
                }
                return value
            }
            entityReplicationPendingReferences = projection.values.values
                .flatMap { value -> [LuaValue] in
                    guard let payload = GMLuaTypeSystem.typedObject(from: value)?
                            .payload as? GMLuaEntityValue,
                          let table = payload.luaTable else { return [value] }
                    return [value, .table(table)]
                }
            // GLua's EntityRemoved contract runs immediately before removal.
            // Release the ordinary registry lock so Entity methods and the
            // original CallOnRemove implementation can read the sidecar table.
            lock.unlock()
            beforeRemoving(removedValues)
            lock.lock()
            commitCanonicalProjectionLocked(projection)
            entityReplicationState = candidateState
            entityReplicationPendingReferences.removeAll(keepingCapacity: true)
            lock.unlock()
            state.refreshGarbageCollectionRootProviders()
            return result
        } catch {
            lock.unlock()
            throw error
        }
    }

    /// Ends CLIENT replication while retaining the highest connection
    /// generation in the replication state, so delayed packets cannot revive
    /// stale userdata.
    public func disconnectEntityReplication() throws {
        guard realm == .client else {
            throw GMLuaCanonicalEntityRegistryError.clientRealmRequired
        }

        entityReplicationMutationLock.lock()
        defer { entityReplicationMutationLock.unlock() }

        lock.lock()
        do {
            var candidateState = entityReplicationState
            candidateState.disconnect()
            let projection = try prepareCanonicalProjectionLocked(target: [:])
            commitCanonicalProjectionLocked(projection)
            entityReplicationState = candidateState
            entityReplicationPlayerUserIDs.removeAll(keepingCapacity: true)
            lock.unlock()
            state.refreshGarbageCollectionRootProviders()
        } catch {
            lock.unlock()
            throw error
        }
    }

    public func canonicalIdentity(
        for value: LuaValue
    ) -> SourceCanonicalEntityIdentity? {
        canonicalSnapshot(for: value)?.identity
    }

    public func canonicalIdentity(at index: Int) -> SourceCanonicalEntityIdentity? {
        canonicalSnapshot(at: index)?.identity
    }

    public func canonicalSnapshot(
        for value: LuaValue
    ) -> SourceCanonicalEntitySnapshot? {
        guard case let .userdata(userdata) = value,
              let object = GMLuaTypeSystem.typedObject(from: value),
              let payload = object.payload as? GMLuaEntityValue else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard object.isValid,
              case let .userdata(canonical)? = values[payload.index],
              canonical === userdata else { return nil }
        return payload.canonicalSnapshot
    }

    public func canonicalSnapshot(at index: Int) -> SourceCanonicalEntitySnapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard let value = values[index],
              let object = GMLuaTypeSystem.typedObject(from: value),
              object.isValid,
              let payload = object.payload as? GMLuaEntityValue else { return nil }
        return payload.canonicalSnapshot
    }

    /// Immutable canonical projection ordered by Source entity-list index.
    /// Render and host consumers receive snapshots only; realm-local userdata
    /// and sidecar tables remain owned by the Lua registry.
    public var canonicalEntitySnapshots: [SourceCanonicalEntitySnapshot] {
        lock.lock()
        defer { lock.unlock() }
        return canonicalSnapshotsByIndexLocked()
            .sorted { $0.key < $1.key }
            .map(\.value)
    }

    /// Allocation-free version of the CLIENT projection. Callers use this to
    /// avoid rebuilding the ordered snapshot array on unchanged host frames.
    public var canonicalEntityReplicationCursor: SourceEntityReplicationCursor? {
        lock.lock()
        defer { lock.unlock() }
        return entityReplicationState.cursor
    }

    /// Atomically compares one kind's CLIENT replication cursor and builds its
    /// ordered immutable projection only when changed. This prevents Player
    /// movement packets from forcing a prop array copy at fixed-tick rate.
    public func canonicalEntityProjection(
        for kind: SourceCanonicalEntityKind,
        ifChangedFrom priorCursor: SourceEntityReplicationCursor?
    ) -> SourceCanonicalEntityKindProjection? {
        lock.lock()
        defer { lock.unlock() }
        guard let cursor = entityReplicationState.cursor(for: kind),
              cursor != priorCursor else { return nil }
        let entities = canonicalSnapshotsByIndexLocked()
            .filter { $0.value.kind == kind }
            .sorted { $0.key < $1.key }
            .map(\.value)
        return SourceCanonicalEntityKindProjection(
            kind: kind,
            cursor: cursor,
            entities: entities
        )
    }

    private struct CanonicalProjection {
        var values: [Int: LuaValue]
        var playerIdentityByUserID: [Int: (index: Int, generation: UInt64)]
        var localPlayerIdentity: (index: Int, generation: UInt64)?
        var invalidations: [(GMLuaTypedObject, GMLuaEntityValue)]
        var snapshotUpdates: [(GMLuaEntityValue, SourceCanonicalEntitySnapshot)]
    }

    /// Requires `lock` to be held. This method creates detached userdata but
    /// never mutates registry-visible values or existing payloads.
    private func prepareCanonicalProjectionLocked(
        target: [Int: SourceCanonicalEntitySnapshot],
        preferredPlayerUserIDs: [Int: Int] = [:]
    ) throws -> CanonicalProjection {
        var candidateValues = values
        var candidatePlayerIDs = playerIdentityByUserID
        var candidateLocalPlayer = localPlayerIdentity
        var invalidations: [(GMLuaTypedObject, GMLuaEntityValue)] = []
        var snapshotUpdates: [(GMLuaEntityValue, SourceCanonicalEntitySnapshot)] = []

        func removeCandidate(at index: Int) {
            guard let removed = candidateValues.removeValue(forKey: index),
                  let object = GMLuaTypeSystem.typedObject(from: removed),
                  let payload = object.payload as? GMLuaEntityValue else { return }
            if let userID = payload.userID,
               let mapped = candidatePlayerIDs[userID],
               mapped.index == payload.index,
               mapped.generation == payload.generation {
                candidatePlayerIDs.removeValue(forKey: userID)
            }
            if candidateLocalPlayer?.index == payload.index,
               candidateLocalPlayer?.generation == payload.generation {
                candidateLocalPlayer = nil
            }
            invalidations.append((object, payload))
        }

        // A full target projection owns only values that have previously been
        // attached to canonical snapshots. Legacy/direct mirrors remain until
        // a matching canonical identity adopts or replaces their slot.
        for (index, value) in Array(candidateValues) {
            guard let payload = GMLuaTypeSystem.typedObject(from: value)?.payload
                    as? GMLuaEntityValue,
                  let current = payload.canonicalSnapshot else { continue }
            guard let incoming = target[index],
                  incoming.identity == current.identity else {
                removeCandidate(at: index)
                continue
            }
        }

        for index in target.keys.sorted() {
            guard let snapshot = target[index] else { continue }
            let incomingKind = Self.luaKind(for: snapshot.kind)

            if let existing = candidateValues[index],
               let object = GMLuaTypeSystem.typedObject(from: existing),
               object.isValid,
               let payload = object.payload as? GMLuaEntityValue {
                if payload.generation == snapshot.identity.generation {
                    guard payload.kind == incomingKind else {
                        throw GMLuaCanonicalEntityRegistryError.identityKindMismatch(
                            handle: snapshot.identity.handle,
                            existing: payload.kind,
                            incoming: incomingKind
                        )
                    }
                    snapshotUpdates.append((payload, snapshot))
                    continue
                }

                // Generation 0 denotes the public legacy register API. It has
                // no Source EHANDLE ownership and cannot be silently replaced.
                guard payload.generation != 0 ||
                        payload.sourceOwner != nil ||
                        payload.canonicalSnapshot != nil else {
                    throw GMLuaCanonicalEntityRegistryError.occupiedLegacyEntityIndex(index)
                }
                removeCandidate(at: index)
            } else if candidateValues[index] != nil {
                throw GMLuaCanonicalEntityRegistryError.occupiedLegacyEntityIndex(index)
            }

            let userID: Int?
            if incomingKind == .player {
                userID = preferredPlayerUserIDs[index] ?? index
                guard let userID, userID > 0 else {
                    throw GMLuaCanonicalEntityRegistryError.playerUserIDConflict(userID ?? 0)
                }
                if let mapped = candidatePlayerIDs[userID], mapped.index != index {
                    throw GMLuaCanonicalEntityRegistryError.playerUserIDConflict(userID)
                }
            } else {
                userID = nil
            }

            let payload = GMLuaEntityValue(
                index: index,
                kind: incomingKind,
                generation: snapshot.identity.generation,
                userID: userID,
                semanticValidity: snapshot.kind != .world,
                sourceOwner: nil,
                className: snapshot.className,
                canonicalSnapshot: snapshot
            )
            let value = try typeSystem.makeObject(
                metaName: incomingKind.rawValue,
                payload: payload
            )
            candidateValues[index] = value
            if let userID {
                candidatePlayerIDs[userID] = (index, snapshot.identity.generation)
            }
        }

        return CanonicalProjection(
            values: candidateValues,
            playerIdentityByUserID: candidatePlayerIDs,
            localPlayerIdentity: candidateLocalPlayer,
            invalidations: invalidations,
            snapshotUpdates: snapshotUpdates
        )
    }

    /// Requires `lock` to be held and a completely prepared projection.
    private func commitCanonicalProjectionLocked(_ projection: CanonicalProjection) {
        for (object, payload) in projection.invalidations {
            object.isValid = false
            payload.canonicalSnapshot = nil
            payload.luaTable = nil
        }
        for (payload, snapshot) in projection.snapshotUpdates {
            payload.className = snapshot.className
            payload.canonicalSnapshot = snapshot
        }
        values = projection.values
        playerIdentityByUserID = projection.playerIdentityByUserID
        localPlayerIdentity = projection.localPlayerIdentity
    }

    private func canonicalSnapshotsByIndexLocked() -> [Int: SourceCanonicalEntitySnapshot] {
        var snapshots: [Int: SourceCanonicalEntitySnapshot] = [:]
        for (index, value) in values {
            guard let payload = GMLuaTypeSystem.typedObject(from: value)?.payload
                    as? GMLuaEntityValue,
                  let snapshot = payload.canonicalSnapshot else { continue }
            snapshots[index] = snapshot
        }
        return snapshots
    }

    private func removalIdentities(
        in packet: SourceEntityReplicationPacket
    ) -> [SourceCanonicalEntityIdentity] {
        guard case let .delta(operations) = packet.payload else { return [] }
        return operations.compactMap { operation in
            guard case let .remove(snapshot) = operation else { return nil }
            return snapshot.identity
        }
    }

    private static func luaKind(
        for kind: SourceCanonicalEntityKind
    ) -> GMLuaEntityKind {
        switch kind {
        case .world, .propPhysics:
            return .entity
        case .player:
            return .player
        }
    }

    private static func validateCanonicalSnapshot(
        _ snapshot: SourceCanonicalEntitySnapshot,
        isRemoval: Bool
    ) throws {
        let index = snapshot.identity.entryIndex
        let indexMatchesKind = snapshot.kind == .world ? index == 0 : index > 0
        guard indexMatchesKind, index < SourceEntityConstants.maxEdicts else {
            throw GMLuaCanonicalEntityRegistryError.invalidEntityIndex(
                kind: snapshot.kind,
                index: index
            )
        }
        guard snapshot.isNetworkable else {
            throw GMLuaCanonicalEntityRegistryError.nonNetworkableEntity(
                snapshot.identity.handle
            )
        }
        guard snapshot.className == snapshot.kind.className else {
            throw GMLuaCanonicalEntityRegistryError.classNameKindMismatch(
                handle: snapshot.identity.handle,
                expected: snapshot.kind.className,
                received: snapshot.className
            )
        }
        if isRemoval {
            guard snapshot.lifecycle == .removed else {
                throw GMLuaCanonicalEntityRegistryError.authoritativeRemovalIsNotRemoved(
                    handle: snapshot.identity.handle,
                    lifecycle: snapshot.lifecycle
                )
            }
        } else if snapshot.lifecycle == .removed {
            throw GMLuaCanonicalEntityRegistryError.authoritativeSnapshotIsRemoved(
                snapshot.identity.handle
            )
        }
    }

    public func entity(at index: Int) -> LuaValue {
        lock.lock()
        let value = values[index]
        lock.unlock()
        guard let value,
              GMLuaTypeSystem.typedObject(from: value)?.isValid == true else {
            return nullValue
        }
        return value
    }

    public func player(at index: Int) -> LuaValue {
        let value = entity(at: index)
        guard let object = GMLuaTypeSystem.typedObject(from: value),
              object.isValid,
              let payload = object.payload as? GMLuaEntityValue,
              payload.kind == .player else { return nullValue }
        return value
    }

    /// Resolves GLua's global `Player(number)`, whose numeric argument is a
    /// UserID rather than an EntIndex. Engine/net code must continue to use
    /// ``player(at:)`` for canonical entity-index lookup.
    public func player(forUserID userID: Int) -> LuaValue {
        lock.lock()
        let identity = playerIdentityByUserID[userID]
        let value = identity.flatMap { values[$0.index] }
        lock.unlock()
        guard let identity,
              let value,
              let object = GMLuaTypeSystem.typedObject(from: value),
              object.isValid,
              let payload = object.payload as? GMLuaEntityValue,
              payload.kind == .player,
              payload.generation == identity.generation,
              payload.userID == userID else { return nullValue }
        return value
    }

    private func removePlayerUserIDMapping(for payload: GMLuaEntityValue) {
        guard let userID = payload.userID,
              let mapped = playerIdentityByUserID[userID],
              mapped.index == payload.index,
              mapped.generation == payload.generation else { return }
        playerIdentityByUserID.removeValue(forKey: userID)
    }

    func setLocalPlayer(index: Int, generation: UInt64) throws {
        let value = player(at: index)
        guard let object = GMLuaTypeSystem.typedObject(from: value),
              object.isValid,
              let payload = object.payload as? GMLuaEntityValue,
              payload.generation == generation else {
            throw LuaError.runtime(
                "LocalPlayer requires the current canonical Player mirror"
            )
        }
        lock.lock()
        localPlayerIdentity = (index, generation)
        lock.unlock()
    }

    func clearLocalPlayer(index: Int, generation: UInt64) {
        lock.lock()
        if localPlayerIdentity?.index == index,
           localPlayerIdentity?.generation == generation {
            localPlayerIdentity = nil
        }
        lock.unlock()
    }

    func localPlayer() -> LuaValue {
        lock.lock()
        let identity = localPlayerIdentity
        let value = identity.flatMap { values[$0.index] }
        lock.unlock()
        guard let identity,
              let value,
              let object = GMLuaTypeSystem.typedObject(from: value),
              object.isValid,
              let payload = object.payload as? GMLuaEntityValue,
              payload.kind == .player,
              payload.generation == identity.generation else { return nullValue }
        return value
    }

    /// Replaces the current host-owned button word only for the exact
    /// canonical Player generation. Stale lifecycle work cannot mutate a
    /// replacement occupant of the same entity slot.
    @discardableResult
    func setPlayerInputButtons(
        index: Int,
        generation: UInt64,
        buttons: SourceInputButtons
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let value = values[index],
              let object = GMLuaTypeSystem.typedObject(from: value),
              object.isValid,
              let payload = object.payload as? GMLuaEntityValue,
              payload.kind == .player,
              payload.generation == generation else { return false }
        payload.inputButtons = buttons
        return true
    }

    /// Reads a button word only when the userdata is still this registry's
    /// canonical Player. Invalidated Player userdata therefore cannot inherit
    /// input from a later generation that reused its EntIndex.
    private func playerInputButtons(for value: LuaValue) -> SourceInputButtons? {
        guard case let .userdata(userdata) = value,
              let object = GMLuaTypeSystem.typedObject(from: value),
              let payload = object.payload as? GMLuaEntityValue else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard object.isValid,
              object.metaName == GMLuaEntityKind.player.rawValue,
              payload.kind == .player,
              case let .userdata(canonical)? = values[payload.index],
              canonical === userdata else { return nil }
        return payload.inputButtons
    }

    /// Reduces a state-local Entity userdata to the engine identity that is
    /// valid on the network transport. The receiving realm resolves that
    /// index through its own canonical registry.
    func networkIndex(from value: LuaValue, function: String) throws -> Int {
        guard let object = GMLuaTypeSystem.typedObject(from: value),
              ["Entity", "Player", "Weapon", "Vehicle"].contains(object.metaName) else {
            throw LuaError.runtime(
                "bad argument #2 to '\(function)' (Entity expected, got \(value.typeName))"
            )
        }
        guard object.isValid else { return -1 }
        guard let payload = object.payload as? GMLuaEntityValue else {
            throw LuaError.runtime("\(function) received an unregistered engine object")
        }
        return payload.index
    }

    func playerNetworkIndex(
        from value: LuaValue,
        function: String,
        argumentPosition: Int = 1
    ) throws -> Int {
        guard let object = GMLuaTypeSystem.typedObject(from: value),
              object.metaName == "Player" else {
            throw LuaError.runtime(
                "bad argument #\(argumentPosition) to '\(function)' " +
                "(Player expected, got \(value.typeName))"
            )
        }
        guard object.isValid,
              let payload = object.payload as? GMLuaEntityValue,
              payload.kind == .player else {
            throw LuaError.runtime(
                "bad argument #\(argumentPosition) to '\(function)' " +
                "(current connected Player expected, got invalid Player)"
            )
        }
        let canonical = player(at: payload.index)
        guard GMLuaTypeSystem.typedObject(from: canonical) === object else {
            throw LuaError.runtime(
                "bad argument #\(argumentPosition) to '\(function)' " +
                "(stale Player generation)"
            )
        }
        return payload.index
    }

    /// Installs a native Player method before the bundled Lua extensions load
    /// and capture it. Keeping this on the canonical metatable preserves the
    /// ordinary Player/Entity lookup chain and stale-generation validation.
    func installPlayerMethod(named name: String, function: LuaValue) throws {
        guard let playerMetatable = typeSystem.metatable(named: "Player") else {
            throw LuaError.runtime("GLua Player metatable was not installed")
        }
        try state.setRawTableValue(
            function,
            for: .string(LuaString(name)),
            in: playerMetatable
        )
    }

    public var registeredCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return values.count
    }

    fileprivate func luaTable(for value: LuaValue) -> LuaTable? {
        guard case let .userdata(userdata) = value,
              let object = GMLuaTypeSystem.typedObject(from: value),
              let payload = object.payload as? GMLuaEntityValue else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard object.isValid,
              case let .userdata(canonical)? = values[payload.index],
              canonical === userdata else { return nil }
        return payload.luaTable
    }

    fileprivate func indexedLuaTableValue(
        for value: LuaValue,
        key: LuaValue
    ) throws -> LuaValue {
        guard let table = luaTable(for: value) else { return .nilValue }
        return try state.call(
            semanticIndex,
            arguments: [.table(table), key]
        ).first ?? .nilValue
    }

    @discardableResult
    fileprivate func setIndexedLuaTableValue(
        _ newValue: LuaValue,
        for value: LuaValue,
        key: LuaValue
    ) throws -> Bool {
        // Capture under the registry lock, then run ordinary table assignment
        // outside it because a custom __newindex may execute arbitrary Lua.
        guard let table = luaTable(for: value) else { return false }
        try state.setTableValue(newValue, for: key, in: table)
        return true
    }

    @discardableResult
    fileprivate func replaceLuaTable(
        for value: LuaValue,
        with replacement: LuaTable
    ) -> Bool {
        guard case let .userdata(userdata) = value,
              let object = GMLuaTypeSystem.typedObject(from: value),
              let payload = object.payload as? GMLuaEntityValue else { return false }
        lock.lock()
        guard object.isValid,
              case let .userdata(canonical)? = values[payload.index],
              canonical === userdata else {
            lock.unlock()
            return false
        }
        payload.luaTable = replacement
        lock.unlock()
        state.refreshGarbageCollectionRootProviders()
        return true
    }

    fileprivate var references: [LuaValue] {
        lock.lock()
        defer { lock.unlock() }
        let canonical = Array(values.values)
        let tables = canonical.compactMap { value -> LuaTable? in
            guard let payload = GMLuaTypeSystem.typedObject(from: value)?.payload
                as? GMLuaEntityValue else { return nil }
            return payload.luaTable
        }.map(LuaValue.table)
        return canonical + tables + entityReplicationPendingReferences +
            [nullValue, semanticIndex]
    }

    fileprivate func all(kind: GMLuaEntityKind? = nil) -> [LuaValue] {
        lock.lock()
        defer { lock.unlock() }
        return values.keys.sorted().compactMap { index in
            guard let value = values[index],
                  GMLuaTypeSystem.typedObject(from: value)?.isValid == true else { return nil }
            if let kind,
               (GMLuaTypeSystem.typedObject(from: value)?.payload as? GMLuaEntityValue)?.kind != kind {
                return nil
            }
            return value
        }
    }

    public static func install(
        into state: LuaState,
        typeSystem: GMLuaTypeSystem,
        realm: GMLuaRealm = .server
    ) throws -> GMLuaEntityRegistry {
        let semanticIndex = try state.executeReturningValues(
            "return function(container, key) return container[key] end",
            sourceName: "=[GModLua Entity table index helper]"
        ).first ?? .nilValue
        let nullValue = state.getGlobal("NULL")
        let registry = GMLuaEntityRegistry(
            state: state,
            typeSystem: typeSystem,
            realm: realm,
            nullValue: nullValue,
            semanticIndex: semanticIndex
        )
        state.registerGarbageCollectionRootProvider { [weak registry] in
            registry?.references ?? []
        }

        let entityMetatableNames = ["Entity", "Player", "Weapon", "Vehicle"]
        func entityNativeFunction(
            _ name: String,
            _ body: @escaping LuaNativeFunction
        ) -> LuaValue {
            .nativeFunction(
                LuaNativeFunctionBox(
                    body,
                    debugName: name,
                    gcReferences: { [weak registry] in registry?.references ?? [] }
                )
            )
        }
        for methodName in ["EntIndex", "GetClass", "IsPlayer", "IsWeapon", "IsVehicle"] {
            let function = entityNativeFunction("Entity:\(methodName)") { arguments in
                        let descriptor = try descriptor(arguments.first, method: methodName)
                        switch methodName {
                        case "EntIndex": return [.number(Double(descriptor?.index ?? 0))]
                        case "GetClass": return [.string(LuaString(descriptor?.className ?? "NULL"))]
                        case "IsPlayer": return [.boolean(descriptor?.kind == .player)]
                        case "IsWeapon": return [.boolean(descriptor?.kind == .weapon)]
                        case "IsVehicle": return [.boolean(descriptor?.kind == .vehicle)]
                        default: return []
                        }
                    }
            for metatableName in entityMetatableNames {
                guard let metatable = typeSystem.metatable(named: metatableName) else { continue }
                try state.setRawTableValue(
                    function,
                    for: .string(LuaString(methodName)),
                    in: metatable
                )
            }
        }

        // Typed-object lifetime validity answers whether this userdata still
        // names the canonical slot occupant. GLua semantic validity is a
        // separate property: Entity(0) is the canonical world userdata and is
        // distinct from NULL, but world:IsValid() is false.
        let entityIsValid = entityNativeFunction("Entity:IsValid") { arguments in
            guard let value = arguments.first,
                  let object = GMLuaTypeSystem.typedObject(from: value),
                  entityMetatableNames.contains(object.metaName) else {
                throw LuaError.runtime(
                    "bad self to 'Entity:IsValid' " +
                    "(Entity expected, got \(arguments.first?.typeName ?? "no value"))"
                )
            }
            guard object.isValid else { return [.boolean(false)] }
            guard let payload = object.payload as? GMLuaEntityValue else {
                // Preserve the native type ABI for host-created typed objects
                // that are not members of this Entity registry.
                return [.boolean(true)]
            }
            return [.boolean(payload.semanticValidity)]
        }
        for metatableName in entityMetatableNames {
            guard let metatable = typeSystem.metatable(named: metatableName) else { continue }
            try state.setRawTableValue(
                entityIsValid,
                for: .string("IsValid"),
                in: metatable
            )
        }

        // Source SDK 2013 `in_buttons.h` values are centralized by
        // SourceInputButtons. Exporting the GLua spellings from those values
        // avoids a second independently maintained numeric contract.
        let buttonGlobals: [(String, SourceInputButtons)] = [
            ("IN_ATTACK", .attack),
            ("IN_JUMP", .jump),
            ("IN_DUCK", .duck),
            ("IN_FORWARD", .forward),
            ("IN_BACK", .back),
            ("IN_USE", .use),
            ("IN_CANCEL", .cancel),
            ("IN_LEFT", .left),
            ("IN_RIGHT", .right),
            ("IN_MOVELEFT", .moveLeft),
            ("IN_MOVERIGHT", .moveRight),
            ("IN_ATTACK2", .attack2),
            ("IN_RUN", .run),
            ("IN_RELOAD", .reload),
            ("IN_ALT1", .alternate1),
            ("IN_ALT2", .alternate2),
            ("IN_SCORE", .score),
            ("IN_SPEED", .speed),
            ("IN_WALK", .walk),
            ("IN_ZOOM", .zoom),
            ("IN_WEAPON1", .weapon1),
            ("IN_WEAPON2", .weapon2),
            ("IN_BULLRUSH", .bullRush),
            ("IN_GRENADE1", .grenade1),
            ("IN_GRENADE2", .grenade2),
            ("IN_ATTACK3", .attack3),
        ]
        for (name, buttons) in buttonGlobals {
            state.setGlobal(name, value: .number(Double(buttons.rawValue)))
        }

        guard let playerMetatable = typeSystem.metatable(named: "Player") else {
            throw LuaError.runtime("GLua Player metatable was not installed")
        }
        let playerKeyDown = entityNativeFunction("Player:KeyDown") { arguments in
            guard let receiver = arguments.first,
                  let current = registry.playerInputButtons(for: receiver) else {
                return [.boolean(false)]
            }
            let mask = try inputButtonMask(
                arguments,
                index: 1,
                function: "Player:KeyDown"
            )
            return [.boolean((current.rawValue & mask) != 0)]
        }
        try state.setRawTableValue(
            playerKeyDown,
            for: .string("KeyDown"),
            in: playerMetatable
        )

        let getTable = entityNativeFunction("Entity:GetTable") { arguments in
            _ = try descriptor(arguments.first, method: "GetTable")
            return [arguments.first.flatMap(registry.luaTable(for:)).map(LuaValue.table)
                ?? .nilValue]
        }
        let setTable = entityNativeFunction("Entity:SetTable") { arguments in
            _ = try descriptor(arguments.first, method: "SetTable")
            guard arguments.indices.contains(1), case let .table(table) = arguments[1] else {
                let actual = arguments.indices.contains(1)
                    ? arguments[1].typeName
                    : "no value"
                throw LuaError.runtime(
                    "bad argument #1 to 'Entity:SetTable' (table expected, got \(actual))"
                )
            }
            if let receiver = arguments.first {
                _ = registry.replaceLuaTable(for: receiver, with: table)
            }
            return []
        }
        for metatableName in entityMetatableNames {
            guard let metatable = typeSystem.metatable(named: metatableName) else { continue }
            try state.setRawTableValue(getTable, for: .string("GetTable"), in: metatable)
            try state.setRawTableValue(setTable, for: .string("SetTable"), in: metatable)
        }

        let entityEquality = entityNativeFunction("Entity.__eq") { arguments in
            guard arguments.count >= 2,
                  let left = GMLuaTypeSystem.typedObject(from: arguments[0]),
                  let right = GMLuaTypeSystem.typedObject(from: arguments[1]) else {
                return [.boolean(false)]
            }
            return [.boolean(!left.isValid && !right.isValid)]
        }
        for metatableName in entityMetatableNames {
            guard let metatable = typeSystem.metatable(named: metatableName) else { continue }
            try state.setRawTableValue(
                entityEquality,
                for: .string("__eq"),
                in: metatable
            )
        }

        guard let entityMetatable = typeSystem.metatable(named: "Entity") else {
            throw LuaError.runtime("GLua Entity metatable was not installed")
        }
        for metatableName in entityMetatableNames {
            guard let metatable = typeSystem.metatable(named: metatableName) else { continue }
            let methodTables = metatableName == "Entity"
                ? [entityMetatable]
                : [metatable, entityMetatable]
            let index = entityNativeFunction("\(metatableName).__index") { arguments in
                guard arguments.indices.contains(1) else { return [.nilValue] }
                for methodTable in methodTables {
                    let method = try state.rawTableValue(for: arguments[1], in: methodTable)
                    if case .nilValue = method {
                        continue
                    }
                    return [method]
                }
                let tableValue = try registry.indexedLuaTableValue(
                    for: arguments[0],
                    key: arguments[1]
                )
                if case .nilValue = tableValue {
                    if metatableName == "Entity",
                       case let .string(key) = arguments[1],
                       key.utf8String == "Owner" {
                        let getOwner = try state.rawTableValue(
                            for: .string("GetOwner"),
                            in: entityMetatable
                        )
                        switch getOwner {
                        case .luaFunction, .nativeFunction:
                            return [try state.call(
                                getOwner,
                                arguments: [arguments[0]]
                            ).first ?? .nilValue]
                        default:
                            break
                        }
                    }
                }
                return [tableValue]
            }
            let newIndex = entityNativeFunction("\(metatableName).__newindex") { arguments in
                guard arguments.count >= 3 else { return [] }
                _ = try registry.setIndexedLuaTableValue(
                    arguments[2],
                    for: arguments[0],
                    key: arguments[1]
                )
                return []
            }
            try state.setRawTableValue(index, for: .string("__index"), in: metatable)
            try state.setRawTableValue(newIndex, for: .string("__newindex"), in: metatable)
        }

        let entityLookup = LuaValue.nativeFunction(
            LuaNativeFunctionBox(
                { [weak registry] arguments in
                    guard let registry else { return [.nilValue] }
                    let index = try entityIndex(arguments, function: "Entity")
                    return [registry.entity(at: index)]
                },
                debugName: "Entity",
                gcReferences: { [weak registry] in registry?.references ?? [] }
            )
        )
        state.setGlobal("Entity", value: entityLookup)

        let playerLookup = LuaValue.nativeFunction(
            LuaNativeFunctionBox(
                { [weak registry] arguments in
                    guard let registry else { return [.nilValue] }
                    let userID = try entityIndex(arguments, function: "Player")
                    return [registry.player(forUserID: userID)]
                },
                debugName: "Player",
                gcReferences: { [weak registry] in registry?.references ?? [] }
            )
        )
        state.setGlobal("Player", value: playerLookup)
        if realm == .client {
            state.setGlobal(
                "LocalPlayer",
                value: .nativeFunction(
                    LuaNativeFunctionBox(
                        { [weak registry] _ in
                            [registry?.localPlayer() ?? nullValue]
                        },
                        debugName: "LocalPlayer",
                        gcReferences: { [weak registry] in registry?.references ?? [] }
                    )
                )
            )
        }

        let ents = existingTable(named: "ents", in: state)
        let player = existingTable(named: "player", in: state)

        try state.setRawTableValue(
            .nativeFunction(
                LuaNativeFunctionBox(
                    { [weak registry, weak state] _ in
                        guard let registry, let state else { return [.table(LuaTable())] }
                        return [.table(try valueArray(registry.all(), state: state))]
                    },
                    debugName: "ents.GetAll",
                    gcReferences: { [weak registry] in registry?.references ?? [] }
                )
            ),
            for: .string("GetAll"),
            in: ents
        )
        try state.setRawTableValue(entityLookup, for: .string("GetByIndex"), in: ents)
        try state.setRawTableValue(
            .nativeFunction(
                LuaNativeFunctionBox(
                    { [weak registry, weak state] _ in
                        guard let registry, let state else { return [.table(LuaTable())] }
                        return [.table(try valueArray(registry.all(kind: .player), state: state))]
                    },
                    debugName: "player.GetAll",
                    gcReferences: { [weak registry] in registry?.references ?? [] }
                )
            ),
            for: .string("GetAll"),
            in: player
        )
        state.setGlobal("ents", value: .table(ents))
        state.setGlobal("player", value: .table(player))
        return registry
    }

    private static func descriptor(
        _ value: LuaValue?,
        method: String
    ) throws -> GMLuaEntityValue? {
        guard let value,
              let object = GMLuaTypeSystem.typedObject(from: value),
              ["Entity", "Player", "Weapon", "Vehicle"].contains(object.metaName) else {
            throw LuaError.runtime(
                "bad self to 'Entity:\(method)' (Entity expected, got \(value?.typeName ?? "no value"))"
            )
        }
        guard object.isValid else { return nil }
        guard let payload = object.payload as? GMLuaEntityValue else {
            throw LuaError.runtime("Entity:\(method) received an unregistered engine object")
        }
        return payload
    }

    private static func inputButtonMask(
        _ arguments: [LuaValue],
        index: Int,
        function: String
    ) throws -> UInt32 {
        guard arguments.indices.contains(index) else {
            throw LuaError.runtime(
                "bad argument #\(index) to '\(function)' (number expected, got no value)"
            )
        }
        let number: Double?
        switch arguments[index] {
        case let .number(value):
            number = value
        case let .string(value):
            number = Double(value.utf8String)
        default:
            number = nil
        }
        guard let number,
              number.isFinite,
              number.rounded(.towardZero) == number,
              number >= Double(Int32.min),
              number <= Double(UInt32.max) else {
            throw LuaError.runtime(
                "bad argument #\(index) to '\(function)' (32-bit integer expected)"
            )
        }
        if number < 0 {
            return UInt32(bitPattern: Int32(number))
        }
        return UInt32(number)
    }

    private static func entityIndex(_ arguments: [LuaValue], function: String) throws -> Int {
        guard let first = arguments.first else {
            throw LuaError.runtime("bad argument #1 to '\(function)' (number expected, got no value)")
        }
        let number: Double
        switch first {
        case let .number(value): number = value
        case let .string(value):
            guard let parsed = Double(value.utf8String) else {
                throw LuaError.runtime("bad argument #1 to '\(function)' (number expected, got string)")
            }
            number = parsed
        default:
            throw LuaError.runtime(
                "bad argument #1 to '\(function)' (number expected, got \(first.typeName))"
            )
        }
        let lowerBoundInclusive = Double(Int.min)
        let upperBoundExclusive = -lowerBoundInclusive
        guard number.isFinite,
              number >= lowerBoundInclusive,
              number < upperBoundExclusive else {
            throw LuaError.runtime("bad argument #1 to '\(function)' (finite entity index expected)")
        }
        return Int(number.rounded(.towardZero))
    }

    private static func existingTable(named name: String, in state: LuaState) -> LuaTable {
        if case let .table(table) = state.getGlobal(name) { return table }
        return LuaTable()
    }

    private static func valueArray(_ values: [LuaValue], state: LuaState) throws -> LuaTable {
        let table = LuaTable()
        for (offset, value) in values.enumerated() {
            try state.setRawTableValue(
                value,
                for: .number(Double(offset + 1)),
                in: table
            )
        }
        return table
    }
}
