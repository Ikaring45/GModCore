import Foundation
import Dispatch
import XCTest
@testable import GModEngine
import GModLua

private final class SharedSessionInvocationSink: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [GMLuaConsoleCommandInvocation] = []

    func append(_ invocation: GMLuaConsoleCommandInvocation) {
        lock.lock()
        storage.append(invocation)
        lock.unlock()
    }

    var values: [GMLuaConsoleCommandInvocation] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private final class SharedSessionReentryObservations: @unchecked Sendable {
    private let lock = NSLock()
    private var disconnectStorage: String?
    private var pumpStorage: String?
    private var closeStorage: [String] = []

    func record(disconnect: String, pump: String, close: [String]) {
        lock.lock()
        disconnectStorage = disconnect
        pumpStorage = pump
        closeStorage = close
        lock.unlock()
    }

    var snapshot: (disconnect: String?, pump: String?, close: [String]) {
        lock.lock()
        defer { lock.unlock() }
        return (disconnectStorage, pumpStorage, closeStorage)
    }
}

private final class SharedSessionAsyncResult: @unchecked Sendable {
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

private final class SharedSessionHostIdentityError: Error, @unchecked Sendable {}

final class GMLuaSharedSessionTests: XCTestCase {
    func testPlayerInventoryUsesSourceBackedWeaponIdentityAcrossRealms() throws {
        let pair = makePair()
        let adapter = try GMLuaSourceRuntimeAdapter(serverRuntime: pair.server)
        defer {
            try? adapter.close()
            _ = pair.client.close()
            _ = pair.server.close()
        }
        try adapter.attach(client: pair.client)
        try XCTUnwrap(pair.server.entityRegistry)
            .connectPlayerWeaponGiveHandler(
                { [weak adapter] _, _, className in
                    guard let adapter else {
                        throw LuaError.runtime("Source adapter was released")
                    }
                    return try adapter.spawnNonNetworkableEntity(
                        SourceEntity(className: className),
                        kind: .weapon
                    )
                },
                removalHandler: { [weak adapter] identity in
                    adapter?.scheduleDeletionIfPresent(identity) == true
                }
            )
        try pair.session.connect(
            server: pair.server,
            client: pair.client,
            playerIndex: 7,
            userID: 70
        )

        try pair.server.execute(
            """
            local ply = Player(70)
            assert(ply:Alive())
            assert(ply:Nick() == "Player 70")
            assert(ply:GetNWString("UserGroup", "user") == "user")
            ply:SetNWString("UserGroup", "admin")
            assert(not ply:HasWeapon("weapon_physgun"))
            local weapon = ply:Give("weapon_physgun")
            assert(weapon:IsValid() and weapon:IsWeapon())
            assert(weapon:GetClass() == "weapon_physgun")
            assert(ply:HasWeapon("WEAPON_PHYSGUN"))
            assert(ply:GetWeapon("weapon_physgun") == weapon)
            assert(#ply:GetWeapons() == 1 and ply:GetWeapons()[1] == weapon)
            assert(ply:Give("weapon_physgun") == NULL)
            ply:SelectWeapon("weapon_physgun")
            assert(ply:GetActiveWeapon() == weapon)
            """,
            sourceName: "=(Source-backed Player inventory regression)"
        )
        try pair.client.execute(
            """
            local ply = LocalPlayer()
            assert(ply:Alive() and ply:Nick() == "Player 70")
            assert(ply:GetNWString("UserGroup", "user") == "admin")
            assert(ply:HasWeapon("weapon_physgun"))
            assert(ply:GetWeapon("weapon_physgun"):IsValid())
            assert(ply:GetWeapon("weapon_physgun"):GetClass() == "weapon_physgun")
            assert(ply:GetActiveWeapon() == ply:GetWeapon("weapon_physgun"))
            """,
            sourceName: "=(realm-local Player inventory mirror regression)"
        )
        try pair.session.updatePlayerAlive(for: pair.client, alive: false)
        try pair.server.execute("assert(not Player(70):Alive())")
        try pair.client.execute("assert(not LocalPlayer():Alive())")
        try pair.session.updatePlayerAlive(for: pair.client, alive: true)
        try pair.server.execute("assert(Player(70):Alive())")
        try pair.session.updatePlayerNickname(
            for: pair.client,
            nickname: "Builder"
        )
        try pair.server.execute("assert(Player(70):Nick() == 'Builder')")
        try pair.client.execute("assert(LocalPlayer():Nick() == 'Builder')")

        let weaponIndexProbe = try pair.server.executeReturningValues(
            "return Player(70):GetWeapon('weapon_physgun'):EntIndex()"
        )
        guard case let .number(weaponIndexValue) = weaponIndexProbe.first else {
            return XCTFail("Source-backed Weapon has no entity index")
        }
        let weaponIndex = Int(weaponIndexValue)
        let serverWeapon = try XCTUnwrap(pair.server.entityRegistry)
            .entity(at: weaponIndex)
        let clientWeapon = try XCTUnwrap(pair.client.entityRegistry)
            .entity(at: weaponIndex)
        XCTAssertFalse(
            GMLuaTypeSystem.typedObject(from: serverWeapon) ===
                GMLuaTypeSystem.typedObject(from: clientWeapon),
            "Weapon userdata must remain realm-local"
        )
        XCTAssertEqual(
            try XCTUnwrap(pair.server.entityRegistry)
                .sourceMirrorIdentity(for: serverWeapon),
            try XCTUnwrap(pair.client.entityRegistry)
                .sourceMirrorIdentity(for: clientWeapon)
        )
    }

