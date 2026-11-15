package com.example.call_log_manager

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Settings
import android.telephony.TelephonyManager
import android.util.Log
import androidx.core.content.ContextCompat
import java.util.concurrent.CopyOnWriteArraySet

internal object CallRecorderCoordinator {
    private const val TAG = "CallRecorderCoord"
    private const val CALL_TYPE_INCOMING = 1
    private const val CALL_TYPE_OUTGOING = 2

    enum class RecordingUiStatus {
        IDLE,
        STARTING,
        RECORDING,
        SILENCED,
        ERROR
    }

    data class RecordingUiState(
        val isCallOffhook: Boolean,
        val status: RecordingUiStatus,
        val startedAtMs: Long,
        val phoneNumber: String,
        val errorMessage: String? = null,
        val audioSource: String = "",
        val hasSignal: Boolean = false
    )

    interface RecordingStateListener {
        fun onRecordingStateChanged(state: RecordingUiState)
    }

    private var currentState = TelephonyManager.CALL_STATE_IDLE
    private var hadRinging = false
    private var pendingPhoneNumber = ""
    private var currentSessionId = 0L
    private var ringStartedAtMs = 0L
    private var offhookStartedAtMs = 0L

    private var uiStatus = RecordingUiStatus.IDLE
    private var recordingStartedAtMs = 0L
    private var lastErrorMessage: String? = null
    private var activeAudioSource: String = ""
    private var hasLiveSignal: Boolean = false
    private var overlayPillActive = false

    private val listeners = CopyOnWriteArraySet<RecordingStateListener>()

    fun addListener(listener: RecordingStateListener) {
        listeners.add(listener)
        listener.onRecordingStateChanged(currentUiState())
    }

    fun removeListener(listener: RecordingStateListener) {
        listeners.remove(listener)
    }

    @Synchronized
    fun currentUiState(): RecordingUiState {
        return RecordingUiState(
            isCallOffhook = currentState == TelephonyManager.CALL_STATE_OFFHOOK,
            status = uiStatus,
            startedAtMs = recordingStartedAtMs,
            phoneNumber = pendingPhoneNumber,
            errorMessage = lastErrorMessage,
            audioSource = activeAudioSource,
            hasSignal = hasLiveSignal
        )
    }

    @Synchronized
    fun onCallStateChanged(context: Context, state: Int, rawNumber: String?) {
        val appContext = context.applicationContext
        val cleanNumber = rawNumber?.trim() ?: ""
        if (cleanNumber.isNotEmpty()) {
            pendingPhoneNumber = cleanNumber
            if (currentState == TelephonyManager.CALL_STATE_OFFHOOK && CallRecorderService.isRunning) {
                val updateIntent = Intent(appContext, CallRecorderService::class.java).apply {
                    action = CallRecorderService.ACTION_UPDATE_META
                    putExtra(CallRecorderService.EXTRA_PHONE_NUMBER, cleanNumber)
                }
                try {
                    appContext.startService(updateIntent)
                } catch (_: Exception) {}
            }
        }

        when (state) {
            TelephonyManager.CALL_STATE_RINGING -> {
                if (currentState == TelephonyManager.CALL_STATE_IDLE) {
                    currentSessionId++
                    ringStartedAtMs = System.currentTimeMillis()
                    CallRecordingPostProcessor.captureSessionBaseline(appContext, currentSessionId)
                }
                hadRinging = true
                currentState = TelephonyManager.CALL_STATE_RINGING
            }

            TelephonyManager.CALL_STATE_OFFHOOK -> {
                if (currentState == TelephonyManager.CALL_STATE_OFFHOOK) {
                    notifyListeners()
                    return
                }
                if (currentState == TelephonyManager.CALL_STATE_IDLE) {
                    currentSessionId++
                    ringStartedAtMs = 0L
                    CallRecordingPostProcessor.captureSessionBaseline(appContext, currentSessionId)
                }
                offhookStartedAtMs = System.currentTimeMillis()
                currentState = TelephonyManager.CALL_STATE_OFFHOOK
                uiStatus = RecordingUiStatus.IDLE
                recordingStartedAtMs = 0L
                lastErrorMessage = null

                // Ghi âm chủ động theo từng cuộc gọi: KHÔNG tự bật micro khi OFFHOOK,
                // chỉ hiển thị nút nổi Ghi âm để người dùng chủ động bấm nếu muốn ghi âm.
                showInCallOverlayPill(appContext)
                notifyListeners()
            }

            TelephonyManager.CALL_STATE_IDLE -> {
                val wasOffhook = currentState == TelephonyManager.CALL_STATE_OFFHOOK
                currentState = TelephonyManager.CALL_STATE_IDLE
                hadRinging = false
                pendingPhoneNumber = ""
                ringStartedAtMs = 0L
                offhookStartedAtMs = 0L

                if (wasOffhook || CallRecorderService.isRunning) {
                    stopManualRecording(appContext, stoppedByUserWhileInCall = false)
                }
                hideInCallOverlayPill(appContext)
                uiStatus = RecordingUiStatus.IDLE
                recordingStartedAtMs = 0L
                lastErrorMessage = null
                notifyListeners()
            }
        }
    }

