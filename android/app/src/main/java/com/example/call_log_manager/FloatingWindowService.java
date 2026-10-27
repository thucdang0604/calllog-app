package com.example.call_log_manager;

import android.Manifest;
import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.ContentResolver;
import android.content.ContentValues;
import android.content.Context;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.database.ContentObserver;
import android.database.Cursor;
import android.graphics.PixelFormat;
import android.net.Uri;
import android.os.Build;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.os.VibrationEffect;
import android.os.Vibrator;
import android.os.VibratorManager;
import android.provider.CallLog;
import android.provider.Settings;
import android.telephony.PhoneStateListener;
import android.telephony.SmsManager;
import android.telephony.TelephonyManager;
import android.view.Gravity;
import android.view.LayoutInflater;
import android.view.View;
import android.view.WindowManager;
import android.view.inputmethod.InputMethodManager;
import android.widget.Button;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;
import android.util.Log;

import org.json.JSONArray;
import org.json.JSONObject;

import androidx.core.content.ContextCompat;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.UUID;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.ThreadLocalRandom;

/**
 * === Tối ưu v3 (phản hồi nhanh + thiết bị yếu + chạy liên tục 24/7) ===
 * - View recycling: tái sử dụng view thay vì removeAllViews + re-inflate mỗi refresh
 * - Cached LayoutInflater & SharedPreferences: giảm IPC/lookup overhead
 * - ThreadLocalRandom thay vì java.util.Random: lock-free, nhẹ hơn
 * - ContentObserver debounce 400ms: phản hồi nhanh khi có cuộc gọi mới
 * - PhoneStateListener: chủ động phát hiện cuộc gọi kết thúc và refresh ngay
 * - Giảm Toast frequency: chỉ hiển thị khi thật sự cần thiết
 */
public class FloatingWindowService extends Service {
    private static final String TAG = "FloatingWindowService";
    private static final String CHANNEL_ID = "floating_window_channel";
    private static final int NOTIFICATION_ID = 1001;
    private static final String PREFS_NAME = "floating_window_state";
    private static volatile FloatingWindowService activeService;

    private WindowManager windowManager;
    private WindowManager.LayoutParams windowParams;
    private View floatingView;
    private static boolean isFloatingWindowShowing = false;

    private LinearLayout floatingContainer;
    private LinearLayout callsContainer;
    private LinearLayout paymentQueueFilter;
    private ScrollView callsScrollView;
    private Button batchUpdateButton;
    private Button paymentTrackingButton;
    private TextView paymentPendingTab;
    private TextView paymentReceivedTab;
    private LinearLayout smsInputContainer;
    private EditText amountInput;
    private Button sendSmsButton, cancelSmsButton;

    // === Cached objects - giảm repeated lookups ===
    private LayoutInflater cachedInflater;
    private SharedPreferences cachedPrefs;

    // Model dữ liệu và View đại diện cho từng cuộc gọi trong popup
    private static class CallItemHolder {
        int callId = -1;
        String rawPhone = "";
        String displayText = "";
        View itemView;
        TextView phoneView;
        TextView durationView;
        Button smsButton;
        Button updateButton;
    }

    private final List<CallItemHolder> currentCallHolders = new ArrayList<>();
    private int pendingSmsCallIndex = -1;

    private ContentObserver callLogObserver;
    private volatile boolean isSelfUpdating = false;
    private boolean bubbleMode = true;
    private boolean panelExpanded = false;
    private boolean paymentQueueMode = false;
    private boolean paymentQueueShowingReceived = false;

    // === PhoneStateListener: chủ động phát hiện kết thúc cuộc gọi ===
    private TelephonyManager telephonyManager;
    private PhoneStateListener phoneStateListener;
    private boolean wasInCall = false;

    private final ExecutorService backgroundExecutor = Executors.newSingleThreadExecutor();
    private final Handler mainHandler = new Handler(Looper.getMainLooper());
    private final Runnable debouncedCallRefresh = this::onNewCallDetected;

    private SharedPreferences getPrefs() {
        if (cachedPrefs == null) {
            cachedPrefs = getSharedPreferences(PREFS_NAME, MODE_PRIVATE);
        }
        return cachedPrefs;
    }

    private LayoutInflater getInflater() {
        if (cachedInflater == null) {
            cachedInflater = LayoutInflater.from(this);
        }
        return cachedInflater;
    }

    @Override
    public void onCreate() {
        super.onCreate();
        activeService = this;
        startForegroundServiceNotification();

        boolean shouldShow = getPrefs().getBoolean("is_showing", false);
        isFloatingWindowShowing = shouldShow;
        if (shouldShow && floatingView == null) {
            mainHandler.post(this::showFloatingBubble);
        }

        // Tự động khôi phục Fake GPS nếu trước đó đang bật
        try {
            SharedPreferences fakeGpsPrefs = getSharedPreferences("fake_gps_state", MODE_PRIVATE);
            if (fakeGpsPrefs.getBoolean("is_running", false)) {
                float lat = fakeGpsPrefs.getFloat("latitude", 0.0f);
                float lng = fakeGpsPrefs.getFloat("longitude", 0.0f);
                if (lat != 0.0f || lng != 0.0f) {
                    MockLocationManager.getInstance(this).startMockLocation(lat, lng);
                }
            }
        } catch (Exception ignored) {
        }
    }

    private void registerCallLogObserver() {
        if (callLogObserver != null) return;

        callLogObserver = new ContentObserver(mainHandler) {
            @Override
            public void onChange(boolean selfChange, Uri uri) {
                super.onChange(selfChange, uri);
                if (isSelfUpdating || floatingView == null || bubbleMode) {
                    return;
                }
                // Debounce 400ms: đủ nhanh để phản hồi, tránh multiple triggers
                mainHandler.removeCallbacks(debouncedCallRefresh);
                mainHandler.postDelayed(debouncedCallRefresh, 400);
            }
        };

        try {
            getContentResolver().registerContentObserver(
                CallLog.Calls.CONTENT_URI,
                true,
                callLogObserver
            );
        } catch (Exception e) {
            Log.e(TAG, "Lỗi khi đăng ký ContentObserver: ", e);
        }

        // Đăng ký PhoneStateListener để phát hiện cuộc gọi kết thúc chủ động
        registerPhoneStateListener();
    }

    private void unregisterCallLogObserver() {
        if (callLogObserver != null) {
            try {
                getContentResolver().unregisterContentObserver(callLogObserver);
                callLogObserver = null;
            } catch (Exception e) {
                Log.e(TAG, "Lỗi khi hủy ContentObserver: ", e);
            }
        }
        unregisterPhoneStateListener();
    }

