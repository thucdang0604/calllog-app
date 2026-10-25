import 'dart:convert';

class SavedLocation {
  final String id;
  final String name;
  final double latitude;
  final double longitude;
  final int createdAt;

  SavedLocation({
    required this.id,
    required this.name,
    required this.latitude,
    required this.longitude,
    int? createdAt,
  }) : createdAt = createdAt ?? DateTime.now().millisecondsSinceEpoch;

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'latitude': latitude,
      'longitude': longitude,
      'createdAt': createdAt,
    };
  }

  factory SavedLocation.fromMap(Map<String, dynamic> map) {
    return SavedLocation(
      id: map['id']?.toString() ?? '',
      name: map['name']?.toString() ?? '',
      latitude: (map['latitude'] as num?)?.toDouble() ?? 0.0,
      longitude: (map['longitude'] as num?)?.toDouble() ?? 0.0,
      createdAt: map['createdAt'] is int ? map['createdAt'] : 0,
    );
  }

  String toJson() => json.encode(toMap());

  factory SavedLocation.fromJson(String source) =>
      SavedLocation.fromMap(json.decode(source));
}
