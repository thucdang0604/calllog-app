package com.example.call_log_manager;

import android.content.ContentValues;
import android.content.Context;
import android.content.SharedPreferences;
import android.database.Cursor;
import android.net.Uri;
import android.os.Build;
import android.os.Environment;
import android.provider.Settings;
import android.provider.Telephony;
import android.util.Log;

import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStreamReader;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.Locale;
import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;

public final class LicenseManager {
    private static final String TAG = "LicenseManager";

    // Secret salt used for HMAC signing of license keys and trial integrity
    private static final String SECRET_SALT = "NVPTTT_SMS_LICENSE_SALT_2026_@!";

    private static final String PREFS_NAME = "nv_sms_license_prefs";
    private static final String KEY_LICENSE_KEY = "activated_license_key";
    private static final String KEY_LICENSE_PLAN = "activated_license_plan";
    private static final String KEY_EXPIRES_AT = "activated_expires_at";
    private static final String KEY_TRIAL_USED = "trial_sms_used_count";
    private static final String KEY_LAST_KNOWN_TIME = "last_known_system_time";

    public static final int MAX_TRIAL_COUNT = 10;

    // Optional online activation endpoint (can be configured or left as default Google Apps Script / Worker)
    private static final String DEFAULT_ONLINE_ENDPOINT = "https://script.google.com/macros/s/AKfycby-YOUR-ENDPOINT/exec";

    private LicenseManager() {}

    /**
     * Generates a unique, persistent hardware-bound Device ID.
     * Format: SMS-XXXX-XXXX (8 hex characters)
     */
    public static synchronized String getDeviceId(Context context) {
        try {
            String androidId = Settings.Secure.getString(
                context.getContentResolver(), Settings.Secure.ANDROID_ID);
            if (androidId == null || androidId.isEmpty() || "9774d56d682e549c".equals(androidId)) {
                androidId = Build.BOARD + "_" + Build.BRAND + "_" + Build.DEVICE + "_" + Build.MODEL;
            }
            String raw = androidId + ":NVPTTT_DEVICE_FINGERPRINT_2026";
            MessageDigest md = MessageDigest.getInstance("SHA-256");
            byte[] hash = md.digest(raw.getBytes(StandardCharsets.UTF_8));
            StringBuilder sb = new StringBuilder();
            for (int i = 0; i < 4; i++) {
                sb.append(String.format("%02X", hash[i]));
            }
            sb.append("-");
            for (int i = 4; i < 8; i++) {
                sb.append(String.format("%02X", hash[i]));
            }
            return "SMS-" + sb.toString();
        } catch (Exception e) {
            Log.e(TAG, "Error generating device ID", e);
            return "SMS-0000-0000";
        }
    }

    /**
     * Checks if the fake SMS feature is currently available (either active license or trial remaining).
     */
    public static boolean isSmsFeatureAvailable(Context context) {
        if (isLicenseActive(context)) {
            return true;
        }
        return getRemainingTrial(context) > 0;
    }

    /**
     * Checks if a valid, unexpired license is active.
     */
    public static boolean isLicenseActive(Context context) {
        SharedPreferences prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE);
        String key = prefs.getString(KEY_LICENSE_KEY, "");
        if (key.isEmpty()) {
            // Also check persistent external file
            key = readExternalLicenseKey(context);
            if (key.isEmpty()) return false;
        }

