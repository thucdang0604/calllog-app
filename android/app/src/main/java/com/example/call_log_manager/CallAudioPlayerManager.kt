package com.example.call_log_manager

import android.media.AudioAttributes
import android.media.MediaPlayer
import android.os.Handler
import android.os.Looper
import android.util.Log
import java.io.File

internal object CallAudioPlayerManager {
    private const val TAG = "CallAudioPlayer"
    private val mainHandler = Handler(Looper.getMainLooper())
    private var mediaPlayer: MediaPlayer? = null
    private var currentFilePath: String? = null
    private var isPausedState = false
    private var lastDurationMs = 0

    private val progressRunnable = object : Runnable {
        override fun run() {
            val player = mediaPlayer ?: return
            try {
                if (player.isPlaying) {
                    val pos = player.currentPosition.coerceAtLeast(0)
                    val dur = player.duration.takeIf { it > 0 } ?: lastDurationMs
                    lastDurationMs = dur
                    CallRecordingEventBus.notifyPlayback("playing", currentFilePath, pos, dur)
                    mainHandler.postDelayed(this, 250L)
                }
            } catch (_: Exception) {}
        }
    }

    fun play(filePath: String): Map<String, Any?> {
        val file = File(filePath)
        if (!file.exists()) {
            throw IllegalStateException("File ghi âm không còn tồn tại.")
        }

        // Toggle resume if same paused file
        if (currentFilePath == filePath && isPausedState && mediaPlayer != null) {
            return resume()
        }

        releaseInternal(notify = false)

        val player = MediaPlayer()
        return try {
            player.setAudioAttributes(
                AudioAttributes.Builder()
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .build()
            )
            player.setDataSource(filePath)
            player.prepare()
            player.setOnCompletionListener { mp ->
                val dur = try { mp.duration.coerceAtLeast(0) } catch (_: Exception) { lastDurationMs }
                mainHandler.removeCallbacks(progressRunnable)
                isPausedState = false
                CallRecordingEventBus.notifyPlayback("completed", currentFilePath, dur, dur)
                releaseInternal(notify = false)
            }
            player.setOnErrorListener { _, what, extra ->
                Log.w(TAG, "MediaPlayer error what=$what extra=$extra")
                releaseInternal(notify = true)
                true
            }

            mediaPlayer = player
            currentFilePath = filePath
            isPausedState = false
            lastDurationMs = player.duration.coerceAtLeast(0)
            player.start()
            mainHandler.removeCallbacks(progressRunnable)
            mainHandler.post(progressRunnable)
            getState()
        } catch (e: Exception) {
            try { player.release() } catch (_: Exception) {}
            releaseInternal(notify = false)
            throw e
        }
    }

    fun pause(): Map<String, Any?> {
        val player = mediaPlayer ?: return getState()
        try {
            if (player.isPlaying) {
                player.pause()
                isPausedState = true
                mainHandler.removeCallbacks(progressRunnable)
                val pos = player.currentPosition.coerceAtLeast(0)
                val dur = player.duration.takeIf { it > 0 } ?: lastDurationMs
                CallRecordingEventBus.notifyPlayback("paused", currentFilePath, pos, dur)
            }
        } catch (_: Exception) {}
        return getState()
    }

    fun resume(): Map<String, Any?> {
        val player = mediaPlayer ?: return getState()
        try {
            if (!player.isPlaying) {
                player.start()
                isPausedState = false
                mainHandler.removeCallbacks(progressRunnable)
                mainHandler.post(progressRunnable)
            }
        } catch (_: Exception) {}
        return getState()
    }

    fun seekTo(positionMs: Int): Map<String, Any?> {
        val player = mediaPlayer ?: return getState()
        try {
            val dur = player.duration.takeIf { it > 0 } ?: lastDurationMs
            val clamped = positionMs.coerceIn(0, dur.coerceAtLeast(0))
            player.seekTo(clamped)
            CallRecordingEventBus.notifyPlayback(
                if (player.isPlaying) "playing" else "paused",
                currentFilePath,
                clamped,
                dur
            )
        } catch (_: Exception) {}
        return getState()
    }

    fun stop(): Map<String, Any?> {
        releaseInternal(notify = true)
        return getState()
    }

    fun getState(): Map<String, Any?> {
        val player = mediaPlayer
        val isPlaying = try { player?.isPlaying == true } catch (_: Exception) { false }
        val pos = try { player?.currentPosition?.coerceAtLeast(0) ?: 0 } catch (_: Exception) { 0 }
        val dur = try { player?.duration?.takeIf { it > 0 } ?: lastDurationMs } catch (_: Exception) { lastDurationMs }
        val status = when {
            player == null -> "stopped"
            isPlaying -> "playing"
            isPausedState -> "paused"
            else -> "stopped"
        }
        return mapOf(
            "status" to status,
            "filePath" to (currentFilePath ?: ""),
            "positionMs" to pos,
            "durationMs" to dur
        )
    }

    private fun releaseInternal(notify: Boolean) {
        mainHandler.removeCallbacks(progressRunnable)
        val oldPath = currentFilePath
        try {
            mediaPlayer?.stop()
        } catch (_: Exception) {}
        try {
            mediaPlayer?.release()
        } catch (_: Exception) {}
        mediaPlayer = null
        currentFilePath = null
        isPausedState = false
        lastDurationMs = 0
        if (notify) {
            CallRecordingEventBus.notifyPlayback("stopped", oldPath, 0, 0)
        }
    }
}

