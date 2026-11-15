package com.example.call_log_manager

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.provider.CallLog
import android.util.Log
import androidx.core.content.ContextCompat
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

internal object CallRecordingPostProcessor {
    private const val TAG = "CallRecPostProc"
    private const val MIN_VALID_FILE_BYTES = 1024L
    private val POLL_AT_MS = longArrayOf(700L, 1500L, 2600L, 4000L, 5500L)

    private val executor = Executors.newSingleThreadScheduledExecutor()
    private val sessionBaselineIds = HashMap<Long, Int>()

    private data class VerificationJob(
        val appContext: Context,
        val sessionId: Long,
        val rawFile: File,
        val recordId: String,
        val phoneHint: String,
        val callTypeHint: Int,
        val ringStartedAtMs: Long,
        val offhookStartedAtMs: Long,
        val recStartedAtMs: Long,
        val recEndedAtMs: Long,
        val rawDurationMs: Long,
        val audioSource: String,
        val minCallLogIdExclusive: Int,
        val stoppedByUserWhileInCall: Boolean,
        val peakAmplitude: Int = -1
    )

    fun captureSessionBaseline(context: Context, sessionId: Long) {
        val appCtx = context.applicationContext
        executor.execute {
            if (!sessionBaselineIds.containsKey(sessionId)) {
                sessionBaselineIds[sessionId] = CallRecordingStore.queryLatestCallLogId(appCtx)
                if (sessionBaselineIds.size > 16) {
                    val oldestKey = sessionBaselineIds.keys.minOrNull()
                    if (oldestKey != null && oldestKey != sessionId) {
                        sessionBaselineIds.remove(oldestKey)
                    }
                }
            }
        }
    }

    fun submitCompletedRecording(
        context: Context,
        sessionId: Long,
        rawFile: File,
        recordId: String,
        phoneHint: String,
        callTypeHint: Int,
        ringStartedAtMs: Long,
        offhookStartedAtMs: Long,
        recStartedAtMs: Long,
        recEndedAtMs: Long,
        rawDurationMs: Long,
        audioSource: String,
        stoppedByUserWhileInCall: Boolean = false,
        peakAmplitude: Int = -1
    ) {
        val appCtx = context.applicationContext
        executor.execute {
            val baselineId = if (stoppedByUserWhileInCall) {
                sessionBaselineIds[sessionId] ?: 0
            } else {
                sessionBaselineIds.remove(sessionId) ?: 0
            }
            val job = VerificationJob(
                appContext = appCtx,
                sessionId = sessionId,
                rawFile = rawFile,
                recordId = recordId,
                phoneHint = phoneHint,
                callTypeHint = callTypeHint,
                ringStartedAtMs = ringStartedAtMs,
                offhookStartedAtMs = offhookStartedAtMs,
                recStartedAtMs = recStartedAtMs,
                recEndedAtMs = recEndedAtMs,
                rawDurationMs = rawDurationMs,
                audioSource = audioSource,
                minCallLogIdExclusive = baselineId,
                stoppedByUserWhileInCall = stoppedByUserWhileInCall,
                peakAmplitude = peakAmplitude
            )

            // Nếu người dùng chủ động bấm Dừng khi cuộc gọi đang diễn ra (OFFHOOK),
            // CallLog chưa có bản ghi cuộc gọi này -> lưu trực tiếp ngay lập tức.
            if (stoppedByUserWhileInCall) {
                saveManualMidCallRecording(job)
                return@execute
            }

            val hasCallLogPerm = ContextCompat.checkSelfPermission(
                appCtx,
                Manifest.permission.READ_CALL_LOG
            ) == PackageManager.PERMISSION_GRANTED

            if (!hasCallLogPerm) {
                handleMissingCallLogPermission(job)
                return@execute
            }

            schedulePollAttempt(job, attemptIndex = 0)
        }
    }

