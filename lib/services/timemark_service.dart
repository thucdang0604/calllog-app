import 'package:flutter/services.dart';

/// Thin bridge to the native CameraX-based TimeMark capture.
/// Watermarking, EXIF correction, location overlay, and saving to Pictures/TimeMark
/// is handled entirely in native code ([TimeMarkCaptureActivity.kt]).
class TimeMarkService {
  static const _nativeChannel = MethodChannel('call_log_manager');

  static Future<bool> openQuickCamera() async {
    return await _nativeChannel.invokeMethod<bool>('openQuickCamera') ?? false;
  }
}
