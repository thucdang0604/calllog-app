package com.example.call_log_manager;

import android.os.Handler;
import android.os.Looper;

import io.flutter.plugin.common.EventChannel;

final class PaymentTrackingEventBus {
    private static final Handler MAIN_HANDLER = new Handler(Looper.getMainLooper());
    private static volatile EventChannel.EventSink eventSink;

    private PaymentTrackingEventBus() {}

    static void setEventSink(EventChannel.EventSink sink) {
        eventSink = sink;
    }

    static void notifyRecordsChanged() {
        MAIN_HANDLER.post(() -> {
            EventChannel.EventSink currentSink = eventSink;
            if (currentSink != null) currentSink.success("updated");
        });
    }
}
