package com.example.call_log_manager;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.Intent;
import android.os.Bundle;
import android.provider.Settings;

/** Handles SENDTO only while CallLog briefly holds the default SMS role. */
public final class SmsSendToActivity extends Activity {
    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        new AlertDialog.Builder(this)
            .setMessage("CallLog chỉ dùng vai trò SMS mặc định để tạo tin ảo. "
                + "Hãy chọn lại ứng dụng SMS thường dùng trước khi soạn tin nhắn thật.")
            .setPositiveButton("Mở cài đặt", (dialog, which) -> {
                startActivity(new Intent(Settings.ACTION_MANAGE_DEFAULT_APPS_SETTINGS));
                finish();
            })
            .setNegativeButton("Đóng", (dialog, which) -> finish())
            .setOnCancelListener(dialog -> finish())
            .show();
    }
}
