import XCTest
@testable import GModEngine
import GModLua

final class SourceCanonicalCollisionPropertyBridgeTests: XCTestCase {
    func testValidatedBoundsDriveGLuaQueriesAndReplicateWithoutFallback() throws {
        let runtime = GMLuaRuntime(
            realm: .server,
            logger: { _ in },
            netTransport: GMLuaNetTransport()
        )
        let adapter = try GMLuaSourceRuntimeAdapter(
            serverRuntime: runtime,
            initialEntitySerialNumber: 6
        )
        defer {
            try? adapter.close()
            _ = runtime.close()
        }
        try adapter.installCanonicalEntityLuaBridge()

        var state = SourceCanonicalEntityState.defaults(for: .propPhysics)
        state.transform = SourceEntityTransform(
            origin: SourceVector3(10, 20, 30),
            angles: SourceQAngle(pitch: 0, yaw: 90, roll: 0)
        )
        let created = try adapter.createCanonicalEntity(
            kind: .propPhysics,
            at: 12,
            state: state
        )
        XCTAssertNil(created.collisionProperty)

        try runtime.execute(
            """
            local prop = Entity(12)
            local ok, message = pcall(function() return prop:OBBMins() end)
            assert(ok == false)
            assert(string.find(message, "canonical collision property is unavailable", 1, true))
            """,
            sourceName: "=(canonical collision property unavailable)"
        )

        let journalBeforeRejection = adapter.pendingCanonicalEntityOperationCount
        XCTAssertThrowsError(
            try adapter.setCanonicalCollisionBounds(
                mins: SourceVector3(2, 0, 0),
                maxs: SourceVector3(1, 1, 1),
                for: created.identity
            )
        ) { error in
            XCTAssertEqual(
                error as? SourceCollisionProperty.ValidationError,
                .invertedBounds
            )
        }
        XCTAssertEqual(adapter.canonicalSnapshot(for: created.identity), created)
        XCTAssertEqual(
            adapter.pendingCanonicalEntityOperationCount,
            journalBeforeRejection
        )

        let updated = try adapter.setCanonicalCollisionBounds(
            mins: SourceVector3(-2, -1, -3),
            maxs: SourceVector3(4, 5, 6),
            for: created.identity
        )
        XCTAssertEqual(updated.revision, created.revision + 1)
        XCTAssertEqual(
            updated.collisionProperty,
            try SourceCollisionProperty(
                mins: SourceVector3(-2, -1, -3),
                maxs: SourceVector3(4, 5, 6)
            )
        )
        XCTAssertEqual(
            adapter.pendingCanonicalEntityOperationCount,
            journalBeforeRejection + 1
        )

        try runtime.execute(
            """
            local prop = Entity(12)
            local mins = prop:OBBMins()
            local maxs = prop:OBBMaxs()
            assert(mins.x == -2 and mins.y == -1 and mins.z == -3)
            assert(maxs.x == 4 and maxs.y == 5 and maxs.z == 6)

            local collisionMins, collisionMaxs = prop:GetCollisionBounds()
            assert(collisionMins.x == mins.x and collisionMins.y == mins.y and collisionMins.z == mins.z)
            assert(collisionMaxs.x == maxs.x and collisionMaxs.y == maxs.y and collisionMaxs.z == maxs.z)

            local query = prop:LocalToWorld(Vector(9, -8, 2))
            local nearest = prop:NearestPoint(query)
            local expected = prop:LocalToWorld(Vector(4, -1, 2))
            assert(math.abs(nearest.x - expected.x) < 0.0001)
            assert(math.abs(nearest.y - expected.y) < 0.0001)
            assert(math.abs(nearest.z - expected.z) < 0.0001)
            """,
            sourceName: "=(canonical collision property GLua queries)"
        )

        let generation = SourceEntityReplicationConnectionGeneration(rawValue: 1)
        var stream = try SourceEntityReplicationServerStream(
            connectionGeneration: generation
        )
        var client = SourceEntityReplicationClientState()
        XCTAssertTrue(client.connect(generation: generation))
        _ = client.apply(try stream.makeSnapshot([created]))
        XCTAssertNil(client.snapshot?.entities.first?.collisionProperty)

        _ = client.apply(try stream.makeDelta([.update(updated)]))
        XCTAssertEqual(client.snapshot?.entities, [updated])
        XCTAssertEqual(
            client.snapshot?.entities.first?.collisionProperty,
            updated.collisionProperty
        )
    }
}
