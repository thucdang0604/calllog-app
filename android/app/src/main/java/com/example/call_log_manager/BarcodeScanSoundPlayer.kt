package com.example.call_log_manager

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.SoundPool
import android.media.ToneGenerator
import android.util.Log
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.roundToInt
import kotlin.math.sin

enum class BarcodeScanOutcome {
    NEW_CODE,
    DUPLICATE_PENDING,
    DUPLICATE_SESSION,
    DUPLICATE_SHARED,
}

object BarcodeScanToneSynthesizer {
    const val SAMPLE_RATE = 44100

    data class ToneSegment(
        val startFreqHz: Double,
        val endFreqHz: Double = startFreqHz,
        val durationMs: Int,
        val gain: Double = 0.8,
        val harmonic2: Double = 0.0,
        val harmonic3: Double = 0.0,
        val attackMs: Int = 6,
        val releaseMs: Int = 16,
    ) {
        companion object {
            fun silence(durationMs: Int): ToneSegment = ToneSegment(
                startFreqHz = 0.0,
                endFreqHz = 0.0,
                durationMs = durationMs,
                gain = 0.0,
                attackMs = 0,
                releaseMs = 0,
            )
        }
    }

    fun resolveOutcome(
        inSharedHistory: Boolean,
        isDuplicateInSession: Boolean,
        inPendingHistory: Boolean,
    ): BarcodeScanOutcome {
        return when {
            inSharedHistory -> BarcodeScanOutcome.DUPLICATE_SHARED
            isDuplicateInSession -> BarcodeScanOutcome.DUPLICATE_SESSION
            inPendingHistory -> BarcodeScanOutcome.DUPLICATE_PENDING
            else -> BarcodeScanOutcome.NEW_CODE
        }
    }

    fun segmentsFor(outcome: BarcodeScanOutcome): List<ToneSegment> {
        return when (outcome) {
            // Bright rising two-note chime ("ti-TING!"): distinct positive confirmation
            BarcodeScanOutcome.NEW_CODE -> listOf(
                ToneSegment(
                    startFreqHz = 1318.5,
                    durationMs = 50,
                    gain = 0.80,
                    harmonic2 = 0.16,
                    attackMs = 5,
                    releaseMs = 12,
                ),
                ToneSegment.silence(16),
                ToneSegment(
                    startFreqHz = 1760.0,
                    durationMs = 105,
                    gain = 0.86,
                    harmonic2 = 0.18,
                    attackMs = 5,
                    releaseMs = 65,
                ),
            )

            // Even mid-pitch double beep ("BIP - BIP"): already in Today's unshared queue
            BarcodeScanOutcome.DUPLICATE_PENDING -> listOf(
                ToneSegment(
                    startFreqHz = 932.3,
                    durationMs = 70,
                    gain = 0.82,
                    harmonic2 = 0.10,
                    harmonic3 = 0.08,
                    attackMs = 6,
                    releaseMs = 16,
                ),
                ToneSegment.silence(55),
                ToneSegment(
                    startFreqHz = 932.3,
                    durationMs = 80,
                    gain = 0.82,
                    harmonic2 = 0.10,
                    harmonic3 = 0.08,
                    attackMs = 6,
                    releaseMs = 22,
                ),
            )

            // Brief soft low dip ("bloop"): already scanned earlier in this camera session
            BarcodeScanOutcome.DUPLICATE_SESSION -> listOf(
                ToneSegment(
                    startFreqHz = 587.3,
                    endFreqHz = 415.3,
                    durationMs = 95,
                    gain = 0.62,
                    harmonic2 = 0.08,
                    attackMs = 6,
                    releaseMs = 35,
                ),
            )

            // Urgent 3-tone descending warning alert ("TO - TE - TO!"): already in Shared list
            BarcodeScanOutcome.DUPLICATE_SHARED -> listOf(
                ToneSegment(
                    startFreqHz = 784.0,
                    durationMs = 70,
                    gain = 0.90,
                    harmonic2 = 0.14,
                    harmonic3 = 0.28,
                    attackMs = 5,
                    releaseMs = 14,
                ),
                ToneSegment.silence(35),
                ToneSegment(
                    startFreqHz = 554.4,
                    durationMs = 70,
                    gain = 0.90,
                    harmonic2 = 0.14,
                    harmonic3 = 0.28,
                    attackMs = 5,
                    releaseMs = 14,
                ),
                ToneSegment.silence(35),
                ToneSegment(
                    startFreqHz = 392.0,
                    durationMs = 125,
                    gain = 0.92,
                    harmonic2 = 0.14,
                    harmonic3 = 0.30,
                    attackMs = 5,
                    releaseMs = 32,
                ),
            )
        }
    }

