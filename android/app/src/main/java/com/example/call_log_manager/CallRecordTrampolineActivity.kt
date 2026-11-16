package com.example.call_log_manager

import android.app.Activity
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.WindowManager

/**
 * Activity trong suốt thoáng qua được mở chủ động khi người dùng bấm nút "Ghi âm" trên overlay
 * để Android 10–15 ghi nhận tiến trình đang ở trạng thái visible TOP khi bật micro foreground service.
 * Đợi service khởi động xong MediaRecorder (hoặc hết timeout an toàn) rồi tự đóng ngay.
 */
class CallRecordTrampolineActivity : Activity() {

    private var dispatched = false
    private var finishedScheduled = false
    private val mainHandler = Handler(Looper.getMainLooper())

    private val focusFallbackRunnable = Runnable {
        dispatchStartIfNeeded()
    }

    private val safetyTimeoutRunnable = Runnable {
        finishSafely()
    }

    private val delayedFinishRunnable = Runnable {
        finishSafely()
    }

    private val stateListener = object : CallRecorderCoordinator.RecordingStateListener {
        override fun onRecordingStateChanged(state: CallRecorderCoordinator.RecordingUiState) {
            if (!dispatched || finishedScheduled) return
            if (state.status != CallRecorderCoordinator.RecordingUiStatus.STARTING) {
                finishedScheduled = true
                // Giữ Activity thêm 250ms sau khi MediaRecorder.start() / probe ổn định.
                mainHandler.postDelayed(delayedFinishRunnable, 250L)
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED)
        }
        @Suppress("DEPRECATION")
        overridePendingTransition(0, 0)
    }

    override fun onResume() {
        super.onResume()
        if (!dispatched) {
            if (hasWindowFocus()) {
                dispatchStartIfNeeded()
            } else {
                mainHandler.postDelayed(focusFallbackRunnable, 220L)
            }
        }
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) {
            dispatchStartIfNeeded()
        }
    }

    private fun dispatchStartIfNeeded() {
        if (dispatched || isFinishing || isDestroyed) return
        dispatched = true
        mainHandler.removeCallbacks(focusFallbackRunnable)
        CallRecorderCoordinator.addListener(stateListener)
        CallRecorderCoordinator.startManualRecording(applicationContext, fromTrampoline = true)
        mainHandler.postDelayed(safetyTimeoutRunnable, 2400L)
    }

    override fun onDestroy() {
        mainHandler.removeCallbacks(focusFallbackRunnable)
        mainHandler.removeCallbacks(safetyTimeoutRunnable)
        mainHandler.removeCallbacks(delayedFinishRunnable)
        CallRecorderCoordinator.removeListener(stateListener)
        if (!dispatched &&
            CallRecorderCoordinator.currentUiState().status == CallRecorderCoordinator.RecordingUiStatus.STARTING
        ) {
            CallRecorderCoordinator.notifyRecordingError("Không kích hoạt được phiên micro")
        }
        super.onDestroy()
    }

    private fun finishSafely() {
        if (!isFinishing && !isDestroyed) {
            finish()
            @Suppress("DEPRECATION")
            overridePendingTransition(0, 0)
        }
    }

    override fun finish() {
        super.finish()
        @Suppress("DEPRECATION")
        overridePendingTransition(0, 0)
    }
}
