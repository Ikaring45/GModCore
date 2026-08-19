-- Original synthetic host-driven GLua timer fixture. No game source is embedded here.
TIMER_TICKS = 0
TIMER_REPS = {}
TIMER_TIMES = {}
TIMER_SIMPLE_FIRED = false
TIMER_AFTER_ERROR_FIRED = false

timer.Create("finite", 0.03, 2, function()
    TIMER_TICKS = TIMER_TICKS + 1
    TIMER_REPS[TIMER_TICKS] = timer.RepsLeft("finite")
    TIMER_TIMES[TIMER_TICKS] = CurTime()
end)

timer.Simple(0, function()
    TIMER_SIMPLE_FIRED = true
end)

timer.Create("bad", 0.015, 1, function()
    error("synthetic timer failure")
end)

timer.Create("after_bad", 0.015, 1, function()
    TIMER_AFTER_ERROR_FIRED = true
end)

do
    local captured = { value = "kept alive" }
    timer.Create("gc_root", 0.015, 1, function()
        TIMER_GC_VALUE = captured.value
    end)
end
collectgarbage("collect")

timer.Create("paused", 0.03, 2, function()
    TIMER_PAUSED_TICKS = (TIMER_PAUSED_TICKS or 0) + 1
end)

timer.Create("stopped", 0.02, 1, function()
    TIMER_STOPPED_FIRED = true
end)
timer.Stop("stopped")

assert(timer.Exists("finite"))
assert(timer.IsPaused("stopped"))
assert(timer.TimeLeft("missing") == nil)
assert(timer.RepsLeft("missing") == nil)

GLUA_TIMER_REGRESSION_READY = true
