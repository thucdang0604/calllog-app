import 'dart:io';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

String _formatPaymentTime(int timestamp) {
  final date = DateTime.fromMillisecondsSinceEpoch(timestamp).toLocal();
  final day = date.day.toString().padLeft(2, '0');
  final month = date.month.toString().padLeft(2, '0');
  final hour = date.hour.toString().padLeft(2, '0');
  final minute = date.minute.toString().padLeft(2, '0');
  return '$day/$month/${date.year} $hour:$minute';
}

class PaymentReconciliationScreen extends StatefulWidget {
  const PaymentReconciliationScreen({super.key});

  @override
  State<PaymentReconciliationScreen> createState() =>
      _PaymentReconciliationScreenState();
}

class _PaymentReconciliationScreenState
    extends State<PaymentReconciliationScreen> {
  static const MethodChannel _channel = MethodChannel('call_log_manager');
  static const EventChannel _paymentEvents = EventChannel(
    'call_log_manager/payment_tracking_events',
  );

  List<_PaymentRecord> _records = [];
  StreamSubscription<dynamic>? _paymentEventsSubscription;
  bool _isLoading = true;
  String? _error;

  List<_PaymentRecord> get _trackableRecords => _records
      .where((record) => record.smsStatus == 'sent' || record.smsStatus.isEmpty)
      .toList();

  List<_PaymentRecord> get _pending =>
      _trackableRecords.where((record) => !record.isReceived).toList();

  List<_PaymentRecord> get _received =>
      _trackableRecords.where((record) => record.isReceived).toList();

  @override
  void initState() {
    super.initState();
    _loadRecords();
    _paymentEventsSubscription = _paymentEvents.receiveBroadcastStream().listen(
      (_) => _loadRecords(showLoading: false),
      onError: (_) {},
    );
  }

  @override
  void dispose() {
    _paymentEventsSubscription?.cancel();
    super.dispose();
  }

  Future<void> _loadRecords({bool showLoading = true}) async {
    if (showLoading) {
      setState(() {
        _isLoading = true;
        _error = null;
      });
    }

    try {
      final result = await _channel.invokeListMethod<dynamic>(
        'getPaymentTrackingRecords',
      );
      final records =
          (result ?? const <dynamic>[])
              .whereType<Map<dynamic, dynamic>>()
              .map((record) => _PaymentRecord.fromMap(record))
              .toList()
            ..sort((a, b) => b.sentAt.compareTo(a.sentAt));

      if (!mounted) return;
      setState(() {
        _records = records;
        _isLoading = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = 'Không tải được danh sách: $error';
        _isLoading = false;
      });
    }
  }

  Future<void> _setReceived(_PaymentRecord record, bool received) async {
    try {
      await _channel.invokeMethod<bool>('setPaymentTrackingReceived', {
        'id': record.id,
        'received': received,
      });
      await _loadRecords();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Không cập nhật được trạng thái: $error')),
      );
    }
  }

  Future<void> _deleteRecord(_PaymentRecord record) async {
    final shouldDelete = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Xóa khoản chuyển khoản?'),
        content: Text(
          '${record.orderCode.isEmpty ? 'Chưa có mã đơn' : 'Đơn ${record.orderCode}'}\n'
          '${record.phone} · ${_formatAmount(record.amountValue, fallback: record.amount)}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Hủy'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Xóa'),
          ),
        ],
      ),
    );
    if (shouldDelete != true) return;

    try {
      final deleted = await _channel.invokeMethod<bool>(
        'deletePaymentTrackingRecord',
        {'id': record.id},
      );
      await _loadRecords();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            deleted == true
                ? 'Đã xóa khoản chuyển khoản.'
                : 'Khoản này không còn trong danh sách.',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Không xóa được khoản này: $error')),
      );
    }
  }

  Future<void> _copyOrderCode(String orderCode) async {
    final code = orderCode.trim();
    if (code.isEmpty) return;

    await Clipboard.setData(ClipboardData(text: code));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Đã sao chép mã vận đơn.')),
    );
  }

  Future<void> _showRecordDetails(_PaymentRecord record) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => _PaymentRecordDetailsScreen(
          record: record,
          channel: _channel,
          sentAtText: _formatTime(record.sentAt),
          amountText: _formatAmount(
            record.amountValue,
            fallback: record.amount,
          ),
        ),
      ),
    );
  }

  Future<void> _clearReceivedRecords() async {
    if (_received.isEmpty) return;
    final shouldClear = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Xóa các khoản đã nhận?'),
        content: Text(
          'Sẽ xóa ${_received.length} khoản đã nhận và ảnh lưu kèm. '
          'Các khoản đang chờ sẽ được giữ lại.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Hủy'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Xóa'),
          ),
        ],
      ),
    );
    if (shouldClear != true) return;

    try {
      final removed = await _channel.invokeMethod<int>(
        'clearReceivedPaymentRecords',
      );
      await _loadRecords();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Đã xóa ${removed ?? 0} khoản đã nhận.')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Không xóa được danh sách: $error')),
      );
    }
  }

  String _formatTime(int timestamp) {
    return _formatPaymentTime(timestamp);
  }

  @override
  Widget build(BuildContext context) {
    final pendingRecords = _pending;
    final receivedRecords = _received;
    final pendingTotal = _pending.fold<int>(
      0,
      (total, record) => total + record.amountValue,
    );
    final receivedTotal = _received.fold<int>(
      0,
      (total, record) => total + record.amountValue,
    );
    const headerItemCount = 4;
    final pendingItemCount = pendingRecords.isEmpty ? 1 : pendingRecords.length;
    final receivedStartIndex = headerItemCount + pendingItemCount;
    final itemCount = receivedStartIndex + (receivedRecords.isEmpty ? 0 : 2);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Đối soát chuyển khoản'),
        actions: [
          IconButton(
            onPressed: _received.isEmpty ? null : _clearReceivedRecords,
            tooltip: 'Xóa tất cả khoản đã nhận',
            icon: const Icon(Icons.delete_sweep_outlined),
          ),
          IconButton(
            onPressed: _loadRecords,
            tooltip: 'Làm mới',
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_error!, textAlign: TextAlign.center),
                    const SizedBox(height: 12),
                    ElevatedButton(
                      onPressed: _loadRecords,
                      child: const Text('Thử lại'),
                    ),
                  ],
                ),
              ),
            )
          : RefreshIndicator(
              onRefresh: _loadRecords,
              child: ListView.builder(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                itemCount: itemCount,
                itemBuilder: (context, index) {
                  if (index == 0) {
                    return _buildSummary(pendingTotal, receivedTotal);
                  }
                  if (index == 1) return const SizedBox(height: 20);
                  if (index == 2) {
                    return _buildSectionTitle(
                      'Chờ khách chuyển (${pendingRecords.length})',
                      Icons.hourglass_top,
                      Colors.orange.shade800,
                    );
                  }
                  if (index == 3) return const SizedBox(height: 8);

                  if (index < receivedStartIndex) {
                    if (pendingRecords.isEmpty) {
                      return _buildEmptyState('Không còn khoản nào đang chờ.');
                    }
                    return _buildRecordCard(
                      pendingRecords[index - headerItemCount],
                      received: false,
                    );
                  }

                  if (index == receivedStartIndex) {
                    return const SizedBox(height: 12);
                  }
                  if (index == receivedStartIndex + 1) {
                    return Card(
                      child: ExpansionTile(
                        leading: Icon(
                          Icons.check_circle_outline,
                          color: Colors.green.shade700,
                        ),
                        title: Text('Đã nhận (${receivedRecords.length})'),
                        children: receivedRecords
                            .map(
                              (record) =>
                                  _buildRecordCard(record, received: true),
                            )
                            .toList(),
                      ),
                    );
                  }
                  return const SizedBox.shrink();
                },
              ),
            ),
    );
  }

  Widget _buildSummary(int pendingTotal, int receivedTotal) {
    final repliedPendingCount = _pending
        .where((record) => record.customerReplied)
        .length;
    return Card(
      color: Colors.orange.shade50,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(Icons.account_balance_wallet, color: Colors.orange.shade800),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${_pending.length} khoản đang chờ · ${_received.length} đã nhận',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 3),
                  Text('Tổng đang chờ: ${_formatAmount(pendingTotal)}'),
                  Text('Tổng đã nhận: ${_formatAmount(receivedTotal)}'),
                  Text('Khách đã phản hồi: $repliedPendingCount'),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionTitle(String title, IconData icon, Color color) {
    return Row(
      children: [
        Icon(icon, size: 19, color: color),
        const SizedBox(width: 8),
        Text(
          title,
          style: TextStyle(fontWeight: FontWeight.bold, color: color),
        ),
      ],
    );
  }

  Widget _buildEmptyState(String message) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Center(
          child: Text(message, style: TextStyle(color: Colors.grey.shade700)),
        ),
      ),
    );
  }

  Widget _buildRecordCard(_PaymentRecord record, {required bool received}) {
    final phoneDigits = record.phone.replaceAll(RegExp(r'[^0-9]'), '');
    final lastFour = phoneDigits.length <= 4
        ? phoneDigits
        : phoneDigits.substring(phoneDigits.length - 4);
    final leading = record.imagePath.isNotEmpty
        ? ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.file(
              File(record.imagePath),
              width: 52,
              height: 52,
              cacheWidth: (52 * MediaQuery.of(context).devicePixelRatio)
                  .round(),
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => _recordIcon(received),
            ),
          )
        : _recordIcon(received);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      color: record.customerReplied ? Colors.lightBlue.shade50 : null,
      child: ListTile(
        onTap: () => _showRecordDetails(record),
        leading: leading,
        title: Row(
          children: [
            Expanded(
              child: Text(
                record.phone,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            if (record.customerReplied)
              Icon(
                Icons.mark_chat_read_outlined,
                size: 19,
                color: Colors.blue.shade800,
              ),
          ],
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${_formatAmount(record.amountValue, fallback: record.amount)} · ${_formatTime(record.sentAt)}',
            ),
            const SizedBox(height: 2),
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              children: [
                if (record.orderCode.isEmpty)
                  const Text('Chưa quét mã đơn')
                else
                  InkWell(
                    onTap: () => _copyOrderCode(record.orderCode),
                    borderRadius: BorderRadius.circular(4),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(
                            child: Text(
                              'Mã đơn: ${record.orderCode}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.primary,
                                fontWeight: FontWeight.w600,
                                decoration: TextDecoration.underline,
                              ),
                            ),
                          ),
                          const SizedBox(width: 4),
                          Icon(
                            Icons.copy_outlined,
                            size: 14,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                        ],
                      ),
                    ),
                  ),
                Text(
                  '4 số cuối: ${lastFour.isEmpty ? '----' : lastFour}',
                ),
              ],
            ),
            if (record.customerReplied)
              Text(
                '✉ Khách đã phản hồi · ${_formatTime(record.replyReceivedAt)}',
              ),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: 'Xóa khoản này',
              onPressed: () => _deleteRecord(record),
              icon: const Icon(Icons.delete_outline),
            ),
            Checkbox(
              value: received,
              onChanged: (value) => _setReceived(record, value ?? false),
            ),
          ],
        ),
      ),
    );
  }

  Widget _recordIcon(bool received) {
    return CircleAvatar(
      backgroundColor: received ? Colors.green.shade50 : Colors.orange.shade50,
      child: Icon(
        received ? Icons.check : Icons.sms_outlined,
        color: received ? Colors.green.shade700 : Colors.orange.shade800,
      ),
    );
  }

  String _formatAmount(int value, {String? fallback}) {
    if (value <= 0) return '${fallback ?? '0'}đ';
    final digits = value.toString();
    final buffer = StringBuffer();
    for (var index = 0; index < digits.length; index++) {
      if (index > 0 && (digits.length - index) % 3 == 0) {
        buffer.write('.');
      }
      buffer.write(digits[index]);
    }
    return '${buffer.toString()}đ';
  }
}

