import 'package:flutter_test/flutter_test.dart';
import 'package:call_log_manager/models/scanned_barcode_item.dart';

void main() {
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
      expect(json['imagePath'], equals('/data/user/0/app/files/barcode_scan_photos/scan_1.webp'));

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
  });
}

