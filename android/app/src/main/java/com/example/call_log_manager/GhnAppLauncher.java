package com.example.call_log_manager;

import android.content.ClipboardManager;
import android.content.ClipData;
import android.content.Context;
import android.content.Intent;
import android.widget.Toast;

final class GhnAppLauncher {
    private static final String GHN_PACKAGE = "com.mpds";

    private GhnAppLauncher() {}

    static boolean open(Context context, String orderCode) {
        String code = orderCode == null ? "" : orderCode.trim();
        if (code.isEmpty()) return false;

        ClipboardManager clipboard =
            (ClipboardManager) context.getSystemService(Context.CLIPBOARD_SERVICE);
        if (clipboard != null) {
            clipboard.setPrimaryClip(ClipData.newPlainText("Mã vận đơn", code));
        }

        Intent launchIntent = context.getPackageManager().getLaunchIntentForPackage(GHN_PACKAGE);
        if (launchIntent == null) {
            Toast.makeText(
                context,
                "Đã sao chép mã " + code + ". Chưa tìm thấy ứng dụng GHN.",
                Toast.LENGTH_LONG
            ).show();
            return false;
        }

        launchIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_NO_ANIMATION);
        context.startActivity(launchIntent);
        Toast.makeText(
            context,
            "Đã sao chép mã " + code + ". Dán mã vào ô tìm kiếm trong GHN.",
            Toast.LENGTH_LONG
        ).show();
        return true;
    }
}