    func testDisconnectReleasesOnlyDepartingPlayerWeaponsAcrossReconnect() throws {
        let session = GMLuaSharedSession()
        let server = GMLuaRuntime(
            realm: .server,
            logger: { _ in },
            netTransport: session.netTransport
        )
        let clientA = GMLuaRuntime(
            realm: .client,
            logger: { _ in },
            netTransport: session.netTransport
        )
        let clientB = GMLuaRuntime(
            realm: .client,
            logger: { _ in },
            netTransport: session.netTransport
        )
        let adapter = try GMLuaSourceRuntimeAdapter(serverRuntime: server)
        defer {
            try? adapter.close()
            _ = clientB.close()
            _ = clientA.close()
            _ = server.close()
        }
        try adapter.attach(client: clientA)
        try adapter.attach(client: clientB)
        let serverRegistry = try XCTUnwrap(server.entityRegistry)
        let clientARegistry = try XCTUnwrap(clientA.entityRegistry)
        let clientBRegistry = try XCTUnwrap(clientB.entityRegistry)
        serverRegistry.connectPlayerWeaponGiveHandler(
            { [weak adapter] _, _, className in
                guard let adapter else {
                    throw LuaError.runtime("Source adapter was released")
                }
                return try adapter.spawnNonNetworkableEntity(
                    SourceEntity(className: className),
                    kind: .weapon
                )
            },
            removalHandler: { [weak adapter] identity in
                adapter?.scheduleDeletionIfPresent(identity) == true
            }
        )
        try session.connect(
            server: server,
            client: clientA,
            playerIndex: 7,
            userID: 70
        )
        try session.connect(
            server: server,
            client: clientB,
            playerIndex: 8,
            userID: 80
        )

        try server.execute(
            """
            OLD_A_PLAYER = Player(70)
            OLD_A_WEAPON = assert(OLD_A_PLAYER:Give("weapon_physgun"))
            B_WEAPON = assert(Player(80):Give("gmod_tool"))
            """
        )
        try clientA.execute(
            """
            OLD_A_PLAYER = LocalPlayer()
            OLD_A_WEAPON = OLD_A_PLAYER:GetWeapon("weapon_physgun")
            B_WEAPON = Player(80):GetWeapon("gmod_tool")
            assert(OLD_A_WEAPON:IsValid() and B_WEAPON:IsValid())
            """
        )
        try clientB.execute(
            """
            REMOTE_OLD_A_WEAPON = Player(70):GetWeapon("weapon_physgun")
            B_WEAPON = LocalPlayer():GetWeapon("gmod_tool")
            assert(REMOTE_OLD_A_WEAPON:IsValid() and B_WEAPON:IsValid())
            """
        )

        let oldAIndexValues = try server.executeReturningValues(
            "return OLD_A_WEAPON:EntIndex()"
        )
        let bIndexValues = try server.executeReturningValues(
            "return B_WEAPON:EntIndex()"
        )
        guard case let .number(oldAIndexValue) = oldAIndexValues.first,
              case let .number(bIndexValue) = bIndexValues.first else {
            return XCTFail("Source-backed weapons have no entity indices")
        }
        let oldAIdentity = try XCTUnwrap(
            serverRegistry.sourceMirrorIdentity(at: Int(oldAIndexValue))
        )
        let bIdentity = try XCTUnwrap(
            serverRegistry.sourceMirrorIdentity(at: Int(bIndexValue))
        )
        XCTAssertEqual(
            clientARegistry.sourceMirrorIdentity(at: oldAIdentity.index),
            oldAIdentity
        )
        XCTAssertEqual(
            clientBRegistry.sourceMirrorIdentity(at: oldAIdentity.index),
            oldAIdentity
        )
        XCTAssertTrue(adapter.contains(oldAIdentity))
        XCTAssertTrue(adapter.contains(bIdentity))

        try session.disconnect(client: clientA)
        try server.execute(
            """
            assert(not OLD_A_PLAYER:IsValid())
            assert(Player(70) == NULL)
            assert(Player(80):GetWeapon("gmod_tool") == B_WEAPON)
            assert(OLD_A_WEAPON:IsValid()) -- deferred until the Source cleanup phase
            """
        )
        try clientA.execute(
            """
            assert(not OLD_A_PLAYER:IsValid())
            assert(LocalPlayer() == NULL)
            assert(OLD_A_WEAPON:IsValid())
            """
        )
        try clientB.execute(
            """
            assert(Player(70) == NULL)
            assert(LocalPlayer():GetWeapon("gmod_tool") == B_WEAPON)
            assert(REMOTE_OLD_A_WEAPON:IsValid())
            """
        )

        try session.connect(
            server: server,
            client: clientA,
            playerIndex: 7,
            userID: 70
        )
        try server.execute(
            """
            assert(Player(70) ~= OLD_A_PLAYER)
            assert(not Player(70):HasWeapon("weapon_physgun"))
            NEW_A_WEAPON = assert(Player(70):Give("weapon_physgun"))
            assert(NEW_A_WEAPON ~= OLD_A_WEAPON)
            assert(Player(80):GetWeapon("gmod_tool") == B_WEAPON)
            """
        )
        try clientA.execute(
            """
            assert(LocalPlayer() ~= OLD_A_PLAYER)
            NEW_A_WEAPON = LocalPlayer():GetWeapon("weapon_physgun")
            assert(NEW_A_WEAPON:IsValid() and NEW_A_WEAPON ~= OLD_A_WEAPON)
            """
        )
        try clientB.execute(
            """
            NEW_A_WEAPON = Player(70):GetWeapon("weapon_physgun")
            assert(NEW_A_WEAPON:IsValid() and NEW_A_WEAPON ~= REMOTE_OLD_A_WEAPON)
            assert(LocalPlayer():GetWeapon("gmod_tool") == B_WEAPON)
            """
        )
        let newAIndexValues = try server.executeReturningValues(
            "return NEW_A_WEAPON:EntIndex()"
        )
        guard case let .number(newAIndexValue) = newAIndexValues.first else {
            return XCTFail("replacement Source-backed weapon has no entity index")
        }
        let newAIdentity = try XCTUnwrap(
            serverRegistry.sourceMirrorIdentity(at: Int(newAIndexValue))
        )
        XCTAssertNotEqual(newAIdentity, oldAIdentity)
        XCTAssertTrue(adapter.contains(oldAIdentity))
        XCTAssertTrue(adapter.contains(newAIdentity))
        XCTAssertTrue(adapter.contains(bIdentity))

        let cleanupReport = try adapter.runServerFixedTick()
        XCTAssertEqual(cleanupReport.removedEntities, [oldAIdentity])
        XCTAssertFalse(adapter.contains(oldAIdentity))
        XCTAssertTrue(adapter.contains(newAIdentity))
        XCTAssertTrue(adapter.contains(bIdentity))
        XCTAssertNil(serverRegistry.sourceMirrorIdentity(at: oldAIdentity.index))
        XCTAssertNil(clientARegistry.sourceMirrorIdentity(at: oldAIdentity.index))
        XCTAssertNil(clientBRegistry.sourceMirrorIdentity(at: oldAIdentity.index))
        XCTAssertEqual(
            serverRegistry.sourceMirrorIdentity(at: newAIdentity.index),
            newAIdentity
        )
        XCTAssertEqual(
            serverRegistry.sourceMirrorIdentity(at: bIdentity.index),
            bIdentity
        )
        try server.execute(
            """
            assert(OLD_A_WEAPON == NULL and not OLD_A_WEAPON:IsValid())
            assert(Player(70):GetWeapon("weapon_physgun") == NEW_A_WEAPON)
            assert(Player(80):GetWeapon("gmod_tool") == B_WEAPON)
            """
        )
        try clientA.execute(
            """
            assert(OLD_A_WEAPON == NULL and not OLD_A_WEAPON:IsValid())
            assert(LocalPlayer():GetWeapon("weapon_physgun") == NEW_A_WEAPON)
            assert(Player(80):GetWeapon("gmod_tool") == B_WEAPON)
            """
        )
        try clientB.execute(
            """
            assert(REMOTE_OLD_A_WEAPON == NULL and not REMOTE_OLD_A_WEAPON:IsValid())
            assert(Player(70):GetWeapon("weapon_physgun") == NEW_A_WEAPON)
            assert(LocalPlayer():GetWeapon("gmod_tool") == B_WEAPON)
            """
        )
    }

