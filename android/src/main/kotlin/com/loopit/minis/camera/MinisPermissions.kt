package com.loopit.minis.camera

import android.Manifest
import android.content.pm.PackageManager
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.plugin.common.MethodChannel
import java.lang.ref.WeakReference
import java.util.concurrent.atomic.AtomicInteger

/**
 * Native permissions helper exposed on channel `loopit/minis/permissions`.
 * Methods: requestCamera, requestMicrophone, status -> map.
 */
class MinisPermissions {
    private var activityRef: WeakReference<FlutterFragmentActivity>? = null
    private val requestSeq = AtomicInteger(1000)
    private val pendingByCode = mutableMapOf<Int, MethodChannel.Result>()

    fun setActivity(activity: FlutterFragmentActivity?) {
        activityRef = activity?.let { WeakReference(it) }
    }

    private fun act(): FlutterFragmentActivity? = activityRef?.get()

    fun status(result: MethodChannel.Result) {
        val a = act() ?: run { result.error("NO_ACTIVITY", "Activity not set", null); return }
        result.success(
            mapOf(
                "camera" to has(a, Manifest.permission.CAMERA),
                "microphone" to has(a, Manifest.permission.RECORD_AUDIO),
            ),
        )
    }

    fun requestCamera(result: MethodChannel.Result) {
        requestOne(Manifest.permission.CAMERA, result)
    }

    fun requestMic(result: MethodChannel.Result) {
        requestOne(Manifest.permission.RECORD_AUDIO, result)
    }

    private fun requestOne(perm: String, result: MethodChannel.Result) {
        val a = act() ?: run { result.error("NO_ACTIVITY", "Activity not set", null); return }
        if (has(a, perm)) { result.success(true); return }
        val code = requestSeq.getAndIncrement()
        pendingByCode[code] = result
        ActivityCompat.requestPermissions(a, arrayOf(perm), code)
    }

    fun onRequestResult(requestCode: Int, grantResults: IntArray): Boolean {
        val r = pendingByCode.remove(requestCode) ?: return false
        val granted = grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
        r.success(granted)
        return true
    }

    private fun has(a: FlutterFragmentActivity, perm: String): Boolean =
        ContextCompat.checkSelfPermission(a, perm) == PackageManager.PERMISSION_GRANTED
}
