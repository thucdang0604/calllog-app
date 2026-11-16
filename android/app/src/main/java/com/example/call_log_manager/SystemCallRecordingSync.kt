package com.example.call_log_manager

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.database.Cursor
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.util.Log
import androidx.core.content.ContextCompat
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.InputStream
import java.security.MessageDigest
import java.text.SimpleDateFormat
import java.util.Locale
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

internal object SystemCallRecordingSync {
    private const val TAG = "SysCallRecSync"
    private const val PREFS_NAME = "floating_window_state"
    private const val KEY_TREE_URI = "system_call_rec_tree_uri"
    private const val KEY_TREE_LABEL = "system_call_rec_tree_label"
    private const val KEY_LAST_SYNC_MS = "system_call_rec_last_sync_ms"
    private const val KEY_LAST_IMPORTED_COUNT = "system_call_rec_last_imported_count"
    private const val KEY_LAST_ERROR = "system_call_rec_last_error"

    private const val MIN_VALID_FILE_BYTES = 1024L
    private const val RETENTION_MS = CallRecordingStore.RETENTION_DAYS * 24L * 60L * 60L * 1000L
    private const val FRESH_WRITE_GUARD_MS = 1200L
    private const val MAX_SAF_DEPTH = 2
    private const val MAX_FILES_PER_SYNC = 150

    private val AUDIO_EXTS = setOf("mp3", "m4a", "aac", "amr", "3gp", "wav", "ogg", "opus", "flac")
    private val KNOWN_REL_CALL_DIRS = listOf(
        "MIUI/sound_recorder/call_rec",
        "Recordings/Call",
        "Recordings/Recordings/Call",
        "Recordings/Sound_recorder/call_rec",
        "SoundRecorder/call_rec",
        "Sounds/CallRecord",
        "Music/CallRecordings",
        "CallRecordings",
        "Call"
    )
    private val KNOWN_PATH_HINTS = listOf(
        "call_rec",
        "call_rec/",
        "/call/",
        "callrecord",
        "recordings/call",
        "sound_recorder/call"
    )

    private val syncLock = Any()
    private val syncExecutor = Executors.newSingleThreadScheduledExecutor()

    private data class CandidateFile(
        val displayName: String,
        val sizeBytes: Long,
        val lastModifiedMs: Long,
        val extension: String,
        val openStream: () -> InputStream?
    ) {
        fun signature(): String {
            val sec = if (lastModifiedMs > 0L) lastModifiedMs / 1000L else 0L
            return "sysfile:${displayName}:${sizeBytes}:${sec}"
        }
    }

    private data class ParsedFilenameMeta(
        val phoneNumber: String,
        val contactHint: String,
        val callTypeHint: Int,
        val timestampMs: Long?
    )

