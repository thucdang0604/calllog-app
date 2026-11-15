package com.example.call_log_manager

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.CallLog
import android.provider.ContactsContract
import android.util.Log
import androidx.core.content.ContextCompat
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

internal object CallRecordingStore {
    private const val TAG = "CallRecordingStore"
    private const val RECORDINGS_DIR = "call_recordings"
    private const val INDEX_FILE = "recordings_index.json"
    private const val PREFS_NAME = "floating_window_state"
    private const val KEY_AUDIO_SOURCE = "call_recording_audio_source"
    const val RETENTION_DAYS = 30L
    private const val RETENTION_MS = RETENTION_DAYS * 24L * 60L * 60L * 1000L

    private val lock = Any()

    fun getRecordingsDir(context: Context): File {
        val dir = File(context.filesDir, RECORDINGS_DIR)
        if (!dir.exists()) {
            dir.mkdirs()
        }
        return dir
    }

    fun createRecordingFile(context: Context, startedAt: Long): File {
        return File(getRecordingsDir(context), "call_${startedAt}.m4a")
    }

    fun createTempRawFile(context: Context, startedAt: Long): File {
        return File(getRecordingsDir(context), "raw_${startedAt}.m4a")
    }

    fun getAudioSourcePref(context: Context): String {
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        return prefs.getString(KEY_AUDIO_SOURCE, "auto") ?: "auto"
    }

    fun setAudioSourcePref(context: Context, source: String) {
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        prefs.edit().putString(KEY_AUDIO_SOURCE, source).apply()
    }

    fun normalizePhone(raw: String?): String {
        if (raw.isNullOrBlank()) return ""
        val digits = raw.filter { it.isDigit() }
        if (digits.isEmpty()) return ""
        val local = if (digits.startsWith("84") && digits.length >= 10) {
            "0${digits.substring(2)}"
        } else {
            digits
        }
        return if (local.length > 10) local.takeLast(9) else local
    }

    private fun readIndexLocked(context: Context): JSONArray {
        val indexFile = File(getRecordingsDir(context), INDEX_FILE)
        if (!indexFile.exists()) return JSONArray()
        return try {
            val text = indexFile.readText(Charsets.UTF_8)
            if (text.isBlank()) JSONArray() else JSONArray(text)
        } catch (e: Exception) {
            Log.w(TAG, "Lỗi đọc index ghi âm", e)
            JSONArray()
        }
    }

    private fun writeIndexLocked(context: Context, array: JSONArray) {
        val dir = getRecordingsDir(context)
        val tempFile = File(dir, "$INDEX_FILE.tmp")
        val targetFile = File(dir, INDEX_FILE)
        try {
            tempFile.writeText(array.toString(), Charsets.UTF_8)
            if (!tempFile.renameTo(targetFile)) {
                targetFile.writeText(array.toString(), Charsets.UTF_8)
                tempFile.delete()
            }
        } catch (e: Exception) {
            Log.e(TAG, "Lỗi ghi index ghi âm", e)
        }
    }

    private fun pruneLocked(context: Context, array: JSONArray): Pair<JSONArray, Boolean> {
        val now = System.currentTimeMillis()
        val kept = JSONArray()
        val keptPaths = HashSet<String>()
        var changed = false

        for (i in 0 until array.length()) {
            val obj = array.optJSONObject(i) ?: continue
            val path = obj.optString("filePath")
            val startedAt = obj.optLong("startedAt", 0L)
            val file = if (path.isNotEmpty()) File(path) else null
            val expired = startedAt > 0L && (now - startedAt) > RETENTION_MS
            val missing = file == null || !file.exists() || file.length() <= 0L

            if (expired || missing) {
                changed = true
                if (expired && file != null && file.exists()) {
                    try {
                        file.delete()
                    } catch (_: Exception) {}
                }
            } else {
                kept.put(obj)
                if (file != null) {
                    keptPaths.add(file.absolutePath)
                }
            }
        }

        // Remove orphaned .m4a files (older than 1h for stale raw_ temp files, 24h for unindexed files)
        val orphanGraceMs = 24L * 60L * 60L * 1000L
        val staleRawGraceMs = 60L * 60L * 1000L
        val files = getRecordingsDir(context).listFiles() ?: emptyArray()
        for (f in files) {
            if (!f.isFile || !f.name.endsWith(".m4a")) continue
            if (!keptPaths.contains(f.absolutePath)) {
                val age = now - f.lastModified()
                val isStaleRaw = f.name.startsWith("raw_") && !CallRecorderService.isRunning && age > staleRawGraceMs
                if (isStaleRaw || age > orphanGraceMs) {
                    try {
                        f.delete()
                    } catch (_: Exception) {}
                }
            }
        }

        if (changed) {
            writeIndexLocked(context, kept)
        }
        return Pair(kept, changed)
    }

