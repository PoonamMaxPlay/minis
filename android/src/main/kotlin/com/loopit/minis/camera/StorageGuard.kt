package com.loopit.minis.camera

import android.os.Environment
import android.os.StatFs
import java.io.File

/**
 * Storage capacity guard. Refuses recording if free bytes < `safetyFactor * expected`.
 */
object StorageGuard {
    private const val SAFETY = 1.5

    /** Free bytes on the filesystem hosting [dir]. */
    fun freeBytes(dir: File): Long {
        val stat = StatFs(if (dir.exists()) dir.absolutePath else Environment.getDataDirectory().absolutePath)
        return stat.availableBlocksLong * stat.blockSizeLong
    }

    /**
     * @param expectedBytes upper bound on bytes the next recording will consume.
     * @return true if recording can safely proceed.
     */
    fun canRecord(dir: File, expectedBytes: Long): Boolean =
        freeBytes(dir).toDouble() >= expectedBytes * SAFETY

    /** Rough estimate from duration/bitrate. */
    fun expectedBytesFor(durationMs: Long, bitsPerSecond: Long): Long =
        (durationMs / 1000.0 * bitsPerSecond / 8.0).toLong()
}
