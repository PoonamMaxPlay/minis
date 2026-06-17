package com.loopit.minis.audio

import java.io.FileOutputStream

/**
 * Optional MP3 encoder shim. The underlying `libmp3lame.so` is vendored only
 * when MP3 export is required (see `cpp/audio/lame_README.md`). All calls are
 * safe no-ops when the library is absent; integrators must branch on
 * `isAvailable()`.
 */
class LameStub {

    fun isAvailable(): Boolean = libLoaded

    fun encode(samples: FloatArray, sr: Int, ch: Int, outPath: String): Boolean {
        if (!libLoaded) return false
        if (samples.isEmpty() || ch !in 1..2 || sr <= 0) return false
        val handle = try { nativeInit(sr, ch, 192) } catch (_: Throwable) { 0L }
        if (handle == 0L) return false
        return try {
            FileOutputStream(outPath).use { fos ->
                val frames = samples.size / ch
                // Chunk to keep native scratch buffer small.
                val chunkFrames = 8192
                val mp3Buf = ByteArray((chunkFrames * 5) / 4 + 7200)
                var off = 0
                while (off < frames) {
                    val n = minOf(chunkFrames, frames - off)
                    val pcm = FloatArray(n * ch)
                    System.arraycopy(samples, off * ch, pcm, 0, n * ch)
                    val written = nativeEncode(handle, pcm, n, mp3Buf)
                    if (written > 0) fos.write(mp3Buf, 0, written)
                    off += n
                }
                val flush = nativeFinish(handle, mp3Buf)
                if (flush > 0) fos.write(mp3Buf, 0, flush)
            }
            true
        } catch (_: Throwable) {
            false
        } finally {
            try { nativeClose(handle) } catch (_: Throwable) {}
        }
    }

    private external fun nativeInit(sampleRate: Int, channels: Int, kbps: Int): Long
    private external fun nativeEncode(handle: Long, pcm: FloatArray, frames: Int, mp3Out: ByteArray): Int
    private external fun nativeFinish(handle: Long, mp3Out: ByteArray): Int
    private external fun nativeClose(handle: Long)

    companion object {
        @Volatile private var libLoaded: Boolean = false

        init {
            libLoaded = try {
                System.loadLibrary("minis_audio_lame")
                true
            } catch (_: Throwable) {
                false
            }
        }
    }
}
