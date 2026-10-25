import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:permission_handler/permission_handler.dart';
import '../services/saved_location_service.dart';
import '../services/fake_gps_service.dart';

class MapLocationPickerScreen extends StatefulWidget {
  final double initialLatitude;
  final double initialLongitude;
  final String? initialName;

  const MapLocationPickerScreen({
    super.key,
    required this.initialLatitude,
    required this.initialLongitude,
    this.initialName,
  });

  @override
  State<MapLocationPickerScreen> createState() => _MapLocationPickerScreenState();
}

class _MapLocationPickerScreenState extends State<MapLocationPickerScreen> {
  late final MapController _mapController;
  late double _currentLat;
  late double _currentLng;
  double _currentZoom = 15.0;
  int _mapTypeIndex = 0; // 0: Google Roadmap, 1: Google Hybrid/Satellite, 2: CartoDB Voyager
  bool _isLocating = false;

  String get _urlTemplate {
    switch (_mapTypeIndex) {
      case 1:
        return 'https://mt{s}.google.com/vt/lyrs=y&x={x}&y={y}&z={z}';
      case 2:
        return 'https://{s}.basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}.png';
      default:
        return 'https://mt{s}.google.com/vt/lyrs=m&x={x}&y={y}&z={z}';
    }
  }

  List<String> get _subdomains {
    if (_mapTypeIndex == 2) {
      return const ['a', 'b', 'c', 'd'];
    }
    return const ['0', '1', '2', '3'];
  }

