import Foundation
import XCTest
import GModEngine
import GModLua

private final class LockedChatEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [GMLuaChatEvent] = []

    func append(_ event: GMLuaChatEvent) {
        lock.lock()
        storage.append(event)
        lock.unlock()
    }

    var values: [GMLuaChatEvent] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

final class GMLuaChatTests: XCTestCase {
    func testStrictRuntimeInstallsAndRetainsChatOnlyInClient() throws {
        let client = GMLuaRuntime(realm: .client, logger: { _ in })
        try client.execute("chat.AddText('runtime event')")
        XCTAssertEqual(
            try XCTUnwrap(client.chat).capturedEvents,
            [GMLuaChatEvent(realm: .client, arguments: [.text("runtime event")])]
        )

        for realm in [GMLuaRealm.server, .menu] {
            let runtime = GMLuaRuntime(realm: realm, logger: { _ in })
            XCTAssertNil(runtime.chat)
            try runtime.execute("assert(chat == nil)")
        }
    }

    func testOriginalFixtureCapturesClLangStyleEventsInArgumentOrder() throws {
        let state = LuaState()
        let typeSystem = try GMLuaTypeSystem.install(
            into: state,
            utilityLayer: .bundledFallback
        )
        let entities = try GMLuaEntityRegistry.install(
            into: state,
            typeSystem: typeSystem
        )
        let player = try entities.register(
            index: 17,
            kind: .player,
            className: "player"
        )
        let entity = try entities.register(
            index: 18,
            kind: .entity,
            className: "prop_physics"
        )
        state.setGlobal("TEST_CHAT_PLAYER", value: player)
        state.setGlobal("TEST_CHAT_ENTITY", value: entity)

        let sinkEvents = LockedChatEvents()
        let chat = try XCTUnwrap(
            GMLuaChat.install(
                into: state,
                realm: .client,
                entityRegistry: entities,
                sink: { sinkEvents.append($0) }
            )
        )

        try state.execute(
            try fixtureSource(),
            sourceName: "@GLuaChatAddTextRegression.lua"
        )
        guard case .boolean(true) = state.getGlobal("GLUA_CHAT_ADDTEXT_REGRESSION_OK") else {
            return XCTFail("chat.AddText regression fixture did not reach its sentinel")
        }

        let expected = [
            GMLuaChatEvent(
                realm: .client,
                arguments: [
                    .color(GMLuaChatColorSnapshot(r: 255, g: 40, b: 50, a: 220)),
                    .text("localized warning")
                ]
            ),
            GMLuaChatEvent(
                realm: .client,
                arguments: [
                    .color(GMLuaChatColorSnapshot(r: 10, g: 20, b: 30, a: 40)),
                    .text(" plain "),
                    .player(
                        GMLuaChatPlayerSnapshot(
                            index: 17,
                            metaName: "Player",
                            wasValid: true
                        )
                    ),
                    .convertedText(sourceType: "number", text: "42.5"),
                    .convertedText(sourceType: "boolean", text: "false"),
                    .convertedText(sourceType: "nil", text: "nil"),
                    .convertedText(sourceType: "table", text: "synthetic-table"),
                    .convertedText(
                        sourceType: "userdata",
                        text: "synthetic-nonplayer-entity"
                    )
                ]
            ),
            GMLuaChatEvent(realm: .client, arguments: [])
        ]

        XCTAssertEqual(chat.capturedEvents, expected)
        XCTAssertEqual(sinkEvents.values, expected)
        XCTAssertEqual(chat.drainCapturedEvents(), expected)
        XCTAssertTrue(chat.capturedEvents.isEmpty)
    }

    func testInstallIsClientOnly() throws {
        let client = LuaState()
        let chat = try XCTUnwrap(GMLuaChat.install(into: client, realm: .client))
        try client.execute("chat.AddText('realm event')")
        XCTAssertEqual(
            chat.capturedEvents,
            [GMLuaChatEvent(realm: .client, arguments: [.text("realm event")])]
        )

        for realm in [GMLuaRealm.server, .menu] {
            let state = LuaState()
            XCTAssertNil(try GMLuaChat.install(into: state, realm: realm))
            guard case .nilValue = state.getGlobal("chat") else {
                return XCTFail("\(realm.rawValue) must not receive a synthetic chat library")
            }
        }
    }

    func testSnapshotsDoNotRetainLuaTablesOutsideTheCollector() throws {
        let state = LuaState()
        let chat = try XCTUnwrap(GMLuaChat.install(into: state, realm: .client))
        guard case let .table(chatTable) = state.getGlobal("chat") else {
            return XCTFail("chat table was not installed")
        }
        let addText = try state.rawTableValue(for: .string("AddText"), in: chatTable)

        weak var weakTable: LuaTable?
        do {
            let ephemeral = LuaTable()
            weakTable = ephemeral
            _ = try state.call(addText, arguments: [.table(ephemeral)])
        }

        XCTAssertEqual(chat.capturedEvents.count, 1)
        _ = state.close()
        XCTAssertNil(weakTable)
    }

    private func fixtureSource() throws -> String {
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: "GLuaChatAddTextRegression",
                withExtension: "lua",
                subdirectory: "Fixtures"
            ) ?? Bundle.module.url(
                forResource: "GLuaChatAddTextRegression",
                withExtension: "lua"
            )
        )
        return try String(contentsOf: url, encoding: .utf8)
    }
}
