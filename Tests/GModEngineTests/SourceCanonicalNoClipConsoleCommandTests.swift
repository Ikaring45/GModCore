@testable import GModEngine
import XCTest

final class SourceCanonicalNoClipConsoleCommandTests: XCTestCase {
    func testOwnershipAndFullHandleFailuresAreTypedAndDoNotMutate() throws {
        let transport = GMLuaNetTransport()
        let server = GMLuaRuntime(
            realm: .server,
            logger: { _ in },
            netTransport: transport
        )
        let adapter = try GMLuaSourceRuntimeAdapter(
            serverRuntime: server,
            initialEntitySerialNumber: 51
        )
        defer {
            try? adapter.close()
            _ = server.close()
        }
        let player = try adapter.createCanonicalEntity(
            kind: .player,
            at: 1,
            playerUserID: 101
        )
        _ = try adapter.discardPendingCanonicalEntityOperations()

        XCTAssertEqual(
            try SourceCanonicalNoClipConsoleCommand.handle(
                invocation(command: "status"),
                adapter: adapter,
                playerIdentity: player.identity
            ),
            .unhandled
        )
        XCTAssertEqual(
            try SourceCanonicalNoClipConsoleCommand.handle(
                invocation(command: "NoClIp", arguments: ["1"]),
                adapter: adapter,
                playerIdentity: player.identity
            ),
            .rejected(.requiresNoArguments(actualCount: 1))
        )
        XCTAssertThrowsError(
            try SourceCanonicalNoClipConsoleCommand.handle(
                invocation(realm: .client, command: "noclip"),
                adapter: adapter,
                playerIdentity: player.identity
            )
        ) { error in
            XCTAssertEqual(
                error as? SourceCanonicalNoClipConsoleHostError,
                .serverInvocationRequired(.client)
            )
        }

        let staleIdentity = SourceCanonicalEntityIdentity(
            handle: SourceBaseHandle(
                entryIndex: player.identity.entryIndex,
                serialNumber: (player.identity.serialNumber + 1) &
                    SourceEntityConstants.serialMask
            )
        )
        XCTAssertThrowsError(
            try SourceCanonicalNoClipConsoleCommand.handle(
                invocation(command: "noclip"),
                adapter: adapter,
                playerIdentity: staleIdentity
            )
        ) { error in
            XCTAssertEqual(
                error as? SourceCanonicalNoClipConsoleHostError,
                .canonicalPlayerUnavailable(staleIdentity)
            )
        }
        XCTAssertEqual(adapter.canonicalSnapshot(for: player.identity), player)
        XCTAssertEqual(adapter.pendingCanonicalEntityOperationCount, 0)
    }

    private func invocation(
        realm: GMLuaRealm = .server,
        command: String,
        arguments: [String] = []
    ) -> GMLuaConsoleCommandInvocation {
        GMLuaConsoleCommandInvocation(
            realm: realm,
            command: command,
            arguments: arguments
        )
    }
}
