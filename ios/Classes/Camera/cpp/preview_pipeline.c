// preview_pipeline.c — CVPixelBufferRef planar (NV12 / 420f) → RGBA via Accelerate/vImage.
//
// Exposed to Swift through the bridging header (auto-imported by Cocoapods when
// `s.source_files = 'Classes/**/*'` picks up `.c` files).

#include <Accelerate/Accelerate.h>
#include <CoreVideo/CVPixelBuffer.h>
#include <stdbool.h>

bool minis_nv12_to_rgba(CVPixelBufferRef pixel_buffer, uint8_t* dst, size_t dst_stride) {
    if (!pixel_buffer || !dst) return false;
    if (CVPixelBufferLockBaseAddress(pixel_buffer, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) return false;

    const size_t w = CVPixelBufferGetWidth(pixel_buffer);
    const size_t h = CVPixelBufferGetHeight(pixel_buffer);
    const size_t y_stride = CVPixelBufferGetBytesPerRowOfPlane(pixel_buffer, 0);
    const size_t uv_stride = CVPixelBufferGetBytesPerRowOfPlane(pixel_buffer, 1);

    vImage_Buffer y_buf  = {
        CVPixelBufferGetBaseAddressOfPlane(pixel_buffer, 0),
        h, w, y_stride,
    };
    vImage_Buffer uv_buf = {
        CVPixelBufferGetBaseAddressOfPlane(pixel_buffer, 1),
        h / 2, w / 2, uv_stride,
    };
    vImage_Buffer rgba_buf = { dst, h, w, dst_stride };

    // BT.601 video-range matrix.
    vImage_YpCbCrToARGB info;
    vImage_YpCbCrPixelRange range = {
        16, 128, 235, 240, 255, 0, 255, 0
    };
    vImage_Error err = vImageConvert_YpCbCrToARGB_GenerateConversion(
        kvImage_YpCbCrToARGBMatrix_ITU_R_601_4,
        &range,
        &info,
        kvImage420Yp8_CbCr8,
        kvImageARGB8888,
        kvImagePrintDiagnosticsToConsole
    );
    if (err != kvImageNoError) {
        CVPixelBufferUnlockBaseAddress(pixel_buffer, kCVPixelBufferLock_ReadOnly);
        return false;
    }

    const uint8_t permute_map[4] = { 1, 2, 3, 0 }; // BGRA -> RGBA
    err = vImageConvert_420Yp8_CbCr8ToARGB8888(
        &y_buf, &uv_buf, &rgba_buf, &info, permute_map, 255, kvImageNoFlags
    );

    CVPixelBufferUnlockBaseAddress(pixel_buffer, kCVPixelBufferLock_ReadOnly);
    return err == kvImageNoError;
}