    /**
     * PhoneStateListener: lắng nghe trạng thái cuộc gọi.
     * Khi cuộc gọi kết thúc (IDLE sau khi đang gọi), trigger refresh sau 1.2s
     * để chờ hệ thống ghi call log entry.
     */
    @SuppressWarnings("deprecation")
    private void registerPhoneStateListener() {
        if (phoneStateListener != null) return;
        try {
            telephonyManager = (TelephonyManager) getSystemService(Context.TELEPHONY_SERVICE);
            if (telephonyManager == null) return;

            phoneStateListener = new PhoneStateListener() {
                @Override
                public void onCallStateChanged(int state, String phoneNumber) {
                    if (state == TelephonyManager.CALL_STATE_OFFHOOK
                            || state == TelephonyManager.CALL_STATE_RINGING) {
                        wasInCall = true;
                    } else if (state == TelephonyManager.CALL_STATE_IDLE && wasInCall) {
                        wasInCall = false;
                        // Cuộc gọi vừa kết thúc → refresh sau 1.2s (chờ hệ thống ghi log)
                        if (floatingView != null && !bubbleMode) {
                            mainHandler.removeCallbacks(debouncedCallRefresh);
                            mainHandler.postDelayed(debouncedCallRefresh, 1200);
                        }
                    }
                }
            };
            telephonyManager.listen(phoneStateListener, PhoneStateListener.LISTEN_CALL_STATE);
        } catch (Exception e) {
            Log.e(TAG, "Error registering PhoneStateListener", e);
        }
    }

    @SuppressWarnings("deprecation")
    private void unregisterPhoneStateListener() {
        if (telephonyManager != null && phoneStateListener != null) {
            try {
                telephonyManager.listen(phoneStateListener, PhoneStateListener.LISTEN_NONE);
            } catch (Exception ignored) {
            }
            phoneStateListener = null;
        }
    }

    /**
     * Lấy số lượng cuộc gọi cần hiển thị (cấu hình trong SharedPreferences, mặc định 4)
     */
    private int getDisplayCallCount() {
        return Math.max(2, Math.min(6, getPrefs().getInt("display_call_count", 4)));
    }

    private int dp(int value) {
        return (int) (value * getResources().getDisplayMetrics().density + 0.5f);
    }

    private int getAvailableScreenWidth() {
        return getResources().getDisplayMetrics().widthPixels;
    }

    private int getAvailableScreenHeight() {
        return getResources().getDisplayMetrics().heightPixels;
    }

    private boolean isShortScreen() {
        return getAvailableScreenHeight() < dp(600);
    }

    private int getPanelWidth() {
        // Keep the panel compact on narrow displays while leaving enough room for row actions.
        int widthLimit = Math.min(dp(216), getAvailableScreenWidth() - dp(16));
        int proportionalWidth = (int) (getAvailableScreenWidth() * 0.62f);
        return Math.max(dp(184), Math.min(widthLimit, proportionalWidth));
    }

    private int getCallListHeight() {
        final int screenHeight = getAvailableScreenHeight();
        final float ratio = panelExpanded ? 0.19f : 0.12f;
        final int minHeight = dp(panelExpanded ? 96 : 70);
        final int maxHeight = dp(panelExpanded ? 112 : 76);
        return Math.max(minHeight, Math.min(maxHeight, (int) (screenHeight * ratio)));
    }

    private int getPaymentQueueHeight() {
        int screenBasedHeight = (int) (getAvailableScreenHeight() * 0.25f);
        return Math.max(dp(88), Math.min(dp(148), screenBasedHeight));
    }

    private int getOverlayCallCount() {
        if (bubbleMode) return 0;
        int requested = getDisplayCallCount();
        if (!panelExpanded || isShortScreen()) return Math.min(2, requested);
        // The panel stays visually small; additional configured rows scroll inside it.
        return requested;
    }

    /**
     * Đọc CallLog trên Background Thread và cập nhật danh sách động trên UI.
     * View recycling: tái sử dụng view cũ thay vì removeAllViews + re-inflate.
     */
    private void onNewCallDetected() {
        if (floatingView == null || bubbleMode) return;
        final int targetCount = getOverlayCallCount();

        backgroundExecutor.execute(() -> {
            try {
                if (ContextCompat.checkSelfPermission(this, Manifest.permission.READ_CALL_LOG) != PackageManager.PERMISSION_GRANTED) {
                    return;
                }

                ContentResolver resolver = getContentResolver();
                Uri callLogUri = CallLog.Calls.CONTENT_URI;
                String[] projection = {
                    CallLog.Calls._ID,
                    CallLog.Calls.NUMBER,
                    CallLog.Calls.CACHED_NAME,
                    CallLog.Calls.DURATION,
                    CallLog.Calls.DATE,
                    CallLog.Calls.TYPE
                };
                // Tuyệt đối không dùng LIMIT trong sortOrder vì SQLite / ContentProvider Android chặn cú pháp LIMIT trong ORDER BY
                String sortOrder = CallLog.Calls.DATE + " DESC";

                Cursor cursor = resolver.query(callLogUri, projection, null, null, sortOrder);
                final List<CallItemData> loadedCalls = new ArrayList<>();

                if (cursor != null) {
                    final int colId = cursor.getColumnIndex(CallLog.Calls._ID);
                    final int colNumber = cursor.getColumnIndex(CallLog.Calls.NUMBER);
                    final int colName = cursor.getColumnIndex(CallLog.Calls.CACHED_NAME);

                    while (cursor.moveToNext() && loadedCalls.size() < targetCount) {
                        int id = colId != -1 ? cursor.getInt(colId) : -1;
                        String rawPhone = colNumber != -1 ? cursor.getString(colNumber) : "";
                        String name = colName != -1 ? cursor.getString(colName) : null;
                        String displayText = (name != null && !name.isEmpty()) ? name + " (" + rawPhone + ")" : rawPhone;

                        loadedCalls.add(new CallItemData(id, rawPhone, displayText));
                    }
                    cursor.close();
                }

                mainHandler.post(() -> updateCallsUi(loadedCalls, targetCount));
            } catch (Exception e) {
                Log.e(TAG, "Lỗi khi xử lý cuộc gọi mới: ", e);
            }
        });
    }

    private static class CallItemData {
        final int id;
        final String rawPhone;
        final String displayText;

        CallItemData(int id, String rawPhone, String displayText) {
            this.id = id;
            this.rawPhone = rawPhone;
            this.displayText = displayText;
        }
    }

