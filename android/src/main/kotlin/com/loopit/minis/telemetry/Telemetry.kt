package com.loopit.minis.telemetry

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Native side of `loopit/minis/telemetry`.
 *
 * Off by default. Hosts call `enable({sink: "log" | "stream"})` to turn it
 * on. Other engines inside the plugin (camera, videdit, audio, etc.) call
 * [Telemetry.publish] to emit events; this object holds the routing.
 *
 * Field scrubbing matches the Dart side allow-list — only structural
 * fields pass through, never paths/URIs/raw bytes.
 */
class Telemetry(messenger: BinaryMessenger) {

  private val main = Handler(Looper.getMainLooper())
  private val method = MethodChannel(messenger, "loopit/minis/telemetry")
  private val events = EventChannel(messenger, "loopit/minis/telemetry/events")
  private var eventSink: EventChannel.EventSink? = null

  init {
    instance = this

    method.setMethodCallHandler { call: MethodCall, result: MethodChannel.Result ->
      try {
        when (call.method) {
          "enable" -> {
            val sink = call.argument<String>("sink") ?: "log"
            enabled = true
            this.sinkMode = if (sink == "stream") SinkMode.STREAM else SinkMode.LOG
            result.success(null)
          }
          "disable" -> {
            enabled = false
            result.success(null)
          }
          "emit" -> {
            val name = call.argument<String>("name") ?: ""
            @Suppress("UNCHECKED_CAST")
            val raw = (call.argument<Map<String, Any?>>("fields") ?: emptyMap())
            publish(name, raw)
            result.success(null)
          }
          else -> result.notImplemented()
        }
      } catch (t: Throwable) {
        // Telemetry must never crash the host.
        result.error("telemetry-error", t.message, null)
      }
    }

    events.setStreamHandler(object : EventChannel.StreamHandler {
      override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
        eventSink = sink
      }
      override fun onCancel(arguments: Any?) { eventSink = null }
    })
  }

  fun dispose() {
    method.setMethodCallHandler(null)
    events.setStreamHandler(null)
    eventSink = null
    if (instance === this) {
      instance = null
    }
  }

  // ----------------------------- Routing ----------------------------- //

  private enum class SinkMode { LOG, STREAM }

  @Volatile private var enabled: Boolean = false
  @Volatile private var sinkMode: SinkMode = SinkMode.LOG

  private fun deliver(name: String, fields: Map<String, Any?>) {
    if (!enabled) return
    when (sinkMode) {
      SinkMode.LOG -> android.util.Log.i("MinisTelemetry", "$name $fields")
      SinkMode.STREAM -> {
        val payload = mapOf(
          "name" to name,
          "ts" to System.currentTimeMillis(),
          "fields" to fields,
        )
        main.post {
          try {
            eventSink?.success(payload)
          } catch (_: Throwable) {}
        }
      }
    }
  }

  companion object {
    @Volatile private var instance: Telemetry? = null

    /** Engines inside the plugin call this to emit a telemetry event. */
    @JvmStatic
    fun publish(name: String, fields: Map<String, Any?> = emptyMap()) {
      val ref = instance ?: return
      ref.deliver(name, scrub(fields))
    }

    private val ALLOW = setOf(
      "op", "kind", "durationMs", "pct", "fps", "codec", "profile",
      "width", "height", "sampleRate", "channels", "bitrateKbps",
      "thermal", "battery", "state", "result", "errorCode",
      "taskId", "segments", "count", "reason",
    )

    private fun scrub(input: Map<String, Any?>): Map<String, Any?> {
      val out = LinkedHashMap<String, Any?>(input.size)
      for ((k, v) in input) {
        if (k !in ALLOW) continue
        if (v is String && v.length > 64) continue
        out[k] = v
      }
      return out
    }
  }
}
