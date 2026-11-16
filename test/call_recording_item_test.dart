import 'package:flutter_test/flutter_test.dart';
import 'package:call_log_manager/models/call_log_entry.dart';
import 'package:call_log_manager/models/call_recording_item.dart';
import 'package:call_log_manager/services/call_recording_service.dart';

void main() {
  group('CallRecordingItem & CallPlaybackState', () {
    test('fromMap parses fields safely and selects displayTitle properly', () {
      final named = CallRecordingItem.fromMap({
        'id': 'rec_1',
        'filePath': '/data/user/0/app/files/call_recordings/call_1.m4a',
        'phoneNumber': '+84901234567',
        'normalizedNumber': '0901234567',
        'contactName': 'Anh Minh Shipper',
        'callType': 2,
        'callLogId': 42,
        'startedAt': 1700000000000,
        'endedAt': 1700000065000,
        'durationMs': 65000,
        'fileSizeBytes': 524288,
        'audioSource': 'VOICE_RECOGNITION',
      });

      expect(named.id, 'rec_1');
      expect(named.isOutgoing, isTrue);
      expect(named.isIncoming, isFalse);
      expect(named.displayTitle, 'Anh Minh Shipper');
      expect(named.callTypeLabel, 'Cuộc gọi đi');
      expect(named.formattedDuration, '01:05');
      expect(named.formattedFileSize, '512 KB');

      final unnamed = CallRecordingItem.fromMap({
        'id': 'rec_2',
        'phoneNumber': '0988777666',
        'contactName': '   ',
        'callType': 1,
        'durationMs': 3661000,
        'fileSizeBytes': 2 * 1024 * 1024,
      });
      expect(unnamed.isIncoming, isTrue);
      expect(unnamed.displayTitle, '0988777666');
      expect(unnamed.formattedDuration, '1:01:01');
      expect(unnamed.formattedFileSize, '2.0 MB');

      final blank = CallRecordingItem.fromMap({'id': 'rec_3'});
      expect(blank.displayTitle, 'Số không xác định');
      expect(blank.formattedDuration, '00:00');
      expect(blank.formattedFileSize, '0 B');
      expect(blank.peakAmplitude, -1);
      expect(blank.isSilentRecording, isFalse);

      final silenced = CallRecordingItem.fromMap({
        'id': 'rec_4',
        'audioSource': 'MIC',
        'peakAmplitude': 0,
      });
      expect(silenced.peakAmplitude, 0);
      expect(silenced.isSilentRecording, isTrue);
      expect(
        CallRecordingItem.audioSourceDisplayLabel('camcorder'),
        contains('Camcorder'),
      );
    });

    test('normalizePhone handles Vietnam +84, spaces, hyphens, and long prefixes', () {
      expect(CallRecordingItem.normalizePhone('+84 987-654-321'), '0987654321');
      expect(CallRecordingItem.normalizePhone('84987654321'), '0987654321');
      expect(CallRecordingItem.normalizePhone('0987 654 321'), '0987654321');
      expect(CallRecordingItem.normalizePhone(''), '');
      expect(CallRecordingItem.normalizePhone(null), '');
    });

    test('daysRemainingBeforeAutoDelete reflects 30-day retention', () {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final fresh = CallRecordingItem.fromMap({
        'id': 'fresh',
        'startedAt': nowMs - const Duration(hours: 1).inMilliseconds,
      });
      expect(fresh.daysRemainingBeforeAutoDelete, inInclusiveRange(29, 30));

      final expired = CallRecordingItem.fromMap({
        'id': 'expired',
        'startedAt': nowMs - const Duration(days: 31).inMilliseconds,
      });
      expect(expired.daysRemainingBeforeAutoDelete, 0);
    });

    test('CallPlaybackState active/playing helpers and progress bounds', () {
      const idle = CallPlaybackState.idle();
      expect(idle.isActive, isFalse);
      expect(idle.progress, 0.0);

      final playing = CallPlaybackState.fromMap({
        'status': 'playing',
        'filePath': '/tmp/a.m4a',
        'positionMs': 15000,
        'durationMs': 60000,
      });
      expect(playing.isPlaying, isTrue);
      expect(playing.isActive, isTrue);
      expect(playing.isPlayingFile('/tmp/a.m4a'), isTrue);
      expect(playing.isPlayingFile('/tmp/b.m4a'), isFalse);
      expect(playing.progress, closeTo(0.25, 0.0001));

      final clamped = CallPlaybackState.fromMap({
        'status': 'paused',
        'filePath': '/tmp/a.m4a',
        'positionMs': 90000,
        'durationMs': 60000,
      });
      expect(clamped.isPaused, isTrue);
      expect(clamped.isActiveFile('/tmp/a.m4a'), isTrue);
      expect(clamped.progress, 1.0);
    });
  });

  group('CallRecordingService.matchRecordingForCall', () {
    test('prefers exact callLogId match over heuristic timing', () {
      const baseTime = 1700000000000;
      final call = CallLogEntry(
        id: 105,
        number: '0901111222',
        duration: 30,
        ringDuration: 0,
        timestamp: baseTime,
        callType: 2,
      );

      final exactById = CallRecordingItem.fromMap({
        'id': 'r_exact',
        'filePath': '/tmp/exact.m4a',
        'phoneNumber': '0999888777',
        'normalizedNumber': '0999888777',
        'callLogId': 105,
        'startedAt': baseTime + 500000,
        'endedAt': baseTime + 530000,
      });
      final nearbyWrongId = CallRecordingItem.fromMap({
        'id': 'r_other',
        'filePath': '/tmp/other.m4a',
        'phoneNumber': '0901111222',
        'normalizedNumber': '0901111222',
        'callLogId': 104,
        'startedAt': baseTime,
        'endedAt': baseTime + 30000,
      });

      final matched = CallRecordingService.matchRecordingForCall(
        call,
        [nearbyWrongId, exactById],
      );
      expect(matched?.id, 'r_exact');
    });

    test('matches normalized phone + incoming ringDuration offset accurately', () {
      const baseTime = 1700000000000;
      // Cuộc gọi đến: đổ chuông 8s rồi nghe 45s -> kết thúc tại baseTime + 53s.
      final incomingCall = CallLogEntry(
        id: 201,
        number: '+84 912 345 678',
        duration: 45,
        ringDuration: 8,
        timestamp: baseTime,
        callType: 1,
      );

      final rec = CallRecordingItem.fromMap({
        'id': 'r_in',
        'filePath': '/tmp/in.m4a',
        'phoneNumber': '0912345678',
        'normalizedNumber': '0912345678',
        'callLogId': -1,
        'startedAt': baseTime + 8000,
        'endedAt': baseTime + 53500,
        'durationMs': 45500,
      });

      final matched = CallRecordingService.matchRecordingForCall(
        incomingCall,
        [rec],
      );
      expect(matched?.id, 'r_in');
    });

    test('skips missed calls and prevents binding recording owned by another callLogId', () {
      const baseTime = 1700000000000;
      final missedCall = CallLogEntry(
        id: 300,
        number: '0901234567',
        duration: 0,
        ringDuration: 10,
        timestamp: baseTime,
        callType: 3,
      );
      final answeredCall = CallLogEntry(
        id: 301,
        number: '0901234567',
        duration: 20,
        ringDuration: 2,
        timestamp: baseTime + 15000,
        callType: 2,
      );

      final recFor301 = CallRecordingItem.fromMap({
        'id': 'r_301',
        'filePath': '/tmp/301.m4a',
        'phoneNumber': '0901234567',
        'normalizedNumber': '0901234567',
        'callLogId': 301,
        'startedAt': baseTime + 15500,
        'endedAt': baseTime + 35500,
      });

      expect(
        CallRecordingService.matchRecordingForCall(missedCall, [recFor301]),
        isNull,
      );

      final unrelatedCallSameNumber = CallLogEntry(
        id: 302,
        number: '0901234567',
        duration: 20,
        ringDuration: 0,
        timestamp: baseTime + 16000,
        callType: 2,
      );
      expect(
        CallRecordingService.matchRecordingForCall(
          unrelatedCallSameNumber,
          [recFor301],
        ),
        isNull,
      );

      expect(
        CallRecordingService.matchRecordingForCall(answeredCall, [recFor301])
            ?.id,
        'r_301',
      );
    });

    test('disambiguates two back-to-back calls to the same phone number', () {
      const baseTime = 1700000000000;
      final firstCall = CallLogEntry(
        id: 401,
        number: '0987000111',
        duration: 15,
        ringDuration: 0,
        timestamp: baseTime,
        callType: 2,
      );
      final secondCall = CallLogEntry(
        id: 402,
        number: '0987000111',
        duration: 25,
        ringDuration: 0,
        timestamp: baseTime + 30000,
        callType: 2,
      );

      final rec1 = CallRecordingItem.fromMap({
        'id': 'r_1',
        'filePath': '/tmp/1.m4a',
        'normalizedNumber': '0987000111',
        'callLogId': -1,
        'startedAt': baseTime + 500,
        'endedAt': baseTime + 15500,
      });
      final rec2 = CallRecordingItem.fromMap({
        'id': 'r_2',
        'filePath': '/tmp/2.m4a',
        'normalizedNumber': '0987000111',
        'callLogId': -1,
        'startedAt': baseTime + 30500,
        'endedAt': baseTime + 55500,
      });

      expect(
        CallRecordingService.matchRecordingForCall(firstCall, [rec1, rec2])?.id,
        'r_1',
      );
      expect(
        CallRecordingService.matchRecordingForCall(secondCall, [rec1, rec2])
            ?.id,
        'r_2',
      );
    });

    test('rejects recordings outside boundary window or with mismatched number', () {
      const baseTime = 1700000000000;
      final call = CallLogEntry(
        id: 500,
        number: '0901111111',
        duration: 30,
        ringDuration: 0,
        timestamp: baseTime,
        callType: 2,
      );

      final wrongNumber = CallRecordingItem.fromMap({
        'id': 'r_wrong_num',
        'filePath': '/tmp/wrong.m4a',
        'normalizedNumber': '0902222222',
        'callLogId': -1,
        'startedAt': baseTime,
        'endedAt': baseTime + 30000,
      });
      final tooLate = CallRecordingItem.fromMap({
        'id': 'r_late',
        'filePath': '/tmp/late.m4a',
        'normalizedNumber': '0901111111',
        'callLogId': -1,
        'startedAt': baseTime + 120000,
        'endedAt': baseTime + 150000,
      });
      final emptyNumberOutsideTightStart = CallRecordingItem.fromMap({
        'id': 'r_empty_far',
        'filePath': '/tmp/empty_far.m4a',
        'normalizedNumber': '',
        'callLogId': -1,
        'startedAt': baseTime + 50000,
        'endedAt': baseTime + 75000,
      });
      final emptyNumberWithinTightWindow = CallRecordingItem.fromMap({
        'id': 'r_empty_near',
        'filePath': '/tmp/empty_near.m4a',
        'normalizedNumber': '',
        'callLogId': -1,
        'startedAt': baseTime + 1000,
        'endedAt': baseTime + 30500,
      });

      expect(
        CallRecordingService.matchRecordingForCall(
          call,
          [wrongNumber, tooLate, emptyNumberOutsideTightStart],
        ),
        isNull,
      );

      expect(
        CallRecordingService.matchRecordingForCall(
          call,
          [wrongNumber, emptyNumberWithinTightWindow],
        )?.id,
        'r_empty_near',
      );
    });

    test('matches heuristically when CallLogEntry.id is null', () {
      const baseTime = 1700000000000;
      final callWithNullId = CallLogEntry(
        id: null,
        number: '0905556666',
        duration: 18,
        ringDuration: 0,
        timestamp: baseTime,
        callType: 2,
      );
      final rec = CallRecordingItem.fromMap({
        'id': 'r_null_id',
        'filePath': '/tmp/null_id.m4a',
        'normalizedNumber': '0905556666',
        'callLogId': 888,
        'startedAt': baseTime + 200,
        'endedAt': baseTime + 18200,
      });

      expect(
        CallRecordingService.matchRecordingForCall(callWithNullId, [rec])?.id,
        'r_null_id',
      );
    });

    test('never matches calls with zero talk duration (unanswered outgoing / instant drop)', () {
      const baseTime = 1700000000000;
      final unansweredOutgoing = CallLogEntry(
        id: 700,
        number: '0909888777',
        duration: 0,
        ringDuration: 15,
        timestamp: baseTime,
        callType: 2,
      );
      final recMatchingIdOrTime = CallRecordingItem.fromMap({
        'id': 'r_zero',
        'filePath': '/tmp/zero.m4a',
        'normalizedNumber': '0909888777',
        'callLogId': 700,
        'startedAt': baseTime + 250,
        'endedAt': baseTime + 15000,
      });

      expect(
        CallRecordingService.matchRecordingForCall(
          unansweredOutgoing,
          [recMatchingIdOrTime],
        ),
        isNull,
      );

      final answeredOutgoing = unansweredOutgoing.copyWith(duration: 12);
      expect(
        CallRecordingService.matchRecordingForCall(
          answeredOutgoing,
          [recMatchingIdOrTime],
        )?.id,
        'r_zero',
      );
    });

    test('system_dialer origin, diagnostic, and sync status models parse cleanly', () {
      final sysItem = CallRecordingItem.fromMap({
        'id': 'sys_1',
        'filePath': '/data/user/0/app/files/call_recordings/sys_1.mp3',
        'phoneNumber': '0938308279',
        'normalizedNumber': '0938308279',
        'callType': 2,
        'startedAt': 1700000000000,
        'endedAt': 1700000045000,
        'durationMs': 45000,
        'fileSizeBytes': 180000,
        'audioSource': 'SYSTEM_DIALER',
        'peakAmplitude': 0,
        'origin': 'system_dialer',
      });
      expect(sysItem.isSystemDialer, isTrue);
      expect(sysItem.isSilentRecording, isFalse);
      expect(
        CallRecordingItem.audioSourceDisplayLabel('system_dialer'),
        contains('2 chiều VoLTE'),
      );
      expect(
        CallRecordingItem.audioSourceDisplayLabel('unprocessed'),
        contains('Unprocessed'),
      );

      final diag = CallRecordingDiagnostic.fromMap({
        'timestampMs': 1700000000000,
        'audioSource': 'VOICE_COMMUNICATION',
        'attemptedSources': 'MIC -> CAMCORDER -> VOICE_RECOGNITION',
        'silencedBySystem': true,
        'peakAmplitude': 0,
        'audioMode': 2,
        'speakerOn': true,
        'reason': 'VoLTE chặn mic · Dùng Ghi âm máy',
        'status': 'SILENCED',
        'brand': 'Xiaomi',
        'model': '2312DRA50G',
        'sdkInt': 34,
      });
      expect(diag.hasAttempt, isTrue);
      expect(diag.silencedBySystem, isTrue);
      expect(diag.speakerOn, isTrue);
      expect(diag.brand, 'Xiaomi');

      final sync = SystemCallRecSyncStatus.fromMap({
        'hasTreePermission': true,
        'hasMediaPermission': false,
        'isReady': true,
        'folderLabel': 'MIUI/sound_recorder/call_rec',
        'lastSyncMs': 1700000100000,
        'lastImportedCount': 3,
        'suggestedFolder': 'MIUI/sound_recorder/call_rec',
      });
      expect(sync.isReady, isTrue);
      expect(sync.hasTreePermission, isTrue);
      expect(sync.lastImportedCount, 3);
    });
  });
}
