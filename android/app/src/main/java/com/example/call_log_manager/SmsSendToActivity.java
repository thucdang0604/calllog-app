package com.example.call_log_manager;

import android.app.Activity;
import android.app.AlertDialog;
import android.app.role.RoleManager;
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
 * (so delivery apps verify the requirement without carrier cost) or send a real SMS.
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

        SharedPreferences prefs = getSharedPreferences(PREFS_NAME, MODE_PRIVATE);
        boolean autoFake = prefs.getBoolean(KEY_AUTO_FAKE_INTENT, false);

        // If auto-fake is active and we have phone & message, create immediately if default SMS app
        if (autoFake && !phone.isEmpty() && !message.isEmpty() && isDefaultSmsApp()) {
            boolean ok = writeFakeSms(phone, message);
            if (ok) {
                Toast.makeText(this, "⚡ Đã tự động tạo SMS ảo cho: " + phone, Toast.LENGTH_SHORT).show();
                finish();
                return;
            }
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
                            Toast.makeText(this, "✅ Đã tạo SMS ảo vào thư mục Đã gửi!", Toast.LENGTH_SHORT).show();
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
            return insertedUri != null;
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
            writeFakeSms(phone, message);
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

        TextView tvSubtitle = new TextView(this);
        tvSubtitle.setText("Ứng dụng nhận được yêu cầu gửi tin nhắn từ GHN.");
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

        // Nút Tạo SMS ảo (vào thư mục Đã gửi)
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
            .setTitle("Xử lý tin nhắn (GHN)")
            .setView(scrollView)
            .setNegativeButton("Đóng", (d, w) -> finish())
            .setOnCancelListener(d -> finish())
            .create();

        btnFake.setOnClickListener(v -> {
            String pStr = etPhone.getText().toString().trim();
            String mStr = etMessage.getText().toString().trim();
            prefs.edit().putBoolean(KEY_AUTO_FAKE_INTENT, cbAuto.isChecked()).apply();

            if (!isDefaultSmsApp()) {
                pendingPhone = pStr;
                pendingMessage = mStr;
                pendingIsFake = true;
                dialog.dismiss();
                requestSmsRole();
                return;
            }

            if (writeFakeSms(pStr, mStr)) {
                Toast.makeText(this, "✅ Đã tạo SMS ảo vào thư mục Đã gửi thành công!", Toast.LENGTH_SHORT).show();
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

    private int dp(int value) {
        return (int) TypedValue.applyDimension(
            TypedValue.COMPLEX_UNIT_DIP, value, getResources().getDisplayMetrics());
    }
}
