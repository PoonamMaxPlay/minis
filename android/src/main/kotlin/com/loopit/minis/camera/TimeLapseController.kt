package com.loopit.minis.camera

import android.content.Context
import android.graphics.BitmapFactory
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLSurface
import android.opengl.GLES20
import android.opengl.GLUtils
import android.opengl.Matrix
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.view.Surface
import androidx.camera.core.ImageCapture
import androidx.camera.core.ImageCaptureException
import androidx.core.content.ContextCompat
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Interval shutter: takes a still every [intervalMs] until [durationMs] elapses.
 * After capture phase finishes, [stitchToMp4] encodes staged JPEGs into a single
 * MP4 via MediaCodec (h264) + MediaMuxer using EGL+GLES texture upload as input.
 */
class TimeLapseController {
    private val thread = HandlerThread("MinisTimeLapse").apply { start() }
    private val handler = Handler(thread.looper)
    private val running = AtomicBoolean(false)

    private var imageCapture: ImageCapture? = null
    private var startedAt = 0L
    private var durationMs = 0L
    private var intervalMs = 0L
    private var context: Context? = null
    private var outputDir: File? = null
    private val frames = mutableListOf<String>()
    private var onComplete: ((List<String>) -> Unit)? = null

    fun bind(ic: ImageCapture) { imageCapture = ic }

    fun framesCaptured(): List<String> = synchronized(frames) { frames.toList() }

    fun start(
        context: Context,
        intervalMs: Long,
        durationMs: Long,
        outputDir: File,
        onComplete: ((List<String>) -> Unit)? = null,
    ) {
        if (!running.compareAndSet(false, true)) return
        this.context = context
        this.intervalMs = intervalMs.coerceAtLeast(100)
        this.durationMs = durationMs.coerceAtLeast(this.intervalMs)
        this.outputDir = outputDir.also { it.mkdirs() }
        this.startedAt = System.currentTimeMillis()
        this.onComplete = onComplete
        synchronized(frames) { frames.clear() }
        handler.post(loop)
    }

    fun stop() {
        if (!running.compareAndSet(true, false)) return
        handler.removeCallbacksAndMessages(null)
        val list = framesCaptured()
        onComplete?.invoke(list)
        onComplete = null
    }

    private val loop = object : Runnable {
        override fun run() {
            if (!running.get()) return
            val now = System.currentTimeMillis()
            if (now - startedAt > durationMs) { stop(); return }
            takeOne()
            handler.postDelayed(this, intervalMs)
        }
    }

    private fun takeOne() {
        val ic = imageCapture ?: return
        val ctx = context ?: return
        val dir = outputDir ?: return
        val file = File(dir, "minis_tl_${System.currentTimeMillis()}.jpg")
        val opts = ImageCapture.OutputFileOptions.Builder(file).build()
        ic.takePicture(opts, ContextCompat.getMainExecutor(ctx), object : ImageCapture.OnImageSavedCallback {
            override fun onImageSaved(output: ImageCapture.OutputFileResults) {
                synchronized(frames) { frames.add(file.absolutePath) }
            }
            override fun onError(exception: ImageCaptureException) {
                Log.w(TAG, "tl capture: ${exception.message}")
            }
        })
    }

    fun release() {
        stop()
        thread.quitSafely()
    }

    /**
     * Encode all staged JPEGs into a single MP4 using MediaCodec (h264) with an
     * EGL input surface. Frames render as textured quads at [fps]. Called on
     * the supplied [executor]; reports completion via [onDone] with the output
     * path on success or null on failure.
     */
    fun stitchToMp4(
        outPath: String,
        fps: Int = 30,
        keepStagedJpegs: Boolean = false,
        executor: java.util.concurrent.Executor,
        onDone: (String?) -> Unit,
    ) {
        executor.execute {
            val frameList = framesCaptured()
            if (frameList.isEmpty()) { onDone(null); return@execute }
            val firstBmp = BitmapFactory.decodeFile(frameList.first())
            if (firstBmp == null) { onDone(null); return@execute }
            // Snap to even dims (h264 requires).
            val w = firstBmp.width and -2
            val h = firstBmp.height and -2
            firstBmp.recycle()
            var result: String? = null
            try {
                Mp4Stitcher(w, h, fps, frameList, outPath).run()
                if (!keepStagedJpegs) {
                    frameList.forEach { runCatching { File(it).delete() } }
                }
                result = outPath
            } catch (e: Exception) {
                Log.e(TAG, "stitch failed", e)
            }
            onDone(result)
        }
    }

    companion object { private const val TAG = "MinisTimeLapse" }
}

/**
 * Internal MediaCodec + EGL stitcher. Encodes a list of JPEG paths into H.264
 * AVC inside MP4. PTS = frameIdx * 1_000_000 / fps µs.
 */
