import XCTest
@testable import GModEngine
import GModLua

final class GMLuaSourceRuntimeAdapterCanonicalEntityTests: XCTestCase {
    func testCanonicalWorldPlayerAndPropUseKernelHandleAndServerOnlyProjection() throws {
        let transport = GMLuaNetTransport()
        let server = makeRuntime(.server, transport: transport)
        let client = makeRuntime(.client, transport: transport)
        let model = SourceEntityModelReference("models/props_c17/oildrum001.mdl")
        let adapter = try GMLuaSourceRuntimeAdapter(
            serverRuntime: server,
            initialEntitySerialNumber: 9,
            canonicalModelValidator: { requestedModel, kind in
                requestedModel == model && kind == .propPhysics ? .valid : .invalid
            }
        )
        defer {
            try? adapter.close()
            _ = client.close()
            _ = server.close()
        }
        try installNoopHooks(in: server)
        try installNoopHooks(in: client)
        try adapter.attach(client: client)

        let world = try adapter.createCanonicalEntity(kind: .world)
        let player = try adapter.createCanonicalEntity(
            kind: .player,
            at: 1,
            playerUserID: 17
        )
        var propState = SourceCanonicalEntityState.defaults(for: .propPhysics)
        propState.model = model
        let prop = try adapter.createCanonicalEntity(
            kind: .propPhysics,
            at: 24,
            state: propState
        )

        let serverRegistry = try XCTUnwrap(server.entityRegistry)
        _ = try serverRegistry.register(
            index: 40,
            kind: .entity,
            className: "legacy_collision"
        )
        XCTAssertThrowsError(
            try adapter.createCanonicalEntity(kind: .player, at: 40)
        ) { error in
            XCTAssertEqual(
                error as? GMLuaCanonicalEntityRegistryError,
                .occupiedLegacyEntityIndex(40)
            )
        }
        XCTAssertNil(adapter.canonicalEntitySnapshots.first(where: {
            $0.identity.entryIndex == 40
        }))
        serverRegistry.unregister(index: 40)
        let collisionReplacement = try adapter.createCanonicalEntity(
            kind: .player,
            at: 40
        )
        XCTAssertEqual(collisionReplacement.identity.serialNumber, 10)

        XCTAssertEqual(
            adapter.canonicalEntitySnapshots.map(\.identity),
            [
                world.identity,
                player.identity,
                prop.identity,
                collisionReplacement.identity,
            ]
        )
        for snapshot in [world, player, prop, collisionReplacement] {
            XCTAssertTrue(adapter.contains(snapshot.identity))
            XCTAssertEqual(
                server.entityRegistry?.canonicalSnapshot(
                    at: snapshot.identity.entryIndex
                ),
                snapshot
            )
            XCTAssertNil(
                client.entityRegistry?.canonicalSnapshot(
                    at: snapshot.identity.entryIndex
                ),
                "canonical CLIENT state must arrive only through the SharedSession FIFO"
            )
        }

        XCTAssertThrowsError(
            try adapter.spawnNetworkableEntity(
                SourceEntity(className: "legacy_prop"),
                at: prop.identity.entryIndex
            )
        ) { error in
            XCTAssertEqual(
                error as? SourceEntityListError,
                .occupiedEntryIndex(prop.identity.entryIndex),
                "legacy and canonical APIs must contend for the same SourceEntityList slot"
            )
        }

        let propBeforeNestedMutation = try XCTUnwrap(
            adapter.canonicalSnapshot(for: prop.identity)
        )
        var nestedMutationError: Error?
        let propAfterNestedMutation = try adapter.updateCanonicalEntity(prop.identity) { state in
            do {
                _ = try adapter.updateCanonicalEntity(prop.identity) { nestedState in
                    nestedState.transform.origin.x = 999
                }
            } catch {
                nestedMutationError = error
            }
            state.motion.linearVelocity = SourceVector3(4, 5, 6)
        }
        let capturedNestedMutationError = try XCTUnwrap(nestedMutationError)
        XCTAssertTrue(
            String(describing: capturedNestedMutationError).contains(
                "cannot re-enter entity mutation"
            )
        )
        XCTAssertEqual(
            propAfterNestedMutation.revision,
            propBeforeNestedMutation.revision + 1
        )
        XCTAssertEqual(propAfterNestedMutation.transform.origin.x, 0)

        let identities = [
            world.identity,
            player.identity,
            prop.identity,
            collisionReplacement.identity,
        ]
        for (offset, identity) in identities.enumerated() {
            let updated = try adapter.updateCanonicalEntity(identity) { state in
                state.transform.origin = SourceVector3(Float(offset + 1), 2, 3)
            }
            XCTAssertEqual(updated.identity, identity)
            XCTAssertEqual(updated.transform.origin.x, Float(offset + 1))
            XCTAssertEqual(
                server.entityRegistry?.canonicalSnapshot(at: identity.entryIndex),
                updated
            )
            XCTAssertEqual(
                try adapter.spawnCanonicalEntity(identity).lifecycle,
                .spawned
            )
            XCTAssertEqual(
                try adapter.activateCanonicalEntity(identity).lifecycle,
                .active
            )
        }

        let removalOrder = [
            prop.identity,
            collisionReplacement.identity,
            player.identity,
            world.identity,
        ]
        for identity in removalOrder {
            let pending: SourceCanonicalEntitySnapshot
            if identity == prop.identity {
                XCTAssertTrue(try adapter.markForDeletion(identity))
                pending = try XCTUnwrap(adapter.canonicalSnapshot(for: identity))
            } else {
                pending = try adapter.markCanonicalEntityForRemoval(identity)
            }
            XCTAssertEqual(pending.identity, identity)
            XCTAssertEqual(pending.lifecycle, .pendingRemoval)
            XCTAssertTrue(adapter.contains(identity))
            XCTAssertEqual(
                server.entityRegistry?.canonicalSnapshot(at: identity.entryIndex),
                pending
            )
        }

        let report = try adapter.runServerFixedTick()
        XCTAssertEqual(report.removedEntities, removalOrder)
        for identity in removalOrder {
            XCTAssertFalse(adapter.contains(identity))
            XCTAssertNil(adapter.canonicalSnapshot(for: identity))
            XCTAssertNil(server.entityRegistry?.canonicalSnapshot(at: identity.entryIndex))
            XCTAssertNil(client.entityRegistry?.canonicalSnapshot(at: identity.entryIndex))
        }

        let replacement = try adapter.createCanonicalEntity(
            kind: .propPhysics,
            at: prop.identity.entryIndex,
            state: propState
        )
        XCTAssertEqual(replacement.identity.entryIndex, prop.identity.entryIndex)
        XCTAssertNotEqual(replacement.identity.handle, prop.identity.handle)
        XCTAssertEqual(
            replacement.identity.serialNumber,
            prop.identity.serialNumber + 1
        )
        XCTAssertTrue(adapter.contains(replacement.identity))
        XCTAssertFalse(adapter.contains(prop.identity))
        XCTAssertEqual(
            server.entityRegistry?.canonicalSnapshot(at: replacement.identity.entryIndex),
            replacement
        )
        XCTAssertNil(
            client.entityRegistry?.canonicalSnapshot(at: replacement.identity.entryIndex)
        )
    }

