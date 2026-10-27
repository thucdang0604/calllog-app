import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../providers/call_log_provider.dart';
import '../services/app_update_service.dart';
import '../widgets/floating_window_widget.dart';
import '../widgets/fake_gps_widget.dart';
import '../widgets/timemark_camera_widget.dart';
import 'payment_reconciliation_screen.dart';

class SimpleHomeScreen extends StatefulWidget {
  const SimpleHomeScreen({super.key});

  @override
  State<SimpleHomeScreen> createState() => _SimpleHomeScreenState();
}

class _SimpleHomeScreenState extends State<SimpleHomeScreen>
    with WidgetsBindingObserver {
  final AppUpdateService _appUpdateService = AppUpdateService();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadCallLogs(force: false);
      _checkForAppUpdate();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
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
                // Floating Window Control
                const FloatingWindowWidget(),

                // Vị trí giả lập (Fake GPS)
                const FakeGpsWidget(),

                // TimeMark: camera hệ thống chỉ mở khi người dùng bấm chụp.
                const TimeMarkCameraWidget(),

                // Cấu hình Tin nhắn SMS mẫu
                const _SmsTemplateConfigWidget(),

                // 2 cuộc gọi gần nhất (preview)
                _buildLatestCallsPreview(provider),
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

class _SmsTemplateConfigWidgetState extends State<_SmsTemplateConfigWidget> {
  final TextEditingController _controller = TextEditingController();
  bool _hasSmsPermission = false;
  bool _hasIncomingSmsPermission = false;
  bool _isSmsFakeMode = false;
  bool _isAutoFakeSmsIntent = false;
  Map<String, dynamic>? _licenseDetails;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadConfig();
  }

  Future<void> _loadConfig() async {
    try {
      const channel = MethodChannel('call_log_manager');
      final String template = await channel.invokeMethod('getSmsTemplate');
      final bool hasPerm = await channel.invokeMethod('hasSmsPermission');
      final bool hasIncomingPerm = await channel.invokeMethod(
        'hasIncomingSmsPermission',
      );
      final bool smsFakeMode = await channel.invokeMethod('getSmsFakeMode');
      final bool autoFakeIntent =
          await channel.invokeMethod('getAutoFakeSmsIntent') ?? false;

      Map<String, dynamic>? licenseInfo;
      try {
        final String? licenseStr =
            await channel.invokeMethod<String>('getSmsLicenseDetails');
        if (licenseStr != null && licenseStr.isNotEmpty) {
          licenseInfo = jsonDecode(licenseStr) as Map<String, dynamic>;
        }
      } catch (_) {}

      if (mounted) {
        setState(() {
          _controller.text = template;
          _hasSmsPermission = hasPerm;
          _hasIncomingSmsPermission = hasIncomingPerm;
          _isSmsFakeMode = smsFakeMode;
          _isAutoFakeSmsIntent = autoFakeIntent;
          _licenseDetails = licenseInfo;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
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

  Future<void> _toggleSmsFakeMode(bool enabled) async {
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
      final saved = await channel.invokeMethod<bool>('setSmsFakeMode', {
        'enabled': enabled,
      });
      if (saved != true) throw StateError('Không lưu được chế độ SMS');
      if (mounted) {
        setState(() => _isSmsFakeMode = enabled);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              enabled
                  ? 'SMS ảo sẽ nằm trong mục Đã gửi, khách không nhận được'
                  : 'Đã chuyển về gửi SMS thật qua SIM',
            ),
            backgroundColor: enabled ? Colors.deepOrange : Colors.green,
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Không đổi được chế độ SMS: $error')),
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
                  ? '⚡ Đã bật tự động tạo SMS ảo và đóng ngay khi bấm từ APP'
                  : 'Đã chuyển sang hiện hộp thoại xác nhận khi bấm từ APP',
            ),
            backgroundColor: enabled ? Colors.green[700] : Colors.grey[700],
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Không đổi được cài đặt: $error')),
      );
    }
  }

  void _showLicenseModal() {
    final TextEditingController keyCtrl = TextEditingController();
    final String devId = _licenseDetails?['deviceId'] ?? 'SMS-XXXX-XXXX';
    final bool isLicensed = _licenseDetails?['isLicensed'] == true;
    final int remainingTrial = _licenseDetails?['remainingTrial'] as int? ?? 0;
    final String cleanDev = devId.replaceAll('SMS-', '').replaceAll('-', '');
    final String transferContent = 'SMS $cleanDev';
    final String qrUrl =
        'https://img.vietqr.io/image/970407-19034108972011-compact2.png?amount=50000&addInfo=SMS%20$cleanDev&accountName=Dang%20Tri%20Thuc';

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            return Container(
              padding: EdgeInsets.only(
                left: 16,
                right: 16,
                top: 20,
                bottom: MediaQuery.of(ctx).viewInsets.bottom + 24,
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
                    Center(
                      child: Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: Colors.grey[300],
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        Icon(
                          Icons.verified_user,
                          color: isLicensed
                              ? Colors.green[700]
                              : Colors.orange[800],
                          size: 26,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          isLicensed
                              ? 'Bản Quyền Đã Kích Hoạt'
                              : 'Nâng Cấp Bản Quyền SMS Ảo',
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),

                    // Device ID Box
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.grey[100],
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: Colors.grey[300]!),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'MÃ THIẾT BỊ (CỐ ĐỊNH PHẦN CỨNG):',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.grey,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  devId,
                                  style: const TextStyle(
                                    fontSize: 17,
                                    fontWeight: FontWeight.bold,
                                    letterSpacing: 1,
                                    fontFamily: 'monospace',
                                  ),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.copy, size: 20),
                            onPressed: () {
                              Clipboard.setData(ClipboardData(text: devId));
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text(' Đã sao chép mã thiết bị!'),
                                  duration: Duration(seconds: 2),
                                ),
                              );
                            },
                          ),
                        ],
                      ),
                    ),

                    if (!isLicensed) ...[
                      const SizedBox(height: 14),
                      Text(
                        remainingTrial > 0
                            ? '⚡ Trải nghiệm miễn phí: Còn $remainingTrial/10 tin nhắn.'
                            : '⚠️ Đã sử dụng hết 10 lượt trải nghiệm miễn phí.',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: remainingTrial > 0
                              ? Colors.orange[800]
                              : Colors.red[700],
                        ),
                      ),
                      const SizedBox(height: 12),

                      // Phương án 1: VietQR Auto
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.green.withValues(alpha: 0.06),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: Colors.green.withValues(alpha: 0.3),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.green[700],
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: const Text(
                                    'PHƯƠNG ÁN 1',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                const Text(
                                  'Quét Mã VietQR Chuyển Khoản',
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            Center(
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: Image.network(
                                  qrUrl,
                                  width: 190,
                                  height: 190,
                                  fit: BoxFit.contain,
                                  errorBuilder:
                                      (_, __, ___) =>
                                          const Text('Không tải được ảnh QR'),
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              '• Ngân hàng: Techcombank\n• STK: 19034108972011 (DANG TRI THUC)\n• Số tiền: 50.000đ\n• Nội dung: $transferContent',
                              style: const TextStyle(fontSize: 12, height: 1.4),
                            ),
                            const SizedBox(height: 6),
                            OutlinedButton.icon(
                              onPressed: () {
                                Clipboard.setData(
                                  ClipboardData(text: transferContent),
                                );
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      ' Đã sao chép nội dung: $transferContent',
                                    ),
                                    duration: const Duration(seconds: 2),
                                  ),
                                );
                              },
                              icon: const Icon(Icons.copy, size: 16),
                              label: const Text('Sao chép nội dung CK'),
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 14),
                      // Phương án 2: Nhập mã offline
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.grey[50],
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Colors.grey[300]!),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.grey[700],
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: const Text(
                                    'PHƯƠNG ÁN 2 (DỰ PHÒNG)',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                const Text(
                                  'Nhập Mã Kích Hoạt Thủ Công',
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            TextField(
                              controller: keyCtrl,
                              textCapitalization: TextCapitalization.characters,
                              decoration: const InputDecoration(
                                hintText: 'VD: NV1-PERM-00000000-XXXXXXXX',
                                border: OutlineInputBorder(),
                                contentPadding: EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 8,
                                ),
                              ),
                              style: const TextStyle(
                                fontSize: 13,
                                fontFamily: 'monospace',
                              ),
                            ),
                            const SizedBox(height: 8),
                            SizedBox(
                              width: double.infinity,
                              child: ElevatedButton.icon(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.green[700],
                                  foregroundColor: Colors.white,
                                ),
                                onPressed: () async {
                                  final key = keyCtrl.text.trim();
                                  if (key.isEmpty) return;
                                  const channel = MethodChannel(
                                    'call_log_manager',
                                  );
                                  final bool? ok = await channel
                                      .invokeMethod<bool>(
                                        'activateSmsLicense',
                                        {'key': key},
                                      );
                                  if (ok == true) {
                                    if (context.mounted) {
                                      Navigator.pop(ctx);
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        const SnackBar(
                                          content: Text(
                                            '🎉 Kích hoạt bản quyền thành công!',
                                          ),
                                          backgroundColor: Colors.green,
                                        ),
                                      );
                                      _loadConfig();
                                    }
                                  } else {
                                    if (context.mounted) {
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        const SnackBar(
                                          content: Text(
                                            '❌ Mã kích hoạt không hợp lệ cho thiết bị này!',
                                          ),
                                          backgroundColor: Colors.red,
                                        ),
                                      );
                                    }
                                  }
                                },
                                icon: const Icon(Icons.key, size: 18),
                                label: const Text('KÍCH HOẠT BẰNG MÃ'),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ] else ...[
                      const SizedBox(height: 16),
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: Colors.green.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: Colors.green),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Gói bản quyền: ${_licenseDetails?['plan'] ?? ''}',
                              style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Hạn dùng: ${_licenseDetails?['expiresAtFormatted'] ?? 'Vĩnh viễn'}',
                              style: TextStyle(
                                fontSize: 13,
                                color: Colors.green[800],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  @override
  void dispose() {
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

          // === Toggle SMS Ảo ===
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: _isSmsFakeMode
                  ? Colors.deepOrange.withValues(alpha: 0.08)
                  : Colors.grey.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: _isSmsFakeMode
                    ? Colors.deepOrange.withValues(alpha: 0.4)
                    : Colors.grey.withValues(alpha: 0.2),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  _isSmsFakeMode
                      ? Icons.sms_failed_outlined
                      : Icons.sms_outlined,
                  color: _isSmsFakeMode ? Colors.deepOrange : Colors.grey[600],
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
                              'SMS ảo',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: _isSmsFakeMode
                                    ? Colors.deepOrange[800]
                                    : Colors.grey[800],
                              ),
                            ),
                          ),
                          if (_isSmsFakeMode) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 1,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.deepOrange,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: const Text(
                                'ĐANG BẬT',
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
                        _isSmsFakeMode
                            ? 'Hiện trong SMS đã gửi · khách không nhận · cần đổi app SMS tạm thời'
                            : 'Gửi SMS thật qua SIM khi tắt chế độ ảo',
                        style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                      ),
                    ],
                  ),
                ),
                Switch(
                  value: _isSmsFakeMode,
                  onChanged: _toggleSmsFakeMode,
                  activeColor: Colors.deepOrange,
                ),
              ],
            ),
          ),

          // === Toggle Tự động tạo SMS ảo từ APP ===
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
                              'Tự tạo SMS ảo từ APP',
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
                            ? 'Bấm icon tin nhắn trong app sẽ tự ghi vào Đã gửi và đóng ngay'
                            : 'Hiện popup để chọn Tạo SMS ảo hoặc Gửi thật qua SIM',
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
                onPressed: _isSmsFakeMode ? null : _requestSmsPermission,
                icon: Icon(
                  _isSmsFakeMode || _hasSmsPermission
                      ? Icons.check_circle
                      : Icons.warning_amber_rounded,
                  color: _isSmsFakeMode || _hasSmsPermission
                      ? Colors.green
                      : Colors.orange,
                  size: 18,
                ),
                label: Text(
                  _isSmsFakeMode
                      ? 'Đổi app khi tạo'
                      : (_hasSmsPermission ? 'Đã có quyền' : 'Cấp quyền SMS'),
                  style: TextStyle(
                    color: _isSmsFakeMode || _hasSmsPermission
                        ? Colors.green[700]
                        : Colors.orange[800],
                    fontWeight: FontWeight.bold,
                  ),
                ),
                style: OutlinedButton.styleFrom(
                  side: BorderSide(
                    color: _isSmsFakeMode || _hasSmsPermission
                        ? Colors.green
                        : Colors.orange,
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