    func testServerPlayerConCommandTargetsClientAtPumpBoundaryAndDisconnectPurgesIt() throws {
        let pair = makePair()
        defer {
            _ = pair.client.close()
            _ = pair.server.close()
        }
        try pair.client.execute(
            "CreateClientConVar('targeted_mode', 'old', true, false)"
        )
        try pair.session.connect(
            server: pair.server,
            client: pair.client,
            playerIndex: 7,
            userID: 70
        )

        try pair.server.execute(
            "Player(70):ConCommand('targeted_mode \\\"new value\\\"')"
        )
        XCTAssertEqual(pair.session.netTransport.pendingDeliveryCount, 1)
        try pair.client.execute(
            "assert(GetConVar('targeted_mode'):GetString() == 'old')"
        )
        XCTAssertEqual(try pair.session.pump(), 1)
        try pair.client.execute(
            "assert(GetConVar('targeted_mode'):GetString() == 'new value')"
        )

        let report = try XCTUnwrap(pair.server.consoleCommandDispatcher)
            .drainPlayerConsoleCommandRequestReport()
        XCTAssertEqual(report.requests.count, 1)
        XCTAssertEqual(report.requests[0].playerIndex, 7)
        XCTAssertEqual(report.requests[0].outcome, .dispatched(commandCount: 1))

        try pair.server.execute(
            "Player(70):ConCommand('targeted_mode disconnected')"
        )
        let oldIdentity = try XCTUnwrap(pair.server.entityRegistry)
            .playerNetworkIdentity(
                from: try XCTUnwrap(pair.server.entityRegistry).player(at: 7),
                function: "test"
            )
        XCTAssertEqual(pair.session.netTransport.pendingDeliveryCount, 1)
        try pair.session.disconnect(client: pair.client)
        XCTAssertEqual(
            pair.session.netTransport.pendingDeliveryCount,
            0,
            "a generation-bound target delivery must not survive disconnect"
        )
        try pair.client.execute(
            "assert(GetConVar('targeted_mode'):GetString() == 'new value')"
        )

        try pair.session.connect(
            server: pair.server,
            client: pair.client,
            playerIndex: 7,
            userID: 70
        )
        XCTAssertThrowsError(
            try pair.session.netTransport.enqueueTargetedConsoleCommands(
                from: try XCTUnwrap(pair.server.netEndpoint),
                toPlayerIndex: 7,
                expectedGeneration: oldIdentity.generation,
                commands: [
                    GMLuaConsoleCommandInvocation(
                        realm: .server,
                        command: "targeted_mode",
                        arguments: ["must-not-reach-new-generation"]
                    ),
                ]
            )
        ) { error in
            XCTAssertTrue(GMLuaRuntime.describe(error).contains("generation is stale"))
        }
        XCTAssertEqual(pair.session.netTransport.pendingDeliveryCount, 0)
        try pair.client.execute(
            "assert(GetConVar('targeted_mode'):GetString() == 'new value')"
        )
    }

    func testTargetedConsoleBindingSurvivesAnotherSharedSessionDisconnect() throws {
        let transport = GMLuaNetTransport()
        let sessionA = GMLuaSharedSession(netTransport: transport)
        let sessionB = GMLuaSharedSession(netTransport: transport)
        let server = GMLuaRuntime(
            realm: .server,
            logger: { _ in },
            netTransport: transport
        )
        let clientA = GMLuaRuntime(
            realm: .client,
            logger: { _ in },
            netTransport: transport
        )
        let clientB = GMLuaRuntime(
            realm: .client,
            logger: { _ in },
            netTransport: transport
        )
        defer {
            _ = clientB.close()
            _ = clientA.close()
            _ = server.close()
        }
        try clientA.execute(
            "CreateClientConVar('session_a_target', 'old', true, false)"
        )
        try sessionA.connect(
            server: server,
            client: clientA,
            playerIndex: 7,
            userID: 70
        )
        try sessionB.connect(
            server: server,
            client: clientB,
            playerIndex: 8,
            userID: 80
        )

        try sessionB.disconnect(client: clientB)
        try server.execute(
            "Player(70):ConCommand('session_a_target still-connected')"
        )
        XCTAssertEqual(transport.pendingDeliveryCount, 1)
        XCTAssertEqual(try sessionA.pump(), 1)
        try clientA.execute(
            "assert(GetConVar('session_a_target'):GetString() == 'still-connected')"
        )
    }

