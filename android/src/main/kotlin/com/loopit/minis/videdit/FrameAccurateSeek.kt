package com.loopit.minis.videdit

import android.media.MediaCodec
import android.media.MediaExtractor

/**
 * Frame-accurate seek built on top of `MediaExtractor.seekTo(SEEK_TO_PREVIOUS_SYNC)`
 * plus a decoded-forward loop until the decoder emits a frame ≥ the
 * requested timestamp. Returns the absolute presentation timestamp (μs) of
 * the delivered frame.
 *
 * The MediaCodec instance passed in must be configured against the
 * extractor's track and started; the caller owns flush/release.
 */
object FrameAccurateSeek {

  fun seekTo(
      extractor: MediaExtractor,
      codec: MediaCodec,
      targetUs: Long,
      timeoutMs: Long = 1500,
  ): Long {
    extractor.seekTo(targetUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
    codec.flush()

    val info = MediaCodec.BufferInfo()
    val deadline = System.currentTimeMillis() + timeoutMs
    var inputDone = false

    while (System.currentTimeMillis() < deadline) {
      if (!inputDone) {
        val inIdx = codec.dequeueInputBuffer(10_000)
        if (inIdx >= 0) {
          val inBuf = codec.getInputBuffer(inIdx) ?: continue
          val read = extractor.readSampleData(inBuf, 0)
          if (read < 0) {
            codec.queueInputBuffer(inIdx, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
            inputDone = true
          } else {
            codec.queueInputBuffer(inIdx, 0, read, extractor.sampleTime, 0)
            extractor.advance()
          }
        }
      }
      val outIdx = codec.dequeueOutputBuffer(info, 10_000)
      when {
        outIdx >= 0 -> {
          val pts = info.presentationTimeUs
          if (pts >= targetUs) {
            codec.releaseOutputBuffer(outIdx, true)
            return pts
          } else {
            codec.releaseOutputBuffer(outIdx, false)
          }
          if ((info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) return pts
        }
        outIdx == MediaCodec.INFO_TRY_AGAIN_LATER -> { /* keep polling */ }
        outIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> { /* swallow */ }
      }
    }
    return -1
  }
}
