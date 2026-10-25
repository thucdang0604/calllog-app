import 'package:flutter/foundation.dart';
import '../models/call_log_entry.dart';
import '../services/call_log_service.dart';

class CallLogProvider with ChangeNotifier {
  final CallLogService _callLogService = CallLogService();

  List<CallLogEntry> _allCallLogs = [];

  bool _isLoading = false;
  bool _hasError = false;
  String _errorMessage = '';
  bool _hasPermission = false;

  // Getters
  List<CallLogEntry> get allCallLogs => _allCallLogs;
  bool get isLoading => _isLoading;
  bool get hasError => _hasError;
  String get errorMessage => _errorMessage;
  bool get hasPermission => _hasPermission;

  /// Tải danh sách call log
  Future<void> loadCallLogs({bool forceRefresh = false}) async {
    if (_isLoading) return;
    if (!forceRefresh && _allCallLogs.isNotEmpty && !_hasError) return;

    _isLoading = true;
    _hasError = false;
    _errorMessage = '';
    notifyListeners();

    try {
      final hasPermission = await _callLogService.hasPermission();

      if (!hasPermission) {
        _hasPermission = false;
        _hasError = false;
        _errorMessage = '';
        _isLoading = false;
        notifyListeners();
        return;
      }

      _hasPermission = true;

      if (forceRefresh) {
        _callLogService.clearCache();
      }

      final callLogs = await _callLogService.getCallLogs();

      _allCallLogs = callLogs;
      _isLoading = false;
      notifyListeners();
    } catch (e) {
      _isLoading = false;
      _hasError = true;
      _errorMessage = 'Lỗi khi tải call log: $e';
      notifyListeners();
    }
  }

  /// Yêu cầu quyền
  Future<bool> requestPermission() async {
    try {
      final granted = await _callLogService.requestPermission();
      _hasPermission = granted;
      notifyListeners();
      return granted;
    } catch (e) {
      _hasError = true;
      _errorMessage = 'Lỗi khi yêu cầu quyền: $e';
      notifyListeners();
      return false;
    }
  }

  /// Lấy danh sách cuộc gọi mới nhất theo số lượng chỉ định (mặc định 4)
  List<CallLogEntry> getLatestCalls({int count = 4}) {
    return _allCallLogs.take(count).toList();
  }

  /// Lấy 2 cuộc gọi mới nhất (giữ để tương thích)
  List<CallLogEntry> getLatestTwoCalls() {
    return _allCallLogs.take(2).toList();
  }

  /// Làm mới dữ liệu
  Future<void> refresh() async {
    await loadCallLogs(forceRefresh: true);
  }

  /// Xóa lỗi
  void clearError() {
    _hasError = false;
    _errorMessage = '';
    notifyListeners();
  }
}