    func testConnectionCreatesCanonicalRealmLocalPlayersAndSendToServerUsesServerMirror() throws {
        let pair = makePair()
        defer {
            _ = pair.client.close()
            _ = pair.server.close()
        }

        try pair.client.execute(
            """
            assert(type(LocalPlayer) == "function")
            assert(LocalPlayer() == NULL)
            assert(Player(70) == NULL and Player(7) == NULL)
            assert(#player.GetAll() == 0)
            """
        )
        try installNetDispatch(in: pair.server)
        try pair.server.execute(
            """
            util.AddNetworkString("client_identity")
            net.Receive("client_identity", function(length, sender)
                assert(length == 3)
                assert(sender == Player(70))
                assert(sender:IsValid() and sender:IsPlayer())
                SERVER_SENDER_INDEX = sender:EntIndex()
                SERVER_PAYLOAD = net.ReadUInt(3)
            end)
            """
        )

        try pair.session.connect(
            server: pair.server,
            client: pair.client,
            playerIndex: 7,
            userID: 70
        )

        XCTAssertEqual(pair.session.connectedClientCount, 1)
        XCTAssertEqual(pair.session.connectedPlayerIndices, [7])
        let serverPlayer = try XCTUnwrap(
            GMLuaTypeSystem.typedObject(from: try XCTUnwrap(pair.server.entityRegistry).player(at: 7))
        )
        let clientPlayer = try XCTUnwrap(
            GMLuaTypeSystem.typedObject(from: try XCTUnwrap(pair.client.entityRegistry).player(at: 7))
        )
        XCTAssertFalse(serverPlayer === clientPlayer, "Player mirrors must remain realm-local")

        try pair.client.execute(
            """
            assert(LocalPlayer() == Entity(7))
            assert(LocalPlayer() == Player(70))
            assert(Player(7) == NULL)
            assert(LocalPlayer():IsValid() and LocalPlayer():EntIndex() == 7)
            assert(#player.GetAll() == 1 and player.GetAll()[1] == LocalPlayer())
            net.Start("client_identity")
            net.WriteUInt(5, 3)
            net.SendToServer()
            """
        )
        XCTAssertEqual(pair.session.netTransport.pendingDeliveryCount, 1)
        guard case .nilValue = pair.server.state.getGlobal("SERVER_SENDER_INDEX") else {
            return XCTFail("SendToServer synchronously re-entered SERVER Lua")
        }

        XCTAssertEqual(try pair.session.pump(), 1)
        try pair.server.execute(
            """
            assert(SERVER_SENDER_INDEX == 7)
            assert(SERVER_PAYLOAD == 5)
            """
        )
    }

    func testNetAndRemoteConsoleCommandsShareOneDeterministicFIFO() throws {
        let pair = makePair()
        defer {
            _ = pair.client.close()
            _ = pair.server.close()
        }
        try installNetDispatch(in: pair.server)
        try pair.server.execute(
            """
            FIFO_EVENTS = {}
            util.AddNetworkString("fifo_a")
            util.AddNetworkString("fifo_c")
            net.Receive("fifo_a", function(_, sender)
                table.insert(FIFO_EVENTS, "A:" .. sender:EntIndex())
            end)
            net.Receive("fifo_c", function(_, sender)
                table.insert(FIFO_EVENTS, "C:" .. sender:EntIndex())
            end)
            concommand = {}
            function concommand.Run(sender, command, arguments, argumentString)
                assert(sender == Player(30))
                assert(command == "server_fifo")
                assert(arguments[1] == "one" and arguments[2] == "two")
                assert(argumentString == "one two")
                table.insert(FIFO_EVENTS, "B:" .. sender:EntIndex())
            end
            AddConsoleCommand("server_fifo")
            """
        )
        try pair.session.connect(
            server: pair.server,
            client: pair.client,
            playerIndex: 3,
            userID: 30
        )

        try pair.client.execute(
            """
            net.Start("fifo_a")
            net.SendToServer()
            RunConsoleCommand("server_fifo", "one", "two")
            net.Start("fifo_c")
            net.SendToServer()
            """
        )
        XCTAssertEqual(pair.session.netTransport.pendingDeliveryCount, 3)
        try pair.server.execute("assert(#FIFO_EVENTS == 0)")

        XCTAssertEqual(try pair.session.pump(maxDeliveries: 1), 1)
        try pair.server.execute("assert(table.concat(FIFO_EVENTS, ',') == 'A:3')")
        XCTAssertEqual(try pair.session.pump(maxDeliveries: 1), 1)
        try pair.server.execute("assert(table.concat(FIFO_EVENTS, ',') == 'A:3,B:3')")
        XCTAssertEqual(try pair.session.pump(), 1)
        try pair.server.execute("assert(table.concat(FIFO_EVENTS, ',') == 'A:3,B:3,C:3')")
    }