class _PaymentRecord {
  const _PaymentRecord({
    required this.id,
    required this.phone,
    required this.amount,
    required this.amountValue,
    required this.sentAt,
    required this.isReceived,
    required this.smsStatus,
    required this.message,
    required this.orderCode,
    required this.imagePath,
    required this.customerReplied,
    required this.replyPhone,
    required this.replyMessage,
    required this.replyReceivedAt,
  });

  final String id;
  final String phone;
  final String amount;
  final int amountValue;
  final int sentAt;
  final bool isReceived;
  final String smsStatus;
  final String message;
  final String orderCode;
  final String imagePath;
  final bool customerReplied;
  final String replyPhone;
  final String replyMessage;
  final int replyReceivedAt;

  factory _PaymentRecord.fromMap(Map<dynamic, dynamic> map) {
    final amount = map['amount']?.toString() ?? '';
    final digits = amount.replaceAll(RegExp(r'[^0-9]'), '');
    return _PaymentRecord(
      id: map['id']?.toString() ?? '',
      phone: map['phone']?.toString() ?? 'Không rõ số điện thoại',
      amount: amount,
      amountValue: int.tryParse(digits) ?? 0,
      sentAt: (map['sentAt'] as num?)?.toInt() ?? 0,
      isReceived: map['status']?.toString() == 'received',
      smsStatus: map['smsStatus']?.toString() ?? '',
      message: map['message']?.toString() ?? '',
      orderCode: map['orderCode']?.toString() ?? '',
      imagePath: map['imagePath']?.toString() ?? '',
      customerReplied: map['customerReplied'] == true,
      replyPhone: map['replyPhone']?.toString() ?? '',
      replyMessage: map['replyMessage']?.toString() ?? '',
      replyReceivedAt: (map['replyReceivedAt'] as num?)?.toInt() ?? 0,
    );
  }
}

