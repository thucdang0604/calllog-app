package com.example.call_log_manager

import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.media.MediaMuxer
import android.util.Log
import java.io.File
import java.nio.ByteBuffer

internal object CallRecordingTrimmer {
    private const val TAG = "CallRecTrimmer"
    private const val MIN_TRIMMED_BYTES = 1024L
    private const val MIN_TRIMMED_DURATION_MS = 400L

    /**
     * Cắt bỏ đoạn đầu [0 .. startOffsetMs] khỏi file M4A/AAC mà không giải mã/nén lại.
     * Trả về thời lượng (ms) của file kết quả nếu cắt thành công, hoặc null nếu thất bại.
     */
    fun trimFromOffset(srcFile: File, dstFile: File, startOffsetMs: Long): Long? {
        if (!srcFile.exists() || srcFile.length() <= MIN_TRIMMED_BYTES || startOffsetMs <= 0L) {
            return null
        }

        val extractor = MediaExtractor()
        var muxer: MediaMuxer? = null
        var muxerStarted = false
        var sampleCount = 0

        return try {
            extractor.setDataSource(srcFile.absolutePath)

            var audioTrackIndex = -1
            var audioFormat: MediaFormat? = null
            for (i in 0 until extractor.trackCount) {
                val format = extractor.getTrackFormat(i)
                val mime = format.getString(MediaFormat.KEY_MIME) ?: continue
                if (mime.startsWith("audio/")) {
                    audioTrackIndex = i
                    audioFormat = format
                    break
                }
            }

            if (audioTrackIndex == -1 || audioFormat == null) {
                Log.w(TAG, "Không tìm thấy track audio trong ${srcFile.name}")
                return null
            }

            dstFile.parentFile?.let { parent ->
                if (!parent.exists()) parent.mkdirs()
            }
            if (dstFile.exists()) {
                dstFile.delete()
            }

            extractor.selectTrack(audioTrackIndex)
            val trimStartUs = startOffsetMs * 1000L
            extractor.seekTo(trimStartUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)

            val maxInput = if (audioFormat.containsKey(MediaFormat.KEY_MAX_INPUT_SIZE)) {
                maxOf(256 * 1024, audioFormat.getInteger(MediaFormat.KEY_MAX_INPUT_SIZE))
            } else {
                256 * 1024
            }
            val buffer = ByteBuffer.allocateDirect(maxInput)
            val bufferInfo = MediaCodec.BufferInfo()

            muxer = MediaMuxer(dstFile.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
            val dstTrackIndex = muxer.addTrack(audioFormat)
            muxer.start()
            muxerStarted = true

            var firstPtsUs = -1L
            var lastWrittenPtsUs = -1L

            while (true) {
                buffer.clear()
                val sampleSize = extractor.readSampleData(buffer, 0)
                if (sampleSize < 0) break

                val sampleTimeUs = extractor.sampleTime
                if (sampleTimeUs < 0L || sampleTimeUs < trimStartUs) {
                    extractor.advance()
                    continue
                }

                if (firstPtsUs < 0L) {
                    firstPtsUs = sampleTimeUs
                }
                val rawRebasedPtsUs = (sampleTimeUs - firstPtsUs).coerceAtLeast(0L)
                val monotonicPtsUs = if (lastWrittenPtsUs < 0L) {
                    rawRebasedPtsUs
                } else {
                    maxOf(rawRebasedPtsUs, lastWrittenPtsUs + 1L)
                }

                bufferInfo.offset = 0
                bufferInfo.size = sampleSize
                bufferInfo.presentationTimeUs = monotonicPtsUs
                @Suppress("DEPRECATION")
                bufferInfo.flags = extractor.sampleFlags

                muxer.writeSampleData(dstTrackIndex, buffer, bufferInfo)
                lastWrittenPtsUs = monotonicPtsUs
                sampleCount++
                extractor.advance()
            }

            if (sampleCount == 0) {
                try { dstFile.delete() } catch (_: Exception) {}
                return null
            }

            muxer.stop()
            muxerStarted = false
            muxer.release()
            muxer = null

            if (!dstFile.exists() || dstFile.length() <= MIN_TRIMMED_BYTES) {
                try { dstFile.delete() } catch (_: Exception) {}
                return null
            }

            val finalDurMs = measureDurationMs(dstFile)
            if (finalDurMs < MIN_TRIMMED_DURATION_MS) {
                try { dstFile.delete() } catch (_: Exception) {}
                return null
            }

            finalDurMs
        } catch (e: Exception) {
            Log.w(TAG, "Lỗi cắt đoạn chờ chuông khỏi file ${srcFile.name}: ${e.message}")
            try {
                if (dstFile.exists()) dstFile.delete()
            } catch (_: Exception) {}
            null
        } finally {
            if (muxer != null) {
                if (muxerStarted && sampleCount > 0) {
                    try { muxer.stop() } catch (_: Exception) {}
                }
                try { muxer.release() } catch (_: Exception) {}
            }
            try { extractor.release() } catch (_: Exception) {}
        }
    }

    fun measureDurationMs(file: File, fallbackMs: Long = 0L): Long {
        val retriever = MediaMetadataRetriever()
        return try {
            retriever.setDataSource(file.absolutePath)
            val durStr = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
            durStr?.toLongOrNull()?.takeIf { it > 0L } ?: fallbackMs
        } catch (_: Exception) {
            fallbackMs
        } finally {
            try { retriever.release() } catch (_: Exception) {}
        }
    }
}
