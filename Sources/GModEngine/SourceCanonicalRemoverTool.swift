import Foundation

/// Stock remover buttons use these numeric values when they call
/// `GM:CanTool`: primary, secondary, and reload respectively.
public enum SourceCanonicalRemoverToolAction: UInt8, Equatable, Sendable {
    case leftClick = 1
    case rightClick = 2
    case reload = 3
}

public enum SourceCanonicalRemoverToolRejection: Equatable, Sendable {
    case actorIsNotLivePlayer
    case targetIsNotLive
    case targetIsWorld
    case targetIsPlayer
    case targetIsPendingRemoval
    case canToolDenied
    case noConstraints
}

/// One backend-complete constraint removal. `constraintEntities` contains the
/// exact constraint EHANDLEs whose physics/backend teardown has already been
/// enqueued by the constraint host. The remover only schedules their Source
/// entity lifetime removal; it never claims that deleting graph topology alone
/// destroyed a real weld, rope, or future constraint body.
public struct SourceCanonicalRemoverConstraintRemoval:
    Equatable,
    Sendable
{
    public let records: [SourceCanonicalConstraintRecord]
    public let constraintEntities: [SourceCanonicalEntityIdentity]

    public init(
        records: [SourceCanonicalConstraintRecord],
        constraintEntities: [SourceCanonicalEntityIdentity]
    ) {
        self.records = records.sorted { $0.identifier < $1.identifier }
        self.constraintEntities = Array(Set(constraintEntities)).sorted {
            $0.handle.rawValue < $1.handle.rawValue
        }
    }

    public static let empty = SourceCanonicalRemoverConstraintRemoval(
        records: [],
        constraintEntities: []
    )
}

/// Concrete weld/rope backends implement this narrow boundary. The stock
/// remover asks for the connected component before right click and performs a
/// backend-complete `constraint.RemoveAll` for each entity selected by the
/// original algorithm.
public protocol SourceCanonicalRemoverConstraintHost: AnyObject {
    func allConstrainedEntities(
        startingAt entity: SourceCanonicalEntityIdentity
    ) -> [SourceCanonicalEntityIdentity]

    func removeAllConstraints(
        involving entity: SourceCanonicalEntityIdentity
    ) throws -> SourceCanonicalRemoverConstraintRemoval
}

/// Deliberately explicit empty implementation for sessions with no concrete
/// constraint backend. It reports no removal rather than manufacturing a
/// successful constraint operation.
public final class SourceCanonicalEmptyRemoverConstraintHost:
    SourceCanonicalRemoverConstraintHost,
    @unchecked Sendable
{
    public init() {}

    public func allConstrainedEntities(
        startingAt entity: SourceCanonicalEntityIdentity
    ) -> [SourceCanonicalEntityIdentity] {
        [entity]
    }

    public func removeAllConstraints(
        involving entity: SourceCanonicalEntityIdentity
    ) throws -> SourceCanonicalRemoverConstraintRemoval {
        .empty
    }
}

/// Authoritative entity surface used by the remover. The live snapshot lookup
/// and every mutation are full-EHANDLE operations, so a delayed callback can
/// never delete a replacement that reused the same entry index.
public protocol SourceCanonicalRemoverEntityHost: AnyObject {
    func canonicalSnapshot(
        for identity: SourceCanonicalEntityIdentity
    ) -> SourceCanonicalEntitySnapshot?

    func updateCanonicalEntity(
        _ identity: SourceCanonicalEntityIdentity,
        _ mutation: (inout SourceCanonicalEntityState) throws -> Void
    ) throws -> SourceCanonicalEntitySnapshot

    func markCanonicalEntityForRemoval(
        _ identity: SourceCanonicalEntityIdentity
    ) throws -> SourceCanonicalEntitySnapshot
}

extension GMLuaSourceRuntimeAdapter: SourceCanonicalRemoverEntityHost {}

public struct SourceCanonicalRemoverCanToolRequest: Equatable, Sendable {
    public let actor: SourceCanonicalEntitySnapshot
    public let target: SourceCanonicalEntitySnapshot
    public let mode: String
    public let action: SourceCanonicalRemoverToolAction

