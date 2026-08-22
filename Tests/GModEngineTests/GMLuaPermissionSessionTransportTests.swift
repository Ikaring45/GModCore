import XCTest
import GModLua
@testable import GModEngine

final class GMLuaPermissionSessionTransportTests: XCTestCase {
    func testLocalConnectionChangesAndStaleDisconnectUseSharedFIFO()
        throws {
        let queue = PermissionTestFIFO()
        let recorder = PermissionDeliveryRecorder()
        let transport = GMLuaPermissionSessionTransport(
            fifo: queue.adapter,
            endpoints: GMLuaPermissionSessionEndpoints(
                server: { recorder.server.append($0) },
                client: { recorder.client.append($0) }
            )
        )
        let permissions = PermissionHostFixture()
        let state = LuaState(output: { _ in })
        defer { _ = state.close() }
        var hookCount = 0
        var resumeCount = 0

        XCTAssertTrue(try GMLuaPermissions.install(
            into: state,
            realm: .menu,
            host: permissions.host,
            sessionTransport: transport,
            onPermissionsChanged: { hookCount += 1 },
            onLocalSessionConnect: { resumeCount += 1 }
        ))

        try state.execute(
            #"""
            local ok = pcall(function()
                permissions.Connect("local://garrys-pad")
            end)
            assert(ok == false)
            permissions.Grant("connect", true)
            permissions.Connect("local://garrys-pad")
            """#,
            sourceName: "@tests/permission_session_connect.lua"
        )

        XCTAssertEqual(hookCount, 1)
        XCTAssertEqual(resumeCount, 1)
        XCTAssertEqual(queue.pendingCount, 2)
        XCTAssertTrue(recorder.server.isEmpty)
        XCTAssertTrue(recorder.client.isEmpty)

        let initial = try queue.pump(into: transport)
        XCTAssertEqual(initial, [.delivered, .delivered])
        XCTAssertEqual(recorder.server.count, 1)
        XCTAssertEqual(recorder.client.count, 1)
        let firstGeneration = try connectedGeneration(
            recorder.server[0],
            expectedDestination: .server,
            expectedPermissions: GMLuaPermissionSnapshot(
                temporary: ["local://garrys-pad": ["connect"]],
                permanent: [:]
            )
        )
        XCTAssertEqual(
            try connectedGeneration(
                recorder.client[0],
                expectedDestination: .client,
                expectedPermissions: GMLuaPermissionSnapshot(
                    temporary: ["local://garrys-pad": ["connect"]],
                    permanent: [:]
                )
            ),
            firstGeneration
        )

        try state.execute(
            #"permissions.Grant("openurl", false)"#,
            sourceName: "@tests/permission_session_change.lua"
        )
        XCTAssertEqual(hookCount, 2)
        let queuedChange = try XCTUnwrap(queue.pending.first)
        XCTAssertEqual(try queue.pump(into: transport), [
            .delivered,
            .delivered,
        ])
        XCTAssertEqual(recorder.server.count, 2)
        XCTAssertEqual(recorder.client.count, 2)
        assertChanged(
            recorder.server[1],
            generation: firstGeneration,
            revision: 1,
            destination: .server
        )
        assertChanged(
            recorder.client[1],
            generation: firstGeneration,
            revision: 1,
            destination: .client
        )

        XCTAssertTrue(try transport.disconnect())
        XCTAssertEqual(queue.pendingCount, 2)
        try state.execute(
            #"permissions.Connect("local://garrys-pad")"#,
            sourceName: "@tests/permission_session_reconnect.lua"
        )
        XCTAssertEqual(resumeCount, 2)
        XCTAssertEqual(queue.pendingCount, 4)
        XCTAssertEqual(try queue.pump(into: transport), [
            .stale,
            .stale,
            .delivered,
            .delivered,
        ])
        XCTAssertEqual(recorder.server.count, 3)
        XCTAssertEqual(recorder.client.count, 3)
        let secondGeneration = try connectedGeneration(
            recorder.server[2],
            expectedDestination: .server,
            expectedPermissions: GMLuaPermissionSnapshot(
                temporary: ["local://garrys-pad": ["connect"]],
                permanent: ["local://garrys-pad": ["openurl"]]
            )
        )
        XCTAssertGreaterThan(secondGeneration, firstGeneration)
        XCTAssertEqual(
            try transport.deliver(queuedChange),
            .stale
        )

        XCTAssertTrue(try transport.disconnect())
        XCTAssertFalse(try transport.disconnect())
        XCTAssertEqual(try queue.pump(into: transport), [
            .delivered,
            .delivered,
        ])
        XCTAssertEqual(recorder.server.count, 4)
        XCTAssertEqual(recorder.client.count, 4)
        assertDisconnected(
            recorder.server[3],
            generation: secondGeneration,
            destination: .server
        )
        assertDisconnected(
            recorder.client[3],
            generation: secondGeneration,
            destination: .client
        )
    }

    private func connectedGeneration(
        _ delivery: GMLuaPermissionSessionDelivery,
        expectedDestination: GMLuaPermissionSessionDestination,
        expectedPermissions: GMLuaPermissionSnapshot
    ) throws -> GMLuaPermissionSessionGeneration {
        XCTAssertEqual(delivery.destination, expectedDestination)
        XCTAssertEqual(delivery.revision, 0)
        guard case let .connected(target, permissions) = delivery.payload else {
            XCTFail("expected connected permission delivery")
            throw PermissionTestError.unexpectedDelivery
        }
        XCTAssertEqual(target, "local://garrys-pad")
        XCTAssertEqual(permissions, expectedPermissions)
        return delivery.generation
    }

    private func assertChanged(
        _ delivery: GMLuaPermissionSessionDelivery,
        generation: GMLuaPermissionSessionGeneration,
        revision: UInt64,
        destination: GMLuaPermissionSessionDestination
    ) {
        XCTAssertEqual(delivery.generation, generation)
        XCTAssertEqual(delivery.revision, revision)
        XCTAssertEqual(delivery.destination, destination)
        guard case let .permissionsChanged(snapshot) = delivery.payload else {
            XCTFail("expected permissionsChanged delivery")
            return
        }
        XCTAssertEqual(snapshot, GMLuaPermissionSnapshot(
            temporary: ["local://garrys-pad": ["connect"]],
            permanent: ["local://garrys-pad": ["openurl"]]
        ))
    }

    private func assertDisconnected(
        _ delivery: GMLuaPermissionSessionDelivery,
        generation: GMLuaPermissionSessionGeneration,
        destination: GMLuaPermissionSessionDestination
    ) {
        XCTAssertEqual(delivery.generation, generation)
        XCTAssertEqual(delivery.revision, 0)
        XCTAssertEqual(delivery.destination, destination)
        guard case .disconnected = delivery.payload else {
            XCTFail("expected disconnected delivery")
            return
        }
    }
}

private final class PermissionTestFIFO {
    private(set) var pending: [GMLuaPermissionSessionDelivery] = []

    var pendingCount: Int { pending.count }

    var adapter: GMLuaPermissionSharedFIFO {
        GMLuaPermissionSharedFIFO { [weak self] batch in
            self?.pending.append(contentsOf: batch)
        }
    }

    func pump(
        into transport: GMLuaPermissionSessionTransport
    ) throws -> [GMLuaPermissionDeliveryDisposition] {
        let deliveries = pending
        pending.removeAll(keepingCapacity: true)
        return try deliveries.map { try transport.deliver($0) }
    }
}

private final class PermissionDeliveryRecorder {
    var server: [GMLuaPermissionSessionDelivery] = []
    var client: [GMLuaPermissionSessionDelivery] = []
}

private final class PermissionHostFixture {
    private static let server = "local://garrys-pad"
    private var temporary: [String: Set<String>] = [:]
    private var permanent: [String: Set<String>] = [:]

    var host: GMLuaPermissionsHost {
        GMLuaPermissionsHost(
            currentServerIdentifier: { Self.server },
            grant: { [weak self] permission, server, sessionOnly in
                guard let self else { return false }
                if sessionOnly {
                    guard self.permanent[server]?.contains(permission) != true
                    else { return false }
                    return self.temporary[server, default: []]
                        .insert(permission).inserted
                }
                let inserted = self.permanent[server, default: []]
                    .insert(permission).inserted
                let removed = self.temporary[server]?.remove(permission) != nil
                return inserted || removed
            },
            revoke: { [weak self] permission, server in
                guard let self else { return false }
                let temporary = self.temporary[server]?.remove(permission) != nil
                let permanent = self.permanent[server]?.remove(permission) != nil
                return temporary || permanent
            },
            isGranted: { [weak self] permission, server in
                guard let self else { return false }
                return self.temporary[server]?.contains(permission) == true
                    || self.permanent[server]?.contains(permission) == true
            },
            getAll: { [weak self] in
                GMLuaPermissionSnapshot(
                    temporary: self?.temporary.mapValues { $0.sorted() } ?? [:],
                    permanent: self?.permanent.mapValues { $0.sorted() } ?? [:]
                )
            },
            connect: { target in
                guard target == Self.server else {
                    throw PermissionTestError.unsupportedTarget
                }
                return .localSession
            }
        )
    }
}

private enum PermissionTestError: Error {
    case unsupportedTarget
    case unexpectedDelivery
}
