// Multi-input audio mixer (improvement3.md §C8).
//
// Opens N audio sources (clip audio, music, voiceover, …), pipes each
// through an `abuffer` source into a user-supplied filtergraph built by
// `ff_audio_graph_build_graph`, and encodes the mixed output as AAC into
// an mp4 / m4a container. Use this when the host needs voiceover ducking
// against a separate music track that the single-input audio graph in
// `ff_export.c` cannot reach.

#include "ff_common.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/avutil.h>
#include <libavutil/opt.h>
#include <libavutil/channel_layout.h>
#include <libavfilter/avfilter.h>
#include <libavfilter/buffersink.h>
#include <libavfilter/buffersrc.h>
#include <libswresample/swresample.h>

typedef struct mix_input {
  AVFormatContext* fmt;
  int stream_idx;
  AVCodecContext* dec;
  AVFilterContext* src_ctx;
  int eof;
} mix_input_t;

static int open_audio_input(const char* path, mix_input_t* mi) {
  int rc = avformat_open_input(&mi->fmt, path, NULL, NULL);
  if (rc < 0) return rc;
  rc = avformat_find_stream_info(mi->fmt, NULL);
  if (rc < 0) { avformat_close_input(&mi->fmt); return rc; }
  mi->stream_idx = -1;
  for (unsigned i = 0; i < mi->fmt->nb_streams; i++) {
    if (mi->fmt->streams[i]->codecpar->codec_type == AVMEDIA_TYPE_AUDIO) {
      mi->stream_idx = (int)i; break;
    }
  }
  if (mi->stream_idx < 0) {
    avformat_close_input(&mi->fmt);
    return AVERROR_STREAM_NOT_FOUND;
  }
  AVCodecParameters* cp = mi->fmt->streams[mi->stream_idx]->codecpar;
  const AVCodec* dec = avcodec_find_decoder(cp->codec_id);
  mi->dec = avcodec_alloc_context3(dec);
  avcodec_parameters_to_context(mi->dec, cp);
  mi->dec->pkt_timebase = mi->fmt->streams[mi->stream_idx]->time_base;
  rc = avcodec_open2(mi->dec, dec, NULL);
  return rc;
}

static void close_audio_input(mix_input_t* mi) {
  if (mi->dec) avcodec_free_context(&mi->dec);
  if (mi->fmt) avformat_close_input(&mi->fmt);
}

