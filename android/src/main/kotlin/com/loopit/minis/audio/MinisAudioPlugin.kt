package com.loopit.minis.audio

import android.content.Context
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Native-side host for the `loopit/minis/audio` channel. Owns the singletons
 * for session, players, recorder, and waveform extraction so the Dart shim can
 * stay stateless.
 */
class MinisAudioPlugin(
    private val context: Context,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {

    private val methodChannel = MethodChannel(messenger, "loopit/minis/audio")
    private val playerEvents = EventChannel(messenger, "loopit/minis/audio/playerEvents")
    private val levelsChannel = EventChannel(messenger, "loopit/minis/audio/levels")
    private val stateChannel = EventChannel(messenger, "loopit/minis/audio/state")
    private val progressChannel = EventChannel(messenger, "loopit/minis/audio/progress")

    private val session = AudioSession(context)
    private val players = PlayerRegistry()
    private val recorder = Recorder(context)
    private val waveform = WaveformExtractor(context)
    private val routes = AudioRouteWatcher(context)
    private val trimmer = AudioTrimmer()
    private val mixer = AudioMixer()
    private val normalizer = LufsNormalizer()
    private val beats = BeatDetector()
    private val stretch = PitchTimeStretch()
    private var progressSink: EventChannel.EventSink? = null

    init {
        methodChannel.setMethodCallHandler(this)
        playerEvents.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                players.attachSink(events)
            }

            override fun onCancel(arguments: Any?) {
                players.attachSink(null)
            }
        })
        levelsChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                recorder.attachLevelSink(events)
            }

            override fun onCancel(arguments: Any?) {
                recorder.attachLevelSink(null)
            }
        })
        stateChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                routes.attachSink(events)
                routes.start()
            }

            override fun onCancel(arguments: Any?) {
                routes.stop()
                routes.attachSink(null)
            }
        })
        progressChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                progressSink = events
            }

            override fun onCancel(arguments: Any?) {
                progressSink = null
            }
        })
    }

    fun dispose() {
        methodChannel.setMethodCallHandler(null)
        playerEvents.setStreamHandler(null)
        levelsChannel.setStreamHandler(null)
        stateChannel.setStreamHandler(null)
        progressChannel.setStreamHandler(null)
        routes.stop()
        routes.attachSink(null)
        players.disposeAll()
        recorder.dispose()
        session.release()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "configureSession" -> {
                    val accepted = session.configure(
                        category = call.argument("category"),
                        categoryOptions = (call.argument<Number>("categoryOptions"))?.toInt() ?: 0,
                        mode = call.argument("mode"),
                        androidAttrs = call.argument("androidAttrs"),
                        androidFocusGain = call.argument("androidFocusGain"),
                    )
                    result.success(mapOf("accepted" to accepted))
                }
                "setSessionActive" -> {
                    val active = call.argument<Boolean>("active") ?: false
                    val applied = session.setActive(active)
                    result.success(mapOf("active" to applied))
                }
                "playerCreate" -> {
                    val path = call.argument<String>("path")
                    if (path.isNullOrEmpty()) {
                        result.error("ARG", "path required", null); return
                    }
                    val volume = (call.argument<Number>("volume"))?.toFloat() ?: 1.0f
                    val existingId = (call.argument<Number>("existingId"))?.toInt()
                    val out = players.createOrReplace(path, volume, existingId)
                    result.success(out)
                }
                "playerControl" -> {
                    val id = (call.argument<Number>("playerId"))?.toInt()
                    val op = call.argument<String>("op")
                    if (id == null || op == null) {
                        result.error("ARG", "playerId+op required", null); return
                    }
                    players.control(id, op, call.argument("value"))
                    result.success(null)
                }
                "playerSetFinishMode" -> {
                    val id = (call.argument<Number>("playerId"))?.toInt()
                    val mode = call.argument<String>("mode") ?: "pause"
                    if (id == null) {
                        result.error("ARG", "playerId required", null); return
                    }
                    players.setFinishMode(id, mode)
                    result.success(null)
                }
                "playerGetDuration" -> {
                    val id = (call.argument<Number>("playerId"))?.toInt()
                    if (id == null) {
                        result.error("ARG", "playerId required", null); return
                    }
                    result.success(mapOf("durationMs" to players.duration(id)))
                }
                "playerDispose" -> {
                    val id = (call.argument<Number>("playerId"))?.toInt()
                    if (id != null) players.dispose(id)
                    result.success(null)
                }
                "startRecord" -> {
                    val path = call.argument<String>("path")
                    if (path.isNullOrEmpty()) {
                        result.error("ARG", "path required", null); return
                    }
                    recorder.start(
                        path = path,
                        format = call.argument<String>("format") ?: "aac",
                        sampleRate = (call.argument<Number>("sampleRate"))?.toInt() ?: 44100,
                        channels = (call.argument<Number>("channels"))?.toInt() ?: 1,
                        bitRate = (call.argument<Number>("bitRate"))?.toInt() ?: 128000,
                        denoise = call.argument<Boolean>("denoise") ?: false,
                        monitor = call.argument<Boolean>("monitor") ?: false,
                    )
                    result.success(null)
                }
                "pauseRecord" -> {
                    recorder.pause()
                    result.success(null)
                }
                "resumeRecord" -> {
                    recorder.resume()
                    result.success(null)
                }
                "stopRecord" -> {
                    val out = recorder.stop()
                    result.success(out)
                }
                "extractWaveform" -> {
                    val path = call.argument<String>("path")
                    val peaks = (call.argument<Number>("peaks"))?.toInt() ?: 1024
                    if (path.isNullOrEmpty()) {
                        result.error("ARG", "path required", null); return
                    }
                    waveform.extract(path, peaks, result)
                }
                // ---- improvement4.md deferred surface (D1.x/D6/D7/D8/D9) ----
                // Wired so call sites can probe via PlatformException(code=NOT_IMPLEMENTED).
                "listInputs" -> result.success(mapOf("inputs" to recorder.listInputs()))
                "setInput" -> {
                    val id = call.argument<String>("id")
                    if (id.isNullOrEmpty()) {
                        result.error("ARG", "id required", null); return
                    }
                    val ok = recorder.setPreferredInput(id)
                    result.success(mapOf("applied" to ok))
                }
                "trim" -> {
                    val path = call.argument<String>("path")
                    val outPath = call.argument<String>("outPath")
                    val inMs = (call.argument<Number>("inMs"))?.toLong() ?: 0L
                    val outMs = (call.argument<Number>("outMs"))?.toLong() ?: 0L
                    val mode = call.argument<String>("mode") ?: "accurate"
                    if (path.isNullOrEmpty() || outPath.isNullOrEmpty()) {
                        result.error("ARG", "path+outPath required", null); return
                    }
                    trimmer.trim(path, inMs, outMs, outPath, mode, result)
                }
                "mix" -> {
                    val rawTracks = call.argument<List<Map<String, Any?>>>("tracks")
                    val outPath = call.argument<String>("outPath")
                    if (rawTracks.isNullOrEmpty() || outPath.isNullOrEmpty()) {
                        result.error("ARG", "tracks+outPath required", null); return
                    }
                    val targetLufs = (call.argument<Number>("targetLufs"))?.toDouble() ?: -14.0
                    val parsed = rawTracks.mapNotNull { m ->
                        val p = m["path"] as? String ?: return@mapNotNull null
                        val eq = m["eq"] as? Map<*, *>
                        AudioMixer.Track(
                            path = p,
                            inMs = (m["inMs"] as? Number)?.toLong() ?: 0L,
                            outMs = (m["outMs"] as? Number)?.toLong() ?: 0L,
                            positionMs = (m["positionMs"] as? Number)?.toLong() ?: 0L,
                            gainEnv = parseEnv(m["gainEnv"]),
                            panEnv = parseEnv(m["panEnv"]),
                            eqLowDb = (eq?.get("lowDb") as? Number)?.toDouble() ?: 0.0,
                            eqMidDb = (eq?.get("midDb") as? Number)?.toDouble() ?: 0.0,
                            eqHighDb = (eq?.get("highDb") as? Number)?.toDouble() ?: 0.0,
                            fadeInMs = (m["fadeInMs"] as? Number)?.toDouble() ?: 0.0,
                            fadeOutMs = (m["fadeOutMs"] as? Number)?.toDouble() ?: 0.0,
                            fadeKind = (m["fadeKind"] as? String) ?: "linear",
                            isVoiceForDuck = (m["isVoice"] as? Boolean) ?: false,
                        )
                    }
                    if (parsed.isEmpty()) {
                        result.error("ARG", "no valid tracks", null); return
                    }
                    mixer.mix(parsed, outPath, targetLufs, result)
                }
                "normalize" -> {
                    val path = call.argument<String>("path")
                    val outPath = call.argument<String>("outPath")
                    if (path.isNullOrEmpty() || outPath.isNullOrEmpty()) {
                        result.error("ARG", "path+outPath required", null); return
                    }
                    val targetLufs = (call.argument<Number>("targetLufs"))?.toDouble() ?: -14.0
                    normalizer.normalize(path, outPath, targetLufs, result)
                }
                "detectBeats" -> {
                    val path = call.argument<String>("path")
                    if (path.isNullOrEmpty()) {
                        result.error("ARG", "path required", null); return
                    }
                    beats.detect(path, result)
                }
                "pitchShift" -> {
                    val path = call.argument<String>("path")
                    val outPath = call.argument<String>("outPath")
                    val semitones = (call.argument<Number>("semitones"))?.toDouble() ?: 0.0
                    if (path.isNullOrEmpty() || outPath.isNullOrEmpty()) {
                        result.error("ARG", "path+outPath required", null); return
                    }
                    stretch.pitchShift(path, semitones, outPath, result)
                }
                "timeStretch" -> {
                    val path = call.argument<String>("path")
                    val outPath = call.argument<String>("outPath")
                    val factor = (call.argument<Number>("factor"))?.toDouble() ?: 1.0
                    val keepPitch = call.argument<Boolean>("keepPitch") ?: false
                    if (path.isNullOrEmpty() || outPath.isNullOrEmpty()) {
                        result.error("ARG", "path+outPath required", null); return
                    }
                    stretch.timeStretch(path, factor, keepPitch, outPath, result)
                }
                else -> result.notImplemented()
            }
        } catch (t: Throwable) {
            result.error("MINIS_AUDIO", t.message, null)
        }
    }

    private fun notImpl(result: MethodChannel.Result, method: String, anchor: String) {
        result.error(
            "NOT_IMPLEMENTED",
            "$method deferred (see improvement4.md $anchor)",
            null
        )
    }

    private fun parseEnv(raw: Any?): List<Pair<Double, Double>> {
        if (raw == null) return emptyList()
        val list = raw as? List<*> ?: return emptyList()
        val out = ArrayList<Pair<Double, Double>>(list.size)
        for (entry in list) {
            if (entry is List<*> && entry.size >= 2) {
                val t = (entry[0] as? Number)?.toDouble()
                val g = (entry[1] as? Number)?.toDouble()
                if (t != null && g != null) out.add(t to g)
            } else if (entry is Map<*, *>) {
                val t = (entry["timeMs"] as? Number)?.toDouble()
                val g = (entry["gain"] as? Number)?.toDouble()
                if (t != null && g != null) out.add(t to g)
            }
        }
        return out
    }

    companion object {
        @JvmStatic
        fun attach(binding: FlutterPlugin.FlutterPluginBinding): MinisAudioPlugin {
            return MinisAudioPlugin(
                binding.applicationContext,
                binding.binaryMessenger,
            )
        }
    }
}
