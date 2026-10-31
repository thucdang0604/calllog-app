import '../models/call_log_entry.dart';
import 'permission_service.dart';
import 'native_call_log_service.dart';

class CallLogService {
  static final CallLogService _instance = CallLogService._internal();
  factory CallLogService() => _instance;
  CallLogService._internal();

  // Cache để tăng tốc độ
  List<CallLogEntry>? _cachedCallLogs;
  DateTime? _lastCacheTime;
  static const Duration _cacheTimeout = Duration(minutes: 2);

  /// Lấy danh sách call log (chỉ lấy 10 cuộc gọi mới nhất)
  Future<List<CallLogEntry>> getCallLogs({int limit = 10}) async {
    if (_cachedCallLogs != null &&
        _lastCacheTime != null &&
        DateTime.now().difference(_lastCacheTime!) < _cacheTimeout) {
      return _cachedCallLogs!.take(limit).toList();
    }

    final systemLogs = await _getSystemCallLogs(limit: limit);
    _cachedCallLogs = systemLogs;
    _lastCacheTime = DateTime.now();
    return systemLogs;
  }

  /// Format số điện thoại
  String _formatPhoneNumber(String number) {
    if (number.isEmpty) return '';

    String cleanNumber = number.replaceAll(RegExp(r'[^\d+]'), '');

    if (cleanNumber.startsWith('0')) {
      cleanNumber = '+84${cleanNumber.substring(1)}';
    } else if (!cleanNumber.startsWith('+')) {
      cleanNumber = '+84$cleanNumber';
    }

    if (cleanNumber.startsWith('+84')) {
      String localNumber = cleanNumber.substring(3);
      if (localNumber.length >= 9) {
        return '+84 ${localNumber.substring(0, 3)} ${localNumber.substring(3, 6)} ${localNumber.substring(6)}';
      }
    }

    return cleanNumber;
  }

  /// Kiểm tra quyền truy cập
  Future<bool> hasPermission() async {
    return await PermissionService().requestCallLogPermission();
  }

  /// Yêu cầu quyền
  Future<bool> requestPermission() async {
    return await PermissionService().requestCallLogPermission();
  }

  /// Clear cache để force refresh
  void clearCache() {
    _cachedCallLogs = null;
    _lastCacheTime = null;
  }

  /// Lấy dữ liệu từ native system
  Future<List<CallLogEntry>> _getSystemCallLogs({int limit = 10}) async {
    final hasPermission = await PermissionService().requestCallLogPermission();
    if (!hasPermission) {
      throw StateError('Không có quyền đọc call log');
    }

    final logs = await NativeCallLogService.getCallLogs(limit: limit);
    return logs.map((log) {
      if (log.formattedNumber == null || log.formattedNumber!.isEmpty) {
        return log.copyWith(formattedNumber: _formatPhoneNumber(log.number ?? ''));
      }
      return log;
    }).toList();
  }
}
