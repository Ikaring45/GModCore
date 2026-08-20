import Foundation
import XCTest
@testable import GModEngine
import GModLua

final class GMLuaTimerTests: XCTestCase {
    func testHostDrivenSchedulingErrorsPauseStopAndGCRoots() throws {
        let fixtureURL = try XCTUnwrap(
            Bundle.module.url(
                forResource: "GLuaTimerRegression",
                withExtension: "lua",
                subdirectory: "Fixtures"
            ) ?? Bundle.module.url(
                forResource: "GLuaTimerRegression",
                withExtension: "lua"
            )
        )
        let source = try String(contentsOf: fixtureURL, encoding: .utf8)
        let state = LuaState(output: { _ in })
        let scheduler = try GMLuaTimer.install(into: state, minimumTickInterval: 0.015)
        try state.execute(source, sourceName: "@GLuaTimerRegression.lua")

        XCTAssertEqual(scheduler.currentTime, 0)
        XCTAssertEqual(try scheduler.advance(by: 0.014), [])
        try state.execute(
            "assert(not TIMER_SIMPLE_FIRED and not TIMER_AFTER_ERROR_FIRED and TIMER_TICKS == 0)",
            sourceName: "@TimerBeforeFirstTick.lua"
        )

        let failures = try scheduler.advance(by: 0.001)
        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(failures[0].identifier, "bad")
        XCTAssertTrue(failures[0].message.contains("synthetic timer failure"))
        try state.execute(
            """
            assert(TIMER_SIMPLE_FIRED)
            assert(TIMER_AFTER_ERROR_FIRED)
            assert(TIMER_GC_VALUE == "kept alive")
            assert(not timer.Exists("bad"))
            assert(not timer.Exists("after_bad"))
            assert(not timer.Exists("gc_root"))
            assert(TIMER_TICKS == 0)
            timer.Pause("paused")
            assert(timer.IsPaused("paused"))
            assert(timer.TimeLeft("paused") < 0)
            """,
            sourceName: "@TimerFirstTick.lua"
        )

        XCTAssertEqual(try scheduler.advance(by: 0.1), [])
        try state.execute(
            """
            assert(TIMER_TICKS == 1)
            assert(TIMER_REPS[1] == 1)
            assert(TIMER_PAUSED_TICKS == nil)
            assert(TIMER_STOPPED_FIRED == nil)
            timer.UnPause("paused")
            timer.Start("stopped")
            """,
            sourceName: "@TimerResume.lua"
        )

        XCTAssertEqual(try scheduler.advance(by: 0.014), [])
        try state.execute(
            "assert(TIMER_PAUSED_TICKS == nil and TIMER_STOPPED_FIRED == nil)",
            sourceName: "@TimerResumeBeforeTick.lua"
        )
        XCTAssertEqual(try scheduler.advance(by: 0.006), [])
        try state.execute(
            """
            assert(TIMER_PAUSED_TICKS == 1)
            assert(TIMER_STOPPED_FIRED)
            assert(not timer.Exists("stopped"))
            """,
            sourceName: "@TimerResumeAfterTick.lua"
        )

        XCTAssertEqual(try scheduler.advance(by: 0.03), [])
        try state.execute(
            """
            assert(TIMER_TICKS == 2)
            assert(TIMER_REPS[2] == 0)
            assert(TIMER_TIMES[2] >= TIMER_TIMES[1])
            assert(not timer.Exists("finite"))
            assert(GLUA_TIMER_REGRESSION_READY)
            """,
            sourceName: "@TimerCompletion.lua"
        )
    }

