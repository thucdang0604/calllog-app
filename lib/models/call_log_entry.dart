class CallLogEntry {
  final int? id; // ID của cuộc gọi
  final String? number;
  final String? name;
  final String? formattedNumber;
  final int duration; // Thời gian trò chuyện (giây)
  final int ringDuration; // Thời gian đổ chuông (giây)
  final int timestamp; // Thời gian gọi
  final int callType; // 1: Incoming, 2: Outgoing, 3: Missed

  CallLogEntry({
    this.id,
    this.number,
    this.name,
    this.formattedNumber,
    required this.duration,
    this.ringDuration = 0,
    required this.timestamp,
    required this.callType,
  });

  factory CallLogEntry.fromMap(Map<String, dynamic> map) {
    return CallLogEntry(
      id: map['id']?.toInt(),
      number: map['number']?.toString(),
      name: map['name']?.toString(),
      formattedNumber: map['formattedNumber']?.toString(),
      duration: map['duration']?.toInt() ?? 0,
      ringDuration: map['ringDuration']?.toInt() ?? map['ring_duration']?.toInt() ?? 0,
      timestamp: map['timestamp']?.toInt() ?? 0,
      callType: map['callType']?.toInt() ?? 1,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'number': number,
      'name': name,
      'formattedNumber': formattedNumber,
      'duration': duration,
      'ringDuration': ringDuration,
      'timestamp': timestamp,
      'callType': callType,
    };
  }

  CallLogEntry copyWith({
    int? id,
    String? number,
    String? name,
    String? formattedNumber,
    int? duration,
    int? ringDuration,
    int? timestamp,
    int? callType,
  }) {
    return CallLogEntry(
      id: id ?? this.id,
      number: number ?? this.number,
      name: name ?? this.name,
      formattedNumber: formattedNumber ?? this.formattedNumber,
      duration: duration ?? this.duration,
      ringDuration: ringDuration ?? this.ringDuration,
      timestamp: timestamp ?? this.timestamp,
      callType: callType ?? this.callType,
    );
  }

  String get callTypeText {
    switch (callType) {
      case 1:
        return 'Incoming';
      case 2:
        return 'Outgoing';
      case 3:
        return 'Missed';
      default:
        return 'Unknown';
    }
  }

  String get ringDurationFormatted {
    if (ringDuration == 0) return '0s';
    int minutes = ringDuration ~/ 60;
    int seconds = ringDuration % 60;
    if (minutes > 0) {
      return '${minutes}m${seconds.toString().padLeft(2, '0')}s';
    } else {
      return '${seconds}s';
    }
  }

  String get talkDurationFormatted => durationFormatted;

  String get durationFormatted {
    if (duration == 0) return '0s';

    int hours = duration ~/ 3600;
    int minutes = (duration % 3600) ~/ 60;
    int seconds = duration % 60;

    if (hours > 0) {
      return '${hours}h${minutes.toString().padLeft(2, '0')}m';
    } else if (minutes > 0) {
      return '${minutes}m${seconds.toString().padLeft(2, '0')}s';
    } else {
      return '${seconds}s';
    }
  }

  String get dateFormatted {
    final date = DateTime.fromMillisecondsSinceEpoch(timestamp);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final callDate = DateTime(date.year, date.month, date.day);

    if (callDate == today) {
      return '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
    } else if (callDate == today.subtract(const Duration(days: 1))) {
      return 'Hôm qua ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
    } else {
      return '${date.day}/${date.month} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
    }
  }
}