    func testReportingPumpClassifiesActionsAndPropagatesHostInvariants() throws {
        let pair = makePair()
        let hostIdentityError = SharedSessionHostIdentityError()
        defer {
            _ = pair.client.close()
            _ = pair.server.close()
        }
        try pair.server.execute(
            """
            concommand = {}
            function concommand.Run(sender, command, arguments)
                assert(sender == Player(90))
                if command == "reported_failure" then
                    error("intentional forwarded action failure")
                end
                if command == "reported_nested_host" then
                    RunConsoleCommand("throwing_host_handler")
                    return
                end
                if command == "reported_nested_lifecycle" then
                    local ok = pcall(RunConsoleCommand, "nested_lifecycle_host")
                    NESTED_LIFECYCLE_PCALL_RETURNED = true
                    NESTED_LIFECYCLE_PCALL_OK = ok
                    return
                end
                assert(command == "after_reported_failure")
                assert(arguments[1] == "still-ran")
                AFTER_REPORTED_FAILURE = true
            end
            AddConsoleCommand("reported_failure")
            AddConsoleCommand("reported_nested_host")
            AddConsoleCommand("reported_nested_lifecycle")
            AddConsoleCommand("after_reported_failure")
            """
        )
        try XCTUnwrap(pair.server.consoleCommandDispatcher).connectHost {
            invocation in
            switch invocation.command {
            case "explicitly_rejected":
                return .rejected(reason: "expected permission rejection")
            case "throwing_host_handler":
                throw hostIdentityError
            case "nested_lifecycle_host":
                try pair.session.disconnect(client: pair.client)
                return .handled
            default:
                return .unhandled
            }
        }
        try pair.session.connect(
            server: pair.server,
            client: pair.client,
            playerIndex: 9,
            userID: 90
        )
        try pair.client.execute(
            """
            RunConsoleCommand("reported_failure", "requested")
            RunConsoleCommand("explicitly_rejected")
            RunConsoleCommand("unowned_action")
            RunConsoleCommand("after_reported_failure", "still-ran")
            """
        )

        let report = try pair.session
            .pumpReportingForwardedConsoleFailures()
        XCTAssertEqual(report.processedDeliveries, 4)
        XCTAssertEqual(report.successfulDeliveries, 1)
        XCTAssertEqual(report.forwardedConsoleFailures.count, 3)
        let failure = try XCTUnwrap(report.forwardedConsoleFailures.first)
        XCTAssertEqual(failure.command, "reported_failure")
        XCTAssertEqual(failure.arguments, ["requested"])
        XCTAssertTrue(
            failure.message.contains("intentional forwarded action failure")
        )
        XCTAssertEqual(
            report.forwardedConsoleFailures.map(\.command),
            ["reported_failure", "explicitly_rejected", "unowned_action"]
        )
        XCTAssertTrue(
            report.forwardedConsoleFailures[1].message.contains(
                "expected permission rejection"
            )
        )
        XCTAssertTrue(
            report.forwardedConsoleFailures[2].message.contains(
                "host did not recognize engine command"
            )
        )
        XCTAssertEqual(pair.session.netTransport.pendingDeliveryCount, 0)
        try pair.server.execute("assert(AFTER_REPORTED_FAILURE == true)")

        // The original API remains strict for callers that require it.
        try pair.client.execute(
            "RunConsoleCommand('reported_failure', 'strict')"
        )
        XCTAssertThrowsError(try pair.session.pump()) { error in
            XCTAssertTrue(
                GMLuaRuntime.describe(error).contains(
                    "intentional forwarded action failure"
                )
            )
        }

        // A host implementation throwing directly is not an expected
        // user-action rejection and retains its concrete error identity.
        try pair.client.execute(
            "RunConsoleCommand('throwing_host_handler')"
        )
        XCTAssertThrowsError(
            try pair.session.pumpReportingForwardedConsoleFailures()
        ) { error in
            XCTAssertTrue(
                (error as? SharedSessionHostIdentityError)
                    === hostIdentityError
            )
        }

        // The same host error can originate inside a forwarded Lua concommand.
        // It must cross state.call without becoming an action-failure string,
        // while the following FIFO item stays queued.
        try pair.server.execute("AFTER_REPORTED_FAILURE = false")
        try pair.client.execute(
            """
            RunConsoleCommand('reported_nested_host')
            RunConsoleCommand('after_reported_failure', 'still-ran')
            """
        )
        XCTAssertThrowsError(
            try pair.session.pumpReportingForwardedConsoleFailures()
        ) { error in
            XCTAssertTrue(
                (error as? SharedSessionHostIdentityError)
                    === hostIdentityError
            )
        }
        XCTAssertEqual(pair.session.netTransport.pendingDeliveryCount, 1)
        let recoveredAfterHost = try pair.session
            .pumpReportingForwardedConsoleFailures()
        XCTAssertEqual(recoveredAfterHost.processedDeliveries, 1)
        XCTAssertEqual(recoveredAfterHost.successfulDeliveries, 1)
        XCTAssertEqual(recoveredAfterHost.forwardedConsoleFailures, [])
        try pair.server.execute("assert(AFTER_REPORTED_FAILURE == true)")

        // Strict pumping never installs the reporting sentinel context, so it
        // also propagates the exact original host error object.
        try pair.client.execute("RunConsoleCommand('reported_nested_host')")
        XCTAssertThrowsError(try pair.session.pump()) { error in
            XCTAssertTrue(
                (error as? SharedSessionHostIdentityError)
                    === hostIdentityError
            )
        }

        // Even Lua pcall must not downgrade a lifecycle violation nested in a
        // forwarded command body. The side channel rethrows it after the Lua
        // body returns and leaves the following FIFO delivery untouched.
        try pair.server.execute("AFTER_REPORTED_FAILURE = false")
        try pair.client.execute(
            """
            RunConsoleCommand('reported_nested_lifecycle')
            RunConsoleCommand('after_reported_failure', 'still-ran')
            """
        )
        XCTAssertThrowsError(
            try pair.session.pumpReportingForwardedConsoleFailures()
        ) { error in
            guard case let .lifecycleDuringPump(operation)? =
                error as? GMLuaSharedSessionError else {
                return XCTFail("nested lifecycle error lost its concrete type")
            }
            XCTAssertEqual(operation, "disconnect")
        }
        XCTAssertEqual(pair.session.netTransport.pendingDeliveryCount, 1)
        try pair.server.execute(
            """
            assert(NESTED_LIFECYCLE_PCALL_RETURNED == true)
            assert(NESTED_LIFECYCLE_PCALL_OK == false)
            """
        )
        let recoveredAfterLifecycle = try pair.session
            .pumpReportingForwardedConsoleFailures()
        XCTAssertEqual(recoveredAfterLifecycle.processedDeliveries, 1)
        XCTAssertEqual(recoveredAfterLifecycle.successfulDeliveries, 1)
        XCTAssertEqual(recoveredAfterLifecycle.forwardedConsoleFailures, [])
        try pair.server.execute("assert(AFTER_REPORTED_FAILURE == true)")
        XCTAssertEqual(pair.session.connectedClientCount, 1)
    }

