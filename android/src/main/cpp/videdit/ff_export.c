// Export pipeline. Decodes the source (or each clip in the timeline JSON),
// feeds a filtergraph built from the timeline params, encodes via the
// preset's codec/bitrate, and muxes into the requested container.
//
// improvement3.md §C12 preset map is hard-coded below. When
// options.targetSizeMb is set, the function runs a two-pass encode by
// invoking the encoder twice with -pass 1 / -pass 2 equivalents.

#include "ff_common.h"
#include "ff_session.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/avutil.h>
#include <libavutil/opt.h>
#include <libavutil/imgutils.h>
#include <libavutil/samplefmt.h>
#include <libavutil/channel_layout.h>
#include <libavfilter/avfilter.h>
#include <libavfilter/buffersink.h>
#include <libavfilter/buffersrc.h>
#include <libswscale/swscale.h>
#include <libswresample/swresample.h>

typedef struct preset {
  const char* name;
  int   width;
  int   height;
  const char* video_codec;   // libx264 / libx265 / h264_mediacodec / h264_videotoolbox / etc.
  int   video_bitrate_kbps;
  const char* audio_codec;
  int   audio_bitrate_kbps;
  const char* pix_fmt;
  int   fps;
  const char* container;
} preset_t;

static const preset_t kPresets[] = {
  {"reel",   1080, 1920, "h264_mediacodec",  8000, "aac", 192, "yuv420p", 30, "mp4"},
  {"story",  1080, 1920, "h264_mediacodec",  6000, "aac", 192, "yuv420p", 30, "mp4"},
  {"feed",   1080, 1080, "h264_mediacodec",  6000, "aac", 192, "yuv420p", 30, "mp4"},
  {"hd",     1920, 1080, "h264_mediacodec", 10000, "aac", 192, "yuv420p", 30, "mp4"},
  {"4k",     3840, 2160, "hevc_mediacodec", 25000, "aac", 192, "yuv420p", 30, "mp4"},
  {"hevc",      0,    0, "hevc_mediacodec",  8000, "aac", 192, "yuv420p", 30, "mp4"},
  {"prores",    0,    0, "prores_ks",            0, "pcm_s16le",     0, "yuv422p10le", 30, "mov"},
  {"webm",   1080, 1920, "libvpx_vp9",       6000, "libopus", 128, "yuv420p", 30, "webm"},
  {"gif",     480,    0, "gif",                 0, NULL,                0, "pal8", 12, "gif"},
};
static const int kPresetCount = sizeof(kPresets) / sizeof(kPresets[0]);

static const preset_t* lookup(const char* name) {
  if (!name) return &kPresets[2];
  for (int i = 0; i < kPresetCount; i++) {
    if (strcmp(kPresets[i].name, name) == 0) return &kPresets[i];
  }
  return &kPresets[2];
}

int ff_progress_register(const char* task_id);
void ff_progress_deregister(const char* task_id);
int ff_progress_is_cancelled(const char* task_id);

static void emit(ff_progress_cb_t* cb, const char* task_id, double pct,
                 double fps, double eta) {
  if (cb && cb->emit) cb->emit(cb->user, task_id, "export", pct, fps, eta);
}

// Parses a `"key":value` integer field from the options JSON. Tiny scanner —
// the JSON is built on the Kotlin/Swift side and only contains scalar
// fields (targetSizeMb, taskId, twoPass, audioBitrate, …).
static long long json_int_field(const char* json, const char* key, long long def) {
  if (!json || !key) return def;
  char needle[64];
  snprintf(needle, sizeof(needle), "\"%s\"", key);
  const char* p = strstr(json, needle);
  if (!p) return def;
  p = strchr(p, ':');
  if (!p) return def;
  return strtoll(p + 1, NULL, 10);
}

static int json_str_field(const char* json, const char* key, char* out, size_t out_sz) {
  if (!json || !key || !out || out_sz == 0) return 0;
  char needle[64];
  snprintf(needle, sizeof(needle), "\"%s\"", key);
  const char* p = strstr(json, needle);
  if (!p) return 0;
  p = strchr(p, ':');
  if (!p) return 0;
  while (*++p && *p != '"');
  if (!*p) return 0;
  const char* end = strchr(p + 1, '"');
  if (!end) return 0;
  size_t n = (size_t)(end - p - 1);
  if (n >= out_sz) n = out_sz - 1;
  memcpy(out, p + 1, n);
  out[n] = 0;
  return 1;
}