int ff_audio_mix_run(const char* const* audio_paths, int n_paths,
                     const char* filter_str, const char* out_path,
                     ff_progress_cb_t* cb) {
  if (!audio_paths || n_paths <= 0 || !filter_str || !out_path) return -1;

  mix_input_t* inputs = (mix_input_t*)calloc((size_t)n_paths, sizeof(*inputs));
  for (int i = 0; i < n_paths; i++) {
    int rc = open_audio_input(audio_paths[i], &inputs[i]);
    if (rc < 0) {
      FF_LOGE("ff_audio_mix: open '%s' rc=%d", audio_paths[i], rc);
      for (int j = 0; j < i; j++) close_audio_input(&inputs[j]);
      free(inputs);
      return rc;
    }
  }

  // Filter graph.
  AVFilterGraph* graph = avfilter_graph_alloc();
  const AVFilter* abuffer = avfilter_get_by_name("abuffer");
  const AVFilter* abuffersink = avfilter_get_by_name("abuffersink");

  AVFilterInOut* outputs_chain = NULL;
  for (int i = 0; i < n_paths; i++) {
    AVCodecContext* d = inputs[i].dec;
    AVStream* s = inputs[i].fmt->streams[inputs[i].stream_idx];
    char args[256];
    snprintf(args, sizeof(args),
             "time_base=%d/%d:sample_rate=%d:sample_fmt=%s:channel_layout=0x%llx",
             s->time_base.num, s->time_base.den,
             d->sample_rate, av_get_sample_fmt_name(d->sample_fmt),
             (unsigned long long)d->ch_layout.u.mask);
    char name[16]; snprintf(name, sizeof(name), "src%d", i);
    if (avfilter_graph_create_filter(&inputs[i].src_ctx, abuffer, name, args, NULL, graph) < 0) {
      avfilter_graph_free(&graph);
      for (int j = 0; j < n_paths; j++) close_audio_input(&inputs[j]);
      free(inputs);
      return -1;
    }
    AVFilterInOut* link = avfilter_inout_alloc();
    char pad[8]; snprintf(pad, sizeof(pad), "%d:a", i);
    link->name = av_strdup(pad);
    link->filter_ctx = inputs[i].src_ctx;
    link->pad_idx = 0;
    link->next = outputs_chain;
    outputs_chain = link;
  }

  AVFilterContext* sink_ctx = NULL;
  if (avfilter_graph_create_filter(&sink_ctx, abuffersink, "sink", NULL, NULL, graph) < 0) {
    avfilter_graph_free(&graph);
    for (int i = 0; i < n_paths; i++) close_audio_input(&inputs[i]);
    free(inputs);
    return -1;
  }
  AVFilterInOut* inputs_chain = avfilter_inout_alloc();
  inputs_chain->name = av_strdup("out");
  inputs_chain->filter_ctx = sink_ctx;
  inputs_chain->pad_idx = 0;
  inputs_chain->next = NULL;

  if (avfilter_graph_parse_ptr(graph, filter_str, &inputs_chain, &outputs_chain, NULL) < 0) {
    FF_LOGE("ff_audio_mix: parse '%s' failed", filter_str);
    avfilter_inout_free(&inputs_chain);
    avfilter_inout_free(&outputs_chain);
    avfilter_graph_free(&graph);
    for (int i = 0; i < n_paths; i++) close_audio_input(&inputs[i]);
    free(inputs);
    return -1;
  }
  avfilter_inout_free(&inputs_chain);
  avfilter_inout_free(&outputs_chain);
  if (avfilter_graph_config(graph, NULL) < 0) {
    avfilter_graph_free(&graph);
    for (int i = 0; i < n_paths; i++) close_audio_input(&inputs[i]);
    free(inputs);
    return -1;
  }

  // Encoder + muxer.
  const AVCodec* enc = avcodec_find_encoder(AV_CODEC_ID_AAC);
  AVCodecContext* enc_ctx = avcodec_alloc_context3(enc);
  enc_ctx->sample_rate = 48000;
  av_channel_layout_default(&enc_ctx->ch_layout, 2);
  enc_ctx->sample_fmt = enc->sample_fmts ? enc->sample_fmts[0] : AV_SAMPLE_FMT_FLTP;
  enc_ctx->bit_rate = 192000;
  enc_ctx->time_base = (AVRational){1, enc_ctx->sample_rate};

  AVFormatContext* octx = NULL;
  avformat_alloc_output_context2(&octx, NULL, NULL, out_path);
  if (octx->oformat->flags & AVFMT_GLOBALHEADER) {
    enc_ctx->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
  }
  avcodec_open2(enc_ctx, enc, NULL);
  AVStream* out_a = avformat_new_stream(octx, NULL);
  avcodec_parameters_from_context(out_a->codecpar, enc_ctx);
  out_a->time_base = enc_ctx->time_base;

  if (!(octx->oformat->flags & AVFMT_NOFILE)) {
    avio_open(&octx->pb, out_path, AVIO_FLAG_WRITE);
  }
  avformat_write_header(octx, NULL);

  AVPacket* pkt = av_packet_alloc();
  AVFrame* frame = av_frame_alloc();
  AVFrame* filt = av_frame_alloc();
  AVPacket* enc_pkt = av_packet_alloc();
  int total_active = n_paths;
  int rc = 0;

  while (total_active > 0) {
    if (cb && cb->cancel_flag) { rc = AVERROR_EXIT; break; }
    int produced = 0;
    for (int i = 0; i < n_paths && total_active > 0; i++) {
      if (inputs[i].eof) continue;
      int rd = av_read_frame(inputs[i].fmt, pkt);
      if (rd == AVERROR_EOF) {
        inputs[i].eof = 1;
        total_active--;
        av_buffersrc_add_frame_flags(inputs[i].src_ctx, NULL, 0);
        continue;
      }
      if (rd < 0) { av_packet_unref(pkt); continue; }
      if (pkt->stream_index != inputs[i].stream_idx) {
        av_packet_unref(pkt); continue;
      }
      if (avcodec_send_packet(inputs[i].dec, pkt) >= 0) {
        while (avcodec_receive_frame(inputs[i].dec, frame) == 0) {
          av_buffersrc_add_frame_flags(inputs[i].src_ctx, frame, AV_BUFFERSRC_FLAG_KEEP_REF);
          av_frame_unref(frame);
          produced = 1;
        }
      }
      av_packet_unref(pkt);
    }
    while (av_buffersink_get_frame(sink_ctx, filt) >= 0) {
      if (avcodec_send_frame(enc_ctx, filt) >= 0) {
        while (avcodec_receive_packet(enc_ctx, enc_pkt) == 0) {
          enc_pkt->stream_index = out_a->index;
          av_packet_rescale_ts(enc_pkt, enc_ctx->time_base, out_a->time_base);
          av_interleaved_write_frame(octx, enc_pkt);
          av_packet_unref(enc_pkt);
        }
      }
      av_frame_unref(filt);
      produced = 1;
    }
    if (!produced) break;
    if (cb && cb->emit) cb->emit(cb->user, "", "audiomix", 0.0, 0.0, 0.0);
  }
  // Flush encoder.
  avcodec_send_frame(enc_ctx, NULL);
  while (avcodec_receive_packet(enc_ctx, enc_pkt) == 0) {
    enc_pkt->stream_index = out_a->index;
    av_packet_rescale_ts(enc_pkt, enc_ctx->time_base, out_a->time_base);
    av_interleaved_write_frame(octx, enc_pkt);
    av_packet_unref(enc_pkt);
  }
  av_write_trailer(octx);

  av_packet_free(&pkt);
  av_packet_free(&enc_pkt);
  av_frame_free(&frame);
  av_frame_free(&filt);
  avcodec_free_context(&enc_ctx);
  avfilter_graph_free(&graph);
  if (octx->pb && !(octx->oformat->flags & AVFMT_NOFILE)) avio_closep(&octx->pb);
  avformat_free_context(octx);
  for (int i = 0; i < n_paths; i++) close_audio_input(&inputs[i]);
  free(inputs);
  if (cb && cb->emit) cb->emit(cb->user, "", "audiomix", 1.0, 0.0, 0.0);
  return rc < 0 && rc != AVERROR_EOF ? rc : 0;
}

