// N-clip concat with codec-mismatch fallback.
//
// Fast path: when every input shares codec_id + resolution + sample-rate +
// channels, use FFmpeg's `concat` demuxer with `-c copy` semantics — pure
// stream-copy, no re-encode.
//
// Slow path: when any input differs, transcode every input to a common
// profile (H.264 1080p 30fps + AAC 48 kHz stereo) and write the encoded
// packets into one output mp4. Equivalent to ffmpeg's `concat` filter but
// kept in-process so we never spawn an external binary.

#include "ff_common.h"
#include "ff_session.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/types.h>

#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/avutil.h>
#include <libavutil/opt.h>
#include <libavutil/channel_layout.h>
#include <libavutil/imgutils.h>
#include <libswscale/swscale.h>
#include <libswresample/swresample.h>

static int probe_codec_config(const char* path, char* codec, size_t codec_sz,
                              int* w, int* h, int* sample_rate, int* channels) {
  AVFormatContext* ctx = NULL;
  int rc = avformat_open_input(&ctx, path, NULL, NULL);
  if (rc < 0) return rc;
  rc = avformat_find_stream_info(ctx, NULL);
  if (rc < 0) { avformat_close_input(&ctx); return rc; }
  codec[0] = 0;
  *w = *h = *sample_rate = *channels = 0;
  for (unsigned i = 0; i < ctx->nb_streams; i++) {
    AVCodecParameters* cp = ctx->streams[i]->codecpar;
    if (cp->codec_type == AVMEDIA_TYPE_VIDEO && codec[0] == 0) {
      const char* n = avcodec_get_name(cp->codec_id);
      strncpy(codec, n ? n : "", codec_sz - 1);
      *w = cp->width; *h = cp->height;
    } else if (cp->codec_type == AVMEDIA_TYPE_AUDIO && *sample_rate == 0) {
      *sample_rate = cp->sample_rate;
      *channels = cp->ch_layout.nb_channels > 0
          ? cp->ch_layout.nb_channels
          : cp->channels;
    }
  }
  avformat_close_input(&ctx);
  return 0;
}

static int all_match(const char* const* paths, int n) {
  if (n <= 1) return 1;
  char a_codec[32];
  int a_w, a_h, a_sr, a_ch;
  if (probe_codec_config(paths[0], a_codec, sizeof(a_codec), &a_w, &a_h, &a_sr, &a_ch) < 0) {
    return 0;
  }
  for (int i = 1; i < n; i++) {
    char codec[32]; int w, h, sr, ch;
    if (probe_codec_config(paths[i], codec, sizeof(codec), &w, &h, &sr, &ch) < 0) return 0;
    if (strcmp(codec, a_codec) || w != a_w || h != a_h || sr != a_sr || ch != a_ch) {
      return 0;
    }
  }
  return 1;
}

static int write_concat_listfile(const char* const* paths, int n,
                                 char* out_path, size_t out_sz) {
  snprintf(out_path, out_sz, "/tmp/minis_concat_%ld.txt", (long)getpid());
  FILE* f = fopen(out_path, "w");
  if (!f) return -1;
  for (int i = 0; i < n; i++) {
    fprintf(f, "file '%s'\n", paths[i]);
  }
  fclose(f);
  return 0;
}

static void emit(ff_progress_cb_t* cb, double pct) {
  if (cb && cb->emit) cb->emit(cb->user, "", "concat", pct, 0.0, 0.0);
}

// ──────────────────────────────────────────────────────────────────
// Fast path: concat demuxer + stream-copy.
// ──────────────────────────────────────────────────────────────────

