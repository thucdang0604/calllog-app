package com.example.call_log_manager

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.AudioManager
import android.media.AudioRecordingConfiguration
import android.media.MediaRecorder
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log
import java.io.File

class CallRecorderService : Service() {

    companion object {
        private const val TAG = "CallRecorderService"
        private const val CHANNEL_ID = "call_recording_channel"
        private const val NOTIFICATION_ID = 2001
        private const val START_DELAY_MS = 50L
        private const val RETRY_DELAY_MS = 400L
        private const val INITIAL_PROBE_DELAY_MS = 180L
        private const val SIGNAL_MONITOR_INTERVAL_MS = 500L
        private const val SILENT_TICKS_THRESHOLD = 5
        private const val MIN_VALID_FILE_BYTES = 1024L

        const val ACTION_START = "com.example.call_log_manager.action.START_CALL_REC"
        const val ACTION_STOP = "com.example.call_log_manager.action.STOP_CALL_REC"
        const val ACTION_UPDATE_META = "com.example.call_log_manager.action.UPDATE_CALL_META"
        const val EXTRA_PHONE_NUMBER = "phone_number"
        const val EXTRA_CALL_TYPE = "call_type"
        const val EXTRA_SESSION_ID = "session_id"
        const val EXTRA_RING_STARTED_AT_MS = "ring_started_at_ms"
        const val EXTRA_OFFHOOK_STARTED_AT_MS = "offhook_started_at_ms"
        const val EXTRA_FROM_TRAMPOLINE = "from_trampoline"
        const val EXTRA_STOPPED_MID_CALL = "stopped_mid_call"

        @Volatile
        var isRunning: Boolean = false
            private set
    }

    private val mainHandler = Handler(Looper.getMainLooper())

    private var mediaRecorder: MediaRecorder? = null
    private var outputFile: File? = null
    private var startedAtMs: Long = 0L
    private var activeSessionId: Long = 0L
    private var activeRingStartedAtMs: Long = 0L
    private var activeOffhookStartedAtMs: Long = 0L
    private var activeRecordId: String = ""
    private var activePhoneNumber: String = ""
    private var activeCallType: Int = 1
    private var usedAudioSourceInt: Int = MediaRecorder.AudioSource.MIC
    private var usedAudioSourceName: String = "MIC"
    private var isRecordingActive: Boolean = false
    private var retryAttempted: Boolean = false
    private var initialProbeSettled: Boolean = false
    private var peakAmplitudeSeen: Int = -1
    private var zeroAmplitudeTicks: Int = 0
    private var lastSystemSilenced: Boolean = false
    private var activeCandidates: List<Pair<Int, String>> = emptyList()
    private val attemptedSourcesLog = ArrayList<String>()

