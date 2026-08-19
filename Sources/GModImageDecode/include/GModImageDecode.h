#ifndef GMOD_IMAGE_DECODE_H
#define GMOD_IMAGE_DECODE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct GModDecodedRGBAImage {
    uint8_t *pixels;
    uint32_t width;
    uint32_t height;
    uint32_t bytes_per_row;
} GModDecodedRGBAImage;

enum GModImageDecodeResult {
    GMOD_IMAGE_DECODE_OK = 0,
    GMOD_IMAGE_DECODE_INVALID_ARGUMENT = 1,
    GMOD_IMAGE_DECODE_UNSUPPORTED_PLATFORM = 2,
    GMOD_IMAGE_DECODE_FORMAT_ERROR = 3,
    GMOD_IMAGE_DECODE_ALLOCATION_ERROR = 4,
    GMOD_IMAGE_DECODE_PLATFORM_ERROR = 5
};

int32_t gmod_decode_image_rgba(
    const uint8_t *encoded_bytes,
    size_t encoded_length,
    GModDecodedRGBAImage *decoded_image
);

void gmod_free_decoded_image(GModDecodedRGBAImage *decoded_image);

#ifdef __cplusplus
}
#endif

#endif
