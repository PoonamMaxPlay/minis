package com.loopit.minis.imgedit

import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Single shared MethodChannel + EventChannel for the image editor. Every
 * Dart call carries a `viewId` argument; the router dispatches it to the
 * matching [ImageEditEngine].
 */
object ImageEditPluginRouter {
    private const val METHOD_NAME = "loopit/minis/imgedit"
    private const val EVENT_NAME = "loopit/minis/imgedit/state"

    private val engines = HashMap<Int, ImageEditEngine>()
    private var methodChannel: MethodChannel? = null
    private var eventChannel: EventChannel? = null
    private var stateSink: EventChannel.EventSink? = null

    fun attach(messenger: BinaryMessenger) {
        if (methodChannel != null) return
        val mc = MethodChannel(messenger, METHOD_NAME)
        mc.setMethodCallHandler { call, result -> dispatch(call, result) }
        methodChannel = mc
        val ec = EventChannel(messenger, EVENT_NAME)
        ec.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                stateSink = events
            }
            override fun onCancel(arguments: Any?) {
                stateSink = null
            }
        })
        eventChannel = ec
    }

    fun detach() {
        methodChannel?.setMethodCallHandler(null)
        methodChannel = null
        eventChannel?.setStreamHandler(null)
        eventChannel = null
        stateSink = null
        engines.values.toList().forEach { it.detach() }
        engines.clear()
    }

    fun register(engine: ImageEditEngine) {
        engines[engine.viewId] = engine
    }

    fun unregister(viewId: Int) {
        engines.remove(viewId)
    }

    fun notifyState(kind: String, payload: Map<String, Any?>) {
        val sink = stateSink ?: return
        val event = HashMap<String, Any?>(payload.size + 1)
        event["kind"] = kind
        event.putAll(payload)
        sink.success(event)
    }

    fun notifyRenderProgress(viewId: Int, pct: Double) =
        notifyState("renderProgress", mapOf("viewId" to viewId, "pct" to pct))

    fun notifyError(viewId: Int, code: String, message: String) =
        notifyState("error", mapOf("viewId" to viewId, "code" to code, "message" to message))

    fun notifyMemoryPressure(viewId: Int?, levelMb: Int) =
        notifyState("memoryPressure", mapOf("viewId" to viewId, "levelMb" to levelMb))

    private fun dispatch(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "listFilters" -> {
                result.success(mapOf("filters" to AssetCatalog.filters()))
                return
            }
            "listStickerPacks" -> {
                result.success(mapOf("packs" to AssetCatalog.stickerPacks()))
                return
            }
            "listFonts" -> {
                result.success(mapOf("fonts" to AssetCatalog.fonts()))
                return
            }
        }
        val args = call.arguments as? Map<*, *>
        val viewId = (args?.get("viewId") as? Number)?.toInt()
        val engine = viewId?.let { engines[it] } ?: engines.values.firstOrNull()
        if (engine == null) {
            result.success(emptyMap<String, Any?>())
            return
        }
        engine.handle(call, result)
    }
}