    fun saveRecording(
        context: Context,
        id: String,
        file: File,
        phoneNumber: String,
        contactName: String,
        callType: Int,
        startedAt: Long,
        endedAt: Long,
        durationMs: Long,
        audioSource: String,
        callLogId: Int = -1,
        peakAmplitude: Int = -1
    ) {
        val resolvedName = resolveContactNameIfBlank(context, phoneNumber, contactName)
        synchronized(lock) {
            val raw = readIndexLocked(context)
            val (pruned, _) = pruneLocked(context, raw)

            val newObj = JSONObject().apply {
                put("id", id)
                put("filePath", file.absolutePath)
                put("phoneNumber", phoneNumber)
                put("normalizedNumber", normalizePhone(phoneNumber))
                put("contactName", resolvedName)
                put("callType", callType)
                put("callLogId", callLogId)
                put("startedAt", startedAt)
                put("endedAt", endedAt)
                put("durationMs", durationMs)
                put("fileSizeBytes", file.length())
                put("audioSource", audioSource)
                put("peakAmplitude", peakAmplitude)
            }

            val updated = JSONArray()
            updated.put(newObj)
            for (i in 0 until pruned.length()) {
                updated.put(pruned.opt(i))
            }
            writeIndexLocked(context, updated)
        }
        CallRecordingEventBus.notifyRecordingsUpdated()
    }

    fun listRecordings(context: Context): List<Map<String, Any?>> {
        val result = ArrayList<Map<String, Any?>>()
        synchronized(lock) {
            val (array, _) = pruneLocked(context, readIndexLocked(context))
            for (i in 0 until array.length()) {
                val obj = array.optJSONObject(i) ?: continue
                result.add(
                    mapOf(
                        "id" to obj.optString("id"),
                        "filePath" to obj.optString("filePath"),
                        "phoneNumber" to obj.optString("phoneNumber"),
                        "normalizedNumber" to obj.optString("normalizedNumber"),
                        "contactName" to obj.optString("contactName"),
                        "callType" to obj.optInt("callType", 1),
                        "callLogId" to obj.optInt("callLogId", -1),
                        "startedAt" to obj.optLong("startedAt", 0L),
                        "endedAt" to obj.optLong("endedAt", 0L),
                        "durationMs" to obj.optLong("durationMs", 0L),
                        "fileSizeBytes" to obj.optLong("fileSizeBytes", 0L),
                        "audioSource" to obj.optString("audioSource", "VOICE_RECOGNITION"),
                        "peakAmplitude" to obj.optInt("peakAmplitude", -1)
                    )
                )
            }
        }
        return result
    }

    fun deleteByIds(context: Context, ids: List<String>): Int {
        if (ids.isEmpty()) return 0
        val idSet = ids.toHashSet()
        var removedCount = 0
        synchronized(lock) {
            val array = readIndexLocked(context)
            val kept = JSONArray()
            for (i in 0 until array.length()) {
                val obj = array.optJSONObject(i) ?: continue
                val id = obj.optString("id")
                if (idSet.contains(id)) {
                    removedCount++
                    val path = obj.optString("filePath")
                    if (path.isNotEmpty()) {
                        try {
                            val file = File(path)
                            if (file.exists()) file.delete()
                        } catch (_: Exception) {}
                    }
                } else {
                    kept.put(obj)
                }
            }
            if (removedCount > 0) {
                writeIndexLocked(context, kept)
            }
        }
        if (removedCount > 0) {
            CallRecordingEventBus.notifyRecordingsUpdated()
        }
        return removedCount
    }

