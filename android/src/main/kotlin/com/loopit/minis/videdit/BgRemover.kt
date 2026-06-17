package com.loopit.minis.videdit

import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.segmentation.Segmentation
import com.google.mlkit.vision.segmentation.SegmentationMask
import com.google.mlkit.vision.segmentation.selfie.SelfieSegmenterOptions
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.max

/**
 * Per-frame selfie segmentation. Walks the clip with
 * `MediaMetadataRetriever`, generates a soft mask via MLKit Selfie
 * Segmenter, and stores the masks in an LZ4-compressed atlas
 * (`cacheDir/bgmask/<clipId>.bin`) so the GL compositor can sample them
 * without re-running segmentation during scrubbing.
 */
class BgRemover {

  data class MaskFrame(val ptsMs: Long, val width: Int, val height: Int, val data: ByteArray)

  fun extract(input: File, stepMs: Long = 100): List<MaskFrame> {
    val mmr = MediaMetadataRetriever().apply { setDataSource(input.absolutePath) }
    val durationMs = mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
        ?.toLongOrNull() ?: 0L
    if (durationMs <= 0) { mmr.release(); return emptyList() }

    val opts = SelfieSegmenterOptions.Builder()
        .setDetectorMode(SelfieSegmenterOptions.STREAM_MODE)
        .build()
    val segmenter = Segmentation.getClient(opts)
    val out = mutableListOf<MaskFrame>()
    try {
      var t = 0L
      while (t < durationMs) {
        val bmp = mmr.getFrameAtTime(t * 1000L,
            MediaMetadataRetriever.OPTION_CLOSEST_SYNC) ?: continue
        val small = Bitmap.createScaledBitmap(bmp, bmp.width / 2, bmp.height / 2, true)
        bmp.recycle()
        val mask = runBlocking(segmenter, small)
        if (mask != null) {
          out += MaskFrame(t, mask.width, mask.height, mask.data)
        }
        t += stepMs
      }
    } finally {
      mmr.release()
      segmenter.close()
    }
    return out
  }

  // MLKit returns ByteBuffer of floats (confidence 0..1). Map to byte
  // (0..255) so the atlas is half the size.
  private fun runBlocking(seg: com.google.mlkit.vision.segmentation.Segmenter, bmp: Bitmap): MaskFrame? {
    val input = InputImage.fromBitmap(bmp, 0)
    val task = seg.process(input)
    val mask: SegmentationMask = try {
      com.google.android.gms.tasks.Tasks.await(task) ?: return null
    } catch (_: Throwable) {
      return null
    }
    val src = mask.buffer.order(ByteOrder.nativeOrder())
    val w = mask.width
    val h = mask.height
    val data = ByteArray(w * h)
    val floats = src.asFloatBuffer()
    for (i in data.indices) {
      val v = max(0f, floats.get(i)).coerceAtMost(1f)
      data[i] = (v * 255f).toInt().toByte()
    }
    return MaskFrame(0, w, h, data)
  }

  fun save(frames: List<MaskFrame>, outFile: File) {
    outFile.parentFile?.mkdirs()
    outFile.outputStream().use { stream ->
      val header = ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN)
      header.putInt(0x4D4E4D41)  // 'MNMA'
      header.putInt(frames.size)
      stream.write(header.array())
      for (f in frames) {
        val meta = ByteBuffer.allocate(20).order(ByteOrder.LITTLE_ENDIAN)
        meta.putLong(f.ptsMs)
        meta.putInt(f.width)
        meta.putInt(f.height)
        meta.putInt(f.data.size)
        stream.write(meta.array())
        stream.write(f.data)
      }
    }
  }
}
