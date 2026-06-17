// Background-replacement export (improvement3.md §C10).
//
// Inputs:
//   - in_path:         source video (foreground)
//   - mask_atlas_path: file produced by BgRemover.{kt,swift} — a sequence
//                      of single-channel uint8 mask frames keyed by PTS.
//   - bg_path:         either an image file (any FFmpeg-decodable still) or
//                      a hex color of the form "#RRGGBB" (treated as a
//                      solid background).
//   - out_path:        H.264 / AAC mp4 output.
//
// Pipeline per video frame:
//   1. Decode source to RGBA.
//   2. Lookup nearest mask in the atlas by PTS (using mask_atlas_query).
//   3. Per-pixel: out = mix(bg, fg, mask / 255.0).
//   4. Encode RGBA back to YUV420P and feed the H.264 encoder.
//
// Audio is stream-copied (BG-remove does not touch audio).

#include "ff_common.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/avutil.h>
#include <libavutil/imgutils.h>
#include <libswscale/swscale.h>

// Forward decls (defined in mask_atlas.cpp).
void* mask_atlas_create(void);
void  mask_atlas_destroy(void* h);
int   mask_atlas_load(void* h, const char* path);
// Phase 2.5 — we don't need a public query yet; the C side reads the binary
// directly when atlas-driven export ships. For this verb we use the raw
// mask_atlas binary format directly.

typedef struct mask_frame_meta {
  int64_t pts_us;
  int width;
  int height;
  uint8_t* data;     // owned
} mask_frame_meta_t;

typedef struct mask_atlas_raw {
  int count;
  mask_frame_meta_t* frames;
} mask_atlas_raw_t;

static int parse_hex_color(const char* s, uint8_t* r, uint8_t* g, uint8_t* b) {
  if (!s || s[0] != '#' || strlen(s) < 7) return 0;
  unsigned int v = 0;
  if (sscanf(s + 1, "%6x", &v) != 1) return 0;
  *r = (v >> 16) & 0xff;
  *g = (v >> 8) & 0xff;
  *b = v & 0xff;
  return 1;
}

// Decode a still image (jpg / png / webp / heic — anything FFmpeg can read
// through the image2 demuxer) into an RGBA buffer at the requested size.
// Caller frees `out_rgba`. Returns 0 on success.
static int decode_image_to_rgba(const char* path, int target_w, int target_h,
                                uint8_t** out_rgba) {
  *out_rgba = NULL;
  AVFormatContext* ictx = NULL;
  int rc = avformat_open_input(&ictx, path, NULL, NULL);
  if (rc < 0) return rc;
  rc = avformat_find_stream_info(ictx, NULL);
  if (rc < 0) { avformat_close_input(&ictx); return rc; }

  int v_idx = -1;
  for (unsigned i = 0; i < ictx->nb_streams; i++) {
    if (ictx->streams[i]->codecpar->codec_type == AVMEDIA_TYPE_VIDEO) {
      v_idx = (int)i; break;
    }
  }
  if (v_idx < 0) { avformat_close_input(&ictx); return AVERROR_STREAM_NOT_FOUND; }

  AVCodecParameters* cp = ictx->streams[v_idx]->codecpar;
  const AVCodec* dec = avcodec_find_decoder(cp->codec_id);
  AVCodecContext* dc = avcodec_alloc_context3(dec);
  avcodec_parameters_to_context(dc, cp);
  rc = avcodec_open2(dc, dec, NULL);
  if (rc < 0) {
    avcodec_free_context(&dc);
    avformat_close_input(&ictx);
    return rc;
  }

  AVPacket* pkt = av_packet_alloc();
  AVFrame* frame = av_frame_alloc();
  int got = 0;
  while (av_read_frame(ictx, pkt) >= 0 && !got) {
    if (pkt->stream_index == v_idx && avcodec_send_packet(dc, pkt) >= 0) {
      if (avcodec_receive_frame(dc, frame) == 0) got = 1;
    }
    av_packet_unref(pkt);
  }
  rc = got ? 0 : -1;

  if (got) {
    struct SwsContext* sws = sws_getContext(
        frame->width, frame->height, dc->pix_fmt,
        target_w, target_h, AV_PIX_FMT_RGBA,
        SWS_BILINEAR, NULL, NULL, NULL);
    if (sws) {
      *out_rgba = (uint8_t*)malloc((size_t)target_w * target_h * 4);
      uint8_t* dst[4] = { *out_rgba, NULL, NULL, NULL };
      int dst_linesize[4] = { target_w * 4, 0, 0, 0 };
      sws_scale(sws, (const uint8_t* const*)frame->data, frame->linesize,
                0, frame->height, dst, dst_linesize);
      sws_freeContext(sws);
    } else {
      rc = -1;
    }
  }

  av_packet_free(&pkt);
  av_frame_free(&frame);
  avcodec_free_context(&dc);
  avformat_close_input(&ictx);
  return rc;
}