    fun deleteByTimeRange(context: Context, mode: String, startMs: Long, endMs: Long): Int {
        var removedCount = 0
        synchronized(lock) {
            val array = readIndexLocked(context)
            val kept = JSONArray()
            for (i in 0 until array.length()) {
                val obj = array.optJSONObject(i) ?: continue
                val startedAt = obj.optLong("startedAt", 0L)
                val shouldDelete = when (mode) {
                    "on_date" -> startedAt in startMs..endMs
                    "before_date" -> startedAt <= endMs
                    else -> false
                }
                if (shouldDelete) {
                    removedCount++
                    val path = obj.optString("filePath")
                    if (path.isNotEmpty()) {
                        try {
                            val file = File(path)
                            if (file.exists()) file.delete()
                        } catch (_: Exception) {}
                    }
                } else {
                    kept.put(obj)
                }
            }
            if (removedCount > 0) {
                writeIndexLocked(context, kept)
            }
        }
        if (removedCount > 0) {
            CallRecordingEventBus.notifyRecordingsUpdated()
        }
        return removedCount
    }

    data class CallLogEntryInfo(
        val callLogId: Int,
        val number: String,
        val name: String,
        val callType: Int,
        val dateMs: Long,
        val durationSec: Int
    )

    sealed class TalkTrimPlan {
        object DiscardNoTalk : TalkTrimPlan()
        object KeepFull : TalkTrimPlan()
        data class KeepAndTrim(val trimStartOffsetMs: Long) : TalkTrimPlan()
    }

    fun computeTrimPlan(
        rawDurationMs: Long,
        talkDurationSec: Int,
        minSavingsMs: Long = 2500L,
        leadBufferMs: Long = 1500L
    ): TalkTrimPlan {
        if (talkDurationSec <= 0) {
            return TalkTrimPlan.DiscardNoTalk
        }
        val talkMs = talkDurationSec * 1000L
        val excessMs = rawDurationMs - talkMs
        if (rawDurationMs > 0L && excessMs > minSavingsMs) {
            val trimOffsetMs = (excessMs - leadBufferMs).coerceAtLeast(0L)
            if (trimOffsetMs >= 1000L && trimOffsetMs < rawDurationMs - 1500L) {
                return TalkTrimPlan.KeepAndTrim(trimOffsetMs)
            }
        }
        return TalkTrimPlan.KeepFull
    }