    fun getRequiredMediaPermission(): String {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            Manifest.permission.READ_MEDIA_AUDIO
        } else {
            Manifest.permission.READ_EXTERNAL_STORAGE
        }
    }

    fun hasMediaAudioPermission(context: Context): Boolean {
        return ContextCompat.checkSelfPermission(
            context,
            getRequiredMediaPermission()
        ) == PackageManager.PERMISSION_GRANTED
    }

    fun getPersistedTreeUri(context: Context): Uri? {
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val raw = prefs.getString(KEY_TREE_URI, null) ?: return null
        if (raw.isBlank()) return null
        val uri = try {
            Uri.parse(raw)
        } catch (_: Exception) {
            return null
        }
        val persisted = context.contentResolver.persistedUriPermissions.any {
            it.uri == uri && it.isReadPermission
        }
        return if (persisted) uri else null
    }

    fun isConfigured(context: Context): Boolean {
        return getPersistedTreeUri(context) != null || hasMediaAudioPermission(context)
    }

    fun getStatus(context: Context): Map<String, Any?> {
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val treeUri = getPersistedTreeUri(context)
        val hasTree = treeUri != null
        val hasMedia = hasMediaAudioPermission(context)
        val folderLabel = if (hasTree) {
            prefs.getString(KEY_TREE_LABEL, null)?.takeIf { it.isNotBlank() }
                ?: decodeTreeLabel(treeUri!!)
        } else {
            ""
        }
        return mapOf(
            "hasTreePermission" to hasTree,
            "hasMediaPermission" to hasMedia,
            "isReady" to (hasTree || hasMedia),
            "folderLabel" to folderLabel,
            "lastSyncMs" to prefs.getLong(KEY_LAST_SYNC_MS, 0L),
            "lastImportedCount" to prefs.getInt(KEY_LAST_IMPORTED_COUNT, 0),
            "lastError" to (prefs.getString(KEY_LAST_ERROR, "") ?: ""),
            "brand" to (Build.BRAND ?: ""),
            "manufacturer" to (Build.MANUFACTURER ?: ""),
            "model" to (Build.MODEL ?: ""),
            "sdkInt" to Build.VERSION.SDK_INT,
            "suggestedFolder" to detectBestSuggestedFolderLabel()
        )
    }

    fun clearTreeFolder(context: Context): Map<String, Any?> {
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val raw = prefs.getString(KEY_TREE_URI, null)
        if (!raw.isNullOrBlank()) {
            try {
                context.contentResolver.releasePersistableUriPermission(
                    Uri.parse(raw),
                    Intent.FLAG_GRANT_READ_URI_PERMISSION
                )
            } catch (_: Exception) {}
        }
        prefs.edit()
            .remove(KEY_TREE_URI)
            .remove(KEY_TREE_LABEL)
            .remove(KEY_LAST_ERROR)
            .apply()
        return getStatus(context)
    }

    fun buildPickFolderIntent(context: Context): Intent {
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or
                    Intent.FLAG_GRANT_PREFIX_URI_PERMISSION
            )
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            buildInitialFolderHintUri()?.let { initialUri ->
                intent.putExtra(DocumentsContract.EXTRA_INITIAL_URI, initialUri)
            }
        }
        return intent
    }

    fun onTreeUriPicked(context: Context, uri: Uri, resultFlags: Int): Map<String, Any?> {
        val takeFlags = resultFlags and Intent.FLAG_GRANT_READ_URI_PERMISSION
        try {
            context.contentResolver.takePersistableUriPermission(
                uri,
                if (takeFlags != 0) takeFlags else Intent.FLAG_GRANT_READ_URI_PERMISSION
            )
        } catch (e: Exception) {
            Log.w(TAG, "Không thể giữ quyền đọc thư mục lâu dài: ${e.message}")
        }

        val label = decodeTreeLabel(uri)
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY_TREE_URI, uri.toString())
            .putString(KEY_TREE_LABEL, label)
            .remove(KEY_LAST_ERROR)
            .apply()

        CallRecordingStore.clearIgnoredSignatures(context)
        return syncNow(context, trigger = "picker")
    }

    fun schedulePostCallSync(context: Context) {
        val appCtx = context.applicationContext
        if (!isConfigured(appCtx)) return
        syncExecutor.schedule(
            { syncNow(appCtx, trigger = "post_call_3s") },
            3000L,
            TimeUnit.MILLISECONDS
        )
        syncExecutor.schedule(
            { syncNow(appCtx, trigger = "post_call_8s") },
            8500L,
            TimeUnit.MILLISECONDS
        )
    }

    fun syncNow(context: Context, trigger: String = "manual"): Map<String, Any?> {
        val appCtx = context.applicationContext
        synchronized(syncLock) {
            val prefs = appCtx.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            if (!isConfigured(appCtx)) {
                return mapOf(
                    "importedCount" to 0,
                    "scannedCount" to 0,
                    "status" to getStatus(appCtx)
                )
            }

            var importedCount = 0
            var scannedCount = 0
            var errorMsg = ""
            try {
                val now = System.currentTimeMillis()
                val cutoffMs = now - RETENTION_MS
                val candidates = ArrayList<CandidateFile>()
                val seenSigs = HashSet<String>()

                getPersistedTreeUri(appCtx)?.let { treeUri ->
                    collectFromSafTree(appCtx, treeUri, cutoffMs, now, candidates, seenSigs)
                }

                if (hasMediaAudioPermission(appCtx)) {
                    collectFromDirectCallDirs(cutoffMs, now, candidates, seenSigs)
                    collectFromMediaStore(appCtx, cutoffMs, now, candidates, seenSigs)
                }

                candidates.sortByDescending { it.lastModifiedMs }
                val limited = if (candidates.size > MAX_FILES_PER_SYNC) {
                    candidates.take(MAX_FILES_PER_SYNC)
                } else {
                    candidates
                }
                scannedCount = limited.size

                for (cand in limited) {
                    val sig = cand.signature()
                    if (CallRecordingStore.hasSystemSignature(appCtx, sig)) {
                        continue
                    }
                    if (importCandidate(appCtx, cand, sig)) {
                        importedCount++
                    }
                }
            } catch (e: Exception) {
                Log.w(TAG, "Lỗi đồng bộ ghi âm máy ($trigger)", e)
                errorMsg = e.message ?: "Lỗi đọc thư mục ghi âm"
            }

            prefs.edit()
                .putLong(KEY_LAST_SYNC_MS, System.currentTimeMillis())
                .putInt(KEY_LAST_IMPORTED_COUNT, importedCount)
                .putString(KEY_LAST_ERROR, errorMsg)
                .apply()

            Log.i(
                TAG,
                "Sync($trigger): scanned=$scannedCount imported=$importedCount err=${errorMsg.ifEmpty { "none" }}"
            )
            return mapOf(
                "importedCount" to importedCount,
                "scannedCount" to scannedCount,
                "status" to getStatus(appCtx)
            )
        }
    }

    private fun importCandidate(
        context: Context,
        cand: CandidateFile,
        signature: String
    ): Boolean {
        val meta = parseSystemFilenameMetadata(cand.displayName, cand.lastModifiedMs)
        val approxStartMs = (meta.timestampMs ?: cand.lastModifiedMs)
            .coerceAtMost(System.currentTimeMillis())
        val hashTag = shortHash(signature)
        val finalFile = CallRecordingStore.createImportedRecordingFile(
            context = context,
            startedAt = approxStartMs,
            extension = cand.extension,
            hashTag = hashTag
        )
        val tmpFile = File(finalFile.parentFile, "${finalFile.name}.tmp")

        try {
            val stream = cand.openStream() ?: return false
            stream.use { input ->
                FileOutputStream(tmpFile, false).use { output ->
                    val buffer = ByteArray(8192)
                    while (true) {
                        val read = input.read(buffer)
                        if (read <= 0) break
                        output.write(buffer, 0, read)
                    }
                    output.flush()
                }
            }

            if (!tmpFile.exists() || tmpFile.length() < MIN_VALID_FILE_BYTES) {
                tmpFile.delete()
                return false
            }

            val probe = probeAudioFile(tmpFile)
            if (!probe.hasAudio || probe.durationMs < 700L) {
                tmpFile.delete()
                return false
            }

            if (finalFile.exists()) finalFile.delete()
            if (!tmpFile.renameTo(finalFile)) {
                tmpFile.copyTo(finalFile, overwrite = true)
                tmpFile.delete()
            }

            val endedAtMs = if (cand.lastModifiedMs > approxStartMs) {
                cand.lastModifiedMs
            } else {
                approxStartMs + probe.durationMs
            }

            val matchedCallLog = CallRecordingStore.findMatchingCallLogForSystemFile(
                context = context,
                startedAtHintMs = approxStartMs,
                endedAtHintMs = endedAtMs,
                durationMs = probe.durationMs,
                phoneHint = meta.phoneNumber
            )

            val resolvedPhone = matchedCallLog?.number?.ifBlank { meta.phoneNumber } ?: meta.phoneNumber
            val resolvedName = matchedCallLog?.name?.ifBlank { meta.contactHint } ?: meta.contactHint
            val resolvedCallType = matchedCallLog?.callType?.takeIf { it == 1 || it == 2 }
                ?: meta.callTypeHint
            val resolvedStartMs = matchedCallLog?.dateMs?.takeIf { it > 0L } ?: approxStartMs
            val resolvedEndMs = resolvedStartMs + probe.durationMs

            CallRecordingStore.saveRecording(
                context = context,
                id = "sys_${resolvedStartMs}_$hashTag",
                file = finalFile,
                phoneNumber = resolvedPhone,
                contactName = resolvedName,
                callType = resolvedCallType,
                startedAt = resolvedStartMs,
                endedAt = resolvedEndMs,
                durationMs = probe.durationMs,
                audioSource = "SYSTEM_DIALER",
                callLogId = matchedCallLog?.callLogId ?: -1,
                peakAmplitude = 1000,
                origin = "system_dialer",
                sourceSignature = signature
            )
            return true
        } catch (e: Exception) {
            Log.w(TAG, "Không thể nhập file ${cand.displayName}: ${e.message}")
            try { if (tmpFile.exists()) tmpFile.delete() } catch (_: Exception) {}
            try { if (finalFile.exists()) finalFile.delete() } catch (_: Exception) {}
            return false
        }
    }

    private data class AudioProbe(val hasAudio: Boolean, val durationMs: Long)

    private fun probeAudioFile(file: File): AudioProbe {
        val mmr = MediaMetadataRetriever()
        return try {
            mmr.setDataSource(file.absolutePath)
            val hasAudioStr = mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_HAS_AUDIO)
            val durStr = mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
            val durationMs = durStr?.toLongOrNull() ?: 0L
            val hasAudio = hasAudioStr == null || hasAudioStr.equals("yes", ignoreCase = true)
            AudioProbe(hasAudio = hasAudio && durationMs > 0L, durationMs = durationMs)
        } catch (_: Exception) {
            AudioProbe(hasAudio = false, durationMs = 0L)
        } finally {
            try { mmr.release() } catch (_: Exception) {}
        }
    }

    private fun collectFromSafTree(
        context: Context,
        treeUri: Uri,
        cutoffMs: Long,
        nowMs: Long,
        out: MutableList<CandidateFile>,
        seenSigs: MutableSet<String>
    ) {
        val rootDocId = try {
            DocumentsContract.getTreeDocumentId(treeUri)
        } catch (_: Exception) {
            return
        }
        walkSafFolder(context, treeUri, rootDocId, 0, cutoffMs, nowMs, out, seenSigs)
    }

    private fun walkSafFolder(
        context: Context,
        treeUri: Uri,
        folderDocId: String,
        depth: Int,
        cutoffMs: Long,
        nowMs: Long,
        out: MutableList<CandidateFile>,
        seenSigs: MutableSet<String>
    ) {
        if (depth > MAX_SAF_DEPTH) return
        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, folderDocId)
        val projection = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
            DocumentsContract.Document.COLUMN_SIZE,
            DocumentsContract.Document.COLUMN_LAST_MODIFIED
        )

        var cursor: Cursor? = null
        try {
            cursor = context.contentResolver.query(childrenUri, projection, null, null, null)
            if (cursor == null) return
            val colId = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
            val colName = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
            val colMime = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_MIME_TYPE)
            val colSize = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_SIZE)
            val colMod = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_LAST_MODIFIED)

            while (cursor.moveToNext()) {
                val docId = if (colId != -1) cursor.getString(colId) else null
                val name = if (colName != -1) cursor.getString(colName) else null
                val mime = if (colMime != -1) cursor.getString(colMime) else ""
                val size = if (colSize != -1) cursor.getLong(colSize) else 0L
                val lastMod = if (colMod != -1) cursor.getLong(colMod) else 0L
                if (docId.isNullOrBlank() || name.isNullOrBlank()) continue

                if (mime == DocumentsContract.Document.MIME_TYPE_DIR) {
                    walkSafFolder(context, treeUri, docId, depth + 1, cutoffMs, nowMs, out, seenSigs)
                    continue
                }

                val ext = name.substringAfterLast('.', "").lowercase()
                if (!AUDIO_EXTS.contains(ext) && !mime.startsWith("audio/")) continue
                if (size < MIN_VALID_FILE_BYTES) continue
                if (lastMod > 0L && lastMod < cutoffMs) continue
                if (lastMod > 0L && (nowMs - lastMod) < FRESH_WRITE_GUARD_MS) continue

                val docUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, docId)
                val cand = CandidateFile(
                    displayName = name,
                    sizeBytes = size,
                    lastModifiedMs = lastMod,
                    extension = if (AUDIO_EXTS.contains(ext)) ext else "mp3",
                    openStream = { context.contentResolver.openInputStream(docUri) }
                )
                if (seenSigs.add(cand.signature())) {
                    out.add(cand)
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "Lỗi đọc thư mục SAF $folderDocId: ${e.message}")
        } finally {
            try { cursor?.close() } catch (_: Exception) {}
        }
    }

    private fun collectFromDirectCallDirs(
        cutoffMs: Long,
        nowMs: Long,
        out: MutableList<CandidateFile>,
        seenSigs: MutableSet<String>
    ) {
        val extRoot = try {
            Environment.getExternalStorageDirectory()
        } catch (_: Exception) {
            null
        } ?: return

        for (rel in KNOWN_REL_CALL_DIRS) {
            val dir = File(extRoot, rel)
            if (!dir.exists() || !dir.isDirectory) continue
            val files = dir.listFiles() ?: continue
            for (f in files) {
                if (!f.isFile) continue
                val ext = f.extension.lowercase()
                if (!AUDIO_EXTS.contains(ext)) continue
                val size = f.length()
                val mod = f.lastModified()
                if (size < MIN_VALID_FILE_BYTES || mod < cutoffMs) continue
                if ((nowMs - mod) < FRESH_WRITE_GUARD_MS) continue

                val cand = CandidateFile(
                    displayName = f.name,
                    sizeBytes = size,
                    lastModifiedMs = mod,
                    extension = ext,
                    openStream = { FileInputStream(f) }
                )
                if (seenSigs.add(cand.signature())) {
                    out.add(cand)
                }
            }
        }
    }

    private fun collectFromMediaStore(
        context: Context,
        cutoffMs: Long,
        nowMs: Long,
        out: MutableList<CandidateFile>,
        seenSigs: MutableSet<String>
    ) {
        val projection = ArrayList<String>().apply {
            add(MediaStore.Audio.Media._ID)
            add(MediaStore.Audio.Media.DISPLAY_NAME)
            add(MediaStore.Audio.Media.SIZE)
            add(MediaStore.Audio.Media.DATE_MODIFIED)
            add(MediaStore.Audio.Media.DATA)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                add(MediaStore.Audio.Media.RELATIVE_PATH)
            }
        }.toTypedArray()

        val cutoffSec = cutoffMs / 1000L
        val selection = "${MediaStore.Audio.Media.DATE_MODIFIED} >= ?"
        val sortOrder = "${MediaStore.Audio.Media.DATE_MODIFIED} DESC"

        try {
            context.contentResolver.query(
                MediaStore.Audio.Media.EXTERNAL_CONTENT_URI,
                projection,
                selection,
                arrayOf(cutoffSec.toString()),
                sortOrder
            )?.use { c ->
                val colId = c.getColumnIndex(MediaStore.Audio.Media._ID)
                val colName = c.getColumnIndex(MediaStore.Audio.Media.DISPLAY_NAME)
                val colSize = c.getColumnIndex(MediaStore.Audio.Media.SIZE)
                val colMod = c.getColumnIndex(MediaStore.Audio.Media.DATE_MODIFIED)
                val colData = c.getColumnIndex(MediaStore.Audio.Media.DATA)
                val colRel = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    c.getColumnIndex(MediaStore.Audio.Media.RELATIVE_PATH)
                } else -1

                while (c.moveToNext()) {
                    val dataPath = if (colData != -1) c.getString(colData) ?: "" else ""
                    val relPath = if (colRel != -1) c.getString(colRel) ?: "" else ""
                    val combinedLower = "$dataPath $relPath".lowercase()
                    if (KNOWN_PATH_HINTS.none { combinedLower.contains(it) }) continue

                    val id = if (colId != -1) c.getLong(colId) else -1L
                    val name = if (colName != -1) c.getString(colName) ?: "" else ""
                    val size = if (colSize != -1) c.getLong(colSize) else 0L
                    val modMs = (if (colMod != -1) c.getLong(colMod) else 0L) * 1000L
                    if (id <= 0L || name.isBlank() || size < MIN_VALID_FILE_BYTES) continue
                    if (modMs > 0L && (nowMs - modMs) < FRESH_WRITE_GUARD_MS) continue

                    val ext = name.substringAfterLast('.', "").lowercase()
                    if (!AUDIO_EXTS.contains(ext)) continue

                    val uri = Uri.withAppendedPath(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, id.toString())
                    val cand = CandidateFile(
                        displayName = name,
                        sizeBytes = size,
                        lastModifiedMs = modMs,
                        extension = ext,
                        openStream = { context.contentResolver.openInputStream(uri) }
                    )
                    if (seenSigs.add(cand.signature())) {
                        out.add(cand)
                    }
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "Lỗi truy vấn MediaStore call_rec: ${e.message}")
        }
    }

    private fun parseSystemFilenameMetadata(fileName: String, fallbackMs: Long): ParsedFilenameMeta {
        val base = fileName.substringBeforeLast('.')
        val lower = base.lowercase()

        val callTypeHint = when {
            lower.contains("gọi đi") || lower.contains("goi di") || lower.contains("outgoing") -> 2
            lower.contains("cuộc gọi đến") || lower.contains("gọi đến") || lower.contains("incoming") -> 1
            else -> 1
        }

        // 1) Tách timestamp trước để tránh nhận nhầm chuỗi 14 số yyyyMMddHHmmss thành số điện thoại
        var parsedTs: Long? = null
        var work = base
        val fullTsRegex = Regex("""(20\d{2})[-_]?([01]\d)[-_]?([0-3]\d)[-_]?([0-2]\d)[-_]?([0-5]\d)[-_]?([0-5]\d)""")
        val shortTsRegex = Regex("""(\d{2})([01]\d)([0-3]\d)[-_]([0-2]\d)([0-5]\d)([0-5]\d)""")
        fullTsRegex.find(base)?.let { m ->
            val compact = "${m.groupValues[1]}${m.groupValues[2]}${m.groupValues[3]}${m.groupValues[4]}${m.groupValues[5]}${m.groupValues[6]}"
            parsedTs = tryParseDate(compact, "yyyyMMddHHmmss")
            work = work.replace(m.value, " ")
        }
        if (parsedTs == null) {
            shortTsRegex.find(base)?.let { m ->
                val compact = "20${m.groupValues[1]}${m.groupValues[2]}${m.groupValues[3]}${m.groupValues[4]}${m.groupValues[5]}${m.groupValues[6]}"
                parsedTs = tryParseDate(compact, "yyyyMMddHHmmss")
                work = work.replace(m.value, " ")
            }
        }

        // 2) Tách số điện thoại: ưu tiên trong ngoặc "(0938308279)" kiểu Xiaomi MIUI Dialer
        val parenPhoneRegex = Regex("""\((\+?\d[\d\s\-]{7,15}\d)\)""")
        val genericPhoneRegex = Regex("""(\+?84\d{8,10}|0\d{8,10}|\d{9,11})""")
        var phone = parenPhoneRegex.find(work)?.groupValues?.getOrNull(1)
            ?.replace(Regex("""[^\d+]"""), "") ?: ""
        if (phone.isBlank()) {
            phone = genericPhoneRegex.find(work)?.value?.replace(Regex("""[^\d+]"""), "") ?: ""
        }

        // 3) Lấy phần tên gợi ý nếu có (VD: "Gọi đi@Nguyễn Văn A(0938...)" -> "Nguyễn Văn A")
        var contactHint = work
            .replace(Regex("""\([^)]*\)"""), "")
            .substringAfterLast('@')
            .replace(Regex("""^(call recording|ghi âm cuộc gọi|cuộc gọi|call)[\s_-]*""", RegexOption.IGNORE_CASE), "")
            .trim(' ', '_', '-', '@')
        if (phone.isNotEmpty() && contactHint.replace(Regex("""\D"""), "") == phone.replace(Regex("""\D"""), "")) {
            contactHint = ""
        }

        return ParsedFilenameMeta(
            phoneNumber = phone,
            contactHint = contactHint,
            callTypeHint = callTypeHint,
            timestampMs = parsedTs ?: fallbackMs
        )
    }

    private fun tryParseDate(compact: String, pattern: String): Long? {
        return try {
            val sdf = SimpleDateFormat(pattern, Locale.US).apply { isLenient = false }
            sdf.parse(compact)?.time
        } catch (_: Exception) {
            null
        }
    }

    private fun buildInitialFolderHintUri(): Uri? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return null
        val extRoot = try {
            Environment.getExternalStorageDirectory()
        } catch (_: Exception) {
            null
        }
        val candidates = listOf(
            "MIUI/sound_recorder/call_rec",
            "Recordings/Call",
            "MIUI/sound_recorder",
            "Recordings",
            "CallRecordings"
        )
        val chosen = candidates.firstOrNull { rel ->
            extRoot != null && File(extRoot, rel).exists()
        } ?: if (Build.MANUFACTURER.equals("Xiaomi", ignoreCase = true) ||
            Build.MANUFACTURER.equals("Redmi", ignoreCase = true) ||
            Build.MANUFACTURER.equals("POCO", ignoreCase = true)
        ) {
            "MIUI/sound_recorder/call_rec"
        } else {
            "Recordings/Call"
        }

        return DocumentsContract.buildDocumentUri(
            "com.android.externalstorage.documents",
            "primary:$chosen"
        )
    }

    private fun detectBestSuggestedFolderLabel(): String {
        val extRoot = try {
            Environment.getExternalStorageDirectory()
        } catch (_: Exception) {
            null
        }
        val ordered = listOf("MIUI/sound_recorder/call_rec", "Recordings/Call", "CallRecordings")
        if (extRoot != null) {
            for (rel in ordered) {
                if (File(extRoot, rel).exists()) return rel
            }
        }
        return if (Build.MANUFACTURER.equals("Xiaomi", ignoreCase = true) ||
            Build.BRAND.equals("Xiaomi", ignoreCase = true) ||
            Build.BRAND.equals("Redmi", ignoreCase = true) ||
            Build.BRAND.equals("POCO", ignoreCase = true)
        ) {
            "MIUI/sound_recorder/call_rec"
        } else {
            "Recordings/Call"
        }
    }

    private fun decodeTreeLabel(uri: Uri): String {
        return try {
            val docId = DocumentsContract.getTreeDocumentId(uri)
            when {
                docId.startsWith("primary:") -> docId.removePrefix("primary:")
                docId.contains(':') -> docId.substringAfter(':')
                else -> docId
            }.ifBlank { uri.lastPathSegment ?: "Thư mục đã chọn" }
        } catch (_: Exception) {
            uri.lastPathSegment ?: "Thư mục đã chọn"
        }
    }

    private fun shortHash(input: String): String {
        return try {
            val bytes = MessageDigest.getInstance("SHA-1").digest(input.toByteArray(Charsets.UTF_8))
            bytes.take(4).joinToString("") { "%02x".format(it) }
        } catch (_: Exception) {
            (input.hashCode().toUInt()).toString(16)
        }
    }
}