    func testServerTargetedSendSupportsSinglePlayerAndDeduplicatedPlayerTable() throws {
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
        defer {
            _ = first.close()
            _ = second.close()
            _ = server.close()
        }
        try installNetDispatch(in: first)
        try installNetDispatch(in: second)
        try server.execute("util.AddNetworkString('target_reply')")
        try first.execute(
            """
            TARGET_COUNT = 0
            net.Receive("target_reply", function(_, sender)
                assert(sender == nil)
                TARGET_COUNT = TARGET_COUNT + 1
                TARGET_TOTAL = (TARGET_TOTAL or 0) + net.ReadUInt(4)
            end)
            """
        )
        try second.execute(
            """
            TARGET_COUNT = 0
            net.Receive("target_reply", function(_, sender)
                assert(sender == nil)
                TARGET_COUNT = TARGET_COUNT + 1
                TARGET_TOTAL = (TARGET_TOTAL or 0) + net.ReadUInt(4)
            end)
            """
        )
        try session.connect(server: server, client: first, playerIndex: 1, userID: 101)
        try session.connect(server: server, client: second, playerIndex: 2, userID: 202)
        try first.execute(
            """
            assert(LocalPlayer() == Entity(1) and LocalPlayer() == Player(101))
            assert(Player(1) == NULL)
            assert(Player(202):IsValid() and Player(2) == NULL)
            assert(#player.GetAll() == 2)
            """
        )
        try second.execute(
            """
            assert(LocalPlayer() == Entity(2) and LocalPlayer() == Player(202))
            assert(Player(2) == NULL)
            assert(Player(101):IsValid() and Player(1) == NULL)
            assert(#player.GetAll() == 2)
            """
        )

        try server.execute(
            """
            net.Start("target_reply")
            net.WriteUInt(2, 4)
            net.Send(Player(202))
            net.Start("target_reply")
            net.WriteUInt(5, 4)
            net.Send({ Player(101), Player(202), Player(202) })
            """
        )
        XCTAssertEqual(session.netTransport.pendingDeliveryCount, 3)
        XCTAssertEqual(try session.pump(), 3)
        try first.execute("assert(TARGET_COUNT == 1 and TARGET_TOTAL == 5)")
        try second.execute("assert(TARGET_COUNT == 2 and TARGET_TOTAL == 7)")

        try session.disconnect(client: first)
        try second.execute(
            """
            assert(Player(101) == NULL)
            assert(LocalPlayer() == Player(202))
            assert(#player.GetAll() == 1 and player.GetAll()[1] == LocalPlayer())
            """
        )
        try server.execute("assert(Player(101) == NULL and Player(202):IsValid())")
    }

    func testLocalClientCommandDoesNotLeakAndDisconnectPurgesOldGeneration() throws {
        let pair = makePair()
        defer {
            _ = pair.client.close()
            _ = pair.server.close()
        }
        try installNetDispatch(in: pair.server)
        try pair.server.execute(
            """
            GENERATION_COUNT = 0
            util.AddNetworkString("generation_probe")
            net.Receive("generation_probe", function(_, sender)
                assert(sender == Player(44))
                GENERATION_COUNT = GENERATION_COUNT + 1
            end)
            """
        )
        try pair.session.connect(
            server: pair.server,
            client: pair.client,
            playerIndex: 4,
            userID: 44
        )
        try pair.client.execute(
            """
            concommand = {}
            function concommand.Run(sender, command, arguments, argumentString)
                assert(sender == LocalPlayer())
                assert(command == "client_local")
                assert(arguments[1] == "local" and argumentString == "local")
                CLIENT_LOCAL_COUNT = (CLIENT_LOCAL_COUNT or 0) + 1
            end
            AddConsoleCommand("client_local")
            RunConsoleCommand("client_local", "local")
            assert(CLIENT_LOCAL_COUNT == 1)
            OLD_LOCAL_PLAYER = LocalPlayer()
            OLD_LOCAL_TABLE = OLD_LOCAL_PLAYER:GetTable()
            OLD_LOCAL_PLAYER.realmValue = "client"
            assert(OLD_LOCAL_TABLE.realmValue == "client")
            net.Start("generation_probe")
            net.SendToServer()
            """
        )
        try pair.server.execute(
            """
            SERVER_OLD_PLAYER = Player(44)
            SERVER_OLD_TABLE = SERVER_OLD_PLAYER:GetTable()
            SERVER_OLD_PLAYER.realmValue = "server"
            assert(SERVER_OLD_TABLE.realmValue == "server")
            """
        )
        XCTAssertEqual(pair.session.netTransport.pendingDeliveryCount, 1)

        try pair.session.disconnect(client: pair.client)
        XCTAssertEqual(pair.session.connectedClientCount, 0)
        XCTAssertEqual(pair.session.netTransport.pendingDeliveryCount, 0)
        try pair.client.execute(
            """
            assert(LocalPlayer() == NULL)
            assert(not OLD_LOCAL_PLAYER:IsValid())
            assert(OLD_LOCAL_PLAYER == NULL and OLD_LOCAL_PLAYER:EntIndex() == 0)
            assert(OLD_LOCAL_PLAYER:GetTable() == nil)
            assert(OLD_LOCAL_TABLE.realmValue == "client")
            """
        )
        try pair.server.execute(
            """
            assert(Player(44) == NULL and GENERATION_COUNT == 0)
            assert(not SERVER_OLD_PLAYER:IsValid())
            assert(SERVER_OLD_PLAYER == NULL and SERVER_OLD_PLAYER:EntIndex() == 0)
            assert(SERVER_OLD_PLAYER:GetTable() == nil)
            assert(SERVER_OLD_TABLE.realmValue == "server")
            """
        )

        try pair.session.connect(
            server: pair.server,
            client: pair.client,
            playerIndex: 4,
            userID: 44
        )
        try pair.client.execute(
            """
            assert(LocalPlayer():IsValid())
            assert(LocalPlayer() ~= OLD_LOCAL_PLAYER)
            assert(OLD_LOCAL_PLAYER == NULL)
            assert(LocalPlayer():GetTable() ~= OLD_LOCAL_TABLE)
            assert(LocalPlayer().realmValue == nil)
            net.Start("generation_probe")
            net.SendToServer()
            """
        )
        try pair.server.execute(
            """
            assert(Player(44):IsValid() and Player(44) ~= SERVER_OLD_PLAYER)
            assert(Player(44):GetTable() ~= SERVER_OLD_TABLE)
            assert(Player(44).realmValue == nil)
            """
        )
        XCTAssertEqual(try pair.session.pump(), 1)
        try pair.server.execute("assert(GENERATION_COUNT == 1)")

        _ = pair.client.close()
        XCTAssertEqual(pair.session.connectedClientCount, 0)
        try pair.server.execute("assert(Player(44) == NULL)")
    }

