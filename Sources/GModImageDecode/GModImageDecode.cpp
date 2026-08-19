#include "GModImageDecode.h"

#include <limits.h>
#include <stdlib.h>
#include <string.h>

static void gmod_reset_decoded_image(GModDecodedRGBAImage *decoded_image) {
    if (decoded_image == NULL) {
        return;
    }

    decoded_image->pixels = NULL;
    decoded_image->width = 0;
    decoded_image->height = 0;
    decoded_image->bytes_per_row = 0;
}

void gmod_free_decoded_image(GModDecodedRGBAImage *decoded_image) {
    if (decoded_image == NULL) {
        return;
    }

    free(decoded_image->pixels);
    gmod_reset_decoded_image(decoded_image);
}

#if defined(_WIN32)

#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <wincodec.h>

template <typename T>
static void gmod_release(T **object) {
    if (object != NULL && *object != NULL) {
        (*object)->Release();
        *object = NULL;
    }
}

int32_t gmod_decode_image_rgba(
    const uint8_t *encoded_bytes,
    size_t encoded_length,
    GModDecodedRGBAImage *decoded_image
) {
    if (decoded_image == NULL) {
        return GMOD_IMAGE_DECODE_INVALID_ARGUMENT;
    }
    gmod_reset_decoded_image(decoded_image);

    if (encoded_bytes == NULL || encoded_length == 0 || encoded_length > ULONG_MAX) {
        return GMOD_IMAGE_DECODE_INVALID_ARGUMENT;
    }

    const HRESULT apartment_result = CoInitializeEx(NULL, COINIT_MULTITHREADED);
    const bool must_uninitialize = apartment_result == S_OK || apartment_result == S_FALSE;
    if (FAILED(apartment_result) && apartment_result != RPC_E_CHANGED_MODE) {
        return GMOD_IMAGE_DECODE_PLATFORM_ERROR;
    }

    IWICImagingFactory *factory = NULL;
    IWICStream *stream = NULL;
    IWICBitmapDecoder *decoder = NULL;
    IWICBitmapFrameDecode *frame = NULL;
    IWICFormatConverter *converter = NULL;
    uint8_t *pixels = NULL;
    UINT width = 0;
    UINT height = 0;
    uint64_t stride64 = 0;
    uint64_t byte_count64 = 0;
    int32_t result = GMOD_IMAGE_DECODE_PLATFORM_ERROR;

    HRESULT hr = CoCreateInstance(
        CLSID_WICImagingFactory,
        NULL,
        CLSCTX_INPROC_SERVER,
        IID_IWICImagingFactory,
        reinterpret_cast<void **>(&factory)
    );
    if (FAILED(hr)) {
        goto cleanup;
    }

    hr = factory->CreateStream(&stream);
    if (FAILED(hr)) {
        goto cleanup;
    }

    hr = stream->InitializeFromMemory(
        const_cast<BYTE *>(reinterpret_cast<const BYTE *>(encoded_bytes)),
        static_cast<DWORD>(encoded_length)
    );
    if (FAILED(hr)) {
        result = GMOD_IMAGE_DECODE_FORMAT_ERROR;
        goto cleanup;
    }

    hr = factory->CreateDecoderFromStream(
        stream,
        NULL,
        WICDecodeMetadataCacheOnLoad,
        &decoder
    );
    if (FAILED(hr)) {
        result = GMOD_IMAGE_DECODE_FORMAT_ERROR;
        goto cleanup;
    }

    hr = decoder->GetFrame(0, &frame);
    if (FAILED(hr)) {
        result = GMOD_IMAGE_DECODE_FORMAT_ERROR;
        goto cleanup;
    }

    hr = frame->GetSize(&width, &height);
    if (FAILED(hr) || width == 0 || height == 0 || width > UINT32_MAX / 4) {
        result = GMOD_IMAGE_DECODE_FORMAT_ERROR;
        goto cleanup;
    }

    stride64 = static_cast<uint64_t>(width) * 4;
    byte_count64 = stride64 * static_cast<uint64_t>(height);
    if (stride64 > UINT32_MAX || byte_count64 > UINT32_MAX || byte_count64 > SIZE_MAX) {
        result = GMOD_IMAGE_DECODE_FORMAT_ERROR;
        goto cleanup;
    }

    hr = factory->CreateFormatConverter(&converter);
    if (FAILED(hr)) {
        goto cleanup;
    }

    hr = converter->Initialize(
        frame,
        GUID_WICPixelFormat32bppRGBA,
        WICBitmapDitherTypeNone,
        NULL,
        0.0,
        WICBitmapPaletteTypeCustom
    );
    if (FAILED(hr)) {
        result = GMOD_IMAGE_DECODE_FORMAT_ERROR;
        goto cleanup;
    }

    pixels = static_cast<uint8_t *>(malloc(static_cast<size_t>(byte_count64)));
    if (pixels == NULL) {
        result = GMOD_IMAGE_DECODE_ALLOCATION_ERROR;
        goto cleanup;
    }

    hr = converter->CopyPixels(
        NULL,
        static_cast<UINT>(stride64),
        static_cast<UINT>(byte_count64),
        pixels
    );
    if (FAILED(hr)) {
        result = GMOD_IMAGE_DECODE_FORMAT_ERROR;
        goto cleanup;
    }

    decoded_image->pixels = pixels;
    decoded_image->width = static_cast<uint32_t>(width);
    decoded_image->height = static_cast<uint32_t>(height);
    decoded_image->bytes_per_row = static_cast<uint32_t>(stride64);
    pixels = NULL;
    result = GMOD_IMAGE_DECODE_OK;

cleanup:
    free(pixels);
    gmod_release(&converter);
    gmod_release(&frame);
    gmod_release(&decoder);
    gmod_release(&stream);
    gmod_release(&factory);
    if (must_uninitialize) {
        CoUninitialize();
    }
    return result;
}

