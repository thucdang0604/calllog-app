class ScannedBarcodeItem {
  final String id;
  final String code;
  final String format;
  final int timestamp;
  final String? imagePath;
  final int? sharedAt;

  const ScannedBarcodeItem({
    required this.id,
    required this.code,
    required this.format,
    required this.timestamp,
    this.imagePath,
    this.sharedAt,
  });

  bool get isQrCode => format.toLowerCase().contains('qr');

  bool get hasImage => imagePath != null && imagePath!.isNotEmpty;

  bool get isShared => sharedAt != null;

  String? get formattedSharedTime {
    if (sharedAt == null) return null;
    final dt = DateTime.fromMillisecondsSinceEpoch(sharedAt!);
    final hour = dt.hour.toString().padLeft(2, '0');
    final minute = dt.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  DateTime get localDateTime => DateTime.fromMillisecondsSinceEpoch(timestamp);

  DateTime get localDateOnly {
    final dt = localDateTime;
    return DateTime(dt.year, dt.month, dt.day);
  }

  String get localDateKey {
    final dt = localDateTime;
    final month = dt.month.toString().padLeft(2, '0');
    final day = dt.day.toString().padLeft(2, '0');
    return '${dt.year}-$month-$day';
  }

  String get formattedDateLabel {
    final dt = localDateTime;
    final day = dt.day.toString().padLeft(2, '0');
    final month = dt.month.toString().padLeft(2, '0');
    return '$day/$month/${dt.year}';
  }

  bool isSameLocalDate(DateTime reference) {
    final dt = localDateTime;
    return dt.year == reference.year &&
        dt.month == reference.month &&
        dt.day == reference.day;
  }

  ScannedBarcodeItem copyWith({
    String? id,
    String? code,
    String? format,
    int? timestamp,
    String? imagePath,
    bool clearImagePath = false,
    int? sharedAt,
    bool clearSharedAt = false,
  }) {
    return ScannedBarcodeItem(
      id: id ?? this.id,
      code: code ?? this.code,
      format: format ?? this.format,
      timestamp: timestamp ?? this.timestamp,
      imagePath: clearImagePath ? null : (imagePath ?? this.imagePath),
      sharedAt: clearSharedAt ? null : (sharedAt ?? this.sharedAt),
    );
  }

  String get formattedDateTime {
    final dt = localDateTime;
    final hour = dt.hour.toString().padLeft(2, '0');
    final minute = dt.minute.toString().padLeft(2, '0');
    final second = dt.second.toString().padLeft(2, '0');
    final day = dt.day.toString().padLeft(2, '0');
    final month = dt.month.toString().padLeft(2, '0');
    final year = dt.year;
    return '$hour:$minute:$second · $day/$month/$year';
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'code': code,
        'format': format,
        'timestamp': timestamp,
        if (hasImage) 'imagePath': imagePath,
        if (sharedAt != null) 'sharedAt': sharedAt,
      };

  factory ScannedBarcodeItem.fromJson(Map<String, dynamic> json) {
    final rawImagePath = json['imagePath']?.toString().trim();
    return ScannedBarcodeItem(
      id: json['id']?.toString() ??
          '${json['code']}_${json['timestamp'] ?? DateTime.now().millisecondsSinceEpoch}',
      code: json['code']?.toString().trim() ?? '',
      format: json['format']?.toString().trim() ?? 'Barcode',
      timestamp: (json['timestamp'] as num?)?.toInt() ??
          DateTime.now().millisecondsSinceEpoch,
      imagePath: (rawImagePath != null && rawImagePath.isNotEmpty)
          ? rawImagePath
          : null,
      sharedAt: (json['sharedAt'] as num?)?.toInt(),
    );
  }
}
