import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'native_call_log_service.dart';

class PermissionService {
  static final PermissionService _instance = PermissionService._internal();
  factory PermissionService() => _instance;
  PermissionService._internal();

  /// Kiểm tra và yêu cầu quyền đọc và ghi call log
  Future<bool> requestCallLogPermission() async {
    try {
      // 1. Kiểm tra / Yêu cầu quyền trực tiếp từ native Android plugin (READ_CALL_LOG & WRITE_CALL_LOG)
      final hasNativePermission = await NativeCallLogService.hasPermission();
      if (hasNativePermission) {
        return true;
      }

      final nativeGranted = await NativeCallLogService.requestPermission();
      if (nativeGranted) {
        return true;
      }
    } catch (e) {
      // Ignore
    }

    // 2. Fallback qua permission_handler
    final phoneStatus = await Permission.phone.status;

    if (phoneStatus.isGranted) {
      return true;
    }

    if (phoneStatus.isDenied) {
      final result = await Permission.phone.request();
      return result.isGranted;
    }

    if (phoneStatus.isPermanentlyDenied) {
      // Mở settings để user có thể cấp quyền thủ công
      await openAppSettings();
      return false;
    }

    return false;
  }

  /// Kiểm tra và yêu cầu quyền SYSTEM_ALERT_WINDOW
  Future<bool> requestSystemAlertWindowPermission() async {
    final status = await Permission.systemAlertWindow.status;

    if (status.isGranted) {
      return true;
    }

    final result = await Permission.systemAlertWindow.request();
    if (result.isGranted) {
      return true;
    }

    // Nếu không được cấp trực tiếp, mở trang cài đặt overlay của Android
    return await openOverlaySettings();
  }

  /// Mở màn hình Cài đặt cấp quyền Vẽ trên ứng dụng khác
  Future<bool> openOverlaySettings() async {
    try {
      const channel = MethodChannel('call_log_manager');
      final result = await channel.invokeMethod('openOverlaySettings');
      return result == true;
    } catch (e) {
      await openAppSettings();
      return false;
    }
  }

  /// Kiểm tra quyền đọc contacts
  Future<bool> requestContactsPermission() async {
    final status = await Permission.contacts.status;

    if (status.isGranted) {
      return true;
    }

    if (status.isDenied) {
      final result = await Permission.contacts.request();
      return result.isGranted;
    }

    if (status.isPermanentlyDenied) {
      await openAppSettings();
      return false;
    }

    return false;
  }

  /// Kiểm tra và yêu cầu quyền notification
  Future<bool> requestNotificationPermission() async {
    final status = await Permission.notification.status;

    if (status.isGranted) {
      return true;
    }

    if (status.isDenied) {
      final result = await Permission.notification.request();
      return result.isGranted;
    }

    if (status.isPermanentlyDenied) {
      // Mở settings để user có thể cấp quyền thủ công
      await openAppSettings();
      return false;
    }

    return false;
  }

  /// Kiểm tra và yêu cầu quyền gửi SMS
  Future<bool> requestSmsPermission() async {
    final status = await Permission.sms.status;

    if (status.isGranted) {
      return true;
    }

    if (status.isDenied) {
      final result = await Permission.sms.request();
      return result.isGranted;
    }

    if (status.isPermanentlyDenied) {
      await openAppSettings();
      return false;
    }

    return false;
  }

  /// Kiểm tra tất cả quyền cần thiết
  Future<Map<String, bool>> checkAllPermissions() async {
    final permissions = await Future.wait([
      Permission.phone.status,
      Permission.contacts.status,
      Permission.notification.status,
      Permission.sms.status,
    ]);

    return {
      'callLog': permissions[0].isGranted,
      'contacts': permissions[1].isGranted,
      'notification': permissions[2].isGranted,
      'sms': permissions[3].isGranted,
    };
  }

  /// Yêu cầu tất cả quyền cần thiết
  Future<Map<String, bool>> requestAllPermissions() async {
    final results = await Future.wait([
      Permission.phone.request(),
      Permission.contacts.request(),
      Permission.notification.request(),
      Permission.sms.request(),
    ]);

    return {
      'callLog': results[0].isGranted,
      'contacts': results[1].isGranted,
      'notification': results[2].isGranted,
      'sms': results[3].isGranted,
    };
  }

  /// Kiểm tra xem có cần hiển thị dialog giải thích không
  Future<bool> shouldShowRequestPermissionRationale() async {
    final phoneStatus = await Permission.phone.status;
    final contactsStatus = await Permission.contacts.status;

    return phoneStatus.isDenied || contactsStatus.isDenied;
  }

  /// Kiểm tra xem ứng dụng đã được miễn trừ tối ưu hóa pin (chạy ngầm không bị tắt) chưa
  Future<bool> isIgnoringBatteryOptimizations() async {
    try {
      const channel = MethodChannel('call_log_manager');
      final bool? result = await channel.invokeMethod(
        'isIgnoringBatteryOptimizations',
      );
      return result ?? false;
    } catch (e) {
      final status = await Permission.ignoreBatteryOptimizations.status;
      return status.isGranted;
    }
  }

  /// Mở cài đặt pin để người dùng tự chọn mức tối ưu phù hợp.
  Future<bool> openBatteryOptimizationSettings() async {
    try {
      const channel = MethodChannel('call_log_manager');
      final bool? result = await channel.invokeMethod(
        'openBatteryOptimizationSettings',
      );
      return result ?? false;
    } catch (e) {
      return openAppSettings();
    }
  }
}
