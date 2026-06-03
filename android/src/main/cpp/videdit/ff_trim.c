// Frame-accurate trim.
//
// Two paths (improvement3.md §C4):
//   - reencode == 0  → keyframe-aligned stream-copy. Lossless. Output starts
//                      at the nearest keyframe ≤ in_ms; UI is responsible for
//                      snapping the slider to keyframe boundaries.
//   - reencode == 1  → frame-accurate transcode. Decodes from the keyframe
//                      preceding in_ms, drops frames before in_ms, re-encodes
//                      frames in [in_ms, out_ms]. Audio is transcoded to AAC
//                      to keep A/V in lockstep across the cut.
//
// Progress: emits `{kind:"trim", pct, fps, etaS}` every ~250 ms via the
// supplied `ff_progress_cb_t`.

#include "ff_common.h"
#include "ff_session.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/avutil.h>
#include <libavutil/opt.h>
#include <libavutil/timestamp.h>
#include <libavutil/mathematics.h>
#include <libavutil/channel_layout.h>
#include <libswscale/swscale.h>
#include <libswresample/swresample.h>

static int64_t now_ms(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (int64_t)ts.tv_sec * 1000LL + ts.tv_nsec / 1000000LL;
}

static int open_input(const char* path, AVFormatContext** out_ctx,
                      int* out_v, int* out_a) {
  AVFormatContext* ctx = NULL;
  int rc = avformat_open_input(&ctx, path, NULL, NULL);
  if (rc < 0) return rc;
  rc = avformat_find_stream_info(ctx, NULL);
  if (rc < 0) { avformat_close_input(&ctx); return rc; }
  int v = -1, a = -1;
  for (unsigned i = 0; i < ctx->nb_streams; i++) {
    AVMediaType t = ctx->streams[i]->codecpar->codec_type;
    if (t == AVMEDIA_TYPE_VIDEO && v < 0) v = (int)i;
    else if (t == AVMEDIA_TYPE_AUDIO && a < 0) a = (int)i;
  }
  if (v < 0) { avformat_close_input(&ctx); return AVERROR_STREAM_NOT_FOUND; }
  *out_ctx = ctx;
  *out_v = v;
  *out_a = a;
  return 0;
}

static int copy_stream(AVFormatContext* out_ctx, AVStream* in_stream,
                       int* out_stream_index) {
  AVStream* os = avformat_new_stream(out_ctx, NULL);
  if (!os) return AVERROR(ENOMEM);
  int rc = avcodec_parameters_copy(os->codecpar, in_stream->codecpar);
  if (rc < 0) return rc;
  os->codecpar->codec_tag = 0;
  os->time_base = in_stream->time_base;
  *out_stream_index = os->index;
  return 0;
}

static void emit(ff_progress_cb_t* cb, double pct, double fps, double eta) {
  if (cb && cb->emit) cb->emit(cb->user, "", "trim", pct, fps, eta);
}

// ──────────────────────────────────────────────────────────────────
// Path A: lossless stream-copy from the nearest keyframe ≤ in_ms.
// ──────────────────────────────────────────────────────────────────

