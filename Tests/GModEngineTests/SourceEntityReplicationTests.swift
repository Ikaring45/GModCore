import XCTest
@testable import GModEngine

final class SourceEntityReplicationTests: XCTestCase {
    private let generation1 = SourceEntityReplicationConnectionGeneration(rawValue: 1)
    private let generation2 = SourceEntityReplicationConnectionGeneration(rawValue: 2)

    func testServerStreamRequiresOneSnapshotThenStampsOrderedDeltas() throws {
        var stream = try SourceEntityReplicationServerStream(
            connectionGeneration: generation1
        )

        XCTAssertThrowsError(try stream.makeDelta([])) { error in
            XCTAssertEqual(error as? SourceEntityReplicationStreamError, .snapshotRequired)
        }

        let snapshot = try stream.makeSnapshot([])
        let firstDelta = try stream.makeDelta([])
        let secondDelta = try stream.makeDelta([])

        XCTAssertEqual(snapshot.sequence, 1)
        XCTAssertEqual(snapshot.payload, .snapshot([]))
        XCTAssertEqual(firstDelta.sequence, 2)
        XCTAssertEqual(firstDelta.payload, .delta([]))
        XCTAssertEqual(secondDelta.sequence, 3)
        XCTAssertEqual(stream.nextSequence, 4)
        XCTAssertThrowsError(try stream.makeSnapshot([])) { error in
            XCTAssertEqual(
                error as? SourceEntityReplicationStreamError,
                .snapshotAlreadySent
            )
        }
    }

    func testClientRejectsMissingDuplicateStaleAndOutOfOrderSequences() {
        var client = SourceEntityReplicationClientState()
        XCTAssertTrue(client.connect(generation: generation1))

        XCTAssertEqual(
            client.apply(packet(sequence: 0, payload: .snapshot([]))),
            .rejected(.invalidSequence)
        )
        XCTAssertEqual(
            client.apply(packet(sequence: 1, payload: .delta([]))),
            .rejected(.initialPacketMustBeSnapshot)
        )
        XCTAssertEqual(client.lastAppliedSequence, 0)

        XCTAssertEqual(
            client.apply(packet(sequence: 2, payload: .snapshot([]))),
            .rejected(.outOfOrderSequence(expected: 1, received: 2))
        )

        XCTAssertEqual(
            client.apply(packet(sequence: 1, payload: .snapshot([]))),
            .applied(
                SourceEntityReplicationClientSnapshot(
                    connectionGeneration: generation1,
                    sequence: 1,
                    entities: []
                )
            )
        )
        XCTAssertEqual(
            client.apply(packet(sequence: 1, payload: .snapshot([]))),
            .rejected(.duplicateSequence(1))
        )
        XCTAssertEqual(
            client.apply(packet(sequence: 3, payload: .delta([]))),
            .rejected(.outOfOrderSequence(expected: 2, received: 3))
        )

        _ = client.apply(packet(sequence: 2, payload: .delta([])))
        XCTAssertEqual(
            client.apply(packet(sequence: 1, payload: .snapshot([]))),
            .rejected(.staleSequence(lastApplied: 2, received: 1))
        )
        XCTAssertEqual(
            client.apply(packet(sequence: 3, payload: .snapshot([]))),
            .rejected(.unexpectedSnapshot)
        )
        XCTAssertEqual(client.lastAppliedSequence, 2)
        XCTAssertEqual(
            client.apply(packet(sequence: 3, payload: .delta([]))),
            .applied(
                SourceEntityReplicationClientSnapshot(
                    connectionGeneration: generation1,
                    sequence: 3,
                    entities: []
                )
            )
        )
    }

