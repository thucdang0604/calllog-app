package com.example.call_log_manager;

import android.os.Build;
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
                if (isDragging) {
                    snapToEdges();
                    isDragging = false;
                } else if (triggerClickOnTap) {
                    floatingView.performClick();
                }
                return true;
        }
        return true;
    }

    private void snapToEdges() {
        try {
            WindowManager.LayoutParams params = (WindowManager.LayoutParams) floatingView.getLayoutParams();
            if (params == null) return;

            int screenWidth = getScreenWidth();
            int viewWidth = floatingView.getWidth();
            if (viewWidth <= 0) viewWidth = 200; // Fallback nếu view chưa đo xong

            if (params.x + (viewWidth / 2) < screenWidth / 2) {
                params.x = 0;
            } else {
                params.x = Math.max(0, screenWidth - viewWidth);
            }

            int viewHeight = floatingView.getHeight();
            if (viewHeight <= 0) viewHeight = 56;
            params.y = Math.max(0, Math.min(params.y, Math.max(0, getScreenHeight() - viewHeight)));

            windowManager.updateViewLayout(floatingView, params);
            context.getSharedPreferences("floating_window_state", Context.MODE_PRIVATE)
                .edit()
                .putInt("floating_x", params.x)
                .putInt("floating_y", params.y)
                .apply();
        } catch (Exception ignored) {
        }
    }

    private int getScreenWidth() {
        return context.getResources().getDisplayMetrics().widthPixels;
    }

    private int getScreenHeight() {
        return context.getResources().getDisplayMetrics().heightPixels;
    }
}
