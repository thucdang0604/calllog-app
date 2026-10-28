package com.example.call_log_manager;

import android.Manifest;
import android.app.Activity;
import android.content.pm.PackageManager;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Color;
import android.graphics.Matrix;
import android.os.Build;
import android.os.Bundle;
import android.view.Gravity;
import android.view.View;
import android.widget.Button;
import android.widget.FrameLayout;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ProgressBar;
import android.widget.TextView;
import android.widget.Toast;

import androidx.core.app.ActivityCompat;
import androidx.core.content.ContextCompat;
import androidx.exifinterface.media.ExifInterface;

import org.json.JSONObject;

import java.io.File;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/** Full-screen preview and gallery export for a captured payment order photo. */
public final class PaymentPodViewerActivity extends Activity {
    static final String EXTRA_RECORD_ID = "payment_pod_record_id";
    private static final int REQUEST_WRITE_STORAGE = 7104;
    private static final int MAX_PREVIEW_SIDE = 2560;

    private final ExecutorService imageExecutor = Executors.newSingleThreadExecutor();
    private String sourcePath = "";
    private String orderCode = "";
    private ImageView imageView;
    private ProgressBar progressBar;
    private Button saveButton;

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        String recordId = getIntent().getStringExtra(EXTRA_RECORD_ID);
        JSONObject record = PaymentTrackingStore.findRecord(this, recordId);
        if (record == null) {
            Toast.makeText(this, "Không tìm thấy khoản chuyển khoản", Toast.LENGTH_SHORT).show();
            finish();
            return;
        }
        sourcePath = record.optString("imagePath", "");
        orderCode = record.optString("orderCode", "");
        if (sourcePath.isEmpty() || !new File(sourcePath).isFile()) {
            Toast.makeText(this, "Ảnh POD không còn trên thiết bị", Toast.LENGTH_SHORT).show();
            finish();
            return;
        }

