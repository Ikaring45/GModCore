import Foundation

/// Identifies one SERVER -> CLIENT replication connection. Packet sequences
/// restart at one for each generation, while generations never move backwards.
/// Keeping this identity outside EHANDLE prevents packets from an old
/// connection from mutating a newly connected client that reused the same
/// entity slot and serial.
public struct SourceEntityReplicationConnectionGeneration:
    RawRepresentable,
    Equatable,
    Hashable,
    Comparable,
    Sendable
{
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static func < (
        lhs: SourceEntityReplicationConnectionGeneration,
        rhs: SourceEntityReplicationConnectionGeneration
    ) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// An ordered entity mutation. Every case carries the complete canonical
/// identity through `SourceCanonicalEntitySnapshot.identity.handle`; remove
/// also carries the final SERVER revision rather than reducing the event to an
/// entry index.
public enum SourceEntityReplicationOperation: Equatable, Sendable {
    case create(SourceCanonicalEntitySnapshot)
    case update(SourceCanonicalEntitySnapshot)
    case remove(SourceCanonicalEntitySnapshot)
}

public enum SourceEntityReplicationChangeKind: Equatable, Sendable {
    case snapshot
    case create
    case update
    case remove
}

/// A new connection begins with exactly one full snapshot. Later packets are
/// deltas whose operation array is applied in order.
public enum SourceEntityReplicationPayload: Equatable, Sendable {
    case snapshot([SourceCanonicalEntitySnapshot])
    case delta([SourceEntityReplicationOperation])
}

/// Transport-neutral replication packet. The existing shared-session FIFO can
/// carry this value without giving the CLIENT a reference to SERVER entities.
public struct SourceEntityReplicationPacket: Equatable, Sendable {
    public let connectionGeneration: SourceEntityReplicationConnectionGeneration
    public let sequence: UInt64
    public let payload: SourceEntityReplicationPayload

    public init(
        connectionGeneration: SourceEntityReplicationConnectionGeneration,
        sequence: UInt64,
        payload: SourceEntityReplicationPayload
    ) {
        self.connectionGeneration = connectionGeneration
        self.sequence = sequence
        self.payload = payload
    }
}

public enum SourceEntityReplicationStreamError: Error, Equatable, Sendable {
    case invalidConnectionGeneration
    case snapshotAlreadySent
    case snapshotRequired
    case sequenceExhausted
}

/// SERVER-side packet stamper. It does not own entities and does not introduce
/// another queue.
///
/// The later integration seam is deliberately narrow: add an entity case to
/// `GMLuaNetTransport`'s existing private `GMLuaTransportDelivery`, stamp that
/// envelope with the transport's global `nextSequence`, and append it to the
/// existing `deliveries` array. `GMLuaSharedSession.pump(maxDeliveries:)` stays
/// the only drain boundary. The packet's sequence remains the per-connection
/// entity sequence; it must not replace the outer FIFO sequence.
public struct SourceEntityReplicationServerStream: Sendable {
    public let connectionGeneration: SourceEntityReplicationConnectionGeneration
    public private(set) var nextSequence: UInt64 = 1
    public private(set) var hasSentSnapshot = false

    public init(
        connectionGeneration: SourceEntityReplicationConnectionGeneration
    ) throws {
        guard connectionGeneration.rawValue > 0 else {
            throw SourceEntityReplicationStreamError.invalidConnectionGeneration
        }
        self.connectionGeneration = connectionGeneration
    }

    public mutating func makeSnapshot(
        _ entities: [SourceCanonicalEntitySnapshot]
    ) throws -> SourceEntityReplicationPacket {
        guard !hasSentSnapshot else {
            throw SourceEntityReplicationStreamError.snapshotAlreadySent
        }
        let packet = try makePacket(payload: .snapshot(entities))
        hasSentSnapshot = true
        return packet
    }

    public mutating func makeDelta(
        _ operations: [SourceEntityReplicationOperation]
    ) throws -> SourceEntityReplicationPacket {
        guard hasSentSnapshot else {
            throw SourceEntityReplicationStreamError.snapshotRequired
        }
        return try makePacket(payload: .delta(operations))
    }

    private mutating func makePacket(
        payload: SourceEntityReplicationPayload
    ) throws -> SourceEntityReplicationPacket {
        guard nextSequence != UInt64.max else {
            throw SourceEntityReplicationStreamError.sequenceExhausted
        }
        let packet = SourceEntityReplicationPacket(
            connectionGeneration: connectionGeneration,
            sequence: nextSequence,
            payload: payload
        )
        nextSequence += 1
        return packet
    }
}

/// Immutable renderer/Lua-facing CLIENT view. Entity order follows Source's
/// entity-list entry-index order and no SERVER-owned object crosses this boundary.
public struct SourceEntityReplicationClientSnapshot: Equatable, Sendable {
    public let connectionGeneration: SourceEntityReplicationConnectionGeneration
    public let sequence: UInt64
    public let entities: [SourceCanonicalEntitySnapshot]

    public init(
        connectionGeneration: SourceEntityReplicationConnectionGeneration,
        sequence: UInt64,
        entities: [SourceCanonicalEntitySnapshot]
    ) {
        self.connectionGeneration = connectionGeneration
        self.sequence = sequence
        self.entities = entities
    }
}

public enum SourceEntityReplicationRejection: Equatable, Sendable {
    case noActiveConnection
    case connectionGenerationMismatch(
        expected: SourceEntityReplicationConnectionGeneration,
        received: SourceEntityReplicationConnectionGeneration
    )
    case invalidSequence
    case duplicateSequence(UInt64)
    case staleSequence(lastApplied: UInt64, received: UInt64)
    case outOfOrderSequence(expected: UInt64, received: UInt64)
    case initialPacketMustBeSnapshot
    case unexpectedSnapshot
    case invalidEntityHandle(SourceBaseHandle)
    case nonNetworkableEntity(SourceBaseHandle)
    case classNameKindMismatch(
        handle: SourceBaseHandle,
        expected: String,
        received: String
    )
    case lifecycleNotAllowed(
        change: SourceEntityReplicationChangeKind,
        handle: SourceBaseHandle,
        lifecycle: SourceCanonicalEntityLifecycle
    )
    case duplicateSnapshotHandle(SourceBaseHandle)
    case entryGenerationConflict(existing: SourceBaseHandle, incoming: SourceBaseHandle)
    case entityAlreadyExists(SourceBaseHandle)
    case missingEntity(SourceBaseHandle)
    case nonMonotonicRevision(handle: SourceBaseHandle, current: UInt64, received: UInt64)
    case sequenceExhausted
}

public enum SourceEntityReplicationApplyResult: Equatable, Sendable {
    case applied(SourceEntityReplicationClientSnapshot)
    case rejected(SourceEntityReplicationRejection)
}

/// CLIENT-side transactional mirror. A packet is validated and replayed into a
/// temporary value dictionary first. Storage and sequence advance together only
/// after every operation succeeds.
public struct SourceEntityReplicationClientState: Sendable {
    public private(set) var activeConnectionGeneration:
        SourceEntityReplicationConnectionGeneration?
    public private(set) var highestConnectionGeneration:
        SourceEntityReplicationConnectionGeneration?
    public private(set) var lastAppliedSequence: UInt64 = 0

    private var entitiesByEntryIndex: [Int: SourceCanonicalEntitySnapshot] = [:]

    public init() {}

    /// Begins a fresh connection only when its generation is newer than every
    /// connection previously observed by this state machine.
    @discardableResult
    public mutating func connect(
        generation: SourceEntityReplicationConnectionGeneration
    ) -> Bool {
        guard generation.rawValue > 0 else { return false }
        if let highestConnectionGeneration,
           generation <= highestConnectionGeneration {
            return false
        }
        activeConnectionGeneration = generation
        highestConnectionGeneration = generation
        lastAppliedSequence = 0
        entitiesByEntryIndex.removeAll(keepingCapacity: true)
        return true
    }

    /// Drops the live mirror but deliberately retains the highest generation,
    /// making delayed packets and attempts to reuse a connection generation
    /// unable to enter a later session.
    public mutating func disconnect() {
        activeConnectionGeneration = nil
        lastAppliedSequence = 0
        entitiesByEntryIndex.removeAll(keepingCapacity: true)
    }

    public var snapshot: SourceEntityReplicationClientSnapshot? {
        guard let activeConnectionGeneration else { return nil }
        return makeSnapshot(
            generation: activeConnectionGeneration,
            sequence: lastAppliedSequence,
            entitiesByEntryIndex: entitiesByEntryIndex
        )
    }

    @discardableResult
    public mutating func apply(
        _ packet: SourceEntityReplicationPacket
    ) -> SourceEntityReplicationApplyResult {
        guard let activeConnectionGeneration else {
            return .rejected(.noActiveConnection)
        }
        guard packet.connectionGeneration == activeConnectionGeneration else {
            return .rejected(
                .connectionGenerationMismatch(
                    expected: activeConnectionGeneration,
                    received: packet.connectionGeneration
                )
            )
        }
        guard packet.sequence > 0 else {
            return .rejected(.invalidSequence)
        }
        if packet.sequence == lastAppliedSequence {
            return .rejected(.duplicateSequence(packet.sequence))
        }
        if packet.sequence < lastAppliedSequence {
            return .rejected(
                .staleSequence(
                    lastApplied: lastAppliedSequence,
                    received: packet.sequence
                )
            )
        }
        guard lastAppliedSequence != UInt64.max else {
            return .rejected(.sequenceExhausted)
        }
        let expectedSequence = lastAppliedSequence + 1
        guard packet.sequence == expectedSequence else {
            return .rejected(
                .outOfOrderSequence(
                    expected: expectedSequence,
                    received: packet.sequence
                )
            )
        }

        var transaction = entitiesByEntryIndex
        let rejection: SourceEntityReplicationRejection?
        switch packet.payload {
        case let .snapshot(entities):
            guard lastAppliedSequence == 0 else {
                return .rejected(.unexpectedSnapshot)
            }
            transaction.removeAll(keepingCapacity: true)
            rejection = applySnapshot(entities, to: &transaction)

        case let .delta(operations):
            guard lastAppliedSequence > 0 else {
                return .rejected(.initialPacketMustBeSnapshot)
            }
            rejection = applyDelta(operations, to: &transaction)
        }

        if let rejection {
            return .rejected(rejection)
        }

        entitiesByEntryIndex = transaction
        lastAppliedSequence = packet.sequence
        return .applied(
            makeSnapshot(
                generation: activeConnectionGeneration,
                sequence: packet.sequence,
                entitiesByEntryIndex: transaction
            )
        )
    }

    private func applySnapshot(
        _ entities: [SourceCanonicalEntitySnapshot],
        to transaction: inout [Int: SourceCanonicalEntitySnapshot]
    ) -> SourceEntityReplicationRejection? {
        for entity in entities {
            if let rejection = validateEntity(entity, for: .snapshot) { return rejection }
            let handle = entity.identity.handle
            if let existing = transaction[handle.entryIndex] {
                if existing.identity.handle == handle {
                    return .duplicateSnapshotHandle(handle)
                }
                return .entryGenerationConflict(
                    existing: existing.identity.handle,
                    incoming: handle
                )
            }
            transaction[handle.entryIndex] = entity
        }
        return nil
    }

    private func applyDelta(
        _ operations: [SourceEntityReplicationOperation],
        to transaction: inout [Int: SourceCanonicalEntitySnapshot]
    ) -> SourceEntityReplicationRejection? {
        for operation in operations {
            switch operation {
            case let .create(entity):
                if let rejection = validateEntity(entity, for: .create) { return rejection }
                let handle = entity.identity.handle
                if let existing = transaction[handle.entryIndex] {
                    if existing.identity.handle == handle {
                        return .entityAlreadyExists(handle)
                    }
                    return .entryGenerationConflict(
                        existing: existing.identity.handle,
                        incoming: handle
                    )
                }
                transaction[handle.entryIndex] = entity

            case let .update(entity):
                if let rejection = validateEntity(entity, for: .update) { return rejection }
                let handle = entity.identity.handle
                guard let existing = transaction[handle.entryIndex] else {
                    return .missingEntity(handle)
                }
                guard existing.identity.handle == handle else {
                    return .entryGenerationConflict(
                        existing: existing.identity.handle,
                        incoming: handle
                    )
                }
                guard entity.revision > existing.revision else {
                    return .nonMonotonicRevision(
                        handle: handle,
                        current: existing.revision,
                        received: entity.revision
                    )
                }
                transaction[handle.entryIndex] = entity

            case let .remove(entity):
                if let rejection = validateEntity(entity, for: .remove) { return rejection }
                let handle = entity.identity.handle
                guard let existing = transaction[handle.entryIndex] else {
                    return .missingEntity(handle)
                }
                guard existing.identity.handle == handle else {
                    return .entryGenerationConflict(
                        existing: existing.identity.handle,
                        incoming: handle
                    )
                }
                guard entity.revision > existing.revision else {
                    return .nonMonotonicRevision(
                        handle: handle,
                        current: existing.revision,
                        received: entity.revision
                    )
                }
                transaction.removeValue(forKey: handle.entryIndex)
            }
        }
        return nil
    }

    private func validateEntity(
        _ entity: SourceCanonicalEntitySnapshot,
        for change: SourceEntityReplicationChangeKind
    ) -> SourceEntityReplicationRejection? {
        let handle = entity.identity.handle
        guard handle.isValid else {
            return .invalidEntityHandle(handle)
        }
        guard entity.isNetworkable,
              handle.entryIndex >= 0,
              handle.entryIndex < SourceEntityConstants.maxEdicts else {
            return .nonNetworkableEntity(handle)
        }
        guard entity.className == entity.kind.className else {
            return .classNameKindMismatch(
                handle: handle,
                expected: entity.kind.className,
                received: entity.className
            )
        }
        let lifecycleIsAllowed: Bool
        switch change {
        case .snapshot, .create:
            lifecycleIsAllowed = entity.lifecycle != .pendingRemoval &&
                entity.lifecycle != .removed
        case .update:
            lifecycleIsAllowed = entity.lifecycle != .removed
        case .remove:
            lifecycleIsAllowed = entity.lifecycle == .removed
        }
        guard lifecycleIsAllowed else {
            return .lifecycleNotAllowed(
                change: change,
                handle: handle,
                lifecycle: entity.lifecycle
            )
        }
        return nil
    }

    private func makeSnapshot(
        generation: SourceEntityReplicationConnectionGeneration,
        sequence: UInt64,
        entitiesByEntryIndex: [Int: SourceCanonicalEntitySnapshot]
    ) -> SourceEntityReplicationClientSnapshot {
        SourceEntityReplicationClientSnapshot(
            connectionGeneration: generation,
            sequence: sequence,
            entities: entitiesByEntryIndex.values.sorted {
                $0.identity.handle.entryIndex < $1.identity.handle.entryIndex
            }
        )
    }
}