    private fun schedulePollAttempt(job: VerificationJob, attemptIndex: Int) {
        val targetElapsed = POLL_AT_MS[attemptIndex]
        val alreadyElapsed = (System.currentTimeMillis() - job.recEndedAtMs).coerceAtLeast(0L)
        val delay = (targetElapsed - alreadyElapsed).coerceAtLeast(150L)

        executor.schedule(
            { runVerificationAttempt(job, attemptIndex) },
            delay,
            TimeUnit.MILLISECONDS
        )
    }

    private fun runVerificationAttempt(job: VerificationJob, attemptIndex: Int) {
        if (!job.rawFile.exists() || job.rawFile.length() <= MIN_VALID_FILE_BYTES) {
            deleteQuietly(job.rawFile)
            return
        }

        val anchorStartMs = if (job.ringStartedAtMs > 0L) {
            job.ringStartedAtMs
        } else if (job.offhookStartedAtMs > 0L) {
            job.offhookStartedAtMs
        } else {
            job.recStartedAtMs
        }

        val matched = CallRecordingStore.findMatchingCallLogEntry(
            context = job.appContext,
            minCallLogIdExclusive = job.minCallLogIdExclusive,
            anchorStartMs = anchorStartMs,
            endedAtMs = job.recEndedAtMs,
            phoneHint = job.phoneHint
        )

        if (matched == null) {
            if (attemptIndex + 1 < POLL_AT_MS.size) {
                schedulePollAttempt(job, attemptIndex + 1)
            } else {
                // Không tìm thấy bản ghi CallLog hợp lệ sau 5.5s (VD: USSD hoặc cuộc gọi lỗi không lưu log)
                Log.i(TAG, "Bỏ qua file ghi âm vì không khớp cuộc gọi nào trong nhật ký sau 5.5s")
                deleteQuietly(job.rawFile)
            }
            return
        }

        val isNonTalkType = matched.callType == CallLog.Calls.MISSED_TYPE ||
            matched.callType == CallLog.Calls.REJECTED_TYPE ||
            matched.callType == CallLog.Calls.BLOCKED_TYPE

        if (isNonTalkType || matched.durationSec <= 0) {
            Log.i(
                TAG,
                "Xóa file ghi âm vì không phát sinh thời gian thoại (callLogId=${matched.callLogId}, type=${matched.callType}, duration=${matched.durationSec}s)"
            )
            deleteQuietly(job.rawFile)
            return
        }

        saveTalkRecording(job, matched)
    }

    private fun saveTalkRecording(
        job: VerificationJob,
        matched: CallRecordingStore.CallLogEntryInfo
    ) {
        val trimPlan = CallRecordingStore.computeTrimPlan(
            rawDurationMs = job.rawDurationMs,
            talkDurationSec = matched.durationSec
        )

        var finalFile: File? = null
        var finalStartMs = job.recStartedAtMs
        var finalDurationMs = job.rawDurationMs

        when (trimPlan) {
            is CallRecordingStore.TalkTrimPlan.DiscardNoTalk -> {
                deleteQuietly(job.rawFile)
                return
            }

            is CallRecordingStore.TalkTrimPlan.KeepAndTrim -> {
                val adjustedStart = job.recStartedAtMs + trimPlan.trimStartOffsetMs
                val trimmedFile = CallRecordingStore.createRecordingFile(job.appContext, adjustedStart)
                val trimmedDurationMs = CallRecordingTrimmer.trimFromOffset(
                    srcFile = job.rawFile,
                    dstFile = trimmedFile,
                    startOffsetMs = trimPlan.trimStartOffsetMs
                )
                if (trimmedDurationMs != null && trimmedFile.exists()) {
                    deleteQuietly(job.rawFile)
                    finalFile = trimmedFile
                    finalStartMs = adjustedStart
                    finalDurationMs = trimmedDurationMs
                    Log.i(
                        TAG,
                        "Đã cắt bỏ ${trimPlan.trimStartOffsetMs}ms chờ chuông -> lưu ${trimmedDurationMs}ms thoại (callLogDuration=${matched.durationSec}s)"
                    )
                } else {
                    Log.w(TAG, "Cắt file thất bại, giữ nguyên file gốc có thoại")
                    finalFile = moveRawToFinalFile(job.appContext, job.rawFile, job.recStartedAtMs)
                }
            }

            is CallRecordingStore.TalkTrimPlan.KeepFull -> {
                finalFile = moveRawToFinalFile(job.appContext, job.rawFile, job.recStartedAtMs)
            }
        }

        val output = finalFile
        if (output == null || !output.exists() || output.length() <= MIN_VALID_FILE_BYTES) {
            deleteQuietly(output)
            deleteQuietly(job.rawFile)
            return
        }

        val resolvedPhone = matched.number.ifBlank { job.phoneHint }
        val resolvedType = if (
            matched.callType == CallLog.Calls.INCOMING_TYPE ||
            matched.callType == CallLog.Calls.OUTGOING_TYPE
        ) {
            matched.callType
        } else {
            job.callTypeHint
        }

        CallRecordingStore.saveRecording(
            context = job.appContext,
            id = job.recordId,
            file = output,
            phoneNumber = resolvedPhone,
            contactName = matched.name,
            callType = resolvedType,
            startedAt = finalStartMs,
            endedAt = job.recEndedAtMs,
            durationMs = finalDurationMs,
            audioSource = job.audioSource,
            callLogId = matched.callLogId,
            peakAmplitude = job.peakAmplitude
        )
    }