    func testReceiverFailureConsumesOnlyThatDeliveryAndLeavesLaterConsoleCommandQueued() throws {
        let pair = makePair()
        defer {
            _ = pair.client.close()
            _ = pair.server.close()
        }
        try installNetDispatch(in: pair.server)
        try pair.server.execute(
            """
            util.AddNetworkString("intentional_failure")
            net.Receive("intentional_failure", function()
                error("shared-session receiver failure")
            end)
            concommand = {}
            function concommand.Run(sender, command)
                assert(sender == Player(80) and command == "after_failure")
                AFTER_FAILURE_COMMAND = true
            end
            AddConsoleCommand("after_failure")
            """
        )
        try pair.session.connect(
            server: pair.server,
            client: pair.client,
            playerIndex: 8,
            userID: 80
        )
        try pair.client.execute(
            """
            net.Start("intentional_failure")
            net.SendToServer()
            RunConsoleCommand("after_failure")
            """
        )

        XCTAssertThrowsError(try pair.session.pump()) { error in
            XCTAssertTrue(GMLuaRuntime.describe(error).contains("shared-session receiver failure"))
        }
        XCTAssertEqual(pair.session.netTransport.pendingDeliveryCount, 1)
        XCTAssertEqual(try pair.session.pump(), 1)
        try pair.server.execute("assert(AFTER_FAILURE_COMMAND == true)")
    }

    func testForwardedConsoleUsesServerConVarAndEngineHostOwnershipBeforeLuaCommands() throws {
        let pair = makePair()
        defer {
            _ = pair.client.close()
            _ = pair.server.close()
        }
        try pair.server.execute(
            """
            CreateConVar("shared_server_value", "old")
            assert(GetConVar("shared_server_value"):GetString() == "old")
            """
        )
        let sink = SharedSessionInvocationSink()
        try XCTUnwrap(pair.server.consoleCommandDispatcher).connectHost { invocation in
            if invocation.command == "engine_server" {
                sink.append(invocation)
                return .handled
            }
            return .unhandled
        }
        try pair.session.connect(
            server: pair.server,
            client: pair.client,
            playerIndex: 6,
            userID: 60
        )

        try pair.client.execute(
            """
            RunConsoleCommand("shared_server_value", "new")
            RunConsoleCommand("engine_server", "alpha", "beta")
            """
        )
        XCTAssertEqual(pair.session.netTransport.pendingDeliveryCount, 2)
        XCTAssertEqual(try pair.session.pump(), 2)
        try pair.server.execute(
            "assert(GetConVar('shared_server_value'):GetString() == 'new')"
        )
        XCTAssertEqual(
            sink.values,
            [GMLuaConsoleCommandInvocation(
                realm: .server,
                command: "engine_server",
                arguments: ["alpha", "beta"]
            )]
        )

        try pair.client.execute("RunConsoleCommand('server_has_no_owner')")
        XCTAssertThrowsError(try pair.session.pump()) { error in
            XCTAssertTrue(
                GMLuaRuntime.describe(error).contains("host did not recognize engine command")
            )
        }
    }

    func testPumpCallbackRejectsReentrantPumpDisconnectAndCloseWithoutDeadlock() throws {
        let pair = makePair()
        defer {
            _ = pair.client.close()
            _ = pair.server.close()
        }
        let observations = SharedSessionReentryObservations()
        pair.server.state.register("HOST_REENTRY_PROBE") { _ in
            let disconnectDescription: String
            do {
                try pair.session.disconnect(client: pair.client)
                disconnectDescription = "unexpected success"
            } catch {
                disconnectDescription = String(describing: error)
            }
            let nestedPumpDescription: String
            do {
                _ = try pair.session.pump()
                nestedPumpDescription = "unexpected success"
            } catch {
                nestedPumpDescription = GMLuaRuntime.describe(error)
            }
            let closeReport = pair.client.close()
            observations.record(
                disconnect: disconnectDescription,
                pump: nestedPumpDescription,
                close: closeReport.errorMessages
            )
            return []
        }
        try installNetDispatch(in: pair.server)
        try pair.server.execute(
            """
            util.AddNetworkString("reentry_probe")
            net.Receive("reentry_probe", function() HOST_REENTRY_PROBE() end)
            """
        )
        try pair.session.connect(
            server: pair.server,
            client: pair.client,
            playerIndex: 11,
            userID: 110
        )
        try pair.client.execute(
            "net.Start('reentry_probe'); net.SendToServer()"
        )

        XCTAssertEqual(try pair.session.pump(), 1)
        let snapshot = observations.snapshot
        XCTAssertTrue(snapshot.disconnect?.contains("cannot disconnect synchronously") == true)
        XCTAssertTrue(snapshot.pump?.contains("cannot be re-entered") == true)
        XCTAssertTrue(snapshot.close.first?.contains("rejected during a Lua delivery callback") == true)
        XCTAssertFalse(pair.client.isClosed)
        XCTAssertEqual(pair.session.connectedClientCount, 1)
    }

