import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/scanned_barcode_item.dart';

class BarcodeScannerService {
  static const _channel = MethodChannel('call_log_manager');
  static const _prefKey = 'scanned_barcodes_history';

  static Future<List<ScannedBarcodeItem>> loadHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final String? jsonStr = prefs.getString(_prefKey);
      if (jsonStr == null || jsonStr.isEmpty) return [];

      final decoded = jsonDecode(jsonStr);
      if (decoded is List) {
        return decoded
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
          // Merge avoiding immediate duplicates while putting newest on top
          final existingCodes = current.map((e) => e.code).toSet();
          final uniqueNew = newItems.where((e) => !existingCodes.contains(e.code)).toList();
          final updated = [...uniqueNew, ...current];
          await saveHistory(updated);
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

