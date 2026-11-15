class CallRecordingItem {
  final String id;
  final String filePath;
  final String phoneNumber;
  final String normalizedNumber;
  final String contactName;
  final int callType;
  final int callLogId;
  final int startedAtMs;
  final int endedAtMs;
  final int durationMs;
  final int fileSizeBytes;
  final String audioSource;
  final int peakAmplitude;

  const CallRecordingItem({
    required this.id,
    required this.filePath,
    required this.phoneNumber,
    required this.normalizedNumber,
    required this.contactName,
    required this.callType,
    required this.callLogId,
    required this.startedAtMs,
    required this.endedAtMs,
    required this.durationMs,
    required this.fileSizeBytes,
    required this.audioSource,
    this.peakAmplitude = -1,
  });

  factory CallRecordingItem.fromMap(Map<dynamic, dynamic> map) {
    return CallRecordingItem(
      id: (map['id'] ?? '').toString(),
      filePath: (map['filePath'] ?? '').toString(),
      phoneNumber: (map['phoneNumber'] ?? '').toString(),
      normalizedNumber: (map['normalizedNumber'] ?? '').toString(),
      contactName: (map['contactName'] ?? '').toString(),
      callType: _asInt(map['callType'], 1),
      callLogId: _asInt(map['callLogId'], -1),
      startedAtMs: _asInt(map['startedAt'], 0),
      endedAtMs: _asInt(map['endedAt'], 0),
      durationMs: _asInt(map['durationMs'], 0),
      fileSizeBytes: _asInt(map['fileSizeBytes'], 0),
      audioSource: (map['audioSource'] ?? 'VOICE_RECOGNITION').toString(),
      peakAmplitude: _asInt(map['peakAmplitude'], -1),
    );
  }

  DateTime get startedAt => DateTime.fromMillisecondsSinceEpoch(startedAtMs);
  DateTime get endedAt => DateTime.fromMillisecondsSinceEpoch(endedAtMs);

  bool get isIncoming => callType == 1;
  bool get isOutgoing => callType == 2;
  bool get isSilentRecording => peakAmplitude == 0;

  String get displayTitle {
    final cleanName = contactName.trim();
    if (cleanName.isNotEmpty) return cleanName;
    final cleanPhone = phoneNumber.trim();
    if (cleanPhone.isNotEmpty) return cleanPhone;
    return 'Số không xác định';
  }

  String get callTypeLabel {
    switch (callType) {
      case 1:
        return 'Cuộc gọi đến';
      case 2:
        return 'Cuộc gọi đi';
      case 3:
        return 'Cuộc gọi nhỡ';
      default:
        return 'Cuộc gọi';
    }
  }

  String get formattedDuration => formatDurationMs(durationMs);

  String get formattedFileSize => formatFileSizeBytes(fileSizeBytes);

  String get formattedDateTime {
    final dt = startedAt;
    final day = dt.day.toString().padLeft(2, '0');
    final month = dt.month.toString().padLeft(2, '0');
    final year = dt.year.toString();
    final hour = dt.hour.toString().padLeft(2, '0');
    final minute = dt.minute.toString().padLeft(2, '0');
    return '$day/$month/$year $hour:$minute';
  }

  String get formattedTimeOnly {
    final dt = startedAt;
    final hour = dt.hour.toString().padLeft(2, '0');
    final minute = dt.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  int get daysRemainingBeforeAutoDelete {
    final expiresAtMs = startedAtMs + const Duration(days: 30).inMilliseconds;
    final remainingMs = expiresAtMs - DateTime.now().millisecondsSinceEpoch;
    if (remainingMs <= 0) return 0;
    return (remainingMs / const Duration(days: 1).inMilliseconds).ceil();
  }

  static String formatDurationMs(int ms) {
    if (ms <= 0) return '00:00';
    final totalSeconds = (ms / 1000).round();
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    final seconds = totalSeconds % 60;
    if (hours > 0) {
      return '$hours:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  static String formatFileSizeBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(0)} KB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  static String normalizePhone(String? raw) {
    if (raw == null || raw.trim().isEmpty) return '';
    final digits = raw.replaceAll(RegExp(r'\D'), '');
    if (digits.isEmpty) return '';
    final local = (digits.startsWith('84') && digits.length >= 10)
        ? '0${digits.substring(2)}'
        : digits;
    return local.length > 10 ? local.substring(local.length - 9) : local;
  }

  static String audioSourceDisplayLabel(String key) {
    switch (key.toLowerCase()) {
      case 'mic':
        return 'Microphone thường (MIC)';
      case 'camcorder':
        return 'Camcorder Mic (Loa ngoài / ít lọc âm)';
      case 'voice_recognition':
        return 'Voice Recognition';
      case 'voice_communication':
        return 'Voice Communication (VoIP/Loa thoại)';
      case 'voice_call':
        return 'Voice Call (Thu 2 chiều hệ thống)';
      case 'auto':
      default:
        return 'Tự động (Thử MIC -> Camcorder -> Voice Recognition)';
    }
  }

  static int _asInt(dynamic value, [int fallback = 0]) {
    if (value == null) return fallback;
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value.toString()) ?? fallback;
  }
}

class CallPlaybackState {
  final String status;
  final String filePath;
  final int positionMs;
  final int durationMs;

  const CallPlaybackState({
    required this.status,
    required this.filePath,
    required this.positionMs,
    required this.durationMs,
  });

  const CallPlaybackState.idle()
      : status = 'idle',
        filePath = '',
        positionMs = 0,
        durationMs = 0;

  factory CallPlaybackState.fromMap(Map<dynamic, dynamic> map) {
    return CallPlaybackState(
      status: (map['status'] ?? 'idle').toString(),
      filePath: (map['filePath'] ?? '').toString(),
      positionMs: CallRecordingItem._asInt(map['positionMs'], 0),
      durationMs: CallRecordingItem._asInt(map['durationMs'], 0),
    );
  }

  bool get isPlaying => status == 'playing';
  bool get isPaused => status == 'paused';
  bool get isActive => (isPlaying || isPaused) && filePath.isNotEmpty;

  bool isPlayingFile(String path) => isPlaying && filePath == path;
  bool isActiveFile(String path) => isActive && filePath == path;

  double get progress {
    if (durationMs <= 0) return 0.0;
    return (positionMs / durationMs).clamp(0.0, 1.0);
  }
}

