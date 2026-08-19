import Foundation
import XCTest
import GModEngine
import GModLua

private final class LockedSoundEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [GMLuaSoundPlayEvent] = []

    func append(_ event: GMLuaSoundPlayEvent) {
        lock.lock()
        storage.append(event)
        lock.unlock()
    }

    var values: [GMLuaSoundPlayEvent] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

final class GMLuaSoundTests: XCTestCase {
    func testRuntimeRetainsSharedLogicalSoundRegistry() throws {
        for realm in [GMLuaRealm.server, .client, .menu] {
            let runtime = GMLuaRuntime(realm: realm, logger: { _ in })
            let sounds = try XCTUnwrap(runtime.sound)
            XCTAssertEqual(sounds.realm, realm)
            XCTAssertFalse(sounds.hasAudioBacking)
            try runtime.execute(
                """
                sound.Add({ name = "runtime.cue", channel = CHAN_STATIC, sound = "ui/cue.wav" })
                assert(Sound("runtime.cue") == "runtime.cue")
                """,
                sourceName: "@GMLuaRuntimeSoundRegression.lua"
            )
            XCTAssertEqual(sounds.script(named: "runtime.cue")?.channel, 6)
        }
    }

    func testOriginalFixtureRegistersSoundDataAndEmitsLogicalPlayEvents() throws {
        let state = LuaState(output: { _ in })
        let typeSystem = try GMLuaTypeSystem.install(into: state)
        try GMLuaVectorAngle.install(into: state, typeSystem: typeSystem)
        let sink = LockedSoundEvents()
        let sounds = try GMLuaSound.install(
            into: state,
            realm: .client,
            playSink: { sink.append($0) }
        )

        try state.execute(try fixtureSource(), sourceName: "@GLuaSoundRegistryRegression.lua")
        guard case .boolean(true) = state.getGlobal("GLUA_SOUND_REGRESSION_READY") else {
            return XCTFail("sound fixture did not reach its sentinel")
        }

        XCTAssertFalse(sounds.hasAudioBacking)
        XCTAssertEqual(
            sounds.registeredSoundNames,
            [LuaString("TTT.MessageCue"), LuaString("Synthetic.Range")]
        )
        XCTAssertEqual(
            sounds.script(named: "TTT.MessageCue"),
            GMLuaSoundScript(
                name: "TTT.MessageCue",
                channel: 3,
                level: 75,
                volume: .scalar(1),
                pitch: .scalar(100),
                pitchStart: 100,
                pitchEnd: 100,
                sound: .single("fixtures/replaced-message-cue.wav")
            )
        )

        let expectedEvents = [
            GMLuaSoundPlayEvent(
                realm: .client,
                sound: "TTT.MessageCue",
                x: 1,
                y: 2,
                z: 3,
                level: 80,
                pitch: 120,
                volume: 0.5,
                dsp: 4
            ),
            GMLuaSoundPlayEvent(
                realm: .client,
                sound: "Synthetic.Range",
                x: -4,
                y: 5,
                z: 6,
                level: 75,
                pitch: 100,
                volume: 1,
                dsp: 0
            )
        ]
        XCTAssertEqual(sounds.capturedPlayEvents, expectedEvents)
        XCTAssertEqual(sink.values, expectedEvents)
        XCTAssertTrue(sounds.capturedPlayEvents.allSatisfy { !$0.hasAudioBacking })
        XCTAssertEqual(sounds.drainCapturedPlayEvents(), expectedEvents)
        XCTAssertTrue(sounds.capturedPlayEvents.isEmpty)
    }

    func testSharedInstallationPreservesExistingSoundTableAndExactCHANValues() throws {
        let expected = GMLuaSound.channelConstants
        for realm in [GMLuaRealm.server, .client, .menu] {
            let state = LuaState()
            try state.execute("sound = { Existing = 72 }")
            let sounds = try GMLuaSound.install(into: state, realm: realm)
            XCTAssertEqual(sounds.realm, realm)
            try state.execute(
                "assert(sound.Existing == 72 and type(sound.Add) == 'function' and Sound('raw') == 'raw')"
            )
            for (name, value) in expected {
                guard case let .number(actual) = state.getGlobal(name) else {
                    return XCTFail("missing \(name) in \(realm.rawValue)")
                }
                XCTAssertEqual(actual, Double(value), name)
            }
        }
    }

    func testRegistryCopiesLuaTablesAndStateIsIsolated() throws {
        let firstState = LuaState()
        let first = try GMLuaSound.install(into: firstState, realm: .client)
        try firstState.execute(
            """
            local files = { "a.wav", "b.wav" }
            local definition = { name = "copied", sound = files, pitch = { 80, 120 } }
            sound.Add(definition)
            files[1] = "mutated.wav"
            definition.name = "mutated"
            assert(sound.GetProperties("copied").sound[1] == "a.wav")
            """
        )
        XCTAssertEqual(
            first.script(named: "copied")?.sound,
            .choices(["a.wav", "b.wav"])
        )

        let secondState = LuaState()
        let second = try GMLuaSound.install(into: secondState, realm: .client)
        XCTAssertNil(second.script(named: "copied"))
        try secondState.execute("assert(sound.GetProperties('copied') == nil)")
    }

    func testInvalidSoundDataFailsWithoutPartialRegistration() throws {
        let state = LuaState()
        let sounds = try GMLuaSound.install(into: state, realm: .server)
        try state.execute(
            """
            local ok1 = pcall(sound.Add, { name = "missing" })
            local ok2 = pcall(sound.Add, { name = "bad-choice", sound = { "ok.wav", 4 } })
            local ok3 = pcall(sound.Add, { name = "bad-range", sound = "ok.wav", pitch = { 90 } })
            local ok4 = pcall(sound.Add, { name = "bad-channel", sound = "ok.wav", channel = 1.5 })
            assert(not ok1 and not ok2 and not ok3 and not ok4)
            """
        )
        XCTAssertTrue(sounds.registeredSoundNames.isEmpty)
    }

    private func fixtureSource() throws -> String {
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: "GLuaSoundRegistryRegression",
                withExtension: "lua",
                subdirectory: "Fixtures"
            ) ?? Bundle.module.url(
                forResource: "GLuaSoundRegistryRegression",
                withExtension: "lua"
            )
        )
        return try String(contentsOf: url, encoding: .utf8)
    }
}