    fun synthesizeSamples(outcome: BarcodeScanOutcome): ShortArray {
        val segments = segmentsFor(outcome)
        val counts = segments.map { ((it.durationMs.toLong() * SAMPLE_RATE) / 1000L).toInt().coerceAtLeast(0) }
        val totalSamples = counts.sum()
        val output = ShortArray(totalSamples)

        var offset = 0
        for (idx in segments.indices) {
            val segment = segments[idx]
            val count = counts[idx]
            if (count > 0 && segment.startFreqHz > 0.0 && segment.gain > 0.0) {
                renderToneSegment(output, offset, count, segment)
            }
            offset += count
        }
        return output
    }

    private fun renderToneSegment(
        output: ShortArray,
        offset: Int,
        count: Int,
        segment: ToneSegment,
    ) {
        val attackSamples = minOf((segment.attackMs * SAMPLE_RATE) / 1000, count / 2)
        val releaseSamples = minOf((segment.releaseMs * SAMPLE_RATE) / 1000, count - attackSamples)
        val releaseStart = count - releaseSamples

        val harmonicNormalizer = 1.0 + abs(segment.harmonic2) + abs(segment.harmonic3)
        val amplitudeScale = (segment.gain / harmonicNormalizer).coerceIn(0.0, 1.0)
        val freqSpan = segment.endFreqHz - segment.startFreqHz

        var phase = 0.0
        for (i in 0 until count) {
            val t = i.toDouble() / count.toDouble()
            val freq = segment.startFreqHz + freqSpan * t
            phase += (2.0 * PI * freq) / SAMPLE_RATE

            val wave = sin(phase) +
                segment.harmonic2 * sin(2.0 * phase) +
                segment.harmonic3 * sin(3.0 * phase)

            val env = when {
                attackSamples > 0 && i < attackSamples ->
                    0.5 * (1.0 - cos((PI * i) / attackSamples))
                releaseSamples > 0 && i >= releaseStart -> {
                    val releaseProgress = (i - releaseStart + 1).toDouble() / releaseSamples.toDouble()
                    0.5 * (1.0 + cos(PI * releaseProgress))
                }
                else -> 1.0
            }

            val pcm = (wave * amplitudeScale * env * Short.MAX_VALUE)
                .roundToInt()
                .coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt())
                .toShort()
            output[offset + i] = pcm
        }
    }

    fun encodeWav16BitMono(samples: ShortArray, sampleRate: Int = SAMPLE_RATE): ByteArray {
        val dataBytes = samples.size * 2
        val byteRate = sampleRate * 2
        val out = ByteArrayOutputStream(44 + dataBytes)

        fun writeAscii(text: String) {
            for (ch in text) out.write(ch.code and 0xFF)
        }

        fun writeInt32LE(value: Int) {
            out.write(value and 0xFF)
            out.write((value ushr 8) and 0xFF)
            out.write((value ushr 16) and 0xFF)
            out.write((value ushr 24) and 0xFF)
        }

        fun writeInt16LE(value: Int) {
            out.write(value and 0xFF)
            out.write((value ushr 8) and 0xFF)
        }

        writeAscii("RIFF")
        writeInt32LE(36 + dataBytes)
        writeAscii("WAVE")
        writeAscii("fmt ")
        writeInt32LE(16)
        writeInt16LE(1) // PCM
        writeInt16LE(1) // Mono
        writeInt32LE(sampleRate)
        writeInt32LE(byteRate)
        writeInt16LE(2) // Block align
        writeInt16LE(16) // Bits per sample
        writeAscii("data")
        writeInt32LE(dataBytes)

        for (sample in samples) {
            val s = sample.toInt()
            out.write(s and 0xFF)
            out.write((s ushr 8) and 0xFF)
        }
        return out.toByteArray()
    }

    fun buildWavBytes(outcome: BarcodeScanOutcome): ByteArray {
        return encodeWav16BitMono(synthesizeSamples(outcome), SAMPLE_RATE)
    }
}

