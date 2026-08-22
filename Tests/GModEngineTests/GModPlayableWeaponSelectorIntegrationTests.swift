@testable import GModEngine
@testable import GModGameSession
import GModLua
import XCTest

final class GModPlayableWeaponSelectorIntegrationTests: XCTestCase {
    func testLaneCatalogQueuesNextAndOrderedDrainUpdatesBothRealms() async throws {
        let lane = GModPlayableSessionLane()
        let configuration = GModPlayableSessionConfiguration(map: .construct)
        let started = try await lane.start(configuration: configuration)
        do {
            try await lane.execute(
                """
                local ply = Player(\(configuration.playerUserID))
                ply:Give("gmod_tool")
                ply:Give("gmod_camera")
                ply:SelectWeapon("gmod_camera")
                """,
                realm: .server,
                sourceName: "=(selector integration inventory)",
                expectedGeneration: started.generation
            )
            let baseline = try await lane.runHostFrame(
                fixedTickCount: 1,
                renderClientFrame: false,
                expectedGeneration: started.generation
            )
            XCTAssertEqual(baseline.actionFailures, [])

            let cameraCatalog = try await lane.clientOwnedWeaponSelectorCatalog(
                expectedGeneration: started.generation
            )
            XCTAssertEqual(cameraCatalog.entries.map(\.className), [
                "gmod_camera", "gmod_tool",
            ])
            XCTAssertEqual(cameraCatalog.activeEntry?.className, "gmod_camera")

            let requestedNext = try await lane.requestNextWeapon(
                expectedGeneration: started.generation
            )
            XCTAssertEqual(requestedNext, "gmod_tool")
            // CLIENT `use` is delivered after this SERVER simulation tick.
            // The resulting canonical Player update is appended to the same
            // ordered drain and reaches CLIENT before the frame returns.
            let nextDrain = try await lane.runHostFrame(
                fixedTickCount: 1,
                renderClientFrame: false,
                expectedGeneration: started.generation
            )
            XCTAssertEqual(nextDrain.actionFailures, [])
            try await lane.execute(
                """
                local ply = Player(\(configuration.playerUserID))
                assert(ply:GetActiveWeapon():GetClass() == "gmod_tool")
                """,
                realm: .server,
                sourceName: "=(selector SERVER next result)",
                expectedGeneration: started.generation
            )
            let toolCatalog = try await lane.clientOwnedWeaponSelectorCatalog(
                expectedGeneration: started.generation
            )
            XCTAssertEqual(toolCatalog.activeEntry?.className, "gmod_tool")

            let requestedPrevious = try await lane.requestPreviousWeapon(
                expectedGeneration: started.generation
            )
            XCTAssertEqual(requestedPrevious, "gmod_camera")
            _ = try await lane.runHostFrame(
                fixedTickCount: 1,
                renderClientFrame: false,
                expectedGeneration: started.generation
            )
            let previousCatalog = try await lane.clientOwnedWeaponSelectorCatalog(
                expectedGeneration: started.generation
            )
            XCTAssertEqual(previousCatalog.activeEntry?.className, "gmod_camera")

            let requestedExact = try await lane.requestWeaponSelection(
                className: "gmod_tool",
                expectedGeneration: started.generation
            )
            XCTAssertEqual(requestedExact, "gmod_tool")
            _ = try await lane.runHostFrame(
                fixedTickCount: 1,
                renderClientFrame: false,
                expectedGeneration: started.generation
            )
            let exactCatalog = try await lane.clientOwnedWeaponSelectorCatalog(
                expectedGeneration: started.generation
            )
            XCTAssertEqual(exactCatalog.activeEntry?.className, "gmod_tool")
            _ = try await lane.close(expectedGeneration: started.generation)
        } catch {
            _ = try? await lane.close()
            throw error
        }
    }

    func testSelectionRejectsClassOutsideExactClientCatalog() throws {
        let session = try GModPlayableSession(
            configuration: .init(map: .construct),
            textMeasurer: nil,
            logger: { _, _ in }
        )
        defer { _ = try? session.close() }
        try session.serverRuntime.execute(
            """
            local ply = Player(1)
            ply:Give("gmod_tool")
            ply:SelectWeapon("gmod_tool")
            """,
            sourceName: "=(exact selector class inventory)"
        )
        _ = try session.runFixedTick()

        XCTAssertThrowsError(
            try session.requestWeaponSelection(className: "GMOD_TOOL")
        ) { error in
            XCTAssertEqual(
                error as? GModPlayableWeaponSelectionError,
                .classNotInCatalog("GMOD_TOOL")
            )
        }
        XCTAssertEqual(session.sharedSession.netTransport.pendingDeliveryCount, 0)
    }

    func testClientConsoleAPIUsesSeparateValuesAndTypedBoundaryFailures() throws {
        let runtime = GMLuaRuntime(realm: .client, logger: { _ in })
        try runtime.execute(
            """
            function RunConsoleCommand(...)
                CAPTURED_CONSOLE_VALUES = { ... }
            end
            """
        )
        let syntaxLikeArgument = "gmod_tool\"); error('injected') --"
        try runtime.invokeClientRunConsoleCommand(
            command: "use",
            arguments: [syntaxLikeArgument]
        )
        guard case let .table(captured) = runtime.state.getGlobal(
            "CAPTURED_CONSOLE_VALUES"
        ) else {
            _ = runtime.close()
            return XCTFail("RunConsoleCommand arguments were not captured")
        }
        XCTAssertEqual(
            try string(at: 1, in: captured, runtime: runtime),
            "use"
        )
        XCTAssertEqual(
            try string(at: 2, in: captured, runtime: runtime),
            syntaxLikeArgument
        )

        runtime.state.setGlobal("RunConsoleCommand", value: .nilValue)
        XCTAssertThrowsError(
            try runtime.invokeClientRunConsoleCommand(command: "use")
        ) { error in
            XCTAssertEqual(
                error as? GMLuaClientConsoleCommandInvocationError,
                .runConsoleCommandUnavailable(actualType: "nil")
            )
        }
        _ = runtime.close()
        XCTAssertThrowsError(
            try runtime.invokeClientRunConsoleCommand(command: "use")
        ) { error in
            XCTAssertEqual(
                error as? GMLuaClientConsoleCommandInvocationError,
                .runtimeClosed
            )
        }

        let server = GMLuaRuntime(realm: .server, logger: { _ in })
        defer { _ = server.close() }
        XCTAssertThrowsError(
            try server.invokeClientRunConsoleCommand(command: "use")
        ) { error in
            XCTAssertEqual(
                error as? GMLuaClientConsoleCommandInvocationError,
                .clientRealmRequired(actualRealm: "SERVER")
            )
        }
    }

    private func string(
        at index: Int,
        in table: LuaTable,
        runtime: GMLuaRuntime
    ) throws -> String {
        let value = try runtime.state.rawTableValue(
            for: .number(Double(index)),
            in: table
        )
        guard case let .string(bytes) = value,
              let result = String(bytes: bytes.bytes, encoding: .utf8) else {
            throw LuaError.runtime("captured console argument is not UTF-8")
        }
        return result
    }
}
