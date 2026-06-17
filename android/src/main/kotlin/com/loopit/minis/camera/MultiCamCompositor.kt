package com.loopit.minis.camera

import android.graphics.SurfaceTexture
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLExt
import android.opengl.EGLSurface
import android.opengl.GLES11Ext
import android.opengl.GLES20
import android.opengl.Matrix
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.view.Surface
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.atomic.AtomicBoolean

/**
 * GL compositor + MediaCodec encoder that takes two camera preview streams via
 * [SurfaceTexture]s, lays them out per [layout], and writes a single MP4 file.
 *
 * Sub-quad NDC table:
 *   topLeft     (-1, 1) → (-0.5,  0.5)
 *   topRight    (0.5, 1) → (1.0,   0.5)
 *   bottomLeft  (-1, -0.5) → (-0.5, -1)
 *   bottomRight (0.5, -0.5) → (1.0, -1)
 *   pip25       (0.5, -0.5) → (1.0, -1)
 *   sideBySide  main (-1,1)→(0,-1) / secondary (0,1)→(1,-1)
 */
class MultiCamCompositor(
    private val width: Int,
    private val height: Int,
    private val fps: Int,
    private val outPath: String,
    private val layout: MultiCamController.Layout,
) {
    private val running = AtomicBoolean(false)
    private val glThread = HandlerThread("MinisPipGl").apply { start() }
    private val handler = Handler(glThread.looper)

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
    private val identity = FloatArray(16).also { Matrix.setIdentityM(it, 0) }
    private val texMatA = FloatArray(16)
    private val texMatB = FloatArray(16)

    private var texA = 0
    private var texB = 0
    private var surfTexA: SurfaceTexture? = null
    private var surfTexB: SurfaceTexture? = null
    private var primarySurface: Surface? = null
    private var secondarySurface: Surface? = null

    private var startNs = 0L
    private var frames = 0L
    private var pendingA = false
    private var pendingB = false

    fun start(onReady: (Boolean) -> Unit) {
        handler.post {
            try {
                setupEncoder()
                setupEgl()
                setupProgram()
                setupTextures()
                running.set(true)
                onReady(true)
                handler.post(renderTick)
            } catch (e: Exception) {
                Log.e(TAG, "start", e)
                onReady(false)
            }
        }
    }

    fun primaryInputSurface(): Surface? = primarySurface
    fun secondaryInputSurface(): Surface? = secondarySurface

    fun stop(onDone: (String?) -> Unit) {
        handler.post {
            running.set(false)
            try {
                encoder?.signalEndOfInputStream()
                drainEncoder(true)
            } catch (_: Exception) {}
            val ok = muxerStarted
            releaseAll()
            onDone(if (ok) outPath else null)
        }
    }

    private val renderTick = object : Runnable {
        override fun run() {
            if (!running.get()) return
            // Update textures if a frame arrived.
            if (pendingA) {
                surfTexA?.updateTexImage()
                surfTexA?.getTransformMatrix(texMatA)
                pendingA = false
            }
            if (pendingB) {
                surfTexB?.updateTexImage()
                surfTexB?.getTransformMatrix(texMatB)
                pendingB = false
            }
            drainEncoder(false)
            GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)
            drawTexture(texA, fullQuadVerts, texMatA)
            drawTexture(texB, subQuadVerts(layout), texMatB)
            val ptsNs = if (startNs == 0L) 0L else (System.nanoTime() - startNs)
            EGLExt.eglPresentationTimeANDROID(eglDisplay, eglSurface, ptsNs)
            EGL14.eglSwapBuffers(eglDisplay, eglSurface)
            if (startNs == 0L) startNs = System.nanoTime()
            frames++
            handler.postDelayed(this, (1000L / fps).coerceAtLeast(8))
        }
    }

    private val fullQuadVerts = floatArrayOf(
        // x, y, u, v
        -1f, -1f, 0f, 0f,
         1f, -1f, 1f, 0f,
        -1f,  1f, 0f, 1f,
         1f,  1f, 1f, 1f,
    )

    private fun subQuadVerts(l: MultiCamController.Layout): FloatArray {
        return when (l) {
            MultiCamController.Layout.TOP_LEFT -> floatArrayOf(
                -1f, 0.5f, 0f, 0f,
                -0.5f, 0.5f, 1f, 0f,
                -1f, 1f, 0f, 1f,
                -0.5f, 1f, 1f, 1f,
            )
            MultiCamController.Layout.TOP_RIGHT -> floatArrayOf(
                0.5f, 0.5f, 0f, 0f,
                1f, 0.5f, 1f, 0f,
                0.5f, 1f, 0f, 1f,
                1f, 1f, 1f, 1f,
            )
            MultiCamController.Layout.BOTTOM_LEFT -> floatArrayOf(
                -1f, -1f, 0f, 0f,
                -0.5f, -1f, 1f, 0f,
                -1f, -0.5f, 0f, 1f,
                -0.5f, -0.5f, 1f, 1f,
            )
            MultiCamController.Layout.BOTTOM_RIGHT -> floatArrayOf(
                0.5f, -1f, 0f, 0f,
                1f, -1f, 1f, 0f,
                0.5f, -0.5f, 0f, 1f,
                1f, -0.5f, 1f, 1f,
            )
            MultiCamController.Layout.SIDE_BY_SIDE -> floatArrayOf(
                0f, -1f, 0f, 0f,
                1f, -1f, 1f, 0f,
                0f, 1f, 0f, 1f,
                1f, 1f, 1f, 1f,
            )
        }
    }

    private fun setupEncoder() {
        val mime = "video/avc"
        val fmt = MediaFormat.createVideoFormat(mime, width, height).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            setInteger(MediaFormat.KEY_FRAME_RATE, fps)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
            setInteger(MediaFormat.KEY_BIT_RATE, width * height * 6)
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
            EGL14.EGL_RED_SIZE, 8, EGL14.EGL_GREEN_SIZE, 8, EGL14.EGL_BLUE_SIZE, 8, EGL14.EGL_ALPHA_SIZE, 8,
            EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
            0x3142, 1,
            EGL14.EGL_NONE,
        )
        val cfgs = arrayOfNulls<EGLConfig>(1)
        val nc = IntArray(1)
        EGL14.eglChooseConfig(eglDisplay, attribs, 0, cfgs, 0, 1, nc, 0)
        val ctxAttribs = intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE)
        eglContext = EGL14.eglCreateContext(eglDisplay, cfgs[0], EGL14.EGL_NO_CONTEXT, ctxAttribs, 0)
        val surfAttribs = intArrayOf(EGL14.EGL_NONE)
        eglSurface = EGL14.eglCreateWindowSurface(eglDisplay, cfgs[0], inputSurface!!, surfAttribs, 0)
        EGL14.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext)
        GLES20.glClearColor(0f, 0f, 0f, 1f)
        GLES20.glViewport(0, 0, width, height)
    }

    private fun setupProgram() {
        val vs = """
            attribute vec4 aPos;
            attribute vec4 aTex;
            uniform mat4 uMvp;
            varying vec2 vTex;
            void main() {
                gl_Position = aPos;
                vTex = (uMvp * aTex).xy;
            }
        """.trimIndent()
        val fs = """
            #extension GL_OES_EGL_image_external : require
            precision mediump float;
            varying vec2 vTex;
            uniform samplerExternalOES uTex;
            void main() {
                gl_FragColor = texture2D(uTex, vTex);
            }
        """.trimIndent()
        program = link(vs, fs)
        aPosLoc = GLES20.glGetAttribLocation(program, "aPos")
        aTexLoc = GLES20.glGetAttribLocation(program, "aTex")
        uMvpLoc = GLES20.glGetUniformLocation(program, "uMvp")
        uTexLoc = GLES20.glGetUniformLocation(program, "uTex")
        val ids = IntArray(1)
        GLES20.glGenBuffers(1, ids, 0)
        quadVbo = ids[0]
    }

    private fun setupTextures() {
        val ids = IntArray(2)
        GLES20.glGenTextures(2, ids, 0)
        texA = ids[0]; texB = ids[1]
        for (t in ids) {
            GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, t)
            GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
            GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
            GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
            GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
        }
        surfTexA = SurfaceTexture(texA).apply {
            setDefaultBufferSize(width, height)
            setOnFrameAvailableListener { pendingA = true }
        }
        surfTexB = SurfaceTexture(texB).apply {
            setDefaultBufferSize(width / 2, height / 2)
            setOnFrameAvailableListener { pendingB = true }
        }
        primarySurface = Surface(surfTexA)
        secondarySurface = Surface(surfTexB)
        Matrix.setIdentityM(texMatA, 0)
        Matrix.setIdentityM(texMatB, 0)
    }

    private fun drawTexture(texId: Int, quad: FloatArray, texMatrix: FloatArray) {
        GLES20.glUseProgram(program)
        val bb = ByteBuffer.allocateDirect(quad.size * 4).order(ByteOrder.nativeOrder())
        bb.asFloatBuffer().put(quad).position(0)
        GLES20.glBindBuffer(GLES20.GL_ARRAY_BUFFER, 0)
        GLES20.glEnableVertexAttribArray(aPosLoc)
        bb.position(0)
        GLES20.glVertexAttribPointer(aPosLoc, 2, GLES20.GL_FLOAT, false, 16, bb)
        GLES20.glEnableVertexAttribArray(aTexLoc)
        bb.position(2)
        GLES20.glVertexAttribPointer(aTexLoc, 2, GLES20.GL_FLOAT, false, 16, bb)
        GLES20.glUniformMatrix4fv(uMvpLoc, 1, false, texMatrix, 0)
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, texId)
        GLES20.glUniform1i(uTexLoc, 0)
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
    }

    private fun drainEncoder(endOfStream: Boolean) {
        val enc = encoder ?: return
        val mux = muxer ?: return
        val info = MediaCodec.BufferInfo()
        while (true) {
            val outIndex = enc.dequeueOutputBuffer(info, 5000)
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
        GLES20.glAttachShader(p, vs); GLES20.glAttachShader(p, fs); GLES20.glLinkProgram(p)
        val ok = IntArray(1)
        GLES20.glGetProgramiv(p, GLES20.GL_LINK_STATUS, ok, 0)
        if (ok[0] == 0) { val l = GLES20.glGetProgramInfoLog(p); GLES20.glDeleteProgram(p); throw RuntimeException("link: $l") }
        return p
    }

    private fun compile(type: Int, src: String): Int {
        val s = GLES20.glCreateShader(type); GLES20.glShaderSource(s, src); GLES20.glCompileShader(s)
        val ok = IntArray(1); GLES20.glGetShaderiv(s, GLES20.GL_COMPILE_STATUS, ok, 0)
        if (ok[0] == 0) { val l = GLES20.glGetShaderInfoLog(s); GLES20.glDeleteShader(s); throw RuntimeException("shader: $l") }
        return s
    }

    private fun releaseAll() {
        runCatching { encoder?.stop() }
        runCatching { encoder?.release() }; encoder = null
        runCatching { if (muxerStarted) muxer?.stop() }
        runCatching { muxer?.release() }; muxer = null
        runCatching { inputSurface?.release() }; inputSurface = null
        runCatching { primarySurface?.release() }; primarySurface = null
        runCatching { secondarySurface?.release() }; secondarySurface = null
        runCatching { surfTexA?.release() }; surfTexA = null
        runCatching { surfTexB?.release() }; surfTexB = null
        if (eglDisplay != EGL14.EGL_NO_DISPLAY) {
            EGL14.eglMakeCurrent(eglDisplay, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
            if (eglSurface != EGL14.EGL_NO_SURFACE) EGL14.eglDestroySurface(eglDisplay, eglSurface)
            if (eglContext != EGL14.EGL_NO_CONTEXT) EGL14.eglDestroyContext(eglDisplay, eglContext)
            EGL14.eglTerminate(eglDisplay)
        }
        eglDisplay = EGL14.EGL_NO_DISPLAY
        eglContext = EGL14.EGL_NO_CONTEXT
        eglSurface = EGL14.EGL_NO_SURFACE
        glThread.quitSafely()
    }

    companion object { private const val TAG = "MinisPipComposite" }
}
