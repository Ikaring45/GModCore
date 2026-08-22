import XCTest
@testable import GModEngine

final class SourceCanonicalWeaponUseConsoleCommandTests: XCTestCase {
    func testOwnershipValidationReturnsTypedRejectionsWithoutMutation()
        throws
    {
        let transport = GMLuaNetTransport()
        let server = GMLuaRuntime(
            realm: .server,
            logger: { _ in },
            netTransport: transport
        )
        let adapter = try GMLuaSourceRuntimeAdapter(
            serverRuntime: server,
            initialEntitySerialNumber: 21
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
            try SourceCanonicalWeaponUseConsoleCommand.handle(
                invocation(command: "status", arguments: []),
                adapter: adapter,
                playerIdentity: player.identity
            ),
            .unhandled
        )
        XCTAssertEqual(
            try SourceCanonicalWeaponUseConsoleCommand.handle(
                invocation(command: "USE", arguments: []),
                adapter: adapter,
                playerIdentity: player.identity
            ),
            .rejected(.requiresExactlyOneArgument(actualCount: 0))
        )
        XCTAssertEqual(
            try SourceCanonicalWeaponUseConsoleCommand.handle(
                invocation(
                    command: "uSe",
                    arguments: ["weapon_one", "weapon_two"]
                ),
                adapter: adapter,
                playerIdentity: player.identity
            ),
            .rejected(.requiresExactlyOneArgument(actualCount: 2))
        )
        XCTAssertEqual(
            try SourceCanonicalWeaponUseConsoleCommand.handle(
                invocation(command: "use", arguments: ["weapon/bad"]),
                adapter: adapter,
                playerIdentity: player.identity
            ),
            .rejected(.invalidWeaponClassName)
        )
        XCTAssertEqual(
            adapter.canonicalSnapshot(for: player.identity),
            player
        )
        XCTAssertEqual(adapter.pendingCanonicalEntityOperationCount, 0)

        XCTAssertThrowsError(
            try SourceCanonicalWeaponUseConsoleCommand.handle(
                invocation(
                    realm: .client,
                    command: "use",
                    arguments: ["weapon_one"]
                ),
                adapter: adapter,
                playerIdentity: player.identity
            )
        ) { error in
            XCTAssertEqual(
                error as? SourceCanonicalWeaponUseConsoleHostError,
                .serverRealmRequired(.client)
            )
        }
    }

    func testOwnedSelectionUsesExactFullHandleAndOrderedCanonicalJournal()
        throws
    {
        let transport = GMLuaNetTransport()
        let server = GMLuaRuntime(
            realm: .server,
            logger: { _ in },
            netTransport: transport
        )
        let adapter = try GMLuaSourceRuntimeAdapter(
            serverRuntime: server,
            initialEntitySerialNumber: 31
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
        let firstWeapon = try adapter.giveCanonicalWeapon(
            className: "weapon_use_first",
            to: player.identity
        )
        let secondWeapon = try adapter.giveCanonicalWeapon(
            className: "weapon_use_second",
            to: player.identity
        )
        _ = try adapter.selectCanonicalWeapon(
            className: firstWeapon.className,
            for: player.identity
        )
        _ = try adapter.discardPendingCanonicalEntityOperations()

        let preceding = try adapter.updateCanonicalEntity(player.identity) {
            $0.transform.origin = SourceVector3(10, 20, 30)
        }
        XCTAssertEqual(
            try SourceCanonicalWeaponUseConsoleCommand.handle(
                invocation(
                    command: "UsE",
                    arguments: [secondWeapon.className.uppercased()]
                ),
                adapter: adapter,
                playerIdentity: player.identity
            ),
            .handled
        )

        let selected = try XCTUnwrap(
            adapter.canonicalSnapshot(for: player.identity)
        )
        XCTAssertEqual(
            selected.weaponInventory.activeWeapon,
            secondWeapon.identity
        )
        XCTAssertEqual(
            selected.weaponInventory.weapon(identity: secondWeapon.identity),
            SourceCanonicalWeaponRecord(
                identity: secondWeapon.identity,
                className: secondWeapon.className
            )
        )

        var published: [SourceEntityReplicationOperation] = []
        XCTAssertEqual(
            try adapter.publishPendingCanonicalEntityOperations { operations in
                published = operations
                return operations.count
            },
            2
        )
        XCTAssertEqual(published, [
            .update(preceding),
            .update(selected),
        ])

        let beforeUnownedUse = selected
        XCTAssertEqual(
            try SourceCanonicalWeaponUseConsoleCommand.handle(
                invocation(
                    command: "use",
                    arguments: ["weapon_not_owned"]
                ),
                adapter: adapter,
                playerIdentity: player.identity
            ),
            .handled
        )
        XCTAssertEqual(
            adapter.canonicalSnapshot(for: player.identity),
            beforeUnownedUse
        )
        XCTAssertEqual(adapter.pendingCanonicalEntityOperationCount, 0)
    }

    func testConsoleHostMapsRejectionButPropagatesAdapterInvariantError()
        throws
    {
        let transport = GMLuaNetTransport()
        let server = GMLuaRuntime(
            realm: .server,
            logger: { _ in },
            netTransport: transport
        )
        let adapter = try GMLuaSourceRuntimeAdapter(
            serverRuntime: server,
            initialEntitySerialNumber: 41
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
        let handler = SourceCanonicalWeaponUseConsoleCommand.makeHostHandler(
            adapter: adapter,
            playerIdentity: player.identity
        )
        let rejection = SourceCanonicalWeaponUseConsoleRejection
            .requiresExactlyOneArgument(actualCount: 0)
        XCTAssertEqual(
            try handler(invocation(command: "USE", arguments: [])),
            .rejected(reason: rejection.description)
        )

        try adapter.close()
        XCTAssertThrowsError(
            try handler(invocation(
                command: "use",
                arguments: ["weapon_any"]
            ))
        ) { error in
            guard case GMLuaSourceRuntimeAdapterError.closedAdapter = error else {
                return XCTFail("unexpected flattened error: \(error)")
            }
        }
    }

    private func invocation(
        realm: GMLuaRealm = .server,
        command: String,
        arguments: [String]
    ) -> GMLuaConsoleCommandInvocation {
        GMLuaConsoleCommandInvocation(
            realm: realm,
            command: command,
            arguments: arguments
        )
    }
}
