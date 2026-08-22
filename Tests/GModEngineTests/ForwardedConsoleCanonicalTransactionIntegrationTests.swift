import XCTest
@testable import GModEngine
import GModLua

final class ForwardedConsoleCanonicalTransactionIntegrationTests: XCTestCase {
    private let model = SourceEntityModelReference(
        "models/props_c17/oildrum001.mdl"
    )

    func testStrictFailureRollsBackAndOneRetryCommitsNetBeforeEntity() throws {
        let harness = try makeHarness()
        defer { close(harness) }

        try assertFailureThenOneRetry(
            harness,
            reporting: false
        )
    }

    func testReportingFailureRollsBackAndOneRetryCommitsNetBeforeEntity() throws {
        let harness = try makeHarness()
        defer { close(harness) }

        try assertFailureThenOneRetry(
            harness,
            reporting: true
        )
    }

    func testLuaPCallCaughtBodyErrorCommitsOuterAction() throws {
        let harness = try makeHarness()
        defer { close(harness) }

        try harness.server.execute(
            "SERVER_TRANSACTION_CATCH_INNER = true; " +
                "SERVER_TRANSACTION_SHOULD_FAIL = false"
        )
        try harness.client.execute(
            "RunConsoleCommand('transaction_spawn_prop')"
        )

        XCTAssertEqual(try harness.session.pump(maxDeliveries: 1), 1)
        XCTAssertEqual(harness.transport.pendingDeliveryCount, 1)
        XCTAssertEqual(harness.transport.completedMessageCount, 1)
        XCTAssertGreaterThan(
            harness.adapter.pendingCanonicalEntityOperationCount,
            0
        )

        let index = try integerGlobal(
            "SERVER_TRANSACTION_LAST_INDEX",
            in: harness.server
        )
        XCTAssertEqual(
            harness.server.entityRegistry?.canonicalSnapshot(at: index)?.lifecycle,
            .active
        )
        XCTAssertNil(
            harness.client.entityRegistry?.canonicalSnapshot(at: index)
        )

        try publishPendingCanonicalOperations(harness)
        XCTAssertEqual(harness.transport.pendingDeliveryCount, 2)
        XCTAssertEqual(try harness.session.pump(maxDeliveries: 1), 1)
        try harness.client.execute(
            "assert(CLIENT_TRANSACTION_NET_COUNT == 1); " +
                "assert(CLIENT_TRANSACTION_VISIBLE_DURING_NET == false)"
        )
        XCTAssertEqual(try harness.session.pump(maxDeliveries: 1), 1)
        XCTAssertEqual(
            harness.client.entityRegistry?.canonicalSnapshot(at: index),
            harness.server.entityRegistry?.canonicalSnapshot(at: index)
        )
        try harness.server.execute(
            "assert(SERVER_TRANSACTION_ATTEMPTS == 1)"
        )
    }

