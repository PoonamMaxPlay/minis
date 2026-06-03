package com.loopit.minis.sys

import android.content.Context
import android.media.MediaMetadataRetriever
import android.net.Uri
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.VideoSize
import androidx.media3.exoplayer.ExoPlayer
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

class VideoPlayerEngine(private val appContext: Context, private val messenger: BinaryMessenger) {
  private val methodChannel = MethodChannel(messenger, METHOD_CHANNEL)
  private val sessions = ConcurrentHashMap<String, Session>()

  data class Session(
    val player: ExoPlayer,
    val eventChannel: EventChannel,
    var eventSink: EventChannel.EventSink? = null,
    var durationMs: Long = 0,
    var width: Int = 0,
    var height: Int = 0
  )

  init {
    methodChannel.setMethodCallHandler { call, result ->
      try {
        when (call.method) {
          "create" -> create(call.arguments as? Map<*, *>, result)
          "play" -> {
            val id = call.argument<String>("playerId") ?: return@setMethodCallHandler result.error("arg", "playerId required", null)
            postUi { sessions[id]?.player?.play(); result.success(null) }
          }
          "pause" -> {
            val id = call.argument<String>("playerId") ?: return@setMethodCallHandler result.error("arg", "playerId required", null)
            postUi { sessions[id]?.player?.pause(); result.success(null) }
          }
          "seek" -> {
            val id = call.argument<String>("playerId") ?: return@setMethodCallHandler result.error("arg", "playerId required", null)
            val ms = (call.argument<Number>("ms") ?: 0).toLong()
            postUi { sessions[id]?.player?.seekTo(ms); result.success(null) }
          }
          "volume" -> {
            val id = call.argument<String>("playerId") ?: return@setMethodCallHandler result.error("arg", "playerId required", null)
            val v = (call.argument<Number>("value") ?: 1).toFloat()
            postUi { sessions[id]?.player?.volume = v.coerceIn(0f, 1f); result.success(null) }
          }
          "rate" -> {
            val id = call.argument<String>("playerId") ?: return@setMethodCallHandler result.error("arg", "playerId required", null)
            val r = (call.argument<Number>("value") ?: 1).toFloat()
            postUi { sessions[id]?.player?.setPlaybackSpeed(r); result.success(null) }
          }
          "dispose" -> {
            val id = call.argument<String>("playerId") ?: return@setMethodCallHandler result.error("arg", "playerId required", null)
            dispose(id); result.success(null)
          }
          else -> result.notImplemented()
        }
      } catch (t: Throwable) {
        result.error("player_error", t.message, null)
      }
    }
  }

  private fun create(args: Map<*, *>?, result: MethodChannel.Result) {
    val path = args?.get("path") as? String ?: return result.error("arg", "path required", null)
    val loop = args["loop"] as? Boolean ?: false
    val autoplay = args["autoplay"] as? Boolean ?: false
    val mute = args["mute"] as? Boolean ?: false
    val playerId = UUID.randomUUID().toString()
    val durationFromFile = extractDuration(path)
    val sizeFromFile = extractSize(path)

    postUi {
      val player = ExoPlayer.Builder(appContext).build().apply {
        setMediaItem(MediaItem.fromUri(Uri.parse(path)))
        repeatMode = if (loop) Player.REPEAT_MODE_ALL else Player.REPEAT_MODE_OFF
        if (mute) volume = 0f
        prepare()
        playWhenReady = autoplay
      }
      val eventChannel = EventChannel(messenger, "$EVENT_CHANNEL_PREFIX$playerId")
      val session = Session(player, eventChannel,
        durationMs = durationFromFile,
        width = sizeFromFile.first,
        height = sizeFromFile.second)
      eventChannel.setStreamHandler(object : EventChannel.StreamHandler {
        override fun onListen(arguments: Any?, events: EventChannel.EventSink?) { session.eventSink = events }
        override fun onCancel(arguments: Any?) { session.eventSink = null }
      })
      player.addListener(object : Player.Listener {
        override fun onPlaybackStateChanged(playbackState: Int) {
          val kind = when (playbackState) {
            Player.STATE_READY -> "ready"
            Player.STATE_BUFFERING -> "buffering"
            Player.STATE_ENDED -> "completed"
            Player.STATE_IDLE -> "paused"
            else -> "ready"
          }
          if (playbackState == Player.STATE_READY) {
            val d = player.duration
            if (d > 0) session.durationMs = d
          }
          emit(session, kind)
        }
        override fun onIsPlayingChanged(isPlaying: Boolean) {
          emit(session, if (isPlaying) "playing" else "paused")
        }
        override fun onVideoSizeChanged(vs: VideoSize) {
          var w = vs.width; var h = vs.height
          val rot = vs.unappliedRotationDegrees
          if (rot == 90 || rot == 270) { val t = w; w = h; h = t }
          session.width = w; session.height = h
        }
        override fun onPlayerError(error: PlaybackException) {
          session.eventSink?.success(mapOf("kind" to "error", "err" to error.message))
        }
      })
      sessions[playerId] = session
      result.success(mapOf(
        "playerId" to playerId,
        "durationMs" to session.durationMs,
        "w" to session.width,
        "h" to session.height
      ))
    }
  }

  private fun emit(session: Session, kind: String) {
    val p = session.player
    session.eventSink?.success(mapOf(
      "kind" to kind,
      "posMs" to p.currentPosition,
      "bufMs" to p.bufferedPosition
    ))
  }

  fun attachSurface(playerId: String, surface: android.view.Surface?) {
    val s = sessions[playerId] ?: return
    postUi { s.player.setVideoSurface(surface) }
  }

  fun detachSurface(playerId: String) {
    val s = sessions[playerId] ?: return
    postUi { s.player.clearVideoSurface() }
  }

  fun dispose(playerId: String) {
    val s = sessions.remove(playerId) ?: return
    postUi { s.player.release(); s.eventChannel.setStreamHandler(null) }
  }

  fun disposeAll() {
    val ids = sessions.keys.toList()
    ids.forEach { dispose(it) }
    methodChannel.setMethodCallHandler(null)
  }

  private fun extractDuration(path: String): Long {
    val r = MediaMetadataRetriever()
    return try {
      r.setDataSource(path)
      r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0L
    } catch (_: Throwable) { 0L } finally { try { r.release() } catch (_: Throwable) {} }
  }
  private fun extractSize(path: String): Pair<Int, Int> {
    val r = MediaMetadataRetriever()
    return try {
      r.setDataSource(path)
      val w = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull() ?: 0
      val h = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull() ?: 0
      Pair(w, h)
    } catch (_: Throwable) { Pair(0, 0) } finally { try { r.release() } catch (_: Throwable) {} }
  }

  private fun postUi(block: () -> Unit) {
    android.os.Handler(android.os.Looper.getMainLooper()).post(block)
  }

  companion object {
    const val METHOD_CHANNEL = "loopit/minis/player"
    const val EVENT_CHANNEL_PREFIX = "loopit/minis/player/events/"
  }
}
