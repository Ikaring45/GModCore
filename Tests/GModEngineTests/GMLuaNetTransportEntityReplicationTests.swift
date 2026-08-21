import Foundation
import XCTest
@testable import GModEngine
import GModLua

private final class LockedEntityTransportEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ event: String) {
        lock.lock()
        storage.append(event)
        lock.unlock()
    }

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private final class LockedEntityReplicationSink: @unchecked Sendable {
    private let lock = NSLock()
    private var state: SourceEntityReplicationClientState

    init(generation: SourceEntityReplicationConnectionGeneration) {
        var state = SourceEntityReplicationClientState()
        precondition(state.connect(generation: generation))
        self.state = state
    }

    func apply(
        _ packet: SourceEntityReplicationPacket
    ) -> SourceEntityReplicationApplyResult {
        lock.lock()
        defer { lock.unlock() }
        return state.apply(packet)
    }

    var snapshot: SourceEntityReplicationClientSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return state.snapshot
    }
}

final class GMLuaNetTransportEntityReplicationTests: XCTestCase {
    private let generation1 = SourceEntityReplicationConnectionGeneration(rawValue: 1)
    private let generation2 = SourceEntityReplicationConnectionGeneration(rawValue: 2)

    func testEntityNetAndConsoleShareOnePumpBoundedGlobalFIFO() throws {
        let pair = try makeConnectedPair()
        let events = LockedEntityTransportEvents()
        let sink = LockedEntityReplicationSink(generation: generation1)
        let serverEndpoint = try XCTUnwrap(pair.server.netEndpoint)
        let clientEndpoint = try XCTUnwrap(pair.client.netEndpoint)

        try clientEndpoint.connectEntityReplicationHandler { packet in
            events.append("entity")
            return sink.apply(packet)
        }
        pair.server.state.register("__record_entity_transport_event") { arguments in
            if case let .string(value) = arguments.first {
                events.append(value.utf8String)
            }
            return []
        }
        pair.client.state.register("__record_entity_transport_event") { arguments in
            if case let .string(value) = arguments.first {
                events.append(value.utf8String)
            }
            return []
        }
        try pair.server.execute(
            """
            util.AddNetworkString("entity_transport_fifo_net")
            concommand = {}
            function concommand.Run(sender, command)
                if command == "entity_transport_fifo_console" then
                    __record_entity_transport_event("console")
                end
            end
            AddConsoleCommand("entity_transport_fifo_console")
            """
        )
        try pair.client.execute(
            """
            net.Receive("entity_transport_fifo_net", function()
                __record_entity_transport_event("net")
            end)
            """
        )

        try pair.session.netTransport.enqueueEntityReplication(
            packet(sequence: 1, payload: .snapshot([])),
            from: serverEndpoint,
            to: clientEndpoint
        )
        try pair.session.netTransport.enqueueConsoleCommand(
            from: clientEndpoint,
            command: "entity_transport_fifo_console",
            arguments: []
        )
        try pair.server.execute(
            """
            net.Start("entity_transport_fifo_net")
            net.Broadcast()
            """
        )

        XCTAssertEqual(pair.session.netTransport.pendingDeliveryCount, 3)
        XCTAssertEqual(events.values, [])
        XCTAssertEqual(sink.snapshot?.sequence, 0, "enqueue must not expose SERVER state")

        XCTAssertEqual(try pair.session.pump(maxDeliveries: 1), 1)
        XCTAssertEqual(events.values, ["entity"])
        XCTAssertEqual(sink.snapshot?.sequence, 1)

        XCTAssertEqual(try pair.session.pump(maxDeliveries: 1), 1)
        XCTAssertEqual(events.values, ["entity", "console"])

        XCTAssertEqual(try pair.session.pump(maxDeliveries: 1), 1)
        XCTAssertEqual(events.values, ["entity", "console", "net"])
        XCTAssertEqual(pair.session.netTransport.pendingDeliveryCount, 0)
    }

    func testEnqueueRequiresTheConnectedClientGenerationAndDisconnectPurgesEntity() throws {
        let pair = try makeConnectedPair()
        let sink = LockedEntityReplicationSink(generation: generation1)
        let serverEndpoint = try XCTUnwrap(pair.server.netEndpoint)
        let clientEndpoint = try XCTUnwrap(pair.client.netEndpoint)
        try clientEndpoint.connectEntityReplicationHandler { packet in
            sink.apply(packet)
        }

        XCTAssertThrowsError(
            try pair.session.netTransport.enqueueEntityReplication(
                packet(
                    sequence: 1,
                    payload: .snapshot([]),
                    generation: generation2
                ),
                from: serverEndpoint,
                to: clientEndpoint
            )
        ) { error in
            XCTAssertEqual(
                error as? GMLuaEntityReplicationTransportError,
                .connectionGenerationMismatch(
                    expected: self.generation1,
                    received: self.generation2
                )
            )
        }
        XCTAssertEqual(pair.session.netTransport.pendingDeliveryCount, 0)

        try pair.session.netTransport.enqueueEntityReplication(
            packet(sequence: 1, payload: .snapshot([])),
            from: serverEndpoint,
            to: clientEndpoint
        )
        XCTAssertEqual(pair.session.netTransport.pendingDeliveryCount, 1)

        try pair.session.disconnect(client: pair.client)
        XCTAssertEqual(pair.session.netTransport.pendingDeliveryCount, 0)
        XCTAssertEqual(try pair.session.pump(), 0)
        XCTAssertEqual(sink.snapshot?.sequence, 0)
    }

