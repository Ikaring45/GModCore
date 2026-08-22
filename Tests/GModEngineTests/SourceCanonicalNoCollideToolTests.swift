import Foundation
import XCTest
@testable import GModEngine
import GModLua

private final class NoCollidePhysicsHost:
    SourceCanonicalNoCollidePhysicsHost
{
    private var bodyIDs: Set<SourcePhysicsBodyID> = []

    func containsCanonicalNoCollidePhysicsBody(
        _ bodyID: SourcePhysicsBodyID
    ) -> Bool {
        bodyIDs.contains(bodyID)
    }

    @discardableResult
    func insert(
        _ entity: SourceCanonicalEntityIdentity,
        solidIndex: Int = 0
    ) throws -> SourcePhysicsBodyID {
        let bodyID = try SourcePhysicsBodyID(
            entityIdentity: entity,
            solidIndex: solidIndex
        )
        bodyIDs.insert(bodyID)
        return bodyID
    }

    func remove(_ bodyID: SourcePhysicsBodyID) {
        bodyIDs.remove(bodyID)
    }
}

private final class NoCollideLimitGate {
    var isAllowed = true
    var actors: [SourceCanonicalEntityIdentity] = []
}

private final class NoCollideHarness {
    let transport: GMLuaNetTransport
    let server: GMLuaRuntime
    let adapter: GMLuaSourceRuntimeAdapter
    let physics: NoCollidePhysicsHost
    let graph: SourceCanonicalConstraintGraph
    let limit: NoCollideLimitGate
    let coordinator: SourceCanonicalNoCollideToolCoordinator

    init(
        commandQueue: (any SourceCanonicalPhysicsConstraintCommandQueue)? = nil
    ) throws {
        let transport = GMLuaNetTransport()
        let server = GMLuaRuntime(
            realm: .server,
            logger: { _ in },
            netTransport: transport
        )
        let adapter = try GMLuaSourceRuntimeAdapter(
            serverRuntime: server,
            initialEntitySerialNumber: 500
        )
        let physics = NoCollidePhysicsHost()
        let graph = SourceCanonicalConstraintGraph()
        let limit = NoCollideLimitGate()
        self.transport = transport
        self.server = server
        self.adapter = adapter
        self.physics = physics
        self.graph = graph
        self.limit = limit
        let selectedQueue: any SourceCanonicalPhysicsConstraintCommandQueue
        if let commandQueue {
            selectedQueue = commandQueue
        } else {
            selectedQueue = transport
        }
        coordinator = SourceCanonicalNoCollideToolCoordinator(
            entityHost: adapter,
            physicsHost: physics,
            commandQueue: selectedQueue,
            constraintGraph: graph
        ) { [limit] actor in
            limit.actors.append(actor.identity)
            return limit.isAllowed
        }
    }

    func close() {
        try? adapter.close()
        _ = server.close()
    }

    func player(
        entryIndex: Int = 1,
        userID: Int = 7
    ) throws -> SourceCanonicalEntitySnapshot {
        try adapter.createCanonicalEntity(
            kind: .player,
            at: entryIndex,
            state: nil,
            playerUserID: userID
        )
    }

    func prop(
        entryIndex: Int,
        collisionGroup: Int32 =
            SourceCanonicalNoCollideCollisionGroup.none,
        installBody: Bool = true
    ) throws -> SourceCanonicalEntitySnapshot {
        var state = SourceCanonicalEntityState.defaults(for: .propPhysics)
        state.collisionGroup = collisionGroup
        let prop = try adapter.createCanonicalEntity(
            kind: .propPhysics,
            at: entryIndex,
            state: state,
            playerUserID: nil
        )
        if installBody {
            _ = try physics.insert(prop.identity)
        }
        return prop
    }

    func left(
        actor: SourceCanonicalEntityIdentity,
        target: SourceCanonicalEntityIdentity,
        bone: Int = 0,
        canTool: SourceCanonicalNoCollideCanTool = { _ in true }
    ) throws -> SourceCanonicalNoCollideToolResult {
        try coordinator.perform(
            actor: actor,
            action: .leftClick,
            trace: SourceCanonicalNoCollideToolTrace(
                target: target,
                hitPosition: SourceVector3(1, 2, 3),
                hitNormal: SourceVector3(0, 0, 1),
                physicsBone: bone
            ),
            canTool: canTool
        )
    }
}

private final class NoCollideMismatchedQueue:
    SourceCanonicalPhysicsConstraintCommandQueue
{
    var received: [[SourceCanonicalQueuedPhysicsConstraintCommand]] = []
    var rollbackCalls: [[SourcePhysicsCommand]] = []

    func enqueueCanonicalPhysicsConstraintCommands(
        _ commands: [SourceCanonicalQueuedPhysicsConstraintCommand]
    ) throws -> [SourcePhysicsCommand] {
        received.append(commands)
        return []
    }

    func rollbackCanonicalPhysicsConstraintCommands(
        _ commands: [SourcePhysicsCommand]
    ) {
        rollbackCalls.append(commands)
    }
}

