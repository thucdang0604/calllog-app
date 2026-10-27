package com.example.call_log_manager

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.os.Build
import android.app.role.RoleManager
import android.provider.Settings
import android.provider.Telephony
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugins.GeneratedPluginRegistrant
import io.flutter.plugin.common.MethodChannel
import androidx.core.content.FileProvider
import java.io.File

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
                "getUpdateApkPath" -> {
                    val version = call.argument<String>("version")
                        ?.filter { it.isLetterOrDigit() || it == '.' || it == '_' }
                        .orEmpty()
                    if (version.isBlank()) {
                        result.error("INVALID_UPDATE_VERSION", "Phiên bản không hợp lệ.", null)
                    } else {
                        val updateDirectory = File(cacheDir, "updates")
                        if (!updateDirectory.exists() && !updateDirectory.mkdirs()) {
                            result.error("UPDATE_CACHE_FAILED", "Không tạo được thư mục tải.", null)
                        } else {
                            result.success(File(updateDirectory, "calllog-$version.apk").absolutePath)
                        }
                    }
                }
                "canInstallApk" -> {
                    result.success(
                        Build.VERSION.SDK_INT < Build.VERSION_CODES.O ||
                            packageManager.canRequestPackageInstalls()
                    )
                }
                "installUpdateApk" -> {
                    try {
                        val path = call.argument<String>("path")
                            ?: throw IllegalArgumentException("Thiếu đường dẫn APK.")
                        val updateDirectory = File(cacheDir, "updates").canonicalFile
                        val apkFile = File(path).canonicalFile
                        if (!apkFile.path.startsWith(updateDirectory.path + File.separator) ||
                            !apkFile.isFile || apkFile.length() == 0L
                        ) {
                            throw IllegalArgumentException("Tệp APK cập nhật không hợp lệ.")
                        }

                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                            !packageManager.canRequestPackageInstalls()
                        ) {
                            startActivity(
                                Intent(
                                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                    Uri.parse("package:$packageName")
                                )
                            )
                            result.success(false)
                            return@setMethodCallHandler
                        }

                        val apkUri = FileProvider.getUriForFile(
                            this,
                            "$packageName.timemark.fileprovider",
                            apkFile
                        )
                        startActivity(
                            Intent(Intent.ACTION_VIEW).apply {
                                setDataAndType(apkUri, "application/vnd.android.package-archive")
                                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            }
                        )
                        result.success(true)
                    } catch (error: Exception) {
                        result.error("APK_INSTALL_FAILED", error.message, null)
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

    override fun onResume() {
        super.onResume()
        val prefs = getSharedPreferences("fake_sms_role", MODE_PRIVATE)
        if (!prefs.getBoolean("restore_required", false)) return

        val stillDefault = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            getSystemService(RoleManager::class.java)?.isRoleHeld(RoleManager.ROLE_SMS) == true
        } else {
            packageName == Telephony.Sms.getDefaultSmsPackage(this)
        }
        if (stillDefault) {
            startActivity(Intent(this, FakeSmsRoleActivity::class.java).apply {
                putExtra(FakeSmsRoleActivity.EXTRA_RESTORE_ONLY, true)
            })
        } else {
            prefs.edit().putBoolean("restore_required", false).apply()
        }
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
