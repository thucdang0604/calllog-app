import 'package:shared_preferences/shared_preferences.dart';
import '../models/saved_location.dart';

class SavedLocationService {
  static const String _key = 'user_saved_locations';

  /// Lấy danh sách vị trí cá nhân đã lưu
  static Future<List<SavedLocation>> getSavedLocations() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final List<String>? jsonList = prefs.getStringList(_key);
      if (jsonList == null || jsonList.isEmpty) {
        return [];
      }
      return jsonList
          .map((item) => SavedLocation.fromJson(item))
          .toList();
    } catch (e) {
      return [];
    }
  }

  /// Lưu một vị trí cá nhân mới
  static Future<bool> saveLocation({
    required String name,
    required double latitude,
    required double longitude,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final locations = await getSavedLocations();

      final newLoc = SavedLocation(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        name: name.trim().isEmpty ? 'Vị trí (${latitude.toStringAsFixed(4)}, ${longitude.toStringAsFixed(4)})' : name.trim(),
        latitude: latitude,
        longitude: longitude,
      );

      // Thêm lên đầu danh sách
      locations.insert(0, newLoc);

      final List<String> jsonList =
          locations.map((loc) => loc.toJson()).toList();
      return await prefs.setStringList(_key, jsonList);
    } catch (e) {
      return false;
    }
  }

  /// Xóa một vị trí đã lưu theo id
  static Future<bool> deleteLocation(String id) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final locations = await getSavedLocations();
      locations.removeWhere((loc) => loc.id == id);
      final List<String> jsonList =
          locations.map((loc) => loc.toJson()).toList();
      return await prefs.setStringList(_key, jsonList);
    } catch (e) {
      return false;
    }
  }
}