static int trim_streamcopy(AVFormatContext* ictx, AVFormatContext* octx,
                           int v_idx, int a_idx, int o_v, int o_a,
                           int64_t in_ms, int64_t out_ms,
                           ff_progress_cb_t* cb) {
  AVStream* in_v = ictx->streams[v_idx];
  int64_t seek_target = av_rescale_q(in_ms, (AVRational){1, 1000}, in_v->time_base);
  int rc = av_seek_frame(ictx, v_idx, seek_target, AVSEEK_FLAG_BACKWARD);
  if (rc < 0) FF_LOGW("ff_trim_streamcopy: seek rc=%d", rc);

  int64_t in_pts_v = av_rescale_q(in_ms, (AVRational){1, 1000}, in_v->time_base);

  AVPacket* pkt = av_packet_alloc();
  int64_t last_progress_ms = now_ms();
  int64_t pkt_count = 0;
  int64_t start_wall = now_ms();
  int64_t duration_ms = out_ms - in_ms;

  while ((rc = av_read_frame(ictx, pkt)) >= 0) {
    if (cb && cb->cancel_flag) { rc = AVERROR_EXIT; break; }
    AVStream* in_s = ictx->streams[pkt->stream_index];

    int out_idx = -1;
    if (pkt->stream_index == v_idx) out_idx = o_v;
    else if (pkt->stream_index == a_idx) out_idx = o_a;
    else { av_packet_unref(pkt); continue; }

    int64_t pts_ms = av_rescale_q(pkt->pts != AV_NOPTS_VALUE ? pkt->pts : pkt->dts,
                                  in_s->time_base, (AVRational){1, 1000});
    if (pts_ms >= out_ms) { av_packet_unref(pkt); break; }
    if (pts_ms < in_ms - 33) { av_packet_unref(pkt); continue; }

    AVStream* out_s = octx->streams[out_idx];
    AVPacket* copy = av_packet_clone(pkt);
    if (!copy) { rc = AVERROR(ENOMEM); break; }
    copy->stream_index = out_idx;
    copy->pos = -1;
    copy->pts = av_rescale_q(pkt->pts - in_pts_v, in_s->time_base, out_s->time_base);
    copy->dts = av_rescale_q(pkt->dts - in_pts_v, in_s->time_base, out_s->time_base);
    copy->duration = av_rescale_q(pkt->duration, in_s->time_base, out_s->time_base);

    int wrc = av_interleaved_write_frame(octx, copy);
    av_packet_free(&copy);
    av_packet_unref(pkt);
    if (wrc < 0) { rc = wrc; break; }

    pkt_count++;
    int64_t now = now_ms();
    if (now - last_progress_ms > 250) {
      double pct = duration_ms > 0 ? (double)(pts_ms - in_ms) / duration_ms : 0.0;
      double elapsed = (double)(now - start_wall) / 1000.0;
      double fps = elapsed > 0 ? pkt_count / elapsed : 0.0;
      double eta = pct > 0 ? elapsed * (1.0 - pct) / pct : 0.0;
      emit(cb, pct, fps, eta);
      last_progress_ms = now;
    }
  }
  av_packet_free(&pkt);
  return (rc == AVERROR_EOF || rc >= 0) ? 0 : rc;
}

// ──────────────────────────────────────────────────────────────────
// Path B: frame-accurate transcode for [in_ms, out_ms].
// Decodes from the keyframe ≤ in_ms, drops frames < in_ms, encodes the
// rest. Audio re-encoded to AAC for portable container support.
// ──────────────────────────────────────────────────────────────────

typedef struct trans_video {
  AVCodecContext* dec;
  AVCodecContext* enc;
  AVStream* out_stream;
  AVStream* in_stream;
  int64_t next_pts;       // monotonic counter in enc->time_base
} trans_video_t;

typedef struct trans_audio {
  AVCodecContext* dec;
  AVCodecContext* enc;
  AVStream* out_stream;
  AVStream* in_stream;
  SwrContext* swr;
  int64_t next_pts;
} trans_audio_t;

static int build_video_transcoder(AVFormatContext* octx, AVStream* in_v,
                                  trans_video_t* tv) {
  AVCodecParameters* cp = in_v->codecpar;
  const AVCodec* dec = avcodec_find_decoder(cp->codec_id);
  if (!dec) return AVERROR_DECODER_NOT_FOUND;
  tv->dec = avcodec_alloc_context3(dec);
  avcodec_parameters_to_context(tv->dec, cp);
  tv->dec->pkt_timebase = in_v->time_base;
  int rc = avcodec_open2(tv->dec, dec, NULL);
  if (rc < 0) return rc;

  // Encoder: prefer hardware H.264; fall back to libx264.
  const AVCodec* enc = avcodec_find_encoder_by_name("h264_mediacodec");
  if (!enc) enc = avcodec_find_encoder_by_name("h264_videotoolbox");
  if (!enc) enc = avcodec_find_encoder_by_name("libx264");
  if (!enc) return AVERROR_ENCODER_NOT_FOUND;
  tv->enc = avcodec_alloc_context3(enc);
  tv->enc->width = tv->dec->width;
  tv->enc->height = tv->dec->height;
  tv->enc->pix_fmt = AV_PIX_FMT_YUV420P;
  tv->enc->time_base = (AVRational){1, 30};
  tv->enc->framerate = (AVRational){30, 1};
  tv->enc->bit_rate = cp->bit_rate > 0 ? cp->bit_rate : 6 * 1000 * 1000;
  tv->enc->gop_size = 60;
  if (octx->oformat->flags & AVFMT_GLOBALHEADER) {
    tv->enc->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
  }
  rc = avcodec_open2(tv->enc, enc, NULL);
  if (rc < 0) return rc;

  AVStream* os = avformat_new_stream(octx, NULL);
  rc = avcodec_parameters_from_context(os->codecpar, tv->enc);
  if (rc < 0) return rc;
  os->time_base = tv->enc->time_base;
  tv->out_stream = os;
  tv->in_stream = in_v;
  tv->next_pts = 0;
  return 0;
}