static int read_atlas_blob(const char* path, mask_atlas_raw_t* out) {
  FILE* f = fopen(path, "rb");
  if (!f) return -1;
  uint32_t magic = 0;
  if (fread(&magic, 4, 1, f) != 1 || magic != 0x4D4E4D41) { fclose(f); return -1; }
  uint32_t count = 0;
  fread(&count, 4, 1, f);
  out->count = (int)count;
  out->frames = (mask_frame_meta_t*)calloc((size_t)count, sizeof(*out->frames));
  for (uint32_t i = 0; i < count; i++) {
    mask_frame_meta_t* mf = &out->frames[i];
    int64_t pts_ms = 0;
    fread(&pts_ms, sizeof(int64_t), 1, f);
    mf->pts_us = pts_ms * 1000;
    int32_t w = 0, h = 0;
    fread(&w, sizeof(int32_t), 1, f);
    fread(&h, sizeof(int32_t), 1, f);
    mf->width = w; mf->height = h;
    uint32_t n = 0;
    fread(&n, sizeof(uint32_t), 1, f);
    mf->data = (uint8_t*)malloc(n);
    fread(mf->data, 1, n, f);
  }
  fclose(f);
  return 0;
}

static void atlas_free(mask_atlas_raw_t* a) {
  if (!a || !a->frames) return;
  for (int i = 0; i < a->count; i++) free(a->frames[i].data);
  free(a->frames);
  a->frames = NULL;
  a->count = 0;
}

static const mask_frame_meta_t* nearest_mask(const mask_atlas_raw_t* a, int64_t pts_us) {
  if (!a || a->count == 0) return NULL;
  int lo = 0, hi = a->count - 1;
  while (lo < hi) {
    int mid = (lo + hi) >> 1;
    if (a->frames[mid].pts_us < pts_us) lo = mid + 1;
    else hi = mid;
  }
  // Return the closer of `lo` and `lo - 1`.
  if (lo > 0 && (pts_us - a->frames[lo - 1].pts_us) < (a->frames[lo].pts_us - pts_us)) {
    return &a->frames[lo - 1];
  }
  return &a->frames[lo];
}

// Bilinearly sample mask at (x_norm, y_norm) where both ∈ [0, 1].
static float sample_mask(const mask_frame_meta_t* m, float xn, float yn) {
  if (!m) return 0.0f;
  float x = xn * (float)(m->width - 1);
  float y = yn * (float)(m->height - 1);
  int x0 = (int)x, y0 = (int)y;
  if (x0 < 0) x0 = 0; if (x0 > m->width - 1) x0 = m->width - 1;
  if (y0 < 0) y0 = 0; if (y0 > m->height - 1) y0 = m->height - 1;
  return (float)m->data[y0 * m->width + x0] / 255.0f;
}

