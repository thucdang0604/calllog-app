import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../providers/call_log_provider.dart';
import '../services/app_update_service.dart';
import '../services/license_api_service.dart';
import '../widgets/floating_window_widget.dart';
import '../widgets/fake_gps_widget.dart';
import '../widgets/timemark_camera_widget.dart';
import 'payment_reconciliation_screen.dart';
import 'payment_account_settings_screen.dart';

class SimpleHomeScreen extends StatefulWidget {
  const SimpleHomeScreen({super.key});

  @override
  State<SimpleHomeScreen> createState() => _SimpleHomeScreenState();
}

class _SimpleHomeScreenState extends State<SimpleHomeScreen>
    with WidgetsBindingObserver {
  final AppUpdateService _appUpdateService = AppUpdateService();
  bool _isCallLogDefaultSmsApp = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refreshDefaultSmsStatus();
      _loadCallLogs(force: false);
      _checkForAppUpdate();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshDefaultSmsStatus();
      _appUpdateService.resumePendingInstallation(context);
      _checkForAppUpdate(delay: false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _checkForAppUpdate({
    bool forceCheck = false,
    bool delay = true,
  }) async {
    if (delay) await Future<void>.delayed(const Duration(seconds: 3));
    if (!mounted) return;
    await _appUpdateService.checkForUpdate(context, forceCheck: forceCheck);
  }

  Future<void> _refreshDefaultSmsStatus() async {
    try {
      const channel = MethodChannel('call_log_manager');
      final isDefault =
          await channel.invokeMethod<bool>('isCallLogDefaultSmsApp') ?? false;
      if (mounted && isDefault != _isCallLogDefaultSmsApp) {
        setState(() => _isCallLogDefaultSmsApp = isDefault);
      }
    } on PlatformException {
      // The warning is optional on devices that do not expose SMS role status.
    }
  }

  Future<void> _openDefaultSmsSettings() async {
    try {
      const channel = MethodChannel('call_log_manager');
      await channel.invokeMethod<bool>('openSmsDefaultSettings');
    } on PlatformException {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Không mở được cài đặt ứng dụng SMS.')),
      );
    }
  }

  Future<void> _loadCallLogs({bool force = true}) async {
    try {
      final provider = Provider.of<CallLogProvider>(context, listen: false);
      await provider.loadCallLogs(forceRefresh: force);
    } catch (e) {
      // Ignore
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: const _DonateCardWidget(),
        leadingWidth: 88,
        titleSpacing: 0,
        centerTitle: false,
        title: const Text(
          'APP NVPTTT',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
        ),
        backgroundColor: Colors.blue[700],
        elevation: 2,
        bottom: _isCallLogDefaultSmsApp
            ? PreferredSize(
                preferredSize: const Size.fromHeight(56),
                child: Container(
                  color: const Color(0xFFFFF3CD),
                  padding: const EdgeInsets.only(left: 12, right: 4),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.warning_amber_rounded,
                        color: Color(0xFF9A6500),
                        size: 21,
                      ),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text(
                          'CallLog đang là app SMS mặc định; tin mới có thể không báo.',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Color(0xFF684700),
                            fontSize: 12,
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: _openDefaultSmsSettings,
                        tooltip: 'Đổi ứng dụng SMS mặc định',
                        icon: const Icon(
                          Icons.settings_outlined,
                          color: Color(0xFF684700),
                        ),
                      ),
                    ],
                  ),
                ),
              )
            : null,
        actions: [
          IconButton(
            icon: const Icon(Icons.system_update, color: Colors.white),
            onPressed: () => _checkForAppUpdate(forceCheck: true, delay: false),
            tooltip: 'Kiểm tra cập nhật',
          ),
          IconButton(
            icon: const Icon(Icons.receipt_long, color: Colors.white),
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const PaymentReconciliationScreen(),
                ),
              );
            },
            tooltip: 'Đối soát chuyển khoản',
          ),
          IconButton(
            icon: const Icon(Icons.refresh, color: Colors.white),
            onPressed: () => _loadCallLogs(force: true),
            tooltip: 'Làm mới',
          ),
        ],
      ),
      body: Consumer<CallLogProvider>(
        builder: (context, provider, child) {
          if (provider.isLoading) {
            return const Center(child: CircularProgressIndicator());
          }

          if (provider.hasError) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.error, size: 64, color: Colors.red[300]),
                  const SizedBox(height: 16),
                  Text(
                    provider.errorMessage,
                    style: const TextStyle(fontSize: 16, color: Colors.red),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: () => _loadCallLogs(force: true),
                    child: const Text('Thử lại'),
                  ),
                ],
              ),
            );
          }

          if (!provider.hasPermission) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.security, size: 64, color: Colors.orange[300]),
                  const SizedBox(height: 16),
                  const Text(
                    'Cần cấp quyền',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Ứng dụng cần quyền đọc nhật ký cuộc gọi',
                    style: TextStyle(fontSize: 14, color: Colors.grey),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 24),
                  ElevatedButton(
                    onPressed: () async {
                      await provider.requestPermission();
                      if (provider.hasPermission) {
                        await _loadCallLogs(force: true);
                      }
                    },
                    child: const Text('Cấp quyền'),
                  ),
                ],
              ),
            );
          }

          return SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            child: Column(
              children: [
                ExpansionTile(
                  initiallyExpanded: true,
                  leading: const Icon(Icons.local_shipping_outlined),
                  title: const Text('Giao hàng & chuyển khoản'),
                  subtitle: const Text('Popup nhanh, cuộc gọi và đối soát'),
                  children: [
                    const FloatingWindowWidget(),
                    _buildLatestCallsPreview(provider),
                  ],
                ),
                ExpansionTile(
                  leading: const Icon(Icons.widgets_outlined),
                  title: const Text('Tiện ích'),
                  subtitle: const Text('Vị trí giả lập và TimeMark'),
                  children: const [FakeGpsWidget(), TimeMarkCameraWidget()],
                ),
                ExpansionTile(
                  leading: const Icon(Icons.tune_outlined),
                  title: const Text('Cài đặt nhắn tin & QR'),
                  subtitle: const Text('Mẫu SMS và tài khoản nhận Zalo'),
                  children: [
                    const _SmsTemplateConfigWidget(),
                    ListTile(
                      leading: const Icon(Icons.account_balance_outlined),
                      title: const Text('Tài khoản QR Zalo'),
                      subtitle: const Text(
                        'Thiết lập và quét xác nhận QR tĩnh',
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.of(context).push<bool>(
                        MaterialPageRoute<bool>(
                          builder: (_) => const PaymentAccountSettingsScreen(),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
      bottomNavigationBar: Container(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
        decoration: BoxDecoration(
          color: Colors.white,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 4,
              offset: const Offset(0, -2),
            ),
          ],
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: const [
            Icon(Icons.verified, size: 14, color: Colors.blue),
            SizedBox(width: 6),
            Text(
              'Thiết kế bởi Thức Đặng',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: Colors.blueGrey,
                letterSpacing: 0.5,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Hiển thị các cuộc gọi gần nhất
  Widget _buildLatestCallsPreview(CallLogProvider provider) {
    final latestCalls = provider.getLatestCalls(count: 4);

    if (latestCalls.isEmpty) {
      return Container(
        margin: const EdgeInsets.all(16),
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: Colors.grey[100],
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          children: [
            Icon(Icons.phone_missed, size: 48, color: Colors.grey[400]),
            const SizedBox(height: 12),
            Text(
              'Chưa có cuộc gọi nào',
              style: TextStyle(fontSize: 16, color: Colors.grey[600]),
            ),
          ],
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                Icon(Icons.history, color: Colors.blue[700], size: 20),
                const SizedBox(width: 8),
                Text(
                  'Cuộc gọi gần nhất (${latestCalls.length})',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Colors.blue[700],
                  ),
                ),
              ],
            ),
          ),
          ...latestCalls.map(
            (call) => Card(
              margin: const EdgeInsets.only(bottom: 8),
              elevation: 2,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
              child: ListTile(
                leading: CircleAvatar(
                  backgroundColor: _getCallTypeColor(call.callType),
                  radius: 22,
                  child: Icon(
                    _getCallTypeIcon(call.callType),
                    color: Colors.white,
                    size: 18,
                  ),
                ),
                title: Text(
                  call.name ?? call.number ?? 'Unknown',
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 15,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  '${call.formattedNumber ?? call.number ?? ''} · ${call.dateFormatted}',
                  style: TextStyle(color: Colors.grey[600], fontSize: 13),
                ),
                trailing: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.blue[50],
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '📞 ${call.talkDurationFormatted}',
                    style: TextStyle(
                      color: Colors.blue[700],
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Color _getCallTypeColor(int callType) {
    switch (callType) {
      case 1:
        return Colors.green;
      case 2:
        return Colors.blue;
      case 3:
        return Colors.red;
      default:
        return Colors.grey;
    }
  }

  IconData _getCallTypeIcon(int callType) {
    switch (callType) {
      case 1:
        return Icons.call_received;
      case 2:
        return Icons.call_made;
      case 3:
        return Icons.call_missed;
      default:
        return Icons.call;
    }
  }
}

class _SmsTemplateConfigWidget extends StatefulWidget {
  const _SmsTemplateConfigWidget();

  @override
  State<_SmsTemplateConfigWidget> createState() =>
      _SmsTemplateConfigWidgetState();
}

class _SmsTemplateConfigWidgetState extends State<_SmsTemplateConfigWidget>
    with WidgetsBindingObserver {
  static const _regularLicenseSyncInterval = Duration(hours: 12);
  static const _pendingLicenseSyncInterval = Duration(minutes: 5);
  static const _pendingLicenseSyncWindow = Duration(days: 3);
  final TextEditingController _controller = TextEditingController();
  final LicenseApiService _licenseApi = LicenseApiService();
  bool _hasSmsPermission = false;
  bool _hasIncomingSmsPermission = false;
  bool _isAutoFakeSmsIntent = false;
  Map<String, dynamic>? _licenseDetails;
  bool _isLoading = true;
  bool _isSyncingLicense = false;
  int _lastLicenseSyncAttemptAt = 0;

  String _lastSyncKey(String deviceId) => 'sms_license_last_sync_$deviceId';
  String _pendingOrderKey(String deviceId) => 'sms_license_pending_order_$deviceId';

  Future<void> _markPendingOrder(String deviceId) async {
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setInt(_pendingOrderKey(deviceId), DateTime.now().millisecondsSinceEpoch);
    } catch (_) {
      // The order remains available on the server if local storage is unavailable.
    }
  }

  Future<void> _clearPendingOrder(String deviceId) async {
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.remove(_pendingOrderKey(deviceId));
    } catch (_) {}
  }

  Future<void> _recordLicenseSync(String deviceId) async {
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setInt(_lastSyncKey(deviceId), DateTime.now().millisecondsSinceEpoch);
    } catch (_) {}
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadConfig();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _syncLicenseFromServer();
  }

  Future<void> _loadConfig() async {
    try {
      const channel = MethodChannel('call_log_manager');
      final String template = await channel.invokeMethod('getSmsTemplate');
      final bool hasPerm = await channel.invokeMethod('hasSmsPermission');
      final bool hasIncomingPerm = await channel.invokeMethod(
        'hasIncomingSmsPermission',
      );
      final bool autoFakeIntent =
          await channel.invokeMethod('getAutoFakeSmsIntent') ?? false;

      final licenseInfo = await _readLicenseDetails(channel);

      if (mounted) {
        setState(() {
          _controller.text = template;
          _hasSmsPermission = hasPerm;
          _hasIncomingSmsPermission = hasIncomingPerm;
          _isAutoFakeSmsIntent = autoFakeIntent;
          _licenseDetails = licenseInfo;
          _isLoading = false;
        });
        unawaited(_syncLicenseFromServer());
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<Map<String, dynamic>?> _readLicenseDetails(
    MethodChannel channel,
  ) async {
    try {
      final String? licenseStr = await channel.invokeMethod<String>(
        'getSmsLicenseDetails',
      );
      if (licenseStr == null || licenseStr.isEmpty) return null;
      return jsonDecode(licenseStr) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  Future<void> _syncLicenseFromServer({bool force = false}) async {
    if (!_licenseApi.isConfigured || _isSyncingLicense) return;
    _isSyncingLicense = true;
    try {
      const channel = MethodChannel('call_log_manager');
      final deviceId = await channel.invokeMethod<String>('getDeviceId');
      if (deviceId == null || deviceId.isEmpty) return;
      SharedPreferences? preferences;
      try {
        preferences = await SharedPreferences.getInstance();
      } catch (_) {
        // A storage failure must not prevent an online license check.
      }
      final now = DateTime.now().millisecondsSinceEpoch;
      final pendingAt = preferences?.getInt(_pendingOrderKey(deviceId)) ?? 0;
      final lastSyncAt = preferences?.getInt(_lastSyncKey(deviceId)) ?? 0;
      final hasRecentOrder = pendingAt > 0 && now >= pendingAt &&
          now - pendingAt < _pendingLicenseSyncWindow.inMilliseconds;
      final interval = hasRecentOrder
          ? _pendingLicenseSyncInterval
          : _regularLicenseSyncInterval;
      if (!force && lastSyncAt > 0 && now >= lastSyncAt &&
          now - lastSyncAt < interval.inMilliseconds) {
        return;
      }
      if (!force && now >= _lastLicenseSyncAttemptAt &&
          now - _lastLicenseSyncAttemptAt < const Duration(minutes: 1).inMilliseconds) {
        return;
      }
      _lastLicenseSyncAttemptAt = now;
      final previousDetails = await _readLicenseDetails(channel);
      final response = await _licenseApi.syncLicense(
        deviceId,
        trialUsed: previousDetails?['usedTrial'] as int? ?? 0,
      );
      final token = response['licenseToken']?.toString();
      if (token == null || token.isEmpty) return;
      final bool? applied = await channel.invokeMethod<bool>(
        'applyServerLicenseToken',
        {'token': token},
      );
      if (applied == true && mounted) {
        await _recordLicenseSync(deviceId);
        if (response['license'] is Map &&
            (response['license'] as Map)['status'] == 'active') {
          await _clearPendingOrder(deviceId);
        }
        final details = await _readLicenseDetails(channel);
        if (mounted && details != null) {
          setState(() => _licenseDetails = details);
        }
      }
    } catch (_) {
      // Keep the last verified token available during temporary network outages.
    } finally {
      _isSyncingLicense = false;
    }
  }

  Future<void> _saveTemplate() async {
    try {
      const channel = MethodChannel('call_log_manager');
      await channel.invokeMethod('saveSmsTemplate', {
        'template': _controller.text,
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('✅ Đã lưu mẫu tin nhắn SMS!'),
            backgroundColor: Colors.green,
            duration: Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('❌ Lỗi khi lưu: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _requestSmsPermission() async {
    try {
      const channel = MethodChannel('call_log_manager');
      final bool granted = await channel.invokeMethod('requestSmsPermission');
      if (mounted) {
        setState(() {
          _hasSmsPermission = granted;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              granted
                  ? '✅ Đã cấp quyền gửi SMS!'
                  : '❌ Quyền gửi SMS bị từ chối',
            ),
            backgroundColor: granted ? Colors.green : Colors.orange,
          ),
        );
      }
    } catch (e) {
      // Ignore
    }
  }

  Future<void> _requestIncomingSmsPermission() async {
    try {
      const channel = MethodChannel('call_log_manager');
      final bool granted = await channel.invokeMethod(
        'requestIncomingSmsPermission',
      );
      if (mounted) {
        setState(() => _hasIncomingSmsPermission = granted);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              granted
                  ? 'Đã bật nhận diện SMS phản hồi.'
                  : 'Chưa được cấp quyền nhận SMS.',
            ),
            backgroundColor: granted ? Colors.green : Colors.orange,
          ),
        );
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Không bật được nhận diện SMS: $error')),
      );
    }
  }

  Future<void> _toggleAutoFakeSmsIntent(bool enabled) async {
    if (enabled && _licenseDetails != null) {
      final bool isLicensed = _licenseDetails!['isLicensed'] == true;
      final int remaining = _licenseDetails!['remainingTrial'] as int? ?? 0;
      if (!isLicensed && remaining <= 0) {
        _showLicenseModal();
        return;
      }
    }
    try {
      const channel = MethodChannel('call_log_manager');
      final saved = await channel.invokeMethod<bool>('setAutoFakeSmsIntent', {
        'enabled': enabled,
      });
      if (saved != true) throw StateError('Không lưu được cài đặt');
      if (mounted) {
        setState(() => _isAutoFakeSmsIntent = enabled);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              enabled
                  ? 'Icon SMS từ GHN sẽ tạo SMS ảo; SMS nhanh trong popup vẫn gửi qua SIM'
                  : 'Icon SMS từ GHN sẽ hiện lựa chọn SMS ảo hoặc gửi thật',
            ),
            backgroundColor: enabled ? Colors.green[700] : Colors.grey[700],
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Không đổi được cài đặt: $error')));
    }
  }

  Future<void> _showLicenseModal() async {
    final keyCtrl = TextEditingController();
    await _syncLicenseFromServer(force: true);
    const deviceIdChannel = MethodChannel('call_log_manager');
    String deviceId = '';
    try {
      deviceId =
          (await deviceIdChannel.invokeMethod<String>('getDeviceId') ?? '')
              .trim()
              .toUpperCase();
    } catch (_) {
      deviceId = '';
    }
    Map<String, dynamic>? licenseInfo = _licenseDetails;
    final deviceIdPattern = RegExp(
      r'^SMS-(?:[A-F0-9]{4}-[A-F0-9]{4}|[A-F0-9]{8}-[A-F0-9]{8})$',
    );
    if (!deviceIdPattern.hasMatch(deviceId)) {
      final cachedDeviceId = (licenseInfo?['deviceId']?.toString() ?? '')
          .trim()
          .toUpperCase();
      if (deviceIdPattern.hasMatch(cachedDeviceId)) {
        deviceId = cachedDeviceId;
      } else {
        licenseInfo = await _readLicenseDetails(deviceIdChannel);
        deviceId = (licenseInfo?['deviceId']?.toString() ?? '')
            .trim()
            .toUpperCase();
      }
    }
    if (!mounted) return;
    if (!deviceIdPattern.hasMatch(deviceId)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Không đọc được mã thiết bị hợp lệ.')),
      );
      return;
    }
    if (licenseInfo != _licenseDetails && licenseInfo != null) {
      setState(() => _licenseDetails = licenseInfo);
    }
    const plans = [
      {'id': '30D', 'title': '30 ngày', 'price': '50.000đ'},
      {'id': '90D', 'title': '90 ngày', 'price': '140.000đ'},
      {'id': '1Y', 'title': '1 năm', 'price': '365.000đ'},
      {'id': 'PERM', 'title': 'Vĩnh viễn', 'price': '999.999đ'},
    ];
    final isLicensed = _licenseDetails?['isLicensed'] == true;
    final remainingTrial = _licenseDetails?['remainingTrial'] as int? ?? 0;
    Map<String, dynamic>? order;
    Timer? paymentTimer;
    var creatingOrder = false;
    var checkingPayment = false;
    var automaticPaymentCheckStopped = false;
    var automaticPaymentCheckCount = 0;
    var sheetIsOpen = true;
    String? paymentMessage;

    Future<void> checkPayment(StateSetter update) async {
      if (checkingPayment || order == null || !sheetIsOpen) return;
      checkingPayment = true;
      try {
        final status = await _licenseApi.checkOrderStatus(
          deviceId: deviceId,
          paymentCode: order!['paymentCode'].toString(),
        );
        final state = status['status']?.toString();
        if (state == 'paid') {
          const channel = MethodChannel('call_log_manager');
          final previousDetails = await _readLicenseDetails(channel);
          final synced = await _licenseApi.syncLicense(
            deviceId,
            trialUsed: previousDetails?['usedTrial'] as int? ?? 0,
          );
          final token = synced['licenseToken']?.toString();
          if (token == null || token.isEmpty) {
            throw const LicenseApiException(
              'Chưa nhận được dữ liệu kích hoạt.',
            );
          }
          final applied = await channel.invokeMethod<bool>(
            'applyServerLicenseToken',
            {'token': token},
          );
          if (applied != true) {
            throw const LicenseApiException(
              'Không xác minh được license trên thiết bị này.',
            );
          }
          await _recordLicenseSync(deviceId);
          await _clearPendingOrder(deviceId);
          paymentTimer?.cancel();
          await _loadConfig();
          if (sheetIsOpen && mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Đã xác nhận chuyển khoản và kích hoạt SMS!'),
                backgroundColor: Colors.green,
              ),
            );
            Navigator.of(context).pop();
          }
        } else if (state == 'expired') {
          await _clearPendingOrder(deviceId);
          paymentTimer?.cancel();
          automaticPaymentCheckStopped = true;
          if (sheetIsOpen) {
            update(() {
              order = null;
              paymentMessage = 'Đơn đã hết hạn. Hãy tạo đơn mới.';
            });
          }
        } else if (state == 'pending' && sheetIsOpen) {
          update(
            () => paymentMessage =
                'Đang chờ quản lý xác nhận đã nhận tiền trong tài khoản.',
          );
        }
      } catch (error) {
        if (sheetIsOpen) update(() => paymentMessage = error.toString());
      } finally {
        checkingPayment = false;
      }
    }

    Future<void> createOrder(String planId, StateSetter update) async {
      if (creatingOrder || order?['plan'] == planId) return;
      update(() {
        creatingOrder = true;
        paymentMessage = null;
      });
      try {
        final created = await _licenseApi.createOrder(
          deviceId: deviceId,
          plan: planId,
        );
        await _markPendingOrder(deviceId);
        if (!sheetIsOpen) return;
        update(() {
          order = created;
          automaticPaymentCheckStopped = false;
          automaticPaymentCheckCount = 0;
          paymentMessage =
              'Chuyển khoản xong, gửi mã máy qua Telegram để quản lý đối soát.';
        });
        paymentTimer?.cancel();
        paymentTimer = Timer.periodic(const Duration(minutes: 5), (_) {
          if (!sheetIsOpen) {
            paymentTimer?.cancel();
            return;
          }
          if (automaticPaymentCheckCount >= 2) {
            paymentTimer?.cancel();
            automaticPaymentCheckStopped = true;
            update(() {
              paymentMessage =
                  'Đã dừng tự kiểm tra sau 15 phút để tiết kiệm chi phí. Bạn vẫn có thể kiểm tra thủ công hoặc nhận mã qua Telegram.';
            });
            return;
          }
          automaticPaymentCheckCount += 1;
          unawaited(checkPayment(update));
        });
        unawaited(checkPayment(update));
      } catch (error) {
        if (sheetIsOpen) update(() => paymentMessage = error.toString());
      } finally {
        if (sheetIsOpen) update(() => creatingOrder = false);
      }
    }

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, update) {
          final expiryValue = order?['expiresAt'];
          final expiry = expiryValue is num
              ? DateTime.fromMillisecondsSinceEpoch(
                  expiryValue.toInt(),
                ).toLocal().toString().substring(0, 16)
              : '';
          return SafeArea(
            child: Container(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(ctx).size.height * 0.9,
              ),
              padding: EdgeInsets.fromLTRB(
                16,
                18,
                16,
                MediaQuery.of(ctx).viewInsets.bottom + 20,
              ),
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Bản quyền SMS',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Mã thiết bị: $deviceId',
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    if (isLicensed)
                      Text(
                        'Đang dùng gói ${_licenseDetails?['plan'] ?? ''} · '
                        '${_licenseDetails?['expiresAtFormatted'] ?? 'Vĩnh viễn'}',
                      )
                    else
                      Text(
                        remainingTrial > 0
                            ? 'Còn $remainingTrial/10 tin nhắn trải nghiệm.'
                            : 'Đã dùng hết lượt trải nghiệm miễn phí.',
                      ),
                    const SizedBox(height: 14),
                    const Text(
                      'Chọn gói bản quyền',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    for (final plan in plans)
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton(
                          onPressed: creatingOrder || order?['plan'] == plan['id']
                              ? null
                              : () => createOrder(plan['id']!, update),
                          child: Row(
                            children: [
                              Expanded(child: Text(plan['title']!)),
                              Text(
                                plan['price']!,
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              if (creatingOrder) ...[
                                const SizedBox(width: 8),
                                const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    if (order != null) ...[
                      const Divider(),
                      Center(
                        child: Image.network(
                          order!['qrUrl'].toString(),
                          width: 210,
                          height: 210,
                          errorBuilder: (_, __, ___) =>
                              const Text('Không tải được ảnh QR.'),
                        ),
                      ),
                      Text(
                        'Ngân hàng: ${order!['bank']}'
                        '\nSố tài khoản: ${order!['accountNumber']}'
                        '\nChủ tài khoản: ${order!['accountName']}'
                        '\nSố tiền: ${(order!['amount'] as num).toInt()}đ'
                        '\nNội dung: ${order!['transferContent']}',
                        style: const TextStyle(fontSize: 12, height: 1.45),
                      ),
                      if (expiry.isNotEmpty)
                        Text(
                          'Đơn có hiệu lực đến $expiry',
                          style: const TextStyle(
                            fontSize: 11,
                            color: Colors.grey,
                          ),
                        ),
                      OutlinedButton.icon(
                        onPressed: () {
                          final content = order!['transferContent'].toString();
                          Clipboard.setData(ClipboardData(text: content));
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text(
                                'Đã sao chép nội dung chuyển khoản.',
                              ),
                            ),
                          );
                        },
                        icon: const Icon(Icons.copy, size: 16),
                        label: const Text('Sao chép nội dung chuyển khoản'),
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        'Sau khi chuyển khoản, gửi mã máy và mã đơn cho bot/quản lý trên Telegram. License chỉ được kích hoạt sau khi quản lý kiểm tra thấy tiền vào tài khoản.',
                        style: TextStyle(fontSize: 12, height: 1.4),
                      ),
                      OutlinedButton.icon(
                        onPressed: () async {
                          final telegramMessage =
                              order!['telegramMessage']?.toString() ??
                              'Mã máy: $deviceId\n'
                                  'Mã đơn: ${order!['paymentCode']}\n'
                                  'Gói: ${order!['planTitle']}\n'
                                  'Số tiền: ${(order!['amount'] as num).toInt()}đ';
                          try {
                            const channel = MethodChannel('call_log_manager');
                            await channel.invokeMethod<bool>('shareText', {
                              'text': telegramMessage,
                            });
                          } catch (_) {
                            await Clipboard.setData(
                              ClipboardData(text: telegramMessage),
                            );
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text(
                                    'Đã sao chép thông tin. Hãy dán vào Telegram.',
                                  ),
                                ),
                              );
                            }
                          }
                        },
                        icon: const Icon(Icons.send, size: 18),
                        label: const Text('Gửi mã máy qua Telegram'),
                      ),
                      Row(
                        children: [
                          if (automaticPaymentCheckStopped)
                            const Icon(Icons.info_outline, size: 18)
                          else
                            const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              paymentMessage ?? 'Đang chờ xác nhận...',
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                        ],
                      ),
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: () => checkPayment(update),
                          child: const Text('Kiểm tra trạng thái kích hoạt'),
                        ),
                      ),
                    ] else if (paymentMessage != null)
                      Text(
                        paymentMessage!,
                        style: TextStyle(color: Colors.red[700], fontSize: 12),
                      ),
                    const Divider(),
                    ExpansionTile(
                      tilePadding: EdgeInsets.zero,
                      title: const Text(
                        'Nhập mã kích hoạt',
                        style: TextStyle(fontSize: 13),
                      ),
                      children: [
                        TextField(
                          controller: keyCtrl,
                          textCapitalization: TextCapitalization.characters,
                          decoration: const InputDecoration(
                            hintText: 'Mã bản quyền có chữ ký từ máy chủ',
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 8),
                        ElevatedButton(
                          onPressed: () async {
                            final key = keyCtrl.text.trim();
                            if (key.isEmpty) return;
                            const channel = MethodChannel('call_log_manager');
                            final ok = await channel.invokeMethod<bool>(
                              'applyServerLicenseToken',
                              {'token': key},
                            );
                            if (ok == true && ctx.mounted) {
                              await _clearPendingOrder(deviceId);
                              await _loadConfig();
                              if (ctx.mounted) Navigator.pop(ctx);
                            } else if (mounted && ctx.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text(
                                    'Mã không hợp lệ hoặc không dành cho thiết bị này.',
                                  ),
                                ),
                              );
                            }
                          },
                          child: const Text('Kích hoạt bằng mã'),
                        ),
                        const SizedBox(height: 8),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    ).whenComplete(() {
      sheetIsOpen = false;
      paymentTimer?.cancel();
      keyCtrl.dispose();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.sms, color: Colors.green[700], size: 22),
              const SizedBox(width: 8),
              Text(
                'Cấu hình Tin nhắn Nhanh (SMS)',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: Colors.green[800],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // === Banner Bản Quyền / Trải Nghiệm ===
          Builder(
            builder: (context) {
              final bool isLicensed = _licenseDetails?['isLicensed'] == true;
              final int remaining =
                  _licenseDetails?['remainingTrial'] as int? ?? 0;
              final String plan = _licenseDetails?['plan'] ?? '';
              final String expires =
                  _licenseDetails?['expiresAtFormatted'] ?? 'Vĩnh viễn';

              if (isLicensed) {
                return InkWell(
                  onTap: _showLicenseModal,
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.green.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: Colors.green.withValues(alpha: 0.4),
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.verified,
                          color: Colors.green[700],
                          size: 18,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Bản quyền: ĐÃ KÍCH HOẠT ($plan - $expires)',
                            style: TextStyle(
                              color: Colors.green[800],
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        Icon(
                          Icons.chevron_right,
                          color: Colors.green[700],
                          size: 18,
                        ),
                      ],
                    ),
                  ),
                );
              }

              return InkWell(
                onTap: _showLicenseModal,
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  margin: const EdgeInsets.only(bottom: 12),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: remaining > 0
                        ? Colors.orange.withValues(alpha: 0.1)
                        : Colors.red.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: remaining > 0
                          ? Colors.orange.withValues(alpha: 0.5)
                          : Colors.red.withValues(alpha: 0.5),
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        remaining > 0 ? Icons.bolt : Icons.lock,
                        color: remaining > 0
                            ? Colors.orange[800]
                            : Colors.red[800],
                        size: 18,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          remaining > 0
                              ? 'Trải nghiệm SMS ảo: Còn $remaining/10 tin'
                              : 'Đã hết 10 lượt trải nghiệm miễn phí',
                          style: TextStyle(
                            color: remaining > 0
                                ? Colors.orange[900]
                                : Colors.red[900],
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: remaining > 0
                              ? Colors.orange[800]
                              : Colors.red[700],
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Text(
                          'NÂNG CẤP',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),

          // === Cấu hình SMS ảo cho icon SMS từ GHN ===
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: _isAutoFakeSmsIntent
                  ? Colors.green.withValues(alpha: 0.08)
                  : Colors.grey.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: _isAutoFakeSmsIntent
                    ? Colors.green.withValues(alpha: 0.4)
                    : Colors.grey.withValues(alpha: 0.2),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.bolt,
                  color: _isAutoFakeSmsIntent
                      ? Colors.green[700]
                      : Colors.grey[600],
                  size: 22,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              'SMS ảo cho icon SMS từ GHN',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: _isAutoFakeSmsIntent
                                    ? Colors.green[800]
                                    : Colors.grey[800],
                              ),
                            ),
                          ),
                          if (_isAutoFakeSmsIntent) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 1,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.green[700],
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: const Text(
                                'TỰ ĐỘNG',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 9,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _isAutoFakeSmsIntent
                            ? 'Tự ghi vào Đã gửi; SMS nhanh số tiền trong popup vẫn gửi qua SIM'
                            : 'Icon SMS hiện lựa chọn ảo hoặc thật; SMS nhanh số tiền luôn gửi qua SIM',
                        style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                      ),
                    ],
                  ),
                ),
                Switch(
                  value: _isAutoFakeSmsIntent,
                  onChanged: _toggleAutoFakeSmsIntent,
                  activeColor: Colors.green[700],
                ),
              ],
            ),
          ),

          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            maxLines: 2,
            decoration: InputDecoration(
              labelText: 'Mẫu nội dung tin nhắn (trước số tiền)',
              hintText: 'VD: 19034108972011 techcombank Dang Tri Thuc. ',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              contentPadding: const EdgeInsets.all(10),
            ),
            style: const TextStyle(fontSize: 13),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _saveTemplate,
                  icon: const Icon(Icons.save, size: 18),
                  label: const Text('Lưu mẫu SMS'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green[700],
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: _requestSmsPermission,
                icon: Icon(
                  _hasSmsPermission
                      ? Icons.check_circle
                      : Icons.warning_amber_rounded,
                  color: _hasSmsPermission ? Colors.green : Colors.orange,
                  size: 18,
                ),
                label: Text(
                  _hasSmsPermission ? 'Đã có quyền' : 'Cấp quyền SMS',
                  style: TextStyle(
                    color: _hasSmsPermission
                        ? Colors.green[700]
                        : Colors.orange[800],
                    fontWeight: FontWeight.bold,
                  ),
                ),
                style: OutlinedButton.styleFrom(
                  side: BorderSide(
                    color: _hasSmsPermission ? Colors.green : Colors.orange,
                  ),
                  padding: const EdgeInsets.symmetric(
                    vertical: 10,
                    horizontal: 12,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            'SMS đến từ số khách đang có đơn chờ sẽ được lưu làm dấu hiệu phản hồi và làm nổi bật các đơn cùng số. Ứng dụng không tự đánh dấu đã nhận tiền.',
            style: TextStyle(fontSize: 12, color: Colors.grey[700]),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: OutlinedButton.icon(
              onPressed: _hasIncomingSmsPermission
                  ? null
                  : _requestIncomingSmsPermission,
              icon: Icon(
                _hasIncomingSmsPermission
                    ? Icons.mark_chat_read_outlined
                    : Icons.mark_chat_unread_outlined,
                size: 18,
              ),
              label: Text(
                _hasIncomingSmsPermission
                    ? 'Đã bật nhận SMS'
                    : 'Cấp quyền nhận SMS',
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DonateCardWidget extends StatelessWidget {
  const _DonateCardWidget();

  static const String _bankName = 'Techcombank';
  static const String _accountName = 'DANG TRI THUC';
  static const String _accountNumber = '84336813825';
  static const String _qrUrl =
      'https://img.vietqr.io/image/TCB-84336813825-compact2.png';

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Ủng hộ tác giả (Donate)',
      child: TextButton.icon(
        onPressed: () => _showDonateDialog(context),
        icon: const Icon(Icons.coffee_outlined, color: Colors.white, size: 18),
        label: const Text(
          'Ủng hộ',
          maxLines: 1,
          style: TextStyle(color: Colors.white, fontSize: 12),
        ),
        style: TextButton.styleFrom(
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 4),
          visualDensity: VisualDensity.compact,
        ),
      ),
    );
  }

  void _showDonateDialog(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 400,
            maxHeight: MediaQuery.sizeOf(dialogContext).height * 0.85,
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    const Text('☕', style: TextStyle(fontSize: 21)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Ủng hộ tác giả (Donate)',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.bold,
                          color: Colors.orange.shade900,
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.of(dialogContext).pop(),
                      tooltip: 'Đóng',
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                Text(
                  'Nếu ứng dụng giúp công việc của bạn nhanh hơn, hãy thưởng '
                  'cho tác giả một ly cà phê nhé. Cảm ơn bạn đã ủng hộ!',
                  style: TextStyle(
                    fontSize: 13,
                    fontStyle: FontStyle.italic,
                    color: Colors.brown.shade800,
                    height: 1.35,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.orange.shade100),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.asset(
                      'assets/images/qr_donate.png',
                      width: 160,
                      fit: BoxFit.contain,
                      errorBuilder: (context, error, stackTrace) =>
                          Image.network(
                            _qrUrl,
                            width: 160,
                            fit: BoxFit.contain,
                          ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.orange.shade100),
                  ),
                  child: Column(
                    children: [
                      _buildInfoRow('Ngân hàng', _bankName, isBold: true),
                      const Divider(height: 12),
                      _buildInfoRow(
                        'Chủ tài khoản',
                        _accountName,
                        isBold: true,
                      ),
                      const Divider(height: 12),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'Số tài khoản',
                            style: TextStyle(
                              fontSize: 13,
                              color: Colors.grey[700],
                            ),
                          ),
                          Row(
                            children: [
                              const Text(
                                '8433 6813 825',
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.blueAccent,
                                ),
                              ),
                              const SizedBox(width: 6),
                              InkWell(
                                onTap: () {
                                  Clipboard.setData(
                                    const ClipboardData(text: _accountNumber),
                                  );
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text(
                                        'Đã sao chép số tài khoản.',
                                      ),
                                      duration: Duration(seconds: 2),
                                      backgroundColor: Colors.green,
                                    ),
                                  );
                                },
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 4,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.blue.shade50,
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Row(
                                    children: [
                                      Icon(
                                        Icons.copy,
                                        size: 14,
                                        color: Colors.blue.shade700,
                                      ),
                                      const SizedBox(width: 2),
                                      Text(
                                        'Copy',
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: Colors.blue.shade700,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildInfoRow(String label, String value, {bool isBold = false}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: TextStyle(fontSize: 13, color: Colors.grey[700])),
        Text(
          value,
          style: TextStyle(
            fontSize: 13,
            fontWeight: isBold ? FontWeight.bold : FontWeight.normal,
            color: Colors.black87,
          ),
        ),
      ],
    );
  }
}
