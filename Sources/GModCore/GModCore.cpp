#include "GModCore.h"

#include <cstdint>
#include <new>

struct GMEngine
{
    uint64_t frameNumber = 0;
    bool booted = false;
};

static GMLogCallback gLogCallback = nullptr;

static void GMLog(const char *message)
{
    if (gLogCallback != nullptr)
    {
        gLogCallback(message);
    }
}

extern "C"
{

uint32_t gm_abi_version(void)
{
    return 1;
}

GMEngine *gm_create(void)
{
    GMEngine *engine = new (std::nothrow) GMEngine();

    if (engine == nullptr)
    {
        GMLog("[GModCore] Failed to allocate engine");
        return nullptr;
    }

    GMLog("[GModCore] Native C++ engine created");

    return engine;
}

void gm_destroy(GMEngine *engine)
{
    if (engine == nullptr)
    {
        return;
    }

    GMLog("[GModCore] Shutting down");

    delete engine;
}

void gm_boot(GMEngine *engine)
{
    if (engine == nullptr)
    {
        GMLog("[GModCore] gm_boot called with null engine");
        return;
    }

    GMLog("[GModCore] Boot begin");

    engine->booted = true;

    GMLog("[GModCore] C++17 runtime OK");
    GMLog("[GModCore] Boot complete");
}

const char *gm_version(void)
{
    return "GModCore 0.0.1";
}

int32_t gm_test_add(
    int32_t a,
    int32_t b
)
{
    return a + b;
}

void gm_set_log_callback(
    GMLogCallback callback
)
{
    gLogCallback = callback;
}

}
