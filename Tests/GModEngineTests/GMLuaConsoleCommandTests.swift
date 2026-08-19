import Foundation
import XCTest
import GModEngine

final class GMLuaConsoleCommandTests: XCTestCase {
    private final class InvocationRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [GMLuaConsoleCommandInvocation] = []

        func append(_ invocation: GMLuaConsoleCommandInvocation) {
            lock.lock()
            storage.append(invocation)
            lock.unlock()
        }

        var first: GMLuaConsoleCommandInvocation? {
            lock.lock()
            defer { lock.unlock() }
            return storage.first
        }

        var values: [GMLuaConsoleCommandInvocation] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    func testRunConsoleCommandMutatesOnlyLuaOwnedConVarsAndReturnsNothing() throws {
        let runtime = GMLuaRuntime(
            realm: .server,
            logger: { _ in },
            bootstrapMode: .strict
        )
        defer { _ = runtime.close() }

        // Original synthetic regression; no installed game source is embedded.
        try runtime.execute(
            """
            local value = CreateConVar("gpad_console_value", "1", 0, "", -20, 20)
            assert(select("#", RunConsoleCommand("GPAD_CONSOLE_VALUE", 12.5)) == 0)
            assert(value:GetString() == "12.5")
            RunConsoleCommand("gpad_console_value")
            assert(value:GetString() == "12.5")

            local ok, message = pcall(RunConsoleCommand, "gpad_console_value", true)
            assert(not ok)
            assert(string.find(message, "bad argument #2", 1, true))

            ok, message = pcall(RunConsoleCommand, "gpad_console_value", "bad\0value")
            assert(not ok)
            assert(string.find(message, "NUL bytes", 1, true))
            """,
            sourceName: "=(synthetic console ConVar regression)"
        )
    }

    func testHostReceivesSeparatedArgumentsAndOwnsUnknownOrRejectedCommands() throws {
        let runtime = GMLuaRuntime(
            realm: .server,
            logger: { _ in },
            bootstrapMode: .strict
        )
        defer { _ = runtime.close() }
        let dispatcher = try XCTUnwrap(runtime.consoleCommandDispatcher)
        let invocations = InvocationRecorder()

        dispatcher.connectHost { invocation in
            invocations.append(invocation)
            if invocation.command == "mp_friendlyfire" { return .handled }
            if invocation.command == "quit" { return .rejected(reason: "not permitted") }
            return .unhandled
        }

        try runtime.execute(
            """
            assert(select("#", RunConsoleCommand("mp_friendlyfire", "1", 2)) == 0)
            """,
            sourceName: "=(synthetic host console dispatch)"
        )
        XCTAssertEqual(invocations.first, GMLuaConsoleCommandInvocation(
            realm: .server,
            command: "mp_friendlyfire",
            arguments: ["1", "2"]
        ))

        XCTAssertThrowsError(
            try runtime.execute("RunConsoleCommand('quit')", sourceName: "=(rejected command)")
        ) { error in
            XCTAssertTrue(GMLuaRuntime.describe(error).contains(
                "host rejected command 'quit': not permitted"
            ))
        }
        XCTAssertThrowsError(
            try runtime.execute("RunConsoleCommand('not_real')", sourceName: "=(unknown command)")
        ) { error in
            XCTAssertTrue(GMLuaRuntime.describe(error).contains(
                "host did not recognize engine command 'not_real'"
            ))
        }

        dispatcher.disconnectHost()
        XCTAssertThrowsError(
            try runtime.execute(
                "RunConsoleCommand('mp_friendlyfire', '1')",
                sourceName: "=(disconnected command)"
            )
        ) { error in
            XCTAssertTrue(GMLuaRuntime.describe(error).contains("no console host is connected"))
        }
    }