    @Synchronized
    fun toggleManualRecording(context: Context) {
        val appContext = context.applicationContext
        if (currentState != TelephonyManager.CALL_STATE_OFFHOOK) {
            lastErrorMessage = "Chỉ bật ghi âm khi đang trong cuộc gọi"
            uiStatus = RecordingUiStatus.ERROR
            notifyListeners()
            return
        }
        when (uiStatus) {
            RecordingUiStatus.STARTING -> return
            RecordingUiStatus.RECORDING,
            RecordingUiStatus.SILENCED -> stopManualRecording(appContext, stoppedByUserWhileInCall = true)
            RecordingUiStatus.IDLE,
            RecordingUiStatus.ERROR -> startManualRecording(appContext, fromTrampoline = false)
        }
    }

    @Synchronized
    fun startManualRecording(context: Context, fromTrampoline: Boolean = false) {
        val appContext = context.applicationContext
        if (currentState != TelephonyManager.CALL_STATE_OFFHOOK) {
            return
        }

        val hasAudioPerm = ContextCompat.checkSelfPermission(
            appContext,
            Manifest.permission.RECORD_AUDIO
        ) == PackageManager.PERMISSION_GRANTED
        if (!hasAudioPerm) {
            Log.w(TAG, "Thiếu quyền RECORD_AUDIO nên không thể ghi âm")
            uiStatus = RecordingUiStatus.ERROR
            recordingStartedAtMs = 0L
            lastErrorMessage = "Chưa cấp quyền Micro trong ứng dụng"
            activeAudioSource = ""
            hasLiveSignal = false
            notifyListeners()
            return
        }

        uiStatus = RecordingUiStatus.STARTING
        lastErrorMessage = null
        activeAudioSource = ""
        hasLiveSignal = false
        notifyListeners()

        // Trên Android 10+, bật micro từ overlay service (không có Activity visible) thường khiến
        // AppOps/AudioFlinger gán trạng thái bị câm toàn bộ (isClientSilenced = true).
        // Mở Activity trong suốt thoáng qua trước để Service nhận quyền foreground TOP hợp lệ.
        if (!fromTrampoline && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            if (launchTrampolineActivity(appContext)) {
                return
            }
        }

        val callType = if (hadRinging) CALL_TYPE_INCOMING else CALL_TYPE_OUTGOING
        val startIntent = Intent(appContext, CallRecorderService::class.java).apply {
            action = CallRecorderService.ACTION_START
            putExtra(CallRecorderService.EXTRA_PHONE_NUMBER, pendingPhoneNumber)
            putExtra(CallRecorderService.EXTRA_CALL_TYPE, callType)
            putExtra(CallRecorderService.EXTRA_SESSION_ID, currentSessionId)
            putExtra(CallRecorderService.EXTRA_RING_STARTED_AT_MS, ringStartedAtMs)
            putExtra(CallRecorderService.EXTRA_OFFHOOK_STARTED_AT_MS, offhookStartedAtMs)
            putExtra(CallRecorderService.EXTRA_FROM_TRAMPOLINE, fromTrampoline)
        }
        try {
            ContextCompat.startForegroundService(appContext, startIntent)
        } catch (e: Exception) {
            Log.e(TAG, "Không thể khởi chạy CallRecorderService", e)
            if (!fromTrampoline) {
                onForegroundMicBlocked(appContext)
            } else {
                uiStatus = RecordingUiStatus.ERROR
                lastErrorMessage = "Không thể khởi động dịch vụ ghi âm"
                notifyListeners()
            }
        }
    }

    @Synchronized
    fun stopManualRecording(context: Context, stoppedByUserWhileInCall: Boolean) {
        val appContext = context.applicationContext
        val stopIntent = Intent(appContext, CallRecorderService::class.java).apply {
            action = CallRecorderService.ACTION_STOP
            putExtra(CallRecorderService.EXTRA_STOPPED_MID_CALL, stoppedByUserWhileInCall)
        }
        try {
            if (CallRecorderService.isRunning || uiStatus == RecordingUiStatus.STARTING) {
                appContext.startService(stopIntent)
            }
        } catch (_: Exception) {}
        if (!stoppedByUserWhileInCall) {
            uiStatus = RecordingUiStatus.IDLE
            recordingStartedAtMs = 0L
            lastErrorMessage = null
            activeAudioSource = ""
            hasLiveSignal = false
            notifyListeners()
        }
    }