class _PaymentRecordDetailsScreen extends StatefulWidget {
  const _PaymentRecordDetailsScreen({
    required this.record,
    required this.channel,
    required this.sentAtText,
    required this.amountText,
  });

  final _PaymentRecord record;
  final MethodChannel channel;
  final String sentAtText;
  final String amountText;

  @override
  State<_PaymentRecordDetailsScreen> createState() =>
      _PaymentRecordDetailsScreenState();
}

class _PaymentRecordDetailsScreenState
    extends State<_PaymentRecordDetailsScreen> {
  bool _isSavingImage = false;

  Future<void> _openSmsConversation() async {
    try {
      await widget.channel.invokeMethod<bool>('openSmsConversation', {
        'phone': widget.record.phone,
      });
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Không mở được hội thoại SMS: $error')),
      );
    }
  }

  Future<void> _saveImage() async {
    if (_isSavingImage) return;
    setState(() => _isSavingImage = true);
    try {
      await widget.channel.invokeMethod<String>('savePaymentTrackingImage', {
        'id': widget.record.id,
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Đã lưu ảnh vào Pictures/PaymentReceipts.'),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Không lưu được ảnh: $error')));
    } finally {
      if (mounted) setState(() => _isSavingImage = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final record = widget.record;
    final photoHeight = (MediaQuery.of(context).size.height * 0.5)
        .clamp(240.0, 480.0)
        .toDouble();
    final imageCacheWidth =
        (MediaQuery.of(context).size.width *
                MediaQuery.of(context).devicePixelRatio)
            .round()
            .clamp(1, 2048)
            .toInt();

    return Scaffold(
      appBar: AppBar(
        title: Text(
          record.orderCode.isEmpty
              ? 'Chi tiết khoản chuyển'
              : 'Đơn ${record.orderCode}',
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            clipBehavior: Clip.antiAlias,
            child: record.imagePath.isEmpty
                ? const SizedBox(
                    height: 180,
                    child: Center(
                      child: Text('Khoản này chưa có ảnh đơn hàng.'),
                    ),
                  )
                : SizedBox(
                    width: double.infinity,
                    height: photoHeight,
                    child: InteractiveViewer(
                      minScale: 0.8,
                      maxScale: 5,
                      child: Image.file(
                        File(record.imagePath),
                        width: double.infinity,
                        height: photoHeight,
                        cacheWidth: imageCacheWidth,
                        fit: BoxFit.contain,
                        errorBuilder: (_, __, ___) => const Center(
                          child: Padding(
                            padding: EdgeInsets.all(20),
                            child: Text(
                              'Không đọc được ảnh trên thiết bị. Có thể ảnh đã bị xóa hoặc bản ghi được tạo trước khi lưu ảnh được bật.',
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
          ),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.phone_outlined),
                  title: const Text('Số điện thoại'),
                  subtitle: Text(record.phone),
                ),
                ListTile(
                  leading: const Icon(Icons.payments_outlined),
                  title: const Text('Số tiền'),
                  subtitle: Text(widget.amountText),
                ),
                ListTile(
                  leading: Icon(
                    record.isReceived
                        ? Icons.check_circle_outline
                        : Icons.hourglass_top,
                  ),
                  title: const Text('Trạng thái'),
                  subtitle: Text(record.isReceived ? 'Đã nhận' : 'Đang chờ'),
                ),
                ListTile(
                  leading: const Icon(Icons.schedule),
                  title: const Text('Gửi lúc'),
                  subtitle: Text(widget.sentAtText),
                ),
              ],
            ),
          ),
          if (record.customerReplied)
            Card(
              color: Colors.lightBlue.shade50,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.mark_chat_read_outlined,
                          color: Colors.blue.shade800,
                        ),
                        const SizedBox(width: 8),
                        const Expanded(
                          child: Text(
                            'Khách đã phản hồi qua SMS',
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '${record.replyPhone.isEmpty ? record.phone : record.replyPhone} · '
                      '${record.replyReceivedAt > 0 ? _formatPaymentTime(record.replyReceivedAt) : 'Thời gian không rõ'}',
                      style: TextStyle(
                        color: Colors.blueGrey.shade700,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      record.replyMessage.isEmpty
                          ? '(Không có nội dung SMS)'
                          : record.replyMessage,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Đây là dấu hiệu khách đã nhắn lại, chưa xác nhận đã chuyển tiền. SMS không có mã đơn nên nếu số này có nhiều đơn đang chờ, tất cả đơn cùng số sẽ được làm nổi bật.',
                      style: TextStyle(
                        color: Colors.blueGrey.shade700,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          Card(
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: _openSmsConversation,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Expanded(
                          child: Text(
                            'Nội dung tin nhắn',
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ),
                        Icon(
                          Icons.open_in_new,
                          size: 18,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      record.message.isEmpty
                          ? '(Không có nội dung)'
                          : record.message,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Chạm để mở hội thoại SMS với khách',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.primary,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
      bottomNavigationBar: record.imagePath.isEmpty
          ? null
          : SafeArea(
              minimum: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: FilledButton.icon(
                onPressed: _isSavingImage ? null : _saveImage,
                icon: _isSavingImage
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.download_outlined),
                label: Text(
                  _isSavingImage ? 'Đang lưu ảnh...' : 'Tải ảnh về thư viện',
                ),
              ),
            ),
    );
  }
}