        LicenseInfo info = verifyLicenseKey(context, key);
        if (info != null && info.isValid) {
            // Anti clock-rollback check
            long now = System.currentTimeMillis();
            long lastTime = prefs.getLong(KEY_LAST_KNOWN_TIME, 0L);
            if (now < lastTime - 3600_000L) { // Clock wound back more than 1 hour
                Log.w(TAG, "System clock rollback detected");
            }
            prefs.edit().putLong(KEY_LAST_KNOWN_TIME, Math.max(now, lastTime)).apply();

            return true;
        }
        return false;
    }

    /**
     * Returns remaining trial count (0 to 10).
     * Synchronizes across local SharedPreferences, external persistent file, and system SMS marker.
     */
    public static int getRemainingTrial(Context context) {
        if (isLicenseActive(context)) {
            return MAX_TRIAL_COUNT;
        }
        int used = getUsedTrialCount(context);
        return Math.max(0, MAX_TRIAL_COUNT - used);
    }

    /**
     * Returns the highest trial usage found across all storage layers (survives app reinstallation).
     */
    public static synchronized int getUsedTrialCount(Context context) {
        SharedPreferences prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE);
        int localCount = prefs.getInt(KEY_TRIAL_USED, 0);

        // Check external file (persists on sdcard even if app is uninstalled)
        int externalCount = readExternalTrialCount(context);

        // Check system SMS marker count (persists in Android telephony provider)
        int systemMarkerCount = readSystemSmsTrialCount(context);

        // Always take the maximum observed count
        int maxUsed = Math.max(localCount, Math.max(externalCount, systemMarkerCount));

        // Sync back if local was lower (e.g. freshly reinstalled app)
        if (localCount < maxUsed) {
            prefs.edit().putInt(KEY_TRIAL_USED, maxUsed).apply();
        }
        if (externalCount < maxUsed) {
            writeExternalTrialCount(context, maxUsed);
        }

        return maxUsed;
    }

    /**
     * Consumes 1 trial message count and syncs across all persistence layers.
     */
    public static synchronized void consumeTrial(Context context) {
        if (isLicenseActive(context)) {
            return; // Licensed users do not consume trial
        }
        int current = getUsedTrialCount(context);
        int updated = Math.min(MAX_TRIAL_COUNT, current + 1);

        // 1. Save to SharedPreferences
        SharedPreferences prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE);
        prefs.edit().putInt(KEY_TRIAL_USED, updated).apply();

        // 2. Save to persistent external file
        writeExternalTrialCount(context, updated);

        // 3. Write system SMS marker
        writeSystemSmsTrialMarker(context, updated);

        Log.d(TAG, "Consumed trial SMS. Used: " + updated + "/" + MAX_TRIAL_COUNT);
    }

    // ==================== License Verification & Activation ====================

    public static class LicenseInfo {
        public final boolean isValid;
        public final String plan;
        public final long expiresAt;
        public final String message;

        public LicenseInfo(boolean isValid, String plan, long expiresAt, String message) {
            this.isValid = isValid;
            this.plan = plan;
            this.expiresAt = expiresAt;
            this.message = message;
        }
    }

    /**
     * Verifies a license key against the current device ID.
     * Key structure: NV1-[PLAN]-[EXP_HEX]-[SIGNATURE_8_HEX]
     * e.g. NV1-PERM-00000000-8F2A1C9E or NV1-30D-673C1200-B8A29F41
     */
    public static LicenseInfo verifyLicenseKey(Context context, String key) {
        if (key == null) return new LicenseInfo(false, "", 0L, "Mã không được để trống");
        String cleanKey = key.trim().toUpperCase().replaceAll("\\s+", "");

        String[] parts = cleanKey.split("-");
        if (parts.length != 4 || !"NV1".equals(parts[0])) {
            return new LicenseInfo(false, "", 0L, "Định dạng mã không hợp lệ");
        }

        String plan = parts[1]; // PERM, 30D, 90D, 1Y
        String expHex = parts[2];
        String signature = parts[3];

        String deviceId = getDeviceId(context);

        // Verify HMAC
        String expectedSig = generateSignature(deviceId, plan, expHex);
        if (!expectedSig.equalsIgnoreCase(signature)) {
            return new LicenseInfo(false, "", 0L, "Mã kích hoạt không khớp với thiết bị này");
        }

        long expiresAt = 0L;
        if (!"PERM".equals(plan)) {
            try {
                long epochSec = Long.parseLong(expHex, 16);
                expiresAt = epochSec * 1000L;
                if (System.currentTimeMillis() > expiresAt) {
                    return new LicenseInfo(false, plan, expiresAt, "Bản quyền đã hết hạn vào " + formatDate(expiresAt));
                }
            } catch (Exception e) {
                return new LicenseInfo(false, "", 0L, "Thời hạn trong mã không hợp lệ");
            }
        }

        String msg = "PERM".equals(plan) ? "Bản quyền Vĩnh viễn" : "Hạn dùng đến " + formatDate(expiresAt);
        return new LicenseInfo(true, plan, expiresAt, msg);
    }

    /**
     * Activates a license key on this device.
     */
    public static boolean activateKey(Context context, String key) {
        LicenseInfo info = verifyLicenseKey(context, key);
        if (!info.isValid) {
            return false;
        }

        String cleanKey = key.trim().toUpperCase().replaceAll("\\s+", "");
        SharedPreferences prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE);
        prefs.edit()
            .putString(KEY_LICENSE_KEY, cleanKey)
            .putString(KEY_LICENSE_PLAN, info.plan)
            .putLong(KEY_EXPIRES_AT, info.expiresAt)
            .apply();

        // Also save to external file so license survives app uninstall
        writeExternalLicenseKey(context, cleanKey);

        return true;
    }

    /**
     * Generates a signature for Device ID + Plan + ExpireHex.
     * Exported for generator / verification.
     */
    public static String generateSignature(String deviceId, String plan, String expHex) {
        try {
            String payload = deviceId + ":" + plan + ":" + expHex;
            Mac mac = Mac.getInstance("HmacSHA256");
            mac.init(new SecretKeySpec(SECRET_SALT.getBytes(StandardCharsets.UTF_8), "HmacSHA256"));
            byte[] hash = mac.doFinal(payload.getBytes(StandardCharsets.UTF_8));
            StringBuilder sb = new StringBuilder();
            for (int i = 0; i < 4; i++) { // 4 bytes = 8 hex chars
                sb.append(String.format("%02X", hash[i]));
            }
            return sb.toString();
        } catch (Exception e) {
            return "00000000";
        }
    }

    /**
     * Helper to create a license key (used by developer or testing).
     */
    public static String createLicenseKey(String deviceId, String plan, long expiresAtMillis) {
        String expHex = "PERM".equalsIgnoreCase(plan)
            ? "00000000"
            : String.format("%08X", expiresAtMillis / 1000L);
        String planUpper = plan.toUpperCase();
        String sig = generateSignature(deviceId.toUpperCase(), planUpper, expHex);
        return "NV1-" + planUpper + "-" + expHex + "-" + sig;
    }

    public static JSONObject getLicenseDetails(Context context) {
        JSONObject obj = new JSONObject();
        try {
            String deviceId = getDeviceId(context);
            boolean isLicensed = isLicenseActive(context);
            int remaining = getRemainingTrial(context);
            int used = getUsedTrialCount(context);

            SharedPreferences prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE);
            String plan = prefs.getString(KEY_LICENSE_PLAN, "TRIAL");
            long expiresAt = prefs.getLong(KEY_EXPIRES_AT, 0L);

            obj.put("deviceId", deviceId);
            obj.put("isLicensed", isLicensed);
            obj.put("remainingTrial", remaining);
            obj.put("usedTrial", used);
            obj.put("maxTrial", MAX_TRIAL_COUNT);
            obj.put("plan", isLicensed ? plan : (remaining > 0 ? "TRIAL" : "EXPIRED"));
            obj.put("expiresAt", expiresAt);
            obj.put("expiresAtFormatted", expiresAt > 0 ? formatDate(expiresAt) : (isLicensed ? "Vĩnh viễn" : ""));
        } catch (Exception ignored) {}
        return obj;
    }

    // ==================== Persistence Layers (Anti-Reinstall Reset) ====================

    private static File getExternalMarkerFile() {
        try {
            File dir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS);
            if (dir != null && (dir.exists() || dir.mkdirs())) {
                return new File(dir, ".nv_sms_vault.bin");
            }
        } catch (Exception ignored) {}
        return null;
    }

    private static int readExternalTrialCount(Context context) {
        File file = getExternalMarkerFile();
        if (file == null || !file.exists()) return 0;
        try (BufferedReader reader = new BufferedReader(new InputStreamReader(new FileInputStream(file), StandardCharsets.UTF_8))) {
            String line = reader.readLine();
            if (line != null && !line.isEmpty()) {
                JSONObject json = new JSONObject(line);
                String expectedDevice = getDeviceId(context);
                if (expectedDevice.equals(json.optString("dev"))) {
                    return json.optInt("trial_used", 0);
                }
            }
        } catch (Exception ignored) {}
        return 0;
    }

    private static void writeExternalTrialCount(Context context, int count) {
        File file = getExternalMarkerFile();
        if (file == null) return;
        try {
            JSONObject json = new JSONObject();
            json.put("dev", getDeviceId(context));
            json.put("trial_used", count);
            json.put("time", System.currentTimeMillis());
            try (FileOutputStream fos = new FileOutputStream(file, false)) {
                fos.write(json.toString().getBytes(StandardCharsets.UTF_8));
            }
        } catch (Exception ignored) {}
    }

    private static String readExternalLicenseKey(Context context) {
        File file = getExternalMarkerFile();
        if (file == null || !file.exists()) return "";
        try (BufferedReader reader = new BufferedReader(new InputStreamReader(new FileInputStream(file), StandardCharsets.UTF_8))) {
            String line = reader.readLine();
            if (line != null && !line.isEmpty()) {
                JSONObject json = new JSONObject(line);
                String expectedDevice = getDeviceId(context);
                if (expectedDevice.equals(json.optString("dev"))) {
                    return json.optString("license_key", "");
                }
            }
        } catch (Exception ignored) {}
        return "";
    }

    private static void writeExternalLicenseKey(Context context, String key) {
        File file = getExternalMarkerFile();
        if (file == null) return;
        try {
            JSONObject json = new JSONObject();
            int currentUsed = getUsedTrialCount(context);
            json.put("dev", getDeviceId(context));
            json.put("trial_used", currentUsed);
            json.put("license_key", key);
            json.put("time", System.currentTimeMillis());
            try (FileOutputStream fos = new FileOutputStream(file, false)) {
                fos.write(json.toString().getBytes(StandardCharsets.UTF_8));
            }
        } catch (Exception ignored) {}
    }

    /**
     * Checks how many trial markers exist in Android's system SMS Sent database.
     * Since CallLog is default SMS app, it can query Telephony.Sms.Sent.
     */
    private static int readSystemSmsTrialCount(Context context) {
        try {
            Uri uri = Telephony.Sms.Sent.CONTENT_URI;
            String[] projection = new String[] { Telephony.Sms._ID, Telephony.Sms.BODY };
            // Marker prefix embedded into trial SMS bodies
            String selection = Telephony.Sms.BODY + " LIKE '%[NVPTTT-SIM]%' OR " + Telephony.Sms.BODY + " LIKE '%\u200B\u200C%'";
            try (Cursor cursor = context.getContentResolver().query(uri, projection, selection, null, null)) {
                if (cursor != null) {
                    return cursor.getCount();
                }
            }
        } catch (Exception ignored) {}
        return 0;
    }

    private static void writeSystemSmsTrialMarker(Context context, int count) {
        // Can be embedded invisibly (zero-width non-joiner) when fake SMS is written
    }

    private static String formatDate(long millis) {
        SimpleDateFormat sdf = new SimpleDateFormat("dd/MM/yyyy", Locale.getDefault());
        return sdf.format(new Date(millis));
    }
}
