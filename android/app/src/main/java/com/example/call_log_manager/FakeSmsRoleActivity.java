package com.example.call_log_manager;

import android.app.Activity;
import android.app.AlertDialog;
import android.app.role.RoleManager;
import android.content.ContentValues;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.content.pm.ResolveInfo;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.provider.Settings;
import android.provider.Telephony;
import android.view.Gravity;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.ProgressBar;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;

public final class FakeSmsRoleActivity extends Activity {
    static final String EXTRA_PHONE = "fake_sms_phone";
    static final String EXTRA_AMOUNT = "fake_sms_amount";
    static final String EXTRA_MESSAGE = "fake_sms_message";
    static final String EXTRA_RESTORE_ONLY = "fake_sms_restore_only";

    private static final int REQUEST_SMS_ROLE = 8101;
    private static final String PREFS = "fake_sms_role";
    private static final String KEY_PREVIOUS_PACKAGE = "previous_sms_package";
    private static final String KEY_RESTORE_REQUIRED = "restore_required";

    private boolean writeComplete;
    private boolean scannerOpened;
    private String sessionId = "";
    private String previousSmsPackage = "";
    private String trialRequestId = "";
    private boolean trialRequestPending;

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        SharedPreferences prefs = getSharedPreferences(PREFS, MODE_PRIVATE);
        if (state != null) {
            writeComplete = state.getBoolean("writeComplete", false);
            sessionId = state.getString("sessionId", "");
            previousSmsPackage = state.getString("previousSmsPackage", "");
            trialRequestId = state.getString("trialRequestId", "");
        }

        if (getIntent().getBooleanExtra(EXTRA_RESTORE_ONLY, false)) {
            writeComplete = true;
            previousSmsPackage = prefs.getString(KEY_PREVIOUS_PACKAGE, "");
            showRestoreScreen();
            return;
        }

        if (!writeComplete && !validRequest()) {
            finish();
            return;
        }
        if (writeComplete) {
            showRestoreScreen();
            return;
        }

        if (prefs.getBoolean(KEY_RESTORE_REQUIRED, false)) {
            previousSmsPackage = prefs.getString(KEY_PREVIOUS_PACKAGE, "");
        } else {
            previousSmsPackage = findPreviousSmsPackage();
        }

