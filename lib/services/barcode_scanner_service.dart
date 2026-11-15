import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/scanned_barcode_item.dart';

class BarcodeArchiveGroup {
  final String dateKey;
  final DateTime date;
  final String label;
  final List<ScannedBarcodeItem> items;

  const BarcodeArchiveGroup({
    required this.dateKey,
    required this.date,
    required this.label,
    required this.items,
  });
}

class BarcodeScannerService {
  static const _channel = MethodChannel('call_log_manager');
  static const _prefKey = 'scanned_barcodes_history';
  static const int _maxStoredPhotos = 300;
  static const int _photoMaxAgeMs = 30 * 24 * 60 * 60 * 1000;

  static List<ScannedBarcodeItem> _decodeItems(String jsonStr) {
    final decoded = jsonDecode(jsonStr);
    if (decoded is! List) return [];
    return decoded
        .map((item) {
          if (item is Map<String, dynamic>) {
            return ScannedBarcodeItem.fromJson(item);
          } else if (item is Map) {
            return ScannedBarcodeItem.fromJson(
              Map<String, dynamic>.from(item),
            );
          }
          return null;
        })
        .whereType<ScannedBarcodeItem>()
        .toList();
  }

  static Future<List<ScannedBarcodeItem>> loadHistory() async {
    try {
      String? jsonStr;
      var nativeStorageAvailable = true;

      try {
        jsonStr = await _channel.invokeMethod<String>('loadBarcodeHistoryJson');
      } on MissingPluginException {
        nativeStorageAvailable = false;
      } catch (_) {
        nativeStorageAvailable = false;
      }

      if (jsonStr == null || jsonStr.isEmpty) {
        final prefs = await SharedPreferences.getInstance();
        final legacyJson = prefs.getString(_prefKey);
        if (legacyJson != null && legacyJson.isNotEmpty) {
          jsonStr = legacyJson;
          if (nativeStorageAvailable) {
            final savedToFile = await _saveToNativeFile(legacyJson);
            if (savedToFile) {
              await prefs.remove(_prefKey);
            }
          }
        }
      }

      if (jsonStr == null || jsonStr.isEmpty) return [];

      final loaded = _decodeItems(jsonStr);
      final pruned = await _pruneExpiredPhotos(loaded);
      if (pruned.changed) {
        await saveHistory(pruned.items);
      }
      return pruned.items;
    } catch (_) {}
    return [];
  }

  static Future<bool> _saveToNativeFile(String jsonStr) async {
    try {
      final result = await _channel.invokeMethod<bool>(
        'saveBarcodeHistoryJson',
        {'json': jsonStr},
      );
      return result == true;
    } on MissingPluginException {
      return false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> saveHistory(List<ScannedBarcodeItem> items) async {
    try {
      final encoded = jsonEncode(items.map((e) => e.toJson()).toList());
      final savedNative = await _saveToNativeFile(encoded);
      if (!savedNative) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_prefKey, encoded);
      }
    } catch (_) {}
  }

