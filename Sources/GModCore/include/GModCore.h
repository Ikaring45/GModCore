#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct GMEngine GMEngine;

typedef void (*GMLogCallback)(const char *message);

/*
    ABI
*/

uint32_t gm_abi_version(void);

/*
    Engine lifecycle
*/

GMEngine *gm_create(void);
void gm_destroy(GMEngine *engine);

void gm_boot(GMEngine *engine);

/*
    Debug / Test
*/

const char *gm_version(void);

int32_t gm_test_add(
    int32_t a,
    int32_t b
);

/*
    Logging
*/

void gm_set_log_callback(
    GMLogCallback callback
);

#ifdef __cplusplus
}
#endif