class BarcodeScanSoundPlayer(context: Context) {

    companion object {
        private const val TAG = "BarcodeScanSound"
        private const val TONE_CACHE_DIR = "barcode_scan_tones"
        private const val TONE_ASSET_VERSION = 1
    }

    private val appContext = context.applicationContext
    private val lock = Any()
    private val isPrepared = AtomicBoolean(false)
    private val isReleased = AtomicBoolean(false)
    private val ioExecutor: ExecutorService = Executors.newSingleThreadExecutor()
    private val soundIds = ConcurrentHashMap<BarcodeScanOutcome, Int>()
    private val loadedSampleIds = ConcurrentHashMap.newKeySet<Int>()

    @Volatile
    private var soundPool: SoundPool? = null
    private var toneGenerator: ToneGenerator? = null
    private var toneGeneratorVolume: Int = -1
    private var activeStreamId: Int = 0
    private var pendingOutcome: BarcodeScanOutcome? = null
    private var pendingVolumePercent: Int = 90

    fun prepareAsync() {
        if (isReleased.get() || !isPrepared.compareAndSet(false, true)) return

        val attrs = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_MEDIA)
            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
            .build()

        val pool = try {
            SoundPool.Builder()
                .setMaxStreams(2)
                .setAudioAttributes(attrs)
                .build()
        } catch (e: Exception) {
            Log.w(TAG, "Không khởi tạo được SoundPool", e)
            null
        }

        pool?.setOnLoadCompleteListener { loadedPool, sampleId, status ->
            if (status == 0 && !isReleased.get()) {
                loadedSampleIds.add(sampleId)
                synchronized(lock) {
                    val waitingOutcome = pendingOutcome
                    if (waitingOutcome != null && soundIds[waitingOutcome] == sampleId) {
                        val waitingVol = pendingVolumePercent
                        pendingOutcome = null
                        playLoadedSampleLocked(loadedPool, sampleId, waitingVol)
                    }
                }
            } else if (status != 0) {
                Log.w(TAG, "Tải âm thanh quét thất bại sampleId=$sampleId status=$status")
            }
        }

        synchronized(lock) {
            if (isReleased.get()) {
                try { pool?.release() } catch (_: Exception) {}
                return
            }
            soundPool = pool
        }

        if (pool == null) return