  /// Chia danh sách mã đã quét thành:
  /// - [today]: các mã quét hôm nay chưa chia sẻ (hàng chờ chính)
  /// - [shared]: các mã quét hôm nay đã copy/chia sẻ hàng loạt
  /// - [archive]: toàn bộ mã thuộc các ngày trước đó (gồm cả đã/chưa chia sẻ)
  /// - [archiveGroups]: danh sách nhóm theo từng ngày (mới nhất đứng trước)
  static ({
    List<ScannedBarcodeItem> today,
    List<ScannedBarcodeItem> shared,
    List<ScannedBarcodeItem> archive,
    List<BarcodeArchiveGroup> archiveGroups,
  }) partitionByDay(
    List<ScannedBarcodeItem> items, {
    DateTime? now,
  }) {
    final reference = now ?? DateTime.now();
    final todayDate = DateTime(reference.year, reference.month, reference.day);

    final today = <ScannedBarcodeItem>[];
    final shared = <ScannedBarcodeItem>[];
    final archive = <ScannedBarcodeItem>[];
    final grouped = <String, List<ScannedBarcodeItem>>{};

    for (final item in items) {
      if (item.isSameLocalDate(todayDate)) {
        if (item.isShared) {
          shared.add(item);
        } else {
          today.add(item);
        }
      } else {
        archive.add(item);
        grouped.putIfAbsent(item.localDateKey, () => <ScannedBarcodeItem>[]).add(
              item,
            );
      }
    }

    shared.sort(
      (a, b) => (b.sharedAt ?? b.timestamp).compareTo(a.sharedAt ?? a.timestamp),
    );

    final yesterdayDate = todayDate.subtract(const Duration(days: 1));
    final archiveGroups = grouped.entries.map((entry) {
      final dateOnly = entry.value.first.localDateOnly;
      final dateLabel = entry.value.first.formattedDateLabel;
      final isYesterday = dateOnly.year == yesterdayDate.year &&
          dateOnly.month == yesterdayDate.month &&
          dateOnly.day == yesterdayDate.day;
      return BarcodeArchiveGroup(
        dateKey: entry.key,
        date: dateOnly,
        label: isYesterday ? 'Hôm qua · $dateLabel' : dateLabel,
        items: entry.value,
      );
    }).toList()
      ..sort((a, b) => b.date.compareTo(a.date));

    return (
      today: today,
      shared: shared,
      archive: archive,
      archiveGroups: archiveGroups,
    );
  }

  /// Phân loại lô mã vừa quét xong so với lịch sử trong ngày [now]:
  /// - [brandNew]: mã chưa có trong ngày hôm nay
  /// - [dupInPending]: mã đã có trong mục Hôm nay (chờ chia sẻ)
  /// - [dupInShared]: mã đã được chuyển vào mục Đã chia sẻ hôm nay
  static ({
    List<ScannedBarcodeItem> brandNew,
    List<ScannedBarcodeItem> dupInPending,
    List<ScannedBarcodeItem> dupInShared,
  }) classifyScannedBatch(
    List<ScannedBarcodeItem> scannedBatch,
    List<ScannedBarcodeItem> existingHistory, {
    DateTime? now,
  }) {
    final reference = now ?? DateTime.now();
    final todayPendingCodes = <String>{};
    final todaySharedCodes = <String>{};

    for (final item in existingHistory) {
      if (!item.isSameLocalDate(reference)) continue;
      if (item.isShared) {
        todaySharedCodes.add(item.code);
      } else {
        todayPendingCodes.add(item.code);
      }
    }

    final brandNew = <ScannedBarcodeItem>[];
    final dupInPending = <ScannedBarcodeItem>[];
    final dupInShared = <ScannedBarcodeItem>[];

    for (final item in scannedBatch) {
      if (todaySharedCodes.contains(item.code)) {
        dupInShared.add(item);
      } else if (todayPendingCodes.contains(item.code)) {
        dupInPending.add(item);
      } else {
        brandNew.add(item);
      }
    }

    return (
      brandNew: brandNew,
      dupInPending: dupInPending,
      dupInShared: dupInShared,
    );
  }

  static List<ScannedBarcodeItem> markItemsSharedState(
    List<ScannedBarcodeItem> items,
    Iterable<String> targetIds, {
    required bool shared,
    int? sharedAtMs,
  }) {
    final idSet = targetIds.toSet();
    if (idSet.isEmpty) return items;
    final stamp = sharedAtMs ?? DateTime.now().millisecondsSinceEpoch;
    return items.map((item) {
      if (!idSet.contains(item.id)) return item;
      if (shared) {
        return item.isShared ? item : item.copyWith(sharedAt: stamp);
      }
      return item.isShared ? item.copyWith(clearSharedAt: true) : item;
    }).toList();
  }

