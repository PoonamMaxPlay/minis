package com.loopit.minis.audio

import android.media.MediaPlayer
import android.media.PlaybackParams
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel
import java.util.concurrent.atomic.AtomicInteger

/**
 * Owns N MediaPlayer instances keyed by an integer playerId. Pumps position +
 * state events to the shared EventChannel sink.
 */
class PlayerRegistry {
    private val players = mutableMapOf<Int, Slot>()
    private val nextId = AtomicInteger(1)
    private var sink: EventChannel.EventSink? = null
    private val handler = Handler(Looper.getMainLooper())

    fun attachSink(s: EventChannel.EventSink?) {
        sink = s
    }

    @Synchronized
    fun createOrReplace(path: String, volume: Float, existingId: Int?): Map<String, Any> {
        if (existingId != null) dispose(existingId)
        val id = nextId.getAndIncrement()
        val mp = MediaPlayer()
        val slot = Slot(id, mp)
        mp.setVolume(volume, volume)
        mp.setDataSource(path)
        mp.prepare()
        slot.duration = mp.duration.coerceAtLeast(0)
        mp.setOnCompletionListener {
            slot.playing = false
            emit(mapOf("playerId" to id, "type" to "completed"))
            emitState(slot, "paused")
            when (slot.finishMode) {
                "loop" -> {
                    mp.seekTo(0)
                    mp.start()
                    slot.playing = true
                    emitState(slot, "playing")
                }
                "stop" -> {
                    mp.reset()
                    emitState(slot, "stopped")
                }
                else -> { /* pause */ }
            }
        }
        players[id] = slot
        return mapOf(
            "playerId" to id,
            "durationMs" to slot.duration,
        )
    }

    @Synchronized
    fun control(id: Int, op: String, value: Any?) {
        val slot = players[id] ?: return
        val mp = slot.player
        when (op) {
            "play" -> {
                mp.start()
                slot.playing = true
                emitState(slot, "playing")
                schedulePositionPump(slot)
            }
            "pause" -> {
                if (mp.isPlaying) mp.pause()
                slot.playing = false
                emitState(slot, "paused")
            }
            "stop" -> {
                mp.pause()
                mp.seekTo(0)
                slot.playing = false
                emitState(slot, "stopped")
            }
            "seek" -> {
                val v = (value as? Number)?.toInt() ?: return
                mp.seekTo(v)
                emit(mapOf("playerId" to id, "type" to "position", "positionMs" to v))
            }
            "volume" -> {
                val v = (value as? Number)?.toFloat() ?: 1f
                mp.setVolume(v, v)
            }
            "rate" -> {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    val v = (value as? Number)?.toFloat()?.coerceIn(0.25f, 4f) ?: 1f
                    try {
                        val wasPlaying = mp.isPlaying
                        mp.playbackParams = PlaybackParams().setSpeed(v)
                        if (!wasPlaying) mp.pause()
                    } catch (_: Throwable) {}
                }
            }
        }
    }

    @Synchronized
    fun setFinishMode(id: Int, mode: String) {
        players[id]?.finishMode = mode
    }

    @Synchronized
    fun duration(id: Int): Int = players[id]?.player?.duration?.coerceAtLeast(0) ?: 0

    @Synchronized
    fun dispose(id: Int) {
        val slot = players.remove(id) ?: return
        try {
            slot.player.stop()
        } catch (_: Throwable) {}
        try {
            slot.player.release()
        } catch (_: Throwable) {}
        slot.disposed = true
    }

    @Synchronized
    fun disposeAll() {
        for (id in players.keys.toList()) dispose(id)
    }

    private fun emitState(slot: Slot, state: String) {
        emit(mapOf("playerId" to slot.id, "type" to "state", "state" to state))
    }

    private fun emit(event: Map<String, Any?>) {
        val s = sink ?: return
        handler.post {
            try {
                s.success(event)
            } catch (_: Throwable) {}
        }
    }

    private fun schedulePositionPump(slot: Slot) {
        val runnable = object : Runnable {
            override fun run() {
                if (slot.disposed) return
                if (!slot.playing) return
                val mp = slot.player
                try {
                    val pos = mp.currentPosition.coerceAtLeast(0)
                    emit(
                        mapOf(
                            "playerId" to slot.id,
                            "type" to "position",
                            "positionMs" to pos,
                        )
                    )
                } catch (_: Throwable) {}
                handler.postDelayed(this, POSITION_TICK_MS)
            }
        }
        handler.postDelayed(runnable, POSITION_TICK_MS)
    }

    private class Slot(val id: Int, val player: MediaPlayer) {
        var playing = false
        var disposed = false
        var finishMode: String = "pause"
        var duration: Int = 0
    }

    companion object {
        private const val POSITION_TICK_MS = 80L
    }
}
