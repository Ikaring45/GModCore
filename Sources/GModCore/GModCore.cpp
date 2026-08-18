#include <stdint.h>

namespace {

constexpr uint32_t GM_ENGINE_HANDLE = 1;
constexpr double GM_TICK_INTERVAL = 0.015;
constexpr uint32_t GM_MAX_TICKS_PER_FRAME = 8;
constexpr uint32_t GM_LOG_CAPACITY = 32;

enum GMLogEvent : uint32_t {
    GM_LOG_ENGINE_CREATED = 1,
    GM_LOG_BOOT_BEGIN = 2,
    GM_LOG_CLOCK_INITIALIZED = 3,
    GM_LOG_BOOT_COMPLETE = 4,
    GM_LOG_ENGINE_DESTROYED = 5
};

struct GMEngineState {
    uint32_t alive;
    uint32_t running;
    uint32_t tickCount;
    double accumulator;
};

GMEngineState gEngine = {};

uint32_t gLogEvents[GM_LOG_CAPACITY] = {};
uint32_t gLogCount = 0;

void GMLogEventPush(uint32_t eventCode)
{
    if (gLogCount < GM_LOG_CAPACITY) {
        gLogEvents[gLogCount++] = eventCode;
    }
}

bool GMValidHandle(uint32_t handle)
{
    return
        handle == GM_ENGINE_HANDLE &&
        gEngine.alive != 0;
}

}

extern "C" {

uint32_t gm_abi_version(void)
{
    return 1;
}

uint32_t gm_create(void)
{
    gEngine.alive = 1;
    gEngine.running = 0;
    gEngine.tickCount = 0;
    gEngine.accumulator = 0.0;

    gLogCount = 0;

    GMLogEventPush(
        GM_LOG_ENGINE_CREATED
    );

    return GM_ENGINE_HANDLE;
}

void gm_destroy(uint32_t handle)
{
    if (!GMValidHandle(handle)) {
        return;
    }

    GMLogEventPush(
        GM_LOG_ENGINE_DESTROYED
    );

    gEngine.running = 0;
    gEngine.alive = 0;
    gEngine.accumulator = 0.0;
}

int32_t gm_boot(uint32_t handle)
{
    if (!GMValidHandle(handle)) {
        return 0;
    }

    GMLogEventPush(
        GM_LOG_BOOT_BEGIN
    );

    gEngine.tickCount = 0;
    gEngine.accumulator = 0.0;

    GMLogEventPush(
        GM_LOG_CLOCK_INITIALIZED
    );

    gEngine.running = 1;

    GMLogEventPush(
        GM_LOG_BOOT_COMPLETE
    );

    return 1;
}

uint32_t gm_frame(
    uint32_t handle,
    double deltaSeconds
)
{
    if (
        !GMValidHandle(handle) ||
        gEngine.running == 0
    ) {
        return 0;
    }

    if (deltaSeconds < 0.0) {
        deltaSeconds = 0.0;
    }

    // Prevent huge catch-up bursts after a pause.
    if (deltaSeconds > 0.25) {
        deltaSeconds = 0.25;
    }

    gEngine.accumulator +=
        deltaSeconds;

    uint32_t ticksExecuted = 0;

    while (
        gEngine.accumulator >=
            GM_TICK_INTERVAL &&
        ticksExecuted <
            GM_MAX_TICKS_PER_FRAME
    ) {
        gEngine.accumulator -=
            GM_TICK_INTERVAL;

        ++gEngine.tickCount;
        ++ticksExecuted;
    }

    // Avoid a spiral of death.
    if (
        ticksExecuted ==
            GM_MAX_TICKS_PER_FRAME &&
        gEngine.accumulator >=
            GM_TICK_INTERVAL
    ) {
        gEngine.accumulator = 0.0;
    }

    return ticksExecuted;
}

double gm_tick_interval(void)
{
    return GM_TICK_INTERVAL;
}

uint32_t gm_tick_count(
    uint32_t handle
)
{
    if (!GMValidHandle(handle)) {
        return 0;
    }

    return gEngine.tickCount;
}

uint32_t gm_is_running(
    uint32_t handle
)
{
    if (!GMValidHandle(handle)) {
        return 0;
    }

    return gEngine.running;
}

uint32_t gm_log_event_count(void)
{
    return gLogCount;
}

uint32_t gm_log_event(
    uint32_t index
)
{
    if (index >= gLogCount) {
        return 0;
    }

    return gLogEvents[index];
}

}
