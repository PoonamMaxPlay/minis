package com.loopit.minis.camera

import android.content.Context
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import android.util.Log
import androidx.camera.video.FileOutputOptions
import androidx.camera.video.PendingRecording
import androidx.camera.video.Recorder
import androidx.camera.video.Recording
import androidx.camera.video.VideoCapture
import androidx.camera.video.VideoRecordEvent
import androidx.core.content.ContextCompat
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.util.concurrent.atomic.AtomicReference

/**
 * Multi-clip segment recorder: each pause finalises one `.mp4` segment, resume
 * starts a new one. [finalize] merges segments via [MediaMuxer] with track copy
 * (no re-encode) so codec config blobs match across clips.
 *
 * On-disk crash recovery: an index file `segments.idx` is fsynced after every
 * segment finalize so a relaunch can pick up an unfinished session.
 */
class MultiClipRecorder(
    private val context: Context,
    private val workDir: File,
    private val onState: (CameraSession.State) -> Unit = {},
    private val onError: (String, String?) -> Unit = { _, _ -> },
) {
    private val segments = mutableListOf<File>()
    private val active = AtomicReference<Recording?>(null)
    private var currentFile: File? = null
    private var sessionId = System.currentTimeMillis()
    private val indexFile = File(workDir, "segments.idx")

    init { workDir.mkdirs(); recoverIfNeeded() }

    fun startNew(videoCapture: VideoCapture<Recorder>, withAudio: Boolean) {
        val outFile = File(workDir, "seg_${sessionId}_${segments.size + 1}.mp4")
        currentFile = outFile
        val pending: PendingRecording = videoCapture.output.prepareRecording(
            context,
            FileOutputOptions.Builder(outFile).build(),
        )
        val starter = if (withAudio) pending.withAudioEnabled() else pending
        val rec = starter.start(
            ContextCompat.getMainExecutor(context),
        ) { event ->
            when (event) {
                is VideoRecordEvent.Start -> onState(CameraSession.State.RECORDING)
                is VideoRecordEvent.Pause -> onState(CameraSession.State.PAUSED)
                is VideoRecordEvent.Resume -> onState(CameraSession.State.RECORDING)
                is VideoRecordEvent.Finalize -> {
                    if (event.hasError()) {
                        onError("RECORD_FAILED", event.cause?.message)
                    } else {
                        outFile.let { segments.add(it); persistIndex() }
                        onState(CameraSession.State.STOPPED)
                    }
                    active.set(null)
                }
                else -> Unit
            }
        }
        active.set(rec)
    }

    fun pause() { active.get()?.pause() }

    fun resume() { active.get()?.resume() }

    /** Stop and return the path of the just-finalised segment (when known). */
    fun stop(): File? {
        active.get()?.stop()
        active.set(null)
        return currentFile
    }

    fun segments(): List<File> = synchronized(segments) { segments.toList() }

    fun discard() {
        active.get()?.stop()
        active.set(null)
        synchronized(segments) {
            segments.forEach { runCatching { it.delete() } }
            segments.clear()
        }
        runCatching { indexFile.delete() }
    }

    /**
     * Concat all segments into one `.mp4` using [MediaMuxer] track-copy.
     * Returns the merged file path. No re-encode — codec config blobs must match
     * across all segments (CameraX uses the same Recorder so this holds).
     */
    fun finalizeMerged(out: File): File? {
        val list = segments().filter { it.exists() && it.length() > 0 }
        if (list.isEmpty()) return null
        if (list.size == 1) return list.first().copyTo(out, overwrite = true)

        var muxer: MediaMuxer? = null
        try {
            muxer = MediaMuxer(out.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
            // Resolve track formats from first segment.
            val firstExtractor = MediaExtractor().also { it.setDataSource(list.first().absolutePath) }
            val firstTrackMap = mutableMapOf<Int, Int>() // muxer-track -> extractor-track
            for (i in 0 until firstExtractor.trackCount) {
                val fmt = firstExtractor.getTrackFormat(i)
                val muxIdx = muxer.addTrack(fmt)
                firstTrackMap[muxIdx] = i
            }
            firstExtractor.release()
            muxer.start()

            val buf = ByteBuffer.allocate(2 * 1024 * 1024)
            val info = MediaCodec.BufferInfo()
            var ptsOffsetUs = 0L

            for (seg in list) {
                val ex = MediaExtractor()
                ex.setDataSource(seg.absolutePath)
                val trackIdxByMime = mutableMapOf<String, Int>()
                for (i in 0 until ex.trackCount) {
                    val mime = ex.getTrackFormat(i).getString(MediaFormat.KEY_MIME) ?: ""
                    trackIdxByMime[mime] = i
                }

                // Map muxer track -> extractor track for THIS segment.
                val perSegMap = mutableMapOf<Int, Int>()
                for ((muxIdx, _) in firstTrackMap) {
                    val muxFmt = muxer.javaClass // placeholder — we keep original ordering
                    // Use index alignment: assume same track order across segments.
                    perSegMap[muxIdx] = muxIdx
                }

                // Select all tracks in this extractor.
                for (i in 0 until ex.trackCount) ex.selectTrack(i)

                var segMaxPtsUs = 0L
                while (true) {
                    val trackIdx = ex.sampleTrackIndex
                    if (trackIdx < 0) break
                    buf.clear()
                    val size = ex.readSampleData(buf, 0)
                    if (size < 0) break
                    val pts = ex.sampleTime + ptsOffsetUs
                    info.set(0, size, pts, ex.sampleFlags)
                    runCatching {
                        muxer.writeSampleData(trackIdx, buf, info)
                    }.onFailure { Log.w(TAG, "writeSample: ${it.message}") }
                    if (pts > segMaxPtsUs) segMaxPtsUs = pts
                    ex.advance()
                }
                ex.release()
                ptsOffsetUs = segMaxPtsUs + 33_333 // 1/30s spacer
            }
            return out
        } catch (e: Exception) {
            Log.e(TAG, "finalize merge failed", e)
            return null
        } finally {
            runCatching { muxer?.stop() }
            runCatching { muxer?.release() }
        }
    }

    private fun persistIndex() {
        try {
            FileOutputStream(indexFile).use { os ->
                synchronized(segments) {
                    segments.forEach { os.write((it.absolutePath + "\n").toByteArray()) }
                }
                os.fd.sync()
            }
        } catch (e: Exception) {
            Log.w(TAG, "persistIndex: ${e.message}")
        }
    }

    private fun recoverIfNeeded() {
        if (!indexFile.exists()) return
        runCatching {
            indexFile.readLines().forEach { line ->
                val f = File(line.trim())
                if (f.exists() && f.length() > 0) {
                    synchronized(segments) { segments.add(f) }
                }
            }
        }.onFailure { Log.w(TAG, "recover: ${it.message}") }
    }

    fun durationsMsTotal(): Long {
        var total = 0L
        for (seg in segments()) {
            total += segmentDurationMs(seg)
        }
        return total
    }

    fun discardRecovery() = discard()

    companion object {
        private const val TAG = "MinisMultiClipRec"

        /**
         * Scan [workDir] for an orphaned `segments.idx` whose listed segments
         * still parse via [MediaExtractor]. Returns the valid segment paths.
         * Empty list when no recovery data exists.
         */
        fun probeOrphans(workDir: File): RecoveryProbe {
            val idx = File(workDir, "segments.idx")
            if (!idx.exists()) return RecoveryProbe(emptyList(), 0)
            val raw = runCatching { idx.readLines() }.getOrDefault(emptyList())
            val valid = mutableListOf<String>()
            var totalMs = 0L
            for (line in raw) {
                val p = line.trim().ifEmpty { continue }
                val f = File(p)
                if (!f.exists() || f.length() <= 0) continue
                val dur = segmentDurationMs(f)
                if (dur > 0) {
                    valid.add(f.absolutePath)
                    totalMs += dur
                }
            }
            return RecoveryProbe(valid, totalMs)
        }

        private fun segmentDurationMs(file: File): Long {
            var ex: MediaExtractor? = null
            return try {
                ex = MediaExtractor()
                ex.setDataSource(file.absolutePath)
                var max = 0L
                for (i in 0 until ex.trackCount) {
                    val fmt = ex.getTrackFormat(i)
                    if (fmt.containsKey(MediaFormat.KEY_DURATION)) {
                        val d = fmt.getLong(MediaFormat.KEY_DURATION) / 1000L
                        if (d > max) max = d
                    }
                }
                max
            } catch (_: Throwable) { 0L } finally { ex?.release() }
        }
    }

    data class RecoveryProbe(val segmentPaths: List<String>, val totalDurationMs: Long)
}
