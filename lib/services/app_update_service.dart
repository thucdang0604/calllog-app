import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AppUpdateService {
  static const _repository = 'thucdang0604/calllog-app';
  static const _lastCheckKey = 'app_update_last_check_ms';
  static const _pendingApkPathKey = 'app_update_pending_apk_path';
  static const _checkInterval = Duration(hours: 1);
  static const _platform = MethodChannel('call_log_manager_updates');

  bool _isChecking = false;
  bool _isInstallingPending = false;

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
            'APK sẽ được tải ngay trong ứng dụng. Android sẽ yêu cầu bạn '
            'xác nhận cài đặt.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Để sau'),
            ),
            FilledButton.icon(
              onPressed: () async {
                Navigator.of(dialogContext).pop();
                await _downloadAndInstall(context, downloadUri, latestTag);
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

  Future<void> resumePendingInstallation(BuildContext context) async {
    if (_isInstallingPending) return;
    _isInstallingPending = true;
    try {
      final preferences = await SharedPreferences.getInstance();
      final apkPath = preferences.getString(_pendingApkPathKey);
      if (apkPath == null || apkPath.isEmpty) return;

      final canInstall = await _platform.invokeMethod<bool>('canInstallApk');
      if (canInstall != true) {
        if (context.mounted) {
          _showMessage(
            context,
            'Cho phép APP NVPTTT cài ứng dụng để tiếp tục cập nhật.',
          );
        }
        return;
      }
      await _installDownloadedApk(context, apkPath, preferences);
    } catch (_) {
      if (context.mounted) {
        _showMessage(context, 'Không mở được trình cài đặt Android.');
      }
    } finally {
      _isInstallingPending = false;
    }
  }

  Future<void> _downloadAndInstall(
    BuildContext context,
    Uri downloadUri,
    String version,
  ) async {
    final progress = ValueNotifier(const _UpdateDownloadProgress(0, 0));
    var progressDialogOpen = true;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _UpdateDownloadProgressDialog(progress: progress),
    );

    try {
      final apkPath = await _downloadApk(downloadUri, version, progress);
      if (context.mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        progressDialogOpen = false;
      }

      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(_pendingApkPathKey, apkPath);
      await _installDownloadedApk(context, apkPath, preferences);
    } catch (_) {
      if (context.mounted) {
        if (progressDialogOpen) {
          Navigator.of(context, rootNavigator: true).pop();
        }
        _showMessage(
          context,
          'Tải APK hoặc mở trình cài đặt chưa thành công. Hãy thử lại.',
        );
      }
    } finally {
      progress.dispose();
    }
  }

  Future<String> _downloadApk(
    Uri downloadUri,
    String version,
    ValueNotifier<_UpdateDownloadProgress> progress,
  ) async {
    final safeVersion = version.replaceAll(RegExp(r'[^0-9.]'), '_');
    final apkPath = await _platform.invokeMethod<String>('getUpdateApkPath', {
      'version': safeVersion,
    });
    if (apkPath == null || apkPath.isEmpty) {
      throw const FileSystemException('Không tạo được tệp APK cập nhật.');
    }

    final apkFile = File(apkPath);
    await apkFile.parent.create(recursive: true);
    final partialFile = File('${apkFile.path}.part');
    if (await partialFile.exists()) await partialFile.delete();

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20)
      ..userAgent = 'APP-NVPTTT';
    try {
      final request = await client
          .getUrl(downloadUri)
          .timeout(const Duration(seconds: 30));
      request.headers.set(HttpHeaders.acceptHeader, 'application/octet-stream');
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        throw HttpException('Máy chủ tải APK trả về ${response.statusCode}.');
      }

      final totalBytes = response.contentLength > 0
          ? response.contentLength
          : 0;
      var receivedBytes = 0;
      final sink = partialFile.openWrite();
      try {
        await for (final chunk in response.timeout(
          const Duration(seconds: 90),
          onTimeout: (eventSink) {
            eventSink.addError(
              const SocketException('Tải xuống bị gián đoạn.'),
            );
            eventSink.close();
          },
        )) {
          sink.add(chunk);
          receivedBytes += chunk.length;
          progress.value = _UpdateDownloadProgress(receivedBytes, totalBytes);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }

      if (receivedBytes == 0 ||
          (totalBytes > 0 && receivedBytes != totalBytes)) {
        throw const FileSystemException('Tệp APK tải về không đầy đủ.');
      }
      if (await apkFile.exists()) await apkFile.delete();
      final completedFile = await partialFile.rename(apkFile.path);
      progress.value = _UpdateDownloadProgress(
        receivedBytes,
        totalBytes,
        completed: true,
      );
      return completedFile.path;
    } catch (_) {
      if (await partialFile.exists()) await partialFile.delete();
      rethrow;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _installDownloadedApk(
    BuildContext context,
    String apkPath,
    SharedPreferences preferences,
  ) async {
    final started = await _platform.invokeMethod<bool>('installUpdateApk', {
      'path': apkPath,
    });
    if (started == true) {
      await preferences.remove(_pendingApkPathKey);
      return;
    }

    if (context.mounted) {
      _showMessage(
        context,
        'Hãy cho phép APP NVPTTT cài ứng dụng rồi quay lại để tiếp tục.',
      );
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

class _UpdateDownloadProgress {
  const _UpdateDownloadProgress(
    this.receivedBytes,
    this.totalBytes, {
    this.completed = false,
  });

  final int receivedBytes;
  final int totalBytes;
  final bool completed;

  double? get fraction => totalBytes > 0
      ? (completed ? 1.0 : (receivedBytes / totalBytes).clamp(0.0, 0.99))
            .toDouble()
      : null;
}

class _UpdateDownloadProgressDialog extends StatelessWidget {
  const _UpdateDownloadProgressDialog({required this.progress});

  final ValueListenable<_UpdateDownloadProgress> progress;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: AlertDialog(
        title: const Text('Đang tải bản cập nhật'),
        content: ValueListenableBuilder<_UpdateDownloadProgress>(
          valueListenable: progress,
          builder: (context, value, child) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              LinearProgressIndicator(value: value.fraction),
              const SizedBox(height: 12),
              Text(
                value.totalBytes > 0
                    ? '${(value.fraction! * 100).round()}%  ·  '
                          '${_formatBytes(value.receivedBytes)} / '
                          '${_formatBytes(value.totalBytes)}'
                    : 'Đã tải ${_formatBytes(value.receivedBytes)}',
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatBytes(int bytes) {
    final megabytes = bytes / (1024 * 1024);
    return '${megabytes.toStringAsFixed(1)} MB';
  }
}
