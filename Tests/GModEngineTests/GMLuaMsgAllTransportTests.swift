import Foundation
import XCTest
@testable import GModEngine

private final class LockedMsgAllLines: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ line: String) {
        lock.lock()
        storage.append(line)
        lock.unlock()
    }

    func drain() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let lines = storage
        storage.removeAll(keepingCapacity: true)
        return lines
    }
}

final class GMLuaMsgAllTransportTests: XCTestCase {
    func testServerMsgAllWritesServerAndConnectedClientConsolesThroughFIFO() throws {
        let session = GMLuaSharedSession()
        let serverLines = LockedMsgAllLines()
        let firstClientLines = LockedMsgAllLines()
        let secondClientLines = LockedMsgAllLines()
        let server = GMLuaRuntime(
            realm: .server,
            logger: { serverLines.append($0) },
            netTransport: session.netTransport
        )
        let firstClient = GMLuaRuntime(
            realm: .client,
            logger: { firstClientLines.append($0) },
            netTransport: session.netTransport
        )
        let secondClient = GMLuaRuntime(
            realm: .client,
            logger: { secondClientLines.append($0) },
            netTransport: session.netTransport
        )
        defer {
            _ = firstClient.close()
            _ = secondClient.close()
            _ = server.close()
        }

        try session.connect(
            server: server,
            client: firstClient,
            playerIndex: 1,
            userID: 101
        )
        try session.connect(
            server: server,
            client: secondClient,
            playerIndex: 2,
            userID: 202
        )
        _ = serverLines.drain()
        _ = firstClientLines.drain()
        _ = secondClientLines.drain()

        // MsgAll targets the engine console sink. A CLIENT Lua script cannot
        // intercept or break an accepted delivery by replacing global Msg.
        try firstClient.execute("Msg = nil")
        try secondClient.execute("Msg = function() error('must not run') end")

        try server.execute(
            "MsgAll('Giving Player a gmod_tool', 7, '\\n')",
            sourceName: "=(SERVER MsgAll broadcast)"
        )
        XCTAssertEqual(
            serverLines.drain(),
            ["[SERVER][Lua] Giving Player a gmod_tool7\n"]
        )
        XCTAssertEqual(firstClientLines.drain(), [])
        XCTAssertEqual(secondClientLines.drain(), [])
        XCTAssertEqual(session.netTransport.pendingDeliveryCount, 2)

        XCTAssertEqual(try session.pump(), 2)
        XCTAssertEqual(
            firstClientLines.drain(),
            ["[CLIENT][Lua] Giving Player a gmod_tool7\n"]
        )
        XCTAssertEqual(
            secondClientLines.drain(),
            ["[CLIENT][Lua] Giving Player a gmod_tool7\n"]
        )
        XCTAssertEqual(session.netTransport.pendingDeliveryCount, 0)

        // Outside SERVER, MsgAll is the same local, concatenating write as
        // Msg and must not manufacture another broadcast.
        try firstClient.execute("MsgAll('client', '-', 'only')")
        XCTAssertEqual(
            firstClientLines.drain(),
            ["[CLIENT][Lua] client-only"]
        )
        XCTAssertEqual(secondClientLines.drain(), [])
        XCTAssertEqual(session.netTransport.pendingDeliveryCount, 0)
    }
}
