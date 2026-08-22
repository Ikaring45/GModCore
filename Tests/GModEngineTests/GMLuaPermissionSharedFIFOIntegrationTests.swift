import XCTest
@testable import GModEngine

final class GMLuaPermissionSharedFIFOIntegrationTests: XCTestCase {
    func testPermissionProjectionUsesSharedGameplayFIFO() throws {
        let session = GMLuaSharedSession()
        let server = GMLuaRuntime(
            realm: .server,
            logger: { _ in },
            netTransport: session.netTransport
        )
        let client = GMLuaRuntime(
            realm: .client,
            logger: { _ in },
            netTransport: session.netTransport
        )
        defer {
            _ = client.close()
            _ = server.close()
        }
        try session.connect(server: server, client: client)

        let initial = GMLuaPermissionSnapshot(
            temporary: ["local://garrys-pad": ["connect"]],
            permanent: [:]
        )
        let generation = try session.permissionSessionTransport.connect(
            to: "local://garrys-pad",
            permissions: initial
        )
        XCTAssertEqual(session.netTransport.pendingDeliveryCount, 2)
        XCTAssertNil(session.serverPermissionProjection.snapshot)
        XCTAssertNil(session.clientPermissionProjection.snapshot)

        XCTAssertEqual(try session.pump(maxDeliveries: 1), 1)
        XCTAssertEqual(
            session.serverPermissionProjection.snapshot,
            GMLuaPermissionRealmSnapshot(
                target: "local://garrys-pad",
                generation: generation,
                revision: 0,
                permissions: initial
            )
        )
        XCTAssertNil(session.clientPermissionProjection.snapshot)
        XCTAssertEqual(try session.pump(), 1)
        XCTAssertEqual(
            session.clientPermissionProjection.snapshot,
            session.serverPermissionProjection.snapshot
        )

        let changed = GMLuaPermissionSnapshot(
            temporary: ["local://garrys-pad": ["connect"]],
            permanent: ["local://garrys-pad": ["openurl"]]
        )
        XCTAssertTrue(
            try session.permissionSessionTransport.permissionsDidChange(
                to: changed
            )
        )
        XCTAssertEqual(try session.pump(), 2)
        XCTAssertEqual(
            session.serverPermissionProjection.snapshot?.revision,
            1
        )
        XCTAssertEqual(
            session.clientPermissionProjection.snapshot?.permissions,
            changed
        )

        XCTAssertTrue(try session.permissionSessionTransport.disconnect())
        XCTAssertEqual(try session.pump(), 2)
        XCTAssertNil(session.serverPermissionProjection.snapshot)
        XCTAssertNil(session.clientPermissionProjection.snapshot)
    }
}