static int concat_streamcopy(const char* const* in_paths, int n_paths,
                             const char* out_path, int keep_audio,
                             ff_progress_cb_t* cb) {
  char listfile[256];
  if (write_concat_listfile(in_paths, n_paths, listfile, sizeof(listfile)) < 0) {
    return -1;
  }

  AVFormatContext* ictx = NULL;
  const AVInputFormat* concat_fmt = av_find_input_format("concat");
  AVDictionary* opts = NULL;
  av_dict_set(&opts, "safe", "0", 0);
  int rc = avformat_open_input(&ictx, listfile, concat_fmt, &opts);
  av_dict_free(&opts);
  if (rc < 0) { remove(listfile); return rc; }
  rc = avformat_find_stream_info(ictx, NULL);
  if (rc < 0) { avformat_close_input(&ictx); remove(listfile); return rc; }

  AVFormatContext* octx = NULL;
  rc = avformat_alloc_output_context2(&octx, NULL, NULL, out_path);
  if (rc < 0 || !octx) { avformat_close_input(&ictx); remove(listfile); return rc < 0 ? rc : -1; }

  int* index_map = (int*)calloc((size_t)ictx->nb_streams, sizeof(int));
  for (unsigned i = 0; i < ictx->nb_streams; i++) {
    AVStream* in_s = ictx->streams[i];
    if (in_s->codecpar->codec_type == AVMEDIA_TYPE_AUDIO && !keep_audio) {
      index_map[i] = -1; continue;
    }
    AVStream* os = avformat_new_stream(octx, NULL);
    if (!os) { rc = AVERROR(ENOMEM); goto done; }
    rc = avcodec_parameters_copy(os->codecpar, in_s->codecpar);
    if (rc < 0) goto done;
    os->codecpar->codec_tag = 0;
    os->time_base = in_s->time_base;
    index_map[i] = os->index;
  }

  AVDictionary* mux_opts = NULL;
  av_dict_set(&mux_opts, "movflags", "+faststart", 0);
  if (!(octx->oformat->flags & AVFMT_NOFILE)) {
    rc = avio_open(&octx->pb, out_path, AVIO_FLAG_WRITE);
    if (rc < 0) goto done;
  }
  rc = avformat_write_header(octx, &mux_opts);
  if (rc < 0) goto done;

  AVPacket* pkt = av_packet_alloc();
  int64_t total_duration = ictx->duration > 0 ? ictx->duration : 0;
  int64_t last_pct_mark = 0;
  while ((rc = av_read_frame(ictx, pkt)) >= 0) {
    if (cb && cb->cancel_flag) { rc = AVERROR_EXIT; break; }
    if (pkt->stream_index >= (int)ictx->nb_streams || index_map[pkt->stream_index] < 0) {
      av_packet_unref(pkt); continue;
    }
    int out_idx = index_map[pkt->stream_index];
    AVStream* in_s = ictx->streams[pkt->stream_index];
    AVStream* out_s = octx->streams[out_idx];
    av_packet_rescale_ts(pkt, in_s->time_base, out_s->time_base);
    pkt->stream_index = out_idx;
    pkt->pos = -1;
    int wrc = av_interleaved_write_frame(octx, pkt);
    av_packet_unref(pkt);
    if (wrc < 0) { rc = wrc; break; }

    if (total_duration > 0) {
      int64_t pts_us = av_rescale_q(pkt->pts, out_s->time_base, AV_TIME_BASE_Q);
      int64_t pct100 = pts_us * 100 / total_duration;
      if (pct100 != last_pct_mark) {
        last_pct_mark = pct100;
        emit(cb, (double)pct100 / 100.0);
      }
    }
  }
  av_packet_free(&pkt);
  if (rc >= 0 || rc == AVERROR_EOF) {
    rc = av_write_trailer(octx);
    emit(cb, 1.0);
  }
  if (mux_opts) av_dict_free(&mux_opts);

done:
  free(index_map);
  if (octx) {
    if (octx->pb && !(octx->oformat->flags & AVFMT_NOFILE)) avio_closep(&octx->pb);
    avformat_free_context(octx);
  }
  if (ictx) avformat_close_input(&ictx);
  remove(listfile);
  return rc < 0 && rc != AVERROR_EOF ? rc : 0;
}

// ──────────────────────────────────────────────────────────────────
// Slow path: transcode every input to a common H.264/AAC profile and
// concatenate the encoded packets in one writer.
// ──────────────────────────────────────────────────────────────────

typedef struct cc_video {
  AVCodecContext* enc;
  AVStream* out_stream;
  int64_t pts;            // monotonic across inputs
} cc_video_t;

typedef struct cc_audio {
  AVCodecContext* enc;
  AVStream* out_stream;
  int64_t pts;
} cc_audio_t;

