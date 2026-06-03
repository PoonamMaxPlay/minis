#ifndef MINIS_PREVIEW_PIPELINE_H
#define MINIS_PREVIEW_PIPELINE_H

#import <CoreVideo/CVPixelBuffer.h>
#import <stdbool.h>
#import <stddef.h>
#import <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

bool minis_nv12_to_rgba(CVPixelBufferRef pixel_buffer, uint8_t* dst, size_t dst_stride);

#ifdef __cplusplus
}
#endif

#endif // MINIS_PREVIEW_PIPELINE_H
