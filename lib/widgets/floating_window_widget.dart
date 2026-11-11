import 'dart:async';
import 'package:flutter/material.dart';
import '../services/floating_window_service.dart';
import '../services/permission_service.dart';

class FloatingWindowWidget extends StatefulWidget {
  const FloatingWindowWidget({super.key});

  @override
  State<FloatingWindowWidget> createState() => _FloatingWindowWidgetState();
}

class _FloatingWindowWidgetState extends State<FloatingWindowWidget>
    with WidgetsBindingObserver {
  bool _isFloatingWindowVisible = false;
  int _displayCallCount = 4;
  int _bubbleOpacity = 80;
  int _panelOpacity = 95;
  bool _isIgnoringBattery = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkInitialFloatingWindowState();
    _loadDisplayCallCount();
    _loadFloatingOpacity();
    _checkBatteryOptimization();
  }

  Future<void> _checkBatteryOptimization() async {
    final ignoring = await PermissionService().isIgnoringBatteryOptimizations();
    if (mounted) {
      setState(() => _isIgnoringBattery = ignoring);
    }
  }

  Future<void> _loadDisplayCallCount() async {
    final count = await FloatingWindowService.getDisplayCallCount();
    if (mounted) {
      setState(() {
        _displayCallCount = count;
      });
    }
  }

  Future<void> _loadFloatingOpacity() async {
    final opacity = await FloatingWindowService.getFloatingOpacity();
    if (mounted) {
      setState(() {
        _bubbleOpacity = opacity['bubbleOpacity'] ?? 80;
        _panelOpacity = opacity['panelOpacity'] ?? 95;
      });
    }
  }

  Future<void> _updateBubbleOpacity(int value) async {
    setState(() => _bubbleOpacity = value);
    await FloatingWindowService.setFloatingOpacity(bubbleOpacity: value);
  }

  Future<void> _updatePanelOpacity(int value) async {
    setState(() => _panelOpacity = value);
    await FloatingWindowService.setFloatingOpacity(panelOpacity: value);
  }

  Future<void> _updateDisplayCallCount(int count) async {
    setState(() {
      _displayCallCount = count;
    });
    await FloatingWindowService.setDisplayCallCount(count);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('✅ Đã chọn tối đa $count cuộc gọi ở chế độ mở rộng'),
          duration: const Duration(seconds: 1),
          backgroundColor: Colors.blue[700],
        ),
      );
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      _syncFloatingWindowState();
      _checkBatteryOptimization();
    }
  }

  /// Kiểm tra trạng thái floating window ban đầu
  Future<void> _checkInitialFloatingWindowState() async {
    try {
      await Future.delayed(const Duration(milliseconds: 100));
      final isVisible = await FloatingWindowService.isFloatingWindowVisible();
      if (isVisible != _isFloatingWindowVisible && mounted) {
        setState(() {
          _isFloatingWindowVisible = isVisible;
        });
      }
    } catch (e) {
      // Ignore
    }
  }

  /// Đồng bộ trạng thái floating window khi app resume
  Future<void> _syncFloatingWindowState() async {
    try {
      final isVisible = await FloatingWindowService.isFloatingWindowVisible();

      if (!isVisible && _isFloatingWindowVisible) {
        // Android báo không hiển thị nhưng UI state = true → thử khôi phục
        final restored = await FloatingWindowService.showFloatingWindow();
        if (!restored && mounted) {
          setState(() => _isFloatingWindowVisible = false);
        }
      } else if (isVisible && !_isFloatingWindowVisible) {
        if (mounted) {
          setState(() => _isFloatingWindowVisible = true);
        }
      }
    } catch (e) {
      // Ignore
    }
  }

  /// Hiển thị floating window
  Future<void> _showFloatingWindow() async {
    try {
      if (mounted) {
        setState(() => _isFloatingWindowVisible = true);
      }

      final success = await FloatingWindowService.showFloatingWindow();

      if (!success) {
        if (mounted) {
          setState(() => _isFloatingWindowVisible = false);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Vui lòng cấp quyền "Hiển thị trên các ứng dụng khác"',
              ),
              backgroundColor: Colors.orange,
              duration: Duration(seconds: 4),
            ),
          );
          await PermissionService().openOverlaySettings();
        }
        return;
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('✅ Bong bóng đã bật'),
            backgroundColor: Colors.green,
            duration: Duration(seconds: 1),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isFloatingWindowVisible = false);
      }
    }
  }

  /// Ẩn floating window
  Future<void> _hideFloatingWindow() async {
    try {
      if (mounted) {
        setState(() => _isFloatingWindowVisible = false);
      }
      await FloatingWindowService.hideFloatingWindow();
    } catch (e) {
      // Ignore - window may already be hidden
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.all(16),
      elevation: 4,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header + Switch
            Row(
              children: [
                Icon(
                  _isFloatingWindowVisible
                      ? Icons.picture_in_picture
                      : Icons.picture_in_picture_alt,
                  color: _isFloatingWindowVisible ? Colors.green : Colors.blue,
                ),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'Bong bóng trôi nổi',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                ),
                Switch(
                  value: _isFloatingWindowVisible,
                  activeColor: Colors.green,
                  onChanged: (value) {
                    if (value) {
                      _showFloatingWindow();
                    } else {
                      _hideFloatingWindow();
                    }
                  },
                ),
              ],
            ),

            const SizedBox(height: 12),

            // Trạng thái
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: _isFloatingWindowVisible
                    ? Colors.green[50]
                    : Colors.grey[100],
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: _isFloatingWindowVisible
                      ? Colors.green
                      : Colors.grey[300]!,
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    _isFloatingWindowVisible
                        ? Icons.check_circle
                        : Icons.circle_outlined,
                    color: _isFloatingWindowVisible
                        ? Colors.green
                        : Colors.grey,
                    size: 16,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _isFloatingWindowVisible
                        ? 'Đang hoạt động — Chạm bong bóng để mở công cụ'
                        : 'Đã tắt',
                    style: TextStyle(
                      color: _isFloatingWindowVisible
                          ? Colors.green[700]
                          : Colors.grey[600],
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),

            Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.blue.shade50,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.blue.shade200),
              ),
              child: Row(
                children: [
                  Icon(Icons.battery_saver, color: Colors.blue[800], size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _isIgnoringBattery
                          ? 'Ứng dụng đang được miễn tối ưu pin nên có thể tốn pin hơn. Mở cài đặt để bật lại tối ưu nếu ưu tiên thời lượng pin.'
                          : 'Android đang tối ưu pin. Chỉ bỏ tối ưu nếu thiết bị thường xuyên tự tắt popup.',
                      style: TextStyle(fontSize: 11, color: Colors.blue[900]),
                    ),
                  ),
                  const SizedBox(width: 4),
                  InkWell(
                    onTap: () async {
                      await PermissionService()
                          .openBatteryOptimizationSettings();
                      await _checkBatteryOptimization();
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.blue[700],
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Text(
                        'Cài đặt pin',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 14),

            // Cấu hình số lượng cuộc gọi hiển thị
            Row(
              children: [
                const Icon(
                  Icons.format_list_numbered,
                  size: 20,
                  color: Colors.blueGrey,
                ),
                const SizedBox(width: 8),
                const Text(
                  'Số cuộc gọi tối đa ở chế độ mở rộng:',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [2, 3, 4, 5, 6].map((count) {
                final isSelected = _displayCallCount == count;
                return ChoiceChip(
                  label: Text(
                    'Tối đa $count',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: isSelected
                          ? FontWeight.bold
                          : FontWeight.normal,
                      color: isSelected ? Colors.white : Colors.black87,
                    ),
                  ),
                  selected: isSelected,
                  selectedColor: Colors.blue[700],
                  backgroundColor: Colors.grey[100],
                  showCheckmark: false,
                  onSelected: (selected) {
                    if (selected) {
                      _updateDisplayCallCount(count);
                    }
                  },
                );
              }).toList(),
            ),
            const SizedBox(height: 4),
            Text(
              'Màn hình thấp luôn chỉ hiện 2 cuộc gọi; mở rộng trên màn hình đủ cao để xem tối đa $_displayCallCount cuộc gọi.',
              style: TextStyle(
                fontSize: 12,
                color: Colors.blue[900],
                fontStyle: FontStyle.italic,
              ),
            ),

            const SizedBox(height: 16),
            const Divider(),
            const SizedBox(height: 8),

            // Cấu hình độ mờ (Opacity)
            const Row(
              children: [
                Icon(Icons.opacity, size: 20, color: Colors.blueGrey),
                SizedBox(width: 8),
                Text(
                  'Độ mờ / Độ trong suốt (Opacity):',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // 1. Bong bóng trồi nổi slider
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Opacity(
                          opacity: _bubbleOpacity / 100.0,
                          child: Container(
                            width: 24,
                            height: 24,
                            decoration: const BoxDecoration(
                              color: Colors.blue,
                              shape: BoxShape.circle,
                            ),
                            alignment: Alignment.center,
                            child: const Text(
                              'LOG',
                              style: TextStyle(
                                fontSize: 8,
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        const Text(
                          'Bong bóng trồi nổi',
                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                        ),
                      ],
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.blue.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        '$_bubbleOpacity%',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: Colors.blue,
                        ),
                      ),
                    ),
                  ],
                ),
                Slider(
                  value: _bubbleOpacity.toDouble(),
                  min: 20,
                  max: 100,
                  divisions: 16,
                  label: '$_bubbleOpacity%',
                  activeColor: Colors.blue[700],
                  onChanged: (val) {
                    final intVal = val.round();
                    if (intVal != _bubbleOpacity) {
                      _updateBubbleOpacity(intVal);
                    }
                  },
                ),
                Padding(
                  padding: const EdgeInsets.only(left: 4, bottom: 8),
                  child: Text(
                    'Mẹo: Chỉnh 60% - 80% để icon mờ nhẹ, không che khuất bản đồ và app giao hàng.',
                    style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 8),

            // 2. Popup thao tác nhanh slider
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Opacity(
                          opacity: _panelOpacity / 100.0,
                          child: Container(
                            width: 24,
                            height: 18,
                            decoration: BoxDecoration(
                              color: const Color(0xFF2C3E50),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            alignment: Alignment.center,
                            child: const Icon(
                              Icons.view_agenda,
                              size: 12,
                              color: Colors.white,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        const Text(
                          'Popup thao tác nhanh',
                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                        ),
                      ],
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.blue.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        '$_panelOpacity%',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: Colors.blue,
                        ),
                      ),
                    ),
                  ],
                ),
                Slider(
                  value: _panelOpacity.toDouble(),
                  min: 50,
                  max: 100,
                  divisions: 10,
                  label: '$_panelOpacity%',
                  activeColor: Colors.blue[700],
                  onChanged: (val) {
                    final intVal = val.round();
                    if (intVal != _panelOpacity) {
                      _updatePanelOpacity(intVal);
                    }
                  },
                ),
                Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: Text(
                    'Mẹo: Chỉnh 80% - 95% để vừa nhìn xuyên ứng dụng bên dưới vừa đọc rõ số điện thoại.',
                    style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
