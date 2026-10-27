package com.example.call_log_manager;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.provider.Telephony;
import android.util.Log;

import java.io.File;
import java.io.FileOutputStream;

/** Preserve an MMS notification PDU if one arrives during the short role switch. */
public final class IncomingMmsReceiver extends BroadcastReceiver {
    private static final String TAG = "IncomingMmsReceiver";

    @Override
    public void onReceive(Context context, Intent intent) {
        if (intent == null
            || !Telephony.Sms.Intents.WAP_PUSH_DELIVER_ACTION.equals(intent.getAction())) return;
        byte[] pdu = intent.getByteArrayExtra("data");
        if (pdu == null || pdu.length == 0) return;

        File directory = new File(context.getFilesDir(), "mms_during_sms_role");
        if (!directory.exists() && !directory.mkdirs()) {
            Log.e(TAG, "Could not create MMS backup directory");
            return;
        }
        File backup = new File(directory, System.currentTimeMillis() + ".pdu");
        try (FileOutputStream stream = new FileOutputStream(backup)) {
            stream.write(pdu);
            Log.w(TAG, "MMS notification saved while CallLog held SMS role: " + backup);
        } catch (Exception error) {
            Log.e(TAG, "Could not preserve incoming MMS notification", error);
        }
    }
}
