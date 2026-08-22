import XCTest
@testable import GModEngine

final class SourceCanonicalCollisionGroupBridgeTests: XCTestCase {
    func testServerMutationReplicatesAndInvalidValuesDoNotCommit() throws {
        let runtime = GMLuaRuntime(
            realm: .server,
            logger: { _ in },
            netTransport: GMLuaNetTransport()
        )
        let adapter = try GMLuaSourceRuntimeAdapter(
            serverRuntime: runtime,
            initialEntitySerialNumber: 3
        )
        defer {
            try? adapter.close()
            _ = runtime.close()
        }
        try adapter.installCanonicalEntityLuaBridge()
        let created = try adapter.createCanonicalEntity(
            kind: .propPhysics,
            at: 12
        )
        XCTAssertEqual(created.collisionGroup, 0)

        try runtime.execute(
            """
            local prop = Entity(12)
            assert(prop:GetCollisionGroup() == COLLISION_GROUP_NONE)
            prop:SetCollisionGroup(11)
            assert(prop:GetCollisionGroup() == 11)
            local ok = pcall(function() prop:SetCollisionGroup(-1) end)
            assert(ok == false)
            assert(prop:GetCollisionGroup() == 11)
            """,
            sourceName: "=(canonical collision group bridge)"
        )
        let updated = try XCTUnwrap(
            adapter.canonicalSnapshot(for: created.identity)
        )
        XCTAssertEqual(updated.collisionGroup, 11)
        XCTAssertEqual(updated.revision, created.revision + 1)

        let generation = SourceEntityReplicationConnectionGeneration(rawValue: 1)
        var stream = try SourceEntityReplicationServerStream(
            connectionGeneration: generation
        )
        var client = SourceEntityReplicationClientState()
        XCTAssertTrue(client.connect(generation: generation))
        _ = client.apply(try stream.makeSnapshot([created]))
        XCTAssertEqual(client.snapshot?.entities.first?.collisionGroup, 0)
        _ = client.apply(try stream.makeDelta([.update(updated)]))
        XCTAssertEqual(client.snapshot?.entities.first?.collisionGroup, 11)
    }

    func testSwiftStateRejectsNegativeCollisionGroupTransactionally() throws {
        let store = SourceCanonicalEntityStore()
        let created = try store.create(kind: .propPhysics, at: 4)
        XCTAssertThrowsError(try store.update(created.identity) { state in
            state.collisionGroup = -1
        }) { error in
            XCTAssertEqual(
                error as? SourceCanonicalEntityError,
                .invalidCollisionGroup(-1)
            )
        }
        XCTAssertEqual(store.snapshot(for: created.identity), created)
    }
}