    func testPerKindCursorIgnoresPlayerOnlyPacketsAndTracksPropRemoval() {
        var client = SourceEntityReplicationClientState()
        XCTAssertTrue(client.connect(generation: generation1))
        let emptyPropCursor = client.cursor(for: .propPhysics)
        XCTAssertEqual(emptyPropCursor?.sequence, 0)

        let player = SourceCanonicalEntitySnapshot(
            identity: SourceCanonicalEntityIdentity(handle: SourceBaseHandle(
                entryIndex: 1,
                serialNumber: 1
            )),
            kind: .player,
            className: SourceCanonicalEntityKind.player.className,
            transform: .identity,
            motion: SourceEntityMotionState(),
            model: nil,
            solidType: .boundingBox,
            moveType: .walk,
            lifecycle: .active,
            isNetworkable: true,
            revision: 1
        )
        _ = client.apply(packet(sequence: 1, payload: .snapshot([player])))
        XCTAssertEqual(client.cursor(for: .player)?.sequence, 1)
        XCTAssertEqual(client.cursor(for: .propPhysics), emptyPropCursor)

        let prop = entity(entryIndex: 2, serialNumber: 4, revision: 0)
        _ = client.apply(packet(sequence: 2, payload: .delta([.create(prop)])))
        XCTAssertEqual(client.cursor(for: .propPhysics)?.sequence, 2)

        let movedPlayer = SourceCanonicalEntitySnapshot(
            identity: player.identity,
            kind: player.kind,
            className: player.className,
            transform: SourceEntityTransform(origin: SourceVector3(1, 0, 0)),
            motion: player.motion,
            model: player.model,
            solidType: player.solidType,
            moveType: player.moveType,
            lifecycle: player.lifecycle,
            isNetworkable: player.isNetworkable,
            revision: 2
        )
        _ = client.apply(packet(
            sequence: 3,
            payload: .delta([.update(movedPlayer)])
        ))
        XCTAssertEqual(client.cursor(for: .player)?.sequence, 3)
        XCTAssertEqual(client.cursor(for: .propPhysics)?.sequence, 2)

        let removed = entity(
            entryIndex: 2,
            serialNumber: 4,
            revision: 1,
            lifecycle: .removed
        )
        _ = client.apply(packet(sequence: 4, payload: .delta([.remove(removed)])))
        XCTAssertEqual(client.cursor(for: .propPhysics)?.sequence, 4)
    }

    func testDisconnectReconnectRejectsOldConnectionGeneration() {
        var client = SourceEntityReplicationClientState()
        XCTAssertTrue(client.connect(generation: generation1))
        _ = client.apply(packet(sequence: 1, payload: .snapshot([])))
        let oldImmutableSnapshot = client.snapshot

        client.disconnect()
        XCTAssertNil(client.snapshot)
        XCTAssertEqual(
            client.apply(packet(sequence: 2, payload: .delta([]))),
            .rejected(.noActiveConnection)
        )
        XCTAssertFalse(client.connect(generation: generation1))
        XCTAssertTrue(client.connect(generation: generation2))

        XCTAssertEqual(
            client.apply(packet(sequence: 2, payload: .delta([]), generation: generation1)),
            .rejected(
                .connectionGenerationMismatch(
                    expected: generation2,
                    received: generation1
                )
            )
        )
        XCTAssertEqual(client.lastAppliedSequence, 0)
        XCTAssertEqual(
            client.apply(packet(sequence: 1, payload: .snapshot([]), generation: generation2)),
            .applied(
                SourceEntityReplicationClientSnapshot(
                    connectionGeneration: generation2,
                    sequence: 1,
                    entities: []
                )
            )
        )
        XCTAssertEqual(oldImmutableSnapshot?.connectionGeneration, generation1)
        XCTAssertEqual(oldImmutableSnapshot?.sequence, 1)
    }

    func testCreateUpdateRemoveApplyInOperationOrderWithFullHandles() {
        let first = entity(entryIndex: 7, serialNumber: 3, revision: 0, originX: 10)
        let second = entity(entryIndex: 8, serialNumber: 1, revision: 0, originX: 20)
        let firstUpdated = entity(
            entryIndex: 7,
            serialNumber: 3,
            revision: 1,
            originX: 30
        )
        let firstRemoved = entity(
            entryIndex: 7,
            serialNumber: 3,
            revision: 2,
            lifecycle: .removed,
            originX: 30
        )

        var client = SourceEntityReplicationClientState()
        XCTAssertTrue(client.connect(generation: generation1))
        _ = client.apply(packet(sequence: 1, payload: .snapshot([first])))

        XCTAssertEqual(
            client.apply(
                packet(
                    sequence: 2,
                    payload: .delta([.update(firstUpdated), .create(second)])
                )
            ),
            .applied(
                SourceEntityReplicationClientSnapshot(
                    connectionGeneration: generation1,
                    sequence: 2,
                    entities: [firstUpdated, second]
                )
            )
        )
        XCTAssertEqual(
            client.apply(
                packet(sequence: 3, payload: .delta([.remove(firstRemoved)]))
            ),
            .applied(
                SourceEntityReplicationClientSnapshot(
                    connectionGeneration: generation1,
                    sequence: 3,
                    entities: [second]
                )
            )
        )
    }