final class SourceCanonicalNoCollideToolTests: XCTestCase {
    func testTwoClickCreateUsesFullBodiesGlobalFIFOUndoAndCleanup()
        throws
    {
        let harness = try NoCollideHarness()
        defer { harness.close() }
        let player = try harness.player()
        let first = try harness.prop(entryIndex: 20)
        let second = try harness.prop(entryIndex: 21)
        let firstBodyID = try SourcePhysicsBodyID(
            entityIdentity: first.identity,
            solidIndex: 0
        )
        let secondBodyID = try SourcePhysicsBodyID(
            entityIdentity: second.identity,
            solidIndex: 0
        )

        var canToolRequests: [SourceCanonicalNoCollideCanToolRequest] = []
        let selected = try harness.left(
            actor: player.identity,
            target: first.identity
        ) {
            canToolRequests.append($0)
            return true
        }
        guard case let .selected(endpoint) = selected else {
            return XCTFail("first click did not retain a physics endpoint")
        }
        XCTAssertTrue(selected.accepted)
        XCTAssertEqual(endpoint.entity, first.identity)
        XCTAssertEqual(endpoint.bodyID, firstBodyID)
        XCTAssertEqual(
            harness.coordinator.selection(for: player.identity),
            endpoint
        )

        let completed = try harness.left(
            actor: player.identity,
            target: second.identity
        ) {
            canToolRequests.append($0)
            return true
        }
        guard case let .created(created) = completed else {
            return XCTFail("second click did not create NoCollide")
        }
        XCTAssertTrue(completed.accepted)
        XCTAssertNil(harness.coordinator.selection(for: player.identity))
        XCTAssertEqual(created.binding.first.bodyID, firstBodyID)
        XCTAssertEqual(created.binding.second.bodyID, secondBodyID)
        XCTAssertEqual(
            created.binding.creationCommand.firstBodyID,
            firstBodyID
        )
        XCTAssertEqual(
            created.binding.creationCommand.secondBodyID,
            secondBodyID
        )
        XCTAssertTrue(created.binding.disableOnRemove)
        XCTAssertEqual(created.constraintEntity.kind, .physicsConstraint)
        XCTAssertEqual(created.constraintEntity.lifecycle, .active)
        XCTAssertEqual(created.countCategory, "constraints")
        XCTAssertEqual(created.cleanupCategory, "nocollide")
        XCTAssertEqual(created.undo.name, "NoCollide")
        XCTAssertEqual(
            created.undo.customUndoText,
            "Undone #tool.nocollide.name"
        )
        XCTAssertEqual(
            harness.coordinator.cleanupConstraints(for: player.identity),
            [created.constraintEntity.identity]
        )
        XCTAssertEqual(harness.limit.actors, [player.identity])
        XCTAssertEqual(canToolRequests.count, 2)
        XCTAssertTrue(canToolRequests.allSatisfy {
            $0.mode == "nocollide" && $0.action == .leftClick
        })

        let pending = harness.transport
            .preparePendingCanonicalPhysicsBodyCommands()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending[0].sequence, created.binding.creationSequence)
        XCTAssertEqual(
            pending[0].payload,
            .createNoCollideConstraint(created.binding.creationCommand)
        )
        XCTAssertEqual(
            harness.graph.records,
            [created.binding.graphRecord]
        )
    }

    func testRightClickMutatesCanonicalCollisionGroupAndReloadDeletesOnlyNoCollide()
        throws
    {
        let harness = try NoCollideHarness()
        defer { harness.close() }
        let player = try harness.player()
        let first = try harness.prop(entryIndex: 20)
        let second = try harness.prop(entryIndex: 21)
        let third = try harness.prop(entryIndex: 22)

        let unrelated = try harness.graph.insert(entities: [
            first.identity,
            third.identity,
        ])
        _ = try harness.left(actor: player.identity, target: first.identity)
        let creation = try harness.left(
            actor: player.identity,
            target: second.identity
        )
        guard case let .created(created) = creation else {
            return XCTFail("NoCollide creation failed")
        }

        var rightRequest: SourceCanonicalNoCollideCanToolRequest?
        let worldGroup = try harness.coordinator.perform(
            actor: player.identity,
            action: .rightClick,
            trace: SourceCanonicalNoCollideToolTrace(
                target: first.identity
            )
        ) {
            rightRequest = $0
            return true
        }
        guard case let .collisionGroupChanged(worldSnapshot) = worldGroup else {
            return XCTFail("right click did not update collision group")
        }
        XCTAssertEqual(
            worldSnapshot.collisionGroup,
            SourceCanonicalNoCollideCollisionGroup.world
        )
        XCTAssertEqual(
            harness.adapter.canonicalSnapshot(for: first.identity)?
                .collisionGroup,
            SourceCanonicalNoCollideCollisionGroup.world
        )
        XCTAssertEqual(rightRequest?.mode, "nocollide")
        XCTAssertEqual(rightRequest?.action, .rightClick)

        let noneGroup = try harness.coordinator.perform(
            actor: player.identity,
            action: .rightClick,
            trace: SourceCanonicalNoCollideToolTrace(
                target: first.identity
            ),
            canTool: { _ in true }
        )
        guard case let .collisionGroupChanged(noneSnapshot) = noneGroup else {
            return XCTFail("second right click did not update collision group")
        }
        XCTAssertEqual(
            noneSnapshot.collisionGroup,
            SourceCanonicalNoCollideCollisionGroup.none
        )

        let reloaded = try harness.coordinator.perform(
            actor: player.identity,
            action: .reload,
            trace: SourceCanonicalNoCollideToolTrace(
                target: first.identity
            ),
            canTool: { request in
                XCTAssertEqual(request.action, .reload)
                return true
            }
        )
        guard case let .constraintsRemoved(removal) = reloaded else {
            return XCTFail("reload did not remove NoCollide")
        }
        XCTAssertEqual(removal.bindings, [created.binding])
        XCTAssertEqual(
            removal.constraintEntitiesMarkedForRemoval,
            [created.constraintEntity.identity]
        )
        XCTAssertEqual(removal.deletionCommands.count, 1)
        XCTAssertEqual(
            removal.deletionCommands[0].payload,
            .deleteConstraint(SourcePhysicsConstraintDeletionCommand(
                constraintID: created.binding.constraintID
            ))
        )
        XCTAssertEqual(
            harness.adapter.canonicalSnapshot(
                for: created.constraintEntity.identity
            )?.lifecycle,
            .pendingRemoval
        )
        XCTAssertEqual(harness.coordinator.bindings, [])
        XCTAssertEqual(
            harness.coordinator.cleanupConstraints(for: player.identity),
            []
        )
        XCTAssertFalse(try XCTUnwrap(
            harness.coordinator.undoRecords.first
        ).isLive)
        XCTAssertEqual(harness.graph.records, [unrelated])

        let none = try harness.coordinator.perform(
            actor: player.identity,
            action: .reload,
            trace: SourceCanonicalNoCollideToolTrace(
                target: first.identity
            ),
            canTool: { _ in true }
        )
        XCTAssertEqual(none, .rejected(.noNoCollideConstraints))
        XCTAssertFalse(none.accepted)
    }

    func testDuplicateLimitDeniedAndHolsterFollowStockTwoStageRules()
        throws
    {
        let harness = try NoCollideHarness()
        defer { harness.close() }
        let player = try harness.player()
        let first = try harness.prop(entryIndex: 20)
        let second = try harness.prop(entryIndex: 21)
        let third = try harness.prop(entryIndex: 22)

        let denied = try harness.left(
            actor: player.identity,
            target: first.identity,
            canTool: { _ in false }
        )
        XCTAssertEqual(denied, .rejected(.canToolDenied))
        XCTAssertNil(harness.coordinator.selection(for: player.identity))

        _ = try harness.left(actor: player.identity, target: first.identity)
        harness.coordinator.holster(player: player.identity)
        XCTAssertNil(harness.coordinator.selection(for: player.identity))

        _ = try harness.left(actor: player.identity, target: first.identity)
        _ = try harness.left(actor: player.identity, target: second.identity)
        _ = try harness.left(actor: player.identity, target: second.identity)
        let duplicate = try harness.left(
            actor: player.identity,
            target: first.identity
        )
        XCTAssertEqual(
            duplicate,
            .handledWithoutConstraint(.pairAlreadyConstrained)
        )
        XCTAssertTrue(duplicate.accepted)
        XCTAssertNil(harness.coordinator.selection(for: player.identity))
        XCTAssertEqual(harness.coordinator.bindings.count, 1)

        _ = try harness.left(actor: player.identity, target: first.identity)
        let identical = try harness.left(
            actor: player.identity,
            target: first.identity
        )
        XCTAssertEqual(
            identical,
            .handledWithoutConstraint(.identicalPhysicsObjects)
        )
        XCTAssertTrue(identical.accepted)

        harness.limit.isAllowed = false
        _ = try harness.left(actor: player.identity, target: first.identity)
        let limited = try harness.left(
            actor: player.identity,
            target: third.identity
        )
        XCTAssertEqual(limited, .rejected(.constraintLimitReached))
        XCTAssertNil(harness.coordinator.selection(for: player.identity))
        XCTAssertEqual(harness.coordinator.bindings.count, 1)
    }

    func testStaleFirstFullHandleCannotConstrainReplacementInReusedSlot()
        throws
    {
        let harness = try NoCollideHarness()
        defer { harness.close() }
        let player = try harness.player()
        let first = try harness.prop(entryIndex: 20)
        let second = try harness.prop(entryIndex: 21)
        let firstBodyID = try SourcePhysicsBodyID(
            entityIdentity: first.identity,
            solidIndex: 0
        )

        _ = try harness.left(actor: player.identity, target: first.identity)
        _ = try harness.adapter.markCanonicalEntityForRemoval(first.identity)
        XCTAssertEqual(
            try harness.adapter.runServerFixedTick().removedEntities,
            [first.identity]
        )
        harness.physics.remove(firstBodyID)
        let replacement = try harness.prop(entryIndex: 20)
        XCTAssertNotEqual(replacement.identity, first.identity)

        let result = try harness.left(
            actor: player.identity,
            target: second.identity
        )
        XCTAssertEqual(
            result,
            .handledWithoutConstraint(.firstSelectionBecameStale)
        )
        XCTAssertNil(harness.coordinator.selection(for: player.identity))
        XCTAssertEqual(harness.coordinator.bindings, [])
        XCTAssertEqual(
            harness.adapter.canonicalSnapshot(for: replacement.identity),
            replacement
        )
        XCTAssertEqual(
            harness.transport.preparePendingCanonicalPhysicsBodyCommands(),
            []
        )
    }

    func testUndoThenCleanupDeleteExactBindingsInFIFOOrder() throws {
        let harness = try NoCollideHarness()
        defer { harness.close() }
        let player = try harness.player()
        let first = try harness.prop(entryIndex: 20)
        let second = try harness.prop(entryIndex: 21)
        let third = try harness.prop(entryIndex: 22)

        _ = try harness.left(actor: player.identity, target: first.identity)
        let firstResult = try harness.left(
            actor: player.identity,
            target: second.identity
        )
        _ = try harness.left(actor: player.identity, target: first.identity)
        let secondResult = try harness.left(
            actor: player.identity,
            target: third.identity
        )
        guard case let .created(firstCreation) = firstResult,
              case let .created(secondCreation) = secondResult else {
            return XCTFail("fixture constraints were not created")
        }

        let undone = try harness.coordinator.undoLatest(
            for: player.identity
        )
        XCTAssertEqual(undone.bindings, [secondCreation.binding])
        XCTAssertEqual(
            harness.coordinator.cleanupConstraints(for: player.identity),
            [firstCreation.constraintEntity.identity]
        )
        let cleaned = try harness.coordinator.removeCleanupConstraints(
            for: player.identity
        )
        XCTAssertEqual(cleaned.bindings, [firstCreation.binding])
        XCTAssertEqual(harness.coordinator.bindings, [])
        XCTAssertTrue(harness.coordinator.undoRecords.allSatisfy {
            !$0.isLive
        })

        let commands = harness.transport
            .preparePendingCanonicalPhysicsBodyCommands()
        XCTAssertEqual(commands.count, 4)
        XCTAssertEqual(commands.map(\.sequence), commands.map(\.sequence).sorted())
        XCTAssertEqual(
            commands.map(\.payload),
            [
                .createNoCollideConstraint(
                    firstCreation.binding.creationCommand
                ),
                .createNoCollideConstraint(
                    secondCreation.binding.creationCommand
                ),
                .deleteConstraint(SourcePhysicsConstraintDeletionCommand(
                    constraintID: secondCreation.binding.constraintID
                )),
                .deleteConstraint(SourcePhysicsConstraintDeletionCommand(
                    constraintID: firstCreation.binding.constraintID
                )),
            ]
        )
    }

    func testMismatchedBackendResponseRollsBackEntityAndGraph() throws {
        let queue = NoCollideMismatchedQueue()
        let harness = try NoCollideHarness(commandQueue: queue)
        defer { harness.close() }
        let player = try harness.player()
        let first = try harness.prop(entryIndex: 20)
        let second = try harness.prop(entryIndex: 21)

        _ = try harness.left(actor: player.identity, target: first.identity)
        XCTAssertThrowsError(try harness.left(
            actor: player.identity,
            target: second.identity
        )) {
            XCTAssertEqual(
                $0 as? SourceCanonicalNoCollideToolError,
                .physicsFIFOResultCount(expected: 1, actual: 0)
            )
        }
        XCTAssertEqual(queue.received.count, 1)
        XCTAssertEqual(queue.rollbackCalls, [])
        XCTAssertEqual(harness.graph.records, [])
        XCTAssertEqual(harness.coordinator.bindings, [])
        XCTAssertFalse(harness.adapter.canonicalEntitySnapshots.contains {
            $0.kind == .physicsConstraint
        })
    }
}
