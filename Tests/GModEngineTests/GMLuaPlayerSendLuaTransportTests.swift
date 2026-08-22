import XCTest
@testable import GModEngine
import GModLua

final class GMLuaPlayerSendLuaTransportTests: XCTestCase {
    func testExactTargetCodeIsInvisibleUntilPumpAndTwoClientsStayIsolated() throws {
        let harness = try makeTwoClientHarness()
        defer { close(harness) }
        let completedBefore = harness.transport.completedMessageCount

        try harness.server.execute(
            #"""
            Player(101):SendLua([[SENDLUA_ORDER = (SENDLUA_ORDER or "") .. "一"]])
            Player(202):SendLua([[SENDLUA_ORDER = (SENDLUA_ORDER or "") .. "二"]])
            Player(101):SendLua([[SENDLUA_ORDER = SENDLUA_ORDER .. "三"]])
            """#,
            sourceName: "=(Player SendLua two-client enqueue)"
        )

        XCTAssertEqual(harness.transport.pendingDeliveryCount, 3)
        XCTAssertEqual(
            harness.transport.completedMessageCount,
            completedBefore,
            "SendLua is a FIFO delivery, not one completed net writer message"
        )
        try harness.first.execute("assert(SENDLUA_ORDER == nil)")
        try harness.second.execute("assert(SENDLUA_ORDER == nil)")

        XCTAssertEqual(try harness.session.pump(maxDeliveries: 1), 1)
        try harness.first.execute("assert(SENDLUA_ORDER == '一')")
        try harness.second.execute("assert(SENDLUA_ORDER == nil)")

        XCTAssertEqual(try harness.session.pump(maxDeliveries: 1), 1)
        try harness.first.execute("assert(SENDLUA_ORDER == '一')")
        try harness.second.execute("assert(SENDLUA_ORDER == '二')")

        XCTAssertEqual(try harness.session.pump(maxDeliveries: 1), 1)
        try harness.first.execute("assert(SENDLUA_ORDER == '一三')")
        try harness.second.execute("assert(SENDLUA_ORDER == '二')")
        XCTAssertEqual(harness.transport.pendingDeliveryCount, 0)
    }

    func testCodeLimitCountsExactLuaBytesAndRejectsBeforeEnqueue() throws {
        let harness = try makeOneClientHarness()
        defer { close(harness) }
        let endpoint = try XCTUnwrap(harness.server.netEndpoint)
        let prefix = "SENDLUA_LIMIT_ACCEPTED = true --"
        let exactLimitSource = prefix + String(
            repeating: "x",
            count: GMLuaNetTransport.maximumSendLuaCodeBytes - prefix.utf8.count
        )
        let exactLimitCode = LuaString(exactLimitSource)
        XCTAssertEqual(
            exactLimitCode.count,
            GMLuaNetTransport.maximumSendLuaCodeBytes
        )

        try harness.transport.enqueueClientLua(
            exactLimitCode,
            from: endpoint,
            toPlayerIndex: 1
        )
        XCTAssertEqual(harness.transport.pendingDeliveryCount, 1)

        let oversizedCode = LuaString(
            exactLimitSource + "x"
        )
        XCTAssertThrowsError(
            try harness.transport.enqueueClientLua(
                oversizedCode,
                from: endpoint,
                toPlayerIndex: 1
            )
        ) { error in
            XCTAssertTrue(
                GMLuaRuntime.describe(error).contains("6000-byte limit")
            )
        }
        XCTAssertEqual(
            harness.transport.pendingDeliveryCount,
            1,
            "rejected source must not reserve a visible delivery"
        )
        try harness.client.execute("assert(SENDLUA_LIMIT_ACCEPTED == nil)")

        XCTAssertEqual(try harness.session.pump(), 1)
        try harness.client.execute("assert(SENDLUA_LIMIT_ACCEPTED == true)")
    }

    func testDisconnectPurgesOldGenerationBeforeReconnect() throws {
        let harness = try makeOneClientHarness()
        defer { close(harness) }

        try harness.server.execute(
            "Player(101):SendLua([[SENDLUA_GENERATION = 'old']])"
        )
        XCTAssertEqual(harness.transport.pendingDeliveryCount, 1)

        try harness.session.disconnect(client: harness.client)
        XCTAssertEqual(
            harness.transport.pendingDeliveryCount,
            0,
            "disconnect must purge the old generation's queued code"
        )
        try harness.client.execute("assert(SENDLUA_GENERATION == nil)")

        try harness.session.connect(
            server: harness.server,
            client: harness.client,
            playerIndex: 1,
            userID: 101
        )
        try harness.server.execute(
            "Player(101):SendLua([[SENDLUA_GENERATION = 'new']])"
        )
        XCTAssertEqual(harness.transport.pendingDeliveryCount, 1)
        XCTAssertEqual(try harness.session.pump(), 1)
        try harness.client.execute("assert(SENDLUA_GENERATION == 'new')")
    }

    func testFailedOuterForwardedActionDiscardsCodeAndRetryExecutesOnce() throws {
        let harness = try makeOneClientHarness()
        let adapter = try GMLuaSourceRuntimeAdapter(
            serverRuntime: harness.server,
            canonicalModelValidator: nil
        )
        defer {
            try? adapter.close()
            close(harness)
        }

        try harness.server.execute(
            """
            SENDLUA_SERVER_ATTEMPTS = 0
            SENDLUA_SERVER_SHOULD_FAIL = true
            concommand = {}
            function concommand.Run(sender, command)
                assert(sender == Player(101))
                assert(command == "sendlua_transaction")
                SENDLUA_SERVER_ATTEMPTS = SENDLUA_SERVER_ATTEMPTS + 1
                sender:SendLua([[
                    SENDLUA_TRANSACTION_EXECUTIONS =
                        (SENDLUA_TRANSACTION_EXECUTIONS or 0) + 1
                ]])
                if SENDLUA_SERVER_SHOULD_FAIL then
                    error("intentional SendLua action failure")
                end
            end
            AddConsoleCommand("sendlua_transaction")
            """,
            sourceName: "=(Player SendLua forwarded action setup)"
        )

        try harness.client.execute(
            "RunConsoleCommand('sendlua_transaction')"
        )
        XCTAssertThrowsError(
            try harness.session.pump(maxDeliveries: 1)
        ) { error in
            XCTAssertTrue(
                GMLuaRuntime.describe(error).contains(
                    "intentional SendLua action failure"
                )
            )
        }
        XCTAssertEqual(harness.transport.pendingDeliveryCount, 0)
        try harness.client.execute(
            "assert(SENDLUA_TRANSACTION_EXECUTIONS == nil)"
        )
        try harness.server.execute("assert(SENDLUA_SERVER_ATTEMPTS == 1)")

        try harness.server.execute("SENDLUA_SERVER_SHOULD_FAIL = false")
        try harness.client.execute(
            "RunConsoleCommand('sendlua_transaction')"
        )
        XCTAssertEqual(try harness.session.pump(maxDeliveries: 1), 1)
        XCTAssertEqual(harness.transport.pendingDeliveryCount, 1)
        try harness.client.execute(
            "assert(SENDLUA_TRANSACTION_EXECUTIONS == nil)"
        )

        XCTAssertEqual(try harness.session.pump(maxDeliveries: 1), 1)
        try harness.client.execute(
            "assert(SENDLUA_TRANSACTION_EXECUTIONS == 1)"
        )
        try harness.server.execute("assert(SENDLUA_SERVER_ATTEMPTS == 2)")
        XCTAssertEqual(harness.transport.pendingDeliveryCount, 0)
    }

    private func makeOneClientHarness() throws -> OneClientHarness {
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
        try session.connect(
            server: server,
            client: client,
            playerIndex: 1,
            userID: 101
        )
        return OneClientHarness(
            session: session,
            transport: session.netTransport,
            server: server,
            client: client
        )
    }

    private func makeTwoClientHarness() throws -> TwoClientHarness {
        let session = GMLuaSharedSession()
        let server = GMLuaRuntime(
            realm: .server,
            logger: { _ in },
            netTransport: session.netTransport
        )
        let first = GMLuaRuntime(
            realm: .client,
            logger: { _ in },
            netTransport: session.netTransport
        )
        let second = GMLuaRuntime(
            realm: .client,
            logger: { _ in },
            netTransport: session.netTransport
        )
        try session.connect(
            server: server,
            client: first,
            playerIndex: 1,
            userID: 101
        )
        try session.connect(
            server: server,
            client: second,
            playerIndex: 2,
            userID: 202
        )
        return TwoClientHarness(
            session: session,
            transport: session.netTransport,
            server: server,
            first: first,
            second: second
        )
    }

    private func close(_ harness: OneClientHarness) {
        _ = harness.client.close()
        _ = harness.server.close()
    }

    private func close(_ harness: TwoClientHarness) {
        _ = harness.first.close()
        _ = harness.second.close()
        _ = harness.server.close()
    }

    private struct OneClientHarness {
        let session: GMLuaSharedSession
        let transport: GMLuaNetTransport
        let server: GMLuaRuntime
        let client: GMLuaRuntime
    }

    private struct TwoClientHarness {
        let session: GMLuaSharedSession
        let transport: GMLuaNetTransport
        let server: GMLuaRuntime
        let first: GMLuaRuntime
        let second: GMLuaRuntime
    }
}
