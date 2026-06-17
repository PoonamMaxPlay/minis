package com.loopit.minis.imgedit

import android.content.Context
import android.util.Log
import org.json.JSONObject

/**
 * Enumerates bundled LUTs, sticker packs, and fonts.
 *
 * Reads:
 *   - `android/src/main/assets/luts/<id>.cube` — listed by stem
 *   - `android/src/main/assets/stickers/<pack_id>/manifest.json`
 *   - `android/src/main/assets/fonts/<family>.ttf`
 *
 * Resolution uses the [Context] supplied to [bind]; the router holds the
 * context for the lifetime of the editor session. If [bind] hasn't been
 * called yet, calls return safe defaults so the channel surface keeps
 * working.
 */
object AssetCatalog {

    private const val TAG = "MinisImgEditAssets"
    private var context: Context? = null

    fun bind(ctx: Context?) {
        context = ctx?.applicationContext
    }

    fun filters(): List<Map<String, Any?>> {
        val ctx = context ?: return listOf(stub("neutral", "Neutral"))
        return try {
            val names = ctx.assets.list("luts").orEmpty()
            val out = mutableListOf<Map<String, Any?>>()
            out += stub("neutral", "Neutral")
            for (name in names) {
                if (!name.endsWith(".cube")) continue
                val id = name.removeSuffix(".cube")
                out += mapOf(
                    "id" to id,
                    "label" to id.replaceFirstChar { it.uppercase() },
                    "lutPath" to "asset:luts/$name",
                )
            }
            out
        } catch (t: Throwable) {
            Log.w(TAG, "filters() failed: ${t.message}")
            listOf(stub("neutral", "Neutral"))
        }
    }

    fun stickerPacks(): List<Map<String, Any?>> {
        val ctx = context ?: return emptyList()
        return try {
            val packs = ctx.assets.list("stickers").orEmpty()
            val out = mutableListOf<Map<String, Any?>>()
            for (pack in packs) {
                val manifest = try {
                    ctx.assets.open("stickers/$pack/manifest.json").use { it.readBytes() }
                } catch (_: Throwable) { null }
                val json = manifest?.let { JSONObject(String(it)) }
                val label = json?.optString("label") ?: pack
                val itemsArr = json?.optJSONArray("items")
                val items = mutableListOf<Map<String, Any?>>()
                if (itemsArr != null) {
                    for (i in 0 until itemsArr.length()) {
                        val o = itemsArr.optJSONObject(i) ?: continue
                        items += mapOf(
                            "id" to o.optString("id"),
                            "w" to o.optInt("w"),
                            "h" to o.optInt("h"),
                            "path" to "asset:stickers/$pack/${o.optString("file")}",
                        )
                    }
                }
                out += mapOf(
                    "packId" to pack,
                    "displayName" to label,
                    "items" to items,
                )
            }
            out
        } catch (t: Throwable) {
            Log.w(TAG, "stickerPacks() failed: ${t.message}")
            emptyList()
        }
    }

    fun fonts(): List<Map<String, Any?>> {
        val ctx = context ?: return listOf(mapOf("family" to "system", "weights" to listOf("regular")))
        return try {
            val names = ctx.assets.list("fonts").orEmpty()
            val grouped = HashMap<String, MutableList<String>>()
            for (name in names) {
                if (!name.endsWith(".ttf") && !name.endsWith(".otf")) continue
                val stem = name.substringBeforeLast('.')
                val parts = stem.split('-')
                val family = parts.first()
                val weight = if (parts.size > 1) parts[1].lowercase() else "regular"
                grouped.getOrPut(family) { mutableListOf() }.add(weight)
            }
            grouped.map { (family, weights) ->
                mapOf("family" to family, "weights" to weights)
            } + mapOf("family" to "system", "weights" to listOf("regular"))
        } catch (t: Throwable) {
            Log.w(TAG, "fonts() failed: ${t.message}")
            listOf(mapOf("family" to "system", "weights" to listOf("regular")))
        }
    }

    private fun stub(id: String, label: String): Map<String, Any?> =
        mapOf("id" to id, "label" to label, "lutPath" to "")
}
