package com.loopit.minis.videdit

import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.view.Surface
import java.util.concurrent.ConcurrentHashMap

/**
 * Pool of `MediaCodec` decoder instances reused across clips. The
 * compositor (Phase 2.5) reaches in with a path + start time and gets back
 * a configured decoder with its output Surface bound to an OES texture.
 *
 * The pool keeps up to [MAX] active decoders and evicts least-recently-used
 * entries when a new one is required.
 */
class HWDecoderPool(private val max: Int = MAX) {

  private data class Entry(
      val codec: MediaCodec,
      val extractor: MediaExtractor,
      val surface: Surface,
  )

  private val active = ConcurrentHashMap<String, Entry>()
  private val lru = ArrayDeque<String>()
  private val lock = Object()

  fun acquire(path: String, outputSurface: Surface): Pair<MediaCodec, MediaExtractor> {
    synchronized(lock) {
      active[path]?.let { entry ->
        lru.remove(path)
        lru.addLast(path)
        return entry.codec to entry.extractor
      }
      while (active.size >= max && lru.isNotEmpty()) {
        val evict = lru.removeFirst()
        active.remove(evict)?.let { e ->
          runCatching { e.codec.stop() }
          runCatching { e.codec.release() }
          runCatching { e.extractor.release() }
        }
      }
      val extractor = MediaExtractor().apply { setDataSource(path) }
      var trackIdx = -1
      var format: MediaFormat? = null
      for (i in 0 until extractor.trackCount) {
        val f = extractor.getTrackFormat(i)
        if (f.getString(MediaFormat.KEY_MIME)?.startsWith("video/") == true) {
          trackIdx = i; format = f; break
        }
      }
      if (trackIdx < 0 || format == null) {
        throw IllegalStateException("no video track in $path")
      }
      extractor.selectTrack(trackIdx)
      val mime = format.getString(MediaFormat.KEY_MIME)!!
      val codec = MediaCodec.createDecoderByType(mime)
      codec.configure(format, outputSurface, null, 0)
      codec.start()
      active[path] = Entry(codec, extractor, outputSurface)
      lru.addLast(path)
      return codec to extractor
    }
  }

  fun release(path: String) {
    synchronized(lock) {
      lru.remove(path)
      active.remove(path)?.let { e ->
        runCatching { e.codec.stop() }
        runCatching { e.codec.release() }
        runCatching { e.extractor.release() }
      }
    }
  }

  fun releaseAll() {
    synchronized(lock) {
      for (e in active.values) {
        runCatching { e.codec.stop() }
        runCatching { e.codec.release() }
        runCatching { e.extractor.release() }
      }
      active.clear()
      lru.clear()
    }
  }

  companion object { const val MAX = 4 }
}
