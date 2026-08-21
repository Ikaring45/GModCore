import Dispatch
import Foundation
import XCTest
@testable import GModEngine
import GModLua

private final class DeliveryTransactionAsyncResult: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Result<Void, Error>?

    func record(_ result: Result<Void, Error>) {
        lock.lock()
        storage = result
        lock.unlock()
    }

    var value: Result<Void, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private enum DeliveryTransactionIntentionalError: Error {
    case rollback
}

final class GMLuaNetTransportDeliveryTransactionTests: XCTestCase {
    func testCommitMergesStagedDeliveryBetweenExistingAndConcurrentSequences() throws {
        let pair = try makeConnectedPair()
        defer {
            _ = pair.client.close()
            _ = pair.server.close()
        }
        try installNetDispatch(in: pair.server)
        try installNetDispatch(in: pair.client)
        try pair.server.execute(
            """
            util.AddNetworkString("transaction_preexisting")
            util.AddNetworkString("transaction_staged")
            util.AddNetworkString("transaction_concurrent")
            SERVER_CONCURRENT_COUNT = 0
            net.Receive("transaction_concurrent", function()
                SERVER_CONCURRENT_COUNT = SERVER_CONCURRENT_COUNT + 1
            end)
            """,
            sourceName: "=(delivery transaction server setup)"
        )
        try pair.client.execute(
            """
            CLIENT_PREEXISTING_COUNT = 0
            CLIENT_STAGED_COUNT = 0
            net.Receive("transaction_preexisting", function()
                CLIENT_PREEXISTING_COUNT = CLIENT_PREEXISTING_COUNT + 1
            end)
            net.Receive("transaction_staged", function()
                CLIENT_STAGED_COUNT = CLIENT_STAGED_COUNT + 1
            end)
            """,
            sourceName: "=(delivery transaction client setup)"
        )

        try pair.server.execute(
            "net.Start('transaction_preexisting'); net.Broadcast()",
            sourceName: "=(delivery transaction preexisting packet)"
        )
        XCTAssertEqual(pair.transport.pendingDeliveryCount, 1)
        XCTAssertEqual(pair.transport.completedMessageCount, 1)

        let workerFinished = DispatchSemaphore(value: 0)
        let workerResult = DeliveryTransactionAsyncResult()
        try pair.transport.withStagedForwardedConsoleDeliveries {
            try pair.server.execute(
                "net.Start('transaction_staged'); net.Broadcast()",
                sourceName: "=(delivery transaction staged packet)"
            )
            XCTAssertEqual(
                pair.transport.pendingDeliveryCount,
                1,
                "current-thread staged work must remain invisible before commit"
            )
            XCTAssertEqual(pair.transport.completedMessageCount, 1)

            DispatchQueue(label: "GMLuaNetTransportDeliveryTransactionTests.concurrent")
                .async {
                    workerResult.record(Result {
                        try pair.client.execute(
                            "net.Start('transaction_concurrent'); net.SendToServer()",
                            sourceName: "=(delivery transaction concurrent packet)"
                        )
                    })
                    workerFinished.signal()
                }
            guard workerFinished.wait(timeout: .now() + 2) == .success else {
                return XCTFail("concurrent transport producer did not finish")
            }
            try XCTUnwrap(workerResult.value).get()
            XCTAssertEqual(
                pair.transport.pendingDeliveryCount,
                2,
                "another thread must enqueue normally while this thread stages"
            )
            XCTAssertEqual(
                pair.transport.completedMessageCount,
                2,
                "only the staged message count must remain hidden"
            )
        }

        XCTAssertEqual(pair.transport.pendingDeliveryCount, 3)
        XCTAssertEqual(pair.transport.completedMessageCount, 3)

        XCTAssertEqual(try pair.transport.pump(maxDeliveries: 1), 1)
        try pair.client.execute(
            "assert(CLIENT_PREEXISTING_COUNT == 1 and CLIENT_STAGED_COUNT == 0)"
        )
        try pair.server.execute("assert(SERVER_CONCURRENT_COUNT == 0)")

        XCTAssertEqual(try pair.transport.pump(maxDeliveries: 1), 1)
        try pair.client.execute(
            "assert(CLIENT_PREEXISTING_COUNT == 1 and CLIENT_STAGED_COUNT == 1)"
        )
        try pair.server.execute("assert(SERVER_CONCURRENT_COUNT == 0)")

        XCTAssertEqual(try pair.transport.pump(maxDeliveries: 1), 1)
        try pair.server.execute("assert(SERVER_CONCURRENT_COUNT == 1)")
        XCTAssertEqual(pair.transport.pendingDeliveryCount, 0)
    }

