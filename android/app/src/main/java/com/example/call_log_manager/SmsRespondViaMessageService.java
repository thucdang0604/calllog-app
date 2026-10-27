package com.example.call_log_manager;

import android.app.Service;
import android.content.Intent;
import android.os.IBinder;

/** Role eligibility component; CallLog never sends a reply without a user action. */
public final class SmsRespondViaMessageService extends Service {
    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }
}
