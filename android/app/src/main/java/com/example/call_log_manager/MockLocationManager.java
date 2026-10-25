package com.example.call_log_manager;

import android.app.AppOpsManager;
import android.content.Context;
import android.content.Intent;
import android.location.Criteria;
import android.location.Location;
import android.location.LocationManager;
import android.os.Build;
import android.os.Process;
import android.os.SystemClock;
import android.provider.Settings;
import android.util.Log;

import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.ScheduledFuture;
import java.util.concurrent.TimeUnit;

public class MockLocationManager {
    private static final String TAG = "MockLocationManager";
    private static MockLocationManager instance;

    private final Context context;
    private final LocationManager locationManager;
    private ScheduledExecutorService scheduler;
    private ScheduledFuture<?> mockTask;

    private boolean isRunning = false;
    private double currentLatitude = 0.0;
    private double currentLongitude = 0.0;

    private static final String[] PROVIDERS = {
        LocationManager.GPS_PROVIDER,
        LocationManager.NETWORK_PROVIDER
    };

    private MockLocationManager(Context context) {
        this.context = context.getApplicationContext();
        this.locationManager = (LocationManager) this.context.getSystemService(Context.LOCATION_SERVICE);
        android.content.SharedPreferences prefs = this.context.getSharedPreferences("fake_gps_state", Context.MODE_PRIVATE);
        this.currentLatitude = prefs.getFloat("latitude", 0.0f);
        this.currentLongitude = prefs.getFloat("longitude", 0.0f);
    }

    public static synchronized MockLocationManager getInstance(Context context) {
        if (instance == null) {
            instance = new MockLocationManager(context);
        }
        return instance;
    }

    public boolean isMockLocationEnabled() {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                AppOpsManager opsManager = (AppOpsManager) context.getSystemService(Context.APP_OPS_SERVICE);
                if (opsManager != null) {
                    int mode = opsManager.checkOpNoThrow(
                        AppOpsManager.OPSTR_MOCK_LOCATION,
                        Process.myUid(),
                        context.getPackageName()
                    );
                    return mode == AppOpsManager.MODE_ALLOWED;
                }
            } else {
                return !Settings.Secure.getString(context.getContentResolver(), Settings.Secure.ALLOW_MOCK_LOCATION).equals("0");
            }
        } catch (Exception e) {
            Log.e(TAG, "Error checking mock location permission", e);
        }
        return false;
    }

    public void openDeveloperSettings() {
        try {
            Intent intent = new Intent(Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS);
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            context.startActivity(intent);
        } catch (Exception e) {
            Log.e(TAG, "Error opening developer settings", e);
            try {
                Intent fallback = new Intent(Settings.ACTION_SETTINGS);
                fallback.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                context.startActivity(fallback);
            } catch (Exception ignored) {}
        }
    }

    public synchronized boolean startMockLocation(double latitude, double longitude) {
        this.currentLatitude = latitude;
        this.currentLongitude = longitude;

        if (isRunning) {
            // Already running, target coordinates updated
            pushLocationUpdate();
            return true;
        }

        if (locationManager == null) {
            Log.e(TAG, "LocationManager is null");
            return false;
        }

        try {
            initTestProviders();
        } catch (SecurityException se) {
            Log.e(TAG, "SecurityException: App is not selected as mock location app", se);
            return false;
        } catch (Exception e) {
            Log.e(TAG, "Error initializing test providers", e);
            return false;
        }

        if (scheduler == null || scheduler.isShutdown()) {
            scheduler = Executors.newSingleThreadScheduledExecutor();
        }

        // Push location once immediately
        pushLocationUpdate();

        // A three-second cadence keeps mock providers fresh without the constant wakeups
        // that were expensive on older and low-RAM devices.
        mockTask = scheduler.scheduleWithFixedDelay(this::pushLocationUpdate, 3000, 3000, TimeUnit.MILLISECONDS);
        isRunning = true;
        context.getSharedPreferences("fake_gps_state", Context.MODE_PRIVATE)
            .edit()
            .putBoolean("is_running", true)
            .putFloat("latitude", (float) latitude)
            .putFloat("longitude", (float) longitude)
            .apply();
        Log.i(TAG, "Fake GPS started at (" + latitude + ", " + longitude + ")");
        return true;
    }

    public synchronized boolean stopMockLocation() {
        if (!isRunning) return true;

        if (mockTask != null) {
            mockTask.cancel(true);
            mockTask = null;
        }

        if (scheduler != null && !scheduler.isShutdown()) {
            scheduler.shutdownNow();
            scheduler = null;
        }

        removeTestProviders();
        isRunning = false;
        context.getSharedPreferences("fake_gps_state", Context.MODE_PRIVATE)
            .edit()
            .putBoolean("is_running", false)
            .apply();
        Log.i(TAG, "Fake GPS stopped");
        return true;
    }

    public boolean isRunning() {
        return isRunning;
    }

    public double getCurrentLatitude() {
        return currentLatitude;
    }

    public double getCurrentLongitude() {
        return currentLongitude;
    }

    private void initTestProviders() {
        for (String provider : PROVIDERS) {
            try {
                locationManager.addTestProvider(
                    provider,
                    false, // requiresNetwork
                    provider.equals(LocationManager.GPS_PROVIDER), // requiresSatellite
                    provider.equals(LocationManager.NETWORK_PROVIDER), // requiresCell
                    false, // hasMonetaryCost
                    true,  // supportsAltitude
                    true,  // supportsSpeed
                    true,  // supportsBearing
                    Criteria.POWER_LOW,
                    Criteria.ACCURACY_FINE
                );
                locationManager.setTestProviderEnabled(provider, true);
            } catch (IllegalArgumentException iae) {
                // Provider may already exist, ignore
            }
        }
    }

    private void removeTestProviders() {
        for (String provider : PROVIDERS) {
            try {
                locationManager.setTestProviderEnabled(provider, false);
                locationManager.removeTestProvider(provider);
            } catch (Exception ignored) {
            }
        }
    }

    // Tái sử dụng Location objects - tránh tạo mới 2 object mỗi 3 giây (tiết kiệm ~8640 alloc/ngày)
    private final Location[] reusableLocations = {
        new Location(LocationManager.GPS_PROVIDER),
        new Location(LocationManager.NETWORK_PROVIDER)
    };

    private void pushLocationUpdate() {
        if (locationManager == null) return;

        long now = System.currentTimeMillis();
        long elapsedNanos = SystemClock.elapsedRealtimeNanos();

        for (int i = 0; i < PROVIDERS.length; i++) {
            try {
                Location mockLoc = reusableLocations[i];
                mockLoc.setLatitude(currentLatitude);
                mockLoc.setLongitude(currentLongitude);
                mockLoc.setAltitude(15.0);
                mockLoc.setTime(now);
                mockLoc.setAccuracy(2.5f);
                mockLoc.setBearing(0.0f);
                mockLoc.setSpeed(0.0f);

                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.JELLY_BEAN_MR1) {
                    mockLoc.setElapsedRealtimeNanos(elapsedNanos);
                }
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    mockLoc.setBearingAccuracyDegrees(0.1f);
                    mockLoc.setVerticalAccuracyMeters(0.1f);
                    mockLoc.setSpeedAccuracyMetersPerSecond(0.01f);
                }

                locationManager.setTestProviderLocation(PROVIDERS[i], mockLoc);
            } catch (Exception e) {
                Log.w(TAG, "Failed to push mock location for provider: " + PROVIDERS[i], e);
            }
        }
    }
}
