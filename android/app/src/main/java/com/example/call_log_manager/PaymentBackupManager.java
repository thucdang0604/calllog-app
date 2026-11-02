package com.example.call_log_manager;

import android.content.Context;
import android.net.Uri;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.UUID;
import java.util.zip.ZipEntry;
import java.util.zip.ZipInputStream;
import java.util.zip.ZipOutputStream;

final class PaymentBackupManager {
    private static final long MAX_ENTRY_BYTES = 20L * 1024 * 1024;
    // shortcut: backup is capped at 500 MiB; raise only when real payment history exceeds it.
    private static final long MAX_BACKUP_BYTES = 500L * 1024 * 1024;
    private static final int MAX_RECORDS = 20_000;

    private PaymentBackupManager() {}

    static Map<String, Object> exportBackup(Context context, Uri destination) throws Exception {
        JSONArray source = PaymentTrackingStore.getRecords(context);
        if (source.length() > MAX_RECORDS) throw new IllegalStateException("Quá nhiều khoản để sao lưu.");
        JSONArray records = new JSONArray();
        Map<String, File> images = new LinkedHashMap<>();
        int missingImages = 0;
        for (int index = 0; index < source.length(); index++) {
            JSONObject record = new JSONObject(source.getJSONObject(index).toString());
            if (!record.has("channel")) record.put("channel", "sms");
            for (String field : new String[] {"imagePath", "qrImagePath"}) {
                String path = record.optString(field, "");
                if (path.isEmpty()) continue;
                File image = allowedImage(context, path);
                if (image == null || !image.isFile()) {
                    record.put(field, "");
                    missingImages++;
                    continue;
                }
                String name = "images/" + index + ("imagePath".equals(field) ? "-image.jpg" : "-qr.png");
                record.put(field, name);
                images.put(name, image);
            }
            records.put(record);
        }

        JSONObject manifest = new JSONObject().put("version", 1).put("records", records);
        byte[] manifestBytes = manifest.toString().getBytes(StandardCharsets.UTF_8);
        if (manifestBytes.length > MAX_ENTRY_BYTES) throw new IllegalStateException("Danh sách quá lớn để sao lưu.");
        try (OutputStream output = context.getContentResolver().openOutputStream(destination, "w")) {
            if (output == null) throw new IllegalStateException("Không mở được tệp sao lưu.");
            try (ZipOutputStream zip = new ZipOutputStream(output)) {
                zip.putNextEntry(new ZipEntry("manifest.json"));
                zip.write(manifestBytes);
                zip.closeEntry();
                long total = manifestBytes.length;
                for (Map.Entry<String, File> entry : images.entrySet()) {
                    zip.putNextEntry(new ZipEntry(entry.getKey()));
                    try (InputStream input = new FileInputStream(entry.getValue())) {
                        total += copyBounded(input, zip, MAX_ENTRY_BYTES);
                    }
                    if (total > MAX_BACKUP_BYTES) throw new IllegalStateException("Bản sao vượt giới hạn 500 MiB.");
                    zip.closeEntry();
                }
            }
        }
        Map<String, Object> result = new HashMap<>();
        result.put("records", records.length());
        result.put("images", images.size());
        result.put("missingImages", missingImages);
        return result;
    }

