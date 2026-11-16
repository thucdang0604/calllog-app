import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';

import '../models/call_log_entry.dart';
import '../models/call_recording_item.dart';

class SystemCallRecSyncStatus {
  final bool hasTreePermission;
  final bool hasMediaPermission;
  final bool isReady;
  final String folderLabel;
  final int lastSyncMs;
  final int lastImportedCount;
  final String lastError;
  final String suggestedFolder;

  const SystemCallRecSyncStatus({
    this.hasTreePermission = false,
    this.hasMediaPermission = false,
    this.isReady = false,
    this.folderLabel = '',
    this.lastSyncMs = 0,
    this.lastImportedCount = 0,
    this.lastError = '',
    this.suggestedFolder = 'MIUI/sound_recorder/call_rec',
  });

  factory SystemCallRecSyncStatus.fromMap(Map<dynamic, dynamic>? map) {
    if (map == null) return const SystemCallRecSyncStatus();
    return SystemCallRecSyncStatus(
      hasTreePermission: map['hasTreePermission'] == true,
      hasMediaPermission: map['hasMediaPermission'] == true,
      isReady: map['isReady'] == true,
      folderLabel: (map['folderLabel'] ?? '').toString(),
      lastSyncMs: _toInt(map['lastSyncMs']),
      lastImportedCount: _toInt(map['lastImportedCount']),
      lastError: (map['lastError'] ?? '').toString(),
      suggestedFolder:
          (map['suggestedFolder'] ?? 'MIUI/sound_recorder/call_rec').toString(),
    );
  }

  static int _toInt(dynamic v) =>
      v is int ? v : (v is num ? v.toInt() : int.tryParse('$v') ?? 0);
}

class CallRecordingDiagnostic {
  final int timestampMs;
  final String audioSource;
  final String attemptedSources;
  final bool silencedBySystem;
  final int peakAmplitude;
  final int audioMode;
  final bool speakerOn;
  final String reason;
  final String status;
  final String brand;
  final String model;
  final int sdkInt;

  const CallRecordingDiagnostic({
    this.timestampMs = 0,
    this.audioSource = '',
    this.attemptedSources = '',
    this.silencedBySystem = false,
    this.peakAmplitude = -1,
    this.audioMode = 0,
    this.speakerOn = false,
    this.reason = '',
    this.status = '',
    this.brand = '',
    this.model = '',
    this.sdkInt = 0,
  });

  factory CallRecordingDiagnostic.fromMap(Map<dynamic, dynamic>? map) {
    if (map == null) return const CallRecordingDiagnostic();
    int toInt(dynamic v, [int fb = 0]) =>
        v is int ? v : (v is num ? v.toInt() : int.tryParse('$v') ?? fb);
    return CallRecordingDiagnostic(
      timestampMs: toInt(map['timestampMs']),
      audioSource: (map['audioSource'] ?? '').toString(),
      attemptedSources: (map['attemptedSources'] ?? '').toString(),
      silencedBySystem: map['silencedBySystem'] == true,
      peakAmplitude: toInt(map['peakAmplitude'], -1),
      audioMode: toInt(map['audioMode']),
      speakerOn: map['speakerOn'] == true,
      reason: (map['reason'] ?? '').toString(),
      status: (map['status'] ?? '').toString(),
      brand: (map['brand'] ?? '').toString(),
      model: (map['model'] ?? '').toString(),
      sdkInt: toInt(map['sdkInt']),
    );
  }

  bool get hasAttempt => timestampMs > 0 && (audioSource.isNotEmpty || status.isNotEmpty);
}

class CallRecordingEvent {
  final String type;
  final CallPlaybackState? playbackState;

  const CallRecordingEvent({
    required this.type,
    this.playbackState,
  });
}

class CallRecordingService {
  static const MethodChannel _channel = MethodChannel('call_log_manager');
  static const EventChannel _eventChannel = EventChannel(
    'call_log_manager/call_recording_events',
  );

  static Stream<CallRecordingEvent>? _broadcastStream;

  static Stream<CallRecordingEvent> get events {
    _broadcastStream ??= _eventChannel
        .receiveBroadcastStream()
        .map<CallRecordingEvent?>((dynamic raw) {
          if (raw is! Map) return null;
          final type = (raw['type'] ?? '').toString();
          if (type == 'playback') {
            return CallRecordingEvent(
              type: type,
              playbackState: CallPlaybackState.fromMap(raw),
            );
          }
          if (type.isNotEmpty) {
            return CallRecordingEvent(type: type);
          }
          return null;
        })
        .where((event) => event != null)
        .cast<CallRecordingEvent>()
        .asBroadcastStream();
    return _broadcastStream!;
  }

