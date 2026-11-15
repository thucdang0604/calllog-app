package com.example.call_log_manager

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel

internal object CallRecordingEventBus {
    private val mainHandler = Handler(Looper.getMainLooper())
    @Volatile
    private var eventSink: EventChannel.EventSink? = null

    fun setEventSink(sink: EventChannel.EventSink?) {
        eventSink = sink
    }

    fun notifyRecordingsUpdated() {
        mainHandler.post {
            eventSink?.success(
                mapOf("type" to "recordings_updated")
            )
        }
    }

    fun notifyPlayback(
        status: String,
        filePath: String?,
        positionMs: Int,
        durationMs: Int
    ) {
        mainHandler.post {
            eventSink?.success(
                mapOf(
                    "type" to "playback",
                    "status" to status,
                    "filePath" to (filePath ?: ""),
                    "positionMs" to positionMs,
                    "durationMs" to durationMs
                )
            )
        }
    }
}

