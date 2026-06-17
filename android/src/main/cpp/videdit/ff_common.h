// Shared declarations and helpers used across the native video editor C code.
//
// Keep this header lean: anything that grows large belongs in its own .c file.
#ifndef LOOPIT_MINIS_FF_COMMON_H
#define LOOPIT_MINIS_FF_COMMON_H

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

#ifdef ANDROID
#include <android/log.h>
#define FF_LOGI(...) __android_log_print(ANDROID_LOG_INFO,  "minis_videdit", __VA_ARGS__)
#define FF_LOGW(...) __android_log_print(ANDROID_LOG_WARN,  "minis_videdit", __VA_ARGS__)
#define FF_LOGE(...) __android_log_print(ANDROID_LOG_ERROR, "minis_videdit", __VA_ARGS__)
#else
#include <stdio.h>
#define FF_LOGI(...) do { fprintf(stderr, "[minis_videdit:I] " __VA_ARGS__); fprintf(stderr, "\n"); } while (0)
#define FF_LOGW(...) do { fprintf(stderr, "[minis_videdit:W] " __VA_ARGS__); fprintf(stderr, "\n"); } while (0)
#define FF_LOGE(...) do { fprintf(stderr, "[minis_videdit:E] " __VA_ARGS__); fprintf(stderr, "\n"); } while (0)
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ff_capabilities {
  int hw_dec_h264;
  int hw_dec_hevc;
  int hw_dec_vp9;
  int hw_enc_h264;
  int hw_enc_hevc;
  int max_resolution_h;
  int max_resolution_w;
  char build_info[256];
} ff_capabilities_t;

void ff_capabilities_query(ff_capabilities_t* out);
const char* ff_build_info(void);

typedef struct ff_progress_cb {
  void (*emit)(void* user, const char* task_id, const char* kind,
               double pct, double fps, double eta_s);
  void* user;
  volatile int cancel_flag;
} ff_progress_cb_t;

#ifdef __cplusplus
}
#endif

#endif // LOOPIT_MINIS_FF_COMMON_H