    func testAdjustOverwriteToggleAndArgumentValidation() throws {
        let state = LuaState(output: { _ in })
        let scheduler = try GMLuaTimer.install(into: state)
        try state.execute(
            """
            COUNT = 0
            timer.Create("adjusted", 1, 5, function() COUNT = COUNT + 100 end)
            assert(timer.Adjust("adjusted", 0.015, 2, function() COUNT = COUNT + 1 end))
            assert(not timer.Adjust("missing", 1))
            timer.Toggle("adjusted")
            assert(timer.IsPaused("adjusted"))
            timer.Toggle("adjusted")
            assert(not timer.IsPaused("adjusted"))

            timer.Create("overwrite", 0.015, 1, function() COUNT = COUNT + 1000 end)
            timer.Create("overwrite", 0.015, 1, function() COUNT = COUNT + 10 end)

            timer.Create("deferred_remove", 0.015, 1, function() COUNT = COUNT + 10000 end)
            timer.Remove("deferred_remove")
            assert(timer.Exists("deferred_remove"))

            assert(not pcall(timer.Create, {}, 1, 1, function() end))
            assert(not pcall(timer.Create, "x", 0 / 0, 1, function() end))
            assert(not pcall(timer.Create, "x", 1, 9223372036854775808, function() end))
            assert(not pcall(timer.Create, "x", 1, 1, {}))
            """,
            sourceName: "@TimerAdjust.lua"
        )

        XCTAssertEqual(try scheduler.advance(by: 0.015), [])
        try state.execute(
            """
            assert(COUNT == 11 and timer.RepsLeft('adjusted') == 1)
            assert(not timer.Exists('deferred_remove'))
            """,
            sourceName: "@TimerAdjustedFirst.lua"
        )
        XCTAssertEqual(try scheduler.advance(by: 0.015), [])
        try state.execute(
            "assert(COUNT == 12 and not timer.Exists('adjusted'))",
            sourceName: "@TimerAdjustedSecond.lua"
        )
    }

    func testRuntimeExposesOneSchedulerPerRealm() throws {
        for realm in [GMLuaRealm.server, .client, .menu] {
            let runtime = GMLuaRuntime(
                realm: realm,
                logger: { _ in },
                bootstrapMode: .strict
            )
            let scheduler = try XCTUnwrap(runtime.timerScheduler)
            try runtime.execute(
                "timer.Create('runtime', 0.015, 1, function() RUNTIME_TIMER = CurTime() end)",
                sourceName: "@RuntimeTimer.lua"
            )
            XCTAssertEqual(try scheduler.advance(by: 0.015), [])
            try runtime.execute(
                "assert(RUNTIME_TIMER == 0.015)",
                sourceName: "@RuntimeTimerCheck.lua"
            )
        }
    }

    func testAbsoluteAdvanceIsNondecreasingAndPreservesRelativeScheduling() throws {
        let state = LuaState(output: { _ in })
        let scheduler = try GMLuaTimer.install(into: state)
        try state.execute(
            """
            ABSOLUTE_TIMER_COUNT = 0
            timer.Create("absolute", 0.5, 1, function()
                ABSOLUTE_TIMER_COUNT = ABSOLUTE_TIMER_COUNT + 1
                ABSOLUTE_TIMER_TIME = CurTime()
            end)
            """,
            sourceName: "@TimerAbsoluteSetup.lua"
        )

        XCTAssertTrue(try scheduler.advance(to: 0.25).isEmpty)
        XCTAssertEqual(scheduler.currentTime, 0.25)
        try state.execute("assert(ABSOLUTE_TIMER_COUNT == 0)")
        XCTAssertTrue(try scheduler.advance(to: 0.5).isEmpty)
        XCTAssertEqual(scheduler.currentTime, 0.5)
        try state.execute(
            "assert(ABSOLUTE_TIMER_COUNT == 1 and ABSOLUTE_TIMER_TIME == 0.5)"
        )

        XCTAssertThrowsError(try scheduler.advance(to: 0.49))
        XCTAssertEqual(scheduler.currentTime, 0.5)
        XCTAssertTrue(try scheduler.advance(to: 0.5).isEmpty)
        XCTAssertTrue(try scheduler.advance(by: 0.25).isEmpty)
        XCTAssertEqual(scheduler.currentTime, 0.75)
        try state.execute("assert(ABSOLUTE_TIMER_COUNT == 1)")
    }
}
