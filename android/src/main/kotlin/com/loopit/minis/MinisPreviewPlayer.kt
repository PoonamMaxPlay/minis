package com.loopit.minis

import android.content.Context
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.view.SurfaceView
import android.view.View
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

class MinisPreviewPlayerFactory(private val messenger: io.flutter.plugin.common.BinaryMessenger) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, id: Int, args: Any?): PlatformView {
        val creationParams = args as? Map<String?, Any?>?
        return MinisPreviewPlayer(context, id, creationParams, messenger)
    }
}

class MinisPreviewPlayer(
    context: Context,
    id: Int,
    creationParams: Map<String?, Any?>?,
    messenger: io.flutter.plugin.common.BinaryMessenger
) : PlatformView, MethodChannel.MethodCallHandler, Player.Listener {

    private val surfaceView = SurfaceView(context)
    private var player: ExoPlayer? = null
    private val methodChannel: MethodChannel = MethodChannel(messenger, "minis_preview_player_$id")
    private var paths: List<String> = emptyList()

    /** Per [paths] index; used when the timeline has not resolved duration yet (common with gallery + recorded mixes). */
    private val pathDurationMsCache: LongArray by lazy {
        LongArray(paths.size) { i -> extractDurationMsFromFile(paths[i]) }
    }

    init {
        methodChannel.setMethodCallHandler(this)
        @Suppress("UNCHECKED_CAST")
        paths = creationParams?.get("paths") as? List<String> ?: emptyList()
        val mute = creationParams?.get("mute") as? Boolean ?: false

        try {
            player = ExoPlayer.Builder(context).build().apply {
                setVideoSurfaceView(surfaceView)
                val mediaItems = paths.map { MediaItem.fromUri(Uri.parse(it)) }
                setMediaItems(mediaItems)
                repeatMode = Player.REPEAT_MODE_ALL
                addListener(this@MinisPreviewPlayer)
                if (mute) volume = 0f
                prepare()
                playWhenReady = true
            }
            // Warm file-based durations so first Flutter poll gets the full multi-clip length.
            if (paths.size > 1) {
                pathDurationMsCache
            }
        } catch (e: Exception) {
            android.util.Log.e("MinisPreviewPlayer", "init failed, releasing player", e)
            player?.release()
            player = null
        }
    }

    override fun getView(): View {
        return surfaceView
    }

    override fun dispose() {
        methodChannel.setMethodCallHandler(null)
        player?.release()
        player = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "play" -> {
                player?.play()
                result.success(null)
            }
            "pause" -> {
                player?.pause()
                result.success(null)
            }
            "seekTo" -> {
                val position = call.arguments as? Int ?: 0
                seekToGlobal(position.toLong())
                result.success(null)
            }
            "getPosition" -> {
                result.success(getTotalPosition())
            }
            "getDuration" -> {
                result.success(getTotalDuration())
            }
            "getVideoSize" -> {
                val format = player?.videoFormat
                var w = format?.width ?: 0
                var h = format?.height ?: 0
                val rot = format?.rotationDegrees ?: 0
                if (rot == 90 || rot == 270) {
                    val temp = w
                    w = h
                    h = temp
                }
                result.success(listOf(w, h))
            }
            else -> result.notImplemented()
        }
    }

    override fun onPlaybackStateChanged(playbackState: Int) {
        if (playbackState == Player.STATE_ENDED) {
            methodChannel.invokeMethod("onEnded", null)
        }
    }

    override fun onVideoSizeChanged(videoSize: androidx.media3.common.VideoSize) {
        var w = videoSize.width
        var h = videoSize.height
        val rot = videoSize.unappliedRotationDegrees
        if (rot == 90 || rot == 270) {
            val temp = w
            w = h
            h = temp
        }
        methodChannel.invokeMethod("onVideoSizeChanged", listOf(w, h))
    }

    private fun sumPathDurationsMs(): Long {
        if (paths.isEmpty()) return 0L
        if (paths.size == 1) return pathDurationMsCache[0]
        var s = 0L
        for (i in pathDurationMsCache.indices) {
            s += pathDurationMsCache[i]
        }
        return s
    }

    private fun extractDurationMsFromFile(path: String): Long {
        val r = MediaMetadataRetriever()
        return try {
            r.setDataSource(path)
            r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0L
        } catch (_: Exception) {
            0L
        } finally {
            try {
                r.release()
            } catch (_: Exception) {
            }
        }
    }

    private fun windowDurationMs(i: Int, window: androidx.media3.common.Timeline.Window): Long {
        val d = window.durationMs
        if (d != androidx.media3.common.C.TIME_UNSET && d > 0) {
            return d
        }
        return if (i in pathDurationMsCache.indices) pathDurationMsCache[i] else 0L
    }

    private fun getTotalDuration(): Long {
        val p = player ?: return sumPathDurationsMs()
        val timeline = p.currentTimeline
        if (timeline.isEmpty) return sumPathDurationsMs()
        var timelineMs = 0L
        val window = androidx.media3.common.Timeline.Window()
        for (i in 0 until timeline.windowCount) {
            timeline.getWindow(i, window)
            timelineMs += windowDurationMs(i, window)
        }
        val pathMs = sumPathDurationsMs()
        // Exo often reports only the first window until the full timeline is ready; file metadata is stable.
        return kotlin.math.max(timelineMs, pathMs)
    }

    private fun getTotalPosition(): Long {
        val p = player ?: return 0L
        val timeline = p.currentTimeline
        if (timeline.isEmpty) return 0L
        var positionMs = p.currentPosition
        val currentWindowIndex = p.currentMediaItemIndex
        val window = androidx.media3.common.Timeline.Window()
        for (i in 0 until currentWindowIndex) {
            timeline.getWindow(i, window)
            positionMs += windowDurationMs(i, window)
        }
        return positionMs
    }

    private fun seekToGlobal(positionMs: Long) {
        val p = player ?: return
        val timeline = p.currentTimeline
        if (timeline.isEmpty) {
            p.seekTo(positionMs)
            return
        }
        var remainingMs = positionMs
        val window = androidx.media3.common.Timeline.Window()
        for (i in 0 until timeline.windowCount) {
            timeline.getWindow(i, window)
            val windowDur = windowDurationMs(i, window)
            if (windowDur > 0 && remainingMs <= windowDur) {
                p.seekTo(i, remainingMs)
                return
            }
            remainingMs -= windowDur
        }
        val last = timeline.windowCount - 1
        timeline.getWindow(last, window)
        p.seekTo(last, windowDurationMs(last, window))
    }
}
