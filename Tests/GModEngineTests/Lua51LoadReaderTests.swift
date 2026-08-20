import GModLua
import XCTest

final class Lua51LoadReaderTests: XCTestCase {
    func testLoadReaderRestoresDumpedChunkByteByByte() throws {
        let state = LuaState(output: { _ in })
        try state.execute(
            #"""
            local function readBytes(bytes)
                local index = 0
                return function()
                    index = index + 1
                    if index > #bytes then return nil end
                    return string.sub(bytes, index, index)
                end
            end

            local dumped = string.dump(loadstring("x = 1; return x"))
            local loaded, message = load(readBytes(dumped), "ignored-for-binary")
            assert(loaded, message)
            assert(loaded() == 1 and x == 1)
            """#,
            sourceName: "@Lua51LoadReaderBinaryRoundTrip.lua"
        )
    }

    func testDumpReloadCreatesFreshNilInitializedUpvalues() throws {
        let state = LuaState(output: { _ in })
        try state.execute(
            #"""
            local a, b = 20, 30
            local original = function(command)
                if command == "set" then
                    a = 10 + b
                    b = b + 1
                else
                    return a
                end
            end

            local dumped = string.dump(original)
            local first = assert(loadstring(dumped))
            local second = assert(loadstring(dumped))

            assert(first() == nil and second() == nil)
            assert(debug.setupvalue(first, 1, "hi") == "a")
            assert(first() == "hi" and second() == nil)
            assert(debug.setupvalue(first, 2, 13) == "b")
            assert(debug.setupvalue(first, 3, 10) == nil)
            first("set")
            assert(first() == 23)
            first("set")
            assert(first() == 24)
            assert(original() == 20)
            """#,
            sourceName: "@Lua51DumpUpvalueReset.lua"
        )
    }

    func testLoadReaderTreatsEmptyStringAsEOFAndCoercesNumbers() throws {
        let state = LuaState(output: { _ in })
        try state.execute(
            #"""
            local calls = 0
            local loaded, message = load(function()
                calls = calls + 1
                if calls == 1 then return "return 7" end
                if calls == 2 then return "" end
                error("reader called after empty-string EOF")
            end, "=empty-reader")

            assert(loaded, message)
            assert(calls == 2 and loaded() == 7)

            local pieces = { "return ", 42 }
            local calls = 0
            loaded, message = load(function()
                calls = calls + 1
                return pieces[calls]
            end, "=number-reader")

            assert(loaded, message)
            assert(calls == 3 and loaded() == 42)
            """#,
            sourceName: "@Lua51LoadReaderEOF.lua"
        )
    }

    func testLoadReaderReturnsCallbackFailuresAndRejectsNonStringPieces() throws {
        let state = LuaState(output: { _ in })
        try state.execute(
            #"""
            local loaded, message = load(function() error("reader exploded") end)
            assert(loaded == nil)
            assert(type(message) == "string" and string.find(message, "reader exploded"))

            local marker = {}
            loaded, message = load(function() error(marker) end)
            assert(loaded == nil and message == marker)

            loaded, message = load(function() return true end)
            assert(loaded == nil)
            assert(message == "reader function must return a string")

            local ok, argumentError = pcall(load, setmetatable({}, {
                __call = function() return nil end
            }))
            assert(not ok and string.find(argumentError, "function expected"))
            """#,
            sourceName: "@Lua51LoadReaderErrors.lua"
        )
    }

    func testLoadReaderStopsAtFirstDefinitiveSyntaxError() throws {
        let state = LuaState(output: { _ in })
        try state.execute(
            #"""
            local index = 0
            local function readOne(source)
                return function()
                    index = index + 1
                    return string.sub(source, index, index)
                end
            end

            local loaded, message = load(readOne("*a = 123"))
            assert(loaded == nil and type(message) == "string")
            assert(index == 2)

            index = 0
            loaded, message = load(readOne("*a *"))
            assert(loaded == nil and type(message) == "string")
            assert(index == 2)

            local calls = 0
            loaded, message = load(function()
                calls = calls + 1
                if calls == 1 then return "*a = 123" end
                error("reader drained after definitive syntax error")
            end)
            assert(loaded == nil and type(message) == "string")
            assert(calls == 1)

            index = 0
            local longString = "return [=[reader remains incremental]=]"
            loaded, message = load(readOne(longString))
            assert(loaded, message)
            assert(loaded() == "reader remains incremental")
            assert(index == #longString + 1)
            """#,
            sourceName: "@Lua51LoadReaderEarlySyntaxError.lua"
        )
    }

    func testLoadReaderDistinguishesEscapedAndRawNewlinesInQuotedStrings() throws {
        let state = LuaState(output: { _ in })
        try state.execute(
            #"""
            local pieces = {
                "return \"a" .. "\\" .. "\n",
                "b\""
            }
            local calls = 0
            local loaded, message = load(function()
                calls = calls + 1
                return pieces[calls]
            end, "=escaped-newline-reader")

            assert(loaded, message)
            assert(calls == 3)
            assert(loaded() == "a\nb")

            local marker = {}
            calls = 0
            loaded, message = load(function()
                calls = calls + 1
                if calls == 1 then
                    return "return \"raw" .. "\n"
                end
                error(marker)
            end, "=raw-newline-reader")

            assert(loaded == nil and type(message) == "string")
            assert(message ~= marker and calls == 1)
            """#,
            sourceName: "@Lua51LoadReaderQuotedNewlines.lua"
        )
    }

    func testLoadReaderDoesNotOverreadDelimitedSyntaxErrors() throws {
        let state = LuaState(output: { _ in })
        try state.execute(
            #"""
            local marker = {}
            local calls = 0
            local loaded, message = load(function()
                calls = calls + 1
                if calls == 1 then return "return 1 x " end
                error(marker)
            end, "=delimited-syntax-error")

            assert(loaded == nil and type(message) == "string")
            assert(message ~= marker and calls == 1)
            """#,
            sourceName: "@Lua51LoadReaderDelimitedError.lua"
        )
    }

    func testHandledReaderFailureDoesNotLeaveFailureFrameRoots() throws {
        let state = LuaState(output: { _ in })
        try state.execute(
            #"""
            local weak = setmetatable({}, { __mode = "v" })
            do
                local marker = {}
                weak[1] = marker
                local reader = function() error(marker) end
                local loaded, message = load(reader)
                assert(loaded == nil and message == marker)
                marker, reader, message = nil, nil, nil
            end

            collectgarbage("collect")
            collectgarbage("collect")
            assert(weak[1] == nil)

            local function outerFailure()
                error("outer failure")
            end
            local ok, traceWasPreserved = xpcall(outerFailure, function(message)
                local before = debug.traceback(message)
                local loaded = load(function() error("reader failure") end)
                assert(loaded == nil)
                local after = debug.traceback(message)
                return before == after
            end)
            assert(not ok and traceWasPreserved)
            """#,
            sourceName: "@Lua51LoadReaderFailureRoots.lua"
        )
    }

    func testDumpedChunkRecognitionIgnoresTrailingBytesAcrossReaderPartitions() throws {
        let state = LuaState(output: { _ in })
        try state.execute(
            #"""
            local dumped = string.dump(function() return 37 end)

            local calls = 0
            local loaded, message = load(function()
                calls = calls + 1
                if calls == 1 then return dumped .. "trailing bytes" end
                error("reader called after complete binary chunk")
            end)
            assert(loaded, message)
            assert(calls == 1 and loaded() == 37)

            local midpoint = math.floor(#dumped / 2)
            calls = 0
            loaded, message = load(function()
                calls = calls + 1
                if calls == 1 then return string.sub(dumped, 1, midpoint) end
                if calls == 2 then
                    return string.sub(dumped, midpoint + 1) .. "trailing bytes"
                end
                error("reader drained after split binary chunk")
            end)
            assert(loaded, message)
            assert(calls == 2 and loaded() == 37)

            calls = 0
            loaded, message = load(function()
                calls = calls + 1
                if calls == 1 then return dumped end
                return "unread trailing bytes"
            end)
            assert(loaded, message)
            assert(calls == 1 and loaded() == 37)

            loaded, message = loadstring(dumped .. "trailing bytes")
            assert(loaded, message)
            assert(loaded() == 37)
            """#,
            sourceName: "@Lua51DumpTrailingBytes.lua"
        )
    }

    func testDumpHandlesCannotAliasAcrossStates() throws {
        let first = LuaState(output: { _ in })
        let second = LuaState(output: { _ in })

        try first.execute(
            "firstDump = string.dump(function() return 11 end)",
            sourceName: "@Lua51DumpFirstState.lua"
        )
        try second.execute(
            "secondDump = string.dump(function() return 22 end)",
            sourceName: "@Lua51DumpSecondState.lua"
        )

        guard case let .string(firstBytes) = first.getGlobal("firstDump"),
              case let .string(secondBytes) = second.getGlobal("secondDump") else {
            return XCTFail("string.dump did not return binary strings")
        }
        XCTAssertNotEqual(firstBytes, secondBytes)

        second.setGlobal("foreignDump", value: .string(firstBytes))
        try second.execute(
            #"""
            local loaded, message = loadstring(foreignDump)
            assert(loaded == nil and type(message) == "string")

            local sent = false
            loaded, message = load(function()
                if sent then return nil end
                sent = true
                return foreignDump
            end)
            assert(loaded == nil and type(message) == "string")
            """#,
            sourceName: "@Lua51DumpStateIsolation.lua"
        )
    }
}