static int open_v_encoder(AVFormatContext* octx, int width, int height, int fps,
                          cc_video_t* cv) {
  const AVCodec* enc = avcodec_find_encoder_by_name("h264_mediacodec");
  if (!enc) enc = avcodec_find_encoder_by_name("h264_videotoolbox");
  if (!enc) enc = avcodec_find_encoder_by_name("libx264");
  if (!enc) return AVERROR_ENCODER_NOT_FOUND;
  cv->enc = avcodec_alloc_context3(enc);
  cv->enc->width = width;
  cv->enc->height = height;
  cv->enc->pix_fmt = AV_PIX_FMT_YUV420P;
  cv->enc->time_base = (AVRational){1, fps};
  cv->enc->framerate = (AVRational){fps, 1};
  cv->enc->bit_rate = 6 * 1000 * 1000;
  cv->enc->gop_size = fps * 2;
  if (octx->oformat->flags & AVFMT_GLOBALHEADER) {
    cv->enc->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
  }
  int rc = avcodec_open2(cv->enc, enc, NULL);
  if (rc < 0) return rc;
  AVStream* os = avformat_new_stream(octx, NULL);
  avcodec_parameters_from_context(os->codecpar, cv->enc);
  os->time_base = cv->enc->time_base;
  cv->out_stream = os;
  return 0;
}

static int open_a_encoder(AVFormatContext* octx, cc_audio_t* ca) {
  const AVCodec* enc = avcodec_find_encoder(AV_CODEC_ID_AAC);
  if (!enc) return AVERROR_ENCODER_NOT_FOUND;
  ca->enc = avcodec_alloc_context3(enc);
  ca->enc->sample_rate = 48000;
  av_channel_layout_default(&ca->enc->ch_layout, 2);
  ca->enc->sample_fmt = enc->sample_fmts ? enc->sample_fmts[0] : AV_SAMPLE_FMT_FLTP;
  ca->enc->bit_rate = 192000;
  ca->enc->time_base = (AVRational){1, ca->enc->sample_rate};
  if (octx->oformat->flags & AVFMT_GLOBALHEADER) {
    ca->enc->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
  }
  int rc = avcodec_open2(ca->enc, enc, NULL);
  if (rc < 0) return rc;
  AVStream* os = avformat_new_stream(octx, NULL);
  avcodec_parameters_from_context(os->codecpar, ca->enc);
  os->time_base = ca->enc->time_base;
  ca->out_stream = os;
  return 0;
}