    private fun launchTrampolineActivity(appContext: Context): Boolean {
        return try {
            val intent = Intent(appContext, CallRecordTrampolineActivity::class.java).apply {
                addFlags(
                    Intent.FLAG_ACTIVITY_NEW_TASK or
                        Intent.FLAG_ACTIVITY_NO_ANIMATION or
                        Intent.FLAG_ACTIVITY_EXCLUDE_FROM_RECENTS
                )
            }
            appContext.startActivity(intent)
            true
        } catch (e: Exception) {
            Log.w(TAG, "Không thể mở CallRecordTrampolineActivity", e)
            false
        }
    }

    fun onForegroundMicBlocked(context: Context) {
        val appContext = context.applicationContext
        if (!launchTrampolineActivity(appContext)) {
            notifyRecordingError("Hệ thống chặn mở micro từ nền")
        }
    }

    @Synchronized
    fun notifyRecordingStarted(
        startedAtMs: Long,
        audioSource: String = "",
        hasSignal: Boolean = false
    ) {
        recordingStartedAtMs = startedAtMs
        uiStatus = RecordingUiStatus.RECORDING
        lastErrorMessage = null
        activeAudioSource = audioSource
        hasLiveSignal = hasSignal
        notifyListeners()
    }

    @Synchronized
    fun notifyRecordingSignalUpdate(
        hasSignal: Boolean,
        isSilenced: Boolean,
        audioSource: String,
        reason: String? = null
    ) {
        if (uiStatus != RecordingUiStatus.RECORDING && uiStatus != RecordingUiStatus.SILENCED) {
            return
        }
        val nextStatus = if (isSilenced) RecordingUiStatus.SILENCED else RecordingUiStatus.RECORDING
        val nextReason = if (isSilenced) reason else null
        if (uiStatus != nextStatus ||
            hasLiveSignal != hasSignal ||
            activeAudioSource != audioSource ||
            lastErrorMessage != nextReason
        ) {
            uiStatus = nextStatus
            hasLiveSignal = hasSignal
            activeAudioSource = audioSource
            lastErrorMessage = nextReason
            notifyListeners()
        }
    }

    @Synchronized
    fun notifyRecordingStopped() {
        uiStatus = RecordingUiStatus.IDLE
        recordingStartedAtMs = 0L
        lastErrorMessage = null
        activeAudioSource = ""
        hasLiveSignal = false
        notifyListeners()
    }

    @Synchronized
    fun notifyRecordingError(message: String) {
        uiStatus = RecordingUiStatus.ERROR
        recordingStartedAtMs = 0L
        lastErrorMessage = message
        activeAudioSource = ""
        hasLiveSignal = false
        notifyListeners()
    }

    private fun showInCallOverlayPill(appContext: Context) {
        if (!Settings.canDrawOverlays(appContext)) {
            Log.w(TAG, "Thiếu quyền SYSTEM_ALERT_WINDOW nên không hiện nút ghi âm cuộc gọi")
            return
        }
        overlayPillActive = true
        val intent = Intent(appContext, FloatingWindowService::class.java).apply {
            action = FloatingWindowService.ACTION_SHOW_CALL_RECORD_PILL
        }
        try {
            if (FloatingWindowService.isServiceActive()) {
                appContext.startService(intent)
            } else {
                ContextCompat.startForegroundService(appContext, intent)
            }
        } catch (e: Exception) {
            Log.e(TAG, "Không thể hiện nút ghi âm nổi", e)
        }
    }

    private fun hideInCallOverlayPill(appContext: Context) {
        if (!overlayPillActive && !FloatingWindowService.isServiceActive()) {
            return
        }
        overlayPillActive = false
        val intent = Intent(appContext, FloatingWindowService::class.java).apply {
            action = FloatingWindowService.ACTION_HIDE_CALL_RECORD_PILL
        }
        try {
            if (FloatingWindowService.isServiceActive()) {
                appContext.startService(intent)
            }
        } catch (_: Exception) {}
    }

    private fun notifyListeners() {
        val snapshot = RecordingUiState(
            isCallOffhook = currentState == TelephonyManager.CALL_STATE_OFFHOOK,
            status = uiStatus,
            startedAtMs = recordingStartedAtMs,
            phoneNumber = pendingPhoneNumber,
            errorMessage = lastErrorMessage,
            audioSource = activeAudioSource,
            hasSignal = hasLiveSignal
        )
        for (listener in listeners) {
            try {
                listener.onRecordingStateChanged(snapshot)
            } catch (_: Exception) {}
        }
    }
}
