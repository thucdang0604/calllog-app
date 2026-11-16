package com.example.call_log_manager

import android.content.Context
import android.content.SharedPreferences

/**
 * Nguồn cấu hình tập trung cho âm thanh, rung và các cảnh báo trên toàn ứng dụng.
 * Lưu chung trong SharedPreferences("floating_window_state") để mọi Activity, Service
 * và giao diện Flutter đọc/ghi đồng bộ ngay lập tức.
 */
object AppSettingsStore {
    private const val PREF_NAME = "floating_window_state"

    private data class BoolSettingSpec(
        val mapKey: String,
        val prefKey: String,
        val defaultValue: Boolean,
    )

    private const val KEY_BARCODE_SOUND_VOLUME = "barcodeSoundVolume"
    private const val PREF_BARCODE_SOUND_VOLUME = "app_setting_barcode_sound_volume"
    private const val DEFAULT_BARCODE_SOUND_VOLUME = 90

    private val boolSpecs = listOf(
        // Âm thanh
        BoolSettingSpec("soundMasterEnabled", "app_setting_sound_master", true),
        BoolSettingSpec("barcodeSoundEnabled", "app_setting_barcode_sound", true),
        BoolSettingSpec("barcodeSoundNewEnabled", "app_setting_barcode_sound_new", true),
        BoolSettingSpec("barcodeSoundPendingEnabled", "app_setting_barcode_sound_pending", true),
        BoolSettingSpec("barcodeSoundSessionEnabled", "app_setting_barcode_sound_session", true),
        BoolSettingSpec("barcodeSoundSharedEnabled", "app_setting_barcode_sound_shared", true),
        BoolSettingSpec("timeMarkShutterSoundEnabled", "app_setting_timemark_shutter_sound", true),
        // Rung
        BoolSettingSpec("vibrationMasterEnabled", "app_setting_vibration_master", true),
        BoolSettingSpec("barcodeVibrationEnabled", "app_setting_barcode_vibration", true),
        BoolSettingSpec("timeMarkVibrationEnabled", "app_setting_timemark_vibration", true),
        BoolSettingSpec("overlayVibrationEnabled", "app_setting_overlay_vibration", true),
        // Cảnh báo & nhắc nhở
        BoolSettingSpec("barcodeCameraDupWarningEnabled", "app_setting_barcode_camera_dup_warning", true),
        BoolSettingSpec("barcodePostScanDupDialogEnabled", "app_setting_barcode_post_scan_dup_dialog", true),
        BoolSettingSpec("defaultSmsWarningEnabled", "app_setting_default_sms_warning", true),
        BoolSettingSpec("callRecordingSetupWarningEnabled", "app_setting_call_rec_setup_warning", true),
        BoolSettingSpec("callRecordingSilenceWarningEnabled", "app_setting_call_rec_silence_warning", true),
        BoolSettingSpec("autoCheckUpdateEnabled", "app_setting_auto_check_update", true),
    )

    private val specByMapKey: Map<String, BoolSettingSpec> = boolSpecs.associateBy { it.mapKey }

    private fun prefs(context: Context): SharedPreferences =
        context.applicationContext.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)

    private fun getBool(context: Context, mapKey: String): Boolean {
        val spec = specByMapKey[mapKey] ?: return true
        return prefs(context).getBoolean(spec.prefKey, spec.defaultValue)
    }

    @JvmStatic
    fun getAllAsMap(context: Context): Map<String, Any> {
        val sp = prefs(context)
        val result = HashMap<String, Any>(boolSpecs.size + 1)
        for (spec in boolSpecs) {
            result[spec.mapKey] = sp.getBoolean(spec.prefKey, spec.defaultValue)
        }
        result[KEY_BARCODE_SOUND_VOLUME] = sp.getInt(
            PREF_BARCODE_SOUND_VOLUME,
            DEFAULT_BARCODE_SOUND_VOLUME,
        ).coerceIn(0, 100)
        return result
    }

    @JvmStatic
    fun saveFromMap(context: Context, values: Map<String, Any?>?): Map<String, Any> {
        if (values != null) {
            val editor = prefs(context).edit()
            for (spec in boolSpecs) {
                val raw = values[spec.mapKey]
                if (raw is Boolean) {
                    editor.putBoolean(spec.prefKey, raw)
                }
            }
            val rawVol = values[KEY_BARCODE_SOUND_VOLUME]
            if (rawVol is Number) {
                editor.putInt(PREF_BARCODE_SOUND_VOLUME, rawVol.toInt().coerceIn(0, 100))
            }
            editor.apply()
        }
        return getAllAsMap(context)
    }

    @JvmStatic
    fun resetDefaults(context: Context): Map<String, Any> {
        val editor = prefs(context).edit()
        for (spec in boolSpecs) {
            editor.putBoolean(spec.prefKey, spec.defaultValue)
        }
        editor.putInt(PREF_BARCODE_SOUND_VOLUME, DEFAULT_BARCODE_SOUND_VOLUME)
        editor.apply()
        return getAllAsMap(context)
    }

    @JvmStatic
    fun isSoundMasterEnabled(context: Context): Boolean = getBool(context, "soundMasterEnabled")

    @JvmStatic
    fun getBarcodeSoundVolume(context: Context): Int =
        prefs(context).getInt(PREF_BARCODE_SOUND_VOLUME, DEFAULT_BARCODE_SOUND_VOLUME).coerceIn(0, 100)

    @JvmStatic
    fun isBarcodeSoundEnabledFor(context: Context, outcome: BarcodeScanOutcome): Boolean {
        if (!getBool(context, "soundMasterEnabled")) return false
        if (!getBool(context, "barcodeSoundEnabled")) return false
        return when (outcome) {
            BarcodeScanOutcome.NEW_CODE -> getBool(context, "barcodeSoundNewEnabled")
            BarcodeScanOutcome.DUPLICATE_PENDING -> getBool(context, "barcodeSoundPendingEnabled")
            BarcodeScanOutcome.DUPLICATE_SESSION -> getBool(context, "barcodeSoundSessionEnabled")
            BarcodeScanOutcome.DUPLICATE_SHARED -> getBool(context, "barcodeSoundSharedEnabled")
        }
    }

    @JvmStatic
    fun isTimeMarkShutterSoundEnabled(context: Context): Boolean =
        getBool(context, "soundMasterEnabled") && getBool(context, "timeMarkShutterSoundEnabled")

    @JvmStatic
    fun isBarcodeVibrationEnabled(context: Context): Boolean =
        getBool(context, "vibrationMasterEnabled") && getBool(context, "barcodeVibrationEnabled")

    @JvmStatic
    fun isTimeMarkVibrationEnabled(context: Context): Boolean =
        getBool(context, "vibrationMasterEnabled") && getBool(context, "timeMarkVibrationEnabled")

    @JvmStatic
    fun isOverlayVibrationEnabled(context: Context): Boolean =
        getBool(context, "vibrationMasterEnabled") && getBool(context, "overlayVibrationEnabled")

    @JvmStatic
    fun isBarcodeCameraDupWarningEnabled(context: Context): Boolean =
        getBool(context, "barcodeCameraDupWarningEnabled")

    @JvmStatic
    fun isCallRecordingSilenceWarningEnabled(context: Context): Boolean =
        getBool(context, "callRecordingSilenceWarningEnabled")
}
