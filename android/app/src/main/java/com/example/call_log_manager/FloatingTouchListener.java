package com.example.call_log_manager;

import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.content.Context;
import android.util.DisplayMetrics;
import android.view.MotionEvent;
import android.view.View;
import android.view.WindowManager;
import android.view.WindowMetrics;

public class FloatingTouchListener implements View.OnTouchListener {
    private final WindowManager windowManager;
    private final View floatingView;
    private final Context context;
    private final boolean triggerClickOnTap;
    private final Handler handler = new Handler(Looper.getMainLooper());
    private Runnable snapRunnable = null;
    private int initialX, initialY;
    private float initialTouchX, initialTouchY;
    private boolean isDragging = false;
    private static final int TOUCH_SLOP = 10; // Pixels threshold to start drag

    public FloatingTouchListener(WindowManager windowManager, View floatingView, Context context) {
        this(windowManager, floatingView, context, false);
    }

    public FloatingTouchListener(WindowManager windowManager, View floatingView, Context context, boolean triggerClickOnTap) {
        this.windowManager = windowManager;
        this.floatingView = floatingView;
        this.context = context;
        this.triggerClickOnTap = triggerClickOnTap;
    }

    @Override
    public boolean onTouch(View v, MotionEvent event) {
        if (floatingView == null || windowManager == null) return false;

        switch (event.getAction()) {
            case MotionEvent.ACTION_DOWN:
                if (snapRunnable != null) {
                    handler.removeCallbacks(snapRunnable);
                    snapRunnable = null;
                }
                WindowManager.LayoutParams currentParams = (WindowManager.LayoutParams) floatingView.getLayoutParams();
                if (currentParams != null) {
                    initialX = currentParams.x;
                    initialY = currentParams.y;
                }
                initialTouchX = event.getRawX();
                initialTouchY = event.getRawY();
                isDragging = false;
                // The header is a dedicated drag handle, so it must own the
                // gesture from ACTION_DOWN through ACTION_UP.
                return true;

            case MotionEvent.ACTION_MOVE:
                float dx = event.getRawX() - initialTouchX;
                float dy = event.getRawY() - initialTouchY;

                if (!isDragging && (Math.abs(dx) > TOUCH_SLOP || Math.abs(dy) > TOUCH_SLOP)) {
                    isDragging = true;
                }

                if (isDragging) {
                    WindowManager.LayoutParams params = (WindowManager.LayoutParams) floatingView.getLayoutParams();
                    if (params != null) {
                        int targetX = initialX + (int) dx;
                        int targetY = initialY + (int) dy;
                        // Chỉ gọi IPC updateViewLayout nếu vị trí thay đổi từ 2px trở lên, giảm tải CPU binder
                        if (Math.abs(targetX - params.x) >= 2 || Math.abs(targetY - params.y) >= 2) {
                            params.x = targetX;
                            params.y = targetY;
                            try {
                                windowManager.updateViewLayout(floatingView, params);
                            } catch (Exception ignored) {}
                        }
                    }
                    return true;
                }
                return true;

            case MotionEvent.ACTION_UP:
            case MotionEvent.ACTION_CANCEL:
                if (isDragging) {
                    snapToEdges();
                    isDragging = false;
                } else if (triggerClickOnTap && event.getAction() == MotionEvent.ACTION_UP) {
                    floatingView.performClick();
                }
                return true;
        }
        return true;
    }

    private void snapToEdges() {
        try {
            if (snapRunnable != null) {
                handler.removeCallbacks(snapRunnable);
                snapRunnable = null;
            }

            WindowManager.LayoutParams params = (WindowManager.LayoutParams) floatingView.getLayoutParams();
            if (params == null) return;

            int screenWidth = getScreenWidth();
            int screenHeight = getScreenHeight();
            int viewWidth = floatingView.getWidth();
            if (viewWidth <= 0) viewWidth = dp(56);
            int viewHeight = floatingView.getHeight();
            if (viewHeight <= 0) viewHeight = dp(56);

            int padding = dp(8);
            int targetX;
            if (params.x + (viewWidth / 2) < screenWidth / 2) {
                targetX = padding;
            } else {
                targetX = Math.max(0, screenWidth - viewWidth - padding);
            }

            int targetY = Math.max(0, Math.min(params.y, Math.max(0, screenHeight - viewHeight - padding)));
            params.y = targetY;

            final int startX = params.x;
            final int diff = targetX - startX;

            if (Math.abs(diff) > 4) {
                final long startTime = SystemClock.uptimeMillis();
                final long duration = 160;

                snapRunnable = new Runnable() {
                    @Override
                    public void run() {
                        if (floatingView == null || windowManager == null || !floatingView.isAttachedToWindow()) {
                            snapRunnable = null;
                            return;
                        }
                        long elapsed = SystemClock.uptimeMillis() - startTime;
                        float t = Math.min(1.0f, (float) elapsed / duration);
                        // Decelerate: 1 - (1 - t)^2
                        float factor = 1.0f - (1.0f - t) * (1.0f - t);
                        params.x = (int) (startX + diff * factor);
                        try {
                            windowManager.updateViewLayout(floatingView, params);
                        } catch (Exception ignored) {}

                        if (t < 1.0f) {
                            handler.postDelayed(this, 16);
                        } else {
                            params.x = targetX;
                            try {
                                windowManager.updateViewLayout(floatingView, params);
                                context.getSharedPreferences("floating_window_state", Context.MODE_PRIVATE)
                                    .edit()
                                    .putInt("floating_x", targetX)
                                    .putInt("floating_y", params.y)
                                    .apply();
                            } catch (Exception ignored) {}
                            snapRunnable = null;
                        }
                    }
                };
                handler.post(snapRunnable);
            } else {
                params.x = targetX;
                windowManager.updateViewLayout(floatingView, params);
                context.getSharedPreferences("floating_window_state", Context.MODE_PRIVATE)
                    .edit()
                    .putInt("floating_x", targetX)
                    .putInt("floating_y", params.y)
                    .apply();
            }
        } catch (Exception ignored) {
        }
    }

    private int dp(int value) {
        return Math.round(value * context.getResources().getDisplayMetrics().density);
    }

    private int getScreenWidth() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && windowManager != null) {
            try {
                WindowMetrics metrics = windowManager.getCurrentWindowMetrics();
                return metrics.getBounds().width();
            } catch (Exception ignored) {}
        }
        return context.getResources().getDisplayMetrics().widthPixels;
    }

    private int getScreenHeight() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && windowManager != null) {
            try {
                WindowMetrics metrics = windowManager.getCurrentWindowMetrics();
                return metrics.getBounds().height();
            } catch (Exception ignored) {}
        }
        return context.getResources().getDisplayMetrics().heightPixels;
    }
}
