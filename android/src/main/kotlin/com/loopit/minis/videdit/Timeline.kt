package com.loopit.minis.videdit

import org.json.JSONArray
import org.json.JSONObject

/**
 * Pure-Kotlin timeline model that the host process passes to the native
 * compositor and exporter. Three track lanes (video, audio, overlay), each
 * carrying ordered [Clip]s with optional [Transition]s between adjacent
 * clips.
 */
data class Clip(
    val id: String,
    val path: String,
    val trackIndex: Int,
    val inMs: Long,
    val outMs: Long,
    val positionMs: Long,
    val transform: Transform = Transform.IDENTITY,
    val speed: Double = 1.0,
    val keepPitch: Boolean = true,
    val lutPath: String? = null,
    val lutIntensity: Double = 1.0,
    val volume: Double = 1.0,
) {
  fun toJson(): JSONObject = JSONObject().apply {
    put("id", id); put("path", path); put("trackIndex", trackIndex)
    put("inMs", inMs); put("outMs", outMs); put("position", positionMs)
    put("transform", transform.toJson())
    put("speed", speed); put("keepPitch", keepPitch)
    if (lutPath != null) { put("lutPath", lutPath); put("lutIntensity", lutIntensity) }
    put("volume", volume)
  }
}

data class Transform(
    val translateX: Double = 0.0,
    val translateY: Double = 0.0,
    val scale: Double = 1.0,
    val rotateDeg: Double = 0.0,
    val cornerRadius: Double = 0.0,
    val mirrorH: Boolean = false,
    val mirrorV: Boolean = false,
) {
  companion object { val IDENTITY = Transform() }
  fun toJson(): JSONObject = JSONObject().apply {
    put("tx", translateX); put("ty", translateY); put("scale", scale)
    put("rot", rotateDeg); put("cornerRadius", cornerRadius)
    put("mirrorH", mirrorH); put("mirrorV", mirrorV)
  }
}

data class Transition(
    val id: String,
    val aId: String,
    val bId: String,
    val type: String,        // crossfade | dip | slide | push | zoom | glitch
    val durMs: Long,
)

data class Overlay(
    val id: String,
    val kind: String,        // text | sticker
    val params: Map<String, Any?>,
)

data class Timeline(
    val clips: List<Clip>,
    val transitions: List<Transition>,
    val overlays: List<Overlay>,
    val durationMs: Long,
) {
  fun toJson(): String {
    val o = JSONObject()
    o.put("clips", JSONArray().apply { clips.forEach { put(it.toJson()) } })
    o.put("transitions", JSONArray().apply {
      transitions.forEach {
        put(JSONObject().apply {
          put("id", it.id); put("aId", it.aId); put("bId", it.bId)
          put("type", it.type); put("durMs", it.durMs)
        })
      }
    })
    o.put("overlays", JSONArray().apply {
      overlays.forEach {
        put(JSONObject().apply {
          put("id", it.id); put("kind", it.kind)
          put("params", JSONObject(it.params))
        })
      }
    })
    o.put("durationMs", durationMs)
    return o.toString()
  }
}