        try {
            ioExecutor.execute {
                loadToneAssetsIntoPool()
            }
        } catch (e: Exception) {
            Log.w(TAG, "Không thể xếp hàng chuẩn bị âm thanh", e)
        }
    }

    private fun loadToneAssetsIntoPool() {
        try {
            val dir = File(appContext.cacheDir, TONE_CACHE_DIR)
            if (!dir.exists()) {
                dir.mkdirs()
            }
            for (outcome in BarcodeScanOutcome.values()) {
                if (isReleased.get()) return
                val fileName = "scan_${outcome.name.lowercase(Locale.ROOT)}_v$TONE_ASSET_VERSION.wav"
                val file = File(dir, fileName)
                val wavBytes = BarcodeScanToneSynthesizer.buildWavBytes(outcome)
                if (!file.exists() || file.length() != wavBytes.size.toLong()) {
                    FileOutputStream(file).use { it.write(wavBytes) }
                }

                synchronized(lock) {
                    if (isReleased.get()) return
                    val activePool = soundPool ?: return
                    val sampleId = activePool.load(file.absolutePath, 1)
                    if (sampleId > 0) {
                        soundIds[outcome] = sampleId
                    }
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "Lỗi tạo tệp âm thanh quét mã", e)
        }
    }

    fun play(outcome: BarcodeScanOutcome, volumePercent: Int = 90) {
        val clampedVolume = volumePercent.coerceIn(0, 100)
        if (isReleased.get() || clampedVolume <= 0) return
        if (!isPrepared.get()) {
            prepareAsync()
        }
        synchronized(lock) {
            if (isReleased.get()) return
            val pool = soundPool
            val sampleId = soundIds[outcome] ?: 0
            if (pool != null && sampleId > 0 && loadedSampleIds.contains(sampleId)) {
                pendingOutcome = null
                if (playLoadedSampleLocked(pool, sampleId, clampedVolume)) {
                    return
                }
            }
            if (pool != null && (!loadedSampleIds.contains(sampleId) || sampleId == 0)) {
                // Đang nạp SoundPool lần đầu (~15ms): xếp hàng phát ngay khi nạp xong
                pendingOutcome = outcome
                pendingVolumePercent = clampedVolume
                return
            }
            playFallbackTone(outcome, clampedVolume)
        }
    }

    private fun playLoadedSampleLocked(
        pool: SoundPool,
        sampleId: Int,
        volumePercent: Int,
    ): Boolean {
        val gain = (volumePercent.coerceIn(0, 100) / 100f)
        if (gain <= 0f) return true
        if (activeStreamId != 0) {
            try { pool.stop(activeStreamId) } catch (_: Exception) {}
            activeStreamId = 0
        }
        val streamId = try {
            pool.play(sampleId, gain, gain, 1, 0, 1.0f)
        } catch (_: Exception) {
            0
        }
        if (streamId != 0) {
            activeStreamId = streamId
            return true
        }
        return false
    }

    private fun playFallbackTone(outcome: BarcodeScanOutcome, volumePercent: Int) {
        try {
            val scaledVol = (volumePercent * 0.95f).roundToInt().coerceIn(5, 100)
            if (toneGenerator == null || toneGeneratorVolume != scaledVol) {
                try { toneGenerator?.release() } catch (_: Exception) {}
                toneGenerator = ToneGenerator(AudioManager.STREAM_MUSIC, scaledVol)
                toneGeneratorVolume = scaledVol
            }
            val tg = toneGenerator ?: return
            tg.stopTone()
            when (outcome) {
                BarcodeScanOutcome.NEW_CODE ->
                    tg.startTone(ToneGenerator.TONE_PROP_ACK, 130)
                BarcodeScanOutcome.DUPLICATE_PENDING ->
                    tg.startTone(ToneGenerator.TONE_PROP_BEEP2, 180)
                BarcodeScanOutcome.DUPLICATE_SESSION ->
                    tg.startTone(ToneGenerator.TONE_PROP_BEEP, 80)
                BarcodeScanOutcome.DUPLICATE_SHARED ->
                    tg.startTone(ToneGenerator.TONE_SUP_ERROR, 260)
            }
        } catch (e: Exception) {
            Log.w(TAG, "Không phát được âm thanh fallback cho $outcome", e)
        }
    }

    fun release() {
        if (!isReleased.compareAndSet(false, true)) return
        ioExecutor.shutdownNow()
        synchronized(lock) {
            activeStreamId = 0
            soundIds.clear()
            loadedSampleIds.clear()
            try { soundPool?.release() } catch (_: Exception) {}
            soundPool = null
            try { toneGenerator?.release() } catch (_: Exception) {}
            toneGenerator = null
        }
    }
}