    private func assertFailureThenOneRetry(
        _ harness: Harness,
        reporting: Bool
    ) throws {
        let preexistingPlayer = try harness.adapter.updateCanonicalEntity(
            harness.player.identity
        ) { candidate in
            candidate.skin = 3
        }
        XCTAssertEqual(
            harness.adapter.pendingCanonicalEntityOperationCount,
            1
        )
        let completedBeforeFailure = harness.transport.completedMessageCount

        try harness.client.execute(
            "RunConsoleCommand('transaction_spawn_prop')"
        )
        XCTAssertEqual(harness.transport.pendingDeliveryCount, 1)

        if reporting {
            let report = try harness.session
                .pumpReportingForwardedConsoleFailures(maxDeliveries: 1)
            XCTAssertEqual(report.processedDeliveries, 1)
            XCTAssertEqual(report.successfulDeliveries, 0)
            XCTAssertEqual(report.forwardedConsoleFailures.count, 1)
            XCTAssertEqual(
                report.forwardedConsoleFailures.first?.command,
                "transaction_spawn_prop"
            )
            XCTAssertTrue(
                report.forwardedConsoleFailures.first?.message.contains(
                    "intentional transaction body failure"
                ) == true
            )
        } else {
            XCTAssertThrowsError(
                try harness.session.pump(maxDeliveries: 1)
            ) { error in
                XCTAssertTrue(
                    GMLuaRuntime.describe(error).contains(
                        "intentional transaction body failure"
                    )
                )
            }
        }

        let failedIndex = try integerGlobal(
            "SERVER_TRANSACTION_LAST_INDEX",
            in: harness.server
        )
        XCTAssertNil(
            harness.server.entityRegistry?.canonicalSnapshot(at: failedIndex),
            "failed body must leave no authoritative SERVER ghost"
        )
        XCTAssertNil(
            harness.client.entityRegistry?.canonicalSnapshot(at: failedIndex),
            "failed body must leave no replicated CLIENT ghost"
        )
        XCTAssertEqual(
            harness.adapter.canonicalSnapshot(for: harness.player.identity),
            preexistingPlayer,
            "rollback must not remove or rewrite the pre-existing Player"
        )
        XCTAssertEqual(
            harness.adapter.pendingCanonicalEntityOperationCount,
            1,
            "rollback must preserve the exact pre-existing journal prefix"
        )
        XCTAssertEqual(harness.transport.pendingDeliveryCount, 0)
        XCTAssertEqual(
            harness.transport.completedMessageCount,
            completedBeforeFailure,
            "the failed body's completed net message must remain staged"
        )
        try harness.server.execute(
            "assert(SERVER_TRANSACTION_ATTEMPTS == 1)"
        )
        try harness.client.execute(
            "assert(CLIENT_TRANSACTION_NET_COUNT == 0)"
        )

        try harness.server.execute(
            "SERVER_TRANSACTION_SHOULD_FAIL = false"
        )
        try harness.client.execute(
            "RunConsoleCommand('transaction_spawn_prop')"
        )
        if reporting {
            let retry = try harness.session
                .pumpReportingForwardedConsoleFailures(maxDeliveries: 1)
            XCTAssertEqual(retry.processedDeliveries, 1)
            XCTAssertEqual(retry.successfulDeliveries, 1)
            XCTAssertEqual(retry.forwardedConsoleFailures, [])
        } else {
            XCTAssertEqual(try harness.session.pump(maxDeliveries: 1), 1)
        }

        try harness.server.execute(
            "assert(SERVER_TRANSACTION_ATTEMPTS == 2)"
        )
        let committedIndex = try integerGlobal(
            "SERVER_TRANSACTION_LAST_INDEX",
            in: harness.server
        )
        let authoritative = try XCTUnwrap(
            harness.server.entityRegistry?.canonicalSnapshot(at: committedIndex)
        )
        XCTAssertEqual(authoritative.lifecycle, .active)
        XCTAssertNil(
            harness.client.entityRegistry?.canonicalSnapshot(at: committedIndex)
        )
        XCTAssertEqual(harness.transport.pendingDeliveryCount, 1)
        XCTAssertEqual(
            harness.transport.completedMessageCount,
            completedBeforeFailure + 1
        )

        try publishPendingCanonicalOperations(harness)
        XCTAssertEqual(
            harness.transport.pendingDeliveryCount,
            2,
            "body net delivery must retain its earlier sequence than the entity delta"
        )

        XCTAssertEqual(try harness.session.pump(maxDeliveries: 1), 1)
        try harness.client.execute(
            "assert(CLIENT_TRANSACTION_NET_COUNT == 1); " +
                "assert(CLIENT_TRANSACTION_VISIBLE_DURING_NET == false)"
        )
        XCTAssertNil(
            harness.client.entityRegistry?.canonicalSnapshot(at: committedIndex)
        )

        XCTAssertEqual(try harness.session.pump(maxDeliveries: 1), 1)
        XCTAssertEqual(
            harness.client.entityRegistry?.canonicalSnapshot(at: committedIndex),
            authoritative
        )
        XCTAssertEqual(
            harness.client.entityRegistry?.canonicalSnapshot(
                at: harness.player.identity.entryIndex
            ),
            preexistingPlayer
        )
        XCTAssertEqual(
            harness.adapter.pendingCanonicalEntityOperationCount,
            0
        )
        XCTAssertEqual(harness.transport.pendingDeliveryCount, 0)
        XCTAssertEqual(
            harness.adapter.canonicalEntitySnapshots.filter {
                $0.kind == .propPhysics
            }.count,
            1,
            "one failed action plus exactly one retry must commit one prop"
        )
    }

