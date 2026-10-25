package com.example.call_log_manager

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugins.GeneratedPluginRegistrant
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterActivity() {
    private lateinit var eventChannel: MethodChannel

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        eventChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "call_log_manager_events")

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "call_log_manager_updates"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getAppVersion" -> {
                    try {
                        result.success(packageManager.getPackageInfo(packageName, 0).versionName)
                    } catch (error: Exception) {
                        result.error("VERSION_READ_FAILED", error.message, null)
                    }
                }
                "openUpdate" -> {
                    val rawUrl = call.argument<String>("url")
                    val uri = rawUrl?.let(Uri::parse)
                    val isTrustedReleaseUrl = uri != null &&
                        uri.scheme == "https" &&
                        uri.host == "github.com" &&
                        uri.path?.startsWith(
                            "/thucdang0604/calllog-app/releases/download/"
                        ) == true

                    if (!isTrustedReleaseUrl) {
                        result.error("INVALID_UPDATE_URL", "Đường dẫn tải không hợp lệ.", null)
                    } else {
                        try {
                            startActivity(Intent(Intent.ACTION_VIEW, uri))
                            result.success(null)
                        } catch (error: Exception) {
                            result.error("UPDATE_LINK_FAILED", error.message, null)
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
        
        // Đăng ký custom plugin
        flutterEngine.plugins.add(CallLogManagerPlugin())
        dispatchTimeMarkRequest(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        dispatchTimeMarkRequest(intent)
    }

    private fun dispatchTimeMarkRequest(intent: Intent?) {
        val sourcePath = intent?.getStringExtra("process_timemark_source")
        if (!sourcePath.isNullOrBlank()) {
            getSharedPreferences("timemark_capture", MODE_PRIVATE)
                .edit()
                .putString("pending_source_path", sourcePath)
                .apply()
            eventChannel.invokeMethod("processTimeMarkSource", null)
            return
        }
        if (intent?.getBooleanExtra("capture_timemark", false) != true) return
        getSharedPreferences("timemark_capture", MODE_PRIVATE)
            .edit()
            .putBoolean("pending", true)
            .apply()
        eventChannel.invokeMethod("captureTimeMark", null)
    }
}
