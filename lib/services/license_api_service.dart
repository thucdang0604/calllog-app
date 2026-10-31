import 'dart:async';
import 'dart:convert';
import 'dart:io';

class LicenseApiException implements Exception {
  const LicenseApiException(this.message);

  final String message;

  @override
  String toString() => message;
}

class LicenseApiService {
  static const String _baseUrl = String.fromEnvironment(
    'LICENSE_API_BASE_URL',
    defaultValue: 'https://mylove-2026-sms-admin.web.app/api',
  );

  bool get isConfigured => _baseUrl.trim().isNotEmpty;

  Future<Map<String, dynamic>> createOrder({
    required String deviceId,
    required String plan,
  }) => _post('orders', {'deviceId': deviceId, 'plan': plan});

  Future<Map<String, dynamic>> checkOrderStatus({
    required String deviceId,
    required String paymentCode,
  }) => _post('orders/status', {
    'deviceId': deviceId,
    'paymentCode': paymentCode,
  });

  Future<Map<String, dynamic>> syncLicense(
    String deviceId, {
    int trialUsed = 0,
  }) => _post('license/sync', {
    'deviceId': deviceId,
    'trialUsed': trialUsed,
  });

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, Object?> body,
  ) async {
    if (!isConfigured) {
      throw const LicenseApiException(
        'Chưa cấu hình địa chỉ máy chủ bản quyền cho ứng dụng.',
      );
    }

    final base = _baseUrl.trim().replaceFirst(RegExp(r'/+$'), '');
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 12);
    try {
      final request = await client
          .postUrl(Uri.parse('$base/$path'))
          .timeout(const Duration(seconds: 15));
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
      final response = await request.close().timeout(
        const Duration(seconds: 15),
      );
      final responseText = await response
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 15));
      Map<String, dynamic> data;
      try {
        data = jsonDecode(responseText) as Map<String, dynamic>;
      } catch (_) {
        throw const LicenseApiException(
          'Máy chủ bản quyền trả về dữ liệu không hợp lệ.',
        );
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw LicenseApiException(
          data['error']?.toString() ?? 'Không kết nối được máy chủ bản quyền.',
        );
      }
      if (data['success'] != true) {
        throw LicenseApiException(
          data['error']?.toString() ?? 'Yêu cầu bản quyền không thành công.',
        );
      }
      return data;
    } on LicenseApiException {
      rethrow;
    } on TimeoutException {
      throw const LicenseApiException(
        'Máy chủ phản hồi chậm. Vui lòng thử lại.',
      );
    } on SocketException {
      throw const LicenseApiException(
        'Không có kết nối mạng tới máy chủ bản quyền.',
      );
    } on FormatException {
      throw const LicenseApiException(
        'Địa chỉ máy chủ bản quyền không hợp lệ.',
      );
    } finally {
      client.close(force: true);
    }
  }
}
