package com.loopit.minis.imgedit

/**
 * Mirrors the layer model from improvement2.md.
 *
 * The stack is ordered bottom-to-top; render code in `cpp/imgedit/pipeline.cpp`
 * walks it in order and composites each layer into the offscreen FBO.
 *
 * This Kotlin side stores layer params verbatim and forwards them to JNI on
 * every change — the C++ renderer is the source of truth for pixels.
 */
class LayerStack {

    enum class Kind { BASE_IMAGE, ADJUSTMENT, FILTER, STICKER, TEXT, DRAW, MASK, EMOJI }

    data class Layer(
        val id: Int,
        val kind: Kind,
        var params: Map<String, Any?>,
        var visible: Boolean = true,
        var opacity: Double = 1.0,
        var blend: String = "normal",
    )

    private val items = ArrayList<Layer>()
    private val adjust = HashMap<String, Double>()
    private var lutPath: String = ""
    private var lutIntensity: Double = 0.0
    private var crop: Map<String, Any?> = emptyMap()
    private var canvasWidth: Int = 0
    private var canvasHeight: Int = 0

    fun reset(w: Int, h: Int) {
        canvasWidth = w
        canvasHeight = h
        items.clear()
        adjust.clear()
        lutPath = ""
        lutIntensity = 0.0
        crop = emptyMap()
        items += Layer(ImageEditEngine.nextLayerId(), Kind.BASE_IMAGE, emptyMap())
    }

    fun push(typeWire: String, params: Map<String, Any?>): Int {
        val kind = parseKind(typeWire)
        val layer = Layer(ImageEditEngine.nextLayerId(), kind, params)
        items += layer
        return layer.id
    }

    fun pushMask(maskHandle: Map<String, Any?>): Int {
        val layer = Layer(ImageEditEngine.nextLayerId(), Kind.MASK, maskHandle)
        items += layer
        return layer.id
    }

    fun update(id: Int, params: Map<String, Any?>): Map<String, Any?> {
        val layer = items.firstOrNull { it.id == id } ?: return emptyMap()
        val prev = layer.params
        layer.params = params
        return prev
    }

    fun remove(id: Int): Layer? {
        val idx = items.indexOfFirst { it.id == id }
        if (idx < 0) return null
        return items.removeAt(idx)
    }

    fun reorder(id: Int, target: Int): Int {
        val from = items.indexOfFirst { it.id == id }
        if (from < 0) return -1
        val layer = items.removeAt(from)
        val clamped = target.coerceIn(0, items.size)
        items.add(clamped, layer)
        return from
    }

    fun applyAdjust(key: String, value: Double) {
        adjust[key] = value
    }

    fun applyFilter(lutPath: String, intensity: Double) {
        this.lutPath = lutPath
        this.lutIntensity = intensity
    }

    fun applyCrop(rect: Map<String, Any?>, rotationDeg: Double, persp: List<Double>?) {
        crop = mapOf(
            "rect" to rect,
            "rotationDeg" to rotationDeg,
            "persp" to (persp ?: emptyList<Double>()),
        )
    }

    fun currentAdjust(key: String): Double = adjust[key] ?: 0.0
    fun currentLut(): String = lutPath
    fun currentLutIntensity(): Double = lutIntensity
    fun currentCrop(): Map<String, Any?> = crop

    fun snapshot(): Snapshot = Snapshot(
        layers = items.map { it.copy() },
        adjust = HashMap(adjust),
        lutPath = lutPath,
        lutIntensity = lutIntensity,
        crop = crop,
    )

    fun restore(snapshot: Snapshot) {
        items.clear()
        items.addAll(snapshot.layers)
        adjust.clear()
        adjust.putAll(snapshot.adjust)
        lutPath = snapshot.lutPath
        lutIntensity = snapshot.lutIntensity
        crop = snapshot.crop
    }

    data class Snapshot(
        val layers: List<Layer>,
        val adjust: Map<String, Double>,
        val lutPath: String,
        val lutIntensity: Double,
        val crop: Map<String, Any?>,
    )

    private fun parseKind(wire: String): Kind = when (wire) {
        "baseImage" -> Kind.BASE_IMAGE
        "adjustment" -> Kind.ADJUSTMENT
        "filter" -> Kind.FILTER
        "sticker" -> Kind.STICKER
        "text" -> Kind.TEXT
        "draw" -> Kind.DRAW
        "mask" -> Kind.MASK
        "emoji" -> Kind.EMOJI
        else -> Kind.ADJUSTMENT
    }
}