int ff_bg_compose_run(const char* in_path, const char* mask_atlas_path,
                      const char* bg_spec, const char* out_path,
                      ff_progress_cb_t* cb) {
  if (!in_path || !out_path || !mask_atlas_path) return -1;
  uint8_t bg_r = 0, bg_g = 0, bg_b = 0;
  uint8_t* bg_image_rgba = NULL;   // owned, freed at cleanup; NULL = solid colour
  int have_bg_image = 0;
  if (!parse_hex_color(bg_spec ? bg_spec : "#000000", &bg_r, &bg_g, &bg_b)) {
    // Treat bg_spec as a still image path. Resolution is matched at the
    // decoder step below once we know the foreground dimensions.
    have_bg_image = 1;
  }

  mask_atlas_raw_t atlas = {0};
  if (read_atlas_blob(mask_atlas_path, &atlas) != 0) {
    FF_LOGE("ff_bg_compose: atlas read '%s' failed", mask_atlas_path);
    return -1;
  }

  AVFormatContext* ictx = NULL;
  int rc = avformat_open_input(&ictx, in_path, NULL, NULL);
  if (rc < 0) { atlas_free(&atlas); return rc; }
  rc = avformat_find_stream_info(ictx, NULL);
  if (rc < 0) { avformat_close_input(&ictx); atlas_free(&atlas); return rc; }

  int v_idx = -1, a_idx = -1;
  for (unsigned i = 0; i < ictx->nb_streams; i++) {
    enum AVMediaType t = ictx->streams[i]->codecpar->codec_type;
    if (t == AVMEDIA_TYPE_VIDEO && v_idx < 0) v_idx = (int)i;
    else if (t == AVMEDIA_TYPE_AUDIO && a_idx < 0) a_idx = (int)i;
  }
  if (v_idx < 0) { avformat_close_input(&ictx); atlas_free(&atlas); return AVERROR_STREAM_NOT_FOUND; }

  AVStream* in_v = ictx->streams[v_idx];
  const AVCodec* dec = avcodec_find_decoder(in_v->codecpar->codec_id);
  AVCodecContext* dec_ctx = avcodec_alloc_context3(dec);
  avcodec_parameters_to_context(dec_ctx, in_v->codecpar);
  dec_ctx->pkt_timebase = in_v->time_base;
  rc = avcodec_open2(dec_ctx, dec, NULL);
  if (rc < 0) { avcodec_free_context(&dec_ctx); avformat_close_input(&ictx); atlas_free(&atlas); return rc; }

  if (have_bg_image) {
    if (decode_image_to_rgba(bg_spec, dec_ctx->width, dec_ctx->height, &bg_image_rgba) != 0) {
      FF_LOGW("ff_bg_compose: image decode '%s' failed, falling back to black", bg_spec);
      have_bg_image = 0;
      bg_r = bg_g = bg_b = 0;
    }
  }

  const AVCodec* enc = avcodec_find_encoder_by_name("h264_mediacodec");
  if (!enc) enc = avcodec_find_encoder_by_name("h264_videotoolbox");
  if (!enc) enc = avcodec_find_encoder_by_name("libx264");
  AVCodecContext* enc_ctx = avcodec_alloc_context3(enc);
  enc_ctx->width = dec_ctx->width;
  enc_ctx->height = dec_ctx->height;
  enc_ctx->pix_fmt = AV_PIX_FMT_YUV420P;
  enc_ctx->time_base = (AVRational){1, 30};
  enc_ctx->framerate = (AVRational){30, 1};
  enc_ctx->bit_rate = 6 * 1000 * 1000;
  enc_ctx->gop_size = 60;

  AVFormatContext* octx = NULL;
  avformat_alloc_output_context2(&octx, NULL, NULL, out_path);
  if (octx->oformat->flags & AVFMT_GLOBALHEADER) {
    enc_ctx->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
  }
  avcodec_open2(enc_ctx, enc, NULL);
  AVStream* out_v = avformat_new_stream(octx, NULL);
  avcodec_parameters_from_context(out_v->codecpar, enc_ctx);
  out_v->time_base = enc_ctx->time_base;

  int out_a_idx = -1;
  if (a_idx >= 0) {
    AVStream* in_a = ictx->streams[a_idx];
    AVStream* out_a = avformat_new_stream(octx, NULL);
    avcodec_parameters_copy(out_a->codecpar, in_a->codecpar);
    out_a->codecpar->codec_tag = 0;
    out_a->time_base = in_a->time_base;
    out_a_idx = out_a->index;
  }

  AVDictionary* mux_opts = NULL;
  av_dict_set(&mux_opts, "movflags", "+faststart", 0);
  if (!(octx->oformat->flags & AVFMT_NOFILE)) {
    avio_open(&octx->pb, out_path, AVIO_FLAG_WRITE);
  }
  avformat_write_header(octx, &mux_opts);
  av_dict_free(&mux_opts);

  struct SwsContext* to_rgba = sws_getContext(
      dec_ctx->width, dec_ctx->height, dec_ctx->pix_fmt,
      dec_ctx->width, dec_ctx->height, AV_PIX_FMT_RGBA,
      SWS_BILINEAR, NULL, NULL, NULL);
  struct SwsContext* to_yuv = sws_getContext(
      dec_ctx->width, dec_ctx->height, AV_PIX_FMT_RGBA,
      enc_ctx->width, enc_ctx->height, enc_ctx->pix_fmt,
      SWS_BILINEAR, NULL, NULL, NULL);

  AVFrame* frame = av_frame_alloc();
  AVFrame* rgba = av_frame_alloc();
  rgba->format = AV_PIX_FMT_RGBA;
  rgba->width = dec_ctx->width;
  rgba->height = dec_ctx->height;
  av_frame_get_buffer(rgba, 32);
  AVFrame* yuv = av_frame_alloc();
  yuv->format = enc_ctx->pix_fmt;
  yuv->width = enc_ctx->width;
  yuv->height = enc_ctx->height;
  av_frame_get_buffer(yuv, 32);

  AVPacket* pkt = av_packet_alloc();
  AVPacket* enc_pkt = av_packet_alloc();
  int64_t v_pts = 0;
  int64_t total_us = ictx->duration > 0 ? ictx->duration : 1;

  while ((rc = av_read_frame(ictx, pkt)) >= 0) {
    if (cb && cb->cancel_flag) { rc = AVERROR_EXIT; break; }
    if (pkt->stream_index == v_idx) {
      if (avcodec_send_packet(dec_ctx, pkt) >= 0) {
        while (avcodec_receive_frame(dec_ctx, frame) == 0) {
          sws_scale(to_rgba, (const uint8_t* const*)frame->data, frame->linesize,
                    0, dec_ctx->height, rgba->data, rgba->linesize);

          int64_t pts_us = av_rescale_q(frame->pts, in_v->time_base, AV_TIME_BASE_Q);
          const mask_frame_meta_t* m = nearest_mask(&atlas, pts_us);

          // Per-pixel composite: out = bg + (fg - bg) * mask.
          // bg is either the solid colour or sampled from the still image.
          uint8_t* row = rgba->data[0];
          int stride = rgba->linesize[0];
          int W = rgba->width;
          for (int y = 0; y < rgba->height; y++) {
            float yn = (float)y / (float)(rgba->height - 1);
            uint8_t* p = row + y * stride;
            for (int x = 0; x < W; x++) {
              float xn = (float)x / (float)(W - 1);
              float a = sample_mask(m, xn, yn);
              uint8_t br, bg, bb;
              if (have_bg_image) {
                const uint8_t* bp = &bg_image_rgba[(y * W + x) * 4];
                br = bp[0]; bg = bp[1]; bb = bp[2];
              } else {
                br = bg_r; bg = bg_g; bb = bg_b;
              }
              p[0] = (uint8_t)(br + (p[0] - br) * a);
              p[1] = (uint8_t)(bg + (p[1] - bg) * a);
              p[2] = (uint8_t)(bb + (p[2] - bb) * a);
              p += 4;
            }
          }

          sws_scale(to_yuv, (const uint8_t* const*)rgba->data, rgba->linesize,
                    0, rgba->height, yuv->data, yuv->linesize);
          yuv->pts = v_pts++;
          if (avcodec_send_frame(enc_ctx, yuv) >= 0) {
            while (avcodec_receive_packet(enc_ctx, enc_pkt) == 0) {
              enc_pkt->stream_index = out_v->index;
              av_packet_rescale_ts(enc_pkt, enc_ctx->time_base, out_v->time_base);
              av_interleaved_write_frame(octx, enc_pkt);
              av_packet_unref(enc_pkt);
            }
          }
          if (cb && cb->emit) {
            cb->emit(cb->user, "", "bgcompose",
                     (double)pts_us / (double)total_us, (double)v_pts, 0.0);
          }
          av_frame_unref(frame);
        }
      }
    } else if (out_a_idx >= 0 && pkt->stream_index == a_idx) {
      AVStream* in_a = ictx->streams[a_idx];
      AVStream* out_a = octx->streams[out_a_idx];
      av_packet_rescale_ts(pkt, in_a->time_base, out_a->time_base);
      pkt->stream_index = out_a_idx;
      pkt->pos = -1;
      av_interleaved_write_frame(octx, pkt);
    }
    av_packet_unref(pkt);
  }
  // Flush encoder.
  avcodec_send_frame(enc_ctx, NULL);
  while (avcodec_receive_packet(enc_ctx, enc_pkt) == 0) {
    enc_pkt->stream_index = out_v->index;
    av_packet_rescale_ts(enc_pkt, enc_ctx->time_base, out_v->time_base);
    av_interleaved_write_frame(octx, enc_pkt);
    av_packet_unref(enc_pkt);
  }
  av_write_trailer(octx);

  sws_freeContext(to_rgba);
  sws_freeContext(to_yuv);
  av_packet_free(&pkt);
  av_packet_free(&enc_pkt);
  av_frame_free(&frame);
  av_frame_free(&rgba);
  av_frame_free(&yuv);
  avcodec_free_context(&enc_ctx);
  avcodec_free_context(&dec_ctx);
  if (octx->pb && !(octx->oformat->flags & AVFMT_NOFILE)) avio_closep(&octx->pb);
  avformat_free_context(octx);
  avformat_close_input(&ictx);
  atlas_free(&atlas);
  if (bg_image_rgba) free(bg_image_rgba);
  if (cb && cb->emit) cb->emit(cb->user, "", "bgcompose", 1.0, 0.0, 0.0);
  return rc < 0 && rc != AVERROR_EOF ? rc : 0;
}
