package com.example.call_log_manager;

import android.Manifest;
import android.app.Activity;
import android.content.ContentResolver;
import android.content.ContentValues;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.database.Cursor;
import android.net.Uri;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.location.Location;
import android.location.LocationListener;
import android.location.LocationManager;
import android.os.Bundle;
import android.provider.MediaStore;
import android.provider.CallLog;
import android.provider.Settings;
import android.util.Log;

import org.json.JSONArray;
import org.json.JSONObject;

import androidx.core.app.ActivityCompat;
import androidx.core.content.ContextCompat;

import java.util.ArrayList;
import java.io.File;
import java.io.FileInputStream;
import java.io.OutputStream;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.embedding.engine.plugins.activity.ActivityAware;
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.EventChannel;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.MethodChannel.MethodCallHandler;
import io.flutter.plugin.common.MethodChannel.Result;
import io.flutter.plugin.common.PluginRegistry;

public class CallLogManagerPlugin implements FlutterPlugin, MethodCallHandler, ActivityAware, PluginRegistry.RequestPermissionsResultListener {
    private static final String CHANNEL = "call_log_manager";
    private static final int PERMISSION_REQUEST_CODE = 1001;
    private static final int SAVE_PAYMENT_IMAGE_PERMISSION_REQUEST_CODE = 1002;
    private static final int RECEIVE_SMS_PERMISSION_REQUEST_CODE = 1003;

    private MethodChannel channel;
    private EventChannel paymentTrackingEvents;
    private Context context;
    private Activity activity;
    private Result pendingPermissionResult;
    private Result pendingIncomingSmsPermissionResult;
    private Result pendingPaymentImagePermissionResult;
    private String pendingPaymentImageRecordId;
    private final ExecutorService backgroundExecutor = Executors.newSingleThreadExecutor();
    private final Handler mainHandler = new Handler(Looper.getMainLooper());

    @Override
    public void onAttachedToEngine(FlutterPluginBinding flutterPluginBinding) {
        channel = new MethodChannel(flutterPluginBinding.getBinaryMessenger(), CHANNEL);
        channel.setMethodCallHandler(this);
        paymentTrackingEvents = new EventChannel(
            flutterPluginBinding.getBinaryMessenger(),
            "call_log_manager/payment_tracking_events"
        );
        paymentTrackingEvents.setStreamHandler(new EventChannel.StreamHandler() {
            @Override
            public void onListen(Object arguments, EventChannel.EventSink events) {
                PaymentTrackingEventBus.setEventSink(events);
            }

            @Override
            public void onCancel(Object arguments) {
                PaymentTrackingEventBus.setEventSink(null);
            }
        });
        context = flutterPluginBinding.getApplicationContext();
    }

    @Override
    public void onAttachedToActivity(ActivityPluginBinding binding) {
        this.activity = binding.getActivity();
        binding.addRequestPermissionsResultListener(this);
    }

    @Override
    public void onDetachedFromActivityForConfigChanges() {
        this.activity = null;
    }

    @Override
    public void onReattachedToActivityForConfigChanges(ActivityPluginBinding binding) {
        this.activity = binding.getActivity();
        binding.addRequestPermissionsResultListener(this);
    }

    @Override
    public void onDetachedFromActivity() {
        this.activity = null;
    }