static int transcode_one_input(const char* path, AVFormatContext* octx,
                               cc_video_t* cv, cc_audio_t* ca, int keep_audio,
                               ff_progress_cb_t* cb, double base_pct, double slice_pct) {
  AVFormatContext* ictx = NULL;
  int rc = avformat_open_input(&ictx, path, NULL, NULL);
  if (rc < 0) return rc;
  rc = avformat_find_stream_info(ictx, NULL);
  if (rc < 0) { avformat_close_input(&ictx); return rc; }

  int v_idx = -1, a_idx = -1;
  for (unsigned i = 0; i < ictx->nb_streams; i++) {
    AVMediaType t = ictx->streams[i]->codecpar->codec_type;
    if (t == AVMEDIA_TYPE_VIDEO && v_idx < 0) v_idx = (int)i;
    else if (t == AVMEDIA_TYPE_AUDIO && a_idx < 0) a_idx = (int)i;
  }
  if (v_idx < 0) { avformat_close_input(&ictx); return AVERROR_STREAM_NOT_FOUND; }

  AVStream* in_v = ictx->streams[v_idx];
  AVCodecParameters* in_vp = in_v->codecpar;
  const AVCodec* v_dec = avcodec_find_decoder(in_vp->codec_id);
  AVCodecContext* v_dc = avcodec_alloc_context3(v_dec);
  avcodec_parameters_to_context(v_dc, in_vp);
  v_dc->pkt_timebase = in_v->time_base;
  rc = avcodec_open2(v_dc, v_dec, NULL);
  if (rc < 0) { avformat_close_input(&ictx); avcodec_free_context(&v_dc); return rc; }

  AVCodecContext* a_dc = NULL;
  SwrContext* swr = NULL;
  if (keep_audio && a_idx >= 0 && ca) {
    AVCodecParameters* ap = ictx->streams[a_idx]->codecpar;
    const AVCodec* a_dec = avcodec_find_decoder(ap->codec_id);
    if (a_dec) {
      a_dc = avcodec_alloc_context3(a_dec);
      avcodec_parameters_to_context(a_dc, ap);
      a_dc->pkt_timebase = ictx->streams[a_idx]->time_base;
      avcodec_open2(a_dc, a_dec, NULL);
      swr_alloc_set_opts2(&swr,
                         &ca->enc->ch_layout, ca->enc->sample_fmt, ca->enc->sample_rate,
                         &a_dc->ch_layout, a_dc->sample_fmt, a_dc->sample_rate,
                         0, NULL);
      swr_init(swr);
    }
  }

  struct SwsContext* sws = sws_getContext(
      v_dc->width, v_dc->height, v_dc->pix_fmt,
      cv->enc->width, cv->enc->height, cv->enc->pix_fmt,
      SWS_BILINEAR, NULL, NULL, NULL);

  AVPacket* pkt = av_packet_alloc();
  AVFrame* frame = av_frame_alloc();
  AVFrame* scaled = av_frame_alloc();
  scaled->format = cv->enc->pix_fmt;
  scaled->width = cv->enc->width;
  scaled->height = cv->enc->height;
  av_frame_get_buffer(scaled, 32);
  AVFrame* a_resampled = av_frame_alloc();
  AVPacket* enc_pkt = av_packet_alloc();

  int64_t total_us = ictx->duration > 0 ? ictx->duration : 1;

  while ((rc = av_read_frame(ictx, pkt)) >= 0) {
    if (cb && cb->cancel_flag) { rc = AVERROR_EXIT; break; }

    if (pkt->stream_index == v_idx) {
      rc = avcodec_send_packet(v_dc, pkt);
      while (rc >= 0) {
        rc = avcodec_receive_frame(v_dc, frame);
        if (rc == AVERROR(EAGAIN) || rc == AVERROR_EOF) break;
        if (rc < 0) goto cleanup;
        sws_scale(sws, (const uint8_t* const*)frame->data, frame->linesize,
                  0, v_dc->height, scaled->data, scaled->linesize);
        scaled->pts = cv->pts++;
        rc = avcodec_send_frame(cv->enc, scaled);
        av_frame_unref(frame);
        while (rc >= 0) {
          rc = avcodec_receive_packet(cv->enc, enc_pkt);
          if (rc == AVERROR(EAGAIN) || rc == AVERROR_EOF) break;
          if (rc < 0) goto cleanup;
          av_packet_rescale_ts(enc_pkt, cv->enc->time_base, cv->out_stream->time_base);
          enc_pkt->stream_index = cv->out_stream->index;
          av_interleaved_write_frame(octx, enc_pkt);
          av_packet_unref(enc_pkt);
        }
        int64_t pts_us = av_rescale_q(frame->pts, in_v->time_base, AV_TIME_BASE_Q);
        double clip_pct = (double)pts_us / (double)total_us;
        emit(cb, base_pct + slice_pct * clip_pct);
      }
    } else if (a_dc && pkt->stream_index == a_idx) {
      rc = avcodec_send_packet(a_dc, pkt);
      while (rc >= 0) {
        rc = avcodec_receive_frame(a_dc, frame);
        if (rc == AVERROR(EAGAIN) || rc == AVERROR_EOF) break;
        if (rc < 0) goto cleanup;
        a_resampled->format = ca->enc->sample_fmt;
        a_resampled->sample_rate = ca->enc->sample_rate;
        av_channel_layout_copy(&a_resampled->ch_layout, &ca->enc->ch_layout);
        a_resampled->nb_samples = frame->nb_samples;
        av_frame_get_buffer(a_resampled, 0);
        swr_convert(swr, a_resampled->data, a_resampled->nb_samples,
                    (const uint8_t**)frame->data, frame->nb_samples);
        a_resampled->pts = ca->pts;
        ca->pts += a_resampled->nb_samples;
        rc = avcodec_send_frame(ca->enc, a_resampled);
        av_frame_unref(frame);
        av_frame_unref(a_resampled);
        while (rc >= 0) {
          rc = avcodec_receive_packet(ca->enc, enc_pkt);
          if (rc == AVERROR(EAGAIN) || rc == AVERROR_EOF) break;
          if (rc < 0) goto cleanup;
          av_packet_rescale_ts(enc_pkt, ca->enc->time_base, ca->out_stream->time_base);
          enc_pkt->stream_index = ca->out_stream->index;
          av_interleaved_write_frame(octx, enc_pkt);
          av_packet_unref(enc_pkt);
        }
      }
    }
    av_packet_unref(pkt);
  }
cleanup:
  if (sws) sws_freeContext(sws);
  if (swr) swr_free(&swr);
  if (a_dc) avcodec_free_context(&a_dc);
  avcodec_free_context(&v_dc);
  av_packet_free(&pkt);
  av_packet_free(&enc_pkt);
  av_frame_free(&frame);
  av_frame_free(&scaled);
  av_frame_free(&a_resampled);
  avformat_close_input(&ictx);
  return rc < 0 && rc != AVERROR_EOF ? rc : 0;
}

