import Foundation
import XCTest
@testable import GModEngine
import GModLua

private final class RemoverConstraintHost:
    SourceCanonicalRemoverConstraintHost,
    @unchecked Sendable
{
    private struct Binding {
        let record: SourceCanonicalConstraintRecord
        let constraintEntity: SourceCanonicalEntityIdentity
    }

    private let lock = NSLock()
    private var bindingsByID: [UInt64: Binding] = [:]

    func install(
        record: SourceCanonicalConstraintRecord,
        constraintEntity: SourceCanonicalEntityIdentity
    ) {
        lock.lock()
        bindingsByID[record.identifier] = Binding(
            record: record,
            constraintEntity: constraintEntity
        )
        lock.unlock()
    }

    func allConstrainedEntities(
        startingAt entity: SourceCanonicalEntityIdentity
    ) -> [SourceCanonicalEntityIdentity] {
        lock.lock()
        let records = bindingsByID.values.map(\.record)
        lock.unlock()
        var visited: Set<SourceCanonicalEntityIdentity> = [entity]
        var queue = [entity]
        var cursor = 0
        while cursor < queue.count {
            let current = queue[cursor]
            cursor += 1
            for record in records where record.entities.contains(current) {
                for linked in record.entities
                    where visited.insert(linked).inserted
                {
                    queue.append(linked)
                }
            }
        }
        return visited.sorted {
            $0.handle.rawValue < $1.handle.rawValue
        }
    }

    func removeAllConstraints(
        involving entity: SourceCanonicalEntityIdentity
    ) throws -> SourceCanonicalRemoverConstraintRemoval {
        lock.lock()
        let identifiers = bindingsByID.values
            .filter { $0.record.entities.contains(entity) }
            .map { $0.record.identifier }
            .sorted()
        let removed = identifiers.compactMap {
            bindingsByID.removeValue(forKey: $0)
        }
        lock.unlock()
        return SourceCanonicalRemoverConstraintRemoval(
            records: removed.map(\.record),
            constraintEntities: removed.map(\.constraintEntity)
        )
    }
}