    @Override
    public void onMethodCall(MethodCall call, Result result) {
        switch (call.method) {
            case "hasPermission":
                hasPermission(result);
                break;
            case "requestPermission":
                requestPermission(result);
                break;
            case "getCallLogs":
                getCallLogs(call, result);
                break;
            case "showFloatingWindow":
                showFloatingWindow(call, result);
                break;
            case "hideFloatingWindow":
                hideFloatingWindow(call, result);
                break;
            case "isFloatingWindowVisible":
                isFloatingWindowVisible(call, result);
                break;
            case "openOverlaySettings":
                openOverlaySettings(call, result);
                break;
            case "getSmsTemplate":
                getSmsTemplate(result);
                break;
            case "saveSmsTemplate":
                saveSmsTemplate(call, result);
                break;
            case "getPaymentTrackingRecords":
                getPaymentTrackingRecords(result);
                break;
            case "setPaymentTrackingReceived":
                setPaymentTrackingReceived(call, result);
                break;
            case "deletePaymentTrackingRecord":
                deletePaymentTrackingRecord(call, result);
                break;
            case "clearReceivedPaymentRecords":
                result.success(PaymentTrackingStore.clearReceived(context));
                break;
            case "savePaymentTrackingImage":
                savePaymentTrackingImage(call, result);
                break;
            case "openSmsConversation":
                openSmsConversation(call, result);
                break;
            case "hasSmsPermission":
                hasSmsPermission(result);
                break;
            case "requestSmsPermission":
                requestSmsPermission(result);
                break;
            case "hasIncomingSmsPermission":
                hasIncomingSmsPermission(result);
                break;
            case "requestIncomingSmsPermission":
                requestIncomingSmsPermission(result);
                break;
            case "getDisplayCallCount":
                getDisplayCallCount(result);
                break;
            case "setDisplayCallCount":
                setDisplayCallCount(call, result);
                break;
            case "isIgnoringBatteryOptimizations":
                isIgnoringBatteryOptimizations(result);
                break;
            case "openBatteryOptimizationSettings":
                openBatteryOptimizationSettings(result);
                break;

            // Fake GPS methods
            case "isMockLocationEnabled":
                isMockLocationEnabled(result);
                break;
            case "openDeveloperSettings":
                openDeveloperSettings(result);
                break;
            case "startFakeGps":
                startFakeGps(call, result);
                break;
            case "stopFakeGps":
                stopFakeGps(result);
                break;
            case "isFakeGpsRunning":
                isFakeGpsRunning(result);
                break;
            case "getFakeGpsLocation":
                getFakeGpsLocation(result);
                break;
            case "getCurrentDeviceLocation":
                getCurrentDeviceLocation(result);
                break;
            case "saveTimeMarkImage":
                saveTimeMarkImage(call, result);
                break;
            case "consumeTimeMarkCapture":
                consumeTimeMarkCapture(result);
                break;
            case "consumeTimeMarkSource":
                consumeTimeMarkSource(result);
                break;
            case "openQuickCamera":
                openQuickCamera(result);
                break;

            case "getAutoFakeSmsIntent":
                getAutoFakeSmsIntent(result);
                break;
            case "setAutoFakeSmsIntent":
                setAutoFakeSmsIntent(call, result);
                break;

            case "getSmsLicenseDetails":
                getSmsLicenseDetails(result);
                break;
            case "activateSmsLicense":
                activateSmsLicense(call, result);
                break;
            case "applyServerLicenseToken":
                applyServerLicenseToken(call, result);
                break;
            case "getDeviceId":
                getDeviceId(result);
                break;
            case "shareText":
                shareText(call, result);
                break;

            default:
                result.notImplemented();
                break;
        }
    }

    // ================= Fake GPS Handlers =================

    private void isMockLocationEnabled(Result result) {
        boolean enabled = MockLocationManager.getInstance(context).isMockLocationEnabled();
        result.success(enabled);
    }

    private void openDeveloperSettings(Result result) {
        MockLocationManager.getInstance(context).openDeveloperSettings();
        result.success(true);
    }

    private void startFakeGps(MethodCall call, Result result) {
        Double lat = call.argument("latitude");
        Double lng = call.argument("longitude");
        if (lat == null || lng == null) {
            result.error("INVALID_ARGUMENTS", "Latitude and Longitude cannot be null", null);
            return;
        }
        boolean started = MockLocationManager.getInstance(context).startMockLocation(lat, lng);
        result.success(started);
    }

    private void stopFakeGps(Result result) {
        boolean stopped = MockLocationManager.getInstance(context).stopMockLocation();
        result.success(stopped);
    }

    private void isFakeGpsRunning(Result result) {
        boolean running = MockLocationManager.getInstance(context).isRunning();
        result.success(running);
    }

    private void getFakeGpsLocation(Result result) {
        MockLocationManager mlm = MockLocationManager.getInstance(context);
        Map<String, Object> data = new HashMap<>();
        data.put("isRunning", mlm.isRunning());
        data.put("latitude", mlm.getCurrentLatitude());
        data.put("longitude", mlm.getCurrentLongitude());
        result.success(data);
    }

