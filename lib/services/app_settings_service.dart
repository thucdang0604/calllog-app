import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../models/app_settings.dart';

/// Quản lý đọc/lưu cấu hình âm thanh, rung và cảnh báo đồng bộ giữa Flutter và native Android.
class AppSettingsService {
  static const MethodChannel _channel = MethodChannel('call_log_manager');

  static final ValueNotifier<AppSettings> notifier =
      ValueNotifier<AppSettings>(const AppSettings());

  static bool _loaded = false;
  static Future<AppSettings>? _inFlightLoad;

  static AppSettings get current => notifier.value;

  static Future<AppSettings> load({bool force = false}) {
    if (_loaded && !force) return Future<AppSettings>.value(notifier.value);
    if (!force && _inFlightLoad != null) return _inFlightLoad!;

    final future = _fetchFromNative();
    _inFlightLoad = future;
    return future;
  }

  static Future<AppSettings> _fetchFromNative() async {
    try {
      final raw = await _channel.invokeMapMethod<dynamic, dynamic>('getAppSettings');
      final parsed = AppSettings.fromMap(raw);
      notifier.value = parsed;
      _loaded = true;
      return parsed;
    } on MissingPluginException {
      _loaded = true;
      return notifier.value;
    } catch (_) {
      return notifier.value;
    } finally {
      _inFlightLoad = null;
    }
  }

  static Future<AppSettings> update(AppSettings next) async {
    notifier.value = next;
    _loaded = true;
    try {
      final raw = await _channel.invokeMapMethod<dynamic, dynamic>(
        'saveAppSettings',
        <String, dynamic>{'settings': next.toMap()},
      );
      if (raw != null) {
        final synced = AppSettings.fromMap(raw);
        notifier.value = synced;
        return synced;
      }
    } on MissingPluginException {
      // Bỏ qua trong môi trường unit test không gắn plugin native.
    } catch (_) {}
    return next;
  }

  static Future<AppSettings> resetDefaults() async {
    const defaults = AppSettings();
    notifier.value = defaults;
    _loaded = true;
    try {
      final raw = await _channel.invokeMapMethod<dynamic, dynamic>('resetAppSettings');
      if (raw != null) {
        final synced = AppSettings.fromMap(raw);
        notifier.value = synced;
        return synced;
      }
    } on MissingPluginException {
      // Bỏ qua trong môi trường unit test không gắn plugin native.
    } catch (_) {}
    return defaults;
  }

  static Future<void> previewScanTone(String outcome, {int? volume}) async {
    try {
      await _channel.invokeMethod<bool>('previewScanTone', <String, dynamic>{
        'outcome': outcome,
        if (volume != null) 'volume': volume,
      });
    } on MissingPluginException {
      // Bỏ qua trong môi trường unit test.
    } catch (_) {}
  }
}