final class SourceCanonicalRemoverToolTests: XCTestCase {
    func testAuthoritativeRemoverRejectsDeniedTargetsAndUsesDeferredFullHandles()
        throws
    {
        let transport = GMLuaNetTransport()
        let server = GMLuaRuntime(
            realm: .server,
            logger: { _ in },
            netTransport: transport
        )
        let client = GMLuaRuntime(
            realm: .client,
            logger: { _ in },
            netTransport: transport
        )
        let adapter = try GMLuaSourceRuntimeAdapter(
            serverRuntime: server,
            initialEntitySerialNumber: 80
        )
        let session = GMLuaSharedSession(netTransport: transport)
        defer {
            try? session.disconnect(client: client)
            try? adapter.close()
            _ = client.close()
            _ = server.close()
        }

        let world = try adapter.createCanonicalEntity(
            kind: .world,
            at: 0,
            state: nil,
            playerUserID: nil
        )
        let player = try adapter.createCanonicalEntity(
            kind: .player,
            at: 1,
            state: nil,
            playerUserID: 37
        )
        var firstState = SourceCanonicalEntityState.defaults(for: .propPhysics)
        firstState.transform.origin = SourceVector3(128, 16, 48)
        let first = try adapter.createCanonicalEntity(
            kind: .propPhysics,
            at: 20,
            state: firstState,
            playerUserID: nil
        )
        let second = try adapter.createCanonicalEntity(
            kind: .propPhysics,
            at: 21,
            state: nil,
            playerUserID: nil
        )
        let constraint = try adapter.createCanonicalEntity(
            kind: .physicsConstraint,
            at: 22,
            state: nil,
            playerUserID: nil
        )
        _ = try adapter.discardPendingCanonicalEntityOperations()
        try session.connectCanonical(
            server: server,
            client: client,
            playerIdentity: player.identity,
            userID: 37,
            authoritativeSnapshots: adapter.canonicalEntitySnapshots
        )
        XCTAssertEqual(try session.pump(), 1)

        let constraints = RemoverConstraintHost()
        let record = SourceCanonicalConstraintRecord(
            identifier: 400,
            entities: [first.identity, second.identity]
        )
        constraints.install(
            record: record,
            constraintEntity: constraint.identity
        )
        let remover = SourceCanonicalRemoverToolCoordinator(
            entityHost: adapter,
            constraintHost: constraints
        )

        var canToolCallCount = 0
        let denied = try remover.perform(
            actor: player.identity,
            target: first.identity,
            action: .leftClick
        ) { request in
            canToolCallCount += 1
            XCTAssertEqual(request.mode, "remover")
            XCTAssertEqual(request.action.rawValue, 1)
            XCTAssertEqual(request.actor.identity, player.identity)
            XCTAssertEqual(request.target.identity, first.identity)
            return false
        }
        XCTAssertEqual(denied.rejection, .canToolDenied)
        XCTAssertEqual(canToolCallCount, 1)
        XCTAssertEqual(
            adapter.canonicalSnapshot(for: first.identity)?.revision,
            first.revision
        )
        XCTAssertEqual(adapter.pendingCanonicalEntityOperationCount, 0)

        let worldResult = try remover.perform(
            actor: player.identity,
            target: world.identity,
            action: .leftClick,
            canTool: { _ in XCTFail("world reached CanTool"); return true }
        )
        XCTAssertEqual(worldResult.rejection, .targetIsWorld)
        let playerResult = try remover.perform(
            actor: player.identity,
            target: player.identity,
            action: .leftClick,
            canTool: { _ in XCTFail("player reached CanTool"); return true }
        )
        XCTAssertEqual(playerResult.rejection, .targetIsPlayer)

        let accepted = try remover.perform(
            actor: player.identity,
            target: first.identity,
            action: .leftClick,
            canTool: { _ in true }
        )
        XCTAssertTrue(accepted.accepted)
        XCTAssertEqual(accepted.stagedEntities, [first.identity])
        XCTAssertEqual(accepted.removedConstraintRecords, [record])
        XCTAssertEqual(
            accepted.constraintEntitiesScheduledForRemoval,
            [constraint.identity]
        )
        XCTAssertEqual(
            accepted.effects,
            [SourceCanonicalRemoverEffect(
                entity: first.identity,
                origin: firstState.transform.origin
            )]
        )
        let ticket = try XCTUnwrap(accepted.ticket)
        let staged = try XCTUnwrap(
            adapter.canonicalSnapshot(for: first.identity)
        )
        XCTAssertTrue(staged.isNotSolid)
        XCTAssertTrue(staged.isNoDraw)
        XCTAssertEqual(staged.moveType, .none)
        XCTAssertEqual(staged.lifecycle, .created)
        XCTAssertEqual(
            adapter.canonicalSnapshot(for: constraint.identity)?.lifecycle,
            .pendingRemoval
        )

        try publishPending(from: adapter, through: session)
        let clientStaged = try XCTUnwrap(
            client.entityRegistry?.canonicalSnapshot(
                at: first.identity.entryIndex
            )
        )
        XCTAssertEqual(clientStaged.identity, first.identity)
        XCTAssertTrue(clientStaged.isNotSolid)
        XCTAssertTrue(clientStaged.isNoDraw)
        XCTAssertEqual(clientStaged.moveType, .none)
        XCTAssertTrue(
            SourceCanonicalRemoverToolCoordinator.predictsAcceptance(
                target: clientStaged
            )
        )

        let constraintCleanup = try adapter.runServerFixedTick()
        XCTAssertEqual(
            constraintCleanup.removedEntities,
            [constraint.identity]
        )
        try publishPending(from: adapter, through: session)
        XCTAssertNil(client.entityRegistry?.canonicalSnapshot(
            at: constraint.identity.entryIndex
        ))
        XCTAssertNotNil(client.entityRegistry?.canonicalSnapshot(
            at: first.identity.entryIndex
        ))

        let finalized = try remover.finalize(ticket)
        XCTAssertEqual(finalized.markedForRemoval, [first.identity])
        XCTAssertEqual(remover.pendingTicketCount, 0)
        XCTAssertEqual(try remover.finalize(ticket), .empty)
        XCTAssertFalse(
            SourceCanonicalRemoverToolCoordinator.predictsAcceptance(
                target: adapter.canonicalSnapshot(for: first.identity)
            )
        )
        let targetCleanup = try adapter.runServerFixedTick()
        XCTAssertEqual(targetCleanup.removedEntities, [first.identity])
        try publishPending(from: adapter, through: session)
        XCTAssertNil(client.entityRegistry?.canonicalSnapshot(
            at: first.identity.entryIndex
        ))

        // The timer stores the complete old handle. If another cleanup path
        // removes that entity and its slot is reused before the callback, the
        // replacement must survive unchanged.
        let staleAction = try remover.perform(
            actor: player.identity,
            target: second.identity,
            action: .leftClick,
            canTool: { _ in true }
        )
        let staleTicket = try XCTUnwrap(staleAction.ticket)
        _ = try adapter.markCanonicalEntityForRemoval(second.identity)
        XCTAssertEqual(
            try adapter.runServerFixedTick().removedEntities,
            [second.identity]
        )
        let replacement = try adapter.createCanonicalEntity(
            kind: .propPhysics,
            at: second.identity.entryIndex,
            state: nil,
            playerUserID: nil
        )
        XCTAssertNotEqual(replacement.identity.handle, second.identity.handle)
        let staleFinalize = try remover.finalize(staleTicket)
        XCTAssertEqual(staleFinalize.staleOrRemoved, [second.identity])
        XCTAssertEqual(
            adapter.canonicalSnapshot(for: replacement.identity),
            replacement
        )

        let reloadConstraint = try adapter.createCanonicalEntity(
            kind: .physicsConstraint,
            at: 23,
            state: nil,
            playerUserID: nil
        )
        let reloadRecord = SourceCanonicalConstraintRecord(
            identifier: 401,
            entities: [replacement.identity, player.identity]
        )
        constraints.install(
            record: reloadRecord,
            constraintEntity: reloadConstraint.identity
        )
        let reload = try remover.perform(
            actor: player.identity,
            target: replacement.identity,
            action: .reload,
            canTool: { _ in true }
        )
        XCTAssertTrue(reload.accepted)
        XCTAssertNil(reload.ticket)
        XCTAssertEqual(reload.removedConstraintRecords, [reloadRecord])
        XCTAssertEqual(
            reload.constraintEntitiesScheduledForRemoval,
            [reloadConstraint.identity]
        )
        XCTAssertEqual(
            adapter.canonicalSnapshot(for: replacement.identity),
            replacement,
            "reload removes constraints without hiding its target"
        )

        let noConstraints = try remover.perform(
            actor: player.identity,
            target: replacement.identity,
            action: .reload,
            canTool: { _ in true }
        )
        XCTAssertEqual(noConstraints.rejection, .noConstraints)
        XCTAssertEqual(
            adapter.canonicalSnapshot(for: replacement.identity),
            replacement
        )

        let rightTarget = try adapter.createCanonicalEntity(
            kind: .propPhysics,
            at: 24,
            state: nil,
            playerUserID: nil
        )
        let rightConstraint = try adapter.createCanonicalEntity(
            kind: .physicsConstraint,
            at: 25,
            state: nil,
            playerUserID: nil
        )
        let rightRecord = SourceCanonicalConstraintRecord(
            identifier: 402,
            entities: [replacement.identity, rightTarget.identity]
        )
        constraints.install(
            record: rightRecord,
            constraintEntity: rightConstraint.identity
        )
        let right = try remover.perform(
            actor: player.identity,
            target: replacement.identity,
            action: .rightClick,
            canTool: { request in
                XCTAssertEqual(request.action.rawValue, 2)
                return true
            }
        )
        let rightIdentities = [replacement.identity, rightTarget.identity]
            .sorted { $0.handle.rawValue < $1.handle.rawValue }
        XCTAssertEqual(right.stagedEntities, rightIdentities)
        XCTAssertEqual(right.removedConstraintRecords, [rightRecord])
        XCTAssertEqual(
            right.constraintEntitiesScheduledForRemoval,
            [rightConstraint.identity]
        )
        let rightTicket = try XCTUnwrap(right.ticket)
        XCTAssertEqual(
            try remover.finalize(rightTicket).markedForRemoval,
            rightIdentities
        )
    }

    private func publishPending(
        from adapter: GMLuaSourceRuntimeAdapter,
        through session: GMLuaSharedSession
    ) throws {
        _ = try adapter.publishPendingCanonicalEntityOperations {
            try session.publishCanonicalEntityUpdates($0)
        }
        _ = try session.pump()
    }
}
