import XCTest
@testable import GModEngine
import GModLua

final class SourceNetworkVariableAllocationPolicyTests: XCTestCase {
    func testExactBoundariesAcceptAndEachPlusOneHasTypedError() throws {
        let exactPolicy = SourceNetworkVariableAllocationPolicy(
            maximumEntryCount: 2,
            maximumAggregateStoredBytes: 11,
            maximumKeyBytes: 3,
            maximumStringValueBytes: 4
        )
        var exact = SourceEntityNetworkVariables()
        _ = exact.setString(
            SourceNetworkVariableString(bytes: [0x80, 0x00, 0xFF, 0x7F]),
            forKey: SourceNetworkVariableString(bytes: [0xFE, 0x00, 0xFD])
        )
        _ = exact.setInt(
            SourceNetworkedIntValue(sourceFloatBitPattern: 0x7FC0_0042),
            forKey: SourceNetworkVariableString(bytes: [])
        )

        XCTAssertEqual(
            exact.allocationUsage,
            SourceNetworkVariableAllocationUsage(
                entryCount: 2,
                aggregateStoredBytes: 11
            )
        )
        XCTAssertNoThrow(try exact.validate(allocationPolicy: exactPolicy))
        XCTAssertEqual(
            exact.string(
                forKey: SourceNetworkVariableString(bytes: [0xFE, 0x00, 0xFD])
            )?.bytes,
            [0x80, 0x00, 0xFF, 0x7F]
        )

        var tooManyEntries = exact
        _ = tooManyEntries.setInt(
            SourceNetworkedIntValue(sourceFloatBitPattern: 1),
            forKey: SourceNetworkVariableString(bytes: [0x01])
        )
        assertAllocationError(
            .entryCountExceeded(actual: 3, maximum: 2),
            from: { try tooManyEntries.validate(allocationPolicy: exactPolicy) }
        )

        var keyTooLong = SourceEntityNetworkVariables()
        _ = keyTooLong.setString(
            SourceNetworkVariableString(bytes: []),
            forKey: SourceNetworkVariableString(bytes: [0, 1, 2, 3])
        )
        assertAllocationError(
            .keyByteCountExceeded(actual: 4, maximum: 3),
            from: { try keyTooLong.validate(allocationPolicy: exactPolicy) }
        )

        var valueTooLong = SourceEntityNetworkVariables()
        _ = valueTooLong.setString(
            SourceNetworkVariableString(bytes: [0, 1, 2, 3, 4]),
            forKey: SourceNetworkVariableString(bytes: [])
        )
        assertAllocationError(
            .stringValueByteCountExceeded(actual: 5, maximum: 4),
            from: { try valueTooLong.validate(allocationPolicy: exactPolicy) }
        )

        var aggregateTooLarge = SourceEntityNetworkVariables()
        _ = aggregateTooLarge.setString(
            SourceNetworkVariableString(bytes: [0, 1, 2, 3]),
            forKey: SourceNetworkVariableString(bytes: [0, 1, 2, 3])
        )
        _ = aggregateTooLarge.setInt(
            SourceNetworkedIntValue(sourceFloatBitPattern: 1),
            forKey: SourceNetworkVariableString(bytes: [])
        )
        let aggregatePolicy = SourceNetworkVariableAllocationPolicy(
            maximumEntryCount: 2,
            maximumAggregateStoredBytes: 11,
            maximumKeyBytes: 4,
            maximumStringValueBytes: 4
        )
        assertAllocationError(
            .aggregateStoredByteCountExceeded(actual: 12, maximum: 11),
            from: {
                try aggregateTooLarge.validate(
                    allocationPolicy: aggregatePolicy
                )
            }
        )
    }

