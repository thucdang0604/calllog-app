package com.example.call_log_manager;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.provider.Telephony;
import android.util.Log;
import android.widget.Toast;

/**
 * Warn when MMS arrives during the short role switch.
 * shortcut: This cannot download the MMS payload; replace with a full MMS client if MMS receive becomes a supported flow.
 */
public final class IncomingMmsReceiver extends BroadcastReceiver {
    private static final String TAG = "IncomingMmsReceiver";

    @Override
    public void onReceive(Context context, Intent intent) {
        if (intent == null
            || !Telephony.Sms.Intents.WAP_PUSH_DELIVER_ACTION.equals(intent.getAction())) return;
        byte[] pdu = intent.getByteArrayExtra("data");
        if (pdu == null || pdu.length == 0) return;

        context.getSharedPreferences("incoming_mms", Context.MODE_PRIVATE)
            .edit().putBoolean("unprocessed_notification", true).apply();
        Log.w(TAG, "MMS arrived while CallLog was default; payload was not downloaded");
        Toast.makeText(context,
            "Đã nhận MMS khi CallLog tạm làm SMS mặc định. Nội dung MMS chưa được tải.",
            Toast.LENGTH_LONG).show();
    }
}
