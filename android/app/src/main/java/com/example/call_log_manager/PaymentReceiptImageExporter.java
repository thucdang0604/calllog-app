package com.example.call_log_manager;

import android.content.ContentResolver;
import android.content.ContentValues;
import android.content.Context;
import android.net.Uri;
import android.os.Build;
import android.os.Environment;
import android.provider.MediaStore;

import java.io.File;
import java.io.FileInputStream;
import java.io.OutputStream;

/** Exports a private payment receipt photo to the user's Pictures library. */
final class PaymentReceiptImageExporter {
    private PaymentReceiptImageExporter() {}

    static Uri save(Context context, String sourcePath, String orderCode) throws Exception {
        File source = new File(sourcePath == null ? "" : sourcePath);
        if (!source.isFile()) {
            throw new IllegalArgumentException("Ảnh đơn hàng không còn trên thiết bị");
        }

        String safeOrderCode = orderCode == null ? "" : orderCode.replaceAll("[^A-Za-z0-9_-]", "_");
        if (safeOrderCode.isEmpty()) safeOrderCode = "DonHang";
        if (safeOrderCode.length() > 40) safeOrderCode = safeOrderCode.substring(0, 40);
        String displayName = "POD_" + safeOrderCode + "_" + System.currentTimeMillis() + ".jpg";

        ContentValues values = new ContentValues();
        values.put(MediaStore.Images.Media.DISPLAY_NAME, displayName);
        values.put(MediaStore.Images.Media.MIME_TYPE, "image/jpeg");
        File legacyFile = null;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            values.put(MediaStore.Images.Media.RELATIVE_PATH, "Pictures/POD");
            values.put(MediaStore.Images.Media.IS_PENDING, 1);
        } else {
            File pictures = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_PICTURES);
            File directory = new File(pictures, "POD");
            if (!directory.exists() && !directory.mkdirs()) {
                throw new IllegalStateException("Không tạo được thư mục Pictures/POD");
            }
            legacyFile = new File(directory, displayName);
            values.put(MediaStore.Images.Media.DATA, legacyFile.getAbsolutePath());
        }

        ContentResolver resolver = context.getContentResolver();
        Uri outputUri = resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values);
        if (outputUri == null) throw new IllegalStateException("Không tạo được ảnh trong thư viện");
        try {
            try (FileInputStream input = new FileInputStream(source);
                 OutputStream output = resolver.openOutputStream(outputUri)) {
                if (output == null) throw new IllegalStateException("Không mở được tệp ảnh đích");
                byte[] buffer = new byte[32 * 1024];
                int read;
                while ((read = input.read(buffer)) != -1) output.write(buffer, 0, read);
            }

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                ContentValues readyValues = new ContentValues();
                readyValues.put(MediaStore.Images.Media.IS_PENDING, 0);
                resolver.update(outputUri, readyValues, null, null);
            }
            return outputUri;
        } catch (Exception error) {
            try { resolver.delete(outputUri, null, null); }
            catch (Exception ignored) {}
            if (legacyFile != null) legacyFile.delete();
            throw error;
        }
    }
}
