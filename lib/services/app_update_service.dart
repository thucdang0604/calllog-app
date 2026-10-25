import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AppUpdateService {
  static const _repository = 'thucdang0604/calllog-app';
  static const _lastCheckKey = 'app_update_last_check_ms';
  static const _checkInterval = Duration(hours: 1);
  static const _platform = MethodChannel('call_log_manager_updates');

  bool _isChecking = false;

  Future<void> checkForUpdate(
    BuildContext context, {
    bool forceCheck = false,
  }) async {
    if (_isChecking) {
      if (forceCheck) _showMessage(context, 'Đang kiểm tra bản cập nhật.');
      return;
    }
    _isChecking = true;

    HttpClient? client;
    try {
      final preferences = await SharedPreferences.getInstance();
      final now = DateTime.now().millisecondsSinceEpoch;
      final lastCheck = preferences.getInt(_lastCheckKey);
      if (!forceCheck &&
          lastCheck != null &&
          now >= lastCheck &&
          now - lastCheck < _checkInterval.inMilliseconds) {
        return;
      }

      final currentVersion = await _platform.invokeMethod<String>(
        'getAppVersion',
      );
      if (currentVersion == null || currentVersion.isEmpty) {
        throw const FormatException('Không đọc được phiên bản ứng dụng.');
      }

      client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
      final request = await client
          .getUrl(
            Uri.parse(
              'https://api.github.com/repos/$_repository/releases/latest',
            ),
          )
          .timeout(const Duration(seconds: 6));
      request.headers
        ..set(HttpHeaders.acceptHeader, 'application/vnd.github+json')
        ..set(HttpHeaders.userAgentHeader, 'APP-NVPTTT');

      final response = await request.close().timeout(
        const Duration(seconds: 6),
      );
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        throw HttpException('GitHub trả về mã ${response.statusCode}.');
      }

      final responseBody = await response
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 6));
      final decoded = jsonDecode(responseBody);
      if (decoded is! Map<String, dynamic> ||
          decoded['draft'] == true ||
          decoded['prerelease'] == true) {
        throw const FormatException('Không đọc được bản phát hành ổn định.');
      }

      final latestTag = decoded['tag_name'];
      final assets = decoded['assets'];
      if (latestTag is! String || assets is! List) {
        throw const FormatException('Thiếu thông tin phiên bản hoặc APK.');
      }

      String? downloadUrl;
      for (final asset in assets) {
        if (asset is Map &&
            asset['name'] is String &&
            (asset['name'] as String).toLowerCase().endsWith('.apk') &&
            asset['browser_download_url'] is String) {
          downloadUrl = asset['browser_download_url'] as String;
          break;
        }
      }
      final downloadUri = downloadUrl == null
          ? null
          : Uri.tryParse(downloadUrl);
      if (downloadUri == null ||
          downloadUri.scheme != 'https' ||
          downloadUri.host != 'github.com' ||
          !downloadUri.path.startsWith('/$_repository/releases/download/')) {
        throw const FormatException('Không tìm thấy APK cập nhật hợp lệ.');
      }

      final latestVersion = _versionParts(latestTag);
      final installedVersion = _versionParts(currentVersion);
      if (latestVersion == null || installedVersion == null) {
        throw const FormatException('Không đọc được số phiên bản.');
      }

      // Save only successful checks; temporary network errors must not delay retries.
      await preferences.setInt(_lastCheckKey, now);

      if (!_isNewer(latestVersion, installedVersion)) {
        if (forceCheck && context.mounted) {
          _showMessage(
            context,
            'Bạn đang dùng phiên bản mới nhất (${_displayVersion(currentVersion)}).',
          );
        }
        return;
      }

      if (!context.mounted) return;
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Có bản cập nhật mới'),
          content: Text(
            'Phiên bản ${_displayVersion(latestTag)} đã sẵn sàng. '
            'Bạn đang dùng phiên bản ${_displayVersion(currentVersion)}.\n\n'
            'Tải APK rồi mở tệp để cài đặt bản cập nhật.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Để sau'),
            ),
            FilledButton.icon(
              onPressed: () async {
                Navigator.of(dialogContext).pop();
                try {
                  await _platform.invokeMethod<void>('openUpdate', {
                    'url': downloadUri.toString(),
                  });
                } on PlatformException {
                  if (context.mounted) {
                    _showMessage(
                      context,
                      'Không mở được trang tải bản cập nhật.',
                    );
                  }
                }
              },
              icon: const Icon(Icons.download),
              label: const Text('Tải cập nhật'),
            ),
          ],
        ),
      );
    } catch (_) {
      if (forceCheck && context.mounted) {
        _showMessage(
          context,
          'Không kiểm tra được cập nhật. Hãy kiểm tra kết nối Internet rồi thử lại.',
        );
      }
    } finally {
      client?.close(force: true);
      _isChecking = false;
    }
  }

  void _showMessage(BuildContext context, String message) {
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(message)));
  }

  static List<int>? _versionParts(String value) {
    final normalized = value
        .trim()
        .replaceFirst(RegExp(r'^[vV]'), '')
        .split('+')
        .first;
    final parts = normalized.split('.');
    if (parts.isEmpty) return null;

    final numbers = <int>[];
    for (final part in parts) {
      final number = int.tryParse(part);
      if (number == null) return null;
      numbers.add(number);
    }
    return numbers;
  }

  static bool _isNewer(List<int> latest, List<int> installed) {
    final length = latest.length > installed.length
        ? latest.length
        : installed.length;
    for (var index = 0; index < length; index++) {
      final latestPart = index < latest.length ? latest[index] : 0;
      final installedPart = index < installed.length ? installed[index] : 0;
      if (latestPart != installedPart) return latestPart > installedPart;
    }
    return false;
  }

  static String _displayVersion(String version) =>
      version.trim().replaceFirst(RegExp(r'^[vV]'), '').split('+').first;
}
