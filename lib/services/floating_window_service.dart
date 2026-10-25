import 'package:flutter/services.dart';
import 'permission_service.dart';

class FloatingWindowService {
  static const MethodChannel _channel = MethodChannel('call_log_manager');

  /// Hiển thị floating window (với kiểm tra quyền)
  static Future<bool> showFloatingWindow() async {
    try {
      final hasPermission = await PermissionService()
          .requestSystemAlertWindowPermission();
      if (!hasPermission) {
        return false;
      }

      final result = await _channel.invokeMethod('showFloatingWindow');
      return result == true;
    } catch (e) {
      return false;
    }
  }

  /// Ẩn floating window
  static Future<bool> hideFloatingWindow() async {
    try {
      final result = await _channel.invokeMethod('hideFloatingWindow');
      return result == true;
    } catch (e) {
      return false;
    }
  }

  /// Kiểm tra xem floating window có đang hiển thị không
  static Future<bool> isFloatingWindowVisible() async {
    try {
      final result = await _channel.invokeMethod('isFloatingWindowVisible');
      return result == true;
    } catch (e) {
      return false;
    }
  }

  /// Lấy số lượng cuộc gọi hiển thị trên popup nổi
  static Future<int> getDisplayCallCount() async {
    try {
      final int? count = await _channel.invokeMethod('getDisplayCallCount');
      return count ?? 4;
    } catch (e) {
      return 4;
    }
  }

  /// Cài đặt số lượng cuộc gọi hiển thị trên popup nổi
  static Future<bool> setDisplayCallCount(int count) async {
    try {
      final result = await _channel.invokeMethod('setDisplayCallCount', {'count': count});
      return result == true;
    } catch (e) {
      return false;
    }
  }
}