private class Mp4Stitcher(
    private val width: Int,
    private val height: Int,
    private val fps: Int,
    private val jpegs: List<String>,
    private val outPath: String,
) {
    private var encoder: MediaCodec? = null
    private var muxer: MediaMuxer? = null
    private var muxerTrack = -1
    private var muxerStarted = false
    private var inputSurface: Surface? = null

    private var eglDisplay: EGLDisplay = EGL14.EGL_NO_DISPLAY
    private var eglContext: EGLContext = EGL14.EGL_NO_CONTEXT
    private var eglSurface: EGLSurface = EGL14.EGL_NO_SURFACE

    private var program = 0
    private var aPosLoc = 0
    private var aTexLoc = 0
    private var uMvpLoc = 0
    private var uTexLoc = 0
    private var quadVbo = 0
    private val mvp = FloatArray(16).also { Matrix.setIdentityM(it, 0) }

    fun run() {
        try {
            setupEncoder()
            setupEgl()
            setupProgram()
            val tex = createTexture()
            var idx = 0
            for (path in jpegs) {
                val bmp = BitmapFactory.decodeFile(path) ?: continue
                val scaled = if (bmp.width != width || bmp.height != height) {
                    android.graphics.Bitmap.createScaledBitmap(bmp, width, height, true).also { bmp.recycle() }
                } else bmp
                drainEncoder(false)
                GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)
                GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, tex)
                GLUtils.texImage2D(GLES20.GL_TEXTURE_2D, 0, scaled, 0)
                drawQuad(tex)
                val ptsNs = idx.toLong() * 1_000_000_000L / fps
                EGLExt.setPresentationTime(eglDisplay, eglSurface, ptsNs)
                EGL14.eglSwapBuffers(eglDisplay, eglSurface)
                scaled.recycle()
                idx++
            }
            encoder?.signalEndOfInputStream()
            drainEncoder(true)
        } finally {
            releaseAll()
        }
    }

    private fun setupEncoder() {
        val mime = "video/avc"
        val fmt = MediaFormat.createVideoFormat(mime, width, height).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            setInteger(MediaFormat.KEY_FRAME_RATE, fps)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
            setInteger(MediaFormat.KEY_BIT_RATE, width * height * 4)
        }
        val enc = MediaCodec.createEncoderByType(mime)
        enc.configure(fmt, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        inputSurface = enc.createInputSurface()
        enc.start()
        encoder = enc
        File(outPath).parentFile?.mkdirs()
        muxer = MediaMuxer(outPath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
    }

    private fun setupEgl() {
        eglDisplay = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
        val ver = IntArray(2)
        EGL14.eglInitialize(eglDisplay, ver, 0, ver, 1)
        val attribs = intArrayOf(
            EGL14.EGL_RED_SIZE, 8,
            EGL14.EGL_GREEN_SIZE, 8,
            EGL14.EGL_BLUE_SIZE, 8,
            EGL14.EGL_ALPHA_SIZE, 8,
            EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
            0x3142 /* EGL_RECORDABLE_ANDROID */, 1,
            EGL14.EGL_NONE,
        )
        val configs = arrayOfNulls<EGLConfig>(1)
        val nc = IntArray(1)
        EGL14.eglChooseConfig(eglDisplay, attribs, 0, configs, 0, 1, nc, 0)
        val ctxAttribs = intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE)
        eglContext = EGL14.eglCreateContext(eglDisplay, configs[0], EGL14.EGL_NO_CONTEXT, ctxAttribs, 0)
        val surfAttribs = intArrayOf(EGL14.EGL_NONE)
        eglSurface = EGL14.eglCreateWindowSurface(eglDisplay, configs[0], inputSurface!!, surfAttribs, 0)
        EGL14.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext)
        GLES20.glClearColor(0f, 0f, 0f, 1f)
        GLES20.glViewport(0, 0, width, height)
    }

    private fun setupProgram() {
        val vs = """
            attribute vec4 aPos;
            attribute vec2 aTex;
            uniform mat4 uMvp;
            varying vec2 vTex;
            void main() {
                gl_Position = uMvp * aPos;
                vTex = aTex;
            }
        """.trimIndent()
        val fs = """
            precision mediump float;
            varying vec2 vTex;
            uniform sampler2D uTex;
            void main() {
                gl_FragColor = texture2D(uTex, vTex);
            }
        """.trimIndent()
        program = link(vs, fs)
        aPosLoc = GLES20.glGetAttribLocation(program, "aPos")
        aTexLoc = GLES20.glGetAttribLocation(program, "aTex")
        uMvpLoc = GLES20.glGetUniformLocation(program, "uMvp")
        uTexLoc = GLES20.glGetUniformLocation(program, "uTex")
        // Quad: pos.x, pos.y, tex.u, tex.v. Tex flipped vertically (GL ↔ bitmap).
        val verts = floatArrayOf(
            -1f, -1f, 0f, 1f,
             1f, -1f, 1f, 1f,
            -1f,  1f, 0f, 0f,
             1f,  1f, 1f, 0f,
        )
        val bb = ByteBuffer.allocateDirect(verts.size * 4).order(ByteOrder.nativeOrder())
        bb.asFloatBuffer().put(verts).position(0)
        val ids = IntArray(1)
        GLES20.glGenBuffers(1, ids, 0)
        quadVbo = ids[0]
        GLES20.glBindBuffer(GLES20.GL_ARRAY_BUFFER, quadVbo)
        GLES20.glBufferData(GLES20.GL_ARRAY_BUFFER, verts.size * 4, bb, GLES20.GL_STATIC_DRAW)
    }

    private fun createTexture(): Int {
        val ids = IntArray(1)
        GLES20.glGenTextures(1, ids, 0)
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, ids[0])
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
        GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
        return ids[0]
    }

    private fun drawQuad(tex: Int) {
        GLES20.glUseProgram(program)
        GLES20.glBindBuffer(GLES20.GL_ARRAY_BUFFER, quadVbo)
        GLES20.glEnableVertexAttribArray(aPosLoc)
        GLES20.glVertexAttribPointer(aPosLoc, 2, GLES20.GL_FLOAT, false, 16, 0)
        GLES20.glEnableVertexAttribArray(aTexLoc)
        GLES20.glVertexAttribPointer(aTexLoc, 2, GLES20.GL_FLOAT, false, 16, 8)
        GLES20.glUniformMatrix4fv(uMvpLoc, 1, false, mvp, 0)
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, tex)
        GLES20.glUniform1i(uTexLoc, 0)
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
    }

    private fun drainEncoder(endOfStream: Boolean) {
        val enc = encoder ?: return
        val mux = muxer ?: return
        val info = MediaCodec.BufferInfo()
        val TIMEOUT_US = 10_000L
        while (true) {
            val outIndex = enc.dequeueOutputBuffer(info, TIMEOUT_US)
            if (outIndex == MediaCodec.INFO_TRY_AGAIN_LATER) {
                if (!endOfStream) return
            } else if (outIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                if (muxerStarted) throw IllegalStateException("format changed twice")
                muxerTrack = mux.addTrack(enc.outputFormat)
                mux.start()
                muxerStarted = true
            } else if (outIndex >= 0) {
                val buf = enc.getOutputBuffer(outIndex)
                if (buf != null && info.size > 0 && (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) == 0) {
                    if (muxerStarted) {
                        buf.position(info.offset)
                        buf.limit(info.offset + info.size)
                        mux.writeSampleData(muxerTrack, buf, info)
                    }
                }
                enc.releaseOutputBuffer(outIndex, false)
                if ((info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) return
            }
        }
    }

    private fun link(vsSrc: String, fsSrc: String): Int {
        val vs = compile(GLES20.GL_VERTEX_SHADER, vsSrc)
        val fs = compile(GLES20.GL_FRAGMENT_SHADER, fsSrc)
        val p = GLES20.glCreateProgram()
        GLES20.glAttachShader(p, vs)
        GLES20.glAttachShader(p, fs)
        GLES20.glLinkProgram(p)
        val ok = IntArray(1)
        GLES20.glGetProgramiv(p, GLES20.GL_LINK_STATUS, ok, 0)
        if (ok[0] == 0) {
            val log = GLES20.glGetProgramInfoLog(p)
            GLES20.glDeleteProgram(p)
            throw RuntimeException("link: $log")
        }
        return p
    }

    private fun compile(type: Int, src: String): Int {
        val s = GLES20.glCreateShader(type)
        GLES20.glShaderSource(s, src)
        GLES20.glCompileShader(s)
        val ok = IntArray(1)
        GLES20.glGetShaderiv(s, GLES20.GL_COMPILE_STATUS, ok, 0)
        if (ok[0] == 0) {
            val log = GLES20.glGetShaderInfoLog(s)
            GLES20.glDeleteShader(s)
            throw RuntimeException("shader: $log")
        }
        return s
    }

    private fun releaseAll() {
        runCatching { encoder?.stop() }
        runCatching { encoder?.release() }
        encoder = null
        runCatching { if (muxerStarted) muxer?.stop() }
        runCatching { muxer?.release() }
        muxer = null
        runCatching { inputSurface?.release() }
        inputSurface = null
        if (eglDisplay != EGL14.EGL_NO_DISPLAY) {
            EGL14.eglMakeCurrent(eglDisplay, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
            if (eglSurface != EGL14.EGL_NO_SURFACE) EGL14.eglDestroySurface(eglDisplay, eglSurface)
            if (eglContext != EGL14.EGL_NO_CONTEXT) EGL14.eglDestroyContext(eglDisplay, eglContext)
            EGL14.eglTerminate(eglDisplay)
        }
        eglDisplay = EGL14.EGL_NO_DISPLAY
        eglContext = EGL14.EGL_NO_CONTEXT
        eglSurface = EGL14.EGL_NO_SURFACE
    }
}

/** Wrapper around the hidden `android.opengl.EGLExt.eglPresentationTimeANDROID`. */
private object EGLExt {
    fun setPresentationTime(display: EGLDisplay, surface: EGLSurface, nanos: Long) {
        try { android.opengl.EGLExt.eglPresentationTimeANDROID(display, surface, nanos) }
        catch (_: Throwable) { /* best-effort */ }
    }
}
