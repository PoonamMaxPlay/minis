package com.loopit.minis.videdit

import android.content.Context
import android.content.Intent
import android.media.MediaExtractor
import android.media.MediaFormat
import android.os.Build
import android.os.Bundle
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.atomic.AtomicReference

/**
 * On-device speech recognition driver. The clip's audio track is first
 * resampled to 16 kHz mono PCM (handed off to the native FFmpeg side via
 * `pan=mono|c0=0.5*FL+0.5*FR,aresample=16000`); the resulting WAV is fed
 * into `SpeechRecognizer` set to offline mode and the partial / final
 * results are mapped into timed caption cues.
 */
class AutoCaptioner(private val context: Context) {

  data class Cue(val startMs: Long, val endMs: Long, val text: String)

  fun caption(audioWav: File, lang: String = "en-US"): List<Cue> {
    if (Build.VERSION.SDK_INT < 31 || !SpeechRecognizer.isOnDeviceRecognitionAvailable(context)) {
      return emptyList()
    }
    val latch = CountDownLatch(1)
    val resultRef = AtomicReference<List<Cue>>(emptyList())
    val recognizer = SpeechRecognizer.createOnDeviceSpeechRecognizer(context)
    val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
      putExtra(RecognizerIntent.EXTRA_LANGUAGE_PREFERENCE, lang)
      putExtra(RecognizerIntent.EXTRA_LANGUAGE, lang)
      putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
      putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
      putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_ENCODING,
          android.media.AudioFormat.ENCODING_PCM_16BIT)
      putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_SAMPLING_RATE, 16000)
      putExtra(RecognizerIntent.EXTRA_AUDIO_SOURCE_CHANNEL_COUNT, 1)
    }

    val cues = mutableListOf<Cue>()
    val startNs = System.nanoTime()
    recognizer.setRecognitionListener(object : RecognitionListener {
      override fun onPartialResults(bundle: Bundle) {
        val text = bundle.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
            ?.firstOrNull() ?: return
        val now = (System.nanoTime() - startNs) / 1_000_000
        cues.add(Cue(startMs = now, endMs = now + 2_000, text = text))
      }
      override fun onResults(bundle: Bundle) {
        val text = bundle.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
            ?.firstOrNull().orEmpty()
        val end = (System.nanoTime() - startNs) / 1_000_000
        if (text.isNotEmpty()) cues.add(Cue(startMs = 0, endMs = end, text = text))
        resultRef.set(coalesce(cues))
        latch.countDown()
      }
      override fun onError(error: Int) { latch.countDown() }
      override fun onReadyForSpeech(params: Bundle?) {}
      override fun onBeginningOfSpeech() {}
      override fun onRmsChanged(rmsdB: Float) {}
      override fun onBufferReceived(buffer: ByteArray?) {}
      override fun onEndOfSpeech() {}
      override fun onEvent(eventType: Int, params: Bundle?) {}
    })

    recognizer.startListening(intent)
    latch.await()
    recognizer.destroy()
    return resultRef.get()
  }

  private fun coalesce(cues: List<Cue>): List<Cue> {
    if (cues.isEmpty()) return cues
    val out = mutableListOf<Cue>()
    var current = cues.first()
    for (c in cues.drop(1)) {
      if (c.startMs - current.endMs < 1500) {
        current = current.copy(endMs = c.endMs, text = "${current.text} ${c.text}".trim())
      } else {
        out.add(current); current = c
      }
    }
    out.add(current)
    return out
  }

  fun toSrt(cues: List<Cue>): String {
    val sb = StringBuilder()
    cues.forEachIndexed { i, c ->
      sb.append(i + 1).append('\n')
      sb.append(formatTime(c.startMs)).append(" --> ").append(formatTime(c.endMs)).append('\n')
      sb.append(c.text).append("\n\n")
    }
    return sb.toString()
  }

  private fun formatTime(ms: Long): String {
    val h = ms / 3_600_000
    val m = (ms / 60_000) % 60
    val s = (ms / 1000) % 60
    val mss = ms % 1000
    return "%02d:%02d:%02d,%03d".format(h, m, s, mss)
  }
}