    /**
     * View Recycling: tái sử dụng view có sẵn thay vì xóa hết rồi inflate lại.
     * Giảm ~70% GC pressure và giảm thời gian render.
     */
    private void updateCallsUi(List<CallItemData> loadedCalls, int targetCount) {
        if (floatingView == null || bubbleMode || callsContainer == null || paymentQueueMode) return;

        if (callsScrollView != null) {
            callsScrollView.getLayoutParams().height = getCallListHeight();
            callsScrollView.requestLayout();
        }

        if (batchUpdateButton != null) {
            batchUpdateButton.setText("⚡");
        }

        final int newCount = loadedCalls.size();
        final int oldCount = currentCallHolders.size();

        // Bước 1: Xóa view thừa nếu danh sách mới ngắn hơn
        while (currentCallHolders.size() > newCount) {
            int lastIdx = currentCallHolders.size() - 1;
            callsContainer.removeViewAt(lastIdx);
            currentCallHolders.remove(lastIdx);
        }

        // Bước 2: Cập nhật dữ liệu cho các view có sẵn (tái sử dụng - không inflate mới)
        for (int i = 0; i < Math.min(oldCount, newCount); i++) {
            final int index = i;
            CallItemData data = loadedCalls.get(i);
            CallItemHolder holder = currentCallHolders.get(i);

            holder.callId = data.id;
            holder.rawPhone = data.rawPhone;
            holder.displayText = data.displayText;
            holder.phoneView.setText(data.displayText != null ? data.displayText : "...");
            holder.phoneView.setTextColor(0xFF90CAF9);
            holder.phoneView.setContentDescription("Chạm để mở Zalo theo số " + data.rawPhone);
            holder.phoneView.setOnClickListener(v -> openZalo(holder.rawPhone));
            holder.durationView.setVisibility(View.GONE);
            holder.updateButton.setOnClickListener(v -> updateSingleCallDuration(index));
            holder.smsButton.setOnClickListener(v -> showSmsInput(index));
        }

        // Bước 3: Inflate thêm view mới nếu danh sách mới dài hơn
        for (int i = oldCount; i < newCount; i++) {
            final int index = i;
            CallItemData data = loadedCalls.get(i);

            View itemView = getInflater().inflate(R.layout.floating_call_item, callsContainer, false);
            TextView phoneView = itemView.findViewById(R.id.item_phone_number);
            TextView durationView = itemView.findViewById(R.id.item_duration);
            Button smsButton = itemView.findViewById(R.id.item_sms_button);
            Button updateButton = itemView.findViewById(R.id.item_update_button);

            phoneView.setText(data.displayText != null ? data.displayText : "...");
            phoneView.setTextColor(0xFF90CAF9);
            durationView.setVisibility(View.GONE);

            CallItemHolder holder = new CallItemHolder();
            holder.callId = data.id;
            holder.rawPhone = data.rawPhone;
            holder.displayText = data.displayText;
            holder.itemView = itemView;
            holder.phoneView = phoneView;
            holder.durationView = durationView;
            holder.smsButton = smsButton;
            holder.updateButton = updateButton;

            phoneView.setContentDescription("Chạm để mở Zalo theo số " + data.rawPhone);
            phoneView.setOnClickListener(v -> openZalo(holder.rawPhone));
            updateButton.setOnClickListener(v -> updateSingleCallDuration(index));
            smsButton.setOnClickListener(v -> showSmsInput(index));

            currentCallHolders.add(holder);
            callsContainer.addView(itemView);
        }
    }

    private void startForegroundServiceNotification() {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                NotificationChannel channel = new NotificationChannel(
                    CHANNEL_ID,
                    "Call Log Manager Floating Service",
                    NotificationManager.IMPORTANCE_LOW
                );
                NotificationManager manager = getSystemService(NotificationManager.class);
                if (manager != null) {
                    manager.createNotificationChannel(channel);
                }
            }

