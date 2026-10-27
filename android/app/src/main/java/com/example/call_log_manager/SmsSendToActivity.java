package com.example.call_log_manager;

import android.app.Activity;
import android.app.AlertDialog;
import android.app.role.RoleManager;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.ContentValues;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.graphics.Color;
import android.graphics.Typeface;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.provider.Settings;
import android.provider.Telephony;
import android.telephony.SmsManager;
import android.text.InputType;
import android.util.Log;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.CheckBox;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;

import java.util.ArrayList;

/**
 * Handles SENDTO / VIEW / SEND intents when CallLog is set as default SMS app.
 * Allows drivers (GHN, etc.) to either create a fake SMS in the system Sent folder
 * or send a real SMS. Enforces 10-message free trial and hardware-locked license.
 */
public final class SmsSendToActivity extends Activity {
    private static final String TAG = "SmsSendToActivity";
    private static final String PREFS_NAME = "floating_window_state";
    private static final String KEY_AUTO_FAKE_INTENT = "sms_auto_fake_intent";
    private static final int REQUEST_SMS_ROLE = 9021;

    private String pendingPhone = "";
    private String pendingMessage = "";
    private boolean pendingIsFake = true;

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);

        String phone = extractPhone(getIntent());
        String message = extractMessage(getIntent());

        boolean isAvailable = LicenseManager.isSmsFeatureAvailable(this);

        SharedPreferences prefs = getSharedPreferences(PREFS_NAME, MODE_PRIVATE);
        boolean autoFake = prefs.getBoolean(KEY_AUTO_FAKE_INTENT, false);

        // Auto-fake is only permitted if feature is available (active license or remaining trial)
        if (autoFake && isAvailable && !phone.isEmpty() && !message.isEmpty() && isDefaultSmsApp()) {
            boolean ok = writeFakeSms(phone, message);
            if (ok) {
                finish();
                return;
            }
        }

        // If trial expired and no license, open the upgrade dialog directly
        if (!isAvailable) {
            showUpgradeDialog(phone, message);
            return;
        }

        showActionDialog(phone, message);
    }

    private String extractPhone(Intent intent) {
        if (intent == null) return "";
        String phone = "";
        Uri uri = intent.getData();
        if (uri != null) {
            String ssp = uri.getSchemeSpecificPart();
            if (ssp != null) {
                int q = ssp.indexOf('?');
                phone = (q >= 0) ? ssp.substring(0, q) : ssp;
            }
        }
        if (phone == null || phone.isEmpty()) {
            if (intent.hasExtra("address")) {
                phone = intent.getStringExtra("address");
            } else if (intent.hasExtra(Intent.EXTRA_PHONE_NUMBER)) {
                phone = intent.getStringExtra(Intent.EXTRA_PHONE_NUMBER);
            } else if (intent.hasExtra("phone")) {
                phone = intent.getStringExtra("phone");
            } else if (intent.hasExtra("addresses")) {
                String[] addresses = intent.getStringArrayExtra("addresses");
                if (addresses != null && addresses.length > 0) {
                    phone = addresses[0];
                }
            }
        }
        if (phone != null) {
            phone = Uri.decode(phone).trim();
            if (phone.contains(";")) {
                phone = phone.split(";")[0].trim();
            } else if (phone.contains(",")) {
                phone = phone.split(",")[0].trim();
            }
        }
        return (phone != null) ? phone : "";
    }

    private String extractMessage(Intent intent) {
        if (intent == null) return "";
        String message = "";
        if (intent.hasExtra("sms_body")) {
            message = intent.getStringExtra("sms_body");
        }
        if ((message == null || message.isEmpty()) && intent.hasExtra(Intent.EXTRA_TEXT)) {
            CharSequence cs = intent.getCharSequenceExtra(Intent.EXTRA_TEXT);
            if (cs != null) message = cs.toString();
        }
        if ((message == null || message.isEmpty()) && intent.hasExtra("android.intent.extra.TEXT")) {
            message = intent.getStringExtra("android.intent.extra.TEXT");
        }
        if ((message == null || message.isEmpty()) && intent.getData() != null) {
            try {
                String qb = intent.getData().getQueryParameter("body");
                if (qb != null) message = qb;
            } catch (Exception ignored) {}
        }
        return (message != null) ? message.trim() : "";
    }

    private boolean isDefaultSmsApp() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            RoleManager roles = getSystemService(RoleManager.class);
            return roles != null && roles.isRoleHeld(RoleManager.ROLE_SMS);
        }
        return getPackageName().equals(Telephony.Sms.getDefaultSmsPackage(this));
    }

    private void requestSmsRole() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            RoleManager roles = getSystemService(RoleManager.class);
            if (roles != null && roles.isRoleAvailable(RoleManager.ROLE_SMS)) {
                startActivityForResult(roles.createRequestRoleIntent(RoleManager.ROLE_SMS), REQUEST_SMS_ROLE);
                return;
            }
        }
        Intent request = new Intent(Telephony.Sms.Intents.ACTION_CHANGE_DEFAULT)
            .putExtra(Telephony.Sms.Intents.EXTRA_PACKAGE_NAME, getPackageName());
        startActivityForResult(request, REQUEST_SMS_ROLE);
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (requestCode == REQUEST_SMS_ROLE) {
            if (isDefaultSmsApp()) {
                if (!pendingPhone.isEmpty() && !pendingMessage.isEmpty()) {
                    if (pendingIsFake) {
                        if (writeFakeSms(pendingPhone, pendingMessage)) {
                            finish();
                            return;
                        }
                    } else {
                        if (sendRealSms(pendingPhone, pendingMessage)) {
                            finish();
                            return;
                        }
                    }
                }
                Toast.makeText(this, "Đã cấp quyền SMS mặc định.", Toast.LENGTH_SHORT).show();
            } else {
                Toast.makeText(this, "Chưa cấp quyền SMS mặc định cho APP NVPTTT", Toast.LENGTH_SHORT).show();
            }
        }
    }

    private boolean writeFakeSms(String phone, String message) {
        if (phone == null || phone.isEmpty() || message == null || message.isEmpty()) {
            Toast.makeText(this, "⚠️ Số nhận hoặc nội dung tin nhắn trống", Toast.LENGTH_SHORT).show();
            return false;
        }

        // License check
        if (!LicenseManager.isSmsFeatureAvailable(this)) {
            showUpgradeDialog(phone, message);
            return false;
        }

        try {
            long now = System.currentTimeMillis();
            ContentValues values = new ContentValues();
            values.put(Telephony.Sms.ADDRESS, phone);
            values.put(Telephony.Sms.BODY, message);
            values.put(Telephony.Sms.DATE, now);
            values.put(Telephony.Sms.DATE_SENT, now);
            values.put(Telephony.Sms.READ, 1);
            values.put(Telephony.Sms.SEEN, 1);
            values.put(Telephony.Sms.TYPE, Telephony.Sms.MESSAGE_TYPE_SENT); // 2 = Sent
            values.put(Telephony.Sms.STATUS, Telephony.Sms.STATUS_COMPLETE); // 0 = Complete

            Uri insertedUri = getContentResolver().insert(Telephony.Sms.Sent.CONTENT_URI, values);
            if (insertedUri == null) {
                insertedUri = getContentResolver().insert(Uri.parse("content://sms/sent"), values);
            }

            if (insertedUri != null) {
                if (!LicenseManager.isLicenseActive(this)) {
                    LicenseManager.consumeTrial(this);
                    int remaining = LicenseManager.getRemainingTrial(this);
                    Toast.makeText(this, "✅ Đã tạo SMS ảo! (Trải nghiệm còn " + remaining + "/10 lượt)", Toast.LENGTH_LONG).show();
                } else {
                    Toast.makeText(this, "✅ Đã tạo SMS ảo vào thư mục Đã gửi thành công!", Toast.LENGTH_SHORT).show();
                }
                return true;
            }
            return false;
        } catch (Exception e) {
            Log.e(TAG, "Error writing fake SMS", e);
            Toast.makeText(this, "Lỗi tạo SMS ảo: " + e.getMessage(), Toast.LENGTH_LONG).show();
            return false;
        }
    }

    private boolean sendRealSms(String phone, String message) {
        if (phone == null || phone.isEmpty() || message == null || message.isEmpty()) {
            Toast.makeText(this, "⚠️ Số nhận hoặc nội dung tin nhắn trống", Toast.LENGTH_SHORT).show();
            return false;
        }
        try {
            SmsManager smsManager;
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                smsManager = getSystemService(SmsManager.class);
            } else {
                smsManager = SmsManager.getDefault();
            }
            ArrayList<String> parts = smsManager.divideMessage(message);
            if (parts.size() > 1) {
                smsManager.sendMultipartTextMessage(phone, null, parts, null, null);
            } else {
                smsManager.sendTextMessage(phone, null, message, null, null);
            }
            // Save copy into Sent box
            try {
                ContentValues values = new ContentValues();
                values.put(Telephony.Sms.ADDRESS, phone);
                values.put(Telephony.Sms.BODY, message);
                values.put(Telephony.Sms.DATE, System.currentTimeMillis());
                values.put(Telephony.Sms.DATE_SENT, System.currentTimeMillis());
                values.put(Telephony.Sms.READ, 1);
                values.put(Telephony.Sms.SEEN, 1);
                values.put(Telephony.Sms.TYPE, Telephony.Sms.MESSAGE_TYPE_SENT);
                getContentResolver().insert(Telephony.Sms.Sent.CONTENT_URI, values);
            } catch (Exception ignored) {}

            Toast.makeText(this, "📤 Đang gửi tin nhắn qua SIM tới " + phone, Toast.LENGTH_SHORT).show();
            return true;
        } catch (Exception e) {
            Log.e(TAG, "Error sending real SMS", e);
            Toast.makeText(this, "Lỗi gửi SMS qua SIM: " + e.getMessage(), Toast.LENGTH_LONG).show();
            return false;
        }
    }

    private void showActionDialog(String initialPhone, String initialMessage) {
        ScrollView scrollView = new ScrollView(this);
        LinearLayout layout = new LinearLayout(this);
        layout.setOrientation(LinearLayout.VERTICAL);
        int p = dp(16);
        layout.setPadding(p, p, p, p);
        scrollView.addView(layout);

        // License / Trial status banner
        boolean isLicensed = LicenseManager.isLicenseActive(this);
        int remainingTrial = LicenseManager.getRemainingTrial(this);

        LinearLayout banner = new LinearLayout(this);
        banner.setOrientation(LinearLayout.HORIZONTAL);
        banner.setGravity(Gravity.CENTER_VERTICAL);
        banner.setPadding(dp(10), dp(6), dp(10), dp(6));
        banner.setBackgroundColor(Color.parseColor(isLicensed ? "#DCFCE7" : "#FEF3C7"));
        LinearLayout.LayoutParams lpBanner = new LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        lpBanner.setMargins(0, 0, 0, dp(10));
        banner.setLayoutParams(lpBanner);

        TextView tvStatus = new TextView(this);
        if (isLicensed) {
            tvStatus.setText("🔑 Bản quyền SMS: ĐÃ KÍCH HOẠT");
            tvStatus.setTextColor(Color.parseColor("#15803D"));
        } else {
            tvStatus.setText("⚡ Trải nghiệm: Còn " + remainingTrial + "/10 tin nhắn miễn phí");
            tvStatus.setTextColor(Color.parseColor("#B45309"));
        }
        tvStatus.setTypeface(null, Typeface.BOLD);
        tvStatus.setTextSize(TypedValue.COMPLEX_UNIT_SP, 12);
        banner.addView(tvStatus);
        layout.addView(banner);

        TextView tvSubtitle = new TextView(this);
        tvSubtitle.setText("Ứng dụng nhận được yêu cầu gửi tin nhắn từ APP.");
        tvSubtitle.setTextColor(Color.parseColor("#4B5563"));
        tvSubtitle.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13);
        layout.addView(tvSubtitle);

        TextView lblPhone = new TextView(this);
        lblPhone.setText("Người nhận:");
        lblPhone.setTypeface(null, Typeface.BOLD);
        lblPhone.setTextColor(Color.parseColor("#1F2937"));
        lblPhone.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13);
        lblPhone.setPadding(0, dp(10), 0, dp(4));
        layout.addView(lblPhone);

        EditText etPhone = new EditText(this);
        etPhone.setText(initialPhone);
        etPhone.setInputType(InputType.TYPE_CLASS_PHONE);
        etPhone.setBackgroundColor(Color.parseColor("#F3F4F6"));
        etPhone.setPadding(dp(10), dp(8), dp(10), dp(8));
        etPhone.setTextSize(TypedValue.COMPLEX_UNIT_SP, 14);
        layout.addView(etPhone);

        TextView lblMessage = new TextView(this);
        lblMessage.setText("Nội dung tin nhắn:");
        lblMessage.setTypeface(null, Typeface.BOLD);
        lblMessage.setTextColor(Color.parseColor("#1F2937"));
        lblMessage.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13);
        lblMessage.setPadding(0, dp(10), 0, dp(4));
        layout.addView(lblMessage);

        EditText etMessage = new EditText(this);
        etMessage.setText(initialMessage);
        etMessage.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_FLAG_MULTI_LINE);
        etMessage.setMinLines(3);
        etMessage.setMaxLines(6);
        etMessage.setGravity(Gravity.TOP | Gravity.START);
        etMessage.setBackgroundColor(Color.parseColor("#F3F4F6"));
        etMessage.setPadding(dp(10), dp(8), dp(10), dp(8));
        etMessage.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13);
        layout.addView(etMessage);

        SharedPreferences prefs = getSharedPreferences(PREFS_NAME, MODE_PRIVATE);
        CheckBox cbAuto = new CheckBox(this);
        cbAuto.setText("⚡ Tự động tạo SMS ảo cho các lần sau");
        cbAuto.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13);
        cbAuto.setTextColor(Color.parseColor("#059669"));
        cbAuto.setChecked(prefs.getBoolean(KEY_AUTO_FAKE_INTENT, false));
        cbAuto.setPadding(0, dp(8), 0, dp(8));
        layout.addView(cbAuto);

        // Nút Tạo SMS ảo
        Button btnFake = new Button(this);
        btnFake.setText("✅ TẠO SMS ẢO (VÀO ĐÃ GỬI)");
        btnFake.setBackgroundColor(Color.parseColor("#10B981"));
        btnFake.setTextColor(Color.WHITE);
        btnFake.setTypeface(null, Typeface.BOLD);
        btnFake.setTextSize(TypedValue.COMPLEX_UNIT_SP, 14);
        LinearLayout.LayoutParams lpBtn = new LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, dp(44));
        lpBtn.setMargins(0, dp(6), 0, dp(6));
        btnFake.setLayoutParams(lpBtn);
        layout.addView(btnFake);

        // Nút Gửi thật qua SIM
        Button btnReal = new Button(this);
        btnReal.setText("📤 GỬI THẬT QUA SIM");
        btnReal.setBackgroundColor(Color.parseColor("#2563EB"));
        btnReal.setTextColor(Color.WHITE);
        btnReal.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13);
        LinearLayout.LayoutParams lpBtn2 = new LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, dp(40));
        lpBtn2.setMargins(0, 0, 0, dp(6));
        btnReal.setLayoutParams(lpBtn2);
        layout.addView(btnReal);

        // Nút Nâng cấp / Kích hoạt (nếu chưa kích hoạt)
        if (!isLicensed) {
            Button btnUpgrade = new Button(this);
            btnUpgrade.setText("⭐ Nâng cấp bản quyền SMS (Mở khóa vĩnh viễn)");
            btnUpgrade.setBackgroundColor(Color.parseColor("#FEF3C7"));
            btnUpgrade.setTextColor(Color.parseColor("#D97706"));
            btnUpgrade.setTextSize(TypedValue.COMPLEX_UNIT_SP, 12);
            LinearLayout.LayoutParams lpUp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, dp(38));
            lpUp.setMargins(0, 0, 0, dp(6));
            btnUpgrade.setLayoutParams(lpUp);
            btnUpgrade.setOnClickListener(v -> showUpgradeDialog(initialPhone, initialMessage));
            layout.addView(btnUpgrade);
        }

        // Nút Đổi lại app SMS mặc định
        Button btnDefault = new Button(this);
        btnDefault.setText("⚙️ Đổi lại ứng dụng SMS mặc định (Google Tin nhắn)");
        btnDefault.setBackgroundColor(Color.parseColor("#E5E7EB"));
        btnDefault.setTextColor(Color.parseColor("#374151"));
        btnDefault.setTextSize(TypedValue.COMPLEX_UNIT_SP, 12);
        LinearLayout.LayoutParams lpBtn3 = new LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, dp(38));
        lpBtn3.setMargins(0, 0, 0, dp(4));
        btnDefault.setLayoutParams(lpBtn3);
        layout.addView(btnDefault);

        AlertDialog dialog = new AlertDialog.Builder(this)
            .setTitle("Xử lý tin nhắn (APP)")
            .setView(scrollView)
            .setNegativeButton("Đóng", (d, w) -> finish())
            .setOnCancelListener(d -> finish())
            .create();

        btnFake.setOnClickListener(v -> {
            String pStr = etPhone.getText().toString().trim();
            String mStr = etMessage.getText().toString().trim();
            prefs.edit().putBoolean(KEY_AUTO_FAKE_INTENT, cbAuto.isChecked()).apply();

            if (!LicenseManager.isSmsFeatureAvailable(this)) {
                dialog.dismiss();
                showUpgradeDialog(pStr, mStr);
                return;
            }

            if (!isDefaultSmsApp()) {
                pendingPhone = pStr;
                pendingMessage = mStr;
                pendingIsFake = true;
                dialog.dismiss();
                requestSmsRole();
                return;
            }

            if (writeFakeSms(pStr, mStr)) {
                dialog.dismiss();
                finish();
            }
        });

        btnReal.setOnClickListener(v -> {
            String pStr = etPhone.getText().toString().trim();
            String mStr = etMessage.getText().toString().trim();
            if (sendRealSms(pStr, mStr)) {
                dialog.dismiss();
                finish();
            }
        });

        btnDefault.setOnClickListener(v -> {
            startActivity(new Intent(Settings.ACTION_MANAGE_DEFAULT_APPS_SETTINGS));
            dialog.dismiss();
            finish();
        });

        dialog.show();
    }

    private void showUpgradeDialog(String fallbackPhone, String fallbackMessage) {
        String deviceId = LicenseManager.getDeviceId(this);

        ScrollView scrollView = new ScrollView(this);
        LinearLayout layout = new LinearLayout(this);
        layout.setOrientation(LinearLayout.VERTICAL);
        int p = dp(16);
        layout.setPadding(p, p, p, p);
        scrollView.addView(layout);

        TextView tvHeader = new TextView(this);
        tvHeader.setText("⚠️ Đã hết 10 lượt trải nghiệm miễn phí");
        tvHeader.setTextColor(Color.parseColor("#DC2626"));
        tvHeader.setTypeface(null, Typeface.BOLD);
        tvHeader.setTextSize(TypedValue.COMPLEX_UNIT_SP, 15);
        layout.addView(tvHeader);

        TextView tvDesc = new TextView(this);
        tvDesc.setText("Tính năng tạo SMS ảo đã hết hạn dùng thử trên thiết bị này. Vui lòng thanh toán hoặc nhập mã kích hoạt để tiếp tục sử dụng.");
        tvDesc.setTextColor(Color.parseColor("#4B5563"));
        tvDesc.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13);
        tvDesc.setPadding(0, dp(4), 0, dp(12));
        layout.addView(tvDesc);

        // Box Device ID
        LinearLayout devBox = new LinearLayout(this);
        devBox.setOrientation(LinearLayout.VERTICAL);
        devBox.setBackgroundColor(Color.parseColor("#F1F5F9"));
        devBox.setPadding(dp(12), dp(10), dp(12), dp(10));

        TextView lblDev = new TextView(this);
        lblDev.setText("MÃ THIẾT BỊ CỦA BẠN (CỐ ĐỊNH):");
        lblDev.setTextSize(TypedValue.COMPLEX_UNIT_SP, 11);
        lblDev.setTextColor(Color.parseColor("#64748B"));
        lblDev.setTypeface(null, Typeface.BOLD);
        devBox.addView(lblDev);

        TextView tvDev = new TextView(this);
        tvDev.setText(deviceId);
        tvDev.setTextSize(TypedValue.COMPLEX_UNIT_SP, 18);
        tvDev.setTextColor(Color.parseColor("#0F172A"));
        tvDev.setTypeface(Typeface.MONOSPACE, Typeface.BOLD);
        tvDev.setPadding(0, dp(2), 0, dp(6));
        devBox.addView(tvDev);

        Button btnCopyDev = new Button(this);
        btnCopyDev.setText("📋 Sao chép mã máy");
        btnCopyDev.setBackgroundColor(Color.parseColor("#CBD5E1"));
        btnCopyDev.setTextColor(Color.parseColor("#1E293B"));
        btnCopyDev.setTextSize(TypedValue.COMPLEX_UNIT_SP, 12);
        btnCopyDev.setOnClickListener(v -> {
            copyToClipboard(deviceId, "Đã sao chép mã thiết bị!");
        });
        devBox.addView(btnCopyDev);
        layout.addView(devBox);

        // Banking Info Box
        LinearLayout bankBox = new LinearLayout(this);
        bankBox.setOrientation(LinearLayout.VERTICAL);
        bankBox.setBackgroundColor(Color.parseColor("#ECFDF5"));
        bankBox.setPadding(dp(12), dp(10), dp(12), dp(10));
        LinearLayout.LayoutParams lpBank = new LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        lpBank.setMargins(0, dp(10), 0, dp(10));
        bankBox.setLayoutParams(lpBank);

        TextView lblBank = new TextView(this);
        lblBank.setText("THÔNG TIN CHUYỂN KHOẢN (PHƯƠNG ÁN 1):");
        lblBank.setTextSize(TypedValue.COMPLEX_UNIT_SP, 11);
        lblBank.setTextColor(Color.parseColor("#065F46"));
        lblBank.setTypeface(null, Typeface.BOLD);
        bankBox.addView(lblBank);

        String transferContent = "SMS " + deviceId.replace("SMS-", "").replace("-", "");
        TextView tvBankInfo = new TextView(this);
        tvBankInfo.setText("• Ngân hàng: Techcombank\n• STK: 19034108972011\n• Chủ TK: DANG TRI THUC\n• Nội dung: " + transferContent);
        tvBankInfo.setTextColor(Color.parseColor("#064E3B"));
        tvBankInfo.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13);
        tvBankInfo.setPadding(0, dp(4), 0, dp(6));
        bankBox.addView(tvBankInfo);

        Button btnCopyBank = new Button(this);
        btnCopyBank.setText("📋 Sao chép nội dung chuyển khoản");
        btnCopyBank.setBackgroundColor(Color.parseColor("#A7F3D0"));
        btnCopyBank.setTextColor(Color.parseColor("#065F46"));
        btnCopyBank.setTextSize(TypedValue.COMPLEX_UNIT_SP, 12);
        btnCopyBank.setOnClickListener(v -> {
            copyToClipboard(transferContent, "Đã sao chép nội dung: " + transferContent);
        });
        bankBox.addView(btnCopyBank);
        layout.addView(bankBox);

        // Offline Key Input Box (Phương án 2 dự phòng)
        TextView lblKey = new TextView(this);
        lblKey.setText("NHẬP MÃ KÍCH HOẠT DỰ PHÒNG (PHƯƠNG ÁN 2):");
        lblKey.setTextSize(TypedValue.COMPLEX_UNIT_SP, 12);
        lblKey.setTypeface(null, Typeface.BOLD);
        lblKey.setTextColor(Color.parseColor("#1E293B"));
        lblKey.setPadding(0, dp(4), 0, dp(4));
        layout.addView(lblKey);

        EditText etKey = new EditText(this);
        etKey.setHint("VD: NV1-PERM-00000000-XXXXXXXX");
        etKey.setBackgroundColor(Color.parseColor("#F1F5F9"));
        etKey.setPadding(dp(10), dp(10), dp(10), dp(10));
        etKey.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13);
        etKey.setTypeface(Typeface.MONOSPACE);
        layout.addView(etKey);

        Button btnActivate = new Button(this);
        btnActivate.setText("🔑 KÍCH HOẠT BẰNG MÃ");
        btnActivate.setBackgroundColor(Color.parseColor("#10B981"));
        btnActivate.setTextColor(Color.WHITE);
        btnActivate.setTypeface(null, Typeface.BOLD);
        btnActivate.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13);
        LinearLayout.LayoutParams lpAct = new LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, dp(42));
        lpAct.setMargins(0, dp(6), 0, dp(12));
        btnActivate.setLayoutParams(lpAct);
        layout.addView(btnActivate);

        // Emergency fallback: Send real SMS via carrier SIM so driver isn't blocked
        if (fallbackPhone != null && !fallbackPhone.isEmpty() && fallbackMessage != null && !fallbackMessage.isEmpty()) {
            Button btnEmergencyReal = new Button(this);
            btnEmergencyReal.setText("📤 Gửi tạm tin thật qua SIM (Không tạo SMS ảo)");
            btnEmergencyReal.setBackgroundColor(Color.parseColor("#2563EB"));
            btnEmergencyReal.setTextColor(Color.WHITE);
            btnEmergencyReal.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13);
            LinearLayout.LayoutParams lpEm = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, dp(40));
            lpEm.setMargins(0, 0, 0, dp(6));
            btnEmergencyReal.setLayoutParams(lpEm);
            btnEmergencyReal.setOnClickListener(v -> {
                sendRealSms(fallbackPhone, fallbackMessage);
                finish();
            });
            layout.addView(btnEmergencyReal);
        }

        AlertDialog dialog = new AlertDialog.Builder(this)
            .setTitle("Bản Quyền Tính Năng SMS Ảo")
            .setView(scrollView)
            .setNegativeButton("Đóng", (d, w) -> finish())
            .setOnCancelListener(d -> finish())
            .create();

        btnActivate.setOnClickListener(v -> {
            String keyStr = etKey.getText().toString().trim();
            if (keyStr.isEmpty()) {
                Toast.makeText(this, "Vui lòng nhập mã kích hoạt", Toast.LENGTH_SHORT).show();
                return;
            }
            boolean success = LicenseManager.activateKey(this, keyStr);
            if (success) {
                Toast.makeText(this, "🎉 Kích hoạt bản quyền thành công!", Toast.LENGTH_LONG).show();
                dialog.dismiss();
                if (fallbackPhone != null && !fallbackPhone.isEmpty()) {
                    showActionDialog(fallbackPhone, fallbackMessage);
                } else {
                    finish();
                }
            } else {
                LicenseManager.LicenseInfo info = LicenseManager.verifyLicenseKey(this, keyStr);
                Toast.makeText(this, "❌ Kích hoạt thất bại: " + info.message, Toast.LENGTH_LONG).show();
            }
        });

        dialog.show();
    }

    private void copyToClipboard(String text, String toastMsg) {
        ClipboardManager cm = (ClipboardManager) getSystemService(Context.CLIPBOARD_SERVICE);
        if (cm != null) {
            cm.setPrimaryClip(ClipData.newPlainText("license_data", text));
            Toast.makeText(this, toastMsg, Toast.LENGTH_SHORT).show();
        }
    }

    private int dp(int value) {
        return (int) TypedValue.applyDimension(
            TypedValue.COMPLEX_UNIT_DIP, value, getResources().getDisplayMetrics());
    }
}
