import XCTest
import GModLua

final class LuaAutomaticGarbageCollectionTests: XCTestCase {
    func testStringAllocationPressureClearsWeakValueWithoutExplicitCollection() throws {
        let state = LuaState(output: { _ in })

        try state.execute(
            """
            local weak = setmetatable({}, { __mode = "v" })
            do
                local marker = {}
                weak[1] = marker
            end

            local seed = string.rep("x", 16384)
            local iterations = 0
            while weak[1] ~= nil and iterations < 1024 do
                local garbage = seed .. iterations
                iterations = iterations + 1
            end

            assert(weak[1] == nil, "automatic collection did not run under string allocation pressure")
            assert(iterations > 0 and iterations < 1024)
            """,
            sourceName: "@automatic-string-gc.lua"
        )
    }

    func testFullCollectionRestartsCollectorAfterStop() throws {
        let state = LuaState(output: { _ in })

        try state.execute(
            """
            collectgarbage("stop")
            collectgarbage("collect")

            local weak = setmetatable({}, { __mode = "v" })
            do
                local marker = {}
                weak[1] = marker
            end

            local seed = string.rep("x", 16384)
            local iterations = 0
            while weak[1] ~= nil and iterations < 1024 do
                local garbage = seed .. iterations
                iterations = iterations + 1
            end

            assert(weak[1] == nil)
            assert(iterations > 0 and iterations < 1024)
            """,
            sourceName: "@full-gc-restarts-automatic-gc.lua"
        )
    }

    func testAllocationDebtDoesNotMasqueradeAsLiveCollectgarbageCount() throws {
        let state = LuaState(output: { _ in })

        try state.execute(
            """
            collectgarbage("collect")
            held = string.rep("x", 16384) .. "!"
            local before = collectgarbage("count")
            collectgarbage("collect")
            local after = collectgarbage("count")
            assert(before == after, before .. " ~= " .. after)
            assert(#held == 16385)
            """,
            sourceName: "@automatic-string-gc-count.lua"
        )
    }

    func testCollectgarbageRejectsUnrepresentableNumbersAndSaturatesWorkMath() throws {
        let state = LuaState(output: { _ in })

        try state.execute(
            """
            for _, option in ipairs({ "step", "setpause", "setstepmul" }) do
                local ok, message = pcall(collectgarbage, option, math.huge)
                assert(not ok and string.find(message, "bad argument #2", 1, true))

                ok, message = pcall(collectgarbage, option, 0/0)
                assert(not ok and string.find(message, "bad argument #2", 1, true))

                ok, message = pcall(collectgarbage, option, 1e300)
                assert(not ok and string.find(message, "bad argument #2", 1, true))
            end

            assert(type(collectgarbage("step", 1e15)) == "boolean")
            collectgarbage("setpause", 1e15)
            collectgarbage("setstepmul", 1e15)
            assert(type(collectgarbage("step", 1e15)) == "boolean")
            """,
            sourceName: "@collectgarbage-number-safety.lua"
        )
    }

    func testFinalizerCannotReenterCloseDuringCollection() throws {
        let state = LuaState(output: { _ in })
        var reentrantReports: [LuaCloseReport] = []
        var finalizerCalls = 0
        state.register("requestHostClose") { _ in
            finalizerCalls += 1
            reentrantReports.append(state.close())
            return []
        }

        try state.execute(
            """
            local object = newproxy(true)
            getmetatable(object).__gc = function()
                requestHostClose()
            end
            object = nil
            collectgarbage("collect")
            survivedCollection = true
            """,
            sourceName: "@gc-close-reentry.lua"
        )

        XCTAssertEqual(finalizerCalls, 1)
        XCTAssertEqual(reentrantReports.count, 1)
        XCTAssertEqual(
            reentrantReports[0].errorMessages,
            ["LuaState.close() rejected during active garbage collection"]
        )
        XCTAssertFalse(state.isClosed)
        try state.execute("assert(survivedCollection)")

        _ = state.close()
        XCTAssertTrue(state.isClosed)
        XCTAssertEqual(finalizerCalls, 1)
    }

    func testStringDebtCreatedByFinalizerSurvivesCurrentCollection() throws {
        let state = LuaState(output: { _ in })

        try state.execute(
            """
            local object = newproxy(true)
            local finalizerCalls = 0
            getmetatable(object).__gc = function(finalizingObject)
                finalizerCalls = finalizerCalls + 1
                if finalizerCalls == 1 then
                    newproxy(finalizingObject)
                    local seed = string.rep("x", 16384)
                    for i = 1, 300 do
                        local garbage = seed .. i
                    end
                end
            end

            object = nil
            collectgarbage("collect")
            assert(finalizerCalls == 2)
            """,
            sourceName: "@gc-finalizer-string-debt.lua"
        )
    }
}