    func testConcurrentConnectPublishesNoPlayerMirrorsUntilActivePumpReturns() throws {
        let pair = makePair()
        let second = GMLuaRuntime(
            realm: .client,
            logger: { _ in },
            netTransport: pair.session.netTransport
        )
        defer {
            _ = second.close()
            _ = pair.client.close()
            _ = pair.server.close()
        }
        let callbackEntered = DispatchSemaphore(value: 0)
        let releaseCallback = DispatchSemaphore(value: 0)
        pair.server.state.register("HOST_CONNECT_GATE") { _ in
            callbackEntered.signal()
            releaseCallback.wait()
            return []
        }
        try installNetDispatch(in: pair.server)
        try pair.server.execute(
            """
            util.AddNetworkString("connect_gate")
            net.Receive("connect_gate", function() HOST_CONNECT_GATE() end)
            """
        )
        try pair.session.connect(
            server: pair.server,
            client: pair.client,
            playerIndex: 1,
            userID: 101
        )
        try pair.client.execute("net.Start('connect_gate'); net.SendToServer()")

        let queue = DispatchQueue(
            label: "GMLuaSharedSessionTests.atomicConnect",
            attributes: .concurrent
        )
        let workers = DispatchGroup()
        let pumpResult = SharedSessionAsyncResult()
        workers.enter()
        queue.async {
            pumpResult.record(Result {
                _ = try pair.session.pump()
            })
            workers.leave()
        }
        guard callbackEntered.wait(timeout: .now() + 2) == .success else {
            releaseCallback.signal()
            _ = workers.wait(timeout: .now() + 2)
            return XCTFail("active pump did not enter the synthetic receiver")
        }

        let connectStarted = DispatchSemaphore(value: 0)
        let connectFinished = DispatchSemaphore(value: 0)
        let connectResult = SharedSessionAsyncResult()
        workers.enter()
        queue.async {
            connectStarted.signal()
            connectResult.record(Result {
                try pair.session.connect(
                    server: pair.server,
                    client: second,
                    playerIndex: 2,
                    userID: 202
                )
            })
            connectFinished.signal()
            workers.leave()
        }
        XCTAssertEqual(connectStarted.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(connectFinished.wait(timeout: .now() + 0.2), .timedOut)
        XCTAssertEqual(pair.session.connectedClientCount, 1)
        XCTAssertFalse(
            GMLuaTypeSystem.typedObject(
                from: try XCTUnwrap(pair.client.entityRegistry).player(at: 2)
            )?.isValid == true,
            "connect leaked a new mirror into an idle CLIENT while SERVER Lua was running"
        )
        XCTAssertFalse(
            GMLuaTypeSystem.typedObject(
                from: try XCTUnwrap(second.entityRegistry).player(at: 1)
            )?.isValid == true,
            "connect leaked existing mirrors before it acquired the lifecycle boundary"
        )

        releaseCallback.signal()
        XCTAssertEqual(workers.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(connectFinished.wait(timeout: .now()), .success)
        try XCTUnwrap(pumpResult.value).get()
        try XCTUnwrap(connectResult.value).get()
        XCTAssertEqual(pair.session.connectedPlayerIndices, [1, 2])
        XCTAssertEqual(pair.session.connectedUserIDs, [101, 202])
        try pair.client.execute("assert(Player(202):IsValid() and Player(2) == NULL)")
        try second.execute(
            "assert(LocalPlayer() == Player(202) and Player(101):IsValid() and Player(1) == NULL)"
        )
    }

    func testTwoThreadCloseVersusConnectCompletesWithoutLockOrderDeadlock() throws {
        let queue = DispatchQueue(
            label: "GMLuaSharedSessionTests.closeVersusConnect",
            attributes: .concurrent
        )
        for iteration in 0..<20 {
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
            let start = DispatchSemaphore(value: 0)
            let workers = DispatchGroup()
            let connectResult = SharedSessionAsyncResult()

            workers.enter()
            queue.async {
                start.wait()
                connectResult.record(Result {
                    try session.connect(
                        server: server,
                        client: client,
                        playerIndex: iteration + 1,
                        userID: iteration + 101
                    )
                })
                workers.leave()
            }
            workers.enter()
            queue.async {
                start.wait()
                _ = client.close()
                workers.leave()
            }
            start.signal()
            start.signal()

            XCTAssertEqual(
                workers.wait(timeout: .now() + 2),
                .success,
                "connect/close lock-order deadlock at iteration \(iteration)"
            )
            XCTAssertTrue(client.isClosed)
            XCTAssertEqual(session.connectedClientCount, 0)
            XCTAssertFalse(
                GMLuaTypeSystem.typedObject(
                    from: try XCTUnwrap(server.entityRegistry).player(at: iteration + 1)
                )?.isValid == true,
                "close left a SERVER Player mirror after racing a successful connect"
            )
            if case let .failure(error) = try XCTUnwrap(connectResult.value) {
                let description = String(describing: error)
                XCTAssertTrue(
                    description.contains("closed CLIENT") ||
                        description.contains("CLIENT endpoint is detached"),
                    "unexpected connect/close race error: \(description)"
                )
            }
            _ = server.close()
        }
    }

    func testManagedSessionDoesNotDeliverServerBroadcastBeforeExplicitConnection() throws {
        let pair = makePair()
        defer {
            _ = pair.client.close()
            _ = pair.server.close()
        }
        try installNetDispatch(in: pair.client)
        try pair.server.execute(
            """
            util.AddNetworkString("pre_connection")
            net.Start("pre_connection")
            net.Broadcast()
            """
        )
        XCTAssertEqual(
            pair.session.netTransport.pendingDeliveryCount,
            0,
            "a shared session must not address a CLIENT before explicit connection"
        )
    }

    private func makePair() -> (
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
        return (session, server, client)
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
            sourceName: "=(shared session net dispatch)"
        )
    }
}
