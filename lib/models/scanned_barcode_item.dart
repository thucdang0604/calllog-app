class ScannedBarcodeItem {
  final String id;
  final String code;
  final String format;
  final int timestamp;
  final String? imagePath;

  const ScannedBarcodeItem({
    required this.id,
    required this.code,
    required this.format,
    required this.timestamp,
    this.imagePath,
  });

  bool get isQrCode => format.toLowerCase().contains('qr');

  bool get hasImage => imagePath != null && imagePath!.isNotEmpty;

  ScannedBarcodeItem copyWith({
    String? id,
    String? code,
    String? format,
    int? timestamp,
    String? imagePath,
    bool clearImagePath = false,
  }) {
    return ScannedBarcodeItem(
      id: id ?? this.id,
      code: code ?? this.code,
      format: format ?? this.format,
      timestamp: timestamp ?? this.timestamp,
      imagePath: clearImagePath ? null : (imagePath ?? this.imagePath),
    );
  }

  String get formattedDateTime {
    final dt = DateTime.fromMillisecondsSinceEpoch(timestamp);
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
    );
  }
}

