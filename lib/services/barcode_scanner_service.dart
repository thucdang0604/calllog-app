import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/scanned_barcode_item.dart';

class BarcodeScannerService {
  static const _channel = MethodChannel('call_log_manager');
  static const _prefKey = 'scanned_barcodes_history';
  static const int _maxStoredPhotos = 300;
  static const int _photoMaxAgeMs = 30 * 24 * 60 * 60 * 1000;

  static Future<List<ScannedBarcodeItem>> loadHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final String? jsonStr = prefs.getString(_prefKey);
      if (jsonStr == null || jsonStr.isEmpty) return [];

      final decoded = jsonDecode(jsonStr);
      if (decoded is List) {
        final loaded = decoded
            .map((item) {
              if (item is Map<String, dynamic>) {
                return ScannedBarcodeItem.fromJson(item);
              } else if (item is Map) {
                return ScannedBarcodeItem.fromJson(Map<String, dynamic>.from(item));
              }
              return null;
            })
            .whereType<ScannedBarcodeItem>()
            .toList();

        final pruned = await _pruneExpiredPhotos(loaded);
        if (pruned.changed) {
          await saveHistory(pruned.items);
        }
        return pruned.items;
      }
    } catch (_) {}
    return [];
  }

  static Future<void> saveHistory(List<ScannedBarcodeItem> items) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = items.map((e) => e.toJson()).toList();
      await prefs.setString(_prefKey, jsonEncode(list));
    } catch (_) {}
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

  static Future<List<ScannedBarcodeItem>> openScanner() async {
    try {
      final String? resultJson =
          await _channel.invokeMethod<String>('openBarcodeScanner');
      if (resultJson == null || resultJson.isEmpty) return [];

      final decoded = jsonDecode(resultJson);
      if (decoded is List) {
        final newItems = <ScannedBarcodeItem>[];
        for (final item in decoded) {
          if (item is Map) {
            final parsed = ScannedBarcodeItem.fromJson(Map<String, dynamic>.from(item));
            if (parsed.code.isNotEmpty) {
              newItems.add(parsed);
            }
          }
        }

        if (newItems.isNotEmpty) {
          final current = await loadHistory();
          // Merge avoiding duplicates while putting newest on top
          final existingCodes = current.map((e) => e.code).toSet();
          final uniqueNew = <ScannedBarcodeItem>[];
          for (final item in newItems) {
            if (existingCodes.add(item.code)) {
              uniqueNew.add(item);
            } else if (item.hasImage) {
              // Discard orphaned photo file when code already exists in history
              await deleteImageFile(item.imagePath);
            }
          }
          final merged = [...uniqueNew, ...current];
          final pruned = await _pruneExpiredPhotos(merged);
          await saveHistory(pruned.items);
          return uniqueNew.isNotEmpty ? uniqueNew : newItems;
        }
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

  static Future<bool> shareList(List<ScannedBarcodeItem> items) async {
    if (items.isEmpty) return false;

    final buffer = StringBuffer();
    buffer.writeln('📋 DANH SÁCH MÃ ĐÃ QUÉT (${items.length} mã):');
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