            Intent launchIntent = getPackageManager().getLaunchIntentForPackage(getPackageName());
            android.app.PendingIntent pendingIntent = null;
            if (launchIntent != null) {
                launchIntent.addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP);
                int flags = android.app.PendingIntent.FLAG_UPDATE_CURRENT;
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    flags |= android.app.PendingIntent.FLAG_IMMUTABLE;
                }
                pendingIntent = android.app.PendingIntent.getActivity(this, 0, launchIntent, flags);
            }

            Notification.Builder builder = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
                ? new Notification.Builder(this, CHANNEL_ID)
                : new Notification.Builder(this);

            builder.setContentTitle("APP NVPTTT")
                .setContentText("Bong bóng và dịch vụ đang chạy ngầm")
                .setSmallIcon(android.R.drawable.ic_menu_call)
                .setOngoing(true);
            if (pendingIntent != null) {
                builder.setContentIntent(pendingIntent);
            }

            Notification notification = builder.build();
            startForeground(NOTIFICATION_ID, notification);
        } catch (Exception e) {
            Log.e(TAG, "Error starting foreground service notification", e);
        }
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        startForegroundServiceNotification();
        if (intent != null) {
            String action = intent.getStringExtra("action");

            if ("show".equals(action)) {
                _saveFloatingWindowState(true);
                showFloatingBubble();
            } else if ("hide".equals(action)) {
                _saveFloatingWindowState(false);
                hideFloatingWindow(true);
            } else if ("refresh_count".equals(action)) {
                if (floatingView != null && !bubbleMode) {
                    onNewCallDetected();
                }
            }
        } else {
            // Intent null: Service được Android tự khởi động lại sau khi bị kill (START_STICKY)
            if (getPrefs().getBoolean("is_showing", false) && floatingView == null) {
                mainHandler.post(this::showFloatingBubble);
            }
        }
        return START_STICKY;
    }

    @Override
    public void onTaskRemoved(Intent rootIntent) {
        super.onTaskRemoved(rootIntent);
        // Khi người dùng vuốt đóng app trong màn hình đa nhiệm (Recent apps),
        // giữ cho foreground service và bong bóng tiếp tục sống nếu đang bật
        if (getPrefs().getBoolean("is_showing", false)) {
            startForegroundServiceNotification();
            if (floatingView == null) {
                mainHandler.post(this::showFloatingBubble);
            }
        }
    }

    private boolean canDrawOverlay() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            if (!Settings.canDrawOverlays(this)) {
                Log.e(TAG, "SYSTEM_ALERT_WINDOW permission not granted");
                return false;
            }
        }
        return true;
    }

    private void ensureWindowParams(int width, int height) {
        if (windowManager == null) {
            windowManager = (WindowManager) getSystemService(WINDOW_SERVICE);
        }
        if (windowParams != null) {
            windowParams.width = width;
            windowParams.height = height;
            return;
        }

        windowParams = new WindowManager.LayoutParams(
            width,
            height,
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
                ? WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
                : WindowManager.LayoutParams.TYPE_PHONE,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE,
            PixelFormat.TRANSLUCENT
        );

        windowParams.gravity = Gravity.TOP | Gravity.START;
        SharedPreferences prefs = getPrefs();
        windowParams.x = prefs.getInt("floating_x", dp(12));
        windowParams.y = prefs.getInt("floating_y", dp(100));
    }

    private void replaceFloatingView(int layoutRes, int width, int height) {
        ensureWindowParams(width, height);
        if (floatingView != null) {
            try {
                windowManager.removeViewImmediate(floatingView);
            } catch (Exception ignored) {
            }
        }
        floatingView = getInflater().inflate(layoutRes, null);
        windowParams.width = width;
        windowParams.height = height;
        // A bubble snapped to the right edge must not leave the larger panel off-screen.
        windowParams.x = Math.max(0, Math.min(windowParams.x, Math.max(0, getAvailableScreenWidth() - width)));
        windowParams.y = Math.max(0, Math.min(windowParams.y, Math.max(0, getAvailableScreenHeight() - dp(56))));
        windowManager.addView(floatingView, windowParams);
        floatingView.post(this::keepOverlayOnScreen);
        isFloatingWindowShowing = true;
        _saveFloatingWindowState(true);
    }

    private void keepOverlayOnScreen() {
        if (floatingView == null || windowManager == null || windowParams == null) return;
        int viewWidth = floatingView.getWidth();
        int viewHeight = floatingView.getHeight();
        if (viewWidth <= 0 || viewHeight <= 0) return;

        int x = Math.max(0, Math.min(windowParams.x, Math.max(0, getAvailableScreenWidth() - viewWidth)));
        int y = Math.max(0, Math.min(windowParams.y, Math.max(0, getAvailableScreenHeight() - viewHeight)));
        if (x == windowParams.x && y == windowParams.y) return;
        windowParams.x = x;
        windowParams.y = y;
        try {
            windowManager.updateViewLayout(floatingView, windowParams);
        } catch (Exception ignored) {
        }
    }

    private void showFloatingBubble() {
        if (!canDrawOverlay()) return;
        if (floatingView != null && bubbleMode) return;

        bubbleMode = true;
        panelExpanded = false;
        paymentQueueMode = false;
        unregisterCallLogObserver();
        mainHandler.removeCallbacks(debouncedCallRefresh);
        callsContainer = null;
        callsScrollView = null;
        paymentQueueFilter = null;
        paymentTrackingButton = null;
        paymentPendingTab = null;
        paymentReceivedTab = null;
        currentCallHolders.clear();

        try {
            replaceFloatingView(R.layout.floating_bubble, dp(56), dp(56));
            floatingView.setOnClickListener(v -> showFloatingPanel(false));
            floatingView.setOnTouchListener(new FloatingTouchListener(windowManager, floatingView, this, true));
        } catch (Exception e) {
            Log.e(TAG, "Error showing floating bubble", e);
            Toast.makeText(this, "Cannot show floating bubble", Toast.LENGTH_SHORT).show();
        }
    }

    private void showFloatingPanel(boolean expanded) {
        if (!canDrawOverlay()) return;

        bubbleMode = false;
        panelExpanded = expanded && !isShortScreen();
        currentCallHolders.clear();
        try {
            replaceFloatingView(R.layout.floating_window, getPanelWidth(), WindowManager.LayoutParams.WRAP_CONTENT);
        } catch (Exception e) {
            Log.e(TAG, "Error showing floating panel", e);
            Toast.makeText(this, "Cannot show floating panel", Toast.LENGTH_SHORT).show();
            return;
        }

        floatingContainer = floatingView.findViewById(R.id.floating_container);
        callsContainer = floatingView.findViewById(R.id.calls_container);
        callsScrollView = floatingView.findViewById(R.id.calls_scroll_view);
        paymentQueueFilter = floatingView.findViewById(R.id.payment_queue_filter);
        paymentPendingTab = floatingView.findViewById(R.id.payment_pending_tab);
        paymentReceivedTab = floatingView.findViewById(R.id.payment_received_tab);
        batchUpdateButton = floatingView.findViewById(R.id.batch_update_button);
        paymentTrackingButton = floatingView.findViewById(R.id.payment_tracking_button);

        if (paymentPendingTab != null) {
            paymentPendingTab.setOnClickListener(v -> {
                paymentQueueShowingReceived = false;
                renderPaymentQueue();
            });
        }
        if (paymentReceivedTab != null) {
            paymentReceivedTab.setOnClickListener(v -> {
                paymentQueueShowingReceived = true;
                renderPaymentQueue();
            });
        }
        if (paymentQueueFilter != null && !paymentQueueMode) {
            paymentQueueFilter.setVisibility(View.GONE);
        }

        // SMS controls
        smsInputContainer = floatingView.findViewById(R.id.sms_input_container);
        amountInput = floatingView.findViewById(R.id.amount_input);
        sendSmsButton = floatingView.findViewById(R.id.send_sms_button);
        cancelSmsButton = floatingView.findViewById(R.id.cancel_sms_button);

        // Cập nhật text nút Batch Update
        if (batchUpdateButton != null) {
            batchUpdateButton.setText("⚡");
            batchUpdateButton.setContentDescription("Cập nhật các cuộc gọi đang hiển thị");
            batchUpdateButton.setOnClickListener(v -> updateAllCurrentCalls());
        }

        updatePaymentTrackingButton();
        if (paymentTrackingButton != null) {
            paymentTrackingButton.setOnClickListener(v -> {
                if (paymentQueueMode) {
                    showCallListInPanel();
                } else {
                    showPaymentQueue();
                }
            });
        }

        View quickTimeMarkButton = floatingView.findViewById(R.id.quick_timemark_button);
        if (quickTimeMarkButton != null) {
            quickTimeMarkButton.setOnClickListener(v -> openTimeMarkCamera());
        }

        Button togglePanelButton = floatingView.findViewById(R.id.toggle_panel_button);
        if (togglePanelButton != null) {
            togglePanelButton.setText(panelExpanded ? "⌃" : "⌄");
            togglePanelButton.setOnClickListener(v -> showFloatingPanel(!panelExpanded));
        }

        // SMS action buttons
        if (sendSmsButton != null) sendSmsButton.setOnClickListener(v -> sendSms());
        if (cancelSmsButton != null) cancelSmsButton.setOnClickListener(v -> hideSmsInput());

        Button closeButton = floatingView.findViewById(R.id.close_button);
        if (closeButton != null) {
            closeButton.setText("−");
            closeButton.setContentDescription("Thu gọn thành bong bóng");
            closeButton.setOnClickListener(v -> showFloatingBubble());
        }

        View dragHandle = floatingView.findViewById(R.id.header_drag_handle);
        if (dragHandle != null) {
            dragHandle.setOnTouchListener(new FloatingTouchListener(windowManager, floatingView, this));
        }

        registerCallLogObserver();
        if (paymentQueueMode) {
            renderPaymentQueue();
        } else {
            onNewCallDetected();
        }
    }

    private void updatePaymentTrackingButton() {
        if (paymentTrackingButton == null) return;
        if (paymentQueueMode) {
            paymentTrackingButton.setText("↩");
            paymentTrackingButton.setContentDescription("Quay lại danh sách cuộc gọi");
        } else {
            paymentTrackingButton.setText("₫");
            paymentTrackingButton.setContentDescription("Mở danh sách khoản chuyển khoản đang chờ");
        }
    }

    private void showPaymentQueue() {
        if (floatingView == null || bubbleMode || callsContainer == null) return;
        unregisterCallLogObserver();
        mainHandler.removeCallbacks(debouncedCallRefresh);
        paymentQueueMode = true;
        paymentQueueShowingReceived = false;
        currentCallHolders.clear();
        callsContainer.removeAllViews();
        if (paymentQueueFilter != null) paymentQueueFilter.setVisibility(View.VISIBLE);
        if (callsScrollView != null) {
            callsScrollView.getLayoutParams().height = getPaymentQueueHeight();
            callsScrollView.setVisibility(View.VISIBLE);
            callsScrollView.requestLayout();
        }
        if (smsInputContainer != null) smsInputContainer.setVisibility(View.GONE);
        updatePaymentTrackingButton();
        renderPaymentQueue();
    }

    private void showCallListInPanel() {
        if (floatingView == null || bubbleMode || callsContainer == null) return;
        paymentQueueMode = false;
        paymentQueueShowingReceived = false;
        if (paymentQueueFilter != null) paymentQueueFilter.setVisibility(View.GONE);
        registerCallLogObserver();
        currentCallHolders.clear();
        callsContainer.removeAllViews();
        updatePaymentTrackingButton();
        onNewCallDetected();
    }

    private void renderPaymentQueue() {
        if (floatingView == null || bubbleMode || !paymentQueueMode || callsContainer == null) return;
        currentCallHolders.clear();
        callsContainer.removeAllViews();
        if (callsScrollView != null) {
            callsScrollView.getLayoutParams().height = getPaymentQueueHeight();
            callsScrollView.requestLayout();
        }
        if (paymentQueueFilter != null) paymentQueueFilter.setVisibility(View.VISIBLE);

        JSONArray records = PaymentTrackingStore.getRecords(this);
        int pendingCount = 0;
        int receivedCount = 0;
        for (int index = records.length() - 1; index >= 0; index--) {
            JSONObject record = records.optJSONObject(index);
            if (record == null) continue;
            String smsStatus = record.optString("smsStatus");
            if (!"sent".equals(smsStatus) && !"simulated".equals(smsStatus)) continue;

            boolean received = "received".equals(record.optString("status"));
            if (received) receivedCount++;
            else pendingCount++;

            if (received == paymentQueueShowingReceived) {
                addPaymentQueueRow(record, received);
            }
        }

        updatePaymentQueueTabs(pendingCount, receivedCount);

        int visibleCount = paymentQueueShowingReceived ? receivedCount : pendingCount;
        if (visibleCount == 0) {
            TextView emptyView = new TextView(this);
            emptyView.setText(paymentQueueShowingReceived
                ? "Chưa có khoản đã nhận"
                : "Không có khoản chờ chuyển khoản");
            emptyView.setTextColor(0xFF666666);
            emptyView.setTextSize(11);
            emptyView.setGravity(Gravity.CENTER);
            emptyView.setPadding(dp(6), dp(8), dp(6), dp(8));
            callsContainer.addView(emptyView, new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
            ));
        }
        if (callsScrollView != null) callsScrollView.scrollTo(0, 0);
        floatingView.post(this::keepOverlayOnScreen);
    }

    private void updatePaymentQueueTabs(int pendingCount, int receivedCount) {
        if (paymentPendingTab != null) {
            paymentPendingTab.setText("Chờ (" + pendingCount + ")");
            stylePaymentQueueTab(paymentPendingTab, !paymentQueueShowingReceived);
        }
        if (paymentReceivedTab != null) {
            paymentReceivedTab.setText("Đã nhận (" + receivedCount + ")");
            stylePaymentQueueTab(paymentReceivedTab, paymentQueueShowingReceived);
        }
    }

    private void stylePaymentQueueTab(TextView tab, boolean selected) {
        tab.setBackgroundColor(selected ? 0xFF1565C0 : 0xFFE8E8E8);
        tab.setTextColor(selected ? 0xFFFFFFFF : 0xFF444444);
        tab.setContentDescription((selected ? "Đang xem " : "Mở danh sách ")
            + tab.getText().toString());
    }

    private void addPaymentQueueRow(JSONObject record, boolean received) {
        String id = record.optString("id", "");
        String phone = record.optString("phone", "");
        String digits = phone.replaceAll("\\D", "");
        String lastFour = digits.length() > 4 ? digits.substring(digits.length() - 4) : digits;
        String orderCode = record.optString("orderCode", "").trim();
        String amount = record.optString("amount", "").trim();
        boolean customerReplied = record.optBoolean("customerReplied", false);
        boolean simulated = "simulated".equals(record.optString("smsStatus"));

        LinearLayout row = new LinearLayout(this);
        row.setOrientation(LinearLayout.VERTICAL);
        row.setPadding(dp(6), dp(4), dp(6), dp(4));

        TextView orderView = new TextView(this);
        orderView.setText((simulated ? "SMS ảo · " : (customerReplied ? "✉ Có phản hồi · " : ""))
            + (orderCode.isEmpty() ? "Chưa quét mã đơn" : "Đơn " + orderCode));
        orderView.setTextColor(0xFF222222);
        orderView.setTextSize(12);
        orderView.setSingleLine(true);
        orderView.setEllipsize(android.text.TextUtils.TruncateAt.END);
        if (!orderCode.isEmpty()) {
            orderView.setTextColor(0xFF1565C0);
            orderView.setPaintFlags(
                orderView.getPaintFlags() | android.graphics.Paint.UNDERLINE_TEXT_FLAG
            );
            orderView.setContentDescription("Sao chép mã vận đơn " + orderCode
                + ". Nhấn giữ để mở ứng dụng GHN.");
            orderView.setOnClickListener(v -> copyOrderCode(orderCode));
            orderView.setOnLongClickListener(v -> {
                openGhnTracking(orderCode);
                return true;
            });
        }

        LinearLayout actionRow = new LinearLayout(this);
        actionRow.setOrientation(LinearLayout.HORIZONTAL);
        actionRow.setGravity(Gravity.CENTER_VERTICAL);

        TextView detailsView = new TextView(this);
        String details = (lastFour.isEmpty() ? "Không rõ SĐT" : "••" + lastFour)
            + (amount.isEmpty() ? "" : "  ·  " + amount + "đ");
        detailsView.setText(details);
        detailsView.setTextColor(0xFF555555);
        detailsView.setTextSize(11);
        detailsView.setSingleLine(true);
        detailsView.setEllipsize(android.text.TextUtils.TruncateAt.END);

        Button receivedButton = new Button(this);
        receivedButton.setText(received ? "↩ Chờ" : "✓ Nhận");
        receivedButton.setTextSize(10);
        receivedButton.setContentDescription(received
            ? "Chuyển khoản này về trạng thái đang chờ"
            : "Đánh dấu khoản chuyển khoản đã nhận");
        receivedButton.setMinWidth(0);
        receivedButton.setMinimumWidth(0);
        receivedButton.setMinHeight(0);
        receivedButton.setMinimumHeight(0);
        receivedButton.setPadding(dp(6), 0, dp(6), 0);
        receivedButton.setOnClickListener(v -> {
            if (PaymentTrackingStore.setReceived(FloatingWindowService.this, id, !received)) {
                PaymentTrackingEventBus.notifyRecordsChanged();
                renderPaymentQueue();
            }
        });

        actionRow.addView(detailsView, new LinearLayout.LayoutParams(0, dp(30), 1f));
        actionRow.addView(receivedButton, new LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.WRAP_CONTENT,
            dp(30)
        ));
        row.addView(orderView, new LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT,
            LinearLayout.LayoutParams.WRAP_CONTENT
        ));
        row.addView(actionRow, new LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT,
            dp(30)
        ));
        row.setBackgroundColor(received
            ? 0xFFE8F5E9
            : (simulated ? 0xFFFFF3E0 : (customerReplied ? 0xFFE3F2FD : 0xFFF4F4F4)));

        LinearLayout.LayoutParams rowParams = new LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT,
            LinearLayout.LayoutParams.WRAP_CONTENT
        );
        rowParams.setMargins(0, 0, 0, dp(3));
        callsContainer.addView(row, rowParams);
    }

    private void openGhnTracking(String orderCode) {
        if (orderCode == null || orderCode.trim().isEmpty()) return;
        try {
            GhnAppLauncher.open(this, orderCode);
        } catch (Exception e) {
            Log.e(TAG, "Could not open GHN app", e);
            Toast.makeText(this, "Không mở được ứng dụng GHN", Toast.LENGTH_SHORT).show();
        }
    }

    private boolean copyOrderCode(String orderCode) {
        ClipboardManager clipboard = (ClipboardManager) getSystemService(Context.CLIPBOARD_SERVICE);
        if (clipboard == null) {
            Toast.makeText(this, "Không sao chép được mã vận đơn.", Toast.LENGTH_SHORT).show();
            return true;
        }
        clipboard.setPrimaryClip(ClipData.newPlainText("Mã vận đơn", orderCode));
        Toast.makeText(this, "Đã sao chép mã vận đơn " + orderCode, Toast.LENGTH_SHORT).show();
        return true;
    }

    private void openTimeMarkCamera() {
        try {
            Intent intent = new Intent(this, TimeMarkCaptureActivity.class);
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_NO_ANIMATION);
            startActivity(intent);
        } catch (Exception e) {
            Log.e(TAG, "Could not open TimeMark camera", e);
            Toast.makeText(this, "Không thể mở TimeMark", Toast.LENGTH_SHORT).show();
        }
    }

    private void openZalo(String rawPhone) {
        if (rawPhone == null || rawPhone.trim().isEmpty()) {
            Toast.makeText(this, "Không có số điện thoại để mở Zalo", Toast.LENGTH_SHORT).show();
            return;
        }

        String phoneDigits = rawPhone.replaceAll("\\D", "");
        if (phoneDigits.startsWith("84") && phoneDigits.length() >= 11) {
            phoneDigits = "0" + phoneDigits.substring(2);
        }
        if (phoneDigits.isEmpty()) {
            Toast.makeText(this, "Số điện thoại không hợp lệ", Toast.LENGTH_SHORT).show();
            return;
        }

        try {
            Intent intent = new Intent(
                Intent.ACTION_VIEW,
                Uri.parse("https://zalo.me/" + Uri.encode(phoneDigits))
            );
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_NO_ANIMATION);
            startActivity(intent);
        } catch (Exception e) {
            Log.e(TAG, "Không thể mở Zalo theo số điện thoại", e);
            Toast.makeText(this, "Không mở được liên kết Zalo", Toast.LENGTH_SHORT).show();
        }
    }

    // ============== SMS Logic ==============

    private void showSmsInput(int callIndex) {
        performHapticFeedback();
        if (callIndex < 0 || callIndex >= currentCallHolders.size()) {
            Toast.makeText(this, "Không tìm thấy cuộc gọi", Toast.LENGTH_SHORT).show();
            return;
        }

        CallItemHolder holder = currentCallHolders.get(callIndex);
        pendingSmsCallIndex = callIndex;

        String targetPhone = holder.rawPhone;
        if (targetPhone == null || targetPhone.isEmpty()) {
            Toast.makeText(this, "Không có số điện thoại", Toast.LENGTH_SHORT).show();
            return;
        }

        if (smsInputContainer != null) {
            smsInputContainer.setVisibility(View.VISIBLE);
            if (callsScrollView != null) callsScrollView.setVisibility(View.GONE);
            TextView header = floatingView.findViewById(R.id.header_title);
            if (header != null) header.setText("→ " + targetPhone);
            floatingView.post(this::keepOverlayOnScreen);
        }
        if (amountInput != null) {
            amountInput.setText("");
            amountInput.requestFocus();
        }

        setWindowFocusable(true);

        mainHandler.postDelayed(() -> {
            if (amountInput != null) {
                InputMethodManager imm = (InputMethodManager) getSystemService(Context.INPUT_METHOD_SERVICE);
                if (imm != null) {
                    imm.showSoftInput(amountInput, InputMethodManager.SHOW_IMPLICIT);
                }
            }
        }, 200);
    }

    private void hideSmsInput() {
        pendingSmsCallIndex = -1;

        if (amountInput != null) {
            InputMethodManager imm = (InputMethodManager) getSystemService(Context.INPUT_METHOD_SERVICE);
            if (imm != null) {
                imm.hideSoftInputFromWindow(amountInput.getWindowToken(), 0);
            }
            amountInput.setText("");
        }

        if (smsInputContainer != null) {
            smsInputContainer.setVisibility(View.GONE);
            if (callsScrollView != null) callsScrollView.setVisibility(View.VISIBLE);
            TextView header = floatingView.findViewById(R.id.header_title);
            if (header != null) header.setText("•••");
            floatingView.post(this::keepOverlayOnScreen);
        }

        setWindowFocusable(false);
    }

    private void sendSms() {
        if (pendingSmsCallIndex < 0 || pendingSmsCallIndex >= currentCallHolders.size()) {
            Toast.makeText(this, "Chưa chọn số điện thoại", Toast.LENGTH_SHORT).show();
            return;
        }

        CallItemHolder holder = currentCallHolders.get(pendingSmsCallIndex);
        String targetPhone = holder.rawPhone;
        if (targetPhone == null || targetPhone.isEmpty()) {
            Toast.makeText(this, "Số điện thoại không hợp lệ", Toast.LENGTH_SHORT).show();
            return;
        }

        String cleanPhone = targetPhone.replaceAll("[^0-9+]", "");
        if (cleanPhone.isEmpty()) {
            cleanPhone = targetPhone;
        }

        String enteredAmount = "";
        if (amountInput != null) {
            enteredAmount = amountInput.getText().toString().trim();
        }

        if (enteredAmount.isEmpty()) {
            Toast.makeText(this, "Vui lòng nhập số tiền", Toast.LENGTH_SHORT).show();
            return;
        }

        String amount = normalizePaymentAmount(enteredAmount);
        if (amount == null) {
            Toast.makeText(this, "Số tiền không hợp lệ", Toast.LENGTH_SHORT).show();
            return;
        }

        String template = getPrefs().getString("sms_template", "19034108972011 techcombank Dang Tri Thuc. ");

        // Keep the SMS body in GSM's ASCII range; the app UI formats this value as đ.
        // A Vietnamese đ forces UCS-2 and can turn this 80+ character template into a
        // multipart SMS, which the previous single-part send path rejected.
        String message = template + amount + " VND";

        final boolean isFakeMode = getPrefs().getBoolean("sms_fake_mode", false);

        if (!isFakeMode && ContextCompat.checkSelfPermission(this, Manifest.permission.SEND_SMS) != PackageManager.PERMISSION_GRANTED) {
            Toast.makeText(this, "⚠️ Chưa cấp quyền gửi SMS. Hãy cấp quyền trong App!", Toast.LENGTH_LONG).show();
            hideSmsInput();
            return;
        }

        final String finalCleanPhone = cleanPhone;
        final String finalAmount = amount;
        if (isFakeMode) {
            try {
                Intent fakeIntent = new Intent(this, FakeSmsRoleActivity.class);
                fakeIntent.putExtra(FakeSmsRoleActivity.EXTRA_PHONE, finalCleanPhone);
                fakeIntent.putExtra(FakeSmsRoleActivity.EXTRA_AMOUNT, finalAmount);
                fakeIntent.putExtra(FakeSmsRoleActivity.EXTRA_MESSAGE, message);
                fakeIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                startActivity(fakeIntent);
            } catch (Exception error) {
                Log.e(TAG, "Cannot start fake SMS role request", error);
                Toast.makeText(this, "Không mở được bước tạo SMS ảo", Toast.LENGTH_LONG).show();
            }
            hideSmsInput();
            return;
        }

        String sessionId = PaymentTrackingStore.createSmsSession(this, finalCleanPhone, finalAmount, message);
        if (sessionId.isEmpty()) {
            Toast.makeText(this, "Không lưu được phiên nhắn tin", Toast.LENGTH_LONG).show();
            hideSmsInput();
            return;
        }
        final String finalSessionId = sessionId;

        backgroundExecutor.execute(() -> {
            try {
                SmsManager smsManager;
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    smsManager = getSystemService(SmsManager.class);
                } else {
                    smsManager = SmsManager.getDefault();
                }

                String requestId = UUID.randomUUID().toString();
                Intent sentIntent = new Intent(this, SmsSentResultReceiver.class);
                sentIntent.setAction(getPackageName() + ".SMS_SENT." + requestId);
                sentIntent.putExtra("sessionId", finalSessionId);
                PendingIntent sentPendingIntent = PendingIntent.getBroadcast(
                    this,
                    requestId.hashCode(),
                    sentIntent,
                    PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE
                );

                smsManager.sendTextMessage(finalCleanPhone, null, message, sentPendingIntent, null);

                mainHandler.post(() -> {
                    performHapticFeedback();
                    Toast.makeText(FloatingWindowService.this, "Đang gửi SMS → " + finalCleanPhone, Toast.LENGTH_SHORT).show();
                });
            } catch (Exception e) {
                PaymentTrackingStore.setSmsStatus(FloatingWindowService.this, finalSessionId, false);
                Log.e(TAG, "Lỗi gửi SMS", e);
                mainHandler.post(() -> Toast.makeText(FloatingWindowService.this, "❌ Lỗi gửi SMS: " + e.getMessage(), Toast.LENGTH_LONG).show());
            }
        });

        try {
            Intent scanIntent = new Intent(this, OrderScanCaptureActivity.class);
            scanIntent.putExtra(OrderScanCaptureActivity.EXTRA_SESSION_ID, finalSessionId);
            scanIntent.putExtra(OrderScanCaptureActivity.EXTRA_PHONE, finalCleanPhone);
            scanIntent.putExtra(OrderScanCaptureActivity.EXTRA_MESSAGE, message);
            scanIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_NO_ANIMATION);
            startActivity(scanIntent);
        } catch (Exception e) {
            Log.e(TAG, "Không thể mở màn quét mã đơn", e);
            Toast.makeText(this, "Không thể mở camera quét mã đơn", Toast.LENGTH_LONG).show();
        }

        hideSmsInput();
    }

    private String normalizePaymentAmount(String rawAmount) {
        String digits = rawAmount == null ? "" : rawAmount.replaceAll("\\D", "");
        if (digits.isEmpty()) return null;

        try {
            long amount = Long.parseLong(digits);
            if (amount <= 0) return null;
            // Short inputs are entered in thousand-dong units (for example,
            // 1923 means 1,923,000 VND). Longer values are treated as VND.
            if (amount <= 9999) amount = Math.multiplyExact(amount, 1000L);

            String rawValue = Long.toString(amount);
            StringBuilder formatted = new StringBuilder(rawValue.length() + rawValue.length() / 3);
            for (int index = 0; index < rawValue.length(); index++) {
                if (index > 0 && (rawValue.length() - index) % 3 == 0) {
                    formatted.append('.');
                }
                formatted.append(rawValue.charAt(index));
            }
            return formatted.toString();
        } catch (NumberFormatException | ArithmeticException ignored) {
            return null;
        }
    }

    private void setWindowFocusable(boolean focusable) {
        if (windowManager == null || floatingView == null || windowParams == null) return;
        try {
            if (focusable) {
                windowParams.flags &= ~WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE;
            } else {
                windowParams.flags |= WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE;
            }
            windowManager.updateViewLayout(floatingView, windowParams);
        } catch (Exception e) {
            Log.e(TAG, "Error updating window flags", e);
        }
    }

    // ============== Call Duration Logic ==============

    private void hideFloatingWindow(boolean userInitiated) {
        unregisterCallLogObserver();
        mainHandler.removeCallbacks(debouncedCallRefresh);
        if (floatingView != null && windowManager != null) {
            try {
                windowManager.removeView(floatingView);
            } catch (Exception e) {
                Log.e(TAG, "Error removing floating window", e);
            } finally {
                floatingView = null;
                isFloatingWindowShowing = false;
                if (userInitiated) {
                    _saveFloatingWindowState(false);
                }
            }
        }
        callsContainer = null;
        callsScrollView = null;
        paymentTrackingButton = null;
        paymentQueueMode = false;
        currentCallHolders.clear();
        try {
            stopForeground(STOP_FOREGROUND_REMOVE);
        } catch (Exception ignored) {
        }
        stopSelf();
    }

    private void performHapticFeedback() {
        try {
            Vibrator vibrator;
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                VibratorManager vm = (VibratorManager) getSystemService(Context.VIBRATOR_MANAGER_SERVICE);
                vibrator = vm != null ? vm.getDefaultVibrator() : null;
            } else {
                vibrator = (Vibrator) getSystemService(Context.VIBRATOR_SERVICE);
            }
            if (vibrator != null && vibrator.hasVibrator()) {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    vibrator.vibrate(VibrationEffect.createOneShot(50, VibrationEffect.DEFAULT_AMPLITUDE));
                } else {
                    vibrator.vibrate(50);
                }
            }
        } catch (Exception e) {
            Log.e(TAG, "Haptic feedback error", e);
        }
    }

    /**
     * Random thời gian trong khoảng từ 10 đến 15 giây (10, 11, 12, 13, 14, 15)
     * Sử dụng ThreadLocalRandom: lock-free, nhẹ hơn java.util.Random
     */
    private int getRandomDuration() {
        return 10 + ThreadLocalRandom.current().nextInt(6);
    }

    /**
     * Cập nhật thời gian riêng lẻ cho một cuộc gọi được chọn
     */
    private void updateSingleCallDuration(int callIndex) {
        performHapticFeedback();

        if (callIndex < 0 || callIndex >= currentCallHolders.size()) {
            Toast.makeText(this, "Không tìm thấy cuộc gọi", Toast.LENGTH_SHORT).show();
            return;
        }

        CallItemHolder holder = currentCallHolders.get(callIndex);
        int targetId = holder.callId;

        if (targetId < 0) {
            Toast.makeText(this, "Không tìm thấy cuộc gọi", Toast.LENGTH_SHORT).show();
            return;
        }

        int randomSecs = getRandomDuration();

        backgroundExecutor.execute(() -> {
            isSelfUpdating = true;
            boolean updated = updateCallLogById(targetId, randomSecs);

            mainHandler.post(() -> {
                if (updated) {
                    if (holder.durationView != null) {
                        holder.durationView.setText(randomSecs + "s ✓");
                        holder.durationView.setVisibility(View.VISIBLE);
                    }
                    Toast.makeText(FloatingWindowService.this, "⚡ " + randomSecs + "s ✓", Toast.LENGTH_SHORT).show();
                } else {
                    Toast.makeText(FloatingWindowService.this, "❌ Lỗi cập nhật", Toast.LENGTH_SHORT).show();
                }
            });

            mainHandler.postDelayed(() -> isSelfUpdating = false, 800);
        });
    }

    /**
     * Nút cập nhật nhanh: Tự động cập nhật theo đúng số lượng cuộc gọi đang hiển thị.
     * ThreadLocalRandom: lock-free, không cần synchronize.
     */
    private void updateAllCurrentCalls() {
        performHapticFeedback();

        if (currentCallHolders.isEmpty()) {
            Toast.makeText(this, "Chưa có cuộc gọi nào để cập nhật", Toast.LENGTH_SHORT).show();
            return;
        }

        final int count = currentCallHolders.size();

        // Tạo dải random 10 - 15s không trùng lặp
        List<Integer> durationPool = new ArrayList<>();
        for (int d = 10; d <= 15; d++) {
            durationPool.add(d);
        }
        Collections.shuffle(durationPool);

        // Lưu danh sách id và thời lượng tương ứng
        final List<Integer> targetIds = new ArrayList<>();
        final List<Integer> assignedDurations = new ArrayList<>();

        for (int i = 0; i < count; i++) {
            targetIds.add(currentCallHolders.get(i).callId);
            if (i < durationPool.size()) {
                assignedDurations.add(durationPool.get(i));
            } else {
                // Nếu vượt quá 6 cuộc gọi thì random trong khoảng [10, 15]
                assignedDurations.add(getRandomDuration());
            }
        }

        backgroundExecutor.execute(() -> {
            isSelfUpdating = true;
            int successCount = 0;

            for (int i = 0; i < count; i++) {
                int callId = targetIds.get(i);
                int duration = assignedDurations.get(i);
                if (callId > 0 && updateCallLogById(callId, duration)) {
                    successCount++;
                }
            }

            final int finalSuccessCount = successCount;
            mainHandler.post(() -> {
                for (int i = 0; i < count; i++) {
                    if (i < currentCallHolders.size()) {
                        CallItemHolder holder = currentCallHolders.get(i);
                        if (holder.durationView != null) {
                            holder.durationView.setText(assignedDurations.get(i) + "s ✓");
                            holder.durationView.setVisibility(View.VISIBLE);
                        }
                    }
                }
                Toast.makeText(
                    FloatingWindowService.this,
                    "⚡ Đã cập nhật " + finalSuccessCount + "/" + count + " cuộc gọi (10-15s)",
                    Toast.LENGTH_SHORT
                ).show();
            });

            mainHandler.postDelayed(() -> isSelfUpdating = false, 1200);
        });
    }

    private boolean updateCallLogById(int callLogId, int newDuration) {
        try {
            ContentResolver resolver = getContentResolver();
            Uri callLogUri = CallLog.Calls.CONTENT_URI;

            ContentValues values = new ContentValues();
            values.put(CallLog.Calls.DURATION, newDuration);
            values.put(CallLog.Calls.TYPE, CallLog.Calls.OUTGOING_TYPE);
            values.put(CallLog.Calls.DATE, System.currentTimeMillis());

            String whereClause = CallLog.Calls._ID + " = ?";
            String[] whereArgs = new String[]{String.valueOf(callLogId)};

            int rows = resolver.update(callLogUri, values, whereClause, whereArgs);
            Log.d(TAG, "Updated call ID=" + callLogId + " DURATION=" + newDuration + "s rows=" + rows);
            return rows > 0;
        } catch (Exception e) {
            Log.e(TAG, "Error updating call log by ID", e);
            return false;
        }
    }

    private void refreshCallLogs() {
        onNewCallDetected();
        Toast.makeText(this, "↻ Đã làm mới", Toast.LENGTH_SHORT).show();
    }

    private void _saveFloatingWindowState(boolean isShowing) {
        getPrefs().edit().putBoolean("is_showing", isShowing).apply();
    }

    public static boolean isFloatingWindowVisible() {
        return isFloatingWindowShowing;
    }

    static void refreshPaymentQueueIfVisible() {
        FloatingWindowService service = activeService;
        if (service == null) return;
        service.mainHandler.post(() -> {
            if (service.paymentQueueMode) service.renderPaymentQueue();
        });
    }

    @Override
    public void onDestroy() {
        if (activeService == this) activeService = null;
        super.onDestroy();
        unregisterCallLogObserver();
        mainHandler.removeCallbacksAndMessages(null);
        // Khi hệ thống hủy service (do RAM yếu hoặc restart), chỉ tháo view để tránh leak,
        // KHÔNG xóa cờ is_showing để khi khởi động lại có thể tự động khôi phục popup!
        if (floatingView != null && windowManager != null) {
            try {
                windowManager.removeView(floatingView);
            } catch (Exception ignored) {
            }
            floatingView = null;
            isFloatingWindowShowing = false;
        }
        callsContainer = null;
        callsScrollView = null;
        paymentTrackingButton = null;
        paymentQueueMode = false;
        currentCallHolders.clear();
        if (!backgroundExecutor.isShutdown()) {
            backgroundExecutor.shutdownNow();
        }
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }
}
