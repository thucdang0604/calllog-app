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
      if (mounted) {
        setState(() {
          _controller.text = template;
          _hasSmsPermission = hasPerm;
          _hasIncomingSmsPermission = hasIncomingPerm;
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