    func testProspectivePublisherFailureLeavesCanonicalStateAndDeletionQueueExact() throws {
        enum ProjectionFailure: Error {
            case intentional
        }

        let list = SourceEntityList(initialSerialNumber: 3)
        let store = SourceCanonicalEntityStore(entityList: list)
        let player = try store.create(kind: .player, at: 11)

        XCTAssertThrowsError(
            try store.update(
                player.identity,
                { state in
                    state.transform.origin = SourceVector3(1, 2, 3)
                },
                publishing: { _ in throw ProjectionFailure.intentional }
            )
        )
        XCTAssertEqual(store.snapshot(for: player.identity), player)

        XCTAssertThrowsError(
            try store.spawn(
                player.identity,
                publishing: { _ in throw ProjectionFailure.intentional }
            )
        )
        XCTAssertEqual(store.snapshot(for: player.identity), player)

        let spawned = try store.spawn(player.identity)
        XCTAssertThrowsError(
            try store.activate(
                player.identity,
                publishing: { _ in throw ProjectionFailure.intentional }
            )
        )
        XCTAssertEqual(store.snapshot(for: player.identity), spawned)

        let active = try store.activate(player.identity)
        XCTAssertThrowsError(
            try store.markForRemoval(
                player.identity,
                publishing: { _ in throw ProjectionFailure.intentional }
            )
        )
        XCTAssertEqual(store.snapshot(for: player.identity), active)
        XCTAssertEqual(list.pendingDeletionCount, 0)

        let pending = try store.markForRemoval(player.identity)
        XCTAssertEqual(list.pendingDeletionCount, 1)
        XCTAssertThrowsError(
            try store.create(
                kind: .player,
                at: 12,
                publishing: { _ in throw ProjectionFailure.intentional }
            )
        )
        XCTAssertEqual(store.snapshot(for: player.identity), pending)
        XCTAssertEqual(list.pendingDeletionCount, 1)
        XCTAssertNil(list.entity(at: 12))

        let replacement = try store.create(kind: .player, at: 12)
        XCTAssertEqual(replacement.identity.serialNumber, 4)
        XCTAssertEqual(list.pendingDeletionCount, 1)
    }

    func testMissingServerRemovalProjectionIsReported() throws {
        let transport = GMLuaNetTransport()
        let server = makeRuntime(.server, transport: transport)
        let adapter = try GMLuaSourceRuntimeAdapter(
            serverRuntime: server,
            initialEntitySerialNumber: 1
        )
        defer {
            try? adapter.close()
            _ = server.close()
        }
        try installNoopHooks(in: server)

        let player = try adapter.createCanonicalEntity(kind: .player, at: 9)
        _ = try adapter.markCanonicalEntityForRemoval(player.identity)
        server.entityRegistry?.unregister(index: player.identity.entryIndex)

        XCTAssertThrowsError(try adapter.runServerFixedTick()) { error in
            guard case let GMLuaSourceRuntimeAdapterError
                    .canonicalRemovalProjectionMissing(identity) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(identity, player.identity)
        }
        XCTAssertFalse(adapter.contains(player.identity))
        XCTAssertNil(adapter.canonicalSnapshot(for: player.identity))
    }

    private func makeRuntime(
        _ realm: GMLuaRealm,
        transport: GMLuaNetTransport
    ) -> GMLuaRuntime {
        GMLuaRuntime(
            realm: realm,
            logger: { _ in },
            netTransport: transport
        )
    }

    private func installNoopHooks(in runtime: GMLuaRuntime) throws {
        try runtime.execute(
            """
            GAMEMODE = {}
            hook = {}
            function hook.Call(event, gm) assert(gm == GAMEMODE) end
            """
        )
    }
}