static int run_single_pass(const char* src_path, const preset_t* p,
                           const char* out_path, int pass_num,
                           int target_video_kbps, const char* task_id,
                           const char* options_json_for_audio,
                           ff_progress_cb_t* cb) {
  AVFormatContext* ictx = NULL;
  int rc = avformat_open_input(&ictx, src_path, NULL, NULL);
  if (rc < 0) return rc;
  rc = avformat_find_stream_info(ictx, NULL);
  if (rc < 0) { avformat_close_input(&ictx); return rc; }

  int v_idx = -1, a_idx = -1;
  for (unsigned i = 0; i < ictx->nb_streams; i++) {
    enum AVMediaType t = ictx->streams[i]->codecpar->codec_type;
    if (t == AVMEDIA_TYPE_VIDEO && v_idx < 0) v_idx = (int)i;
    else if (t == AVMEDIA_TYPE_AUDIO && a_idx < 0) a_idx = (int)i;
  }
  if (v_idx < 0) { avformat_close_input(&ictx); return AVERROR_STREAM_NOT_FOUND; }

  AVStream* in_v = ictx->streams[v_idx];
  AVCodecParameters* in_v_cp = in_v->codecpar;

  // Decoder.
  const AVCodec* dec = avcodec_find_decoder(in_v_cp->codec_id);
  AVCodecContext* dec_ctx = avcodec_alloc_context3(dec);
  avcodec_parameters_to_context(dec_ctx, in_v_cp);
  rc = avcodec_open2(dec_ctx, dec, NULL);
  if (rc < 0) { avcodec_free_context(&dec_ctx); avformat_close_input(&ictx); return rc; }

  // Encoder.
  const AVCodec* enc = avcodec_find_encoder_by_name(p->video_codec);
  if (!enc) {
    FF_LOGW("ff_export: preferred encoder '%s' unavailable, falling back to libx264", p->video_codec);
    enc = avcodec_find_encoder_by_name("libx264");
  }
  if (!enc) { avcodec_free_context(&dec_ctx); avformat_close_input(&ictx); return -1; }
  AVCodecContext* enc_ctx = avcodec_alloc_context3(enc);
  enc_ctx->width  = p->width  > 0 ? p->width  : in_v_cp->width;
  enc_ctx->height = p->height > 0 ? p->height : in_v_cp->height;
  enc_ctx->time_base = (AVRational){1, p->fps};
  enc_ctx->framerate = (AVRational){p->fps, 1};
  enc_ctx->pix_fmt = av_get_pix_fmt(p->pix_fmt);
  enc_ctx->bit_rate = (int64_t)target_video_kbps * 1000;
  enc_ctx->gop_size = p->fps * 2;

  AVDictionary* enc_opts = NULL;
  if (strcmp(p->video_codec, "libx264") == 0 || strcmp(p->video_codec, "libx265") == 0) {
    av_dict_set(&enc_opts, "preset", "medium", 0);
    av_dict_set(&enc_opts, "profile", "high", 0);
    if (pass_num == 1) av_dict_set(&enc_opts, "x264-params", "pass=1", 0);
    if (pass_num == 2) av_dict_set(&enc_opts, "x264-params", "pass=2", 0);
  }
  rc = avcodec_open2(enc_ctx, enc, &enc_opts);
  av_dict_free(&enc_opts);
  if (rc < 0) {
    avcodec_free_context(&enc_ctx);
    avcodec_free_context(&dec_ctx);
    avformat_close_input(&ictx);
    return rc;
  }

  // Output muxer (skipped on pass 1: write to /dev/null).
  AVFormatContext* octx = NULL;
  const char* dest = pass_num == 1 ? "/dev/null" : out_path;
  rc = avformat_alloc_output_context2(&octx, NULL, p->container, dest);
  if (rc < 0 || !octx) goto cleanup;
  AVStream* out_v = avformat_new_stream(octx, NULL);
  rc = avcodec_parameters_from_context(out_v->codecpar, enc_ctx);
  if (rc < 0) goto cleanup;
  out_v->time_base = enc_ctx->time_base;

  // Audio path:
  //   - When the host supplies an `audioFilter` string (built by
  //     ff_audio_graph.c on the Kotlin/Swift side), open a filtergraph,
  //     re-encode to AAC, and apply volume/fade/loudnorm/ducking.
  //   - Otherwise stream-copy the source audio to avoid an unnecessary
  //     re-encode of the music track.
  int out_a_idx = -1;
  AVFilterGraph* afilt_graph = NULL;
  AVFilterContext* afilt_src = NULL;
  AVFilterContext* afilt_sink = NULL;
  AVCodecContext* a_dec = NULL;
  AVCodecContext* a_enc = NULL;
  char audio_filter[1024] = {0};
  if (options_json_for_audio) json_str_field(options_json_for_audio,
                                             "audioFilter", audio_filter, sizeof(audio_filter));

  if (a_idx >= 0 && pass_num != 1) {
    if (audio_filter[0]) {
      // Decoder → graph → AAC encoder pipeline.
      AVStream* in_a = ictx->streams[a_idx];
      const AVCodec* dec = avcodec_find_decoder(in_a->codecpar->codec_id);
      a_dec = avcodec_alloc_context3(dec);
      avcodec_parameters_to_context(a_dec, in_a->codecpar);
      a_dec->pkt_timebase = in_a->time_base;
      if (avcodec_open2(a_dec, dec, NULL) >= 0) {
        const AVCodec* enc = avcodec_find_encoder(AV_CODEC_ID_AAC);
        a_enc = avcodec_alloc_context3(enc);
        a_enc->sample_rate = a_dec->sample_rate;
        av_channel_layout_copy(&a_enc->ch_layout, &a_dec->ch_layout);
        a_enc->sample_fmt = enc->sample_fmts ? enc->sample_fmts[0] : AV_SAMPLE_FMT_FLTP;
        a_enc->bit_rate = (int64_t)p->audio_bitrate_kbps * 1000;
        a_enc->time_base = (AVRational){1, a_enc->sample_rate};
        if (octx->oformat->flags & AVFMT_GLOBALHEADER) {
          a_enc->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
        }
        avcodec_open2(a_enc, enc, NULL);

        AVStream* out_a = avformat_new_stream(octx, NULL);
        avcodec_parameters_from_context(out_a->codecpar, a_enc);
        out_a->time_base = a_enc->time_base;
        out_a_idx = out_a->index;

        // Build the filtergraph.
        afilt_graph = avfilter_graph_alloc();
        char src_args[256];
        snprintf(src_args, sizeof(src_args),
                 "time_base=%d/%d:sample_rate=%d:sample_fmt=%s:channel_layout=0x%llx",
                 in_a->time_base.num, in_a->time_base.den,
                 a_dec->sample_rate, av_get_sample_fmt_name(a_dec->sample_fmt),
                 (unsigned long long)a_dec->ch_layout.u.mask);
        const AVFilter* abuffer = avfilter_get_by_name("abuffer");
        const AVFilter* abuffersink = avfilter_get_by_name("abuffersink");
        avfilter_graph_create_filter(&afilt_src, abuffer, "src", src_args, NULL, afilt_graph);
        avfilter_graph_create_filter(&afilt_sink, abuffersink, "sink", NULL, NULL, afilt_graph);

        AVFilterInOut* outputs = avfilter_inout_alloc();
        outputs->name = av_strdup("in");
        outputs->filter_ctx = afilt_src;
        outputs->pad_idx = 0;
        outputs->next = NULL;
        AVFilterInOut* inputs = avfilter_inout_alloc();
        inputs->name = av_strdup("out");
        inputs->filter_ctx = afilt_sink;
        inputs->pad_idx = 0;
        inputs->next = NULL;
        avfilter_graph_parse_ptr(afilt_graph, audio_filter, &inputs, &outputs, NULL);
        avfilter_graph_config(afilt_graph, NULL);
        avfilter_inout_free(&inputs);
        avfilter_inout_free(&outputs);
        FF_LOGI("ff_export: audio filter graph configured: %s", audio_filter);
      }
    } else {
      AVStream* in_a = ictx->streams[a_idx];
      AVStream* out_a = avformat_new_stream(octx, NULL);
      avcodec_parameters_copy(out_a->codecpar, in_a->codecpar);
      out_a->codecpar->codec_tag = 0;
      out_a->time_base = in_a->time_base;
      out_a_idx = out_a->index;
    }
  }

  AVDictionary* mux_opts = NULL;
  av_dict_set(&mux_opts, "movflags", "+faststart", 0);
  if (pass_num != 1 && !(octx->oformat->flags & AVFMT_NOFILE)) {
    rc = avio_open(&octx->pb, dest, AVIO_FLAG_WRITE);
    if (rc < 0) goto cleanup;
  }
  if (pass_num != 1) {
    rc = avformat_write_header(octx, &mux_opts);
    if (rc < 0) goto cleanup;
  }

  AVPacket* pkt = av_packet_alloc();
  AVPacket* enc_pkt = av_packet_alloc();
  AVFrame* frame = av_frame_alloc();
  AVFrame* out_frame = av_frame_alloc();
  out_frame->format = enc_ctx->pix_fmt;
  out_frame->width = enc_ctx->width;
  out_frame->height = enc_ctx->height;
  av_frame_get_buffer(out_frame, 32);

  struct SwsContext* sws = sws_getContext(
      dec_ctx->width, dec_ctx->height, dec_ctx->pix_fmt,
      enc_ctx->width, enc_ctx->height, enc_ctx->pix_fmt,
      SWS_BILINEAR, NULL, NULL, NULL);

  int64_t pts = 0;
  int64_t total_us = ictx->duration > 0 ? ictx->duration : 1;
  while ((rc = av_read_frame(ictx, pkt)) >= 0) {
    if (cb && cb->cancel_flag) { rc = AVERROR_EXIT; break; }
    if (task_id && ff_progress_is_cancelled(task_id)) { rc = AVERROR_EXIT; break; }

    if (pkt->stream_index == v_idx) {
      if (avcodec_send_packet(dec_ctx, pkt) >= 0) {
        while (avcodec_receive_frame(dec_ctx, frame) == 0) {
          sws_scale(sws, (const uint8_t* const*)frame->data, frame->linesize,
                    0, dec_ctx->height,
                    out_frame->data, out_frame->linesize);
          out_frame->pts = pts++;
          if (avcodec_send_frame(enc_ctx, out_frame) >= 0) {
            while (avcodec_receive_packet(enc_ctx, enc_pkt) == 0) {
              if (pass_num != 1) {
                enc_pkt->stream_index = out_v->index;
                av_packet_rescale_ts(enc_pkt, enc_ctx->time_base, out_v->time_base);
                av_interleaved_write_frame(octx, enc_pkt);
              }
              av_packet_unref(enc_pkt);
            }
          }
          int64_t pts_us = av_rescale_q(frame->pts, in_v->time_base, AV_TIME_BASE_Q);
          double pct = (double)pts_us / (double)total_us;
          emit(cb, task_id ? task_id : "", pct, (double)pts, 0.0);
          av_frame_unref(frame);
        }
      }
    } else if (pkt->stream_index == a_idx && out_a_idx >= 0) {
      AVStream* in_a = ictx->streams[a_idx];
      AVStream* out_a = octx->streams[out_a_idx];
      if (afilt_graph && a_dec && a_enc) {
        // Decode → graph → encode → mux.
        AVFrame* a_frame = av_frame_alloc();
        AVFrame* filt_frame = av_frame_alloc();
        if (avcodec_send_packet(a_dec, pkt) >= 0) {
          while (avcodec_receive_frame(a_dec, a_frame) == 0) {
            if (av_buffersrc_add_frame_flags(afilt_src, a_frame, 0) >= 0) {
              while (av_buffersink_get_frame(afilt_sink, filt_frame) >= 0) {
                if (avcodec_send_frame(a_enc, filt_frame) >= 0) {
                  while (avcodec_receive_packet(a_enc, enc_pkt) == 0) {
                    av_packet_rescale_ts(enc_pkt, a_enc->time_base, out_a->time_base);
                    enc_pkt->stream_index = out_a_idx;
                    av_interleaved_write_frame(octx, enc_pkt);
                    av_packet_unref(enc_pkt);
                  }
                }
                av_frame_unref(filt_frame);
              }
            }
            av_frame_unref(a_frame);
          }
        }
        av_frame_free(&a_frame);
        av_frame_free(&filt_frame);
      } else {
        av_packet_rescale_ts(pkt, in_a->time_base, out_a->time_base);
        pkt->stream_index = out_a_idx;
        pkt->pos = -1;
        av_interleaved_write_frame(octx, pkt);
      }
    }
    av_packet_unref(pkt);
  }

  // Flush.
  avcodec_send_frame(enc_ctx, NULL);
  while (avcodec_receive_packet(enc_ctx, enc_pkt) == 0) {
    if (pass_num != 1) {
      enc_pkt->stream_index = out_v->index;
      av_packet_rescale_ts(enc_pkt, enc_ctx->time_base, out_v->time_base);
      av_interleaved_write_frame(octx, enc_pkt);
    }
    av_packet_unref(enc_pkt);
  }
  if (pass_num != 1) av_write_trailer(octx);

  if (sws) sws_freeContext(sws);
  av_packet_free(&pkt);
  av_packet_free(&enc_pkt);
  av_frame_free(&frame);
  av_frame_free(&out_frame);
  if (afilt_graph) avfilter_graph_free(&afilt_graph);
  if (a_dec) avcodec_free_context(&a_dec);
  if (a_enc) avcodec_free_context(&a_enc);
  if (mux_opts) av_dict_free(&mux_opts);

cleanup:
  if (octx) {
    if (octx->pb && !(octx->oformat->flags & AVFMT_NOFILE)) avio_closep(&octx->pb);
    avformat_free_context(octx);
  }
  avcodec_free_context(&enc_ctx);
  avcodec_free_context(&dec_ctx);
  avformat_close_input(&ictx);
  return rc < 0 && rc != AVERROR_EOF ? rc : 0;
}

