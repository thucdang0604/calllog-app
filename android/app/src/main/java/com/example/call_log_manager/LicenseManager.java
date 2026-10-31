package com.example.call_log_manager;

import android.content.ContentValues;
import android.content.Context;
import android.content.SharedPreferences;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.os.Environment;
import android.provider.Settings;
import android.util.Base64;
import android.util.Log;

import org.json.JSONObject;

import java.io.File;
import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.KeyFactory;
import java.security.Signature;
import java.security.spec.X509EncodedKeySpec;
import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.Locale;
import java.util.UUID;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public final class LicenseManager {
    private static final String TAG = "LicenseManager";

    private static final String PREFS_NAME = "nv_sms_license_prefs";
    private static final String KEY_SERVER_LICENSE_TOKEN = "server_license_token";
    private static final String KEY_TRIAL_USED = "trial_sms_used_count";
    private static final String KEY_LAST_KNOWN_TIME = "last_known_system_time";
    private static final String KEY_LEGACY_DATA_REMOVED = "legacy_license_data_removed";
    private static final String KEY_PENDING_TRIAL_REQUEST = "pending_trial_request_id";
    private static final String KEY_PENDING_TRIAL_FINGERPRINT = "pending_trial_request_fingerprint";
    private static final ExecutorService TRIAL_EXECUTOR = Executors.newSingleThreadExecutor();
    private static final Handler MAIN_HANDLER = new Handler(Looper.getMainLooper());

    public static final int MAX_TRIAL_COUNT = 10;

    private LicenseManager() {}

    /**
     * Generates a unique, persistent hardware-bound Device ID.
     * Format: SMS-XXXXXXXX-XXXXXXXX (16 hex characters)
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
            return "SMS-00000000-00000000";
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
        removeLegacyLicenseData(context);
        SharedPreferences prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE);
        String serverToken = prefs.getString(KEY_SERVER_LICENSE_TOKEN, "");
        if (serverToken == null || serverToken.isEmpty()) return false;
        JSONObject entitlement = verifyServerLicenseToken(context, serverToken);
        if (entitlement == null || !"active".equals(entitlement.optString("status"))) return false;
        long expiresAt = entitlement.isNull("expiresAt") ? 0L : entitlement.optLong("expiresAt", 0L);
        long offlineUntil = entitlement.optLong("offlineUntil", 0L);
        long now = System.currentTimeMillis();
        long lastKnownTime = prefs.getLong(KEY_LAST_KNOWN_TIME, 0L);
        if (now < lastKnownTime - 3600_000L) {
            Log.w(TAG, "System clock rollback detected for server license");
            return false;
        }
        prefs.edit().putLong(KEY_LAST_KNOWN_TIME, Math.max(now, lastKnownTime)).apply();
        return (expiresAt == 0L || expiresAt > now) && offlineUntil > now;
    }

    /** Returns the last server-synchronized trial count (0 to 10). */
    public static int getRemainingTrial(Context context) {
        if (isLicenseActive(context)) {
            return MAX_TRIAL_COUNT;
        }
        int used = getUsedTrialCount(context);
        return Math.max(0, MAX_TRIAL_COUNT - used);
    }

    public static synchronized int getUsedTrialCount(Context context) {
        SharedPreferences prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE);
        return Math.max(0, Math.min(MAX_TRIAL_COUNT, prefs.getInt(KEY_TRIAL_USED, 0)));
    }

    public static synchronized String getTrialRequestId(Context context, String phone, String message) {
        SharedPreferences prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE);
        String fingerprint;
        try {
            byte[] digest = MessageDigest.getInstance("SHA-256").digest(
                ((phone == null ? "" : phone) + "\n" + (message == null ? "" : message))
                    .getBytes(StandardCharsets.UTF_8));
            fingerprint = Base64.encodeToString(digest, Base64.URL_SAFE | Base64.NO_WRAP | Base64.NO_PADDING);
        } catch (Exception error) {
            Log.e(TAG, "Could not fingerprint pending trial request", error);
            return UUID.randomUUID().toString();
        }

        String existingId = prefs.getString(KEY_PENDING_TRIAL_REQUEST, "");
        if (!existingId.isEmpty() && fingerprint.equals(prefs.getString(KEY_PENDING_TRIAL_FINGERPRINT, ""))) {
            return existingId;
        }
        String requestId = UUID.randomUUID().toString();
        prefs.edit().putString(KEY_PENDING_TRIAL_REQUEST, requestId)
            .putString(KEY_PENDING_TRIAL_FINGERPRINT, fingerprint).commit();
        return requestId;
    }

    public static synchronized void completeTrialRequest(Context context, String requestId) {
        SharedPreferences prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE);
        if (requestId.equals(prefs.getString(KEY_PENDING_TRIAL_REQUEST, ""))) {
            prefs.edit().remove(KEY_PENDING_TRIAL_REQUEST)
                .remove(KEY_PENDING_TRIAL_FINGERPRINT).commit();
        }
    }

    public static final class TrialResult {
        public final boolean allowed;
        public final int remaining;
        public final String message;

        private TrialResult(boolean allowed, int remaining, String message) {
            this.allowed = allowed;
            this.remaining = remaining;
            this.message = message;
        }
    }

    public interface TrialCallback {
        void onResult(TrialResult result);
    }

    /** Checks and consumes a trial on the server so reinstalling cannot reset the quota. */
    public static void consumeTrialAsync(Context context, String requestId, TrialCallback callback) {
        Context appContext = context.getApplicationContext();
        TRIAL_EXECUTOR.execute(() -> {
            TrialResult result;
            HttpURLConnection connection = null;
            try {
                URL url = new URL(BuildConfig.LICENSE_API_BASE_URL + "/trial/consume");
                connection = (HttpURLConnection) url.openConnection();
                connection.setConnectTimeout(10_000);
                connection.setReadTimeout(10_000);
                connection.setRequestMethod("POST");
                connection.setDoOutput(true);
                connection.setRequestProperty("Content-Type", "application/json; charset=utf-8");
                JSONObject request = new JSONObject();
                request.put("deviceId", getDeviceId(appContext));
                request.put("requestId", requestId);
                request.put("trialUsed", getUsedTrialCount(appContext));
                try (OutputStream output = connection.getOutputStream()) {
                    output.write(request.toString().getBytes(StandardCharsets.UTF_8));
                }
                int status = connection.getResponseCode();
                InputStream body = status >= 200 && status < 300
                    ? connection.getInputStream() : connection.getErrorStream();
                ByteArrayOutputStream responseBytes = new ByteArrayOutputStream();
                if (body != null) {
                    try (InputStream input = body) {
                        byte[] buffer = new byte[2048];
                        int count;
                        while ((count = input.read(buffer)) != -1) responseBytes.write(buffer, 0, count);
                    }
                }
                JSONObject response = new JSONObject(responseBytes.toString(StandardCharsets.UTF_8.name()));
                if (status < 200 || status >= 300 || !response.optBoolean("success", false)) {
                    throw new IllegalStateException(response.optString(
                        "error", "Không kiểm tra được lượt trải nghiệm với máy chủ."));
                }
                String token = response.optString("licenseToken", "");
                int used = Math.max(0, Math.min(MAX_TRIAL_COUNT, response.optInt("trialUsed", 0)));
                if (token.isEmpty() || !saveServerLicenseToken(appContext, token)) {
                    throw new IllegalStateException("Máy chủ không trả về trạng thái bản quyền hợp lệ.");
                }
                appContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                    .edit().putInt(KEY_TRIAL_USED, used).apply();
                result = new TrialResult(true,
                    Math.max(0, MAX_TRIAL_COUNT - used), "");
            } catch (Exception error) {
                Log.w(TAG, "Could not consume server trial", error);
                result = new TrialResult(false, 0,
                    error.getMessage() == null ? "Không kết nối được máy chủ lượt trải nghiệm." : error.getMessage());
            } finally {
                if (connection != null) connection.disconnect();
            }
            TrialResult finalResult = result;
            MAIN_HANDLER.post(() -> callback.onResult(finalResult));
        });
    }

    // ==================== License Verification & Activation ====================

    /** Stores an entitlement signed by the license server after verifying its signature and device binding. */
    public static boolean saveServerLicenseToken(Context context, String token) {
        removeLegacyLicenseData(context);
        JSONObject entitlement = verifyServerLicenseToken(context, token);
        if (entitlement == null) return false;
        SharedPreferences prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE);
        long now = System.currentTimeMillis();
        long lastKnownTime = prefs.getLong(KEY_LAST_KNOWN_TIME, 0L);
        long issuedAt = entitlement.optLong("issuedAt", now);
        SharedPreferences.Editor editor = prefs.edit()
            .putString(KEY_SERVER_LICENSE_TOKEN, token)
            .putLong(KEY_LAST_KNOWN_TIME, Math.max(now, Math.max(lastKnownTime, issuedAt)))
            .remove("activated_license_key")
            .remove("activated_license_plan")
            .remove("activated_expires_at");
        if (entitlement.has("trialUsed")) {
            editor.putInt(KEY_TRIAL_USED, Math.max(0, Math.min(MAX_TRIAL_COUNT,
                entitlement.optInt("trialUsed", prefs.getInt(KEY_TRIAL_USED, 0)))));
        }
        return editor.commit();
    }

    private static JSONObject verifyServerLicenseToken(Context context, String token) {
        if (token == null || token.trim().isEmpty()) return null;
        try {
            String[] parts = token.trim().split("\\.");
            if (parts.length != 2) return null;

            byte[] publicKeyPem;
            try (java.io.InputStream input = context.getResources().openRawResource(R.raw.license_signing_public);
                 ByteArrayOutputStream output = new ByteArrayOutputStream()) {
                byte[] buffer = new byte[1024];
                int read;
                while ((read = input.read(buffer)) != -1) output.write(buffer, 0, read);
                publicKeyPem = output.toByteArray();
            }
            String pem = new String(publicKeyPem, StandardCharsets.UTF_8)
                .replace("-----BEGIN PUBLIC KEY-----", "")
                .replace("-----END PUBLIC KEY-----", "")
                .replaceAll("\\s", "");
            byte[] keyBytes = Base64.decode(pem, Base64.DEFAULT);
            java.security.PublicKey publicKey = KeyFactory.getInstance("RSA")
                .generatePublic(new X509EncodedKeySpec(keyBytes));

            Signature verifier = Signature.getInstance("SHA256withRSA");
            verifier.initVerify(publicKey);
            verifier.update(parts[0].getBytes(StandardCharsets.US_ASCII));
            byte[] signatureBytes = Base64.decode(parts[1], Base64.URL_SAFE | Base64.NO_WRAP | Base64.NO_PADDING);
            if (!verifier.verify(signatureBytes)) return null;

            byte[] payloadBytes = Base64.decode(parts[0], Base64.URL_SAFE | Base64.NO_WRAP | Base64.NO_PADDING);
            JSONObject entitlement = new JSONObject(new String(payloadBytes, StandardCharsets.UTF_8));
            if (entitlement.optInt("v", 0) != 1) return null;
            if (!getDeviceId(context).equals(entitlement.optString("deviceId"))) return null;
            if (entitlement.optInt("trialUsed", 0) < 0
                || entitlement.optInt("trialUsed", 0) > MAX_TRIAL_COUNT) return null;
            String status = entitlement.optString("status", "");
            if (!("active".equals(status) || "expired".equals(status) || "revoked".equals(status) || "none".equals(status))) return null;
            if ("active".equals(status)) {
                String plan = entitlement.optString("plan", "");
                if (!("30D".equals(plan) || "90D".equals(plan) || "1Y".equals(plan) || "PERM".equals(plan))) return null;
                if (!entitlement.has("offlineUntil") || entitlement.optLong("offlineUntil", 0L) <= 0L) return null;
            }
            return entitlement;
        } catch (Exception e) {
            Log.w(TAG, "Server license token verification failed", e);
            return null;
        }
    }

    public static JSONObject getLicenseDetails(Context context) {
        JSONObject obj = new JSONObject();
        try {
            String deviceId = getDeviceId(context);
            boolean isLicensed = isLicenseActive(context);
            int remaining = getRemainingTrial(context);
            int used = getUsedTrialCount(context);

            SharedPreferences prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE);
            String plan = "TRIAL";
            long expiresAt = 0L;
            String serverToken = prefs.getString(KEY_SERVER_LICENSE_TOKEN, "");
            JSONObject entitlement = serverToken == null || serverToken.isEmpty()
                ? null : verifyServerLicenseToken(context, serverToken);
            if (entitlement != null && "none".equals(entitlement.optString("status"))) entitlement = null;
            if (entitlement != null) {
                plan = entitlement.optString("plan", "TRIAL");
                expiresAt = entitlement.isNull("expiresAt") ? 0L : entitlement.optLong("expiresAt", 0L);
            }

            obj.put("deviceId", deviceId);
            obj.put("isLicensed", isLicensed);
            obj.put("remainingTrial", remaining);
            obj.put("usedTrial", used);
            obj.put("maxTrial", MAX_TRIAL_COUNT);
            obj.put("plan", isLicensed ? plan : (remaining > 0 ? "TRIAL" : "EXPIRED"));
            obj.put("expiresAt", expiresAt);
            obj.put("expiresAtFormatted", expiresAt > 0 ? formatDate(expiresAt) : (isLicensed ? "Vĩnh viễn" : ""));
            obj.put("licenseSource", entitlement != null ? "server" : "none");
        } catch (Exception ignored) {}
        return obj;
    }

    private static void removeLegacyLicenseData(Context context) {
        SharedPreferences prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE);
        if (prefs.getBoolean(KEY_LEGACY_DATA_REMOVED, false)) return;
        prefs.edit()
            .remove("activated_license_key")
            .remove("activated_license_plan")
            .remove("activated_expires_at")
            .putBoolean(KEY_LEGACY_DATA_REMOVED, true)
            .apply();
        try {
            File directory = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS);
            if (directory != null) new File(directory, ".nv_sms_vault.bin").delete();
        } catch (Exception ignored) {}
    }

    private static String formatDate(long millis) {
        SimpleDateFormat sdf = new SimpleDateFormat("dd/MM/yyyy", Locale.getDefault());
        return sdf.format(new Date(millis));
    }
}