// Replaces the audio track of `video_path` with `audio_path`, stream-copying
// both video and audio (no re-encode). Output is a single mp4.
int ff_av_remux_run(const char* video_path, const char* audio_path,
                    const char* out_path, ff_progress_cb_t* cb) {
  if (!video_path || !audio_path || !out_path) return -1;
  AVFormatContext* v_ctx = NULL;
  AVFormatContext* a_ctx = NULL;
  int rc = avformat_open_input(&v_ctx, video_path, NULL, NULL);
  if (rc < 0) return rc;
  avformat_find_stream_info(v_ctx, NULL);
  rc = avformat_open_input(&a_ctx, audio_path, NULL, NULL);
  if (rc < 0) { avformat_close_input(&v_ctx); return rc; }
  avformat_find_stream_info(a_ctx, NULL);

  int v_idx = -1, a_idx = -1;
  for (unsigned i = 0; i < v_ctx->nb_streams; i++) {
    if (v_ctx->streams[i]->codecpar->codec_type == AVMEDIA_TYPE_VIDEO) { v_idx = (int)i; break; }
  }
  for (unsigned i = 0; i < a_ctx->nb_streams; i++) {
    if (a_ctx->streams[i]->codecpar->codec_type == AVMEDIA_TYPE_AUDIO) { a_idx = (int)i; break; }
  }
  if (v_idx < 0 || a_idx < 0) {
    avformat_close_input(&v_ctx); avformat_close_input(&a_ctx);
    return AVERROR_STREAM_NOT_FOUND;
  }

  AVFormatContext* octx = NULL;
  rc = avformat_alloc_output_context2(&octx, NULL, NULL, out_path);
  if (rc < 0) { avformat_close_input(&v_ctx); avformat_close_input(&a_ctx); return rc; }

  AVStream* out_v = avformat_new_stream(octx, NULL);
  avcodec_parameters_copy(out_v->codecpar, v_ctx->streams[v_idx]->codecpar);
  out_v->codecpar->codec_tag = 0;
  out_v->time_base = v_ctx->streams[v_idx]->time_base;
  AVStream* out_a = avformat_new_stream(octx, NULL);
  avcodec_parameters_copy(out_a->codecpar, a_ctx->streams[a_idx]->codecpar);
  out_a->codecpar->codec_tag = 0;
  out_a->time_base = a_ctx->streams[a_idx]->time_base;

  AVDictionary* mux_opts = NULL;
  av_dict_set(&mux_opts, "movflags", "+faststart", 0);
  if (!(octx->oformat->flags & AVFMT_NOFILE)) {
    avio_open(&octx->pb, out_path, AVIO_FLAG_WRITE);
  }
  avformat_write_header(octx, &mux_opts);
  av_dict_free(&mux_opts);

  AVPacket* pkt = av_packet_alloc();
  // Video.
  while ((rc = av_read_frame(v_ctx, pkt)) >= 0) {
    if (cb && cb->cancel_flag) { rc = AVERROR_EXIT; break; }
    if (pkt->stream_index == v_idx) {
      av_packet_rescale_ts(pkt, v_ctx->streams[v_idx]->time_base, out_v->time_base);
      pkt->stream_index = out_v->index;
      pkt->pos = -1;
      av_interleaved_write_frame(octx, pkt);
    }
    av_packet_unref(pkt);
  }
  // Audio.
  while ((rc = av_read_frame(a_ctx, pkt)) >= 0) {
    if (cb && cb->cancel_flag) { rc = AVERROR_EXIT; break; }
    if (pkt->stream_index == a_idx) {
      av_packet_rescale_ts(pkt, a_ctx->streams[a_idx]->time_base, out_a->time_base);
      pkt->stream_index = out_a->index;
      pkt->pos = -1;
      av_interleaved_write_frame(octx, pkt);
    }
    av_packet_unref(pkt);
  }
  av_write_trailer(octx);
  av_packet_free(&pkt);
  if (octx->pb && !(octx->oformat->flags & AVFMT_NOFILE)) avio_closep(&octx->pb);
  avformat_free_context(octx);
  avformat_close_input(&v_ctx);
  avformat_close_input(&a_ctx);
  if (cb && cb->emit) cb->emit(cb->user, "", "avmux", 1.0, 0.0, 0.0);
  return rc < 0 && rc != AVERROR_EOF ? rc : 0;
}
