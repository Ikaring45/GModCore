import Foundation
import XCTest
import GModEngine

final class GMLuaGameEnvironmentTests: XCTestCase {
    func testConfiguredSessionQueriesMatchHostFacts() throws {
        let configuration = try GMLuaGameEnvironmentConfiguration(
            maxPlayers: 24,
            mapName: "ttt_minecraft_b5",
            sessionKind: .dedicatedServer
        )
        let runtime = GMLuaRuntime(
            realm: .server,
            logger: { _ in },
            gameEnvironmentConfiguration: configuration
        )
        let fixtureURL = try XCTUnwrap(
            Bundle.module.url(
                forResource: "GLuaGameEnvironmentRegression",
                withExtension: "lua",
                subdirectory: "Fixtures"
            ) ?? Bundle.module.url(
                forResource: "GLuaGameEnvironmentRegression",
                withExtension: "lua"
            )
        )
        try runtime.execute(
            String(contentsOf: fixtureURL, encoding: .utf8),
            sourceName: "@GLuaGameEnvironmentRegression.lua"
        )
        try runtime.execute(
            "assert(GLUA_GAME_ENVIRONMENT_REGRESSION_OK == true)"
        )
    }

    func testConnectionChangesAreLiveAndDisconnectedCallsFailHonestly() throws {
        let runtime = GMLuaRuntime(realm: .client, logger: { _ in })
        let environment = try XCTUnwrap(runtime.gameEnvironment)

        let missing = try runtime.executeReturningValues(
            "local ok, err = pcall(game.MaxPlayers); return ok, err"
        )
        XCTAssertEqual(missing.first?.printable, "false")
        XCTAssertTrue(
            missing.dropFirst().first?.printable.contains(
                "no host game environment is connected"
            ) == true
        )

        environment.connect(try GMLuaGameEnvironmentConfiguration(
            maxPlayers: 1,
            mapName: "gm_flatgrass",
            sessionKind: .singlePlayer
        ))
        try runtime.execute(
            "assert(game.MaxPlayers() == 1); " +
                "assert(game.GetMap() == 'gm_flatgrass'); " +
                "assert(game.SinglePlayer()); assert(not game.IsDedicated())"
        )

        environment.disconnect()
        let disconnected = try runtime.executeReturningValues(
            "local ok, err = pcall(game.GetMap); return ok, err"
        )
        XCTAssertEqual(disconnected.first?.printable, "false")
        XCTAssertTrue(
            disconnected.dropFirst().first?.printable.contains(
                "no host game environment is connected"
            ) == true
        )
    }

    func testMenuMapIsDocumentedConstantWithoutGameplayConnection() throws {
        let runtime = GMLuaRuntime(realm: .menu, logger: { _ in })
        try runtime.execute("assert(game.GetMap() == 'menu')")
        let result = try runtime.executeReturningValues(
            "local ok, err = pcall(game.SinglePlayer); return ok, err"
        )
        XCTAssertEqual(result.first?.printable, "false")
    }

    func testConfigurationRejectsValuesThatWouldMisrepresentTheHost() throws {
        XCTAssertThrowsError(try GMLuaGameEnvironmentConfiguration(
            maxPlayers: 0,
            mapName: "gm_construct",
            sessionKind: .listenServer
        ))
        XCTAssertThrowsError(try GMLuaGameEnvironmentConfiguration(
            maxPlayers: 16,
            mapName: "maps/gm_construct.bsp",
            sessionKind: .listenServer
        ))
    }
}