    func testFailedDeltaRollsBackEveryEarlierOperationAndSequence() {
        let first = entity(entryIndex: 7, serialNumber: 3, revision: 0, originX: 10)
        let firstUpdated = entity(
            entryIndex: 7,
            serialNumber: 3,
            revision: 1,
            originX: 99
        )
        let missing = entity(entryIndex: 12, serialNumber: 4, revision: 1)

        var client = SourceEntityReplicationClientState()
        XCTAssertTrue(client.connect(generation: generation1))
        _ = client.apply(packet(sequence: 1, payload: .snapshot([first])))
        let beforeFailure = client.snapshot

        XCTAssertEqual(
            client.apply(
                packet(
                    sequence: 2,
                    payload: .delta([.update(firstUpdated), .update(missing)])
                )
            ),
            .rejected(.missingEntity(missing.identity.handle))
        )
        XCTAssertEqual(client.lastAppliedSequence, 1)
        XCTAssertEqual(client.snapshot, beforeFailure)

        XCTAssertEqual(
            client.apply(packet(sequence: 2, payload: .delta([.update(firstUpdated)]))),
            .applied(
                SourceEntityReplicationClientSnapshot(
                    connectionGeneration: generation1,
                    sequence: 2,
                    entities: [firstUpdated]
                )
            )
        )
        XCTAssertEqual(beforeFailure?.entities, [first])
    }

    func testSlotReuseRequiresOrderedOldGenerationRemoveThenNewGenerationCreate() {
        let oldEntity = entity(entryIndex: 11, serialNumber: 4, revision: 5)
        let oldRemoved = entity(
            entryIndex: 11,
            serialNumber: 4,
            revision: 6,
            lifecycle: .removed
        )
        let newEntity = entity(entryIndex: 11, serialNumber: 5, revision: 0)

        var client = SourceEntityReplicationClientState()
        XCTAssertTrue(client.connect(generation: generation1))
        _ = client.apply(packet(sequence: 1, payload: .snapshot([oldEntity])))

        XCTAssertEqual(
            client.apply(packet(sequence: 2, payload: .delta([.create(newEntity)]))),
            .rejected(
                .entryGenerationConflict(
                    existing: oldEntity.identity.handle,
                    incoming: newEntity.identity.handle
                )
            )
        )
        XCTAssertEqual(client.lastAppliedSequence, 1)

        XCTAssertEqual(
            client.apply(
                packet(
                    sequence: 2,
                    payload: .delta([.remove(oldRemoved), .create(newEntity)])
                )
            ),
            .applied(
                SourceEntityReplicationClientSnapshot(
                    connectionGeneration: generation1,
                    sequence: 2,
                    entities: [newEntity]
                )
            )
        )
    }

    func testRevisionAndNetworkabilityFailuresAreTransactional() {
        let original = entity(entryIndex: 7, serialNumber: 3, revision: 4)
        let stale = entity(entryIndex: 7, serialNumber: 3, revision: 4, originX: 55)
        let nonNetworkable = entity(
            entryIndex: 8,
            serialNumber: 2,
            revision: 0,
            isNetworkable: false
        )

        var client = SourceEntityReplicationClientState()
        XCTAssertTrue(client.connect(generation: generation1))
        _ = client.apply(packet(sequence: 1, payload: .snapshot([original])))

        XCTAssertEqual(
            client.apply(packet(sequence: 2, payload: .delta([.update(stale)]))),
            .rejected(
                .nonMonotonicRevision(
                    handle: original.identity.handle,
                    current: 4,
                    received: 4
                )
            )
        )
        XCTAssertEqual(
            client.apply(packet(sequence: 2, payload: .delta([.create(nonNetworkable)]))),
            .rejected(.nonNetworkableEntity(nonNetworkable.identity.handle))
        )
        XCTAssertEqual(client.lastAppliedSequence, 1)
        XCTAssertEqual(client.snapshot?.entities, [original])
    }