static int build_audio_transcoder(AVFormatContext* octx, AVStream* in_a,
                                  trans_audio_t* ta) {
  AVCodecParameters* cp = in_a->codecpar;
  const AVCodec* dec = avcodec_find_decoder(cp->codec_id);
  if (!dec) return AVERROR_DECODER_NOT_FOUND;
  ta->dec = avcodec_alloc_context3(dec);
  avcodec_parameters_to_context(ta->dec, cp);
  ta->dec->pkt_timebase = in_a->time_base;
  int rc = avcodec_open2(ta->dec, dec, NULL);
  if (rc < 0) return rc;

  const AVCodec* enc = avcodec_find_encoder(AV_CODEC_ID_AAC);
  if (!enc) return AVERROR_ENCODER_NOT_FOUND;
  ta->enc = avcodec_alloc_context3(enc);
  ta->enc->sample_rate = ta->dec->sample_rate > 0 ? ta->dec->sample_rate : 48000;
  av_channel_layout_default(&ta->enc->ch_layout, 2);
  ta->enc->sample_fmt = enc->sample_fmts ? enc->sample_fmts[0] : AV_SAMPLE_FMT_FLTP;
  ta->enc->bit_rate = 192000;
  ta->enc->time_base = (AVRational){1, ta->enc->sample_rate};
  if (octx->oformat->flags & AVFMT_GLOBALHEADER) {
    ta->enc->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
  }
  rc = avcodec_open2(ta->enc, enc, NULL);
  if (rc < 0) return rc;

  swr_alloc_set_opts2(&ta->swr,
                     &ta->enc->ch_layout, ta->enc->sample_fmt, ta->enc->sample_rate,
                     &ta->dec->ch_layout, ta->dec->sample_fmt, ta->dec->sample_rate,
                     0, NULL);
  swr_init(ta->swr);

  AVStream* os = avformat_new_stream(octx, NULL);
  rc = avcodec_parameters_from_context(os->codecpar, ta->enc);
  if (rc < 0) return rc;
  os->time_base = ta->enc->time_base;
  ta->out_stream = os;
  ta->in_stream = in_a;
  ta->next_pts = 0;
  return 0;
}

static int flush_encoder(AVCodecContext* enc, AVFormatContext* octx, AVStream* out_s) {
  int rc = avcodec_send_frame(enc, NULL);
  AVPacket* pkt = av_packet_alloc();
  while (rc >= 0) {
    rc = avcodec_receive_packet(enc, pkt);
    if (rc == AVERROR(EAGAIN) || rc == AVERROR_EOF) break;
    if (rc < 0) break;
    av_packet_rescale_ts(pkt, enc->time_base, out_s->time_base);
    pkt->stream_index = out_s->index;
    av_interleaved_write_frame(octx, pkt);
    av_packet_unref(pkt);
  }
  av_packet_free(&pkt);
  return 0;
}

