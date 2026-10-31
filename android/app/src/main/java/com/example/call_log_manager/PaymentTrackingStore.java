package com.example.call_log_manager;

import android.content.ContentValues;
import android.content.Context;
import android.content.SharedPreferences;
import android.database.Cursor;
import android.database.sqlite.SQLiteDatabase;
import android.database.sqlite.SQLiteOpenHelper;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.io.File;
import java.util.UUID;

final class PaymentTrackingStore {
    private static final String PREFS_NAME = "payment_tracking";
    private static final String KEY_RECORDS = "records";
    private static final String KEY_MIGRATED = "records_migrated_to_sqlite";
    private static final String DATABASE_NAME = "payment_tracking.db";
    private static final String TABLE = "records";
    private static DatabaseHelper helper;

    private PaymentTrackingStore() {}

    private static final class DatabaseHelper extends SQLiteOpenHelper {
        DatabaseHelper(Context context) {
            super(context, DATABASE_NAME, null, 1);
        }

        @Override
        public void onCreate(SQLiteDatabase db) {
            db.execSQL("CREATE TABLE " + TABLE + " ("
                + "id TEXT PRIMARY KEY NOT NULL, "
                + "created_at INTEGER NOT NULL DEFAULT 0, "
                + "phone_norm TEXT NOT NULL DEFAULT '', "
                + "channel TEXT NOT NULL DEFAULT 'sms', "
                + "status TEXT NOT NULL DEFAULT 'pending', "
                + "sent_at INTEGER NOT NULL DEFAULT 0, "
                + "sms_status TEXT NOT NULL DEFAULT '', "
                + "record_json TEXT NOT NULL)");
            db.execSQL("CREATE INDEX records_phone_status_idx ON " + TABLE
                + " (phone_norm, status, channel, sent_at)");
        }

        @Override
        public void onUpgrade(SQLiteDatabase db, int oldVersion, int newVersion) {}
    }

