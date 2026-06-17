package com.loopit.minis.imgedit

import android.util.Log

/**
 * MLKit face landmarks + selfie segmentation. The MLKit deps are not yet
 * declared in `android/build.gradle` (improvement2 keeps the host gradle
 * dependency surface minimal until each feature lands); when the host app
 * pulls them in via its own gradle, the runtime reflection paths below
 * activate without recompiling the plugin.
 */
object FaceDetector {
    private const val TAG = "MinisImgEditFace"

    fun runFaceLandmarks(viewId: Int, sourcePath: String?): List<Map<String, Any?>> {
        if (sourcePath.isNullOrEmpty()) return emptyList()
        return try {
            val detector = mlkitFaceDetector() ?: return emptyList()
            ImageEditNative.runFaceLandmarks(viewId, sourcePath, detector)
        } catch (t: Throwable) {
            Log.w(TAG, "face landmarks unavailable: ${t.message}")
            emptyList()
        }
    }

    fun runSelfieSegmentation(viewId: Int, sourcePath: String?): Map<String, Any?> {
        if (sourcePath.isNullOrEmpty()) return mapOf("status" to "no_source")
        return try {
            val segmenter = mlkitSelfieSegmenter() ?: return mapOf("status" to "unavailable")
            ImageEditNative.runSelfieSegmentation(viewId, sourcePath, segmenter)
        } catch (t: Throwable) {
            Log.w(TAG, "selfie segmentation failed: ${t.message}")
            mapOf("status" to "error", "message" to (t.message ?: ""))
        }
    }

    private fun mlkitFaceDetector(): Any? = try {
        val opts = Class
            .forName("com.google.mlkit.vision.face.FaceDetectorOptions\$Builder")
            .getConstructor()
            .newInstance()
        Class.forName("com.google.mlkit.vision.face.FaceDetection")
            .getMethod("getClient",
                Class.forName("com.google.mlkit.vision.face.FaceDetectorOptions"))
            .invoke(null, opts)
    } catch (_: Throwable) {
        null
    }

    private fun mlkitSelfieSegmenter(): Any? = try {
        val opts = Class
            .forName("com.google.mlkit.vision.segmentation.selfie.SelfieSegmenterOptions\$Builder")
            .getConstructor()
            .newInstance()
        Class.forName("com.google.mlkit.vision.segmentation.Segmentation")
            .getMethod("getClient",
                Class.forName("com.google.mlkit.vision.segmentation.SegmenterOptions"))
            .invoke(null, opts)
    } catch (_: Throwable) {
        null
    }
}
