package com.example.call_log_manager;

import android.content.Context;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.SharedPreferences;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.RectF;
import android.net.Uri;
import android.graphics.Typeface;
import android.util.Log;

import androidx.core.content.FileProvider;

import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.util.HashMap;
import java.util.Map;
import java.util.UUID;

final class PaymentQrShareManager {
    private static final String TAG = "PaymentQrShareManager";
    private static final String PREFS = "payment_account";
    private static final String ZALO_PACKAGE = "com.zing.zalo";

    private PaymentQrShareManager() {}

    static Map<String, Object> getSettings(Context context) {
        SharedPreferences prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
        Map<String, Object> settings = new HashMap<>();
        settings.put("bankName", prefs.getString("bank_name", ""));
        settings.put("bankBin", prefs.getString("bank_bin", ""));
        settings.put("bankId", prefs.getString("bank_id", ""));
        settings.put("accountNumber", prefs.getString("account_number", ""));
        settings.put("accountName", prefs.getString("account_name", ""));
        settings.put("verified", prefs.getBoolean("verified", false));
        return settings;
    }

    static boolean saveSettings(
        Context context,
        String bankName,
        String bankBin,
        String bankId,
        String accountNumber,
        String accountName,
        boolean verified
    ) {
        String cleanBin = bankBin == null ? "" : bankBin.replaceAll("\\D", "");
        String cleanAccount = accountNumber == null ? "" : accountNumber.trim();
        String cleanName = accountName == null ? "" : accountName.trim();
        if (cleanBin.length() != 6 || !cleanAccount.matches("[0-9]{6,19}")
            || cleanName.isEmpty() || bankId == null || bankId.trim().isEmpty()) {
            return false;
        }

        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putString("bank_name", bankName == null ? "" : bankName.trim())
            .putString("bank_bin", cleanBin)
            .putString("bank_id", bankId.trim())
            .putString("account_number", cleanAccount)
            .putString("account_name", cleanName)
            .putBoolean("verified", verified)
            .apply();
        return true;
    }

    static String createAccountOnlyQrUrl(
        String bankId,
        String accountNumber,
        String accountName
    ) throws Exception {
        String cleanBank = bankId == null ? "" : bankId.trim();
        String cleanAccount = accountNumber == null ? "" : accountNumber.trim();
        String cleanName = accountName == null ? "" : accountName.trim();
        if (cleanBank.isEmpty() || cleanAccount.isEmpty() || cleanName.isEmpty()) {
            throw new IllegalArgumentException("Thiếu ngân hàng hoặc thông tin tài khoản.");
        }

        // No amount or transfer-memo query parameter is added: the QR only identifies
        // the configured destination account.
        String encodedName = URLEncoder.encode(cleanName, StandardCharsets.UTF_8.name());
        return "https://img.vietqr.io/image/" + Uri.encode(cleanBank) + "-"
            + Uri.encode(cleanAccount) + "-qr_only.png?accountName=" + encodedName;
    }

