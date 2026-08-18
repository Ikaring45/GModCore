#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

uint32_t gm_abi_version(void);

uint32_t gm_create(void);

void gm_destroy(
    uint32_t handle
);

int32_t gm_boot(
    uint32_t handle
);

uint32_t gm_frame(
    uint32_t handle,
    double deltaSeconds
);

double gm_tick_interval(void);

uint32_t gm_tick_count(
    uint32_t handle
);

uint32_t gm_is_running(
    uint32_t handle
);

uint32_t gm_log_event_count(void);

uint32_t gm_log_event(
    uint32_t index
);

#ifdef __cplusplus
}
#endif