static int trim_transcode(AVFormatContext* ictx, AVFormatContext* octx,
                          int v_idx, int a_idx,
                          int64_t in_ms, int64_t out_ms,
                          ff_progress_cb_t* cb) {
  trans_video_t tv = {0};
  trans_audio_t ta = {0};
  int rc = build_video_transcoder(octx, ictx->streams[v_idx], &tv);
  if (rc < 0) goto cleanup;
  int has_audio = (a_idx >= 0);
  if (has_audio) {
    rc = build_audio_transcoder(octx, ictx->streams[a_idx], &ta);
    if (rc < 0) { has_audio = 0; }
  }

  AVDictionary* mux_opts = NULL;
  av_dict_set(&mux_opts, "movflags", "+faststart", 0);
  if (!(octx->oformat->flags & AVFMT_NOFILE)) {
    rc = avio_open(&octx->pb, octx->url, AVIO_FLAG_WRITE);
    if (rc < 0) { av_dict_free(&mux_opts); goto cleanup; }
  }
  rc = avformat_write_header(octx, &mux_opts);
  av_dict_free(&mux_opts);
  if (rc < 0) goto cleanup;

  AVStream* in_v = ictx->streams[v_idx];
  int64_t seek_t = av_rescale_q(in_ms, (AVRational){1, 1000}, in_v->time_base);
  av_seek_frame(ictx, v_idx, seek_t, AVSEEK_FLAG_BACKWARD);

  AVPacket* pkt = av_packet_alloc();
  AVFrame* frame = av_frame_alloc();
  AVPacket* enc_pkt = av_packet_alloc();
  AVFrame* sampled = av_frame_alloc();
  int64_t in_us = in_ms * 1000;
  int64_t out_us = out_ms * 1000;
  int64_t duration_ms = out_ms - in_ms;
  int64_t last_progress_ms = now_ms();
  int64_t start_wall = now_ms();
  int64_t enc_count = 0;

  while ((rc = av_read_frame(ictx, pkt)) >= 0) {
    if (cb && cb->cancel_flag) { rc = AVERROR_EXIT; break; }

    if (pkt->stream_index == v_idx) {
      rc = avcodec_send_packet(tv.dec, pkt);
      while (rc >= 0) {
        rc = avcodec_receive_frame(tv.dec, frame);
        if (rc == AVERROR(EAGAIN) || rc == AVERROR_EOF) break;
        if (rc < 0) goto loop_done;
        int64_t pts_us = av_rescale_q(frame->pts, in_v->time_base, AV_TIME_BASE_Q);
        if (pts_us < in_us) { av_frame_unref(frame); continue; }
        if (pts_us >= out_us) { rc = AVERROR_EOF; goto loop_done; }

        frame->pts = tv.next_pts++;
        rc = avcodec_send_frame(tv.enc, frame);
        av_frame_unref(frame);
        while (rc >= 0) {
          rc = avcodec_receive_packet(tv.enc, enc_pkt);
          if (rc == AVERROR(EAGAIN) || rc == AVERROR_EOF) break;
          if (rc < 0) goto loop_done;
          av_packet_rescale_ts(enc_pkt, tv.enc->time_base, tv.out_stream->time_base);
          enc_pkt->stream_index = tv.out_stream->index;
          av_interleaved_write_frame(octx, enc_pkt);
          av_packet_unref(enc_pkt);
          enc_count++;
        }

        int64_t now = now_ms();
        if (now - last_progress_ms > 250) {
          int64_t cur_ms = pts_us / 1000;
          double pct = duration_ms > 0 ? (double)(cur_ms - in_ms) / duration_ms : 0.0;
          double elapsed = (double)(now - start_wall) / 1000.0;
          double fps = elapsed > 0 ? (double)enc_count / elapsed : 0.0;
          double eta = pct > 0 ? elapsed * (1.0 - pct) / pct : 0.0;
          emit(cb, pct, fps, eta);
          last_progress_ms = now;
        }
      }
    } else if (has_audio && pkt->stream_index == a_idx) {
      AVStream* in_a = ictx->streams[a_idx];
      int64_t pts_us = av_rescale_q(pkt->pts, in_a->time_base, AV_TIME_BASE_Q);
      if (pts_us >= in_us && pts_us < out_us) {
        rc = avcodec_send_packet(ta.dec, pkt);
        while (rc >= 0) {
          rc = avcodec_receive_frame(ta.dec, frame);
          if (rc == AVERROR(EAGAIN) || rc == AVERROR_EOF) break;
          if (rc < 0) goto loop_done;
          sampled->format = ta.enc->sample_fmt;
          sampled->sample_rate = ta.enc->sample_rate;
          av_channel_layout_copy(&sampled->ch_layout, &ta.enc->ch_layout);
          sampled->nb_samples = frame->nb_samples;
          av_frame_get_buffer(sampled, 0);
          swr_convert(ta.swr, sampled->data, sampled->nb_samples,
                      (const uint8_t**)frame->data, frame->nb_samples);
          sampled->pts = ta.next_pts;
          ta.next_pts += sampled->nb_samples;
          rc = avcodec_send_frame(ta.enc, sampled);
          av_frame_unref(frame);
          av_frame_unref(sampled);
          while (rc >= 0) {
            rc = avcodec_receive_packet(ta.enc, enc_pkt);
            if (rc == AVERROR(EAGAIN) || rc == AVERROR_EOF) break;
            if (rc < 0) goto loop_done;
            av_packet_rescale_ts(enc_pkt, ta.enc->time_base, ta.out_stream->time_base);
            enc_pkt->stream_index = ta.out_stream->index;
            av_interleaved_write_frame(octx, enc_pkt);
            av_packet_unref(enc_pkt);
          }
        }
      }
    }
    av_packet_unref(pkt);
  }
loop_done:
  av_packet_unref(pkt);
  av_packet_free(&pkt);
  av_frame_free(&frame);
  av_frame_free(&sampled);
  av_packet_free(&enc_pkt);

  flush_encoder(tv.enc, octx, tv.out_stream);
  if (has_audio) flush_encoder(ta.enc, octx, ta.out_stream);
  av_write_trailer(octx);
  emit(cb, 1.0, 0.0, 0.0);
  rc = 0;

cleanup:
  if (tv.dec) avcodec_free_context(&tv.dec);
  if (tv.enc) avcodec_free_context(&tv.enc);
  if (ta.dec) avcodec_free_context(&ta.dec);
  if (ta.enc) avcodec_free_context(&ta.enc);
  if (ta.swr) swr_free(&ta.swr);
  return rc;
}