    private void getCurrentDeviceLocation(Result result) {
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_FINE_LOCATION) != PackageManager.PERMISSION_GRANTED
                && ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_COARSE_LOCATION) != PackageManager.PERMISSION_GRANTED) {
            result.error("PERMISSION_DENIED", "Chưa cấp quyền định vị vị trí (Location permission)", null);
            return;
        }

        try {
            LocationManager locationManager = (LocationManager) context.getSystemService(Context.LOCATION_SERVICE);
            if (locationManager == null) {
                result.error("UNAVAILABLE", "Không tìm thấy dịch vụ định vị", null);
                return;
            }

            Location bestLocation = null;
            List<String> providers = locationManager.getProviders(true);
            for (String provider : providers) {
                try {
                    Location l = locationManager.getLastKnownLocation(provider);
                    if (l == null) continue;
                    if (bestLocation == null || l.getAccuracy() < bestLocation.getAccuracy()) {
                        bestLocation = l;
                    }
                } catch (SecurityException ignored) {}
            }

            if (bestLocation != null) {
                Map<String, Object> data = new HashMap<>();
                data.put("latitude", bestLocation.getLatitude());
                data.put("longitude", bestLocation.getLongitude());
                data.put("accuracy", (double) bestLocation.getAccuracy());
                result.success(data);
                return;
            }

            boolean isGps = locationManager.isProviderEnabled(LocationManager.GPS_PROVIDER);
            boolean isNet = locationManager.isProviderEnabled(LocationManager.NETWORK_PROVIDER);
            String targetProvider = isGps ? LocationManager.GPS_PROVIDER : (isNet ? LocationManager.NETWORK_PROVIDER : null);

            if (targetProvider == null) {
                result.error("LOCATION_DISABLED", "Dịch vụ định vị GPS trên thiết bị đang tắt", null);
                return;
            }

            final boolean[] responded = {false};
            LocationListener listener = new LocationListener() {
                @Override
                public void onLocationChanged(Location location) {
                    if (responded[0]) return;
                    responded[0] = true;
                    try {
                        locationManager.removeUpdates(this);
                    } catch (Exception ignored) {}
                    Map<String, Object> data = new HashMap<>();
                    data.put("latitude", location.getLatitude());
                    data.put("longitude", location.getLongitude());
                    data.put("accuracy", (double) location.getAccuracy());
                    mainHandler.post(() -> result.success(data));
                }
                @Override public void onStatusChanged(String provider, int status, Bundle extras) {}
                @Override public void onProviderEnabled(String provider) {}
                @Override public void onProviderDisabled(String provider) {}
            };

            locationManager.requestSingleUpdate(targetProvider, listener, Looper.getMainLooper());

            mainHandler.postDelayed(() -> {
                if (!responded[0]) {
                    responded[0] = true;
                    try {
                        locationManager.removeUpdates(listener);
                    } catch (Exception ignored) {}
                    result.error("TIMEOUT", "Không thể lấy tọa độ GPS kịp thời", null);
                }
            }, 4000);

        } catch (SecurityException se) {
            result.error("PERMISSION_DENIED", se.getMessage(), null);
        } catch (Exception e) {
            result.error("LOCATION_ERROR", e.getMessage(), null);
        }
    }

    /**
     * Copies the completed TimeMark file into the user's Pictures collection.
     * The file copy is intentionally kept off the platform channel's main thread.
     */
    private void saveTimeMarkImage(MethodCall call, Result result) {
        final String sourcePath = call.argument("sourcePath");
        if (sourcePath == null || sourcePath.isEmpty()) {
            result.error("INVALID_ARGUMENT", "sourcePath is required", null);
            return;
        }

        backgroundExecutor.execute(() -> {
            Uri outputUri = null;
            try {
                File source = new File(sourcePath);
                if (!source.isFile()) {
                    throw new IllegalArgumentException("TimeMark source image does not exist");
                }
                ContentValues values = new ContentValues();
                values.put(MediaStore.Images.Media.DISPLAY_NAME, "TimeMark_" + System.currentTimeMillis() + ".jpg");
                values.put(MediaStore.Images.Media.MIME_TYPE, "image/jpeg");
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    values.put(MediaStore.Images.Media.RELATIVE_PATH, "Pictures/TimeMark");
                    values.put(MediaStore.Images.Media.IS_PENDING, 1);
                }

                ContentResolver resolver = context.getContentResolver();
                outputUri = resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values);
                if (outputUri == null) throw new IllegalStateException("Could not create media item");
                try (FileInputStream input = new FileInputStream(source);
                     OutputStream output = resolver.openOutputStream(outputUri)) {
                    if (output == null) throw new IllegalStateException("Could not open media output");
                    byte[] buffer = new byte[32 * 1024];
                    int read;
                    while ((read = input.read(buffer)) != -1) {
                        output.write(buffer, 0, read);
                    }
                }
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    ContentValues readyValues = new ContentValues();
                    readyValues.put(MediaStore.Images.Media.IS_PENDING, 0);
                    resolver.update(outputUri, readyValues, null, null);
                }
                final String uriText = outputUri.toString();
                mainHandler.post(() -> result.success(uriText));
            } catch (Exception e) {
                if (outputUri != null) {
                    try {
                        context.getContentResolver().delete(outputUri, null, null);
                    } catch (Exception ignored) {
                    }
                }
                mainHandler.post(() -> result.error("SAVE_TIMEMARK_ERROR", e.getMessage(), null));
            }
        });
    }

    private void consumeTimeMarkCapture(Result result) {
        android.content.SharedPreferences prefs = context.getSharedPreferences("timemark_capture", Context.MODE_PRIVATE);
        boolean pending = prefs.getBoolean("pending", false);
        if (pending) prefs.edit().putBoolean("pending", false).apply();
        result.success(pending);
    }

    private void consumeTimeMarkSource(Result result) {
        android.content.SharedPreferences prefs = context.getSharedPreferences("timemark_capture", Context.MODE_PRIVATE);
        String sourcePath = prefs.getString("pending_source_path", null);
        if (sourcePath != null) prefs.edit().remove("pending_source_path").apply();
        result.success(sourcePath);
    }

    private void openQuickCamera(Result result) {
        try {
            Intent intent = new Intent(context, TimeMarkCaptureActivity.class);
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_NO_ANIMATION);
            context.startActivity(intent);
            result.success(true);
        } catch (Exception e) {
            Log.e("CallLogManager", "Error opening quick camera", e);
            result.error("CAMERA_ERROR", e.getMessage(), null);
        }
    }

    // ================= SMS & Overlay Handlers =================

    private void getSmsTemplate(Result result) {
        android.content.SharedPreferences prefs = context.getSharedPreferences("floating_window_state", Context.MODE_PRIVATE);
        String template = prefs.getString("sms_template", "19034108972011 techcombank Dang Tri Thuc. ");
        result.success(template);
    }

    private void saveSmsTemplate(MethodCall call, Result result) {
        String template = call.argument("template");
        if (template != null) {
            android.content.SharedPreferences prefs = context.getSharedPreferences("floating_window_state", Context.MODE_PRIVATE);
            prefs.edit().putString("sms_template", template).apply();
            result.success(true);
        } else {
            result.success(false);
        }
    }

    private void getPaymentTrackingRecords(Result result) {
        JSONArray records = PaymentTrackingStore.getRecords(context);
        List<Map<String, Object>> output = new ArrayList<>();
        for (int index = 0; index < records.length(); index++) {
            JSONObject record = records.optJSONObject(index);
            if (record == null) continue;

            Map<String, Object> item = new HashMap<>();
            item.put("id", record.optString("id", ""));
            item.put("phone", record.optString("phone", ""));
            item.put("amount", record.optString("amount", ""));
            item.put("message", record.optString("message", ""));
            item.put("sentAt", record.optLong("sentAt", 0L));
            item.put("status", record.optString("status", "pending"));
            item.put("receivedAt", record.isNull("receivedAt") ? null : record.optLong("receivedAt", 0L));
            item.put("smsStatus", record.optString("smsStatus", ""));
            item.put("orderCode", record.optString("orderCode", ""));
            item.put("imagePath", record.optString("imagePath", ""));
            item.put("capturedAt", record.optLong("capturedAt", 0L));
            item.put("customerReplied", record.optBoolean("customerReplied", false));
            item.put("replyPhone", record.optString("replyPhone", ""));
            item.put("replyMessage", record.optString("replyMessage", ""));
            item.put("replyReceivedAt", record.optLong("replyReceivedAt", 0L));
            output.add(item);
        }
        result.success(output);
    }

    private void setPaymentTrackingReceived(MethodCall call, Result result) {
        String id = call.argument("id");
        Boolean received = call.argument("received");
        if (id == null || received == null) {
            result.error("INVALID_ARGUMENT", "Thiếu mã khoản hoặc trạng thái", null);
            return;
        }
        result.success(PaymentTrackingStore.setReceived(context, id, received));
    }

    private void deletePaymentTrackingRecord(MethodCall call, Result result) {
        String id = call.argument("id");
        if (id == null || id.isEmpty()) {
            result.error("INVALID_ARGUMENT", "Thiếu mã khoản cần xóa", null);
            return;
        }
        result.success(PaymentTrackingStore.deleteRecord(context, id));
    }

    private void openSmsConversation(MethodCall call, Result result) {
        String phone = call.argument("phone");
        if (phone == null || phone.trim().isEmpty()) {
            result.error("INVALID_ARGUMENT", "Thiếu số điện thoại khách hàng", null);
            return;
        }

        String cleanPhone = phone.replaceAll("[^0-9+]", "");
        if (cleanPhone.isEmpty()) {
            result.error("INVALID_ARGUMENT", "Số điện thoại không hợp lệ", null);
            return;
        }

        Intent intent = new Intent(
            Intent.ACTION_VIEW,
            Uri.fromParts("sms", cleanPhone, null)
        );
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        try {
            context.startActivity(intent);
            result.success(true);
        } catch (Exception e) {
            result.error("OPEN_SMS_ERROR", "Không mở được hội thoại SMS trên thiết bị", e.getMessage());
        }
    }

    private void savePaymentTrackingImage(MethodCall call, Result result) {
        String id = call.argument("id");
        if (id == null || id.isEmpty()) {
            result.error("INVALID_ARGUMENT", "Thiếu mã khoản cần lưu ảnh", null);
            return;
        }

        if (Build.VERSION.SDK_INT <= Build.VERSION_CODES.P
            && ContextCompat.checkSelfPermission(context, Manifest.permission.WRITE_EXTERNAL_STORAGE)
                != PackageManager.PERMISSION_GRANTED) {
            if (activity == null) {
                result.error("PERMISSION_DENIED", "Cần quyền lưu ảnh vào thiết bị", null);
                return;
            }
            pendingPaymentImagePermissionResult = result;
            pendingPaymentImageRecordId = id;
            ActivityCompat.requestPermissions(
                activity,
                new String[]{Manifest.permission.WRITE_EXTERNAL_STORAGE},
                SAVE_PAYMENT_IMAGE_PERMISSION_REQUEST_CODE
            );
            return;
        }

        savePaymentTrackingImageToGallery(id, result);
    }

    private void savePaymentTrackingImageToGallery(String id, Result result) {
        JSONObject record = PaymentTrackingStore.findRecord(context, id);
        if (record == null) {
            result.error("RECORD_NOT_FOUND", "Không tìm thấy khoản chuyển khoản", null);
            return;
        }
        final String sourcePath = record.optString("imagePath", "");
        if (sourcePath.isEmpty()) {
            result.error("IMAGE_NOT_FOUND", "Khoản này chưa có ảnh", null);
            return;
        }
        String orderCode = record.optString("orderCode", "");
        final String finalOrderCode = orderCode;

        backgroundExecutor.execute(() -> {
            try {
                Uri outputUri = PaymentReceiptImageExporter.save(context, sourcePath, finalOrderCode);
                final String uriText = outputUri.toString();
                mainHandler.post(() -> result.success(uriText));
            } catch (Exception e) {
                mainHandler.post(() -> result.error("SAVE_PAYMENT_IMAGE_ERROR", e.getMessage(), null));
            }
        });
    }

    private void getDisplayCallCount(Result result) {
        android.content.SharedPreferences prefs = context.getSharedPreferences("floating_window_state", Context.MODE_PRIVATE);
        int count = prefs.getInt("display_call_count", 4);
        result.success(count);
    }

    private void setDisplayCallCount(MethodCall call, Result result) {
        Integer count = call.argument("count");
        if (count != null && count >= 1 && count <= 10) {
            android.content.SharedPreferences prefs = context.getSharedPreferences("floating_window_state", Context.MODE_PRIVATE);
            prefs.edit().putInt("display_call_count", count).apply();

            // Nếu FloatingWindowService đang chạy, gửi broadcast intent để reload giao diện tức thì
            try {
                Intent intent = new Intent(context, FloatingWindowService.class);
                intent.putExtra("action", "refresh_count");
                context.startService(intent);
            } catch (Exception ignored) {}

            result.success(true);
        } else {
            result.success(false);
        }
    }

    private void getAutoFakeSmsIntent(Result result) {
        android.content.SharedPreferences prefs = context.getSharedPreferences("floating_window_state", Context.MODE_PRIVATE);
        boolean autoFake = prefs.getBoolean("sms_auto_fake_intent", false);
        result.success(autoFake);
    }

    private void setAutoFakeSmsIntent(MethodCall call, Result result) {
        Boolean enabled = call.argument("enabled");
        if (enabled != null) {
            android.content.SharedPreferences prefs = context.getSharedPreferences("floating_window_state", Context.MODE_PRIVATE);
            prefs.edit().putBoolean("sms_auto_fake_intent", enabled).apply();
            result.success(true);
        } else {
            result.success(false);
        }
    }

    private void getSmsLicenseDetails(Result result) {
        try {
            org.json.JSONObject details = LicenseManager.getLicenseDetails(context);
            result.success(details.toString());
        } catch (Exception e) {
            result.error("LICENSE_ERROR", e.getMessage(), null);
        }
    }

    private void activateSmsLicense(MethodCall call, Result result) {
        String key = call.argument("key");
        if (key != null && !key.isEmpty()) {
            boolean success = LicenseManager.activateKey(context, key);
            result.success(success);
        } else {
            result.success(false);
        }
    }

    private void applyServerLicenseToken(MethodCall call, Result result) {
        String token = call.argument("token");
        result.success(LicenseManager.saveServerLicenseToken(context, token));
    }

    private void getDeviceId(Result result) {
        result.success(LicenseManager.getDeviceId(context));
    }

    private void shareText(MethodCall call, Result result) {
        String text = call.argument("text");
        if (text == null || text.trim().isEmpty()) {
            result.error("INVALID_ARGUMENTS", "Nội dung chia sẻ đang trống.", null);
            return;
        }
        try {
            Intent shareIntent = new Intent(Intent.ACTION_SEND);
            shareIntent.setType("text/plain");
            shareIntent.putExtra(Intent.EXTRA_TEXT, text);
            Intent chooser = Intent.createChooser(shareIntent, "Gửi thông tin đơn qua Telegram");
            if (activity != null) {
                activity.startActivity(chooser);
            } else {
                chooser.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                context.startActivity(chooser);
            }
            result.success(true);
        } catch (Exception e) {
            Log.e("CallLogManagerPlugin", "Could not open text share sheet", e);
            result.error("SHARE_FAILED", "Không mở được ứng dụng chia sẻ.", null);
        }
    }

    private void hasSmsPermission(Result result) {
        boolean smsPermission = ContextCompat.checkSelfPermission(context, Manifest.permission.SEND_SMS) == PackageManager.PERMISSION_GRANTED;
        result.success(smsPermission);
    }

    private void requestSmsPermission(Result result) {
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.SEND_SMS) == PackageManager.PERMISSION_GRANTED) {
            result.success(true);
            return;
        }
        if (activity == null) {
            result.success(false);
            return;
        }
        pendingPermissionResult = result;
        ActivityCompat.requestPermissions(activity, new String[]{
            Manifest.permission.SEND_SMS
        }, PERMISSION_REQUEST_CODE);
    }

    private void hasIncomingSmsPermission(Result result) {
        boolean granted = ContextCompat.checkSelfPermission(
            context,
            Manifest.permission.RECEIVE_SMS
        ) == PackageManager.PERMISSION_GRANTED;
        result.success(granted);
    }

    private void requestIncomingSmsPermission(Result result) {
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.RECEIVE_SMS)
            == PackageManager.PERMISSION_GRANTED) {
            result.success(true);
            return;
        }
        if (activity == null) {
            result.success(false);
            return;
        }
        pendingIncomingSmsPermissionResult = result;
        ActivityCompat.requestPermissions(
            activity,
            new String[]{Manifest.permission.RECEIVE_SMS},
            RECEIVE_SMS_PERMISSION_REQUEST_CODE
        );
    }

    private void hasPermission(Result result) {
        boolean readPermission = ContextCompat.checkSelfPermission(context, Manifest.permission.READ_CALL_LOG) == PackageManager.PERMISSION_GRANTED;
        boolean writePermission = ContextCompat.checkSelfPermission(context, Manifest.permission.WRITE_CALL_LOG) == PackageManager.PERMISSION_GRANTED;
        result.success(readPermission && writePermission);
    }

    private void requestPermission(Result result) {
        boolean readPermission = ContextCompat.checkSelfPermission(context, Manifest.permission.READ_CALL_LOG) == PackageManager.PERMISSION_GRANTED;
        boolean writePermission = ContextCompat.checkSelfPermission(context, Manifest.permission.WRITE_CALL_LOG) == PackageManager.PERMISSION_GRANTED;

        if (readPermission && writePermission) {
            result.success(true);
            return;
        }

        if (activity == null) {
            result.success(false);
            return;
        }

        pendingPermissionResult = result;
        ActivityCompat.requestPermissions(activity, new String[]{
            Manifest.permission.READ_CALL_LOG,
            Manifest.permission.WRITE_CALL_LOG
        }, PERMISSION_REQUEST_CODE);
    }

    @Override
    public boolean onRequestPermissionsResult(int requestCode, String[] permissions, int[] grantResults) {
        if (requestCode == RECEIVE_SMS_PERMISSION_REQUEST_CODE) {
            boolean granted = grantResults.length > 0
                && grantResults[0] == PackageManager.PERMISSION_GRANTED;
            Result permissionResult = pendingIncomingSmsPermissionResult;
            pendingIncomingSmsPermissionResult = null;
            if (permissionResult != null) permissionResult.success(granted);
            return true;
        }
        if (requestCode == SAVE_PAYMENT_IMAGE_PERMISSION_REQUEST_CODE) {
            boolean granted = grantResults.length > 0
                && grantResults[0] == PackageManager.PERMISSION_GRANTED;
            Result saveResult = pendingPaymentImagePermissionResult;
            String recordId = pendingPaymentImageRecordId;
            pendingPaymentImagePermissionResult = null;
            pendingPaymentImageRecordId = null;
            if (saveResult != null) {
                if (granted && recordId != null) {
                    savePaymentTrackingImageToGallery(recordId, saveResult);
                } else {
                    saveResult.error("PERMISSION_DENIED", "Chưa được cấp quyền lưu ảnh", null);
                }
            }
            return true;
        }
        if (requestCode == PERMISSION_REQUEST_CODE) {
            boolean allGranted = grantResults.length > 0;
            for (int grantResult : grantResults) {
                if (grantResult != PackageManager.PERMISSION_GRANTED) {
                    allGranted = false;
                    break;
                }
            }
            if (pendingPermissionResult != null) {
                pendingPermissionResult.success(allGranted);
                pendingPermissionResult = null;
            }
            return true;
        }
        return false;
    }

    private void openOverlaySettings(MethodCall call, Result result) {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                Intent intent = new Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                        Uri.parse("package:" + context.getPackageName()));
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                context.startActivity(intent);
                result.success(true);
            } else {
                result.success(true);
            }
        } catch (Exception e) {
            Log.e("CallLogManager", "Error opening overlay settings", e);
            result.error("SETTINGS_ERROR", "Failed to open overlay settings: " + e.getMessage(), null);
        }
    }

    private void isIgnoringBatteryOptimizations(Result result) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            android.os.PowerManager pm = (android.os.PowerManager) context.getSystemService(Context.POWER_SERVICE);
            boolean isIgnoring = pm != null && pm.isIgnoringBatteryOptimizations(context.getPackageName());
            result.success(isIgnoring);
        } else {
            result.success(true);
        }
    }

    private void openBatteryOptimizationSettings(Result result) {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                Intent intent = new Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS);
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                context.startActivity(intent);
                result.success(true);
                return;
            }
            result.success(true);
        } catch (Exception e) {
            try {
                Intent intent = new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS);
                intent.setData(Uri.parse("package:" + context.getPackageName()));
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                context.startActivity(intent);
                result.success(true);
            } catch (Exception ex) {
                result.error("BATTERY_ERROR", ex.getMessage(), null);
            }
        }
    }


    /**
     * Tối ưu hiệu năng: Đọc CallLog trên Background Thread để không làm giật/đơ UI Main Thread.
     * Column indices cached trước vòng lặp, HashMap pre-sized để giảm rehash.
     */
    private void getCallLogs(MethodCall call, Result result) {
        Integer limitArg = call.argument("limit");
        final int maxCount = (limitArg != null && limitArg > 0) ? limitArg : 10;

        backgroundExecutor.execute(() -> {
            try {
                if (ContextCompat.checkSelfPermission(context, Manifest.permission.READ_CALL_LOG) != PackageManager.PERMISSION_GRANTED) {
                    mainHandler.post(() -> result.error("PERMISSION_DENIED", "Quyền READ_CALL_LOG chưa được cấp", null));
                    return;
                }

                ContentResolver resolver = context.getContentResolver();
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

                if (cursor != null) {
                    List<Map<String, Object>> callLogs = new ArrayList<>();

                    // Safe column indices lookup
                    final int colId = cursor.getColumnIndex(CallLog.Calls._ID);
                    final int colNumber = cursor.getColumnIndex(CallLog.Calls.NUMBER);
                    final int colName = cursor.getColumnIndex(CallLog.Calls.CACHED_NAME);
                    final int colDuration = cursor.getColumnIndex(CallLog.Calls.DURATION);
                    final int colDate = cursor.getColumnIndex(CallLog.Calls.DATE);
                    final int colType = cursor.getColumnIndex(CallLog.Calls.TYPE);

                    while (cursor.moveToNext() && callLogs.size() < maxCount) {
                        Map<String, Object> callLog = new HashMap<>(8);
                        callLog.put("id", colId != -1 ? cursor.getInt(colId) : 0);
                        callLog.put("number", colNumber != -1 ? cursor.getString(colNumber) : "");
                        callLog.put("name", colName != -1 ? cursor.getString(colName) : "");
                        callLog.put("duration", colDuration != -1 ? cursor.getInt(colDuration) : 0);
                        callLog.put("timestamp", colDate != -1 ? cursor.getLong(colDate) : 0L);
                        callLog.put("callType", colType != -1 ? cursor.getInt(colType) : 1);

                        callLogs.add(callLog);
                    }

                    cursor.close();
                    mainHandler.post(() -> result.success(callLogs));
                } else {
                    mainHandler.post(() -> result.error("QUERY_ERROR", "Failed to query call logs", null));
                }
            } catch (Exception e) {
                Log.e("CallLogManager", "Error getting call logs", e);
                mainHandler.post(() -> result.error("QUERY_ERROR", "Failed to get call logs: " + e.getMessage(), null));
            }
        });
    }

    private void showFloatingWindow(MethodCall call, Result result) {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                if (!Settings.canDrawOverlays(context)) {
                    result.error("PERMISSION_DENIED", "SYSTEM_ALERT_WINDOW permission not granted", null);
                    return;
                }
            }

            Intent intent = new Intent(context, FloatingWindowService.class);
            intent.putExtra("action", "show");
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent);
            } else {
                context.startService(intent);
            }
            result.success(true);
        } catch (Exception e) {
            Log.e("CallLogManager", "Error showing floating window", e);
            result.error("FLOATING_WINDOW_ERROR", "Failed to show floating window: " + e.getMessage(), null);
        }
    }

    private void hideFloatingWindow(MethodCall call, Result result) {
        try {
            Intent intent = new Intent(context, FloatingWindowService.class);
            intent.putExtra("action", "hide");
            context.startService(intent);
            result.success(true);
        } catch (Exception e) {
            Log.e("CallLogManager", "Error hiding floating window", e);
            result.error("FLOATING_WINDOW_ERROR", "Failed to hide floating window: " + e.getMessage(), null);
        }
    }

    private void isFloatingWindowVisible(MethodCall call, Result result) {
        try {
            boolean isVisible = FloatingWindowService.isFloatingWindowVisible();
            result.success(isVisible);
        } catch (Exception e) {
            Log.e("CallLogManager", "Error checking floating window visibility", e);
            result.error("FLOATING_WINDOW_ERROR", "Failed to check floating window visibility: " + e.getMessage(), null);
        }
    }

    @Override
    public void onDetachedFromEngine(FlutterPluginBinding binding) {
        channel.setMethodCallHandler(null);
        if (paymentTrackingEvents != null) paymentTrackingEvents.setStreamHandler(null);
        PaymentTrackingEventBus.setEventSink(null);
        backgroundExecutor.shutdown();
    }
}