int ff_export_run(const char* timeline_json, const char* preset_name,
                  const char* out_path, const char* options_json,
                  ff_progress_cb_t* cb) {
  if (!out_path) return -1;
  const preset_t* p = lookup(preset_name);

  // Phase 2.5: timeline_json carries the full multi-clip composition.
  // The current implementation only honours a single `inputPath` field so
  // export-from-trimmer works end-to-end on day one.
  char src_path[1024] = {0};
  json_str_field(options_json, "inputPath", src_path, sizeof(src_path));
  if (!src_path[0]) {
    json_str_field(timeline_json, "inputPath", src_path, sizeof(src_path));
  }
  if (!src_path[0]) {
    FF_LOGE("ff_export_run: missing inputPath in options/timeline");
    return -1;
  }

  char task_id[64] = {0};
  json_str_field(options_json, "taskId", task_id, sizeof(task_id));
  if (task_id[0]) ff_progress_register(task_id);

  long long target_mb = json_int_field(options_json, "targetSizeMb", 0);
  int video_kbps = p->video_bitrate_kbps;
  int two_pass = target_mb > 0 ? 1 : (int)json_int_field(options_json, "twoPass", 0);
  if (target_mb > 0) {
    // duration probe to derive bitrate
    AVFormatContext* probe = NULL;
    if (avformat_open_input(&probe, src_path, NULL, NULL) == 0) {
      avformat_find_stream_info(probe, NULL);
      double dur_s = probe->duration > 0 ? probe->duration / (double)AV_TIME_BASE : 1.0;
      video_kbps = (int)((target_mb * 8.0 * 1024.0 / dur_s) - p->audio_bitrate_kbps);
      if (video_kbps < 500) video_kbps = 500;
      avformat_close_input(&probe);
    }
  }

  int rc = 0;
  if (two_pass) {
    rc = run_single_pass(src_path, p, out_path, 1, video_kbps, task_id, options_json, cb);
    if (rc == 0) rc = run_single_pass(src_path, p, out_path, 2, video_kbps, task_id, options_json, cb);
  } else {
    rc = run_single_pass(src_path, p, out_path, 0, video_kbps, task_id, options_json, cb);
  }

  if (task_id[0]) ff_progress_deregister(task_id);
  return rc;
}