#elif defined(__APPLE__)

#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <ImageIO/ImageIO.h>

int32_t gmod_decode_image_rgba(
    const uint8_t *encoded_bytes,
    size_t encoded_length,
    GModDecodedRGBAImage *decoded_image
) {
    if (decoded_image == NULL) {
        return GMOD_IMAGE_DECODE_INVALID_ARGUMENT;
    }
    gmod_reset_decoded_image(decoded_image);

    if (encoded_bytes == NULL || encoded_length == 0 || encoded_length > LONG_MAX) {
        return GMOD_IMAGE_DECODE_INVALID_ARGUMENT;
    }

    CFDataRef encoded_data = CFDataCreate(
        kCFAllocatorDefault,
        encoded_bytes,
        (CFIndex)encoded_length
    );
    if (encoded_data == NULL) {
        return GMOD_IMAGE_DECODE_ALLOCATION_ERROR;
    }

    CGImageSourceRef source = CGImageSourceCreateWithData(encoded_data, NULL);
    CFRelease(encoded_data);
    if (source == NULL) {
        return GMOD_IMAGE_DECODE_FORMAT_ERROR;
    }

    CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0, NULL);
    CFRelease(source);
    if (image == NULL) {
        return GMOD_IMAGE_DECODE_FORMAT_ERROR;
    }

    const size_t width = CGImageGetWidth(image);
    const size_t height = CGImageGetHeight(image);
    if (width == 0 || height == 0 || width > UINT32_MAX / 4 || height > UINT32_MAX) {
        CGImageRelease(image);
        return GMOD_IMAGE_DECODE_FORMAT_ERROR;
    }

    const size_t bytes_per_row = width * 4;
    if (height > SIZE_MAX / bytes_per_row || bytes_per_row > UINT32_MAX) {
        CGImageRelease(image);
        return GMOD_IMAGE_DECODE_FORMAT_ERROR;
    }

    const size_t byte_count = bytes_per_row * height;
    uint8_t *pixels = static_cast<uint8_t *>(calloc(1, byte_count));
    if (pixels == NULL) {
        CGImageRelease(image);
        return GMOD_IMAGE_DECODE_ALLOCATION_ERROR;
    }

    CGColorSpaceRef color_space = CGColorSpaceCreateDeviceRGB();
    if (color_space == NULL) {
        free(pixels);
        CGImageRelease(image);
        return GMOD_IMAGE_DECODE_PLATFORM_ERROR;
    }

    CGContextRef context = CGBitmapContextCreate(
        pixels,
        width,
        height,
        8,
        bytes_per_row,
        color_space,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big
    );
    CGColorSpaceRelease(color_space);
    if (context == NULL) {
        free(pixels);
        CGImageRelease(image);
        return GMOD_IMAGE_DECODE_PLATFORM_ERROR;
    }

    CGContextTranslateCTM(context, 0.0, (CGFloat)height);
    CGContextScaleCTM(context, 1.0, -1.0);
    CGContextDrawImage(context, CGRectMake(0.0, 0.0, (CGFloat)width, (CGFloat)height), image);
    CGContextRelease(context);
    CGImageRelease(image);

    // Core Graphics renders into this bitmap as premultiplied RGBA. The GLua
    // material contract and the Windows WIC path both expose straight RGBA,
    // so restore each non-transparent component before handing bytes to Swift.
    // Fully transparent source RGB cannot be recovered after Core Graphics
    // compositing and is deterministically represented as zero.
    for (size_t offset = 0; offset < byte_count; offset += 4) {
        const uint32_t alpha = pixels[offset + 3];
        if (alpha == 0) {
            pixels[offset] = 0;
            pixels[offset + 1] = 0;
            pixels[offset + 2] = 0;
            continue;
        }
        if (alpha == 255) {
            continue;
        }
        for (size_t component = 0; component < 3; ++component) {
            const uint32_t straight =
                (static_cast<uint32_t>(pixels[offset + component]) * 255 + alpha / 2) / alpha;
            pixels[offset + component] = static_cast<uint8_t>(straight > 255 ? 255 : straight);
        }
    }

    decoded_image->pixels = pixels;
    decoded_image->width = (uint32_t)width;
    decoded_image->height = (uint32_t)height;
    decoded_image->bytes_per_row = (uint32_t)bytes_per_row;
    return GMOD_IMAGE_DECODE_OK;
}

#else

int32_t gmod_decode_image_rgba(
    const uint8_t *encoded_bytes,
    size_t encoded_length,
    GModDecodedRGBAImage *decoded_image
) {
    (void)encoded_bytes;
    (void)encoded_length;
    gmod_reset_decoded_image(decoded_image);
    return GMOD_IMAGE_DECODE_UNSUPPORTED_PLATFORM;
}

#endif