    func testThrowRollsBackVisibilityAndCompletedMessageCount() throws {
        let pair = try makeConnectedPair()
        defer {
            _ = pair.client.close()
            _ = pair.server.close()
        }
        try installNetDispatch(in: pair.client)
        try pair.server.execute(
            "util.AddNetworkString('transaction_rollback')",
            sourceName: "=(delivery transaction rollback server setup)"
        )
        try pair.client.execute(
            """
            TRANSACTION_ROLLBACK_COUNT = 0
            net.Receive("transaction_rollback", function()
                TRANSACTION_ROLLBACK_COUNT = TRANSACTION_ROLLBACK_COUNT + 1
            end)
            """,
            sourceName: "=(delivery transaction rollback client setup)"
        )

        XCTAssertThrowsError(
            try pair.transport.withStagedForwardedConsoleDeliveries {
                try pair.server.execute(
                    "net.Start('transaction_rollback'); net.Broadcast()",
                    sourceName: "=(delivery transaction rolled back packet)"
                )
                XCTAssertEqual(pair.transport.pendingDeliveryCount, 0)
                XCTAssertEqual(pair.transport.completedMessageCount, 0)
                throw DeliveryTransactionIntentionalError.rollback
            }
        ) { error in
            guard case DeliveryTransactionIntentionalError.rollback = error else {
                return XCTFail("unexpected transaction error: \(error)")
            }
        }
        XCTAssertEqual(pair.transport.pendingDeliveryCount, 0)
        XCTAssertEqual(pair.transport.completedMessageCount, 0)
        XCTAssertEqual(try pair.transport.pump(), 0)
        try pair.client.execute("assert(TRANSACTION_ROLLBACK_COUNT == 0)")

        try pair.server.execute(
            "net.Start('transaction_rollback'); net.Broadcast()",
            sourceName: "=(delivery transaction post-rollback packet)"
        )
        XCTAssertEqual(pair.transport.pendingDeliveryCount, 1)
        XCTAssertEqual(pair.transport.completedMessageCount, 1)
        XCTAssertEqual(try pair.transport.pump(), 1)
        try pair.client.execute("assert(TRANSACTION_ROLLBACK_COUNT == 1)")
    }

    func testNestedScopeIsRejectedAndOuterScopeRollsBack() throws {
        let transport = GMLuaNetTransport()
        XCTAssertThrowsError(
            try transport.withStagedForwardedConsoleDeliveries {
                try transport.withStagedForwardedConsoleDeliveries {}
            }
        ) { error in
            XCTAssertEqual(
                error as? GMLuaNetTransportDeliveryTransactionError,
                .nestedTransaction
            )
        }
        XCTAssertEqual(transport.pendingDeliveryCount, 0)
        XCTAssertEqual(transport.completedMessageCount, 0)
    }

    private func makeConnectedPair() throws -> (
        session: GMLuaSharedSession,
        transport: GMLuaNetTransport,
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
        try session.connect(
            server: server,
            client: client,
            playerIndex: 1,
            userID: 101
        )
        return (session, session.netTransport, server, client)
    }

    private func installNetDispatch(in runtime: GMLuaRuntime) throws {
        try runtime.execute(
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
            sourceName: "=(delivery transaction net dispatch)"
        )
    }
}
