import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:call_log_manager/models/scanned_barcode_item.dart';
import 'package:call_log_manager/services/barcode_scanner_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ScannedBarcodeItem Test Suite', () {
    test('Serialization giữ nguyên imagePath khi có ảnh và bỏ qua khi rỗng', () {
      const withPhoto = ScannedBarcodeItem(
        id: '1',
        code: 'AVN90452708-1.1',
        format: 'Code 128',
        timestamp: 1700000000000,
        imagePath: '/data/user/0/app/files/barcode_scan_photos/scan_1.webp',
      );

      expect(withPhoto.hasImage, isTrue);
      final json = withPhoto.toJson();
      expect(
        json['imagePath'],
        equals('/data/user/0/app/files/barcode_scan_photos/scan_1.webp'),
      );

      final parsed = ScannedBarcodeItem.fromJson(json);
      expect(parsed.code, equals('AVN90452708-1.1'));
      expect(parsed.hasImage, isTrue);
      expect(parsed.imagePath, equals(withPhoto.imagePath));

      final withoutPhoto = ScannedBarcodeItem.fromJson({
        'id': '2',
        'code': 'FHS38861094',
        'format': 'Code 128',
        'timestamp': 1700000000000,
        'imagePath': '   ',
      });
      expect(withoutPhoto.hasImage, isFalse);
      expect(withoutPhoto.imagePath, isNull);
      expect(withoutPhoto.toJson().containsKey('imagePath'), isFalse);
    });

    test('copyWith với clearImagePath xóa đường dẫn ảnh nhưng giữ nguyên thông tin mã', () {
      const original = ScannedBarcodeItem(
        id: '3',
        code: 'GYECY6FM',
        format: 'QR Code',
        timestamp: 1700000000000,
        imagePath: '/tmp/scan_3.webp',
      );

      final cleared = original.copyWith(clearImagePath: true);
      expect(cleared.hasImage, isFalse);
      expect(cleared.imagePath, isNull);
      expect(cleared.code, equals('GYECY6FM'));
      expect(cleared.isQrCode, isTrue);
    });

    test('Phân tách Hôm nay và Lưu trữ theo ngày chính xác khi qua ngày mới', () {
      final now = DateTime(2026, 11, 14, 10, 30);
      final todayMorning = DateTime(2026, 11, 14, 8, 15).millisecondsSinceEpoch;
      final yesterdayAfternoon =
          DateTime(2026, 11, 13, 17, 45).millisecondsSinceEpoch;
      final twoDaysAgo = DateTime(2026, 11, 12, 9, 0).millisecondsSinceEpoch;

      final items = [
        ScannedBarcodeItem(
          id: 't1',
          code: 'TODAY_01',
          format: 'Code 128',
          timestamp: todayMorning,
        ),
        ScannedBarcodeItem(
          id: 'y1',
          code: 'YEST_01',
          format: 'QR Code',
          timestamp: yesterdayAfternoon,
        ),
        ScannedBarcodeItem(
          id: 'o1',
          code: 'OLD_01',
          format: 'Code 128',
          timestamp: twoDaysAgo,
        ),
      ];

      final partitioned = BarcodeScannerService.partitionByDay(items, now: now);
      expect(partitioned.today.map((e) => e.code).toList(), equals(['TODAY_01']));
      expect(
        partitioned.archive.map((e) => e.code).toList(),
        equals(['YEST_01', 'OLD_01']),
      );
      expect(partitioned.archiveGroups.length, equals(2));
      expect(partitioned.archiveGroups[0].label, equals('Hôm qua · 13/11/2026'));
      expect(partitioned.archiveGroups[1].label, equals('12/11/2026'));

      // Sang ngày mới (15/11): mã ngày 14/11 tự động trở thành Hôm qua trong Lưu trữ
      final nextDay = DateTime(2026, 11, 15, 0, 5);
      final nextPartitioned = BarcodeScannerService.partitionByDay(
        items,
        now: nextDay,
      );
      expect(nextPartitioned.today, isEmpty);
      expect(nextPartitioned.archive.length, equals(3));
      expect(
        nextPartitioned.archiveGroups.first.label,
        equals('Hôm qua · 14/11/2026'),
      );
    });

    test('loadHistory và saveHistory fallback qua SharedPreferences ổn định khi chạy test', () async {
      SharedPreferences.setMockInitialValues({});
      final nowMs = DateTime(2026, 11, 14, 12, 0).millisecondsSinceEpoch;
      final input = [
        ScannedBarcodeItem(
          id: 's1',
          code: 'SPX123456',
          format: 'Code 128',
          timestamp: nowMs,
        ),
      ];

      await BarcodeScannerService.saveHistory(input);
      final loaded = await BarcodeScannerService.loadHistory();
      expect(loaded.length, equals(1));
      expect(loaded.first.code, equals('SPX123456'));
      expect(loaded.first.localDateKey, equals('2026-11-14'));
    });

    test('Phân tách 3 mục Hôm nay / Đã chia sẻ / Lưu trữ và hoàn tác trạng thái chia sẻ', () {
      final now = DateTime(2026, 11, 14, 15, 0);
      final todayPendingMs = DateTime(2026, 11, 14, 9, 0).millisecondsSinceEpoch;
      final todaySharedMs = DateTime(2026, 11, 14, 10, 0).millisecondsSinceEpoch;
      final sharedAtMs = DateTime(2026, 11, 14, 11, 30).millisecondsSinceEpoch;
      final yesterdayMs = DateTime(2026, 11, 13, 18, 0).millisecondsSinceEpoch;

      final items = [
        ScannedBarcodeItem(
          id: 'p1',
          code: 'PENDING_1',
          format: 'Code 128',
          timestamp: todayPendingMs,
        ),
        ScannedBarcodeItem(
          id: 's1',
          code: 'SHARED_1',
          format: 'QR Code',
          timestamp: todaySharedMs,
          sharedAt: sharedAtMs,
        ),
        ScannedBarcodeItem(
          id: 'a1',
          code: 'ARCHIVE_SHARED',
          format: 'Code 128',
          timestamp: yesterdayMs,
          sharedAt: yesterdayMs + 60000,
        ),
      ];

      final part = BarcodeScannerService.partitionByDay(items, now: now);
      expect(part.today.map((e) => e.code).toList(), equals(['PENDING_1']));
      expect(part.shared.map((e) => e.code).toList(), equals(['SHARED_1']));
      expect(part.archive.map((e) => e.code).toList(), equals(['ARCHIVE_SHARED']));
      expect(part.archive.first.isShared, isTrue);

      // Chuyển PENDING_1 sang Đã chia sẻ
      final afterMark = BarcodeScannerService.markItemsSharedState(
        items,
        ['p1'],
        shared: true,
        sharedAtMs: sharedAtMs + 5000,
      );
      final partAfterMark =
          BarcodeScannerService.partitionByDay(afterMark, now: now);
      expect(partAfterMark.today, isEmpty);
      expect(
        partAfterMark.shared.map((e) => e.code).toList(),
        equals(['PENDING_1', 'SHARED_1']),
      );

      // Hoàn tác SHARED_1 về Hôm nay
      final afterUndo = BarcodeScannerService.markItemsSharedState(
        afterMark,
        ['s1'],
        shared: false,
      );
      final partAfterUndo =
          BarcodeScannerService.partitionByDay(afterUndo, now: now);
      expect(partAfterUndo.today.map((e) => e.code).toList(), equals(['SHARED_1']));
      expect(
        partAfterUndo.shared.map((e) => e.code).toList(),
        equals(['PENDING_1']),
      );

      // Qua ngày mới: cả Hôm nay lẫn Đã chia sẻ đều gộp vào Lưu trữ theo ngày
      final nextDay = DateTime(2026, 11, 15, 0, 1);
      final partNextDay =
          BarcodeScannerService.partitionByDay(afterUndo, now: nextDay);
      expect(partNextDay.today, isEmpty);
      expect(partNextDay.shared, isEmpty);
      expect(partNextDay.archive.length, equals(3));
      expect(partNextDay.archiveGroups.first.label, equals('Hôm qua · 14/11/2026'));
    });

    test('classifyScannedBatch phân loại đúng mã mới, mã đã có hôm nay và mã ở Đã chia sẻ', () {
      final now = DateTime(2026, 11, 14, 16, 0);
      final todayMs = DateTime(2026, 11, 14, 9, 0).millisecondsSinceEpoch;
      final yesterdayMs = DateTime(2026, 11, 13, 9, 0).millisecondsSinceEpoch;

      final history = [
        ScannedBarcodeItem(
          id: 'h_pending',
          code: 'CODE_PENDING',
          format: 'Code 128',
          timestamp: todayMs,
        ),
        ScannedBarcodeItem(
          id: 'h_shared',
          code: 'CODE_SHARED',
          format: 'QR Code',
          timestamp: todayMs,
          sharedAt: todayMs + 1000,
        ),
        ScannedBarcodeItem(
          id: 'h_old',
          code: 'CODE_YESTERDAY',
          format: 'Code 128',
          timestamp: yesterdayMs,
          sharedAt: yesterdayMs + 1000,
        ),
      ];

      final scannedBatch = [
        ScannedBarcodeItem(
          id: 'n1',
          code: 'CODE_NEW',
          format: 'Code 128',
          timestamp: now.millisecondsSinceEpoch,
        ),
        ScannedBarcodeItem(
          id: 'n2',
          code: 'CODE_YESTERDAY',
          format: 'Code 128',
          timestamp: now.millisecondsSinceEpoch + 1,
        ),
        ScannedBarcodeItem(
          id: 'n3',
          code: 'CODE_PENDING',
          format: 'Code 128',
          timestamp: now.millisecondsSinceEpoch + 2,
        ),
        ScannedBarcodeItem(
          id: 'n4',
          code: 'CODE_SHARED',
          format: 'QR Code',
          timestamp: now.millisecondsSinceEpoch + 3,
        ),
      ];

      final classified = BarcodeScannerService.classifyScannedBatch(
        scannedBatch,
        history,
        now: now,
      );
      expect(
        classified.brandNew.map((e) => e.code).toList(),
        equals(['CODE_NEW', 'CODE_YESTERDAY']),
      );
      expect(
        classified.dupInPending.map((e) => e.code).toList(),
        equals(['CODE_PENDING']),
      );
      expect(
        classified.dupInShared.map((e) => e.code).toList(),
        equals(['CODE_SHARED']),
      );
    });
  });
}
