import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/timemark_service.dart';

/// A deliberately small UI: the native CameraX activity owns the camera.
/// The app does not hold a camera texture in memory.
class TimeMarkCameraWidget extends StatefulWidget {
  const TimeMarkCameraWidget({super.key});

  @override
  State<TimeMarkCameraWidget> createState() => _TimeMarkCameraWidgetState();
}

class _TimeMarkCameraWidgetState extends State<TimeMarkCameraWidget> {
  static const _events = MethodChannel('call_log_manager_events');
  bool _isCapturing = false;
  String? _lastMessage;

  @override
  void initState() {
    super.initState();
    _events.setMethodCallHandler(_handleNativeEvent);
  }

  Future<void> _handleNativeEvent(MethodCall call) async {
    if (call.method == 'captureTimeMark') {
      await _capture();
    }
  }

  Future<void> _capture() async {
    if (_isCapturing) return;
    setState(() => _isCapturing = true);
    try {
      final opened = await TimeMarkService.openQuickCamera();
      if (!mounted) return;
      if (opened) {
        setState(() => _lastMessage = 'Camera đã mở - chụp 1 chạm');
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Không thể mở camera: $error'), backgroundColor: Colors.red),
      );
    } finally {
      if (mounted) setState(() => _isCapturing = false);
    }
  }

  @override
  void dispose() {
    _events.setMethodCallHandler(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.camera_alt_outlined, color: Colors.indigo[700]),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text('TimeMark', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                ),
                if (_isCapturing)
                  const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'Chụp ảnh kèm thời gian, tọa độ và mã QR/mã vạch nếu phát hiện được.',
              style: TextStyle(fontSize: 12, color: Colors.grey[700]),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _isCapturing ? null : _capture,
                icon: const Icon(Icons.camera_alt),
                label: const Text('Chụp ảnh TimeMark'),
              ),
            ),
            if (_lastMessage != null) ...[
              const SizedBox(height: 10),
              Text(
                _lastMessage!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: Colors.green[800]),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