  static Future<bool> hasPermissions() async {
    try {
      final result = await _channel.invokeMethod<bool>(
        'hasCallRecordingPermissions',
      );
      return result ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> requestPermissions() async {
    try {
      final result = await _channel.invokeMethod<bool>(
        'requestCallRecordingPermissions',
      );
      return result ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> hasOverlayPermission() async {
    try {
      final result = await _channel.invokeMethod<bool>(
        'hasOverlayPermission',
      );
      return result ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> openOverlaySettings() async {
    try {
      final result = await _channel.invokeMethod<bool>(
        'openOverlaySettings',
      );
      return result ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> openAppDetailsSettings() async {
    try {
      final result = await _channel.invokeMethod<bool>(
        'openAppDetailsSettings',
      );
      return result ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<List<CallRecordingItem>> getRecordings() async {
    final rawList = await _channel.invokeMethod<List<dynamic>>(
      'getCallRecordings',
    );
    if (rawList == null) return const [];
    return rawList
        .whereType<Map<dynamic, dynamic>>()
        .map(CallRecordingItem.fromMap)
        .toList();
  }

  static Future<int> deleteRecordings(List<String> ids) async {
    if (ids.isEmpty) return 0;
    final removed = await _channel.invokeMethod<int>(
      'deleteCallRecordings',
      {'ids': ids},
    );
    return removed ?? 0;
  }

  static Future<int> deleteRecordingsOnDate(DateTime date) async {
    final start = DateTime(date.year, date.month, date.day);
    final end = DateTime(date.year, date.month, date.day, 23, 59, 59, 999);
    final removed = await _channel.invokeMethod<int>(
      'deleteCallRecordingsByDate',
      {
        'mode': 'on_date',
        'startMs': start.millisecondsSinceEpoch,
        'endMs': end.millisecondsSinceEpoch,
      },
    );
    return removed ?? 0;
  }

  static Future<int> deleteRecordingsBeforeDate(DateTime date) async {
    final end = DateTime(date.year, date.month, date.day, 23, 59, 59, 999);
    final removed = await _channel.invokeMethod<int>(
      'deleteCallRecordingsByDate',
      {
        'mode': 'before_date',
        'startMs': 0,
        'endMs': end.millisecondsSinceEpoch,
      },
    );
    return removed ?? 0;
  }

  static Future<bool> shareRecording(CallRecordingItem item) async {
    final result = await _channel.invokeMethod<bool>(
      'shareCallRecording',
      {
        'filePath': item.filePath,
        'title': '${item.displayTitle} (${item.formattedDateTime})',
      },
    );
    return result ?? false;
  }

  static Future<String> getAudioSource() async {
    try {
      final result = await _channel.invokeMethod<String>(
        'getCallRecordingAudioSource',
      );
      return (result == null || result.isEmpty) ? 'auto' : result;
    } catch (_) {
      return 'auto';
    }
  }

  static Future<bool> setAudioSource(String source) async {
    try {
      final result = await _channel.invokeMethod<bool>(
        'setCallRecordingAudioSource',
        {'source': source},
      );
      return result ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<CallPlaybackState> play(String filePath) async {
    final map = await _channel.invokeMethod<Map<dynamic, dynamic>>(
      'playCallRecording',
      {'filePath': filePath},
    );
    if (map == null) return const CallPlaybackState.idle();
    return CallPlaybackState.fromMap(map);
  }

  static Future<CallPlaybackState> pause() async {
    final map = await _channel.invokeMethod<Map<dynamic, dynamic>>(
      'pauseCallRecording',
    );
    if (map == null) return const CallPlaybackState.idle();
    return CallPlaybackState.fromMap(map);
  }

  static Future<CallPlaybackState> resume() async {
    final map = await _channel.invokeMethod<Map<dynamic, dynamic>>(
      'resumeCallRecording',
    );
    if (map == null) return const CallPlaybackState.idle();
    return CallPlaybackState.fromMap(map);
  }

  static Future<CallPlaybackState> seekTo(int positionMs) async {
    final map = await _channel.invokeMethod<Map<dynamic, dynamic>>(
      'seekCallRecording',
      {'positionMs': positionMs},
    );
    if (map == null) return const CallPlaybackState.idle();
    return CallPlaybackState.fromMap(map);
  }

  static Future<CallPlaybackState> stop() async {
    final map = await _channel.invokeMethod<Map<dynamic, dynamic>>(
      'stopCallRecording',
    );
    if (map == null) return const CallPlaybackState.idle();
    return CallPlaybackState.fromMap(map);
  }

  static Future<CallPlaybackState> getPlaybackState() async {
    try {
      final map = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'getCallRecordingPlaybackState',
      );
      if (map == null) return const CallPlaybackState.idle();
      return CallPlaybackState.fromMap(map);
    } catch (_) {
      return const CallPlaybackState.idle();
    }
  }

  static Future<CallRecordingDiagnostic> getDiagnostic() async {
    try {
      final map = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'getCallRecordingDiagnostic',
      );
      return CallRecordingDiagnostic.fromMap(map);
    } catch (_) {
      return const CallRecordingDiagnostic();
    }
  }

  static Future<SystemCallRecSyncStatus> getSystemSyncStatus() async {
    try {
      final map = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'getSystemCallRecSyncStatus',
      );
      return SystemCallRecSyncStatus.fromMap(map);
    } catch (_) {
      return const SystemCallRecSyncStatus();
    }
  }

  static Future<({int importedCount, int scannedCount, SystemCallRecSyncStatus status})?>
      pickSystemCallRecFolder() async {
    try {
      final map = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'pickSystemCallRecFolder',
      );
      if (map == null) return null;
      return (
        importedCount: SystemCallRecSyncStatus._toInt(map['importedCount']),
        scannedCount: SystemCallRecSyncStatus._toInt(map['scannedCount']),
        status: SystemCallRecSyncStatus.fromMap(
          map['status'] as Map<dynamic, dynamic>?,
        ),
      );
    } catch (_) {
      return null;
    }
  }

  static Future<bool> requestSystemMediaPermission() async {
    try {
      final granted = await _channel.invokeMethod<bool>(
        'requestSystemCallRecMediaPermission',
      );
      return granted ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<({int importedCount, int scannedCount, SystemCallRecSyncStatus status})>
      syncSystemRecordings() async {
    try {
      final map = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'syncSystemCallRecordings',
      );
      return (
        importedCount: SystemCallRecSyncStatus._toInt(map?['importedCount']),
        scannedCount: SystemCallRecSyncStatus._toInt(map?['scannedCount']),
        status: SystemCallRecSyncStatus.fromMap(
          map?['status'] as Map<dynamic, dynamic>?,
        ),
      );
    } catch (_) {
      return (
        importedCount: 0,
        scannedCount: 0,
        status: const SystemCallRecSyncStatus(),
      );
    }
  }

  static Future<SystemCallRecSyncStatus> clearSystemCallRecFolder() async {
    try {
      final map = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'clearSystemCallRecFolder',
      );
      return SystemCallRecSyncStatus.fromMap(map);
    } catch (_) {
      return const SystemCallRecSyncStatus();
    }
  }

  static CallRecordingItem? matchRecordingForCall(
    CallLogEntry call,
    List<CallRecordingItem> recordings,
  ) {
    if (recordings.isEmpty || call.duration <= 0) return null;

    final callId = call.id;
    if (callId != null && callId > 0) {
      for (final rec in recordings) {
        if (rec.callLogId == callId) {
          return rec;
        }
      }
    }

    // Cuộc gọi nhỡ hoặc cuộc gọi không phát sinh thoại bỏ qua fallback heuristic.
    if (call.callType == 3) {
      return null;
    }

    final callNorm = CallRecordingItem.normalizePhone(call.number);
    final callStartMs = call.timestamp;
    final talkMs = call.duration * 1000;
    final ringMs = call.ringDuration > 0 ? call.ringDuration * 1000 : 0;
    final endNoRingMs = callStartMs + talkMs;
    final endWithRingMs = callStartMs + talkMs + ringMs;
    final maxPossibleEndMs = math.max(endNoRingMs, endWithRingMs);

    CallRecordingItem? bestMatch;
    int bestScore = 1 << 60;

    for (final rec in recordings) {
      // Nếu file ghi âm đã gắn với callLogId khác thì không ghép nhầm sang cuộc gọi này.
      if (rec.callLogId > 0 &&
          callId != null &&
          callId > 0 &&
          rec.callLogId != callId) {
        continue;
      }

      final hasBothNumbers =
          callNorm.isNotEmpty && rec.normalizedNumber.isNotEmpty;
      if (hasBothNumbers && rec.normalizedNumber != callNorm) {
        continue;
      }
      if (callNorm.isNotEmpty && rec.normalizedNumber.isEmpty) {
        // Trường hợp số chưa kịp đồng bộ khi đang gọi: giới hạn cửa sổ thời gian chặt hơn.
        if (rec.startedAtMs < callStartMs - 15000 ||
            rec.startedAtMs > maxPossibleEndMs + 15000) {
          continue;
        }
      }

      if (rec.startedAtMs < callStartMs - 15000 ||
          rec.startedAtMs > maxPossibleEndMs + 25000 ||
          rec.startedAtMs - callStartMs > 180000) {
        continue;
      }

      final endDiffNoRing = (rec.endedAtMs - endNoRingMs).abs();
      final endDiffWithRing = (rec.endedAtMs - endWithRingMs).abs();
      final endDiff = math.min(endDiffNoRing, endDiffWithRing);
      if (endDiff > 60000) {
        continue;
      }

      final expectedStart =
          callStartMs + (call.callType == 1 ? ringMs : 0);
      final startDiff = (rec.startedAtMs - expectedStart).abs();
      final numberPenalty = (hasBothNumbers && rec.normalizedNumber == callNorm)
          ? 0
          : 25000;
      final score = endDiff + (startDiff ~/ 2) + numberPenalty;

      if (score < bestScore) {
        bestScore = score;
        bestMatch = rec;
      }
    }

    return bestMatch;
  }
}