    public init(
        actor: SourceCanonicalEntitySnapshot,
        target: SourceCanonicalEntitySnapshot,
        mode: String = "remover",
        action: SourceCanonicalRemoverToolAction
    ) {
        self.actor = actor
        self.target = target
        self.mode = mode
        self.action = action
    }
}

public typealias SourceCanonicalRemoverCanTool =
    (SourceCanonicalRemoverCanToolRequest) throws -> Bool

/// Token retained by the one-second stock `timer.Simple` callback. The token
/// maps to immutable full handles, never entry indices or Lua userdata.
public struct SourceCanonicalRemoverTicket:
    Equatable,
    Hashable,
    Sendable
{
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }
}

public struct SourceCanonicalRemoverEffect: Equatable, Sendable {
    public let entity: SourceCanonicalEntityIdentity
    public let origin: SourceVector3

    public init(
        entity: SourceCanonicalEntityIdentity,
        origin: SourceVector3
    ) {
        self.entity = entity
        self.origin = origin
    }
}

public struct SourceCanonicalRemoverToolResult: Equatable, Sendable {
    public let accepted: Bool
    public let rejection: SourceCanonicalRemoverToolRejection?
    public let ticket: SourceCanonicalRemoverTicket?
    public let stagedEntities: [SourceCanonicalEntityIdentity]
    public let removedConstraintRecords: [SourceCanonicalConstraintRecord]
    public let constraintEntitiesScheduledForRemoval:
        [SourceCanonicalEntityIdentity]
    public let effects: [SourceCanonicalRemoverEffect]

    public init(
        accepted: Bool,
        rejection: SourceCanonicalRemoverToolRejection?,
        ticket: SourceCanonicalRemoverTicket?,
        stagedEntities: [SourceCanonicalEntityIdentity],
        removedConstraintRecords: [SourceCanonicalConstraintRecord],
        constraintEntitiesScheduledForRemoval:
            [SourceCanonicalEntityIdentity],
        effects: [SourceCanonicalRemoverEffect]
    ) {
        self.accepted = accepted
        self.rejection = rejection
        self.ticket = ticket
        self.stagedEntities = stagedEntities
        self.removedConstraintRecords = removedConstraintRecords
        self.constraintEntitiesScheduledForRemoval =
            constraintEntitiesScheduledForRemoval
        self.effects = effects
    }

    fileprivate static func rejected(
        _ rejection: SourceCanonicalRemoverToolRejection
    ) -> Self {
        Self(
            accepted: false,
            rejection: rejection,
            ticket: nil,
            stagedEntities: [],
            removedConstraintRecords: [],
            constraintEntitiesScheduledForRemoval: [],
            effects: []
        )
    }
}

public struct SourceCanonicalRemoverFinalizeReport: Equatable, Sendable {
    public let markedForRemoval: [SourceCanonicalEntityIdentity]
    public let alreadyPendingRemoval: [SourceCanonicalEntityIdentity]
    public let staleOrRemoved: [SourceCanonicalEntityIdentity]

    public init(
        markedForRemoval: [SourceCanonicalEntityIdentity],
        alreadyPendingRemoval: [SourceCanonicalEntityIdentity],
        staleOrRemoved: [SourceCanonicalEntityIdentity]
    ) {
        self.markedForRemoval = markedForRemoval
        self.alreadyPendingRemoval = alreadyPendingRemoval
        self.staleOrRemoved = staleOrRemoved
    }

    public static let empty = SourceCanonicalRemoverFinalizeReport(
        markedForRemoval: [],
        alreadyPendingRemoval: [],
        staleOrRemoved: []
    )
}

