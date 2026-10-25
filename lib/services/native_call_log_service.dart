import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../models/call_log_entry.dart';

class NativeCallLogService {
  static const MethodChannel _channel = MethodChannel('call_log_manager');

  /// Lấy danh sách call log từ native Android (mặc định lấy 10 cuộc gọi mới nhất)
  static Future<List<CallLogEntry>> getCallLogs({int limit = 10}) async {
    try {
      final List<dynamic> result = await _channel.invokeMethod('getCallLogs', {
        'limit': limit,
      });

      return result
          .map((item) => CallLogEntry.fromMap(Map<String, dynamic>.from(item)))
          .toList();
    } catch (e) {
      debugPrint('[NativeCallLogService] getCallLogs error: $e');
      return [];
    }
  }

  /// Kiểm tra quyền
  static Future<bool> hasPermission() async {
    try {
      final bool result = await _channel.invokeMethod('hasPermission');
      return result;
    } catch (e) {
      return false;
    }
  }

  /// Yêu cầu quyền
  static Future<bool> requestPermission() async {
    try {
      final bool result = await _channel.invokeMethod('requestPermission');
      return result;
    } catch (e) {
      return false;
    }
  }
}
