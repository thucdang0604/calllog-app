import 'package:flutter/services.dart';

class FakeGpsService {
  static const MethodChannel _channel = MethodChannel('call_log_manager');

  /// Kiểm tra xem ứng dụng đã được chọn làm Mock Location App chưa
  static Future<bool> isMockLocationEnabled() async {
    try {
      final bool result = await _channel.invokeMethod('isMockLocationEnabled');
      return result;
    } catch (e) {
      return false;
    }
  }

  /// Mở trang Cài đặt Nhà phát triển (Developer Options) để người dùng chọn Mock Location App
  static Future<void> openDeveloperSettings() async {
    try {
      await _channel.invokeMethod('openDeveloperSettings');
    } catch (e) {
      // Ignore
    }
  }

  /// Bắt đầu giả lập vị trí GPS
  static Future<bool> startFakeGps({
    required double latitude,
    required double longitude,
  }) async {
    try {
      final bool result = await _channel.invokeMethod('startFakeGps', {
        'latitude': latitude,
        'longitude': longitude,
      });
      return result;
    } catch (e) {
      return false;
    }
  }

  /// Dừng giả lập vị trí GPS
  static Future<bool> stopFakeGps() async {
    try {
      final bool result = await _channel.invokeMethod('stopFakeGps');
      return result;
    } catch (e) {
      return false;
    }
  }

  /// Kiểm tra xem Fake GPS có đang chạy không
  static Future<bool> isFakeGpsRunning() async {
    try {
      final bool result = await _channel.invokeMethod('isFakeGpsRunning');
      return result;
    } catch (e) {
      return false;
    }
  }

  /// Lấy thông tin tọa độ đang giả lập
  static Future<Map<String, dynamic>> getFakeGpsLocation() async {
    try {
      final Map<dynamic, dynamic>? result =
          await _channel.invokeMethod('getFakeGpsLocation');
      if (result != null) {
        return Map<String, dynamic>.from(result);
      }
      return {'isRunning': false, 'latitude': 0.0, 'longitude': 0.0};
    } catch (e) {
      return {'isRunning': false, 'latitude': 0.0, 'longitude': 0.0};
    }
  }

  /// Lấy vị trí GPS thực tế hiện tại của thiết bị
  static Future<Map<String, double>?> getCurrentDeviceLocation() async {
    try {
      final Map<dynamic, dynamic>? result =
          await _channel.invokeMethod('getCurrentDeviceLocation');
      if (result != null) {
        final double? lat = (result['latitude'] as num?)?.toDouble();
        final double? lng = (result['longitude'] as num?)?.toDouble();
        if (lat != null && lng != null) {
          return {'latitude': lat, 'longitude': lng};
        }
      }
      return null;
    } catch (e) {
      return null;
    }
  }
}