    func testRejectedEntityDeliveryIsTypedAndClientApplyRemainsTransactional() throws {
        let pair = try makeConnectedPair()
        let sink = LockedEntityReplicationSink(generation: generation1)
        let serverEndpoint = try XCTUnwrap(pair.server.netEndpoint)
        let clientEndpoint = try XCTUnwrap(pair.client.netEndpoint)
        try clientEndpoint.connectEntityReplicationHandler { packet in
            sink.apply(packet)
        }

        try pair.session.netTransport.enqueueEntityReplication(
            packet(sequence: 1, payload: .snapshot([])),
            from: serverEndpoint,
            to: clientEndpoint
        )
        XCTAssertEqual(try pair.session.pump(), 1)

        let created = entity(entryIndex: 7, serialNumber: 3, revision: 0)
        let missing = entity(entryIndex: 12, serialNumber: 4, revision: 1)
        try pair.session.netTransport.enqueueEntityReplication(
            packet(
                sequence: 2,
                payload: .delta([.create(created), .update(missing)])
            ),
            from: serverEndpoint,
            to: clientEndpoint
        )
        try pair.session.netTransport.enqueueEntityReplication(
            packet(sequence: 3, payload: .delta([])),
            from: serverEndpoint,
            to: clientEndpoint
        )

        XCTAssertThrowsError(try pair.session.pump()) { error in
            XCTAssertEqual(
                error as? GMLuaEntityReplicationTransportError,
                .packetRejected(
                    transportSequence: 2,
                    packetSequence: 2,
                    rejection: .missingEntity(missing.identity.handle)
                )
            )
        }
        XCTAssertEqual(sink.snapshot?.sequence, 1)
        XCTAssertEqual(sink.snapshot?.entities, [])
        XCTAssertEqual(
            pair.session.netTransport.pendingDeliveryCount,
            1,
            "a failing entity handler must leave later global FIFO entries queued"
        )
    }

    func testEntityHandlerBelongsToAClientEndpointAndMissingHandlerIsTyped() throws {
        let pair = try makeConnectedPair()
        let serverEndpoint = try XCTUnwrap(pair.server.netEndpoint)
        let clientEndpoint = try XCTUnwrap(pair.client.netEndpoint)

        XCTAssertThrowsError(
            try serverEndpoint.connectEntityReplicationHandler { _ in
                .rejected(.noActiveConnection)
            }
        ) { error in
            XCTAssertEqual(
                error as? GMLuaEntityReplicationTransportError,
                .clientDestinationRequired
            )
        }

        try pair.session.netTransport.enqueueEntityReplication(
            packet(sequence: 1, payload: .snapshot([])),
            from: serverEndpoint,
            to: clientEndpoint
        )
        XCTAssertThrowsError(try pair.session.pump()) { error in
            XCTAssertEqual(
                error as? GMLuaEntityReplicationTransportError,
                .clientHandlerUnavailable
            )
        }
    }

    private func makeConnectedPair() throws -> (
        session: GMLuaSharedSession,
        server: GMLuaRuntime,
        client: GMLuaRuntime
    ) {
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
        try client.execute(
            """
            net.Receivers = {}
            function net.Receive(name, callback)
                net.Receivers[string.lower(name)] = callback
            end
            function net.Incoming(length, sender)
                local messageID = net.ReadHeader()
                local messageName = assert(util.NetworkIDToString(messageID))
                local callback = net.Receivers[string.lower(messageName)]
                if callback ~= nil then callback(length - 16, sender) end
            end
            """,
            sourceName: "=(entity replication FIFO net dispatch)"
        )
        try server.execute("return true")
        try client.execute("return true")
        try session.connect(
            server: server,
            client: client,
            playerIndex: 1,
            userID: 101
        )
        return (session, server, client)
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
        revision: UInt64
    ) -> SourceCanonicalEntitySnapshot {
        SourceCanonicalEntitySnapshot(
            identity: SourceCanonicalEntityIdentity(
                handle: SourceBaseHandle(
                    entryIndex: entryIndex,
                    serialNumber: serialNumber
                )
            ),
            kind: .propPhysics,
            className: SourceCanonicalEntityKind.propPhysics.className,
            transform: SourceEntityTransform(),
            motion: SourceEntityMotionState(),
            model: SourceEntityModelReference("models/props_c17/oildrum001.mdl"),
            solidType: .vPhysics,
            moveType: .vPhysics,
            lifecycle: .active,
            isNetworkable: true,
            revision: revision
        )
    }
}
