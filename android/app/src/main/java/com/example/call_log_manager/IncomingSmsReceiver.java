package com.example.call_log_manager;

import android.content.BroadcastReceiver;
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
        if (intent == null || !Telephony.Sms.Intents.SMS_RECEIVED_ACTION.equals(intent.getAction())) {
            return;
        }

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