    private fun saveManualMidCallRecording(job: VerificationJob) {
        if (!job.rawFile.exists() || job.rawFile.length() <= MIN_VALID_FILE_BYTES || job.rawDurationMs < 500L) {
            deleteQuietly(job.rawFile)
            return
        }
        val dest = moveRawToFinalFile(job.appContext, job.rawFile, job.recStartedAtMs)
        if (dest != null && dest.exists() && dest.length() > MIN_VALID_FILE_BYTES) {
            val contactName = CallRecordingStore.resolveContactNameIfBlank(
                job.appContext,
                job.phoneHint,
                ""
            )
            CallRecordingStore.saveRecording(
                context = job.appContext,
                id = job.recordId,
                file = dest,
                phoneNumber = job.phoneHint,
                contactName = contactName,
                callType = job.callTypeHint,
                startedAt = job.recStartedAtMs,
                endedAt = job.recEndedAtMs,
                durationMs = job.rawDurationMs,
                audioSource = job.audioSource,
                peakAmplitude = job.peakAmplitude
            )
            return
        }
        deleteQuietly(job.rawFile)
    }

    private fun handleMissingCallLogPermission(job: VerificationJob) {
        if (job.rawDurationMs >= 1000L) {
            val dest = moveRawToFinalFile(job.appContext, job.rawFile, job.recStartedAtMs)
            if (dest != null && dest.exists()) {
                val contactName = CallRecordingStore.resolveContactNameIfBlank(
                    job.appContext,
                    job.phoneHint,
                    ""
                )
                CallRecordingStore.saveRecording(
                    context = job.appContext,
                    id = job.recordId,
                    file = dest,
                    phoneNumber = job.phoneHint,
                    contactName = contactName,
                    callType = job.callTypeHint,
                    startedAt = job.recStartedAtMs,
                    endedAt = job.recEndedAtMs,
                    durationMs = job.rawDurationMs,
                    audioSource = job.audioSource,
                    peakAmplitude = job.peakAmplitude
                )
                return
            }
        }
        Log.w(TAG, "Thiếu READ_CALL_LOG và file quá ngắn -> hủy file tạm")
        deleteQuietly(job.rawFile)
    }

    private fun moveRawToFinalFile(context: Context, rawFile: File, startedAtMs: Long): File? {
        if (!rawFile.exists()) return null
        val dest = CallRecordingStore.createRecordingFile(context, startedAtMs)
        if (rawFile.absolutePath == dest.absolutePath) return dest
        if (dest.exists()) dest.delete()
        return if (rawFile.renameTo(dest)) {
            dest
        } else {
            try {
                rawFile.copyTo(dest, overwrite = true)
                rawFile.delete()
                dest
            } catch (_: Exception) {
                rawFile
            }
        }
    }

    private fun deleteQuietly(file: File?) {
        if (file != null && file.exists()) {
            try {
                file.delete()
            } catch (_: Exception) {}
        }
    }
}