  @override
  void initState() {
    super.initState();
    _mapController = MapController();
    _currentLat = widget.initialLatitude;
    _currentLng = widget.initialLongitude;

    // Đảm bảo tọa độ hợp lệ
    if (_currentLat < -90 || _currentLat > 90 || _currentLat == 0.0) {
      _currentLat = 21.028511; // Dự phòng
    }
    if (_currentLng < -180 || _currentLng > 180 || _currentLng == 0.0) {
      _currentLng = 105.854444;
    }

    // Nếu toạ độ đang là Hà Nội mặc định, tự động dò vị trí GPS thực tế của máy ngay khi mở
    if ((_currentLat == 21.028511 && _currentLng == 105.854444) ||
        widget.initialLatitude == 0.0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _goToCurrentDeviceLocation(silent: true);
      });
    }
  }

  Future<void> _goToCurrentDeviceLocation({bool silent = false}) async {
    if (_isLocating) return;
    setState(() => _isLocating = true);

    try {
      await Permission.location.request();
      final loc = await FakeGpsService.getCurrentDeviceLocation();

      if (loc != null && mounted) {
        final lat = loc['latitude']!;
        final lng = loc['longitude']!;
        setState(() {
          _currentLat = lat;
          _currentLng = lng;
          _currentZoom = 16.0;
        });
        _mapController.move(LatLng(lat, lng), 16.0);

        if (!silent && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('📍 Đã chuyển tới vị trí GPS thực tế: ${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}'),
              backgroundColor: Colors.green,
              duration: const Duration(seconds: 2),
            ),
          );
        }
      } else if (!silent && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('⚠️ Không thể lấy vị trí GPS. Hãy bật dịch vụ định vị (Vị trí/GPS) trên điện thoại.'),
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
        setState(() => _isLocating = false);
      }
    }
  }

  @override
  void dispose() {
    _mapController.dispose();
    super.dispose();
  }

  void _zoomIn() {
    setState(() {
      _currentZoom = (_currentZoom + 1).clamp(4.0, 19.0);
    });
    _mapController.move(LatLng(_currentLat, _currentLng), _currentZoom);
  }

  void _zoomOut() {
    setState(() {
      _currentZoom = (_currentZoom - 1).clamp(4.0, 19.0);
    });
    _mapController.move(LatLng(_currentLat, _currentLng), _currentZoom);
  }

  void _applyLocation() {
    Navigator.of(context).pop({
      'latitude': _currentLat,
      'longitude': _currentLng,
    });
  }

  Future<void> _showSaveLocationDialog() async {
    final nameController = TextEditingController(text: widget.initialName ?? '');

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
              'Đặt tên để dễ dàng chọn lại vị trí này:',
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
              'Tọa độ: ${_currentLat.toStringAsFixed(6)}, ${_currentLng.toStringAsFixed(6)}',
              style: const TextStyle(fontSize: 11, color: Colors.blueGrey),
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
        latitude: _currentLat,
        longitude: _currentLng,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('✅ Đã lưu "$name" vào danh sách cá nhân'),
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 2),
          ),
        );

        // Trả kết quả về
        Navigator.of(context).pop({
          'latitude': _currentLat,
          'longitude': _currentLng,
          'name': name,
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Kéo bản đồ chọn vị trí',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 17),
        ),
        backgroundColor: Colors.blue[700],
        foregroundColor: Colors.white,
        elevation: 2,
        actions: [
          PopupMenuButton<int>(
            icon: const Icon(Icons.layers_outlined),
            tooltip: 'Đổi kiểu bản đồ',
            onSelected: (val) {
              setState(() => _mapTypeIndex = val);
            },
            itemBuilder: (ctx) => [
              const PopupMenuItem(
                value: 0,
                child: Row(
                  children: [
                    Icon(Icons.map_outlined, color: Colors.blue),
                    SizedBox(width: 8),
                    Text('Bản đồ đường đi'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 1,
                child: Row(
                  children: [
                    Icon(Icons.satellite_alt, color: Colors.teal),
                    SizedBox(width: 8),
                    Text('Bản đồ vệ tinh'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 2,
                child: Row(
                  children: [
                    Icon(Icons.terrain, color: Colors.orange),
                    SizedBox(width: 8),
                    Text('Bản đồ CartoDB'),
                  ],
                ),
              ),
            ],
          ),
          IconButton(
            icon: _isLocating
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : const Icon(Icons.my_location),
            tooltip: 'Lấy vị trí GPS thực tế hiện tại',
            onPressed: () => _goToCurrentDeviceLocation(silent: false),
          ),
        ],
      ),
      body: Stack(
        children: [
          // Bản đồ OpenStreetMap / Google siêu nhẹ thuần Dart
          FlutterMap(
            key: ValueKey('map_type_$_mapTypeIndex'),
            mapController: _mapController,
            options: MapOptions(
              initialCenter: LatLng(_currentLat, _currentLng),
              initialZoom: _currentZoom,
              minZoom: 4.0,
              maxZoom: 20.0,
              onPositionChanged: (camera, hasGesture) {
                setState(() {
                  _currentLat = camera.center.latitude;
                  _currentLng = camera.center.longitude;
                  _currentZoom = camera.zoom;
                });
              },
            ),
            children: [
              TileLayer(
                urlTemplate: _urlTemplate,
                subdomains: _subdomains,
                fallbackUrl: 'https://{s}.basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}.png',
                maxZoom: 20,
              ),
            ],
          ),

          // Ghim định vị cố định ở tâm màn hình với bóng đổ
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Icon ghim nổi bật
                Transform.translate(
                  offset: const Offset(0, -20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          color: Colors.red[600],
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 2),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.3),
                              blurRadius: 8,
                              offset: const Offset(0, 3),
                            ),
                          ],
                        ),
                        child: const Icon(
                          Icons.location_on,
                          color: Colors.white,
                          size: 28,
                        ),
                      ),
                      // Tâm chạm đất
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.6),
                          shape: BoxShape.circle,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // Header Card hiển thị tọa độ thời gian thực
          Positioned(
            top: 12,
            left: 12,
            right: 12,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.95),
                borderRadius: BorderRadius.circular(12),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.15),
                    blurRadius: 10,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Row(
                children: [
                  const Icon(Icons.gps_fixed, color: Colors.redAccent, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text(
                          'Kéo bản đồ để đặt tâm ghim vào vị trí mong muốn:',
                          style: TextStyle(
                            fontSize: 11,
                            color: Colors.grey,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${_currentLat.toStringAsFixed(6)}, ${_currentLng.toStringAsFixed(6)}',
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            color: Colors.black87,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Nút Định vị GPS & Zoom (+ / -) bên phải
          Positioned(
            right: 16,
            bottom: 110,
            child: Column(
              children: [
                FloatingActionButton.small(
                  heroTag: 'my_location_btn',
                  backgroundColor: Colors.white,
                  foregroundColor: Colors.blue[700],
                  elevation: 4,
                  tooltip: 'Về vị trí GPS thực tế hiện tại',
                  onPressed: () => _goToCurrentDeviceLocation(silent: false),
                  child: _isLocating
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.blue),
                        )
                      : const Icon(Icons.my_location, size: 20),
                ),
                const SizedBox(height: 10),
                FloatingActionButton.small(
                  heroTag: 'zoom_in_btn',
                  backgroundColor: Colors.white,
                  foregroundColor: Colors.black87,
                  elevation: 3,
                  onPressed: _zoomIn,
                  child: const Icon(Icons.add),
                ),
                const SizedBox(height: 8),
                FloatingActionButton.small(
                  heroTag: 'zoom_out_btn',
                  backgroundColor: Colors.white,
                  foregroundColor: Colors.black87,
                  elevation: 3,
                  onPressed: _zoomOut,
                  child: const Icon(Icons.remove),
                ),
              ],
            ),
          ),

          // Thanh điều khiển bên dưới: Chọn & Lưu
          Positioned(
            left: 12,
            right: 12,
            bottom: 16,
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.2),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Row(
                children: [
                  // Nút Lưu vị trí cá nhân
                  Expanded(
                    flex: 1,
                    child: OutlinedButton.icon(
                      onPressed: _showSaveLocationDialog,
                      icon: const Icon(Icons.bookmark_border, size: 18),
                      label: const Text(
                        'Lưu vị trí',
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                      ),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.purple[700],
                        side: BorderSide(color: Colors.purple.shade400, width: 1.5),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  // Nút Chọn vị trí này
                  Expanded(
                    flex: 1,
                    child: ElevatedButton.icon(
                      onPressed: _applyLocation,
                      icon: const Icon(Icons.check, size: 18),
                      label: const Text(
                        'Dùng vị trí này',
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blue[700],
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        elevation: 2,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