        setContentView(createContentView());
        loadPreview();
    }

    private View createContentView() {
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setBackgroundColor(Color.rgb(20, 20, 20));

        LinearLayout header = new LinearLayout(this);
        header.setGravity(Gravity.CENTER_VERTICAL);
        header.setPadding(dp(16), dp(8), dp(8), dp(8));
        TextView title = new TextView(this);
        title.setText(orderCode.isEmpty() ? "Ảnh POD" : "POD · " + orderCode);
        title.setTextColor(Color.WHITE);
        title.setTextSize(16);
        title.setMaxLines(1);
        title.setEllipsize(android.text.TextUtils.TruncateAt.END);
        header.addView(title, new LinearLayout.LayoutParams(0, dp(48), 1f));
        Button closeButton = new Button(this);
        closeButton.setText("Đóng");
        closeButton.setOnClickListener(view -> finish());
        header.addView(closeButton, new LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.WRAP_CONTENT,
            dp(48)
        ));
        root.addView(header);

        FrameLayout imageFrame = new FrameLayout(this);
        imageFrame.setBackgroundColor(Color.BLACK);
        imageView = new ImageView(this);
        imageView.setScaleType(ImageView.ScaleType.FIT_CENTER);
        imageFrame.addView(imageView, new FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.MATCH_PARENT,
            FrameLayout.LayoutParams.MATCH_PARENT
        ));
        progressBar = new ProgressBar(this);
        FrameLayout.LayoutParams progressParams = new FrameLayout.LayoutParams(
            dp(48), dp(48), Gravity.CENTER);
        imageFrame.addView(progressBar, progressParams);
        root.addView(imageFrame, new LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f));

        saveButton = new Button(this);
        saveButton.setText("Tải ảnh POD về thư viện");
        saveButton.setOnClickListener(view -> requestSavePermissionIfNeeded());
        LinearLayout.LayoutParams saveParams = new LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT, dp(52));
        saveParams.setMargins(dp(16), dp(8), dp(16), dp(12));
        root.addView(saveButton, saveParams);
        return root;
    }

    private void loadPreview() {
        progressBar.setVisibility(View.VISIBLE);
        imageExecutor.execute(() -> {
            Bitmap bitmap = decodePreview(new File(sourcePath));
            runOnUiThread(() -> {
                if (isFinishing() || isDestroyed()) {
                    if (bitmap != null) bitmap.recycle();
                    return;
                }
                progressBar.setVisibility(View.GONE);
                if (bitmap == null) {
                    Toast.makeText(this, "Không đọc được ảnh POD", Toast.LENGTH_SHORT).show();
                    finish();
                } else {
                    imageView.setImageBitmap(bitmap);
                }
            });
        });
    }

    private Bitmap decodePreview(File source) {
        BitmapFactory.Options bounds = new BitmapFactory.Options();
        bounds.inJustDecodeBounds = true;
        BitmapFactory.decodeFile(source.getAbsolutePath(), bounds);
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null;

        int sampleSize = 1;
        while (Math.max(bounds.outWidth / sampleSize, bounds.outHeight / sampleSize)
            > MAX_PREVIEW_SIDE * 3 / 2) {
            sampleSize *= 2;
        }
        BitmapFactory.Options options = new BitmapFactory.Options();
        options.inSampleSize = sampleSize;
        options.inPreferredConfig = Bitmap.Config.RGB_565;
        Bitmap decoded = BitmapFactory.decodeFile(source.getAbsolutePath(), options);
        if (decoded == null) return null;

        Bitmap oriented = decoded;
        try {
            int degrees = new ExifInterface(source).getRotationDegrees();
            if (degrees != 0) {
                Matrix matrix = new Matrix();
                matrix.postRotate(degrees);
                oriented = Bitmap.createBitmap(decoded, 0, 0, decoded.getWidth(), decoded.getHeight(), matrix, true);
                if (oriented != decoded) decoded.recycle();
            }
        } catch (Exception ignored) {
            // CameraX usually stores upright pixels; keep the decoded image if EXIF is unavailable.
        }

        int longestSide = Math.max(oriented.getWidth(), oriented.getHeight());
        if (longestSide > MAX_PREVIEW_SIDE) {
            float scale = MAX_PREVIEW_SIDE / (float) longestSide;
            Bitmap scaled = Bitmap.createScaledBitmap(
                oriented,
                Math.max(1, Math.round(oriented.getWidth() * scale)),
                Math.max(1, Math.round(oriented.getHeight() * scale)),
                true
            );
            if (scaled != oriented) oriented.recycle();
            oriented = scaled;
        }
        return oriented;
    }

    private void requestSavePermissionIfNeeded() {
        if (Build.VERSION.SDK_INT <= Build.VERSION_CODES.P
            && ContextCompat.checkSelfPermission(this, Manifest.permission.WRITE_EXTERNAL_STORAGE)
                != PackageManager.PERMISSION_GRANTED) {
            ActivityCompat.requestPermissions(
                this,
                new String[]{Manifest.permission.WRITE_EXTERNAL_STORAGE},
                REQUEST_WRITE_STORAGE
            );
            return;
        }
        saveImage();
    }

    private void saveImage() {
        saveButton.setEnabled(false);
        saveButton.setText("Đang lưu ảnh...");
        imageExecutor.execute(() -> {
            try {
                PaymentReceiptImageExporter.save(this, sourcePath, orderCode);
                runOnUiThread(() -> Toast.makeText(
                    this, "Đã lưu ảnh trong Pictures/POD", Toast.LENGTH_LONG).show());
            } catch (Exception error) {
                runOnUiThread(() -> Toast.makeText(
                    this,
                    "Không lưu được ảnh: " + error.getMessage(),
                    Toast.LENGTH_LONG
                ).show());
            } finally {
                runOnUiThread(() -> {
                    if (!isFinishing() && !isDestroyed()) {
                        saveButton.setEnabled(true);
                        saveButton.setText("Tải ảnh POD về thư viện");
                    }
                });
            }
        });
    }

    @Override
    public void onRequestPermissionsResult(int requestCode, String[] permissions, int[] grantResults) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults);
        if (requestCode != REQUEST_WRITE_STORAGE) return;
        if (grantResults.length > 0 && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
            saveImage();
        } else {
            Toast.makeText(this, "Chưa được cấp quyền lưu ảnh", Toast.LENGTH_SHORT).show();
        }
    }

    private int dp(int value) {
        return (int) (value * getResources().getDisplayMetrics().density);
    }

    @Override
    protected void onDestroy() {
        imageExecutor.shutdown();
        super.onDestroy();
    }
}
