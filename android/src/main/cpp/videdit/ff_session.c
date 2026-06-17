// Wraps AVFormatContext for the bridge layer. Opens a file, probes streams,
// exposes the basic metadata that every higher-level operation needs
// (duration, resolution, fps, codecs).
//
// Higher-level pipelines (trim, concat, export, repair) open their own
// AVFormatContext instances and do not share one with the session probe.

#include "ff_session.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/dict.h>
#include <libavutil/display.h>
#include <libavutil/rational.h>

struct ff_session {
  AVFormatContext* fmt;
  int video_stream;
  int audio_stream;
};

static double stream_fps(AVStream* s) {
  if (!s) return 0.0;
  AVRational fr = av_guess_frame_rate(NULL, s, NULL);
  if (fr.num <= 0 || fr.den <= 0) return 0.0;
  return (double)fr.num / (double)fr.den;
}

static int rotation_from_side_data(AVStream* s) {
  if (!s) return 0;
  for (int i = 0; i < s->nb_side_data; i++) {
    AVPacketSideData* sd = &s->side_data[i];
    if (sd->type == AV_PKT_DATA_DISPLAYMATRIX && sd->size >= 9 * sizeof(int32_t)) {
      double theta = av_display_rotation_get((int32_t*)sd->data);
      if (!isnan(theta)) return (int)lround(theta);
    }
  }
  AVDictionaryEntry* e = av_dict_get(s->metadata, "rotate", NULL, 0);
  if (e && e->value) return atoi(e->value);
  return 0;
}

ff_session_t* ff_session_open(const char* path) {
  if (!path || !path[0]) return NULL;
  ff_session_t* s = (ff_session_t*)calloc(1, sizeof(*s));
  if (!s) return NULL;
  s->video_stream = -1;
  s->audio_stream = -1;

  int rc = avformat_open_input(&s->fmt, path, NULL, NULL);
  if (rc < 0 || !s->fmt) {
    FF_LOGE("ff_session_open: open '%s' rc=%d", path, rc);
    free(s);
    return NULL;
  }
  rc = avformat_find_stream_info(s->fmt, NULL);
  if (rc < 0) {
    FF_LOGW("ff_session_open: find_stream_info rc=%d", rc);
  }

  for (unsigned i = 0; i < s->fmt->nb_streams; i++) {
    AVStream* st = s->fmt->streams[i];
    if (!st || !st->codecpar) continue;
    if (st->codecpar->codec_type == AVMEDIA_TYPE_VIDEO && s->video_stream < 0) {
      s->video_stream = (int)i;
    } else if (st->codecpar->codec_type == AVMEDIA_TYPE_AUDIO && s->audio_stream < 0) {
      s->audio_stream = (int)i;
    }
  }
  return s;
}

int ff_session_info_get(ff_session_t* s, ff_session_info_t* out) {
  if (!s || !s->fmt || !out) return -1;
  memset(out, 0, sizeof(*out));

  if (s->fmt->duration != AV_NOPTS_VALUE) {
    out->duration_ms = (int64_t)(s->fmt->duration * 1000LL / AV_TIME_BASE);
  }
  out->bitrate = s->fmt->bit_rate;

  if (s->video_stream >= 0) {
    AVStream* st = s->fmt->streams[s->video_stream];
    AVCodecParameters* cp = st->codecpar;
    out->width = cp->width;
    out->height = cp->height;
    out->fps = stream_fps(st);
    out->rotation = rotation_from_side_data(st);
    const char* name = avcodec_get_name(cp->codec_id);
    if (name) {
      strncpy(out->video_codec, name, sizeof(out->video_codec) - 1);
    }
  }
  if (s->audio_stream >= 0) {
    AVStream* st = s->fmt->streams[s->audio_stream];
    AVCodecParameters* cp = st->codecpar;
    out->has_audio = 1;
    out->audio_sample_rate = cp->sample_rate;
    out->audio_channels = cp->ch_layout.nb_channels > 0
        ? cp->ch_layout.nb_channels
        : cp->channels;
    const char* name = avcodec_get_name(cp->codec_id);
    if (name) {
      strncpy(out->audio_codec, name, sizeof(out->audio_codec) - 1);
    }
  }
  return 0;
}

void ff_session_close(ff_session_t* s) {
  if (!s) return;
  if (s->fmt) {
    avformat_close_input(&s->fmt);
  }
  free(s);
}

const char* ff_build_info(void) {
  return av_version_info();
}

void ff_capabilities_query(ff_capabilities_t* out) {
  if (!out) return;
  memset(out, 0, sizeof(*out));

  out->hw_dec_h264 = (avcodec_find_decoder_by_name("h264_mediacodec") != NULL);
  out->hw_dec_hevc = (avcodec_find_decoder_by_name("hevc_mediacodec") != NULL);
  out->hw_dec_vp9  = (avcodec_find_decoder_by_name("vp9_mediacodec")  != NULL);
  out->hw_enc_h264 = (avcodec_find_encoder_by_name("h264_mediacodec") != NULL);
  out->hw_enc_hevc = (avcodec_find_encoder_by_name("hevc_mediacodec") != NULL);
  out->max_resolution_w = 3840;
  out->max_resolution_h = 2160;
  const char* bi = av_version_info();
  if (bi) strncpy(out->build_info, bi, sizeof(out->build_info) - 1);
}
