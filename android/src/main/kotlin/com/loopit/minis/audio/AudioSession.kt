package com.loopit.minis.audio

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build

/**
 * `audio_session` parity: configures AudioManager mode + AudioFocus.
 */
class AudioSession(context: Context) {
    private val audioManager =
        context.applicationContext.getSystemService(Context.AUDIO_SERVICE) as AudioManager

    private var lastCategory: String? = null
    private var lastFocusGain: Int = AudioManager.AUDIOFOCUS_GAIN
    private var lastAttrs: AudioAttributes? = null
    private var focusRequest: AudioFocusRequest? = null

    fun configure(
        category: String?,
        @Suppress("UNUSED_PARAMETER") categoryOptions: Int,
        @Suppress("UNUSED_PARAMETER") mode: String?,
        androidAttrs: Map<*, *>?,
        androidFocusGain: String?,
    ): Boolean {
        lastCategory = category
        lastAttrs = buildAttributes(androidAttrs)
        lastFocusGain = focusGainFromName(androidFocusGain)
        audioManager.mode = when (category) {
            "playAndRecord", "record" -> AudioManager.MODE_IN_COMMUNICATION
            else -> AudioManager.MODE_NORMAL
        }
        return true
    }

    fun setActive(active: Boolean): Boolean {
        return if (active) requestFocus() else abandonFocus()
    }

    fun release() {
        abandonFocus()
    }

    private fun requestFocus(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val attrs = lastAttrs ?: defaultAttrs()
            val req = AudioFocusRequest.Builder(lastFocusGain)
                .setAudioAttributes(attrs)
                .setOnAudioFocusChangeListener { /* no-op for now */ }
                .build()
            focusRequest = req
            return audioManager.requestAudioFocus(req) ==
                AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        }
        @Suppress("DEPRECATION")
        val res = audioManager.requestAudioFocus(
            null,
            AudioManager.STREAM_MUSIC,
            lastFocusGain,
        )
        return res == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
    }

    private fun abandonFocus(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val req = focusRequest ?: return true
            focusRequest = null
            return audioManager.abandonAudioFocusRequest(req) ==
                AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        }
        @Suppress("DEPRECATION")
        val res = audioManager.abandonAudioFocus(null)
        return res == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
    }

    private fun defaultAttrs(): AudioAttributes =
        AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_MEDIA)
            .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
            .build()

    private fun buildAttributes(map: Map<*, *>?): AudioAttributes {
        if (map == null) return defaultAttrs()
        val usage = when (map["usage"] as? String) {
            "voiceCommunication" -> AudioAttributes.USAGE_VOICE_COMMUNICATION
            "alarm" -> AudioAttributes.USAGE_ALARM
            "notification" -> AudioAttributes.USAGE_NOTIFICATION
            "game" -> AudioAttributes.USAGE_GAME
            "media" -> AudioAttributes.USAGE_MEDIA
            else -> AudioAttributes.USAGE_UNKNOWN
        }
        val content = when (map["contentType"] as? String) {
            "speech" -> AudioAttributes.CONTENT_TYPE_SPEECH
            "music" -> AudioAttributes.CONTENT_TYPE_MUSIC
            "movie" -> AudioAttributes.CONTENT_TYPE_MOVIE
            "sonification" -> AudioAttributes.CONTENT_TYPE_SONIFICATION
            else -> AudioAttributes.CONTENT_TYPE_UNKNOWN
        }
        return AudioAttributes.Builder()
            .setUsage(usage)
            .setContentType(content)
            .build()
    }

    private fun focusGainFromName(name: String?): Int = when (name) {
        "gainTransient" -> AudioManager.AUDIOFOCUS_GAIN_TRANSIENT
        "gainTransientMayDuck" -> AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK
        "gainTransientExclusive" -> AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_EXCLUSIVE
        else -> AudioManager.AUDIOFOCUS_GAIN
    }
}
