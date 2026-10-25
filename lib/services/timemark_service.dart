import 'package:flutter/services.dart';

class TimeMarkResult {
  const TimeMarkResult({
    required this.path,
    required this.capturedAt,
    required this.locationLabel,
    this.detectedCode,
  });

  final String path;
  final DateTime capturedAt;
  final String locationLabel;
  final String? detectedCode;
}

/// Thin bridge to the native CameraX-based TimeMark capture.
///
/// All image processing (watermark, barcode scanning, geocoding, gallery save)
/// is handled entirely in native code ([TimeMarkCaptureActivity.kt]).
/// The Dart side only provides the trigger and consumes results.
class TimeMarkService {
  static const _nativeChannel = MethodChannel('call_log_manager');

  static Future<bool> consumePendingCapture() async {
    try {
      return await _nativeChannel.invokeMethod<bool>('consumeTimeMarkCapture') ?? false;
    } on PlatformException {
      return false;
    }
  }

  static Future<String?> consumePendingSource() async {
    try {
      return await _nativeChannel.invokeMethod<String>('consumeTimeMarkSource');
    } on PlatformException {
      return null;
    }
  }

  static Future<bool> openQuickCamera() async {
    try {
      return await _nativeChannel.invokeMethod<bool>('openQuickCamera') ?? false;
    } on PlatformException {
      return false;
    }
  }
}