        if (isDefaultSmsApp()) {
            writeFakeSms();
        } else {
            prefs.edit()
                .putString(KEY_PREVIOUS_PACKAGE, previousSmsPackage)
                .putBoolean(KEY_RESTORE_REQUIRED, true)
                .apply();
            requestSmsRole();
        }
    }

    private boolean validRequest() {
        String phone = getIntent().getStringExtra(EXTRA_PHONE);
        String amount = getIntent().getStringExtra(EXTRA_AMOUNT);
        String message = getIntent().getStringExtra(EXTRA_MESSAGE);
        return phone != null && !phone.isEmpty()
            && amount != null && !amount.isEmpty()
            && message != null && !message.isEmpty();
    }

    private boolean isDefaultSmsApp() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            RoleManager roles = getSystemService(RoleManager.class);
            return roles != null && roles.isRoleHeld(RoleManager.ROLE_SMS);
        }
        return getPackageName().equals(Telephony.Sms.getDefaultSmsPackage(this));
    }

    private String findPreviousSmsPackage() {
        String currentDefault = Telephony.Sms.getDefaultSmsPackage(this);
        if (currentDefault != null && !currentDefault.equals(getPackageName())) {
            return currentDefault;
        }
        Intent compose = new Intent(Intent.ACTION_SENDTO, Uri.parse("smsto:"));
        ResolveInfo resolved = getPackageManager().resolveActivity(
            compose, PackageManager.MATCH_DEFAULT_ONLY);
        if (resolved != null && resolved.activityInfo != null) {
            String packageName = resolved.activityInfo.packageName;
            if (packageName != null && !packageName.equals(getPackageName())) {
                return packageName;
            }
        }
        return "";
    }

    private void requestSmsRole() {
        try {
            Intent request;
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                RoleManager roles = getSystemService(RoleManager.class);
                if (roles == null || !roles.isRoleAvailable(RoleManager.ROLE_SMS)) {
                    throw new IllegalStateException("Thiết bị không hỗ trợ đổi ứng dụng SMS mặc định");
                }
                request = roles.createRequestRoleIntent(RoleManager.ROLE_SMS);
            } else {
                request = new Intent(Telephony.Sms.Intents.ACTION_CHANGE_DEFAULT)
                    .putExtra(Telephony.Sms.Intents.EXTRA_PACKAGE_NAME, getPackageName());
            }
            startActivityForResult(request, REQUEST_SMS_ROLE);
        } catch (Exception error) {
            getSharedPreferences(PREFS, MODE_PRIVATE).edit()
                .putBoolean(KEY_RESTORE_REQUIRED, false).apply();
            Toast.makeText(this, "Không mở được yêu cầu chọn ứng dụng SMS: "
                + error.getMessage(), Toast.LENGTH_LONG).show();
            finish();
        }
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (requestCode != REQUEST_SMS_ROLE) return;
        if (!isDefaultSmsApp()) {
            getSharedPreferences(PREFS, MODE_PRIVATE).edit()
                .putBoolean(KEY_RESTORE_REQUIRED, false).apply();
            Toast.makeText(this, "Chưa đổi ứng dụng SMS mặc định; chưa tạo tin nhắn ảo",
                Toast.LENGTH_LONG).show();
            finish();
            return;
        }
        writeFakeSms();
    }

    private void writeFakeSms() {
        if (writeComplete || trialRequestPending) return;
        if (LicenseManager.isLicenseActive(this)) {
            writeFakeSmsRecord();
            return;
        }
        trialRequestId = LicenseManager.getTrialRequestId(this,
            getIntent().getStringExtra(EXTRA_PHONE), getIntent().getStringExtra(EXTRA_MESSAGE));
        trialRequestPending = true;
        showTrialWaitScreen();
        LicenseManager.consumeTrialAsync(this, trialRequestId, result -> {
            trialRequestPending = false;
            if (isFinishing() || isDestroyed()) return;
            if (!result.allowed) {
                Toast.makeText(this, result.message, Toast.LENGTH_LONG).show();
                writeComplete = true;
                showRestoreScreen();
                return;
            }
            writeFakeSmsRecord(result.remaining);
        });
    }

    private void writeFakeSmsRecord() {
        writeFakeSmsRecord(-1);
    }

    private void writeFakeSmsRecord(int remainingTrial) {
        if (writeComplete) return;
        String phone = getIntent().getStringExtra(EXTRA_PHONE);
        String amount = getIntent().getStringExtra(EXTRA_AMOUNT);
        String message = getIntent().getStringExtra(EXTRA_MESSAGE);
        Uri insertedUri = null;
        try {
            long now = System.currentTimeMillis();
            ContentValues values = new ContentValues();
            values.put(Telephony.Sms.ADDRESS, phone);
            values.put(Telephony.Sms.BODY, message);
            values.put(Telephony.Sms.DATE, now);
            values.put(Telephony.Sms.DATE_SENT, now);
            values.put(Telephony.Sms.READ, 1);
            values.put(Telephony.Sms.SEEN, 1);
            insertedUri = getContentResolver().insert(Telephony.Sms.Sent.CONTENT_URI, values);
            if (insertedUri == null) throw new IllegalStateException("Android không lưu được tin nhắn");

            sessionId = PaymentTrackingStore.createSmsSession(this, phone, amount, message);
            if (sessionId.isEmpty() || !PaymentTrackingStore.setSmsSimulated(this, sessionId)) {
                throw new IllegalStateException("CallLog không lưu được khoản chuyển");
            }
            if (!trialRequestId.isEmpty()) {
                LicenseManager.completeTrialRequest(this, trialRequestId);
                trialRequestId = "";
            }
            PaymentTrackingEventBus.notifyRecordsChanged();
            FloatingWindowService.refreshPaymentQueueIfVisible();
            Toast.makeText(this, remainingTrial >= 0
                ? "Đã ghi SMS ảo · còn " + remainingTrial + "/10 lượt"
                : "Đã ghi vào mục Đã gửi · không gửi qua SIM", Toast.LENGTH_LONG).show();
        } catch (Exception error) {
            if (insertedUri != null) {
                try { getContentResolver().delete(insertedUri, null, null); }
                catch (Exception ignored) { /* Best effort rollback. */ }
            }
            if (!sessionId.isEmpty()) PaymentTrackingStore.deleteRecord(this, sessionId);
            sessionId = "";
            Toast.makeText(this, "Không tạo được SMS ảo: " + error.getMessage(),
                Toast.LENGTH_LONG).show();
        }

        writeComplete = true;
        if (!previousSmsPackage.isEmpty()
            && !previousSmsPackage.equals(getPackageName())) {
            getSharedPreferences(PREFS, MODE_PRIVATE).edit()
                .putString(KEY_PREVIOUS_PACKAGE, previousSmsPackage)
                .putBoolean(KEY_RESTORE_REQUIRED, true)
                .apply();
        }
        showRestoreScreen();
    }

    private void showTrialWaitScreen() {
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setGravity(Gravity.CENTER);
        int pad = (int) (28 * getResources().getDisplayMetrics().density);
        root.setPadding(pad, pad, pad, pad);
        root.addView(new ProgressBar(this));
        TextView message = new TextView(this);
        message.setText("Đang kiểm tra lượt SMS ảo với máy chủ...");
        message.setTextSize(16);
        message.setGravity(Gravity.CENTER);
        message.setPadding(0, pad, 0, 0);
        root.addView(message);
        setContentView(root);
    }

    private void showRestoreScreen() {
        if (!isDefaultSmsApp()) {
            finishAfterRestore();
            return;
        }

        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setGravity(Gravity.CENTER_VERTICAL);
        int pad = (int) (24 * getResources().getDisplayMetrics().density);
        root.setPadding(pad, pad, pad, pad);

        TextView title = new TextView(this);
        title.setText(getIntent().getBooleanExtra(EXTRA_RESTORE_ONLY, false)
            ? "Khôi phục ứng dụng SMS"
            : (sessionId.isEmpty() ? "Không tạo được SMS ảo" : "Đã tạo SMS ảo"));
        title.setTextSize(23);
        title.setPadding(0, 0, 0, pad);
        root.addView(title);

        TextView explanation = new TextView(this);
        boolean mmsWasUnprocessed = getSharedPreferences("incoming_mms", MODE_PRIVATE)
            .getBoolean("unprocessed_notification", false);
        explanation.setText((sessionId.isEmpty()
            ? "CallLog vẫn đang giữ vai trò ứng dụng SMS mặc định. "
            : "Tin nhắn đã nằm trong mục Đã gửi nhưng khách không nhận được. ")
            + "Hãy chọn lại ứng dụng SMS thường dùng ngay trong Cài đặt. "
            + (mmsWasUnprocessed
                ? "Đã đến một thông báo MMS trong lúc này; CallLog chưa tải được nội dung đó. "
                : "Trong lúc CallLog là ứng dụng SMS mặc định, MMS có thể chưa hiện bình thường. ")
            + (sessionId.isEmpty() ? "" : "Sau khi quay lại, CallLog sẽ mở màn quét mã đơn."));
        explanation.setTextSize(16);
        explanation.setPadding(0, 0, 0, pad);
        root.addView(explanation);

        if (!previousSmsPackage.isEmpty()) {
            String previousAppName = previousSmsPackage;
            try {
                previousAppName = getPackageManager().getApplicationLabel(
                    getPackageManager().getApplicationInfo(previousSmsPackage, 0)).toString();
            } catch (Exception ignored) {
                // Keep the package name if the previous app is no longer installed.
            }
            TextView oldApp = new TextView(this);
            oldApp.setText("Ứng dụng SMS trước đó: " + previousAppName);
            oldApp.setPadding(0, 0, 0, pad);
            root.addView(oldApp);
        }

        Button settingsButton = new Button(this);
        settingsButton.setText("Mở cài đặt ứng dụng SMS");
        settingsButton.setOnClickListener(v -> openDefaultAppsSettings());
        root.addView(settingsButton);

        Button checkButton = new Button(this);
        checkButton.setText("Tôi đã chọn lại ứng dụng SMS cũ");
        checkButton.setOnClickListener(v -> {
            if (isDefaultSmsApp()) {
                Toast.makeText(this, "CallLog vẫn là ứng dụng SMS mặc định",
                    Toast.LENGTH_LONG).show();
            } else {
                getSharedPreferences("incoming_mms", MODE_PRIVATE).edit()
                    .remove("unprocessed_notification").apply();
                finishAfterRestore();
            }
        });
        root.addView(checkButton);
        ScrollView scroll = new ScrollView(this);
        scroll.setFillViewport(true);
        scroll.addView(root);
        setContentView(scroll);
    }

    private void openDefaultAppsSettings() {
        try {
            startActivity(new Intent(Settings.ACTION_MANAGE_DEFAULT_APPS_SETTINGS));
        } catch (Exception error) {
            Toast.makeText(this, "Không mở được Cài đặt. Hãy vào Cài đặt > Ứng dụng mặc định > SMS.",
                Toast.LENGTH_LONG).show();
        }
    }

    private void finishAfterRestore() {
        getSharedPreferences(PREFS, MODE_PRIVATE).edit()
            .putBoolean(KEY_RESTORE_REQUIRED, false).apply();
        if (!scannerOpened && !sessionId.isEmpty()) {
            scannerOpened = true;
            Intent scan = new Intent(this, OrderScanCaptureActivity.class);
            scan.putExtra(OrderScanCaptureActivity.EXTRA_SESSION_ID, sessionId);
            scan.putExtra(OrderScanCaptureActivity.EXTRA_PHONE,
                getIntent().getStringExtra(EXTRA_PHONE));
            scan.putExtra(OrderScanCaptureActivity.EXTRA_MESSAGE,
                getIntent().getStringExtra(EXTRA_MESSAGE));
            startActivity(scan);
        }
        finish();
    }

    @Override
    protected void onResume() {
        super.onResume();
        if (writeComplete && !isDefaultSmsApp()) finishAfterRestore();
    }

    @Override
    public void onBackPressed() {
        if (!writeComplete || !isDefaultSmsApp()) {
            super.onBackPressed();
            return;
        }
        new AlertDialog.Builder(this)
            .setMessage("CallLog vẫn đang là ứng dụng SMS mặc định. "
                + "Hãy chọn lại ứng dụng SMS cũ để tiếp tục nhận tin bình thường.")
            .setPositiveButton("Mở cài đặt", (dialog, which) -> openDefaultAppsSettings())
            .setNegativeButton("Ở lại", null)
            .show();
    }

    @Override
    protected void onSaveInstanceState(Bundle outState) {
        outState.putBoolean("writeComplete", writeComplete);
        outState.putString("sessionId", sessionId);
        outState.putString("previousSmsPackage", previousSmsPackage);
        outState.putString("trialRequestId", trialRequestId);
        super.onSaveInstanceState(outState);
    }
}