    func testLifecycleAndClassNameValidationRejectsWholePacket() {
        let original = entity(entryIndex: 7, serialNumber: 3, revision: 0)
        let pendingSnapshot = entity(
            entryIndex: 7,
            serialNumber: 3,
            revision: 1,
            lifecycle: .pendingRemoval
        )
        let removedSnapshot = entity(
            entryIndex: 7,
            serialNumber: 3,
            revision: 1,
            lifecycle: .removed
        )
        let pendingCreate = entity(
            entryIndex: 8,
            serialNumber: 2,
            revision: 0,
            lifecycle: .pendingRemoval
        )
        let activeRemove = entity(
            entryIndex: 7,
            serialNumber: 3,
            revision: 1
        )
        let mismatchedClass = entity(
            entryIndex: 8,
            serialNumber: 2,
            revision: 0,
            className: SourceCanonicalEntityKind.player.className
        )
        let validUpdate = entity(
            entryIndex: 7,
            serialNumber: 3,
            revision: 1,
            originX: 5
        )

        var client = SourceEntityReplicationClientState()
        XCTAssertTrue(client.connect(generation: generation1))
        XCTAssertEqual(
            client.apply(packet(sequence: 1, payload: .snapshot([pendingSnapshot]))),
            .rejected(
                .lifecycleNotAllowed(
                    change: .snapshot,
                    handle: pendingSnapshot.identity.handle,
                    lifecycle: .pendingRemoval
                )
            )
        )
        _ = client.apply(packet(sequence: 1, payload: .snapshot([original])))

        XCTAssertEqual(
            client.apply(packet(sequence: 2, payload: .delta([.create(pendingCreate)]))),
            .rejected(
                .lifecycleNotAllowed(
                    change: .create,
                    handle: pendingCreate.identity.handle,
                    lifecycle: .pendingRemoval
                )
            )
        )
        XCTAssertEqual(
            client.apply(packet(sequence: 2, payload: .delta([.update(removedSnapshot)]))),
            .rejected(
                .lifecycleNotAllowed(
                    change: .update,
                    handle: removedSnapshot.identity.handle,
                    lifecycle: .removed
                )
            )
        )
        XCTAssertEqual(
            client.apply(packet(sequence: 2, payload: .delta([.remove(activeRemove)]))),
            .rejected(
                .lifecycleNotAllowed(
                    change: .remove,
                    handle: activeRemove.identity.handle,
                    lifecycle: .active
                )
            )
        )
        XCTAssertEqual(
            client.apply(packet(sequence: 2, payload: .delta([.create(mismatchedClass)]))),
            .rejected(
                .classNameKindMismatch(
                    handle: mismatchedClass.identity.handle,
                    expected: SourceCanonicalEntityKind.propPhysics.className,
                    received: SourceCanonicalEntityKind.player.className
                )
            )
        )
        XCTAssertEqual(client.lastAppliedSequence, 1)
        XCTAssertEqual(client.snapshot?.entities, [original])
        XCTAssertEqual(
            client.apply(packet(sequence: 2, payload: .delta([.update(validUpdate)]))),
            .applied(
                SourceEntityReplicationClientSnapshot(
                    connectionGeneration: generation1,
                    sequence: 2,
                    entities: [validUpdate]
                )
            )
        )
    }

    private func packet(
        sequence: UInt64,
        payload: SourceEntityReplicationPayload,
        generation: SourceEntityReplicationConnectionGeneration? = nil
    ) -> SourceEntityReplicationPacket {
        SourceEntityReplicationPacket(
            connectionGeneration: generation ?? generation1,
            sequence: sequence,
            payload: payload
        )
    }

    private func entity(
        entryIndex: Int,
        serialNumber: Int,
        revision: UInt64,
        lifecycle: SourceCanonicalEntityLifecycle = .active,
        originX: Float = 0,
        isNetworkable: Bool = true,
        className: String? = nil
    ) -> SourceCanonicalEntitySnapshot {
        SourceCanonicalEntitySnapshot(
            identity: SourceCanonicalEntityIdentity(
                handle: SourceBaseHandle(
                    entryIndex: entryIndex,
                    serialNumber: serialNumber
                )
            ),
            kind: .propPhysics,
            className: className ?? SourceCanonicalEntityKind.propPhysics.className,
            transform: SourceEntityTransform(
                origin: SourceVector3(originX, 0, 0)
            ),
            motion: SourceEntityMotionState(),
            model: SourceEntityModelReference("models/props_c17/oildrum001.mdl"),
            solidType: .vPhysics,
            moveType: .vPhysics,
            lifecycle: lifecycle,
            isNetworkable: isNetworkable,
            revision: revision
        )
    }
}
