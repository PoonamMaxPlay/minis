package com.loopit.minis.imgedit

import android.content.Context
import android.graphics.Color
import android.view.Gravity
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.HorizontalScrollView
import android.widget.LinearLayout
import android.widget.TextView
import androidx.recyclerview.widget.GridLayoutManager
import androidx.recyclerview.widget.RecyclerView
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

/**
 * Native emoji keyboard PlatformView. ViewType `loopit/minis/emoji_picker`.
 *
 * Categories are hard-coded; ranges are pulled from Unicode 15.1 blocks.
 * Selections are emitted via the shared `loopit/minis/emoji_picker/selected`
 * MethodChannel (host method `emit`).
 */
class EmojiPickerViewFactory(
    private val messenger: BinaryMessenger,
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {

    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        return EmojiPickerView(context, viewId, messenger)
    }
}

private class EmojiPickerView(
    context: Context,
    viewId: Int,
    messenger: BinaryMessenger,
) : PlatformView {

    private val root: LinearLayout
    private val channel: MethodChannel =
        MethodChannel(messenger, "loopit/minis/emoji_picker/selected")
    private val prefs = context.getSharedPreferences("minis_emoji", Context.MODE_PRIVATE)

    init {
        root = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Color.parseColor("#101010"))
        }
        val tabs = HorizontalScrollView(context)
        val tabRow = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
        }
        val grid = RecyclerView(context).apply {
            layoutManager = GridLayoutManager(context, 8)
        }
        val adapter = EmojiAdapter(emoji = CATEGORIES.first().codepoints,
                                   onPick = ::emit)
        grid.adapter = adapter
        for ((idx, cat) in CATEGORIES.withIndex()) {
            val tv = TextView(context).apply {
                text = cat.label
                setTextColor(Color.WHITE)
                setPadding(24, 16, 24, 16)
                setOnClickListener {
                    val codes = if (cat.key == "recent") recents() else cat.codepoints
                    adapter.update(codes)
                }
            }
            if (idx == 0) tv.setBackgroundColor(Color.parseColor("#1F1F1F"))
            tabRow.addView(tv)
        }
        tabs.addView(tabRow,
            ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
            ))
        root.addView(tabs,
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
            ))
        root.addView(grid,
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                0, 1f,
            ))
    }

    override fun getView(): View = root

    override fun dispose() {}

    private fun emit(codePoint: Int) {
        channel.invokeMethod("emit", mapOf("codePoint" to codePoint))
        appendRecent(codePoint)
    }

    private fun recents(): IntArray =
        prefs.getString("recents", "")?.split(",")
            ?.mapNotNull { it.toIntOrNull() }?.toIntArray() ?: IntArray(0)

    private fun appendRecent(cp: Int) {
        val cur = recents().toMutableList()
        cur.remove(cp)
        cur.add(0, cp)
        val capped = cur.take(32)
        prefs.edit().putString("recents", capped.joinToString(",")).apply()
    }

    private data class Category(val key: String, val label: String, val codepoints: IntArray)

    companion object {
        private val SMILEYS = (0x1F600..0x1F64F).toList().toIntArray()
        private val ANIMALS = (0x1F400..0x1F43E).toList().toIntArray()
        private val FOOD    = (0x1F32D..0x1F37F).toList().toIntArray()
        private val TRAVEL  = (0x1F680..0x1F6C5).toList().toIntArray()
        private val OBJECTS = (0x1F4A0..0x1F4FF).toList().toIntArray()
        private val SYMBOLS = (0x2700..0x27BF).toList().toIntArray()
        private val FLAGS   = (0x1F1E6..0x1F1FF).toList().toIntArray()

        private val CATEGORIES = listOf(
            Category("recent",  "Recent",  IntArray(0)),
            Category("smileys", "Smileys", SMILEYS),
            Category("animals", "Animals", ANIMALS),
            Category("food",    "Food",    FOOD),
            Category("travel",  "Travel",  TRAVEL),
            Category("objects", "Objects", OBJECTS),
            Category("symbols", "Symbols", SYMBOLS),
            Category("flags",   "Flags",   FLAGS),
        )
    }
}

private class EmojiAdapter(
    private var emoji: IntArray,
    private val onPick: (Int) -> Unit,
) : RecyclerView.Adapter<EmojiAdapter.VH>() {

    fun update(next: IntArray) {
        emoji = next
        notifyDataSetChanged()
    }

    override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): VH {
        val tv = TextView(parent.context).apply {
            textSize = 28f
            gravity = Gravity.CENTER
            setPadding(8, 8, 8, 8)
        }
        return VH(tv)
    }

    override fun onBindViewHolder(holder: VH, position: Int) {
        val cp = emoji[position]
        holder.tv.text = String(Character.toChars(cp))
        holder.tv.setOnClickListener { onPick(cp) }
    }

    override fun getItemCount(): Int = emoji.size

    class VH(val tv: TextView) : RecyclerView.ViewHolder(tv)
}
