package com.example.call_log_manager;

import android.app.Activity;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.telephony.SmsManager;
import android.widget.Toast;

public class SmsSentResultReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context context, Intent intent) {
        String sessionId = intent.getStringExtra("sessionId");

        if (getResultCode() == Activity.RESULT_OK) {
            PaymentTrackingStore.setSmsStatus(context, sessionId, true);
            Toast.makeText(context, "SMS đã gửi lên mạng", Toast.LENGTH_SHORT).show();
            return;
        }

        PaymentTrackingStore.setSmsStatus(context, sessionId, false);

        String message = "Gửi SMS thất bại";
        int resultCode = getResultCode();
        int errorCode = intent.getIntExtra("errorCode", -1);
        boolean noDefaultSmsSubscription = intent.getBooleanExtra("noDefault", false);
        if (noDefaultSmsSubscription) {
            message = "Gửi SMS thất bại: chưa chọn SIM gửi tin nhắn";
        } else if (resultCode == SmsManager.RESULT_ERROR_NO_SERVICE) {
            message = "Gửi SMS thất bại: không có sóng di động";
        } else if (resultCode == SmsManager.RESULT_ERROR_RADIO_OFF) {
            message = "Gửi SMS thất bại: radio di động đang tắt";
        } else if (resultCode == SmsManager.RESULT_ERROR_NULL_PDU) {
            message = "Gửi SMS thất bại: nội dung không hợp lệ";
        } else if (resultCode == SmsManager.RESULT_ERROR_LIMIT_EXCEEDED) {
            message = "Gửi SMS thất bại: vượt giới hạn gửi tin";
        } else if (resultCode == SmsManager.RESULT_ERROR_FDN_CHECK_FAILURE) {
            message = "Gửi SMS thất bại: số điện thoại bị chặn bởi FDN";
        } else if (resultCode == SmsManager.RESULT_ERROR_GENERIC_FAILURE) {
            message = errorCode >= 0
                ? "Gửi SMS thất bại: mã lỗi mạng " + errorCode
                : "Gửi SMS thất bại: lỗi chung của nhà mạng";
        } else if (errorCode >= 0) {
            message = "Gửi SMS thất bại: mã lỗi mạng " + errorCode;
        } else {
            message = "Gửi SMS thất bại: mã lỗi " + resultCode;
        }
        android.util.Log.e(
            "SmsSentResultReceiver",
            "SMS failed, resultCode=" + resultCode
                + ", errorCode=" + errorCode
                + ", noDefaultSmsSubscription=" + noDefaultSmsSubscription
        );
        Toast.makeText(context, message, Toast.LENGTH_LONG).show();
    }
}