/// Engine-owned lifecycle portion of the bundled Sandbox remover tool.
///
/// The surrounding stock SWEP remains responsible for its single trace,
/// `GM:CanTool` call, toolgun shoot effect, achievement SendLua, and the
/// one-second `timer.Simple`. This coordinator owns only authoritative Entity
/// and constraint mutation so CLIENT prediction cannot directly mirror state.
public final class SourceCanonicalRemoverToolCoordinator:
    @unchecked Sendable
{
    private let entityHost: any SourceCanonicalRemoverEntityHost
    private let constraintHost: any SourceCanonicalRemoverConstraintHost
    private let lock = NSLock()
    private var nextTicketRawValue: UInt64 = 1
    private var pendingByTicket: [
        SourceCanonicalRemoverTicket: [SourceCanonicalEntityIdentity]
    ] = [:]

    public init(
        entityHost: any SourceCanonicalRemoverEntityHost,
        constraintHost: any SourceCanonicalRemoverConstraintHost =
            SourceCanonicalEmptyRemoverConstraintHost()
    ) {
        self.entityHost = entityHost
        self.constraintHost = constraintHost
    }

    public var pendingTicketCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return pendingByTicket.count
    }

    /// SERVER authoritative half of the stock action. `canTool` must be the
    /// result of the original gamemode hook for this exact trace/button.
    @discardableResult
    public func perform(
        actor actorIdentity: SourceCanonicalEntityIdentity,
        target targetIdentity: SourceCanonicalEntityIdentity,
        action: SourceCanonicalRemoverToolAction,
        canTool: SourceCanonicalRemoverCanTool
    ) throws -> SourceCanonicalRemoverToolResult {
        guard let actor = liveSnapshot(actorIdentity), actor.kind == .player else {
            return .rejected(.actorIsNotLivePlayer)
        }
        guard let target = liveSnapshot(targetIdentity) else {
            return .rejected(.targetIsNotLive)
        }
        switch target.kind {
        case .world:
            return .rejected(.targetIsWorld)
        case .player:
            return .rejected(.targetIsPlayer)
        case .propPhysics, .physicsConstraint, .playerHands, .weapon:
            break
        }
        guard target.lifecycle != .pendingRemoval,
              target.lifecycle != .removed else {
            return .rejected(.targetIsPendingRemoval)
        }
        guard try canTool(SourceCanonicalRemoverCanToolRequest(
            actor: actor,
            target: target,
            action: action
        )) else {
            return .rejected(.canToolDenied)
        }

        if action == .reload {
            let removed = try constraintHost.removeAllConstraints(
                involving: target.identity
            )
            guard !removed.records.isEmpty ||
                    !removed.constraintEntities.isEmpty else {
                return .rejected(.noConstraints)
            }
            let scheduled = try scheduleConstraintEntities(
                removed.constraintEntities,
                excluding: []
            )
            return SourceCanonicalRemoverToolResult(
                accepted: true,
                rejection: nil,
                ticket: nil,
                stagedEntities: [],
                removedConstraintRecords: removed.records,
                constraintEntitiesScheduledForRemoval: scheduled,
                effects: []
            )
        }

        let selected: [SourceCanonicalEntityIdentity]
        if action == .rightClick {
            selected = constraintHost.allConstrainedEntities(
                startingAt: target.identity
            )
        } else {
            selected = [target.identity]
        }

        var staged: [SourceCanonicalEntitySnapshot] = []
        var seen: Set<SourceCanonicalEntityIdentity> = []
        for identity in selected.sorted(by: Self.identityOrder) {
            guard seen.insert(identity).inserted,
                  let snapshot = liveSnapshot(identity),
                  snapshot.kind != .world,
                  snapshot.kind != .player,
                  snapshot.lifecycle != .pendingRemoval,
                  snapshot.lifecycle != .removed else { continue }
            staged.append(try entityHost.updateCanonicalEntity(identity) {
                $0.isNotSolid = true
                $0.moveType = .none
                $0.isNoDraw = true
            })
        }
        guard !staged.isEmpty else {
            return .rejected(.targetIsNotLive)
        }

        var removedRecordsByID: [
            UInt64: SourceCanonicalConstraintRecord
        ] = [:]
        var constraintEntitySet: Set<SourceCanonicalEntityIdentity> = []
        for entity in staged {
            let removed = try constraintHost.removeAllConstraints(
                involving: entity.identity
            )
            for record in removed.records {
                removedRecordsByID[record.identifier] = record
            }
            constraintEntitySet.formUnion(removed.constraintEntities)
        }
        let stagedIdentities = staged.map(\.identity)
        let scheduledConstraints = try scheduleConstraintEntities(
            Array(constraintEntitySet),
            excluding: Set(stagedIdentities)
        )
        let ticket = try allocateTicket(for: stagedIdentities)
        return SourceCanonicalRemoverToolResult(
            accepted: true,
            rejection: nil,
            ticket: ticket,
            stagedEntities: stagedIdentities,
            removedConstraintRecords: removedRecordsByID.values.sorted {
                $0.identifier < $1.identifier
            },
            constraintEntitiesScheduledForRemoval: scheduledConstraints,
            effects: staged.map {
                SourceCanonicalRemoverEffect(
                    entity: $0.identity,
                    origin: $0.transform.origin
                )
            }
        )
    }

    /// Called by the stock one-second timer. Removing the ticket before any
    /// mutation makes retries idempotent. Every target is revalidated by its
    /// complete handle, so slot reuse is reported as stale and left untouched.
    @discardableResult
    public func finalize(
        _ ticket: SourceCanonicalRemoverTicket
    ) throws -> SourceCanonicalRemoverFinalizeReport {
        lock.lock()
        let identities = pendingByTicket.removeValue(forKey: ticket)
        lock.unlock()
        guard let identities else { return .empty }

        var marked: [SourceCanonicalEntityIdentity] = []
        var pending: [SourceCanonicalEntityIdentity] = []
        var stale: [SourceCanonicalEntityIdentity] = []
        for identity in identities.sorted(by: Self.identityOrder) {
            guard let snapshot = entityHost.canonicalSnapshot(for: identity) else {
                stale.append(identity)
                continue
            }
            switch snapshot.lifecycle {
            case .pendingRemoval:
                pending.append(identity)
            case .removed:
                stale.append(identity)
            case .created, .spawned, .active:
                _ = try entityHost.markCanonicalEntityForRemoval(identity)
                marked.append(identity)
            }
        }
        return SourceCanonicalRemoverFinalizeReport(
            markedForRemoval: marked,
            alreadyPendingRemoval: pending,
            staleOrRemoved: stale
        )
    }

    /// CLIENT prediction performs only the same validity/class rejection. It
    /// cannot enqueue a ticket or mutate a mirrored snapshot.
    public static func predictsAcceptance(
        target: SourceCanonicalEntitySnapshot?
    ) -> Bool {
        guard let target,
              target.lifecycle != .pendingRemoval,
              target.lifecycle != .removed else { return false }
        return target.kind != .world && target.kind != .player
    }

    private func liveSnapshot(
        _ identity: SourceCanonicalEntityIdentity
    ) -> SourceCanonicalEntitySnapshot? {
        guard let snapshot = entityHost.canonicalSnapshot(for: identity),
              snapshot.identity == identity,
              snapshot.lifecycle != .removed else { return nil }
        return snapshot
    }

    private func scheduleConstraintEntities(
        _ identities: [SourceCanonicalEntityIdentity],
        excluding excluded: Set<SourceCanonicalEntityIdentity>
    ) throws -> [SourceCanonicalEntityIdentity] {
        var scheduled: [SourceCanonicalEntityIdentity] = []
        for identity in Array(Set(identities)).sorted(by: Self.identityOrder)
            where !excluded.contains(identity)
        {
            guard let snapshot = liveSnapshot(identity),
                  snapshot.kind == .physicsConstraint else { continue }
            if snapshot.lifecycle != .pendingRemoval {
                _ = try entityHost.markCanonicalEntityForRemoval(identity)
                scheduled.append(identity)
            }
        }
        return scheduled
    }

    private func allocateTicket(
        for identities: [SourceCanonicalEntityIdentity]
    ) throws -> SourceCanonicalRemoverTicket {
        lock.lock()
        defer { lock.unlock() }
        guard nextTicketRawValue != UInt64.max else {
            throw SourceCanonicalRemoverToolInternalError.ticketSpaceExhausted
        }
        let ticket = SourceCanonicalRemoverTicket(
            rawValue: nextTicketRawValue
        )
        nextTicketRawValue += 1
        pendingByTicket[ticket] = identities
        return ticket
    }

    private static func identityOrder(
        _ lhs: SourceCanonicalEntityIdentity,
        _ rhs: SourceCanonicalEntityIdentity
    ) -> Bool {
        lhs.handle.rawValue < rhs.handle.rawValue
    }
}

public enum SourceCanonicalRemoverToolInternalError:
    Error,
    Equatable,
    Sendable
{
    case ticketSpaceExhausted
}
