import GModLua
import XCTest

final class Lua51StringFormatTests: XCTestCase {
    func testFormatQUsesLua51ByteEscaping() throws {
        let state = LuaState(output: { _ in })
        try state.execute(
            #"""
            local arbitrary = string.char(1, 9, 0xE4, 0xED, 0xFF)
            assert(string.format("%q", arbitrary) == '"' .. arbitrary .. '"')

            local special = string.char(34, 92, 10, 13, 0)
            local expected = string.char(
                34,
                92, 34,
                92, 92,
                92, 10,
                92, 114,
                92, 48, 48, 48,
                34
            )
            assert(string.format("%q", special) == expected)
            assert(assert(loadstring("return " .. expected))() == special)
            """#,
            sourceName: "@Lua51StringFormatQRegression.lua"
        )
    }

    func testFormatQComposesWithPercentSWithoutTranscoding() throws {
        let state = LuaState(output: { _ in })
        try state.execute(
            #"""
            local x = string.char(34, 0xE4, 108, 111, 34, 10, 92)
            local quoted = string.char(
                34,
                92, 34,
                0xE4, 108, 111,
                92, 34,
                92, 10,
                92, 92,
                34
            )
            assert(string.format("%q%s", x, x) == quoted .. x)
            """#,
            sourceName: "@Lua51StringFormatQCompositionRegression.lua"
        )
    }
}