    func testEngineOwnedConVarSetterAndQueryFallThroughToHost() throws {
        let catalog = try GMLuaEngineConVarCatalog(descriptors: [
            GMLuaEngineConVarDescriptor(name: "gmod_language", defaultValue: "en")
        ])
        let runtime = GMLuaRuntime(
            realm: .client,
            logger: { _ in },
            bootstrapMode: .strict,
            engineConVarCatalog: catalog
        )
        defer { _ = runtime.close() }
        let dispatcher = try XCTUnwrap(runtime.consoleCommandDispatcher)
        let invocations = InvocationRecorder()

        dispatcher.connectHost { invocation in
            invocations.append(invocation)
            guard invocation.command.lowercased() == "gmod_language" else {
                return .unhandled
            }
            if let value = invocation.arguments.first {
                _ = catalog.setCurrentValue(value, for: invocation.command)
            }
            return .handled
        }

        try runtime.execute(
            """
            local local_value = CreateConVar("gpad_local_value", "1")
            RunConsoleCommand("GPAD_LOCAL_VALUE", "2")
            assert(local_value:GetString() == "2")
            RunConsoleCommand("gpad_local_value")

            RunConsoleCommand("GMOD_LANGUAGE", "ja")
            assert(GetConVar("gmod_language"):GetString() == "ja")
            RunConsoleCommand("gmod_language")
            """,
            sourceName: "=(engine ConVar host console dispatch)"
        )

        XCTAssertThrowsError(
            try runtime.execute(
                "RunConsoleCommand('not_catalogued', 'value')",
                sourceName: "=(unknown console command remains explicit)"
            )
        ) { error in
            XCTAssertTrue(GMLuaRuntime.describe(error).contains(
                "host did not recognize engine command 'not_catalogued'"
            ))
        }
        XCTAssertEqual(invocations.values, [
            GMLuaConsoleCommandInvocation(
                realm: .client,
                command: "GMOD_LANGUAGE",
                arguments: ["ja"]
            ),
            GMLuaConsoleCommandInvocation(
                realm: .client,
                command: "gmod_language",
                arguments: []
            ),
            GMLuaConsoleCommandInvocation(
                realm: .client,
                command: "not_catalogued",
                arguments: ["value"]
            )
        ])
        XCTAssertEqual(catalog.currentValue(for: "gmod_language"), "ja")
    }

    func testServerLuaCommandsDispatchThroughConcommandRunWithNullCaller() throws {
        let runtime = GMLuaRuntime(
            realm: .server,
            logger: { _ in },
            bootstrapMode: .strict
        )
        defer { _ = runtime.close() }
        try XCTUnwrap(runtime.consoleCommandDispatcher).connectHost { _ in .unhandled }

        // Minimal original oracle for the public concommand.Run engine ABI.
        try runtime.execute(
            """
            concommand = {}
            local calls = 0
            function concommand.Run(ply, command, args, argStr)
                calls = calls + 1
                assert(ply == NULL)
                assert(command == "gPaD_CoMmAnD")
                assert(#args == 3)
                assert(args[1] == "first")
                assert(args[2] == "has space")
                assert(args[3] == "3")
                assert(argStr == "first has space 3")
                return true
            end

            AddConsoleCommand("GPAD_COMMAND", "fixture", 0)
            assert(RunConsoleCommand("gPaD_CoMmAnD", "first", "has space", 3) == nil)
            assert(calls == 1)

            local variable = CreateConVar("gpad_conflict", "old")
            AddConsoleCommand("GPAD_CONFLICT", "must not register", 0)
            RunConsoleCommand("gpad_conflict", "new")
            assert(variable:GetString() == "new")
            assert(calls == 1)
            """,
            sourceName: "=(synthetic Lua console command dispatch)"
        )
        XCTAssertEqual(runtime.consoleCommands, ["GPAD_COMMAND"])
    }

    func testClientLuaCommandNeedsHostOwnedPlayerContext() throws {
        let runtime = GMLuaRuntime(
            realm: .client,
            logger: { _ in },
            bootstrapMode: .strict
        )
        defer { _ = runtime.close() }
        try runtime.execute("AddConsoleCommand('gpad_client_command')")

        XCTAssertThrowsError(
            try runtime.execute("RunConsoleCommand('gpad_client_command')")
        ) { error in
            XCTAssertTrue(GMLuaRuntime.describe(error).contains(
                "without a host-owned player context"
            ))
        }
    }
}