    static String prepareAccountQrForZalo(
        Context context,
        String phone,
        String amount
    ) throws Exception {
        Map<String, Object> settings = getSettings(context);
        String bankName = String.valueOf(settings.get("bankName"));
        String bankId = String.valueOf(settings.get("bankId"));
        String accountNumber = String.valueOf(settings.get("accountNumber"));
        String accountName = String.valueOf(settings.get("accountName"));
        boolean qrConfigured = Boolean.TRUE.equals(settings.get("verified"))
            && !bankId.isEmpty() && !accountNumber.isEmpty() && !accountName.isEmpty();
        String trackingMessage = "Số tiền cần chuyển: " + amount + " VND. ";
        trackingMessage += qrConfigured
            ? "Quét QR tĩnh để nhận " + bankName + " · " + accountNumber
                + ". Khách tự nhập số tiền khi quét."
            : "Chưa có QR tài khoản đã xác nhận trên thiết bị này.";
        String id = PaymentTrackingStore.createZaloSession(
            context,
            phone,
            amount,
            trackingMessage
        );
        if (id.isEmpty()) {
            throw new IllegalStateException("Không lưu được khoản theo dõi Zalo.");
        }
        if (qrConfigured) {
            File directory = new File(context.getCacheDir(), "payment_qr");
            if (!directory.exists() && !directory.mkdirs()) {
                Log.w(TAG, "QR folder unavailable; continue opening the customer's Zalo chat");
            } else {
                File[] cachedImages = directory.listFiles();
                if (cachedImages != null) {
                    long staleBefore = System.currentTimeMillis() - 24L * 60L * 60L * 1000L;
                    for (File cachedImage : cachedImages) {
                        if (cachedImage.isFile() && cachedImage.lastModified() < staleBefore) {
                            cachedImage.delete();
                        }
                    }
                }
                String fileToken = UUID.randomUUID().toString();
                File sourceQrFile = new File(directory, "zalo-qr-" + fileToken + ".png");
                File transferCardFile = new File(directory, "zalo-transfer-" + fileToken + ".png");
                try {
                    String qrUrl = createAccountOnlyQrUrl(bankId, accountNumber, accountName);
                    downloadImage(qrUrl, sourceQrFile);
                    createTransferCard(
                        sourceQrFile,
                        transferCardFile,
                        bankName,
                        accountNumber,
                        accountName,
                        amount
                    );
                    if (!PaymentTrackingStore.setZaloQrImagePath(
                        context,
                        id,
                        transferCardFile.getAbsolutePath()
                    )) {
                        throw new IllegalStateException("Không lưu được ảnh QR chuyển khoản.");
                    }
                } catch (Exception error) {
                    Log.w(TAG, "QR was not prepared; continue opening the customer's Zalo chat", error);
                    transferCardFile.delete();
                } finally {
                    sourceQrFile.delete();
                }
            }
        }
        PaymentTrackingEventBus.notifyRecordsChanged();
        FloatingWindowService.refreshPaymentQueueIfVisible();
        return id;
    }

    static void copyTransferCardToZaloClipboard(Context context, String imagePath) throws Exception {
        if (imagePath == null || imagePath.trim().isEmpty()) {
            throw new IllegalArgumentException("Không có ảnh QR để sao chép.");
        }
        File imageFile = new File(imagePath);
        if (!imageFile.isFile()) throw new IllegalStateException("Ảnh QR không còn trên thiết bị.");
        ClipboardManager clipboard = (ClipboardManager) context.getSystemService(Context.CLIPBOARD_SERVICE);
        if (clipboard == null) throw new IllegalStateException("Không truy cập được bộ nhớ tạm.");

        Uri imageUri = FileProvider.getUriForFile(
            context,
            context.getPackageName() + ".timemark.fileprovider",
            imageFile
        );
        context.grantUriPermission(
            ZALO_PACKAGE,
            imageUri,
            android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION
        );
        clipboard.setPrimaryClip(ClipData.newUri(
            context.getContentResolver(),
            "QR và số tiền chuyển khoản",
            imageUri
        ));
    }

    private static void createTransferCard(
        File qrFile,
        File outputFile,
        String bankName,
        String accountNumber,
        String accountName,
        String amount
    ) throws Exception {
        Bitmap qrBitmap = BitmapFactory.decodeFile(qrFile.getAbsolutePath());
        if (qrBitmap == null) throw new IllegalStateException("Không đọc được mã QR ngân hàng.");

        final int width = 900;
        final int height = 1240;
        Bitmap card = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888);
        try {
            Canvas canvas = new Canvas(card);
            canvas.drawColor(Color.WHITE);

            Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG | Paint.SUBPIXEL_TEXT_FLAG);
            paint.setColor(Color.rgb(28, 43, 58));
            paint.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
            paint.setTextSize(42f);
            drawCenteredText(canvas, paint, "Thông tin chuyển khoản", width / 2f, 82f, width - 96f);