static int concat_transcode(const char* const* in_paths, int n_paths,
                            const char* out_path, int keep_audio,
                            ff_progress_cb_t* cb) {
  // Use the first clip's resolution / sample-rate as the common profile.
  char codec0[32]; int w0, h0, sr0, ch0;
  if (probe_codec_config(in_paths[0], codec0, sizeof(codec0), &w0, &h0, &sr0, &ch0) < 0) {
    return -1;
  }
  if (w0 <= 0 || h0 <= 0) { w0 = 1080; h0 = 1920; }

  AVFormatContext* octx = NULL;
  int rc = avformat_alloc_output_context2(&octx, NULL, "mp4", out_path);
  if (rc < 0 || !octx) return rc < 0 ? rc : -1;

  cc_video_t cv = {0};
  cc_audio_t ca = {0};
  rc = open_v_encoder(octx, w0, h0, 30, &cv);
  if (rc < 0) goto cleanup;
  if (keep_audio) {
    rc = open_a_encoder(octx, &ca);
    if (rc < 0) keep_audio = 0;
  }

  AVDictionary* mux_opts = NULL;
  av_dict_set(&mux_opts, "movflags", "+faststart", 0);
  if (!(octx->oformat->flags & AVFMT_NOFILE)) {
    rc = avio_open(&octx->pb, out_path, AVIO_FLAG_WRITE);
    if (rc < 0) { av_dict_free(&mux_opts); goto cleanup; }
  }
  rc = avformat_write_header(octx, &mux_opts);
  av_dict_free(&mux_opts);
  if (rc < 0) goto cleanup;

  double slice = 1.0 / (double)n_paths;
  for (int i = 0; i < n_paths; i++) {
    rc = transcode_one_input(in_paths[i], octx, &cv, keep_audio ? &ca : NULL,
                             keep_audio, cb, slice * i, slice);
    if (rc < 0) goto cleanup;
  }

  // Flush encoders.
  AVPacket* enc_pkt = av_packet_alloc();
  avcodec_send_frame(cv.enc, NULL);
  while (avcodec_receive_packet(cv.enc, enc_pkt) == 0) {
    av_packet_rescale_ts(enc_pkt, cv.enc->time_base, cv.out_stream->time_base);
    enc_pkt->stream_index = cv.out_stream->index;
    av_interleaved_write_frame(octx, enc_pkt);
    av_packet_unref(enc_pkt);
  }
  if (keep_audio) {
    avcodec_send_frame(ca.enc, NULL);
    while (avcodec_receive_packet(ca.enc, enc_pkt) == 0) {
      av_packet_rescale_ts(enc_pkt, ca.enc->time_base, ca.out_stream->time_base);
      enc_pkt->stream_index = ca.out_stream->index;
      av_interleaved_write_frame(octx, enc_pkt);
      av_packet_unref(enc_pkt);
    }
  }
  av_packet_free(&enc_pkt);

  av_write_trailer(octx);
  emit(cb, 1.0);

cleanup:
  if (cv.enc) avcodec_free_context(&cv.enc);
  if (ca.enc) avcodec_free_context(&ca.enc);
  if (octx) {
    if (octx->pb && !(octx->oformat->flags & AVFMT_NOFILE)) avio_closep(&octx->pb);
    avformat_free_context(octx);
  }
  return rc < 0 && rc != AVERROR_EOF ? rc : 0;
}

// ──────────────────────────────────────────────────────────────────
// Public entry point
// ──────────────────────────────────────────────────────────────────

int ff_concat_run(const char* const* in_paths, int n_paths,
                  const char* out_path, double speed, int keep_audio,
                  const char* music_path, int64_t music_in_ms, int64_t music_out_ms,
                  int keep_music_tempo,
                  ff_progress_cb_t* cb) {
  if (n_paths <= 0 || !in_paths || !out_path) return -1;
  (void)speed; (void)music_path; (void)music_in_ms; (void)music_out_ms;
  (void)keep_music_tempo;

  if (all_match(in_paths, n_paths)) {
    return concat_streamcopy(in_paths, n_paths, out_path, keep_audio, cb);
  }
  FF_LOGI("ff_concat_run: codec mismatch — transcoding %d inputs to common profile", n_paths);
  return concat_transcode(in_paths, n_paths, out_path, keep_audio, cb);
}