    private func makeHarness() throws -> Harness {
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
        let propAsset = try makeAttestedPropPhysicsTestAsset(
            modelPath: model.path
        )
        let adapter = try GMLuaSourceRuntimeAdapter(
            serverRuntime: server,
            initialEntitySerialNumber: 9,
            canonicalModelValidator: { [model] candidate, kind in
                candidate == model && kind == .propPhysics ? .valid : .invalid
            },
            canonicalPropPhysicsAssetResolver:
                makeAttestedPropPhysicsTestResolver(asset: propAsset)
        )

        let world = try adapter.createCanonicalEntity(kind: .world, at: 0)
        let player = try adapter.createCanonicalEntity(
            kind: .player,
            at: 1,
            playerUserID: 101
        )
        try adapter.installCanonicalEntityLuaBridge()
        try session.connectCanonical(
            server: server,
            client: client,
            playerIdentity: player.identity,
            userID: 101,
            authoritativeSnapshots: [world, player]
        )
        XCTAssertEqual(try adapter.discardPendingCanonicalEntityOperations(), 2)
        XCTAssertEqual(try session.pump(), 1)

        try installNetDispatch(in: server)
        try installNetDispatch(in: client)
        try server.execute(
            """
            util.AddNetworkString("transaction_prop_observed")
            SERVER_TRANSACTION_ATTEMPTS = 0
            SERVER_TRANSACTION_SHOULD_FAIL = true
            SERVER_TRANSACTION_CATCH_INNER = false
            concommand = {}
            function concommand.Run(sender, command, arguments, argumentString)
                assert(sender == Player(101))
                assert(command == "transaction_spawn_prop")
                SERVER_TRANSACTION_ATTEMPTS = SERVER_TRANSACTION_ATTEMPTS + 1

                local prop = assert(ents.Create("prop_physics"))
                local index = prop:EntIndex()
                SERVER_TRANSACTION_LAST_INDEX = index
                prop:SetModel("models/props_c17/oildrum001.mdl")
                prop:Spawn()
                prop:Activate()

                if SERVER_TRANSACTION_CATCH_INNER then
                    local ok = pcall(function()
                        error("caught inside forwarded body")
                    end)
                    assert(ok == false)
                end

                net.Start("transaction_prop_observed")
                net.WriteUInt(index, 16)
                net.Broadcast()
                if SERVER_TRANSACTION_SHOULD_FAIL then
                    error("intentional transaction body failure")
                end
                SERVER_TRANSACTION_LAST_PROP = prop
            end
            AddConsoleCommand("transaction_spawn_prop")
            """,
            sourceName: "=(forwarded canonical transaction server command)"
        )
        try client.execute(
            """
            CLIENT_TRANSACTION_NET_COUNT = 0
            CLIENT_TRANSACTION_VISIBLE_DURING_NET = nil
            net.Receive("transaction_prop_observed", function()
                local index = net.ReadUInt(16)
                CLIENT_TRANSACTION_NET_COUNT = CLIENT_TRANSACTION_NET_COUNT + 1
                CLIENT_TRANSACTION_VISIBLE_DURING_NET = Entity(index):IsValid()
            end)
            """,
            sourceName: "=(forwarded canonical transaction client receiver)"
        )

        return Harness(
            session: session,
            transport: session.netTransport,
            server: server,
            client: client,
            adapter: adapter,
            player: player
        )
    }

    private func publishPendingCanonicalOperations(
        _ harness: Harness
    ) throws {
        _ = try harness.adapter.publishPendingCanonicalEntityOperations {
            try harness.session.publishCanonicalEntityUpdates($0)
        }
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
            sourceName: "=(forwarded canonical transaction net dispatch)"
        )
    }

    private func integerGlobal(
        _ name: String,
        in runtime: GMLuaRuntime
    ) throws -> Int {
        guard case let .number(value) = runtime.state.getGlobal(name),
              value.isFinite,
              value.rounded(.towardZero) == value else {
            throw LuaError.runtime("\(name) is not an integer Lua global")
        }
        return Int(value)
    }

    private func close(_ harness: Harness) {
        try? harness.adapter.close()
        _ = harness.client.close()
        _ = harness.server.close()
    }

    private struct Harness {
        let session: GMLuaSharedSession
        let transport: GMLuaNetTransport
        let server: GMLuaRuntime
        let client: GMLuaRuntime
        let adapter: GMLuaSourceRuntimeAdapter
        let player: SourceCanonicalEntitySnapshot
    }
}