// ──────────────────────────────────────────────────────────────────
// Public entry point
// ──────────────────────────────────────────────────────────────────

int ff_trim_run(const char* in_path, const char* out_path,
                int64_t in_ms, int64_t out_ms, int reencode,
                ff_progress_cb_t* cb) {
  if (!in_path || !out_path || out_ms <= in_ms) return -1;

  AVFormatContext* ictx = NULL;
  int v_idx = -1, a_idx = -1;
  int rc = open_input(in_path, &ictx, &v_idx, &a_idx);
  if (rc < 0) {
    FF_LOGE("ff_trim_run: open '%s' rc=%d", in_path, rc);
    return rc;
  }

  if (reencode) {
    // Build a fresh muxer for the transcode path. It does its own
    // header/trailer + stream allocation inside trim_transcode.
    AVFormatContext* octx = NULL;
    rc = avformat_alloc_output_context2(&octx, NULL, NULL, out_path);
    if (rc < 0 || !octx) { avformat_close_input(&ictx); return rc < 0 ? rc : -1; }
    octx->url = av_strdup(out_path);
    rc = trim_transcode(ictx, octx, v_idx, a_idx, in_ms, out_ms, cb);
    if (octx->pb && !(octx->oformat->flags & AVFMT_NOFILE)) avio_closep(&octx->pb);
    avformat_free_context(octx);
    avformat_close_input(&ictx);
    return rc < 0 && rc != AVERROR_EOF ? rc : 0;
  }

  // Lossless stream-copy path.
  AVFormatContext* octx = NULL;
  rc = avformat_alloc_output_context2(&octx, NULL, NULL, out_path);
  if (rc < 0 || !octx) { avformat_close_input(&ictx); return rc < 0 ? rc : -1; }

  AVDictionary* mux_opts = NULL;
  av_dict_set(&mux_opts, "movflags", "+faststart", 0);
  int o_v = -1, o_a = -1;
  rc = copy_stream(octx, ictx->streams[v_idx], &o_v);
  if (rc < 0) goto fail;
  if (a_idx >= 0) {
    rc = copy_stream(octx, ictx->streams[a_idx], &o_a);
    if (rc < 0) goto fail;
  }

  if (!(octx->oformat->flags & AVFMT_NOFILE)) {
    rc = avio_open(&octx->pb, out_path, AVIO_FLAG_WRITE);
    if (rc < 0) goto fail;
  }
  rc = avformat_write_header(octx, &mux_opts);
  if (rc < 0) goto fail;

  rc = trim_streamcopy(ictx, octx, v_idx, a_idx, o_v, o_a, in_ms, out_ms, cb);
  if (rc == 0) {
    av_write_trailer(octx);
    emit(cb, 1.0, 0.0, 0.0);
  }

fail:
  if (octx) {
    if (octx->pb && !(octx->oformat->flags & AVFMT_NOFILE)) avio_closep(&octx->pb);
    avformat_free_context(octx);
  }
  if (mux_opts) av_dict_free(&mux_opts);
  if (ictx) avformat_close_input(&ictx);
  return rc < 0 && rc != AVERROR_EOF ? rc : 0;
}
