// FFmpeg-backed thumbnail strip used as the software fallback when the
// platform's HW scrubber (MediaMetadataRetriever / AVAssetImageGenerator)
// cannot decode the source codec. Decodes N evenly-spaced timestamps to
// RGB24 via swscale and writes one JPEG per thumbnail into `out_dir`.

#include "ff_common.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/imgutils.h>
#include <libswscale/swscale.h>

static int encode_jpeg(AVFrame* rgb, int w, int h, const char* out_path) {
  const AVCodec* enc = avcodec_find_encoder(AV_CODEC_ID_MJPEG);
  if (!enc) return -1;
  AVCodecContext* cc = avcodec_alloc_context3(enc);
  if (!cc) return -1;
  cc->width = w;
  cc->height = h;
  cc->time_base = (AVRational){1, 25};
  cc->pix_fmt = AV_PIX_FMT_YUVJ420P;
  int rc = avcodec_open2(cc, enc, NULL);
  if (rc < 0) { avcodec_free_context(&cc); return rc; }

  AVFrame* yuv = av_frame_alloc();
  yuv->format = AV_PIX_FMT_YUVJ420P;
  yuv->width = w; yuv->height = h;
  av_frame_get_buffer(yuv, 32);
  struct SwsContext* sws = sws_getContext(w, h, AV_PIX_FMT_RGB24,
                                          w, h, AV_PIX_FMT_YUVJ420P,
                                          SWS_BILINEAR, NULL, NULL, NULL);
  sws_scale(sws, (const uint8_t* const*)rgb->data, rgb->linesize,
            0, h, yuv->data, yuv->linesize);
  sws_freeContext(sws);

  AVPacket* pkt = av_packet_alloc();
  rc = avcodec_send_frame(cc, yuv);
  if (rc >= 0) rc = avcodec_receive_packet(cc, pkt);
  if (rc >= 0) {
    FILE* f = fopen(out_path, "wb");
    if (f) { fwrite(pkt->data, 1, pkt->size, f); fclose(f); }
    av_packet_unref(pkt);
  }
  av_packet_free(&pkt);
  av_frame_free(&yuv);
  avcodec_free_context(&cc);
  return rc >= 0 ? 0 : rc;
}

int ff_thumbstrip_run(const char* in_path, int count, int w, int h,
                      const char* out_dir, char*** out_paths, int* out_n) {
  if (!in_path || !out_dir || count <= 0 || w <= 0 || h <= 0) return -1;
  AVFormatContext* ictx = NULL;
  int rc = avformat_open_input(&ictx, in_path, NULL, NULL);
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

  AVStream* st = ictx->streams[v_idx];
  AVCodecParameters* cp = st->codecpar;
  const AVCodec* dec = avcodec_find_decoder(cp->codec_id);
  AVCodecContext* dc = avcodec_alloc_context3(dec);
  avcodec_parameters_to_context(dc, cp);
  rc = avcodec_open2(dc, dec, NULL);
  if (rc < 0) {
    avcodec_free_context(&dc);
    avformat_close_input(&ictx);
    return rc;
  }

  int64_t duration = ictx->duration > 0 ? ictx->duration : 0;
  AVFrame* frame = av_frame_alloc();
  AVFrame* rgb = av_frame_alloc();
  rgb->format = AV_PIX_FMT_RGB24;
  rgb->width = w; rgb->height = h;
  av_frame_get_buffer(rgb, 32);

  *out_paths = (char**)calloc((size_t)count, sizeof(char*));
  *out_n = 0;

  for (int i = 0; i < count; i++) {
    int64_t target = duration * i / count;
    int64_t seek_t = av_rescale_q(target, AV_TIME_BASE_Q, st->time_base);
    av_seek_frame(ictx, v_idx, seek_t, AVSEEK_FLAG_BACKWARD);
    avcodec_flush_buffers(dc);

    AVPacket* pkt = av_packet_alloc();
    int got = 0;
    while (av_read_frame(ictx, pkt) >= 0) {
      if (pkt->stream_index == v_idx) {
        avcodec_send_packet(dc, pkt);
        while (avcodec_receive_frame(dc, frame) == 0) {
          if (frame->pts >= seek_t || got) {
            struct SwsContext* sws = sws_getContext(
                frame->width, frame->height, dc->pix_fmt,
                w, h, AV_PIX_FMT_RGB24,
                SWS_BILINEAR, NULL, NULL, NULL);
            sws_scale(sws, (const uint8_t* const*)frame->data, frame->linesize,
                      0, frame->height, rgb->data, rgb->linesize);
            sws_freeContext(sws);
            char path[512];
            snprintf(path, sizeof(path), "%s/t_%03d.jpg", out_dir, i);
            if (encode_jpeg(rgb, w, h, path) == 0) {
              (*out_paths)[*out_n] = strdup(path);
              (*out_n)++;
              got = 1;
            }
            break;
          }
        }
        if (got) { av_packet_unref(pkt); break; }
      }
      av_packet_unref(pkt);
    }
    av_packet_free(&pkt);
  }

  av_frame_free(&rgb);
  av_frame_free(&frame);
  avcodec_free_context(&dc);
  avformat_close_input(&ictx);
  return 0;
}
