import GModLua
import XCTest

final class Lua51PatternFrontierTests: XCTestCase {
    func testFrontierUsesNULAtSubjectBoundariesAcrossStringAPIs() throws {
        let state = LuaState(output: { _ in })
        try state.execute(
            #"""
            local subject = "function"
            local nonzero = "%f[\1-\255]"
            local zero = "%f[^\1-\255]"

            local first, last = string.find(subject, nonzero)
            assert(first == 1 and last == 0)
            first, last = string.find(subject, zero)
            assert(first == 9 and last == 8)

            assert(string.match(subject, zero) == "")

            local result, count = string.gsub(subject, nonzero, ".")
            assert(result == ".function" and count == 1)
            result, count = string.gsub(subject, zero, ".")
            assert(result == "function." and count == 1)

            local matches = string.gmatch(subject, zero)
            assert(matches() == "")
            assert(matches() == nil)

            assert(string.find("", "%f[%z]") == nil)
            assert(string.find("", "%f[^%z]") == nil)
            """#,
            sourceName: "@Lua51PatternFrontierBoundariesRegression.lua"
        )
    }

    func testFrontierSetsRemainByteOrientedAroundEmbeddedNUL() throws {
        let state = LuaState(output: { _ in })
        try state.execute(
            #"""
            local subject = string.char(0, 0xE4, 0xFF, 0)
            local high = "%f[" .. string.char(0xE4) .. "-" .. string.char(0xFF) .. "]"
            local outside = "%f[^" .. string.char(0xE4) .. "-" .. string.char(0xFF) .. "]"

            local first, last = string.find(subject, high)
            assert(first == 2 and last == 1)
            first, last = string.find(subject, outside, 2)
            assert(first == 4 and last == 3)

            assert(string.match(subject, high) == "")
            assert(string.gsub(subject, high, ".") == string.char(0) .. "." .. string.char(0xE4, 0xFF, 0))

            local matches = string.gmatch(subject, high)
            assert(matches() == "")
            assert(matches() == nil)
            """#,
            sourceName: "@Lua51PatternFrontierBytesRegression.lua"
        )
    }

    func testMalformedFrontierPatternsFailAcrossStringAPIs() throws {
        let state = LuaState(output: { _ in })
        try state.execute(
            #"""
            local operations = {
                function(pattern) return string.find("x", pattern) end,
                function(pattern) return string.match("x", pattern) end,
                function(pattern) return string.gsub("x", pattern, ".") end,
                function(pattern) return string.gmatch("x", pattern)() end,
            }

            local malformed = {
                { "%f", "missing '[' after '%f' in pattern" },
                { "%fa", "missing '[' after '%f' in pattern" },
                { "%f[abc", "malformed pattern (missing ']')" },
            }

            for _, operation in ipairs(operations) do
                for _, case in ipairs(malformed) do
                    local ok, message = pcall(operation, case[1])
                    assert(not ok)
                    assert(string.find(message, case[2], 1, true))
                end
            end
            """#,
            sourceName: "@Lua51PatternFrontierMalformedRegression.lua"
        )
    }
}
