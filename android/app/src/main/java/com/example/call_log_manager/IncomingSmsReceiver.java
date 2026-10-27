package com.example.call_log_manager;

import android.content.BroadcastReceiver;
import android.content.ContentValues;
import android.content.Context;
import android.content.Intent;
import android.provider.Telephony;
import android.telephony.SmsMessage;
import android.util.Log;

import java.util.LinkedHashMap;
import java.util.Map;

public final class IncomingSmsReceiver extends BroadcastReceiver {
    private static final String TAG = "IncomingSmsReceiver";

    @Override
    public void onReceive(Context context, Intent intent) {
        if (intent == null) {
            return;
        }

        String action = intent.getAction();
        boolean deliver = Telephony.Sms.Intents.SMS_DELIVER_ACTION.equals(action);
        if (!deliver && !Telephony.Sms.Intents.SMS_RECEIVED_ACTION.equals(action)) return;

        SmsMessage[] messages = Telephony.Sms.Intents.getMessagesFromIntent(intent);
        if (messages == null || messages.length == 0) return;

        Map<String, StringBuilder> messagesBySender = new LinkedHashMap<>();
        Map<String, Long> receivedAtBySender = new LinkedHashMap<>();
        for (SmsMessage message : messages) {
            if (message == null) continue;
            String sender = message.getOriginatingAddress();
            String body = message.getMessageBody();
            if (sender == null || sender.trim().isEmpty() || body == null || body.isEmpty()) continue;

            StringBuilder combined = messagesBySender.get(sender);
            if (combined == null) {
                combined = new StringBuilder();
                messagesBySender.put(sender, combined);
                receivedAtBySender.put(sender, message.getTimestampMillis());
            }
            combined.append(body);
        }

        if (deliver) {
            // While CallLog temporarily holds the SMS role, Android leaves inbox
            // persistence to this receiver. Keep arriving messages available after
            // the user restores their usual messaging app.
            for (Map.Entry<String, StringBuilder> entry : messagesBySender.entrySet()) {
                ContentValues values = new ContentValues();
                values.put(Telephony.Sms.ADDRESS, entry.getKey());
                values.put(Telephony.Sms.BODY, entry.getValue().toString());
                values.put(Telephony.Sms.DATE,
                    receivedAtBySender.getOrDefault(entry.getKey(), System.currentTimeMillis()));
                values.put(Telephony.Sms.READ, 0);
                values.put(Telephony.Sms.SEEN, 0);
                try {
                    context.getContentResolver().insert(Telephony.Sms.Inbox.CONTENT_URI, values);
                } catch (Exception error) {
                    Log.e(TAG, "Could not preserve an incoming SMS", error);
                }
            }
        }

        int matchedRecords = 0;
        for (Map.Entry<String, StringBuilder> entry : messagesBySender.entrySet()) {
            matchedRecords += PaymentTrackingStore.recordCustomerReply(
                context,
                entry.getKey(),
                entry.getValue().toString(),
                receivedAtBySender.getOrDefault(entry.getKey(), System.currentTimeMillis())
            );
        }

        if (matchedRecords > 0) {
            Log.i(TAG, "Customer reply matched " + matchedRecords + " pending payment record(s)");
            PaymentTrackingEventBus.notifyRecordsChanged();
            FloatingWindowService.refreshPaymentQueueIfVisible();
        }
    }
}
