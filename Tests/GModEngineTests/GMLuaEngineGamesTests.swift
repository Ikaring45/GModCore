import Foundation
import XCTest
import GModEngine

final class GMLuaEngineGamesTests: XCTestCase {
    func testConfiguredAddonSnapshotUsesDocumentedEightFieldABI() throws {
        let runtime = GMLuaRuntime(
            realm: .client,
            logger: { _ in },
            engineConfiguration: GMLuaEngineConfiguration(
                games: [],
                addons: [GMLuaMountedAddon(
                    downloaded: true,
                    models: 12,
                    title: "Host addon",
                    file: "addons/host_addon.gma",
                    mounted: true,
                    workshopID: "123456789",
                    size: 4_096,
                    updated: 123_456
                )],
                isPlayingDemo: false,
                isRecordingDemo: false
            )
        )

        try runtime.execute(
            """
            local addons = engine.GetAddons()
            assert(#addons == 1)
            local addon = addons[1]
            assert(addon.downloaded and addon.mounted and addon.models == 12)
            assert(addon.title == "Host addon")
            assert(addon.file == "addons/host_addon.gma")
            assert(addon.wsid == "123456789")
            assert(addon.size == 4096 and addon.updated == 123456)
            addons[1].title = "mutated"
            assert(engine.GetAddons()[1].title == "Host addon")
            """,
            sourceName: "@GMLuaEngineAddonSnapshotRegression.lua"
        )
    }

    func testConfiguredGamesMatchHostSnapshotAndResultsDoNotAliasIt() throws {
        let configuration = GMLuaEngineConfiguration(games: [
            try GMLuaMountedGame(
                depot: 220,
                title: "Half-Life 2",
                folder: "hl2",
                owned: true,
                installed: true,
                mounted: true
            ),
            try GMLuaMountedGame(
                depot: 240,
                title: "Counter-Strike",
                folder: "cstrike",
                owned: false,
                installed: false,
                mounted: false
            )
        ], isPlayingDemo: false, isRecordingDemo: true)
        let runtime = GMLuaRuntime(
            realm: .client,
            logger: { _ in },
            engineConfiguration: configuration
        )
        let fixtureURL = try XCTUnwrap(
            Bundle.module.url(
                forResource: "GLuaEngineGamesRegression",
                withExtension: "lua",
                subdirectory: "Fixtures"
            ) ?? Bundle.module.url(
                forResource: "GLuaEngineGamesRegression",
                withExtension: "lua"
            )
        )
        try runtime.execute(
            String(contentsOf: fixtureURL, encoding: .utf8),
            sourceName: "@GLuaEngineGamesRegression.lua"
        )
        try runtime.execute("assert(GLUA_ENGINE_GAMES_REGRESSION_OK == true)")
    }

    func testDisconnectedCallFailsAndConnectionChangesAreLive() throws {
        let runtime = GMLuaRuntime(realm: .server, logger: { _ in })
        let registry = try XCTUnwrap(runtime.engineRegistry)
        try runtime.execute(
            "assert(engine.IsPlayingDemo == nil); " +
                "assert(engine.IsRecordingDemo == nil)"
        )

        let disconnected = try runtime.executeReturningValues(
            "local ok, err = pcall(engine.GetGames); return ok, err"
        )
        XCTAssertEqual(disconnected.first?.printable, "false")
        XCTAssertTrue(
            disconnected.dropFirst().first?.printable.contains(
                "no host engine registry is connected"
            ) == true
        )

        registry.connect(GMLuaEngineConfiguration(
            games: [],
            isPlayingDemo: false,
            isRecordingDemo: false
        ))
        try runtime.execute("assert(#engine.GetGames() == 0)")

        registry.connect(GMLuaEngineConfiguration(games: [
            try GMLuaMountedGame(
                depot: 4000,
                title: "Garry's Mod",
                folder: "garrysmod",
                owned: true,
                installed: true,
                mounted: true
            )
        ], isPlayingDemo: true, isRecordingDemo: false))
        try runtime.execute(
            "local games = engine.GetGames(); " +
                "assert(#games == 1 and games[1].folder == 'garrysmod')"
        )

        registry.disconnect()
        let disconnectedAgain = try runtime.executeReturningValues(
            "local ok = pcall(engine.GetGames); return ok"
        )
        XCTAssertEqual(disconnectedAgain.first?.printable, "false")
    }

    func testClientDemoQueriesRequireAndTrackHostState() throws {
        let runtime = GMLuaRuntime(realm: .client, logger: { _ in })
        let registry = try XCTUnwrap(runtime.engineRegistry)
        let missing = try runtime.executeReturningValues(
            "local ok, err = pcall(engine.IsPlayingDemo); return ok, err"
        )
        XCTAssertEqual(missing.first?.printable, "false")
        XCTAssertTrue(
            missing.dropFirst().first?.printable.contains(
                "no host engine registry is connected"
            ) == true
        )

        registry.connect(GMLuaEngineConfiguration(
            games: [],
            isPlayingDemo: true,
            isRecordingDemo: false
        ))
        try runtime.execute(
            "assert(engine.IsPlayingDemo()); assert(not engine.IsRecordingDemo())"
        )
    }

    func testDescriptorRejectsUnrepresentableOrPathLikeHostValues() throws {
        XCTAssertThrowsError(try GMLuaMountedGame(
            depot: 0,
            title: "Half-Life 2",
            folder: "hl2",
            owned: true,
            installed: true,
            mounted: true
        ))
        XCTAssertThrowsError(try GMLuaMountedGame(
            depot: 220,
            title: " ",
            folder: "hl2",
            owned: true,
            installed: true,
            mounted: true
        ))
        XCTAssertThrowsError(try GMLuaMountedGame(
            depot: 220,
            title: "Half-Life 2",
            folder: "games/hl2",
            owned: true,
            installed: true,
            mounted: true
        ))
    }
}
