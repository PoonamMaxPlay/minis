package com.loopit.minis.imgedit

import android.graphics.BitmapFactory
import android.util.Log
import android.view.SurfaceHolder
import android.view.SurfaceView
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.atomic.AtomicInteger

/**
 * Per-viewId session — owns the GLES surface lifecycle, the [LayerStack],
 * and the [HistoryStack]. Channel calls arrive routed by viewId from
 * [ImageEditPluginRouter].
 *
 * Render graph (see `cpp/imgedit/pipeline.cpp`):
 *   BaseImageLayer → Adjustments → LUT → per-layer composite → Output FBO.
 */
class ImageEditEngine private constructor(
    val viewId: Int,
    private val surface: SurfaceView,
) : SurfaceHolder.Callback {

    private val tag = "MinisImgEdit"
    private val layers = LayerStack()
    private val history = HistoryStack()
    private var sourcePath: String? = null
    private var width: Int = 0
    private var height: Int = 0

    init {
        surface.holder.addCallback(this)
    }

    override fun surfaceCreated(holder: SurfaceHolder) {
        ImageEditNative.surfaceCreated(viewId, holder.surface)
    }

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, w: Int, h: Int) {
        ImageEditNative.surfaceChanged(viewId, w, h)
    }

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        ImageEditNative.surfaceDestroyed(viewId)
    }

    fun detach() {
        try {
            ImageEditNative.disposeView(viewId)
            ImageEditPluginRouter.unregister(viewId)
        } catch (t: Throwable) {
            Log.w(tag, "detach failed: ${t.message}")
        }
    }

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        val args = (call.arguments as? Map<*, *>) ?: emptyMap<Any, Any?>()
        when (call.method) {
            "init" -> result.success(handleInit(args))
            "dispose" -> {
                detach()
                result.success(null)
            }
            "pushLayer" -> {
                val type = args["type"] as? String ?: "adjustment"
                @Suppress("UNCHECKED_CAST")
                val params = (args["params"] as? Map<String, Any?>) ?: emptyMap()
                val id = layers.push(type, params)
                history.recordPush(id, type, params)
                ImageEditNative.requestRender(viewId)
                result.success(mapOf("layerId" to id))
            }
            "updateLayer" -> {
                val id = (args["layerId"] as? Number)?.toInt() ?: -1
                @Suppress("UNCHECKED_CAST")
                val params = (args["params"] as? Map<String, Any?>) ?: emptyMap()
                val prev = layers.update(id, params)
                history.recordUpdate(id, prev, params)
                ImageEditNative.requestRender(viewId)
                result.success(null)
            }
            "removeLayer" -> {
                val id = (args["layerId"] as? Number)?.toInt() ?: -1
                val removed = layers.remove(id)
                if (removed != null) history.recordRemove(id, removed)
                ImageEditNative.requestRender(viewId)
                result.success(null)
            }
            "reorderLayer" -> {
                val id = (args["layerId"] as? Number)?.toInt() ?: -1
                val index = (args["index"] as? Number)?.toInt() ?: 0
                val from = layers.reorder(id, index)
                history.recordReorder(id, from, index)
                ImageEditNative.requestRender(viewId)
                result.success(null)
            }
            "applyAdjust" -> {
                val key = args["key"] as? String ?: ""
                val value = (args["value"] as? Number)?.toDouble() ?: 0.0
                history.recordAdjust(key, layers.currentAdjust(key), value)
                layers.applyAdjust(key, value)
                ImageEditNative.applyAdjust(viewId, key, value)
                result.success(null)
            }
            "applyFilter" -> {
                val lutPath = args["lutPath"] as? String ?: ""
                val intensity = (args["intensity"] as? Number)?.toDouble() ?: 1.0
                history.recordFilter(layers.currentLut(), layers.currentLutIntensity(), lutPath, intensity)
                layers.applyFilter(lutPath, intensity)
                ImageEditNative.applyFilter(viewId, lutPath, intensity)
                result.success(null)
            }
            "applyCrop" -> {
                @Suppress("UNCHECKED_CAST")
                val rect = (args["rect"] as? Map<String, Any?>) ?: emptyMap()
                val rotation = (args["rotationDeg"] as? Number)?.toDouble() ?: 0.0
                @Suppress("UNCHECKED_CAST")
                val persp = args["persp"] as? List<Double>
                history.recordCrop(layers.currentCrop(), rect, rotation, persp)
                layers.applyCrop(rect, rotation, persp)
                ImageEditNative.applyCrop(viewId, rect, rotation, persp)
                result.success(null)
            }
            "brushStroke" -> {
                ImageEditNative.brushStroke(viewId, args)
                history.recordStroke(args)
                result.success(null)
            }
            "spotHeal" -> {
                ImageEditNative.spotHeal(viewId, args)
                history.recordHeal(args)
                result.success(null)
            }
            "liquify" -> {
                ImageEditNative.liquify(viewId, args)
                history.recordLiquify(args)
                result.success(null)
            }
            "beautify" -> {
                ImageEditNative.beautify(viewId, args)
                history.recordBeautify(args)
                result.success(null)
            }
            "removeBg" -> {
                val maskLayer = FaceDetector.runSelfieSegmentation(viewId, sourcePath)
                val id = layers.pushMask(maskLayer)
                history.recordPush(id, "mask", emptyMap())
                result.success(mapOf("maskLayerId" to id))
            }
            "placeText" -> {
                val params = args.castMap()
                val id = layers.push("text", params)
                history.recordPush(id, "text", params)
                ImageEditNative.requestRender(viewId)
                result.success(mapOf("layerId" to id))
            }
            "placeSticker" -> {
                val params = args.castMap()
                val id = layers.push("sticker", params)
                history.recordPush(id, "sticker", params)
                ImageEditNative.requestRender(viewId)
                result.success(mapOf("layerId" to id))
            }
            "placeEmoji" -> {
                val params = args.castMap()
                val id = layers.push("emoji", params)
                history.recordPush(id, "emoji", params)
                ImageEditNative.requestRender(viewId)
                result.success(mapOf("layerId" to id))
            }
            "undo" -> {
                history.undo(layers)
                ImageEditNative.requestRender(viewId)
                result.success(mapOf("canUndo" to history.canUndo(), "canRedo" to history.canRedo()))
            }
            "redo" -> {
                history.redo(layers)
                ImageEditNative.requestRender(viewId)
                result.success(mapOf("canUndo" to history.canUndo(), "canRedo" to history.canRedo()))
            }
            "setHistoryCap" -> {
                val mb = (args["mb"] as? Number)?.toLong() ?: 64L
                history.setMemoryCap(mb * 1024L * 1024L)
                result.success(mapOf("capBytes" to history.memoryCap()))
            }
            "exportImage" -> {
                val format = args["format"] as? String ?: "jpeg"
                val quality = (args["quality"] as? Number)?.toInt() ?: 92
                val maxDim = (args["maxDim"] as? Number)?.toInt()
                val path = args["path"] as? String ?: ""
                val exported = Exporter.write(
                    viewId = viewId,
                    sourcePath = sourcePath,
                    layers = layers,
                    format = format,
                    quality = quality,
                    maxDim = maxDim,
                    path = path,
                )
                result.success(exported)
            }
            else -> result.notImplemented()
        }
    }

    private fun handleInit(args: Map<*, *>): Map<String, Any?> {
        val path = args["sourcePath"] as? String
        sourcePath = path
        val (w, h, exif) = decodeBounds(path)
        width = w
        height = h
        ImageEditNative.initSession(viewId, path, w, h)
        layers.reset(w, h)
        history.clear()
        ImageEditPluginRouter.notifyState(
            "init",
            mapOf("viewId" to viewId, "w" to w, "h" to h),
        )
        return mapOf(
            "viewId" to viewId,
            "w" to w,
            "h" to h,
            "exif" to exif,
        )
    }

    private fun decodeBounds(path: String?): Triple<Int, Int, Map<String, Any?>> {
        if (path.isNullOrEmpty()) return Triple(0, 0, emptyMap())
        val f = File(path)
        if (!f.exists()) return Triple(0, 0, emptyMap())
        val opts = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(path, opts)
        return Triple(
            opts.outWidth.coerceAtLeast(0),
            opts.outHeight.coerceAtLeast(0),
            emptyMap(),
        )
    }

    companion object {
        private val NEXT_LAYER_ID = AtomicInteger(1)

        fun create(viewId: Int, surface: SurfaceView, sourcePath: String?): ImageEditEngine {
            val engine = ImageEditEngine(viewId, surface)
            engine.sourcePath = sourcePath
            return engine
        }

        fun nextLayerId(): Int = NEXT_LAYER_ID.getAndIncrement()
    }
}

private fun Map<*, *>.castMap(): Map<String, Any?> {
    val out = HashMap<String, Any?>(size)
    for ((k, v) in this) {
        if (k is String) out[k] = v
    }
    return out
}