    fun queryLatestCallLogId(context: Context): Int {
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.READ_CALL_LOG)
            != PackageManager.PERMISSION_GRANTED
        ) {
            return 0
        }
        return queryCallLogWithLimit(
            context = context,
            projection = arrayOf(CallLog.Calls._ID),
            sortOrder = "${CallLog.Calls._ID} DESC",
            limit = 1
        )?.use { c ->
            if (c.moveToFirst()) c.getInt(0) else 0
        } ?: 0
    }

    private fun queryCallLogWithLimit(
        context: Context,
        projection: Array<String>,
        sortOrder: String,
        limit: Int
    ): android.database.Cursor? {
        val limitedUri = CallLog.Calls.CONTENT_URI.buildUpon()
            .appendQueryParameter(CallLog.Calls.LIMIT_PARAM_KEY, limit.toString())
            .build()
        return try {
            context.contentResolver.query(limitedUri, projection, null, null, sortOrder)
        } catch (_: Exception) {
            try {
                context.contentResolver.query(
                    CallLog.Calls.CONTENT_URI,
                    projection,
                    null,
                    null,
                    sortOrder
                )
            } catch (_: Exception) {
                null
            }
        }
    }

    fun resolveContactNameIfBlank(context: Context, phoneNumber: String, currentName: String): String {
        if (currentName.isNotBlank() || phoneNumber.isBlank()) return currentName
        return lookupContactName(context, phoneNumber)
    }

    fun findMatchingCallLogEntry(
        context: Context,
        minCallLogIdExclusive: Int,
        anchorStartMs: Long,
        endedAtMs: Long,
        phoneHint: String
    ): CallLogEntryInfo? {
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.READ_CALL_LOG)
            != PackageManager.PERMISSION_GRANTED
        ) {
            return null
        }

        val usedCallLogIds = HashSet<Int>()
        synchronized(lock) {
            val array = readIndexLocked(context)
            for (i in 0 until array.length()) {
                val id = array.optJSONObject(i)?.optInt("callLogId", -1) ?: -1
                if (id > 0) usedCallLogIds.add(id)
            }
        }

        val normHint = normalizePhone(phoneHint)

        return try {
            val projection = arrayOf(
                CallLog.Calls._ID,
                CallLog.Calls.NUMBER,
                CallLog.Calls.CACHED_NAME,
                CallLog.Calls.DATE,
                CallLog.Calls.DURATION,
                CallLog.Calls.TYPE
            )
            val cursor = queryCallLogWithLimit(
                context = context,
                projection = projection,
                sortOrder = "${CallLog.Calls.DATE} DESC",
                limit = 20
            ) ?: return null

            var bestMatch: CallLogEntryInfo? = null
            var bestScore = Long.MAX_VALUE

            cursor.use { c ->
                val colId = c.getColumnIndex(CallLog.Calls._ID)
                val colNumber = c.getColumnIndex(CallLog.Calls.NUMBER)
                val colName = c.getColumnIndex(CallLog.Calls.CACHED_NAME)
                val colDate = c.getColumnIndex(CallLog.Calls.DATE)
                val colDur = c.getColumnIndex(CallLog.Calls.DURATION)
                val colType = c.getColumnIndex(CallLog.Calls.TYPE)

                var checked = 0
                while (c.moveToNext() && checked < 15) {
                    checked++
                    val rowId = if (colId != -1) c.getInt(colId) else -1
                    if (rowId <= 0) continue
                    if (minCallLogIdExclusive > 0 && rowId <= minCallLogIdExclusive) {
                        continue
                    }
                    if (usedCallLogIds.contains(rowId)) {
                        continue
                    }

                    val callDate = if (colDate != -1) c.getLong(colDate) else 0L
                    val callDurSec = (if (colDur != -1) c.getInt(colDur) else 0).coerceAtLeast(0)
                    val dateFloor = if (minCallLogIdExclusive > 0) {
                        anchorStartMs - 120_000L
                    } else {
                        anchorStartMs - 15_000L
                    }
                    if (callDate > endedAtMs + 15_000L || callDate < dateFloor) {
                        continue
                    }

                    val expectedEnd = callDate + callDurSec * 1000L
                    if (callDurSec > 0 && kotlin.math.abs(expectedEnd - endedAtMs) > 180_000L) {
                        continue
                    }

                    val number = (if (colNumber != -1) c.getString(colNumber) else null) ?: ""
                    val name = (if (colName != -1) c.getString(colName) else null) ?: ""
                    val callType = if (colType != -1) c.getInt(colType) else 1

                    val timingDiff = if (callDurSec > 0) {
                        kotlin.math.abs(expectedEnd - endedAtMs) +
                            kotlin.math.abs(callDate - anchorStartMs) / 4L
                    } else {
                        kotlin.math.abs(callDate - anchorStartMs)
                    }
                    val normRow = normalizePhone(number)
                    val phonePenalty = if (normHint.isNotEmpty() && normRow.isNotEmpty() && normHint != normRow) {
                        30_000L
                    } else {
                        0L
                    }
                    val score = timingDiff + phonePenalty
                    if (score < bestScore) {
                        bestScore = score
                        bestMatch = CallLogEntryInfo(
                            callLogId = rowId,
                            number = number,
                            name = name,
                            callType = callType,
                            dateMs = callDate,
                            durationSec = callDurSec
                        )
                    }
                }
            }

            if (bestMatch != null && bestMatch!!.name.isBlank() && bestMatch!!.number.isNotBlank()) {
                val contactName = lookupContactName(context, bestMatch!!.number)
                if (contactName.isNotBlank()) {
                    bestMatch = bestMatch!!.copy(name = contactName)
                }
            }
            bestMatch
        } catch (e: Exception) {
            Log.w(TAG, "Lỗi truy vấn CallLog để xác minh thời gian thoại", e)
            null
        }
    }

    private fun lookupContactName(context: Context, phoneNumber: String): String {
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.READ_CONTACTS)
            != PackageManager.PERMISSION_GRANTED
        ) {
            return ""
        }
        return try {
            val uri = Uri.withAppendedPath(
                ContactsContract.PhoneLookup.CONTENT_FILTER_URI,
                Uri.encode(phoneNumber)
            )
            context.contentResolver.query(
                uri,
                arrayOf(ContactsContract.PhoneLookup.DISPLAY_NAME),
                null,
                null,
                null
            )?.use { cursor ->
                if (cursor.moveToFirst()) {
                    cursor.getString(0) ?: ""
                } else {
                    ""
                }
            } ?: ""
        } catch (_: Exception) {
            ""
        }
    }
}