            paint.setColor(Color.rgb(90, 102, 115));
            paint.setTypeface(Typeface.create("sans-serif", Typeface.NORMAL));
            paint.setTextSize(30f);
            drawCenteredText(canvas, paint, "Số tiền cần chuyển", width / 2f, 145f, width - 96f);

            paint.setColor(Color.rgb(21, 101, 192));
            paint.setTypeface(Typeface.create("sans-serif-bold", Typeface.NORMAL));
            paint.setTextSize(62f);
            drawCenteredText(canvas, paint, amount + " đ", width / 2f, 220f, width - 96f);

            paint.setColor(Color.rgb(45, 55, 66));
            paint.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
            paint.setTextSize(29f);
            drawCenteredText(canvas, paint, bankName, width / 2f, 278f, width - 96f);

            paint.setTypeface(Typeface.create("sans-serif", Typeface.NORMAL));
            paint.setTextSize(27f);
            drawCenteredText(canvas, paint, accountName, width / 2f, 322f, width - 96f);
            drawCenteredText(canvas, paint, accountNumber, width / 2f, 363f, width - 96f);

            Paint borderPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
            borderPaint.setColor(Color.rgb(232, 236, 240));
            borderPaint.setStyle(Paint.Style.STROKE);
            borderPaint.setStrokeWidth(3f);
            canvas.drawRoundRect(new RectF(82f, 390f, 818f, 1126f), 20f, 20f, borderPaint);
            canvas.drawBitmap(qrBitmap, null, new RectF(92f, 400f, 808f, 1116f), null);

            paint.setColor(Color.rgb(90, 102, 115));
            paint.setTextSize(23f);
            drawCenteredText(
                canvas,
                paint,
                "QR không cài sẵn số tiền · khách tự nhập khi quét",
                width / 2f,
                1184f,
                width - 64f
            );

            try (FileOutputStream output = new FileOutputStream(outputFile)) {
                if (!card.compress(Bitmap.CompressFormat.PNG, 100, output)) {
                    throw new IllegalStateException("Không tạo được ảnh chuyển khoản.");
                }
                output.flush();
            }
        } finally {
            qrBitmap.recycle();
            card.recycle();
        }
    }

    private static void drawCenteredText(
        Canvas canvas,
        Paint paint,
        String text,
        float centerX,
        float baselineY,
        float maximumWidth
    ) {
        String value = text == null ? "" : text;
        float originalSize = paint.getTextSize();
        while (paint.measureText(value) > maximumWidth && paint.getTextSize() > 18f) {
            paint.setTextSize(paint.getTextSize() - 1f);
        }
        canvas.drawText(value, centerX - paint.measureText(value) / 2f, baselineY, paint);
        paint.setTextSize(originalSize);
    }

    private static void downloadImage(String imageUrl, File destination) throws Exception {
        HttpURLConnection connection = null;
        try {
            connection = (HttpURLConnection) new URL(imageUrl).openConnection();
            connection.setConnectTimeout(10_000);
            connection.setReadTimeout(10_000);
            connection.setRequestMethod("GET");
            connection.setRequestProperty("Accept", "image/png,image/*;q=0.9,*/*;q=0.5");
            int status = connection.getResponseCode();
            String contentType = connection.getContentType();
            if (status != HttpURLConnection.HTTP_OK || contentType == null
                || !contentType.toLowerCase(java.util.Locale.ROOT).startsWith("image/")) {
                throw new IllegalStateException("Không tải được ảnh mã QR.");
            }
            try (InputStream input = connection.getInputStream();
                 FileOutputStream output = new FileOutputStream(destination)) {
                byte[] buffer = new byte[8192];
                int count;
                while ((count = input.read(buffer)) != -1) output.write(buffer, 0, count);
            }
            if (destination.length() == 0) throw new IllegalStateException("Ảnh QR tải về bị trống.");
        } catch (Exception error) {
            Log.e(TAG, "Could not download VietQR image", error);
            destination.delete();
            throw error;
        } finally {
            if (connection != null) connection.disconnect();
        }
    }
}
