// Burns a .srt / .ass subtitle track into a video as part of the export
// pipeline (improvement3.md §C9). Called by `ff_export_run` when the
// options JSON contains `subtitlesPath`. The work is a straightforward
// decode → avfilter(`subtitles=PATH:force_style=...`) → encode loop.
//
// Returns 0 on success and writes to out_path; non-zero rc on failure.

#include "ff_common.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/avutil.h>
#include <libavutil/opt.h>
#include <libavutil/imgutils.h>
#include <libavfilter/avfilter.h>
#include <libavfilter/buffersink.h>
#include <libavfilter/buffersrc.h>

static int build_vf(AVFilterGraph** graph, AVFilterContext** src_ctx, AVFilterContext** sink_ctx,
                    AVCodecContext* dec, AVStream* in_v, const char* srt_path,
                    const char* style) {
  *graph = avfilter_graph_alloc();
  char args[512];
  snprintf(args, sizeof(args),
           "video_size=%dx%d:pix_fmt=%d:time_base=%d/%d:pixel_aspect=%d/%d",
           dec->width, dec->height, dec->pix_fmt,
           in_v->time_base.num, in_v->time_base.den,
           dec->sample_aspect_ratio.num, dec->sample_aspect_ratio.den);
  const AVFilter* bufsrc = avfilter_get_by_name("buffer");
  const AVFilter* bufsink = avfilter_get_by_name("buffersink");
  if (avfilter_graph_create_filter(src_ctx, bufsrc, "in", args, NULL, *graph) < 0) return -1;
  if (avfilter_graph_create_filter(sink_ctx, bufsink, "out", NULL, NULL, *graph) < 0) return -1;

  char filter_desc[1024];
  if (style && style[0]) {
    snprintf(filter_desc, sizeof(filter_desc), "subtitles='%s':force_style='%s'", srt_path, style);
  } else {
    snprintf(filter_desc, sizeof(filter_desc), "subtitles='%s'", srt_path);
  }

  AVFilterInOut* outputs = avfilter_inout_alloc();
  outputs->name = av_strdup("in");
  outputs->filter_ctx = *src_ctx;
  outputs->pad_idx = 0;
  outputs->next = NULL;
  AVFilterInOut* inputs = avfilter_inout_alloc();
  inputs->name = av_strdup("out");
  inputs->filter_ctx = *sink_ctx;
  inputs->pad_idx = 0;
  inputs->next = NULL;

  int rc = avfilter_graph_parse_ptr(*graph, filter_desc, &inputs, &outputs, NULL);
  avfilter_inout_free(&inputs);
  avfilter_inout_free(&outputs);
  if (rc < 0) return rc;
  return avfilter_graph_config(*graph, NULL);
}

int ff_subtitles_burn(const char* in_path, const char* out_path,
                      const char* srt_path, const char* style,
                      ff_progress_cb_t* cb) {
  if (!in_path || !out_path || !srt_path) return -1;

  AVFormatContext* ictx = NULL;
  int rc = avformat_open_input(&ictx, in_path, NULL, NULL);
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
  const AVCodec* v_dec = avcodec_find_decoder(in_v->codecpar->codec_id);
  AVCodecContext* dec_ctx = avcodec_alloc_context3(v_dec);
  avcodec_parameters_to_context(dec_ctx, in_v->codecpar);
  dec_ctx->pkt_timebase = in_v->time_base;
  rc = avcodec_open2(dec_ctx, v_dec, NULL);
  if (rc < 0) { avcodec_free_context(&dec_ctx); avformat_close_input(&ictx); return rc; }

  AVFilterGraph* graph = NULL;
  AVFilterContext* fsrc = NULL;
  AVFilterContext* fsink = NULL;
  rc = build_vf(&graph, &fsrc, &fsink, dec_ctx, in_v, srt_path, style);
  if (rc < 0) {
    avcodec_free_context(&dec_ctx);
    avformat_close_input(&ictx);
    return rc;
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

  // Stream-copy audio to keep voice perfectly in sync with the burned caption.
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

  AVPacket* pkt = av_packet_alloc();
  AVPacket* enc_pkt = av_packet_alloc();
  AVFrame* frame = av_frame_alloc();
  AVFrame* filt = av_frame_alloc();
  int64_t v_pts = 0;
  int64_t total_us = ictx->duration > 0 ? ictx->duration : 1;

  while ((rc = av_read_frame(ictx, pkt)) >= 0) {
    if (cb && cb->cancel_flag) { rc = AVERROR_EXIT; break; }
    if (pkt->stream_index == v_idx) {
      if (avcodec_send_packet(dec_ctx, pkt) >= 0) {
        while (avcodec_receive_frame(dec_ctx, frame) == 0) {
          if (av_buffersrc_add_frame_flags(fsrc, frame, 0) >= 0) {
            while (av_buffersink_get_frame(fsink, filt) >= 0) {
              filt->pts = v_pts++;
              if (avcodec_send_frame(enc_ctx, filt) >= 0) {
                while (avcodec_receive_packet(enc_ctx, enc_pkt) == 0) {
                  enc_pkt->stream_index = out_v->index;
                  av_packet_rescale_ts(enc_pkt, enc_ctx->time_base, out_v->time_base);
                  av_interleaved_write_frame(octx, enc_pkt);
                  av_packet_unref(enc_pkt);
                }
              }
              av_frame_unref(filt);
            }
          }
          int64_t pts_us = av_rescale_q(frame->pts, in_v->time_base, AV_TIME_BASE_Q);
          if (cb && cb->emit) {
            cb->emit(cb->user, "", "captions", (double)pts_us / (double)total_us, 0.0, 0.0);
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

  av_packet_free(&pkt);
  av_packet_free(&enc_pkt);
  av_frame_free(&frame);
  av_frame_free(&filt);
  avfilter_graph_free(&graph);
  avcodec_free_context(&enc_ctx);
  avcodec_free_context(&dec_ctx);
  if (octx->pb && !(octx->oformat->flags & AVFMT_NOFILE)) avio_closep(&octx->pb);
  avformat_free_context(octx);
  avformat_close_input(&ictx);
  if (cb && cb->emit) cb->emit(cb->user, "", "captions", 1.0, 0.0, 0.0);
  return rc < 0 && rc != AVERROR_EOF ? rc : 0;
}