    private static SQLiteDatabase database(Context context) {
        if (helper == null) helper = new DatabaseHelper(context.getApplicationContext());
        SQLiteDatabase db = helper.getWritableDatabase();
        SharedPreferences prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE);
        if (!prefs.getBoolean(KEY_MIGRATED, false)) {
            String legacyJson = prefs.getString(KEY_RECORDS, "[]");
            db.beginTransaction();
            try {
                JSONArray legacyRecords = new JSONArray(legacyJson);
                for (int index = 0; index < legacyRecords.length(); index++) {
                    JSONObject record = legacyRecords.optJSONObject(index);
                    if (record != null && !record.optString("id").isEmpty()) {
                        putRecord(db, record, true);
                    }
                }
                db.setTransactionSuccessful();
            } catch (JSONException | RuntimeException error) {
                android.util.Log.e("PaymentTrackingStore", "Could not migrate payment history", error);
                return db;
            } finally {
                db.endTransaction();
            }
            prefs.edit().remove(KEY_RECORDS).putBoolean(KEY_MIGRATED, true).commit();
        }
        return db;
    }

    static synchronized JSONArray getRecords(Context context) {
        SQLiteDatabase db = database(context);
        JSONArray records = new JSONArray();
        try (Cursor cursor = db.query(TABLE, new String[] {"record_json"}, null, null,
            null, null, "created_at ASC, rowid ASC")) {
            while (cursor.moveToNext()) {
                try {
                    records.put(new JSONObject(cursor.getString(0)));
                } catch (JSONException ignored) {
                    // Skip a corrupt row without hiding the rest of the history.
                }
            }
        }
        return records;
    }

    static synchronized String createSmsSession(Context context, String phone, String amount, String message) {
        JSONObject record = new JSONObject();
        String id = UUID.randomUUID().toString();
        try {
            record.put("id", id);
            record.put("channel", "sms");
            record.put("phone", phone);
            record.put("amount", amount);
            record.put("message", message);
            record.put("createdAt", System.currentTimeMillis());
            record.put("sentAt", 0L);
            record.put("smsStatus", "sending");
            record.put("deliveryStatus", "sending");
            record.put("status", "pending");
            record.put("receivedAt", JSONObject.NULL);
            record.put("orderCode", "");
            record.put("imagePath", "");
            record.put("capturedAt", 0L);
            return insertRecord(context, record) ? id : "";
        } catch (JSONException ignored) {
            return "";
        }
    }

    static synchronized String createZaloSession(Context context, String phone, String amount, String message) {
        JSONObject record = new JSONObject();
        String id = UUID.randomUUID().toString();
        try {
            record.put("id", id);
            record.put("channel", "zalo");
            record.put("phone", phone == null ? "" : phone);
            record.put("amount", amount == null ? "" : amount);
            record.put("message", message == null ? "" : message);
            record.put("createdAt", System.currentTimeMillis());
            record.put("sentAt", 0L);
            record.put("smsStatus", "not_applicable");
            record.put("deliveryStatus", "awaiting_scan");
            record.put("status", "pending");
            record.put("receivedAt", JSONObject.NULL);
            record.put("orderCode", "");
            record.put("imagePath", "");
            record.put("qrImagePath", "");
            record.put("capturedAt", 0L);
            record.put("customerReplied", false);
            record.put("replyMessage", "");
            return insertRecord(context, record) ? id : "";
        } catch (JSONException ignored) {
            return "";
        }
    }

    static synchronized boolean setZaloDeliveryStatus(Context context, String id, String status) {
        if (id == null || id.isEmpty()
            || (!"sent_confirmed".equals(status) && !"draft_ready".equals(status)
                && !"chat_opened".equals(status))) return false;
        JSONObject existing = findRecord(context, id);
        if (existing == null || !"zalo".equals(existing.optString("channel", ""))) return false;
        return updateRecord(context, id, record -> {
            try {
                record.put("deliveryStatus", status);
                if ("sent_confirmed".equals(status)) record.put("sentAt", System.currentTimeMillis());
                if ("draft_ready".equals(status)) record.put("qrCopiedAt", System.currentTimeMillis());
                if ("chat_opened".equals(status)) record.put("chatOpenedAt", System.currentTimeMillis());
            } catch (JSONException ignored) {}
        });
    }

    static synchronized boolean setZaloQrImagePath(Context context, String id, String imagePath) {
        if (id == null || id.isEmpty() || imagePath == null || imagePath.trim().isEmpty()) return false;
        JSONObject existing = findRecord(context, id);
        if (existing == null || !"zalo".equals(existing.optString("channel", ""))) return false;
        return updateRecord(context, id, record -> {
            try { record.put("qrImagePath", imagePath); }
            catch (JSONException ignored) {}
        });
    }

    static synchronized boolean setZaloReply(Context context, String id, String message) {
        if (id == null || id.isEmpty() || message == null || message.trim().isEmpty()) return false;
        JSONObject existing = findRecord(context, id);
        if (existing == null || !"zalo".equals(existing.optString("channel", ""))) return false;
        return updateRecord(context, id, record -> {
            try {
                record.put("customerReplied", true);
                record.put("replyPhone", record.optString("phone", ""));
                record.put("replyMessage", message.trim());
                record.put("replyReceivedAt", System.currentTimeMillis());
                record.put("zaloReplyManuallyRecorded", true);
            } catch (JSONException ignored) {}
        });
    }

    static synchronized void setSmsStatus(Context context, String id, boolean sent) {
        updateRecord(context, id, record -> {
            try {
                record.put("smsStatus", sent ? "sent" : "failed");
                record.put("deliveryStatus", sent ? "sent" : "failed");
                if (sent) record.put("sentAt", System.currentTimeMillis());
            } catch (JSONException ignored) {}
        });
    }

    static synchronized boolean setSmsSimulated(Context context, String id) {
        return updateRecord(context, id, record -> {
            try {
                record.put("smsStatus", "simulated");
                record.put("deliveryStatus", "simulated");
                record.put("sentAt", System.currentTimeMillis());
            } catch (JSONException ignored) {}
        });
    }

    static synchronized int recordCustomerReply(Context context, String senderPhone, String message, long receivedAt) {
        String normalizedSender = normalizePhone(senderPhone);
        if (normalizedSender.isEmpty() || message == null || message.trim().isEmpty()) return 0;

        SQLiteDatabase db = database(context);
        java.util.ArrayList<JSONObject> matches = new java.util.ArrayList<>();
        try (Cursor cursor = db.query(TABLE, new String[] {"record_json"},
            "phone_norm=? AND status=? AND channel=? AND sent_at<=? AND (sms_status=? OR sms_status=?)",
            new String[] {normalizedSender, "pending", "sms", String.valueOf(receivedAt), "sent", ""},
            null, null, "created_at ASC")) {
            while (cursor.moveToNext()) {
                try {
                    matches.add(new JSONObject(cursor.getString(0)));
                } catch (JSONException ignored) {
                    // Skip a corrupt row and continue matching the rest.
                }
            }
        }
        if (matches.isEmpty()) return 0;

        db.beginTransaction();
        try {
            for (JSONObject record : matches) {
                try {
                    record.put("customerReplied", true);
                    record.put("replyPhone", senderPhone);
                    record.put("replyMessage", message.trim());
                    record.put("replyReceivedAt", receivedAt);
                    putRecord(db, record, false);
                } catch (JSONException ignored) {
                    // Keep processing other matching records.
                }
            }
            db.setTransactionSuccessful();
        } finally {
            db.endTransaction();
        }
        return matches.size();
    }

    static synchronized boolean setOrderCapture(Context context, String id, String orderCode, String imagePath, long capturedAt) {
        return updateRecord(context, id, record -> {
            try {
                record.put("orderCode", orderCode);
                record.put("imagePath", imagePath);
                record.put("capturedAt", capturedAt);
            } catch (JSONException ignored) {}
        });
    }

    static synchronized boolean setReceived(Context context, String id, boolean received) {
        return updateRecord(context, id, record -> {
            try {
                record.put("status", received ? "received" : "pending");
                record.put("receivedAt", received ? System.currentTimeMillis() : JSONObject.NULL);
            } catch (JSONException ignored) {}
        });
    }

    static synchronized int clearReceived(Context context) {
        SQLiteDatabase db = database(context);
        java.util.ArrayList<String> paths = new java.util.ArrayList<>();
        int removed = 0;
        try (Cursor cursor = db.query(TABLE, new String[] {"record_json"}, "status=?",
            new String[] {"received"}, null, null, null)) {
            while (cursor.moveToNext()) {
                JSONObject record = new JSONObject(cursor.getString(0));
                addPath(paths, record.optString("imagePath", ""));
                addPath(paths, record.optString("qrImagePath", ""));
                removed++;
            }
        } catch (JSONException ignored) {}
        if (removed == 0) return 0;
        db.delete(TABLE, "status=?", new String[] {"received"});
        deleteFiles(paths);
        return removed;
    }

    static synchronized boolean deleteRecord(Context context, String id) {
        if (id == null || id.isEmpty()) return false;
        JSONObject record = findRecord(context, id);
        if (record == null) return false;
        database(context).delete(TABLE, "id=?", new String[] {id});
        java.util.ArrayList<String> paths = new java.util.ArrayList<>();
        addPath(paths, record.optString("imagePath", ""));
        addPath(paths, record.optString("qrImagePath", ""));
        deleteFiles(paths);
        return true;
    }

    static synchronized JSONObject findRecord(Context context, String id) {
        if (id == null || id.isEmpty()) return null;
        try (Cursor cursor = database(context).query(TABLE, new String[] {"record_json"},
            "id=?", new String[] {id}, null, null, null, "1")) {
            if (cursor.moveToFirst()) return new JSONObject(cursor.getString(0));
        } catch (JSONException ignored) {}
        return null;
    }

    private static boolean insertRecord(Context context, JSONObject record) {
        return putRecord(database(context), record, true) != -1;
    }

    private static boolean updateRecord(Context context, String id, RecordUpdater updater) {
        JSONObject record = findRecord(context, id);
        if (record == null) return false;
        updater.update(record);
        return putRecord(database(context), record, false) != -1;
    }

    private static long putRecord(SQLiteDatabase db, JSONObject record, boolean ignoreDuplicate) {
        ContentValues values = new ContentValues();
        values.put("id", record.optString("id", ""));
        values.put("created_at", record.optLong("createdAt", 0L));
        values.put("phone_norm", normalizePhone(record.optString("phone", "")));
        values.put("channel", record.optString("channel", "sms"));
        values.put("status", record.optString("status", "pending"));
        values.put("sent_at", record.optLong("sentAt", 0L));
        values.put("sms_status", record.optString("smsStatus", ""));
        values.put("record_json", record.toString());
        return db.insertWithOnConflict(TABLE, null, values,
            ignoreDuplicate ? SQLiteDatabase.CONFLICT_IGNORE : SQLiteDatabase.CONFLICT_REPLACE);
    }

    private static void addPath(java.util.List<String> paths, String path) {
        if (path != null && !path.isEmpty()) paths.add(path);
    }

    private static void deleteFiles(java.util.List<String> paths) {
        for (String path : paths) {
            try { new File(path).delete(); }
            catch (Exception ignored) {}
        }
    }

    private static String normalizePhone(String phone) {
        if (phone == null) return "";
        String digits = phone.replaceAll("\\D", "");
        return digits.startsWith("84") && digits.length() >= 11
            ? "0" + digits.substring(2) : digits;
    }

    private interface RecordUpdater {
        void update(JSONObject record);
    }
}