    private var pendingStartRunnable: Runnable? = null
    private var initialProbeRunnable: Runnable? = null
    private var signalMonitorRunnable: Runnable? = null
    private var audioRecordingCallback: Any? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.action
        when (action) {
            ACTION_START -> {
                val number = intent.getStringExtra(EXTRA_PHONE_NUMBER)?.trim() ?: ""
                val callType = intent.getIntExtra(EXTRA_CALL_TYPE, 1)
                val sessionId = intent.getLongExtra(EXTRA_SESSION_ID, 0L)
                val ringStartedAtMs = intent.getLongExtra(EXTRA_RING_STARTED_AT_MS, 0L)
                val offhookStartedAtMs = intent.getLongExtra(EXTRA_OFFHOOK_STARTED_AT_MS, 0L)
                val fromTrampoline = intent.getBooleanExtra(EXTRA_FROM_TRAMPOLINE, false)

                if (number.isNotEmpty()) {
                    activePhoneNumber = number
                }
                activeCallType = callType
                if (!isRecordingActive && pendingStartRunnable == null) {
                    activeSessionId = sessionId
                    activeRingStartedAtMs = ringStartedAtMs
                    activeOffhookStartedAtMs = offhookStartedAtMs
                }

                if (!startForegroundMicrophoneSafe(fromTrampoline)) {
                    isRunning = false
                    stopSelf()
                    return START_NOT_STICKY
                }
                isRunning = true

                if (!isRecordingActive && pendingStartRunnable == null) {
                    retryAttempted = false
                    if (fromTrampoline) {
                        // Khởi chạy ngay trong khi CallRecordTrampolineActivity còn đang ở trạng thái TOP.
                        beginRecording(0)
                    } else {
                        val runnable = Runnable {
                            pendingStartRunnable = null
                            beginRecording(0)
                        }
                        pendingStartRunnable = runnable
                        mainHandler.postDelayed(runnable, START_DELAY_MS)
                    }
                }
            }

            ACTION_UPDATE_META -> {
                val number = intent.getStringExtra(EXTRA_PHONE_NUMBER)?.trim() ?: ""
                if (number.isNotEmpty() && activePhoneNumber.isEmpty()) {
                    activePhoneNumber = number
                }
            }

            ACTION_STOP -> {
                val stoppedMidCall = intent.getBooleanExtra(EXTRA_STOPPED_MID_CALL, false)
                stopAndFinalize(stoppedMidCall = stoppedMidCall)
            }

            else -> {
                stopAndFinalize(stoppedMidCall = false)
            }
        }
        return START_NOT_STICKY
    }

    private fun startForegroundMicrophoneSafe(fromTrampoline: Boolean): Boolean {
        return try {
            ensureNotificationChannel()
            val launchIntent = packageManager.getLaunchIntentForPackage(packageName)?.apply {
                addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
            }
            val pendingIntent = if (launchIntent != null) {
                val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                PendingIntent.getActivity(this, 201, launchIntent, flags)
            } else {
                null
            }

            val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Notification.Builder(this, CHANNEL_ID)
            } else {
                @Suppress("DEPRECATION")
                Notification.Builder(this)
            }

            val title = "Đang ghi âm cuộc gọi"
            val body = if (activePhoneNumber.isNotEmpty()) {
                "Số: $activePhoneNumber · Bấm Dừng hoặc gác máy để lưu"
            } else {
                "Bấm Dừng trên màn hình hoặc gác máy để lưu"
            }

            builder.setContentTitle(title)
                .setContentText(body)
                .setSmallIcon(android.R.drawable.ic_btn_speak_now)
                .setOngoing(true)

            if (pendingIntent != null) {
                builder.setContentIntent(pendingIntent)
            }

            val notification = builder.build()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
            true
        } catch (se: SecurityException) {
            Log.w(TAG, "Hệ thống từ chối startForeground MICROPHONE (fromTrampoline=$fromTrampoline)", se)
            if (!fromTrampoline) {
                CallRecorderCoordinator.onForegroundMicBlocked(applicationContext)
            } else {
                CallRecorderCoordinator.notifyRecordingError("Android chặn micro nền lúc này")
            }
            false
        } catch (e: Exception) {
            Log.e(TAG, "Không thể bật foreground service ghi âm", e)
            CallRecorderCoordinator.notifyRecordingError("Không thể khởi động ghi âm")
            false
        }
    }

    private fun ensureNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Ghi âm cuộc gọi",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Thông báo trạng thái khi ghi âm cuộc gọi chủ động"
                setShowBadge(false)
            }
            val manager = getSystemService(NotificationManager::class.java)
            manager?.createNotificationChannel(channel)
        }
    }

    private fun getAudioSourceCandidates(): List<Pair<Int, String>> {
        val unprocessedPair = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            MediaRecorder.AudioSource.UNPROCESSED to "UNPROCESSED"
        } else {
            null
        }
        return when (CallRecordingStore.getAudioSourcePref(this)) {
            "voice_call" -> buildList {
                add(MediaRecorder.AudioSource.VOICE_CALL to "VOICE_CALL")
                add(MediaRecorder.AudioSource.MIC to "MIC")
                add(MediaRecorder.AudioSource.CAMCORDER to "CAMCORDER")
                add(MediaRecorder.AudioSource.VOICE_RECOGNITION to "VOICE_RECOGNITION")
                add(MediaRecorder.AudioSource.VOICE_COMMUNICATION to "VOICE_COMMUNICATION")
                unprocessedPair?.let(::add)
            }
            "camcorder" -> listOf(
                MediaRecorder.AudioSource.CAMCORDER to "CAMCORDER",
                MediaRecorder.AudioSource.MIC to "MIC",
                MediaRecorder.AudioSource.VOICE_RECOGNITION to "VOICE_RECOGNITION"
            )
            "mic" -> listOf(
                MediaRecorder.AudioSource.MIC to "MIC",
                MediaRecorder.AudioSource.CAMCORDER to "CAMCORDER",
                MediaRecorder.AudioSource.VOICE_RECOGNITION to "VOICE_RECOGNITION"
            )
            "voice_recognition" -> listOf(
                MediaRecorder.AudioSource.VOICE_RECOGNITION to "VOICE_RECOGNITION",
                MediaRecorder.AudioSource.MIC to "MIC",
                MediaRecorder.AudioSource.CAMCORDER to "CAMCORDER"
            )
            "voice_communication" -> listOf(
                MediaRecorder.AudioSource.VOICE_COMMUNICATION to "VOICE_COMMUNICATION",
                MediaRecorder.AudioSource.MIC to "MIC",
                MediaRecorder.AudioSource.CAMCORDER to "CAMCORDER",
                MediaRecorder.AudioSource.VOICE_RECOGNITION to "VOICE_RECOGNITION"
            )
            "unprocessed" -> buildList {
                unprocessedPair?.let(::add)
                add(MediaRecorder.AudioSource.MIC to "MIC")
                add(MediaRecorder.AudioSource.CAMCORDER to "CAMCORDER")
            }
            else -> buildList {
                // Không dùng Trợ năng: ưu tiên MIC & CAMCORDER trước vì VOICE_RECOGNITION/VOICE_COMMUNICATION
                // thường bị AudioPolicy hoặc DSP cuộc gọi khử tiếng / câm khi MODE_IN_CALL.
                add(MediaRecorder.AudioSource.MIC to "MIC")
                add(MediaRecorder.AudioSource.CAMCORDER to "CAMCORDER")
                add(MediaRecorder.AudioSource.VOICE_RECOGNITION to "VOICE_RECOGNITION")
                add(MediaRecorder.AudioSource.VOICE_COMMUNICATION to "VOICE_COMMUNICATION")
                unprocessedPair?.let(::add)
            }
        }
    }

    private fun beginRecording(candidateStartIndex: Int = 0) {
        if (isRecordingActive) return

        val candidates = if (candidateStartIndex > 0 && activeCandidates.isNotEmpty()) {
            activeCandidates
        } else {
            attemptedSourcesLog.clear()
            getAudioSourceCandidates().also { activeCandidates = it }
        }
        val now = System.currentTimeMillis()

        for (idx in candidateStartIndex until candidates.size) {
            val (sourceInt, sourceName) = candidates[idx]
            attemptedSourcesLog.add(sourceName)
            val targetFile = CallRecordingStore.createTempRawFile(this, now + idx)
            var recorder: MediaRecorder? = null
            try {
                recorder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    MediaRecorder(this)
                } else {
                    @Suppress("DEPRECATION")
                    MediaRecorder()
                }
                recorder.setAudioSource(sourceInt)
                recorder.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
                recorder.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
                recorder.setAudioChannels(1)
                recorder.setAudioSamplingRate(44100)
                recorder.setAudioEncodingBitRate(48000)
                recorder.setOutputFile(targetFile.absolutePath)
                recorder.prepare()
                recorder.start()

                mediaRecorder = recorder
                outputFile = targetFile
                startedAtMs = now
                activeRecordId = "rec_$now"
                usedAudioSourceInt = sourceInt
                usedAudioSourceName = sourceName
                isRecordingActive = true
                initialProbeSettled = false
                peakAmplitudeSeen = -1
                zeroAmplitudeTicks = 0
                lastSystemSilenced = false

                // Gọi getMaxAmplitude lần đầu để reset bộ đo biên độ đỉnh của MediaRecorder.
                sampleMaxAmplitudeSafe()
                registerAudioRecordingCallback()
                scheduleInitialProbe(idx, candidates.size)
                Log.i(TAG, "Khởi tạo ghi âm source=$sourceName idx=$idx file=${targetFile.name}")
                return
            } catch (e: Exception) {
                Log.w(TAG, "Thử nguồn ghi âm $sourceName thất bại: ${e.message}")
                try { recorder?.reset() } catch (_: Exception) {}
                try { recorder?.release() } catch (_: Exception) {}
                try { if (targetFile.exists()) targetFile.delete() } catch (_: Exception) {}
            }
        }

        if (!retryAttempted && candidateStartIndex == 0) {
            retryAttempted = true
            val retry = Runnable {
                pendingStartRunnable = null
                if (isRunning) beginRecording(0)
            }
            pendingStartRunnable = retry
            mainHandler.postDelayed(retry, RETRY_DELAY_MS)
        } else {
            Log.e(TAG, "Không khởi tạo được MediaRecorder với bất kỳ nguồn âm nào")
            CallRecorderCoordinator.notifyRecordingError("Micro đang bị chiếm dụng")
            stopAndFinalize(stoppedMidCall = false, notifyIdle = false)
        }
    }

    private fun scheduleInitialProbe(candidateIndex: Int, totalCandidates: Int) {
        initialProbeRunnable?.let { mainHandler.removeCallbacks(it) }
        val runnable = Runnable {
            initialProbeRunnable = null
            if (!isRecordingActive) return@Runnable

            val amp = sampleMaxAmplitudeSafe()
            if (amp >= 0) {
                peakAmplitudeSeen = maxOf(peakAmplitudeSeen, amp)
            }
            val sysSilenced = querySystemSilencedState() == true
            val pref = CallRecordingStore.getAudioSourcePref(this)

            // Nếu đang ở chế độ 'auto' và hệ thống báo rõ nguồn hiện tại bị câm ngay lập tức,
            // thử chuyển nhanh sang nguồn tiếp theo khi CallRecordTrampolineActivity vẫn còn TOP.
            if (pref == "auto" && sysSilenced && (candidateIndex + 1) < totalCandidates) {
                Log.w(TAG, "Nguồn $usedAudioSourceName bị hệ thống câm lúc khởi động -> thử nguồn kế tiếp")
                resetActiveRecorderOnly(deleteFile = true)
                beginRecording(candidateStartIndex = candidateIndex + 1)
                return@Runnable
            }

            initialProbeSettled = true
            lastSystemSilenced = sysSilenced
            val hasSignalNow = peakAmplitudeSeen > 0 && !sysSilenced
            CallRecorderCoordinator.notifyRecordingStarted(startedAtMs, usedAudioSourceName, hasSignalNow)
            if (sysSilenced) {
                val reason = buildSystemSilenceReason()
                saveDiagnosticSnapshot(silenced = true, status = "SILENCED", reason = reason)
                CallRecorderCoordinator.notifyRecordingSignalUpdate(
                    hasSignal = false,
                    isSilenced = true,
                    audioSource = usedAudioSourceName,
                    reason = reason
                )
            } else {
                saveDiagnosticSnapshot(silenced = false, status = "RECORDING", reason = "")
            }
            scheduleSignalMonitor()
        }
        initialProbeRunnable = runnable
        mainHandler.postDelayed(runnable, INITIAL_PROBE_DELAY_MS)
    }

    private fun scheduleSignalMonitor() {
        signalMonitorRunnable?.let { mainHandler.removeCallbacks(it) }
        val runnable = object : Runnable {
            override fun run() {
                if (!isRecordingActive) return
                val amp = sampleMaxAmplitudeSafe()
                if (amp > 0) {
                    peakAmplitudeSeen = maxOf(peakAmplitudeSeen, amp)
                    zeroAmplitudeTicks = 0
                } else if (amp == 0) {
                    if (peakAmplitudeSeen < 0) peakAmplitudeSeen = 0
                    zeroAmplitudeTicks++
                }
                val sysSilenced = querySystemSilencedState()
                if (sysSilenced != null) {
                    lastSystemSilenced = sysSilenced
                }
                evaluateAndPushSignalState()
                mainHandler.postDelayed(this, SIGNAL_MONITOR_INTERVAL_MS)
            }
        }
        signalMonitorRunnable = runnable
        mainHandler.postDelayed(runnable, SIGNAL_MONITOR_INTERVAL_MS)
    }

    private fun buildSystemSilenceReason(): String {
        val audioManager = getSystemService(Context.AUDIO_SERVICE) as? AudioManager
        val mode = audioManager?.mode ?: AudioManager.MODE_NORMAL
        return if (mode == AudioManager.MODE_IN_CALL) {
            if (SystemCallRecordingSync.isConfigured(this)) {
                "VoLTE chặn mic · Bấm Thêm→Ghi âm"
            } else {
                "VoLTE chặn mic · Dùng Ghi âm máy"
            }
        } else {
            "Hệ thống chặn mic khi đang gọi"
        }
    }

    private fun saveDiagnosticSnapshot(silenced: Boolean, status: String, reason: String) {
        val audioManager = getSystemService(Context.AUDIO_SERVICE) as? AudioManager
        val mode = audioManager?.mode ?: AudioManager.MODE_NORMAL
        @Suppress("DEPRECATION")
        val speakerOn = try { audioManager?.isSpeakerphoneOn == true } catch (_: Exception) { false }
        CallRecordingStore.saveLastDiagnostic(
            this,
            mapOf(
                "timestampMs" to System.currentTimeMillis(),
                "audioSource" to usedAudioSourceName,
                "attemptedSources" to attemptedSourcesLog.distinct().joinToString(" -> "),
                "silencedBySystem" to silenced,
                "peakAmplitude" to peakAmplitudeSeen,
                "audioMode" to mode,
                "speakerOn" to speakerOn,
                "reason" to reason,
                "status" to status
            )
        )
    }

    private fun evaluateAndPushSignalState() {
        if (!isRecordingActive || !initialProbeSettled) return
        val hasSignalNow = peakAmplitudeSeen > 0 && !lastSystemSilenced
        val zeroTooLong = peakAmplitudeSeen <= 0 && zeroAmplitudeTicks >= SILENT_TICKS_THRESHOLD
        val showSilenced = lastSystemSilenced || zeroTooLong
        val reason = when {
            lastSystemSilenced -> buildSystemSilenceReason()
            zeroTooLong -> "Không thấy tiếng · thử Loa ngoài"
            else -> null
        }
        if (showSilenced && reason != null) {
            saveDiagnosticSnapshot(silenced = lastSystemSilenced, status = "SILENCED", reason = reason)
        }
        CallRecorderCoordinator.notifyRecordingSignalUpdate(
            hasSignal = hasSignalNow,
            isSilenced = showSilenced,
            audioSource = usedAudioSourceName,
            reason = reason
        )
    }

    private fun sampleMaxAmplitudeSafe(): Int {
        val rec = mediaRecorder ?: return -1
        return try {
            rec.maxAmplitude
        } catch (_: Exception) {
            -1
        }
    }

    private fun querySystemSilencedState(): Boolean? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return false
        return try {
            val audioManager = getSystemService(Context.AUDIO_SERVICE) as? AudioManager ?: return null
            val configs = audioManager.activeRecordingConfigurations
            if (configs.isEmpty()) return null
            val matching = configs.filter { it.clientAudioSource == usedAudioSourceInt }
                .ifEmpty { configs }
            matching.all { it.isClientSilenced }
        } catch (_: Exception) {
            null
        }
    }

    private fun resetActiveRecorderOnly(deleteFile: Boolean) {
        initialProbeRunnable?.let { mainHandler.removeCallbacks(it) }
        initialProbeRunnable = null
        signalMonitorRunnable?.let { mainHandler.removeCallbacks(it) }
        signalMonitorRunnable = null
        unregisterAudioRecordingCallback()

        val recorder = mediaRecorder
        mediaRecorder = null
        val file = outputFile
        outputFile = null
        isRecordingActive = false

        if (recorder != null) {
            try { recorder.stop() } catch (_: Exception) {}
            try { recorder.release() } catch (_: Exception) {}
        }
        if (deleteFile && file != null && file.exists()) {
            try { file.delete() } catch (_: Exception) {}
        }
    }

    private fun registerAudioRecordingCallback() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return
        unregisterAudioRecordingCallback()
        try {
            val audioManager = getSystemService(Context.AUDIO_SERVICE) as? AudioManager ?: return
            val callback = object : AudioManager.AudioRecordingCallback() {
                override fun onRecordingConfigChanged(configs: MutableList<AudioRecordingConfiguration>?) {
                    if (!isRecordingActive || configs == null || configs.isEmpty()) return
                    val matching = configs.filter { it.clientAudioSource == usedAudioSourceInt }
                        .ifEmpty { configs }
                    lastSystemSilenced = matching.all { it.isClientSilenced }
                    evaluateAndPushSignalState()
                }
            }
            audioManager.registerAudioRecordingCallback(callback, mainHandler)
            audioRecordingCallback = callback
        } catch (e: Exception) {
            Log.w(TAG, "Không đăng ký được AudioRecordingCallback", e)
        }
    }

    private fun unregisterAudioRecordingCallback() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return
        val cb = audioRecordingCallback as? AudioManager.AudioRecordingCallback ?: return
        audioRecordingCallback = null
        try {
            val audioManager = getSystemService(Context.AUDIO_SERVICE) as? AudioManager
            audioManager?.unregisterAudioRecordingCallback(cb)
        } catch (_: Exception) {}
    }

    private fun stopAndFinalize(stoppedMidCall: Boolean, notifyIdle: Boolean = true) {
        pendingStartRunnable?.let { mainHandler.removeCallbacks(it) }
        pendingStartRunnable = null
        initialProbeRunnable?.let { mainHandler.removeCallbacks(it) }
        initialProbeRunnable = null
        signalMonitorRunnable?.let { mainHandler.removeCallbacks(it) }
        signalMonitorRunnable = null
        unregisterAudioRecordingCallback()

        val recorder = mediaRecorder
        mediaRecorder = null
        val file = outputFile
        outputFile = null
        val wasRecording = isRecordingActive
        isRecordingActive = false
        initialProbeSettled = false
        activeCandidates = emptyList()

        val endedAtMs = System.currentTimeMillis()
        val sessionId = activeSessionId
        val ringStartMs = activeRingStartedAtMs
        val offhookStartMs = activeOffhookStartedAtMs
        val recordId = activeRecordId
        val startMs = startedAtMs
        val phone = activePhoneNumber
        val callType = activeCallType
        val audioSource = usedAudioSourceName
        val recordedPeakAmp = peakAmplitudeSeen
        val wasSilencedAtStop = lastSystemSilenced

        saveDiagnosticSnapshot(
            silenced = wasSilencedAtStop || recordedPeakAmp == 0,
            status = if (wasSilencedAtStop) "SILENCED" else if (recordedPeakAmp > 0) "RECORDED_AUDIO" else "NO_SIGNAL",
            reason = if (wasSilencedAtStop) buildSystemSilenceReason() else ""
        )

        activeSessionId = 0L
        activeRingStartedAtMs = 0L
        activeOffhookStartedAtMs = 0L
        activeRecordId = ""
        startedAtMs = 0L
        activePhoneNumber = ""
        peakAmplitudeSeen = -1
        zeroAmplitudeTicks = 0
        lastSystemSilenced = false
        attemptedSourcesLog.clear()

        if (recorder != null) {
            try {
                if (wasRecording) {
                    recorder.stop()
                }
            } catch (e: Exception) {
                Log.w(TAG, "MediaRecorder stop warning: ${e.message}")
            } finally {
                try {
                    recorder.release()
                } catch (_: Exception) {}
            }
        }

        if (wasRecording && file != null && file.exists() && file.length() > MIN_VALID_FILE_BYTES) {
            val rawDurationMs = CallRecordingTrimmer.measureDurationMs(
                file,
                (endedAtMs - startMs).coerceAtLeast(0L)
            )
            Log.i(
                TAG,
                "Lưu file ghi âm source=$audioSource peakAmp=$recordedPeakAmp duration=${rawDurationMs}ms size=${file.length()}"
            )
            CallRecordingPostProcessor.submitCompletedRecording(
                context = applicationContext,
                sessionId = sessionId,
                rawFile = file,
                recordId = recordId.ifEmpty { "rec_$startMs" },
                phoneHint = phone,
                callTypeHint = callType,
                ringStartedAtMs = ringStartMs,
                offhookStartedAtMs = offhookStartMs,
                recStartedAtMs = startMs,
                recEndedAtMs = endedAtMs,
                rawDurationMs = rawDurationMs,
                audioSource = audioSource,
                stoppedByUserWhileInCall = stoppedMidCall,
                peakAmplitude = recordedPeakAmp
            )
        } else if (file != null && file.exists()) {
            try {
                file.delete()
            } catch (_: Exception) {}
        }

        isRunning = false
        if (notifyIdle) {
            CallRecorderCoordinator.notifyRecordingStopped()
        }
        try {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } catch (_: Exception) {}
        stopSelf()
    }

    override fun onDestroy() {
        pendingStartRunnable?.let { mainHandler.removeCallbacks(it) }
        pendingStartRunnable = null
        initialProbeRunnable?.let { mainHandler.removeCallbacks(it) }
        initialProbeRunnable = null
        signalMonitorRunnable?.let { mainHandler.removeCallbacks(it) }
        signalMonitorRunnable = null
        unregisterAudioRecordingCallback()
        mediaRecorder?.let { rec ->
            try { rec.stop() } catch (_: Exception) {}
            try { rec.release() } catch (_: Exception) {}
        }
        mediaRecorder = null
        isRecordingActive = false
        isRunning = false
        super.onDestroy()
    }
}
