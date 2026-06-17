#ifndef LOOPIT_MINIS_FF_SESSION_H
#define LOOPIT_MINIS_FF_SESSION_H

#include "ff_common.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ff_session ff_session_t;

typedef struct ff_session_info {
  int64_t duration_ms;
  int     width;
  int     height;
  double  fps;
  char    video_codec[32];
  char    audio_codec[32];
  int     has_audio;
  int     audio_sample_rate;
  int     audio_channels;
  int     rotation;
  int64_t bitrate;
} ff_session_info_t;

ff_session_t* ff_session_open(const char* path);
int           ff_session_info_get(ff_session_t* s, ff_session_info_t* out);
void          ff_session_close(ff_session_t* s);

#ifdef __cplusplus
}
#endif

#endif // LOOPIT_MINIS_FF_SESSION_H