  static Future<List<ScannedBarcodeItem>> commitScannedBatch(
    List<ScannedBarcodeItem> existingHistory, {
    required List<ScannedBarcodeItem> itemsToAdd,
    List<ScannedBarcodeItem> discardedDuplicates = const [],
  }) async {
    if (discardedDuplicates.isNotEmpty) {
      await deleteAllImages(discardedDuplicates);
    }
    if (itemsToAdd.isEmpty) {
      return existingHistory;
    }
    final merged = [...itemsToAdd, ...existingHistory];
    final pruned = await _pruneExpiredPhotos(merged);
    await saveHistory(pruned.items);
    return pruned.items;
  }

  static Future<void> deleteImageFile(String? path) async {
    if (path == null || path.isEmpty) return;
    try {
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {}
  }

  static Future<void> deleteAllImages(List<ScannedBarcodeItem> items) async {
    for (final item in items) {
      if (item.hasImage) {
        await deleteImageFile(item.imagePath);
      }
    }
  }

  static Future<({List<ScannedBarcodeItem> items, bool changed})> _pruneExpiredPhotos(
    List<ScannedBarcodeItem> items,
  ) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    var photoCount = 0;
    var changed = false;
    final result = <ScannedBarcodeItem>[];

    for (final item in items) {
      if (!item.hasImage) {
        result.add(item);
        continue;
      }

      final isExpired = (now - item.timestamp) > _photoMaxAgeMs;
      final isOverLimit = photoCount >= _maxStoredPhotos;
      if (isExpired || isOverLimit) {
        await deleteImageFile(item.imagePath);
        result.add(item.copyWith(clearImagePath: true));
        changed = true;
      } else {
        photoCount++;
        result.add(item);
      }
    }
    return (items: result, changed: changed);
  }

  static Future<List<ScannedBarcodeItem>> openScanner({
    List<String> existingPendingCodes = const [],
    List<String> existingSharedCodes = const [],
  }) async {
    try {
      final String? resultJson = await _channel.invokeMethod<String>(
        'openBarcodeScanner',
        {
          'existingPendingCodes': existingPendingCodes,
          'existingSharedCodes': existingSharedCodes,
        },
      );
      if (resultJson == null || resultJson.isEmpty) return [];

      final decoded = jsonDecode(resultJson);
      if (decoded is List) {
        final newItems = <ScannedBarcodeItem>[];
        for (int i = 0; i < decoded.length; i++) {
          final item = decoded[i];
          if (item is Map) {
            final map = Map<String, dynamic>.from(item);
            final parsed = ScannedBarcodeItem.fromJson(map);
            if (parsed.code.isNotEmpty) {
              final hasExplicitId =
                  map['id'] != null && map['id'].toString().isNotEmpty;
              newItems.add(
                hasExplicitId
                    ? parsed
                    : parsed.copyWith(
                        id: '${parsed.code}_${parsed.timestamp}_$i',
                      ),
              );
            }
          }
        }
        return newItems;
      }
    } catch (_) {}
    return [];
  }

  static Future<void> copyList(
    List<ScannedBarcodeItem> items, {
    bool withIndex = false,
  }) async {
    if (items.isEmpty) return;

    final buffer = StringBuffer();
    for (int i = 0; i < items.length; i++) {
      if (withIndex) {
        buffer.writeln('${i + 1}. ${items[i].code}');
      } else {
        buffer.writeln(items[i].code);
      }
    }

    await Clipboard.setData(ClipboardData(text: buffer.toString().trim()));
  }

  static Future<bool> shareList(
    List<ScannedBarcodeItem> items, {
    String? title,
  }) async {
    if (items.isEmpty) return false;

    final buffer = StringBuffer();
    buffer.writeln(
      '📋 ${title ?? 'DANH SÁCH MÃ ĐÃ QUÉT'} (${items.length} mã):',
    );
    for (int i = 0; i < items.length; i++) {
      final item = items[i];
      buffer.writeln('${i + 1}. ${item.code} (${item.format}) - ${item.formattedDateTime}');
    }

    try {
      await _channel.invokeMethod('shareText', {'text': buffer.toString().trim()});
      return true;
    } catch (_) {
      return false;
    }
  }
}
