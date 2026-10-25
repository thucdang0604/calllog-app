package com.example.call_log_manager;

import android.content.Context;
import android.content.SharedPreferences;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.io.File;
import java.util.UUID;

final class PaymentTrackingStore {
    private static final String PREFS_NAME = "payment_tracking";
    private static final String KEY_RECORDS = "records";

    private PaymentTrackingStore() {}

    static synchronized JSONArray getRecords(Context context) {
        SharedPreferences prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE);
        String json = prefs.getString(KEY_RECORDS, "[]");
        try {
            return new JSONArray(json);
        } catch (JSONException ignored) {
            return new JSONArray();
        }
    }

    static synchronized String createSmsSession(Context context, String phone, String amount, String message) {
        String id = UUID.randomUUID().toString();
        JSONArray records = getRecords(context);
        JSONObject record = new JSONObject();
        try {
            record.put("id", id);
            record.put("phone", phone);
            record.put("amount", amount);
            record.put("message", message);
            record.put("createdAt", System.currentTimeMillis());
            record.put("sentAt", 0L);
            record.put("smsStatus", "sending");
            record.put("status", "pending");
            record.put("receivedAt", JSONObject.NULL);
            record.put("orderCode", "");
            record.put("imagePath", "");
            record.put("capturedAt", 0L);
            records.put(record);
        } catch (JSONException ignored) {
            return "";
        }

        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY_RECORDS, records.toString())
            .apply();
        return id;
    }

    static synchronized void setSmsStatus(Context context, String id, boolean sent) {
        updateRecord(context, id, record -> {
            try {
                record.put("smsStatus", sent ? "sent" : "failed");
                if (sent) record.put("sentAt", System.currentTimeMillis());
            } catch (JSONException ignored) {
                // Leave the stored values unchanged if an update fails.
            }
        });
    }

    static synchronized int recordCustomerReply(
        Context context,
        String senderPhone,
        String message,
        long receivedAt
    ) {
        String normalizedSender = normalizePhone(senderPhone);
        if (normalizedSender.isEmpty() || message == null || message.trim().isEmpty()) return 0;

        JSONArray records = getRecords(context);
        boolean changed = false;
        int matched = 0;
        for (int index = 0; index < records.length(); index++) {
            JSONObject record = records.optJSONObject(index);
            if (record == null
                || !"pending".equals(record.optString("status", "pending"))
                || record.optLong("sentAt", 0L) > receivedAt
                || !("sent".equals(record.optString("smsStatus", ""))
                    || record.optString("smsStatus", "").isEmpty())
                || !normalizedSender.equals(normalizePhone(record.optString("phone", "")))) {
                continue;
            }

            try {
                record.put("customerReplied", true);
                record.put("replyPhone", senderPhone);
                record.put("replyMessage", message.trim());
                record.put("replyReceivedAt", receivedAt);
                matched++;
                changed = true;
            } catch (JSONException ignored) {
                // Keep processing other matching records if one record is malformed.
            }
        }

        if (changed) {
            context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                .edit()
                .putString(KEY_RECORDS, records.toString())
                .apply();
        }
        return matched;
    }

    static synchronized boolean setOrderCapture(
        Context context,
        String id,
        String orderCode,
        String imagePath,
        long capturedAt
    ) {
        return updateRecord(context, id, record -> {
            try {
                record.put("orderCode", orderCode);
                record.put("imagePath", imagePath);
                record.put("capturedAt", capturedAt);
            } catch (JSONException ignored) {
                // Leave the stored values unchanged if an update fails.
            }
        });
    }

    static synchronized boolean setReceived(Context context, String id, boolean received) {
        return updateRecord(context, id, record -> {
            try {
                record.put("status", received ? "received" : "pending");
                if (received) {
                    record.put("receivedAt", System.currentTimeMillis());
                } else {
                    record.put("receivedAt", JSONObject.NULL);
                }
            } catch (JSONException ignored) {
                // Leave the stored values unchanged if an update fails.
            }
        });
    }

    static synchronized int clearReceived(Context context) {
        JSONArray records = getRecords(context);
        JSONArray remainingRecords = new JSONArray();
        java.util.ArrayList<String> imagesToDelete = new java.util.ArrayList<>();
        int removed = 0;

        for (int index = 0; index < records.length(); index++) {
            JSONObject record = records.optJSONObject(index);
            if (record == null) continue;

            if ("received".equals(record.optString("status"))) {
                String imagePath = record.optString("imagePath", "");
                if (!imagePath.isEmpty()) imagesToDelete.add(imagePath);
                removed++;
            } else {
                remainingRecords.put(record);
            }
        }

        if (removed == 0) return 0;

        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY_RECORDS, remainingRecords.toString())
            .apply();

        for (String imagePath : imagesToDelete) {
            try {
                new File(imagePath).delete();
            } catch (Exception ignored) {
                // The record is cleared even if a stale image file cannot be removed.
            }
        }
        return removed;
    }

    static synchronized boolean deleteRecord(Context context, String id) {
        if (id == null || id.isEmpty()) return false;

        JSONArray records = getRecords(context);
        JSONArray remainingRecords = new JSONArray();
        String imagePath = "";
        boolean found = false;

        for (int index = 0; index < records.length(); index++) {
            JSONObject record = records.optJSONObject(index);
            if (record == null) continue;
            if (id.equals(record.optString("id"))) {
                imagePath = record.optString("imagePath", "");
                found = true;
            } else {
                remainingRecords.put(record);
            }
        }

        if (!found) return false;
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY_RECORDS, remainingRecords.toString())
            .apply();

        if (!imagePath.isEmpty()) {
            try {
                new File(imagePath).delete();
            } catch (Exception ignored) {
                // The record is removed even if its private image is already missing.
            }
        }
        return true;
    }

    static synchronized JSONObject findRecord(Context context, String id) {
        JSONArray records = getRecords(context);
        for (int index = 0; index < records.length(); index++) {
            JSONObject record = records.optJSONObject(index);
            if (record != null && id.equals(record.optString("id"))) return record;
        }
        return null;
    }

    private static boolean updateRecord(Context context, String id, RecordUpdater updater) {
        if (id == null || id.isEmpty()) return false;

        JSONArray records = getRecords(context);
        JSONArray updatedRecords = new JSONArray();
        boolean found = false;
        for (int index = 0; index < records.length(); index++) {
            JSONObject record = records.optJSONObject(index);
            if (record == null) continue;
            if (id.equals(record.optString("id"))) {
                updater.update(record);
                found = true;
            }
            updatedRecords.put(record);
        }

        if (found) {
            context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                .edit()
                .putString(KEY_RECORDS, updatedRecords.toString())
                .apply();
        }
        return found;
    }

    private static String normalizePhone(String phone) {
        if (phone == null) return "";
        String digits = phone.replaceAll("\\D", "");
        if (digits.startsWith("84") && digits.length() >= 11) {
            digits = "0" + digits.substring(2);
        }
        return digits;
    }

    private interface RecordUpdater {
        void update(JSONObject record);
    }
}
