import XCTest
@testable import GModEngine
import GModLua

final class GMLuaPlayerConCommandTransportTests: XCTestCase {
    func testParsedCommandsShareGlobalFIFOAndKeepTwoClientsIsolated() throws {
        let harness = try makeTwoClientHarness()
        defer { close(harness) }
        try installTargetCommand(in: harness.first)
        try installTargetCommand(in: harness.second)

        try harness.server.execute(
            #"""
            Player(101):SendLua([[table.insert(TARGET_EVENTS, "send-a")]])
            Player(101):ConCommand([[target_append "one two"; target_append three
            ]])
            Player(202):ConCommand([[target_append second]])
            Player(101):SendLua([[table.insert(TARGET_EVENTS, "send-c")]])
            """#,
            sourceName: "=(targeted ConCommand mixed FIFO enqueue)"
        )

        XCTAssertEqual(harness.transport.pendingDeliveryCount, 5)
        try assertEvents([], in: harness.first)
        try assertEvents([], in: harness.second)

        XCTAssertEqual(try harness.session.pump(maxDeliveries: 1), 1)
        try assertEvents(["send-a"], in: harness.first)
        try assertEvents([], in: harness.second)

        XCTAssertEqual(try harness.session.pump(maxDeliveries: 1), 1)
        try assertEvents(["send-a", "one two"], in: harness.first)
        try assertEvents([], in: harness.second)

        XCTAssertEqual(try harness.session.pump(maxDeliveries: 1), 1)
        try assertEvents(["send-a", "one two", "three"], in: harness.first)
        try assertEvents([], in: harness.second)

        XCTAssertEqual(try harness.session.pump(maxDeliveries: 1), 1)
        try assertEvents(["send-a", "one two", "three"], in: harness.first)
        try assertEvents(["second"], in: harness.second)

        XCTAssertEqual(try harness.session.pump(maxDeliveries: 1), 1)
        try assertEvents(
            ["send-a", "one two", "three", "send-c"],
            in: harness.first
        )
        try assertEvents(["second"], in: harness.second)
        XCTAssertEqual(harness.transport.pendingDeliveryCount, 0)

        let report = try XCTUnwrap(harness.server.consoleCommandDispatcher)
            .drainPlayerConsoleCommandRequestReport()
        XCTAssertEqual(report.requests.map(\.playerIndex), [1, 2])
        XCTAssertEqual(
            report.requests.map(\.outcome),
            [.dispatched(commandCount: 2), .dispatched(commandCount: 1)]
        )
    }

    func testDisconnectPurgesGenerationAndStaleServerPlayerCannotRetarget()
        throws
    {
        let harness = try makeOneClientHarness()
        defer { close(harness) }
        try installTargetCommand(in: harness.client)

        try harness.server.execute(
            """
            OLD_TARGET_PLAYER = Player(101)
            OLD_TARGET_PLAYER:ConCommand("target_append old")
            """,
            sourceName: "=(old targeted ConCommand generation enqueue)"
        )
        XCTAssertEqual(harness.transport.pendingDeliveryCount, 1)

        try harness.session.disconnect(client: harness.client)
        XCTAssertEqual(
            harness.transport.pendingDeliveryCount,
            0,
            "disconnect must purge the exact old destination generation"
        )
        try assertEvents([], in: harness.client)

        try harness.session.connect(
            server: harness.server,
            client: harness.client,
            playerIndex: 1,
            userID: 101
        )
        try harness.server.execute(
            """
            local ok, message = pcall(
                OLD_TARGET_PLAYER.ConCommand,
                OLD_TARGET_PLAYER,
                "target_append stale"
            )
            assert(ok == false)
            assert(string.find(message, "current connected Player", 1, true))
            Player(101):ConCommand("target_append fresh")
            """,
            sourceName: "=(stale targeted ConCommand generation rejection)"
        )
        XCTAssertEqual(
            harness.transport.pendingDeliveryCount,
            1,
            "stale SERVER Player must not enqueue against the replacement"
        )
        XCTAssertEqual(try harness.session.pump(), 1)
        try assertEvents(["fresh"], in: harness.client)
    }

    func testFailedOuterForwardedActionRollsBackTargetedDelivery() throws {
        let harness = try makeOneClientHarness()
        let adapter = try GMLuaSourceRuntimeAdapter(
            serverRuntime: harness.server,
            canonicalModelValidator: nil
        )
        defer {
            try? adapter.close()
            close(harness)
        }
        try installTargetCommand(in: harness.client)

        try harness.server.execute(
            """
            TARGET_SERVER_ATTEMPTS = 0
            TARGET_SERVER_SHOULD_FAIL = true
            concommand = {}
            function concommand.Run(sender, command)
                assert(sender == Player(101))
                assert(command == "target_transaction")
                TARGET_SERVER_ATTEMPTS = TARGET_SERVER_ATTEMPTS + 1
                sender:ConCommand("target_append attempt")
                if TARGET_SERVER_SHOULD_FAIL then
                    error("intentional targeted action failure")
                end
            end
            AddConsoleCommand("target_transaction")
            """,
            sourceName: "=(targeted ConCommand transaction setup)"
        )

        try harness.client.execute("RunConsoleCommand('target_transaction')")
        XCTAssertThrowsError(
            try harness.session.pump(maxDeliveries: 1)
        ) { error in
            XCTAssertTrue(
                GMLuaRuntime.describe(error).contains(
                    "intentional targeted action failure"
                )
            )
        }
        XCTAssertEqual(harness.transport.pendingDeliveryCount, 0)
        try assertEvents([], in: harness.client)
        try harness.server.execute("assert(TARGET_SERVER_ATTEMPTS == 1)")

        try harness.server.execute("TARGET_SERVER_SHOULD_FAIL = false")
        try harness.client.execute("RunConsoleCommand('target_transaction')")
        XCTAssertEqual(try harness.session.pump(maxDeliveries: 1), 1)
        XCTAssertEqual(harness.transport.pendingDeliveryCount, 1)
        try assertEvents([], in: harness.client)

        XCTAssertEqual(try harness.session.pump(maxDeliveries: 1), 1)
        try assertEvents(["attempt"], in: harness.client)
        try harness.server.execute("assert(TARGET_SERVER_ATTEMPTS == 2)")
        XCTAssertEqual(harness.transport.pendingDeliveryCount, 0)
    }

    private func installTargetCommand(in runtime: GMLuaRuntime) throws {
        try runtime.execute(
            """
            TARGET_EVENTS = {}
            concommand = {}
            function concommand.Run(sender, command, arguments, argumentString)
                assert(sender == LocalPlayer())
                assert(command == "target_append")
                assert(#arguments == 1)
                assert(argumentString == arguments[1])
                table.insert(TARGET_EVENTS, arguments[1])
            end
            AddConsoleCommand("target_append")
            """,
            sourceName: "=(targeted CLIENT command setup)"
        )
    }

    private func assertEvents(
        _ expected: [String],
        in runtime: GMLuaRuntime,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let values = try runtime.executeReturningValues(
            "return table.concat(TARGET_EVENTS, '\\0')",
            sourceName: "=(targeted CLIENT event snapshot)"
        )
        XCTAssertEqual(
            values.first?.printable,
            expected.joined(separator: "\0"),
            file: file,
            line: line
        )
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
