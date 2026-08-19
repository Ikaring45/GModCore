import Foundation
import XCTest
import GModEngine
import GModLua

private final class LockedCursorWarpRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [GMLuaCursorPosition] = []

    func append(_ position: GMLuaCursorPosition) {
        lock.lock()
        storage.append(position)
        lock.unlock()
    }

    var values: [GMLuaCursorPosition] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

final class GMLuaInputTests: XCTestCase {
    func testOriginalFixtureUsesExplicitBindingsAndHostFedState() throws {
        let state = LuaState(output: { _ in })
        let cursorRequests = LockedCursorWarpRequests()
        let input = try XCTUnwrap(
            GMLuaInput.install(
                into: state,
                realm: .client,
                configuration: GMLuaInputConfiguration(
                    bindingsByButton: [
                        15: "+use",
                        11: "+use",
                        79: "+speed",
                        108: "+attack2"
                    ],
                    buttonNames: [
                        11: "a",
                        15: "e",
                        79: "shift",
                        108: "mouse2"
                    ],
                    cursorPosition: GMLuaCursorPosition(x: 41, y: 73)
                ),
                cursorWarpSink: { cursorRequests.append($0) }
            )
        )

        try state.execute(try fixtureSource(), sourceName: "@GLuaInputRegression.lua")
        guard case .boolean(true) = state.getGlobal("GLUA_INPUT_REGRESSION_READY") else {
            return XCTFail("input fixture did not reach its host-handoff sentinel")
        }
        XCTAssertEqual(
            cursorRequests.values,
            [GMLuaCursorPosition(x: 320.5, y: 240.25)]
        )
        XCTAssertEqual(input.cursorPosition, GMLuaCursorPosition(x: 320.5, y: 240.25))

        // This is the platform handoff: only explicit host transitions can
        // make an input query true or satisfy a key trap.
        input.updateKey(17, isDown: true)
        input.updateKey(GMLuaInput.leftShiftKey, isDown: true)
        input.updateKey(GMLuaInput.leftControlKey, isDown: true)
        input.updateMouseButton(107, isDown: true)
        input.updateButton(150, isDown: true)

        let result = try state.executeReturningValues(
            "return GLUA_INPUT_ASSERT_HOST_STATE()",
            sourceName: "@GMLuaInputHostHandoff.lua"
        ).first
        guard let result, case .boolean(true) = result else {
            return XCTFail("host-fed input assertions did not complete")
        }
    }

    func testEmptyConfigurationDoesNotInventBindingsOrPressedInput() throws {
        let state = LuaState()
        let input = try XCTUnwrap(
            GMLuaInput.install(into: state, realm: .client)
        )
        input.replacePressedKeys([])
        input.replacePressedMouseButtons([])
        input.replacePressedOtherButtons([])
        XCTAssertFalse(input.isKeyDown(15))
        XCTAssertFalse(input.isMouseButtonDown(107))
        XCTAssertFalse(input.isButtonDown(150))
        try state.execute(
            """
            assert(input.LookupBinding('+use') == nil)
            assert(input.LookupKeyBinding(15) == nil)
            assert(input.GetKeyName(15) == nil)
            assert(input.IsKeyDown(15) == false)
            assert(input.IsMouseDown(107) == false)
            assert(input.IsButtonDown(150) == false)
            local x, y = input.GetCursorPos()
            assert(x == 0 and y == 0)
            """,
            sourceName: "@GMLuaInputEmptyHostState.lua"
        )
    }

    func testButtonCodeConversionRejectsIntOverflowWithoutTrapping() throws {
        let state = LuaState()
        _ = try XCTUnwrap(GMLuaInput.install(into: state, realm: .client))
        try state.execute(
            """
            local upper_ok, upper_err = pcall(input.GetKeyName, 9223372036854775808)
            assert(not upper_ok and string.find(upper_err, "BUTTON_CODE out of range", 1, true))
            local nan_ok = pcall(input.IsKeyDown, 0/0)
            local inf_ok = pcall(input.IsMouseDown, 1/0)
            assert(not nan_ok and not inf_ok)
            """,
            sourceName: "@GMLuaInputButtonRangeRegression.lua"
        )
    }

    func testInstallIsClientAndMenuOnlyAndPreservesExistingTable() throws {
        for realm in [GMLuaRealm.client, .menu] {
            let state = LuaState()
            try state.execute("input = { Existing = 72 }")
            let input = try XCTUnwrap(
                GMLuaInput.install(
                    into: state,
                    realm: realm,
                    configuration: GMLuaInputConfiguration(
                        bindingsByButton: [15: "+use"],
                        buttonNames: [15: "e"]
                    )
                )
            )
            XCTAssertEqual(input.realm, realm)
            try state.execute(
                "assert(input.Existing == 72 and input.LookupBinding('+use') == 'e')"
            )
        }

        let server = LuaState()
        try server.execute("input = { ServerOwned = true }")
        XCTAssertNil(try GMLuaInput.install(into: server, realm: .server))
        try server.execute(
            "assert(input.ServerOwned == true and input.LookupBinding == nil)"
        )
    }

    func testRuntimeRetainsTheClientInputBridgeAndConfiguration() throws {
        let runtime = GMLuaRuntime(
            realm: .client,
            logger: { _ in },
            inputConfiguration: GMLuaInputConfiguration(
                bindingsByButton: [15: "+use"],
                buttonNames: [15: "e"]
            )
        )
        let input = try XCTUnwrap(runtime.input)
        try runtime.execute(
            "assert(input.LookupBinding('+use') == 'e' and not input.IsKeyDown(15))"
        )
        input.updateKey(15, isDown: true)
        try runtime.execute("assert(input.IsKeyDown(15))")

        let server = GMLuaRuntime(realm: .server, logger: { _ in })
        XCTAssertNil(server.input)
        try server.execute("assert(input == nil)")
    }

    func testDynamicHostConfigurationAndTrapRequiresNewPressTransition() throws {
        let state = LuaState()
        let input = try XCTUnwrap(
            GMLuaInput.install(into: state, realm: .menu)
        )
        input.setButtonName("q", forButton: 27)
        input.setBinding("+menu", forButton: 27)
        input.updateKey(27, isDown: true)

        try state.execute(
            """
            assert(input.LookupBinding('+menu') == 'q')
            input.StartKeyTrapping()
            assert(input.CheckKeyTrapping() == nil)
            """
        )
        input.updateKey(27, isDown: true)
        try state.execute("assert(input.CheckKeyTrapping() == nil)")
        input.updateKey(27, isDown: false)
        input.updateKey(27, isDown: true)
        try state.execute(
            "assert(input.IsKeyTrapping() and input.CheckKeyTrapping() == 27 and not input.IsKeyTrapping())"
        )

        input.setBinding(nil, forButton: 27)
        input.setButtonName(nil, forButton: 27)
        try state.execute(
            "assert(input.LookupBinding('+menu') == nil and input.GetKeyName(27) == nil)"
        )
    }

    private func fixtureSource() throws -> String {
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: "GLuaInputRegression",
                withExtension: "lua",
                subdirectory: "Fixtures"
            ) ?? Bundle.module.url(
                forResource: "GLuaInputRegression",
                withExtension: "lua"
            )
        )
        return try String(contentsOf: url, encoding: .utf8)
    }
}
