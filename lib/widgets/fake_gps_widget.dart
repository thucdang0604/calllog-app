import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import '../services/fake_gps_service.dart';
import '../services/saved_location_service.dart';
import '../models/saved_location.dart';
import '../screens/map_location_picker_screen.dart';

class FakeGpsWidget extends StatefulWidget {
  const FakeGpsWidget({super.key});

  @override
  State<FakeGpsWidget> createState() => _FakeGpsWidgetState();
}

class _FakeGpsWidgetState extends State<FakeGpsWidget> with WidgetsBindingObserver {
  final TextEditingController _latController = TextEditingController();
  final TextEditingController _lngController = TextEditingController();

  bool _isRunning = false;
  bool _isMockEnabled = false;
  bool _isLoading = true;
  bool _isFetchingLocation = false;
  List<SavedLocation> _savedLocations = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _latController.text = '21.028511';
    _lngController.text = '105.854444';
    _checkStatus();
    _loadSavedLocations();

    // Tự động dò vị trí GPS thực tế của máy ngay khi mở app
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_isRunning) {
        _fetchCurrentDeviceLocation(silent: true);
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _latController.dispose();
    _lngController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkStatus();
      _loadSavedLocations();
    }
  }

  Future<void> _loadSavedLocations() async {
    final list = await SavedLocationService.getSavedLocations();
    if (mounted) {
      setState(() {
        _savedLocations = list;
      });
    }
  }

  Future<void> _checkStatus() async {
    try {
      final running = await FakeGpsService.isFakeGpsRunning();
      final mockEnabled = await FakeGpsService.isMockLocationEnabled();
      final locationData = await FakeGpsService.getFakeGpsLocation();

      if (mounted) {
        setState(() {
          _isRunning = running;
          _isMockEnabled = mockEnabled;
          if (running) {
            final lat = locationData['latitude'] as double? ?? 0.0;
            final lng = locationData['longitude'] as double? ?? 0.0;
            if (lat != 0.0 && lng != 0.0) {
              _latController.text = lat.toStringAsFixed(6);
              _lngController.text = lng.toStringAsFixed(6);
            }
          }
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  /// Lấy vị trí GPS thực tế hiện tại của thiết bị
  Future<void> _fetchCurrentDeviceLocation({bool silent = false}) async {
    if (_isFetchingLocation) return;
    setState(() => _isFetchingLocation = true);

    try {
      await Permission.location.request();
      final loc = await FakeGpsService.getCurrentDeviceLocation();

      if (loc != null && mounted) {
        final double lat = loc['latitude']!;
        final double lng = loc['longitude']!;

        setState(() {
          _latController.text = lat.toStringAsFixed(6);
          _lngController.text = lng.toStringAsFixed(6);
        });

        if (_isRunning) {
          await FakeGpsService.startFakeGps(
            latitude: lat,
            longitude: lng,
          );
        }

        if (!silent && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('📍 Đã lấy vị trí GPS thực tế: ${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}'),
              backgroundColor: Colors.green,
              duration: const Duration(seconds: 2),
            ),
          );
        }
      } else if (!silent && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('⚠️ Không thể lấy vị trí GPS. Hãy bật dịch vụ Vị trí (GPS) trên máy và thử lại.'),
            backgroundColor: Colors.orange,
            duration: Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      if (!silent && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('❌ Lỗi định vị: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isFetchingLocation = false);
      }
    }
  }

  Future<void> _toggleFakeGps() async {
    if (_isRunning) {
      final stopped = await FakeGpsService.stopFakeGps();
      if (mounted) {
        setState(() {
          _isRunning = !stopped;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('🛑 Đã tắt Fake GPS - Trả về vị trí thực'),
            backgroundColor: Colors.orange,
            duration: Duration(seconds: 2),
          ),
        );
      }
    } else {
      final double? lat = double.tryParse(_latController.text.trim());
      final double? lng = double.tryParse(_lngController.text.trim());

      if (lat == null || lng == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('❌ Vui lòng nhập đúng tọa độ Vĩ độ và Kinh độ'),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }

      if (lat < -90 || lat > 90 || lng < -180 || lng > 180) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('❌ Vĩ độ [-90..90] hoặc Kinh độ [-180..180] không hợp lệ'),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }

      final started = await FakeGpsService.startFakeGps(
        latitude: lat,
        longitude: lng,
      );

      if (started) {
        if (mounted) {
          setState(() => _isRunning = true);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('📍 Đã bật Fake GPS: $lat, $lng'),
              backgroundColor: Colors.green,
              duration: const Duration(seconds: 2),
            ),
          );
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('⚠️ Cần chọn ứng dụng trong "Tùy chọn nhà phát triển"'),
              backgroundColor: Colors.redAccent,
              duration: Duration(seconds: 4),
            ),
          );
        }
        await FakeGpsService.openDeveloperSettings();
      }
    }
  }

  /// Khi người dùng bấm vào một vị trí đã lưu trong danh sách cá nhân
  void _applySavedLocation(SavedLocation loc) {
    setState(() {
      _latController.text = loc.latitude.toStringAsFixed(6);
      _lngController.text = loc.longitude.toStringAsFixed(6);
    });

    if (_isRunning) {
      FakeGpsService.startFakeGps(
        latitude: loc.latitude,
        longitude: loc.longitude,
      );
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('📍 Đã chuyển vị trí tới "${loc.name}"'),
          backgroundColor: Colors.green,
          duration: const Duration(seconds: 2),
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('📍 Đã chọn vị trí: "${loc.name}"'),
          backgroundColor: Colors.blue[700],
          duration: const Duration(seconds: 1),
        ),
      );
    }
  }

  /// Mở bản đồ kéo thả trực quan
  Future<void> _openMapPicker() async {
    final double lat = double.tryParse(_latController.text.trim()) ?? 21.028511;
    final double lng = double.tryParse(_lngController.text.trim()) ?? 105.854444;

    final result = await Navigator.of(context).push<Map<String, dynamic>>(
      MaterialPageRoute(
        builder: (ctx) => MapLocationPickerScreen(
          initialLatitude: lat,
          initialLongitude: lng,
        ),
      ),
    );

    if (result != null && mounted) {
      final double newLat = result['latitude'] as double;
      final double newLng = result['longitude'] as double;
      final String? name = result['name'] as String?;

      setState(() {
        _latController.text = newLat.toStringAsFixed(6);
        _lngController.text = newLng.toStringAsFixed(6);
      });

      await _loadSavedLocations();

      if (_isRunning) {
        await FakeGpsService.startFakeGps(
          latitude: newLat,
          longitude: newLng,
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(name != null
                  ? '📍 Đã lưu & chuyển tới "$name"'
                  : '📍 Đã cập nhật tọa độ trên bản đồ'),
              backgroundColor: Colors.green,
              duration: const Duration(seconds: 2),
            ),
          );
        }
      }
    }
  }

  /// Lưu vị trí từ tọa độ đang nhập vào danh sách cá nhân
  Future<void> _showSaveCurrentLocationDialog() async {
    final double? lat = double.tryParse(_latController.text.trim());
    final double? lng = double.tryParse(_lngController.text.trim());

    if (lat == null || lng == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Vui lòng nhập tọa độ trước khi lưu'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    final nameController = TextEditingController();

    final bool? saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: const [
            Icon(Icons.bookmark_add, color: Colors.purple),
            SizedBox(width: 8),
            Text('Lưu vị trí cá nhân', style: TextStyle(fontSize: 18)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Đặt tên cho vị trí này:',
              style: TextStyle(fontSize: 13, color: Colors.grey),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: nameController,
              autofocus: true,
              decoration: InputDecoration(
                labelText: 'Tên địa điểm',
                hintText: 'Ví dụ: Nhà riêng, Công ty, Bãi xe...',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                prefixIcon: const Icon(Icons.label_outline),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Tọa độ: ${lat.toStringAsFixed(6)}, ${lng.toStringAsFixed(6)}',
              style: const TextStyle(fontSize: 12, color: Colors.blueGrey),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Hủy'),
          ),
          ElevatedButton(
            onPressed: () {
              if (nameController.text.trim().isNotEmpty) {
                Navigator.of(ctx).pop(true);
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.purple[700],
              foregroundColor: Colors.white,
            ),
            child: const Text('Lưu'),
          ),
        ],
      ),
    );

    if (saved == true && mounted) {
      final name = nameController.text.trim();
      await SavedLocationService.saveLocation(
        name: name,
        latitude: lat,
        longitude: lng,
      );
      await _loadSavedLocations();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('✅ Đã lưu vị trí "$name"'),
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }
  }

  /// Xóa vị trí đã lưu
  Future<void> _deleteLocation(SavedLocation loc) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: const Text('Xác nhận xóa', style: TextStyle(fontSize: 17)),
        content: Text('Bạn có chắc muốn xóa vị trí "${loc.name}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Hủy'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Xóa'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await SavedLocationService.deleteLocation(loc.id);
      await _loadSavedLocations();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('🗑️ Đã xóa "${loc.name}"'),
            duration: const Duration(seconds: 1),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(
            children: [
              Icon(
                Icons.location_on,
                color: _isRunning ? Colors.green[700] : Colors.purple[700],
                size: 22,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Vị trí giả lập (Fake GPS)',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: _isRunning ? Colors.green[800] : Colors.purple[900],
                  ),
                ),
              ),
              Switch(
                value: _isRunning,
                activeColor: Colors.green,
                onChanged: (_) => _toggleFakeGps(),
              ),
            ],
          ),

          // Status bar
          Container(
            margin: const EdgeInsets.symmetric(vertical: 8),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: _isRunning ? Colors.green[50] : Colors.grey[100],
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: _isRunning ? Colors.green : Colors.grey[300]!,
              ),
            ),
            child: Row(
              children: [
                Icon(
                  _isRunning ? Icons.gps_fixed : Icons.gps_off,
                  size: 16,
                  color: _isRunning ? Colors.green : Colors.grey,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _isRunning
                        ? 'Đang giả lập: ${_latController.text}, ${_lngController.text}'
                        : 'Fake GPS đang tắt',
                    style: TextStyle(
                      color: _isRunning ? Colors.green[800] : Colors.grey[700],
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),

          // Cảnh báo quyền nếu chưa kích hoạt Mock Location App
          if (!_isMockEnabled && !_isRunning)
            Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.amber.shade50,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.amber.shade300),
              ),
              child: Row(
                children: [
                  Icon(Icons.info_outline, color: Colors.amber[900], size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Cần chọn app này làm "Ứng dụng vị trí giả lập" trong Cài đặt nhà phát triển.',
                      style: TextStyle(fontSize: 11, color: Colors.amber[900]),
                    ),
                  ),
                  const SizedBox(width: 4),
                  InkWell(
                    onTap: () => FakeGpsService.openDeveloperSettings(),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.amber[800],
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Text(
                        'Mở Cài đặt',
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

          // Tọa độ Inputs
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _latController,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                  decoration: InputDecoration(
                    labelText: 'Vĩ độ (Latitude)',
                    hintText: '21.028511',
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  ),
                  style: const TextStyle(fontSize: 13),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _lngController,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                  decoration: InputDecoration(
                    labelText: 'Kinh độ (Longitude)',
                    hintText: '105.854444',
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  ),
                  style: const TextStyle(fontSize: 13),
                ),
              ),
            ],
          ),

          const SizedBox(height: 10),

          // Nút lấy vị trí GPS thực tế hiện tại của máy
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _isFetchingLocation ? null : () => _fetchCurrentDeviceLocation(silent: false),
              icon: _isFetchingLocation
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.my_location, size: 18),
              label: Text(
                _isFetchingLocation ? 'Đang định vị GPS thực tế...' : '📍 Lấy vị trí GPS thực tế hiện tại của máy',
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
              ),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.teal[800],
                side: BorderSide(color: Colors.teal.shade300),
                backgroundColor: Colors.teal.shade50.withValues(alpha: 0.6),
                padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 8),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
            ),
          ),

          const SizedBox(height: 8),

          // Các nút công cụ thao tác vị trí: Kéo trên bản đồ & Lưu vị trí hiện tại
          Row(
            children: [
              // Nút Mở bản đồ kéo vị trí
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _openMapPicker,
                  icon: const Icon(Icons.map, size: 18),
                  label: const Text(
                    'Kéo trên bản đồ',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                  ),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.blue[800],
                    side: BorderSide(color: Colors.blue.shade300),
                    padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 8),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // Nút Lưu vị trí hiện tại
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _showSaveCurrentLocationDialog,
                  icon: const Icon(Icons.bookmark_add_outlined, size: 18),
                  label: const Text(
                    'Lưu vị trí này',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                  ),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.purple[800],
                    side: BorderSide(color: Colors.purple.shade300),
                    padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 8),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 12),

          // Danh sách vị trí cá nhân đã lưu
          Row(
            children: [
              Icon(Icons.bookmarks, size: 16, color: Colors.purple[700]),
              const SizedBox(width: 6),
              const Text(
                'Vị trí cá nhân đã lưu:',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.black87),
              ),
              const Spacer(),
              if (_savedLocations.isNotEmpty)
                Text(
                  '(${_savedLocations.length})',
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
            ],
          ),
          const SizedBox(height: 8),

          if (_savedLocations.isEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
              decoration: BoxDecoration(
                color: Colors.grey[50],
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.grey.shade200),
              ),
              child: Column(
                children: const [
                  Icon(Icons.location_off_outlined, size: 24, color: Colors.grey),
                  SizedBox(height: 4),
                  Text(
                    'Chưa có vị trí cá nhân nào được lưu.',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  SizedBox(height: 2),
                  Text(
                    'Bấm "Kéo trên bản đồ" hoặc "Lưu vị trí này" để tạo vị trí thường dùng.',
                    style: TextStyle(fontSize: 11, color: Colors.blueGrey),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            )
          else
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 180),
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: _savedLocations.length,
                separatorBuilder: (_, __) => const SizedBox(height: 6),
                itemBuilder: (context, index) {
                  final loc = _savedLocations[index];
                  final isCurrentSelected =
                      _latController.text == loc.latitude.toStringAsFixed(6) &&
                      _lngController.text == loc.longitude.toStringAsFixed(6);

                  return InkWell(
                    onTap: () => _applySavedLocation(loc),
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      decoration: BoxDecoration(
                        color: isCurrentSelected ? Colors.purple.shade50 : Colors.grey.shade50,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: isCurrentSelected ? Colors.purple.shade300 : Colors.grey.shade300,
                          width: isCurrentSelected ? 1.5 : 1,
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            isCurrentSelected ? Icons.check_circle : Icons.location_pin,
                            size: 18,
                            color: isCurrentSelected ? Colors.purple[700] : Colors.grey[700],
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  loc.name,
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.bold,
                                    color: isCurrentSelected ? Colors.purple[900] : Colors.black87,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  '${loc.latitude.toStringAsFixed(6)}, ${loc.longitude.toStringAsFixed(6)}',
                                  style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.delete_outline, size: 18, color: Colors.redAccent),
                            tooltip: 'Xóa vị trí',
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                            onPressed: () => _deleteLocation(loc),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),

          const SizedBox(height: 14),

          // Nút Bật / Tắt chính
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _toggleFakeGps,
              icon: Icon(_isRunning ? Icons.stop_circle_outlined : Icons.play_circle_outline, size: 20),
              label: Text(_isRunning ? 'Dừng Fake GPS' : 'Kích hoạt Fake GPS'),
              style: ElevatedButton.styleFrom(
                backgroundColor: _isRunning ? Colors.red[700] : Colors.purple[700],
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 11),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