    static Map<String, Object> importBackup(Context context, Uri source) throws Exception {
        File staging = new File(context.getCacheDir(), "payment-import-" + UUID.randomUUID());
        if (!staging.mkdirs()) throw new IllegalStateException("Không tạo được thư mục tạm.");
        ArrayList<File> createdImages = new ArrayList<>();
        boolean committed = false;
        try {
            Map<String, File> images = new HashMap<>();
            byte[] manifestBytes = null;
            long total = 0;
            try (InputStream input = context.getContentResolver().openInputStream(source)) {
                if (input == null) throw new IllegalStateException("Không đọc được tệp sao lưu.");
                try (ZipInputStream zip = new ZipInputStream(input)) {
                    ZipEntry entry;
                    while ((entry = zip.getNextEntry()) != null) {
                        String name = entry.getName();
                        if (entry.isDirectory() || (!"manifest.json".equals(name) && !validImageName(name))
                            || images.containsKey(name) || ("manifest.json".equals(name) && manifestBytes != null)) {
                            throw new IllegalArgumentException("Tệp sao lưu có mục không hợp lệ.");
                        }
                        if ("manifest.json".equals(name)) {
                            ByteArrayOutputStream buffer = new ByteArrayOutputStream();
                            total += copyBounded(zip, buffer, MAX_ENTRY_BYTES);
                            manifestBytes = buffer.toByteArray();
                        } else {
                            File staged = new File(staging, name.replace('/', '_'));
                            try (OutputStream output = new FileOutputStream(staged)) {
                                total += copyBounded(zip, output, MAX_ENTRY_BYTES);
                            }
                            images.put(name, staged);
                        }
                        if (total > MAX_BACKUP_BYTES || images.size() > MAX_RECORDS * 2) {
                            throw new IllegalArgumentException("Tệp sao lưu vượt giới hạn.");
                        }
                        zip.closeEntry();
                    }
                }
            }
            if (manifestBytes == null) throw new IllegalArgumentException("Tệp sao lưu thiếu danh sách.");
            JSONObject manifest = new JSONObject(new String(manifestBytes, StandardCharsets.UTF_8));
            if (manifest.optInt("version") != 1) throw new IllegalArgumentException("Phiên bản sao lưu không hỗ trợ.");
            JSONArray records = manifest.getJSONArray("records");
            if (records.length() > MAX_RECORDS) throw new IllegalArgumentException("Bản sao có quá nhiều khoản.");
            JSONArray additions = new JSONArray();
            HashSet<String> seenIds = new HashSet<>();
            File restoredFolder = new File(context.getFilesDir(), "payment_receipts");
            if (!restoredFolder.isDirectory() && !restoredFolder.mkdirs()) {
                throw new IllegalStateException("Không tạo được thư mục ảnh đối soát.");
            }
            for (int index = 0; index < records.length(); index++) {
                JSONObject record = records.getJSONObject(index);
                if (!record.has("channel")) record.put("channel", "sms");
                String id = record.optString("id", "");
                try { UUID.fromString(id); }
                catch (IllegalArgumentException error) { throw new IllegalArgumentException("Mã khoản trong bản sao không hợp lệ."); }
                if (!seenIds.add(id) || record.optLong("createdAt", 0) <= 0
                    || !("sms".equals(record.optString("channel")) || "zalo".equals(record.optString("channel")))) {
                    throw new IllegalArgumentException("Dữ liệu khoản trong bản sao không hợp lệ.");
                }
                if (PaymentTrackingStore.findRecord(context, id) != null) continue;
                for (String field : new String[] {"imagePath", "qrImagePath"}) {
                    String name = record.optString(field, "");
                    if (name.isEmpty()) continue;
                    File staged = validImageName(name) ? images.get(name) : null;
                    if (staged == null) throw new IllegalArgumentException("Bản sao thiếu ảnh của một khoản.");
                    File target = new File(restoredFolder, "backup-" + UUID.randomUUID()
                        + ("imagePath".equals(field) ? ".jpg" : ".png"));
                    createdImages.add(target);
                    try (InputStream imageInput = new FileInputStream(staged);
                         OutputStream imageOutput = new FileOutputStream(target)) {
                        copyBounded(imageInput, imageOutput, MAX_ENTRY_BYTES);
                    }
                    record.put(field, target.getAbsolutePath());
                }
                additions.put(record);
            }
            int imported = PaymentTrackingStore.importRecords(context, additions);
            committed = true;
            PaymentTrackingEventBus.notifyRecordsChanged();
            FloatingWindowService.refreshPaymentQueueIfVisible();
            Map<String, Object> result = new HashMap<>();
            result.put("records", imported);
            result.put("skipped", records.length() - imported);
            return result;
        } finally {
            if (!committed) for (File file : createdImages) file.delete();
            File[] temporary = staging.listFiles();
            if (temporary != null) for (File file : temporary) file.delete();
            staging.delete();
        }
    }

    private static boolean validImageName(String name) {
        return name != null && name.matches("images/[0-9]+-(?:image\\.jpg|qr\\.png)");
    }

    private static File allowedImage(Context context, String path) throws Exception {
        File image = new File(path).getCanonicalFile();
        File receipts = new File(context.getFilesDir(), "payment_receipts").getCanonicalFile();
        File qr = new File(context.getCacheDir(), "payment_qr").getCanonicalFile();
        return image.getPath().startsWith(receipts.getPath() + File.separator)
            || image.getPath().startsWith(qr.getPath() + File.separator) ? image : null;
    }

    private static long copyBounded(InputStream input, OutputStream output, long limit) throws Exception {
        byte[] buffer = new byte[8192];
        long copied = 0;
        int count;
        while ((count = input.read(buffer)) != -1) {
            copied += count;
            if (copied > limit) throw new IllegalArgumentException("Ảnh hoặc danh sách trong bản sao quá lớn.");
            output.write(buffer, 0, count);
        }
        return copied;
    }
}