    func testRejectedCandidateDoesNotMutateStateJournalOrClient() throws {
        let transport = GMLuaNetTransport()
        let shared = GMLuaSharedSession(netTransport: transport)
        let server = makeRuntime(.server, transport: transport)
        let client = makeRuntime(.client, transport: transport)
        let policy = SourceNetworkVariableAllocationPolicy(
            maximumEntryCount: 1,
            maximumAggregateStoredBytes: 5,
            maximumKeyBytes: 1,
            maximumStringValueBytes: 4
        )
        let adapter = try GMLuaSourceRuntimeAdapter(
            serverRuntime: server,
            initialEntitySerialNumber: 41,
            canonicalNetworkVariableAllocationPolicy: policy
        )
        defer {
            try? shared.disconnect(client: client)
            try? adapter.close()
            _ = client.close()
            _ = server.close()
        }

        try installNoopHooks(in: server)
        try installNoopHooks(in: client)
        try adapter.installCanonicalEntityLuaBridge()
        try adapter.attach(client: client)
        let player = try adapter.createCanonicalEntity(
            kind: .player,
            at: 1,
            playerUserID: 301
        )
        let prop = try adapter.createCanonicalEntity(kind: .propPhysics, at: 20)
        try shared.connectCanonical(
            server: server,
            client: client,
            playerIdentity: player.identity,
            userID: 301,
            authoritativeSnapshots: adapter.canonicalEntitySnapshots
        )
        _ = try adapter.discardPendingCanonicalEntityOperations()
        XCTAssertEqual(try shared.pump(), 1)

        let key = SourceNetworkVariableString(bytes: [0xFF])
        var latest = try adapter.setCanonicalNetworkedString(
            SourceNetworkVariableString(bytes: [0x80, 0x00, 0xFE, 0x7F]),
            forKey: key,
            on: prop.identity
        )
        XCTAssertEqual(
            latest.networkVariables.allocationUsage,
            SourceNetworkVariableAllocationUsage(
                entryCount: 1,
                aggregateStoredBytes: 5
            )
        )

        // Different raw values replace one slot rather than retaining keys or
        // bytes from earlier full snapshots in canonical state.
        for byte in UInt8(1)...UInt8(4) {
            latest = try adapter.setCanonicalNetworkedString(
                SourceNetworkVariableString(bytes: [byte, 0, 0, 0]),
                forKey: key,
                on: prop.identity
            )
            XCTAssertEqual(latest.networkVariables.stringEntries.count, 1)
            XCTAssertEqual(latest.networkVariables.allocationUsage.entryCount, 1)
            XCTAssertEqual(
                latest.networkVariables.allocationUsage.aggregateStoredBytes,
                5
            )
        }
        let journalBeforeNoop = adapter.pendingCanonicalEntityOperationCount
        let noOp = try adapter.setCanonicalNetworkedString(
            SourceNetworkVariableString(bytes: [4, 0, 0, 0]),
            forKey: key,
            on: prop.identity
        )
        XCTAssertEqual(noOp, latest)
        XCTAssertEqual(
            adapter.pendingCanonicalEntityOperationCount,
            journalBeforeNoop
        )

        var publishedOperations: [SourceEntityReplicationOperation] = []
        XCTAssertEqual(
            try adapter.publishPendingCanonicalEntityOperations {
                publishedOperations = $0
                return try shared.publishCanonicalEntityUpdates($0)
            },
            1
        )
        XCTAssertEqual(publishedOperations.count, 5)
        for operation in publishedOperations {
            guard case let .update(snapshot) = operation else {
                return XCTFail("NW overwrite journal must contain updates")
            }
            XCTAssertEqual(
                snapshot.networkVariables.allocationUsage,
                SourceNetworkVariableAllocationUsage(
                    entryCount: 1,
                    aggregateStoredBytes: 5
                )
            )
        }
        XCTAssertEqual(try shared.pump(), 1)
        let clientBeforeRejection = try XCTUnwrap(
            client.entityRegistry?.canonicalSnapshot(at: 20)
        )
        let serverBeforeRejection = try XCTUnwrap(
            adapter.canonicalSnapshot(for: prop.identity)
        )
        XCTAssertEqual(adapter.pendingCanonicalEntityOperationCount, 0)

        assertAllocationError(
            .stringValueByteCountExceeded(actual: 5, maximum: 4),
            from: {
                _ = try adapter.setCanonicalNetworkedString(
                    SourceNetworkVariableString(bytes: [0, 1, 2, 3, 4]),
                    forKey: key,
                    on: prop.identity
                )
            }
        )
        XCTAssertEqual(
            adapter.canonicalSnapshot(for: prop.identity),
            serverBeforeRejection
        )
        XCTAssertEqual(
            server.entityRegistry?.canonicalSnapshot(at: 20),
            serverBeforeRejection
        )
        XCTAssertEqual(adapter.pendingCanonicalEntityOperationCount, 0)
        XCTAssertEqual(try shared.pump(), 0)
        XCTAssertEqual(
            client.entityRegistry?.canonicalSnapshot(at: 20),
            clientBeforeRejection
        )
    }

    func testRemovalAndIndexReuseStartsWithAnEmptyBudget() throws {
        let policy = SourceNetworkVariableAllocationPolicy(
            maximumEntryCount: 1,
            maximumAggregateStoredBytes: 2,
            maximumKeyBytes: 1,
            maximumStringValueBytes: 1
        )
        let store = SourceCanonicalEntityStore(
            entityList: SourceEntityList(initialSerialNumber: 7),
            networkVariableAllocationPolicy: policy
        )
        let original = try store.create(kind: .propPhysics, at: 20)
        let key = SourceNetworkVariableString(bytes: [0xFF])
        _ = try store.update(original.identity) { candidate in
            _ = candidate.networkVariables.setString(
                SourceNetworkVariableString(bytes: [0x80]),
                forKey: key
            )
        }
        _ = try store.markForRemoval(original.identity)
        XCTAssertEqual(
            store.cleanupDeferredRemovals().map(\.identity),
            [original.identity]
        )

        let replacement = try store.create(kind: .propPhysics, at: 20)
        XCTAssertNotEqual(replacement.identity, original.identity)
        XCTAssertEqual(
            replacement.networkVariables.allocationUsage,
            SourceNetworkVariableAllocationUsage(
                entryCount: 0,
                aggregateStoredBytes: 0
            )
        )
        let filledReplacement = try store.update(replacement.identity) { candidate in
            _ = candidate.networkVariables.setString(
                SourceNetworkVariableString(bytes: [0x81]),
                forKey: key
            )
        }
        XCTAssertEqual(
            filledReplacement.networkVariables.allocationUsage,
            SourceNetworkVariableAllocationUsage(
                entryCount: 1,
                aggregateStoredBytes: 2
            )
        )
    }

    private func assertAllocationError(
        _ expected: SourceNetworkVariableAllocationError,
        from operation: () throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            XCTAssertEqual(
                error as? SourceNetworkVariableAllocationError,
                expected,
                file: file,
                line: line
            )
        }
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
            """,
            sourceName: "=(NW allocation no-op hooks)"
        )
    }
}
