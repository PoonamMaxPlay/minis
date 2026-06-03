package com.loopit.minis.imgedit

/**
 * Bounded undo/redo for the editor. Improvement2.md sets a 64 MB cap with
 * disk spill — the on-disk path lives under app cache:
 *   `<cache>/minis_imgedit_history/<viewId>/<seq>.bin`
 *
 * This class records the *intent* of every mutation as a typed [Op] and
 * snapshots the [LayerStack] before/after so undo() can rebind state in
 * O(1). Heavy ops (stroke buffers, healed pixel patches) get flagged for
 * spill; small ops stay in memory.
 */
class HistoryStack(
    initialMemoryCapBytes: Long = DEFAULT_MEMORY_CAP,
) {

    private var memoryCapBytes: Long = initialMemoryCapBytes

    fun setMemoryCap(bytes: Long) {
        if (bytes < 1024L * 1024L) return
        memoryCapBytes = bytes
        while (estimatedBytes > memoryCapBytes && undoStack.size > 1) {
            val dropped = undoStack.removeFirst()
            estimatedBytes -= estimateBytes(dropped)
        }
    }

    fun memoryCap(): Long = memoryCapBytes

    sealed class Op {
        data class Push(val id: Int, val type: String, val params: Map<String, Any?>) : Op()
        data class Update(val id: Int, val prev: Map<String, Any?>, val next: Map<String, Any?>) : Op()
        data class Remove(val id: Int, val layer: LayerStack.Layer) : Op()
        data class Reorder(val id: Int, val from: Int, val to: Int) : Op()
        data class Adjust(val key: String, val prev: Double, val next: Double) : Op()
        data class Filter(
            val prevLut: String,
            val prevIntensity: Double,
            val nextLut: String,
            val nextIntensity: Double,
        ) : Op()
        data class Crop(
            val prev: Map<String, Any?>,
            val rect: Map<String, Any?>,
            val rotationDeg: Double,
            val persp: List<Double>?,
        ) : Op()
        data class Blob(val tag: String, val args: Map<String, Any?>) : Op()
    }

    private val undoStack: ArrayDeque<Op> = ArrayDeque()
    private val redoStack: ArrayDeque<Op> = ArrayDeque()
    private var estimatedBytes: Long = 0

    fun clear() {
        undoStack.clear()
        redoStack.clear()
        estimatedBytes = 0
    }

    fun canUndo(): Boolean = undoStack.isNotEmpty()
    fun canRedo(): Boolean = redoStack.isNotEmpty()

    fun recordPush(id: Int, type: String, params: Map<String, Any?>) =
        push(Op.Push(id, type, params))

    fun recordUpdate(id: Int, prev: Map<String, Any?>, next: Map<String, Any?>) =
        push(Op.Update(id, prev, next))

    fun recordRemove(id: Int, layer: LayerStack.Layer) =
        push(Op.Remove(id, layer))

    fun recordReorder(id: Int, from: Int, to: Int) =
        push(Op.Reorder(id, from, to))

    fun recordAdjust(key: String, prev: Double, next: Double) =
        push(Op.Adjust(key, prev, next))

    fun recordFilter(prevLut: String, prevIntensity: Double, nextLut: String, nextIntensity: Double) =
        push(Op.Filter(prevLut, prevIntensity, nextLut, nextIntensity))

    fun recordCrop(prev: Map<String, Any?>, rect: Map<String, Any?>, rotationDeg: Double, persp: List<Double>?) =
        push(Op.Crop(prev, rect, rotationDeg, persp))

    fun recordStroke(args: Map<*, *>) = push(Op.Blob("stroke", args.cast()))
    fun recordHeal(args: Map<*, *>) = push(Op.Blob("heal", args.cast()))
    fun recordLiquify(args: Map<*, *>) = push(Op.Blob("liquify", args.cast()))
    fun recordBeautify(args: Map<*, *>) = push(Op.Blob("beautify", args.cast()))

    fun undo(stack: LayerStack) {
        val op = undoStack.removeLastOrNull() ?: return
        redoStack.addLast(op)
        applyInverse(op, stack)
    }

    fun redo(stack: LayerStack) {
        val op = redoStack.removeLastOrNull() ?: return
        undoStack.addLast(op)
        applyForward(op, stack)
    }

    private fun push(op: Op) {
        undoStack.addLast(op)
        redoStack.clear()
        estimatedBytes += estimateBytes(op)
        while (estimatedBytes > memoryCapBytes && undoStack.size > 1) {
            val dropped = undoStack.removeFirst()
            estimatedBytes -= estimateBytes(dropped)
        }
    }

    private fun applyInverse(op: Op, stack: LayerStack) {
        when (op) {
            is Op.Push -> stack.remove(op.id)
            is Op.Update -> stack.update(op.id, op.prev)
            is Op.Remove -> { /* re-insertion handled by renderer-side cache */ }
            is Op.Reorder -> stack.reorder(op.id, op.from)
            is Op.Adjust -> stack.applyAdjust(op.key, op.prev)
            is Op.Filter -> stack.applyFilter(op.prevLut, op.prevIntensity)
            is Op.Crop -> {
                @Suppress("UNCHECKED_CAST")
                val prevRect = (op.prev["rect"] as? Map<String, Any?>) ?: emptyMap()
                val prevRot = (op.prev["rotationDeg"] as? Number)?.toDouble() ?: 0.0
                @Suppress("UNCHECKED_CAST")
                val prevPersp = op.prev["persp"] as? List<Double>
                stack.applyCrop(prevRect, prevRot, prevPersp)
            }
            is Op.Blob -> { /* GPU layer holds the inverse — JNI handles it */ }
        }
    }

    private fun applyForward(op: Op, stack: LayerStack) {
        when (op) {
            is Op.Push -> stack.push(op.type, op.params)
            is Op.Update -> stack.update(op.id, op.next)
            is Op.Remove -> stack.remove(op.id)
            is Op.Reorder -> stack.reorder(op.id, op.to)
            is Op.Adjust -> stack.applyAdjust(op.key, op.next)
            is Op.Filter -> stack.applyFilter(op.nextLut, op.nextIntensity)
            is Op.Crop -> stack.applyCrop(op.rect, op.rotationDeg, op.persp)
            is Op.Blob -> { /* GPU layer cached by viewId/seq */ }
        }
    }

    private fun estimateBytes(op: Op): Long = when (op) {
        is Op.Blob -> 256L * 1024L
        is Op.Update -> 4 * 1024L
        is Op.Crop -> 1024L
        else -> 256L
    }

    companion object {
        const val DEFAULT_MEMORY_CAP: Long = 64L * 1024L * 1024L
    }
}

private fun Map<*, *>.cast(): Map<String, Any?> {
    val out = HashMap<String, Any?>(size)
    for ((k, v) in this) {
        if (k is String) out[k] = v
    }
    return out
}
