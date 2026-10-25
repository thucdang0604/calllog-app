import 'package:flutter_test/flutter_test.dart';
import 'package:call_log_manager/models/call_log_entry.dart';

void main() {
  group('CallLogEntry Test Suite', () {
    test('Kiểm tra khởi tạo và tách biệt 2 thời gian cuộc gọi', () {
      final entry = CallLogEntry(
        id: 1,
        number: '0987654321',
        name: 'Nguyễn Văn A',
        formattedNumber: '+84 987 654 321',
        duration: 10, // 💬 Thời gian trò chuyện: 10s
        ringDuration: 5, // 🔔 Thời gian đổ chuông: 5s
        timestamp: DateTime.now().millisecondsSinceEpoch,
        callType: 1,
      );

      expect(entry.duration, equals(10));
      expect(entry.ringDuration, equals(5));
      expect(entry.ringDurationFormatted, equals('5s'));
      expect(entry.talkDurationFormatted, equals('10s'));
    });

    test('Kiểm tra copyWith cập nhật độc lập Thời gian đổ chuông hoặc Thời gian trò chuyện', () {
      final original = CallLogEntry(
        id: 2,
        number: '0123456789',
        duration: 20,
        ringDuration: 10,
        timestamp: 1600000000000,
        callType: 2,
      );

      // Cập nhật riêng thời gian đổ chuông
      final updatedRing = original.copyWith(ringDuration: 15);
      expect(updatedRing.ringDuration, equals(15));
      expect(updatedRing.duration, equals(20)); // Giữ nguyên thời gian trò chuyện

      // Cập nhật riêng thời gian trò chuyện
      final updatedTalk = original.copyWith(duration: 45);
      expect(updatedTalk.duration, equals(45));
      expect(updatedTalk.ringDuration, equals(10)); // Giữ nguyên thời gian đổ chuông
    });

    test('Kiểm tra serialization toMap và fromMap với ring_duration', () {
      final mapData = {
        'id': 10,
        'number': '0901234567',
        'name': 'Test User',
        'formattedNumber': '+84 901 234 567',
        'duration': 30,
        'ring_duration': 8,
        'timestamp': 1700000000000,
        'callType': 1,
      };

      final entry = CallLogEntry.fromMap(mapData);
      expect(entry.id, equals(10));
      expect(entry.duration, equals(30));
      expect(entry.ringDuration, equals(8));

      final exportedMap = entry.toMap();
      expect(exportedMap['duration'], equals(30));
      expect(exportedMap['ringDuration'], equals(8));
    });
  });
}
