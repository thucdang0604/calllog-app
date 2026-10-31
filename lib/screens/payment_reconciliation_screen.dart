import 'dart:io';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'payment_account_settings_screen.dart';

String _formatPaymentTime(int timestamp) {
  final date = DateTime.fromMillisecondsSinceEpoch(timestamp).toLocal();
  final day = date.day.toString().padLeft(2, '0');
  final month = date.month.toString().padLeft(2, '0');
  final hour = date.hour.toString().padLeft(2, '0');
  final minute = date.minute.toString().padLeft(2, '0');
  return '$day/$month/${date.year} $hour:$minute';
}

String _zaloStatusLabel(String status) {
  switch (status) {
    case 'share_opened':
      return 'Đã mở luồng chia sẻ Zalo';
    case 'awaiting_scan':
      return 'Đang chờ quét mã đơn';
    case 'draft_ready':
      return 'QR kèm số tiền đã sao chép; chờ gửi trong chat';
    case 'chat_opened':
      return 'Đã mở chat Zalo; chưa có QR đã xác nhận';
    case 'sent_confirmed':
      return 'Người dùng xác nhận đã bấm Gửi';
    default:
      return 'Chưa rõ trạng thái gửi';
  }
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
  final _searchController = TextEditingController();
  String _channelFilter = 'all';
  StreamSubscription<dynamic>? _paymentEventsSubscription;
  bool _isLoading = true;
  String? _error;

  List<_PaymentRecord> get _trackableRecords => _records
      .where(
        (record) =>
            record.channel == 'zalo' ||
            record.smsStatus == 'sent' ||
            record.smsStatus == 'simulated' ||
            record.smsStatus.isEmpty,
      )
      .toList();

  List<_PaymentRecord> get _filteredRecords {
    final query = _searchController.text.trim().toLowerCase();
    return _trackableRecords.where((record) {
      if (_channelFilter != 'all' && record.channel != _channelFilter) {
        return false;
      }
      if (query.isEmpty) return true;
      return <String>[
        record.phone,
        record.amount,
        record.orderCode,
        record.message,
        record.replyMessage,
      ].any((value) => value.toLowerCase().contains(query));
    }).toList();
  }

  List<_PaymentRecord> get _pending =>
      _filteredRecords.where((record) => !record.isReceived).toList();

  List<_PaymentRecord> get _received =>
      _filteredRecords.where((record) => record.isReceived).toList();

  List<_PaymentRecord> get _allReceived =>
      _records.where((record) => record.isReceived).toList();

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
    _searchController.dispose();
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
            ..sort((a, b) => b.sortTime.compareTo(a.sortTime));

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
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Đã sao chép mã vận đơn.')));
  }

  Future<void> _showRecordDetails(_PaymentRecord record) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => _PaymentRecordDetailsScreen(
          record: record,
          channel: _channel,
          amountText: _formatAmount(
            record.amountValue,
            fallback: record.amount,
          ),
        ),
      ),
    );
    await _loadRecords(showLoading: false);
  }

  Future<void> _openConversation(_PaymentRecord record) async {
    try {
      await _channel.invokeMethod<bool>(
        record.channel == 'zalo' ? 'openZaloConversation' : 'openSmsConversation',
        {'phone': record.phone},
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Không mở được hội thoại: $error')),
      );
    }
  }

  Future<void> _clearReceivedRecords() async {
    if (_allReceived.isEmpty) return;
    final shouldClear = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Xóa các khoản đã nhận?'),
        content: Text(
          'Sẽ xóa ${_allReceived.length} khoản đã nhận và ảnh lưu kèm. '
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
    const headerItemCount = 6;
    final pendingItemCount = pendingRecords.isEmpty ? 1 : pendingRecords.length;
    final receivedStartIndex = headerItemCount + pendingItemCount;
    final itemCount = receivedStartIndex + (receivedRecords.isEmpty ? 0 : 2);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Đối soát chuyển khoản'),
        actions: [
          IconButton(
            onPressed: () => Navigator.of(context).push<bool>(
              MaterialPageRoute<bool>(
                builder: (_) => const PaymentAccountSettingsScreen(),
              ),
            ),
            tooltip: 'Cấu hình tài khoản QR Zalo',
            icon: const Icon(Icons.account_balance_outlined),
          ),
          IconButton(
            onPressed: _allReceived.isEmpty ? null : _clearReceivedRecords,
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
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: TextField(
                        controller: _searchController,
                        decoration: InputDecoration(
                          prefixIcon: const Icon(Icons.search),
                          hintText: 'Tìm SĐT, mã đơn, số tiền, nội dung',
                          suffixIcon: _searchController.text.isEmpty
                              ? null
                              : IconButton(
                                  onPressed: () => setState(
                                    _searchController.clear,
                                  ),
                                  icon: const Icon(Icons.clear),
                                ),
                          border: const OutlineInputBorder(),
                          isDense: true,
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                    );
                  }
                  if (index == 3) {
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Wrap(
                        spacing: 8,
                        children: [
                          ChoiceChip(
                            label: const Text('Tất cả'),
                            selected: _channelFilter == 'all',
                            onSelected: (_) =>
                                setState(() => _channelFilter = 'all'),
                          ),
                          ChoiceChip(
                            avatar: const Icon(Icons.sms_outlined, size: 16),
                            label: const Text('SMS'),
                            selected: _channelFilter == 'sms',
                            onSelected: (_) =>
                                setState(() => _channelFilter = 'sms'),
                          ),
                          ChoiceChip(
                            avatar: const Icon(Icons.chat_bubble_outline, size: 16),
                            label: const Text('Zalo'),
                            selected: _channelFilter == 'zalo',
                            onSelected: (_) =>
                                setState(() => _channelFilter = 'zalo'),
                          ),
                        ],
                      ),
                    );
                  }
                  if (index == 4) {
                    return _buildSectionTitle(
                      'Chờ khách chuyển (${pendingRecords.length})',
                      Icons.hourglass_top,
                      Colors.orange.shade800,
                    );
                  }
                  if (index == 5) return const SizedBox(height: 8);

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
            errorBuilder: (_, __, ___) => _recordIcon(received, record.channel),
            ),
          )
        : _recordIcon(received, record.channel);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      color: record.channel == 'zalo'
          ? Colors.blue.shade50
          : record.smsStatus == 'simulated'
          ? Colors.deepOrange.shade50
          : (record.customerReplied ? Colors.lightBlue.shade50 : null),
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
              '${record.channel == 'zalo' ? 'Zalo · ' : (record.smsStatus == 'simulated' ? 'SMS ảo · ' : 'SMS · ')}'
              '${_formatAmount(record.amountValue, fallback: record.amount)} · ${_formatTime(record.sortTime)}',
            ),
            if (record.channel == 'zalo')
              Text(_zaloStatusLabel(record.deliveryStatus)),
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
                InkWell(
                  onTap: () => _openConversation(record),
                  borderRadius: BorderRadius.circular(4),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Text(
                      '4 số cuối: ${lastFour.isEmpty ? '----' : lastFour} · ${record.channel == 'zalo' ? 'mở Zalo' : 'mở SMS'}',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            if (record.customerReplied)
              Text(
                '✉ Khách đã phản hồi · ${_formatTime(record.replyReceivedAt)}',
              ),
            if (record.customerReplied && record.replyMessage.isNotEmpty)
              Text(
                'Khách: ${record.replyMessage}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
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

  Widget _recordIcon(bool received, String channel) {
    return CircleAvatar(
      backgroundColor: received ? Colors.green.shade50 : Colors.orange.shade50,
      child: Icon(
        received
            ? Icons.check
            : channel == 'zalo'
            ? Icons.chat_bubble_outline
            : Icons.sms_outlined,
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
    required this.channel,
    required this.phone,
    required this.amount,
    required this.amountValue,
    required this.sentAt,
    required this.isReceived,
    required this.smsStatus,
    required this.deliveryStatus,
    required this.createdAt,
    required this.message,
    required this.orderCode,
    required this.imagePath,
    required this.customerReplied,
    required this.replyPhone,
    required this.replyMessage,
    required this.replyReceivedAt,
  });

  final String id;
  final String channel;
  final String phone;
  final String amount;
  final int amountValue;
  final int sentAt;
  final bool isReceived;
  final String smsStatus;
  final String deliveryStatus;
  final int createdAt;
  final String message;
  final String orderCode;
  final String imagePath;
  final bool customerReplied;
  final String replyPhone;
  final String replyMessage;
  final int replyReceivedAt;

  int get sortTime => sentAt > 0 ? sentAt : createdAt;

  factory _PaymentRecord.fromMap(Map<dynamic, dynamic> map) {
    final amount = map['amount']?.toString() ?? '';
    final digits = amount.replaceAll(RegExp(r'[^0-9]'), '');
    return _PaymentRecord(
      id: map['id']?.toString() ?? '',
      channel: map['channel']?.toString() ?? 'sms',
      phone: map['phone']?.toString() ?? 'Không rõ số điện thoại',
      amount: amount,
      amountValue: int.tryParse(digits) ?? 0,
      sentAt: (map['sentAt'] as num?)?.toInt() ?? 0,
      isReceived: map['status']?.toString() == 'received',
      smsStatus: map['smsStatus']?.toString() ?? '',
      deliveryStatus: map['deliveryStatus']?.toString() ?? '',
      createdAt: (map['createdAt'] as num?)?.toInt() ?? 0,
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
    required this.amountText,
  });

  final _PaymentRecord record;
  final MethodChannel channel;
  final String amountText;

  @override
  State<_PaymentRecordDetailsScreen> createState() =>
      _PaymentRecordDetailsScreenState();
}

class _PaymentRecordDetailsScreenState
    extends State<_PaymentRecordDetailsScreen> {
  bool _isSavingImage = false;
  late _PaymentRecord _record;

  @override
  void initState() {
    super.initState();
    _record = widget.record;
  }

  Future<void> _refreshRecord() async {
    final records = await widget.channel.invokeListMethod<dynamic>(
      'getPaymentTrackingRecords',
    );
    _PaymentRecord? match;
    for (final item in records ?? const <dynamic>[]) {
      if (item is Map<dynamic, dynamic>) {
        final candidate = _PaymentRecord.fromMap(item);
        if (candidate.id == _record.id) {
          match = candidate;
          break;
        }
      }
    }
    final refreshedRecord = match;
    if (refreshedRecord != null && mounted) {
      setState(() => _record = refreshedRecord);
    }
  }

  Future<void> _openConversation() async {
    try {
      await widget.channel.invokeMethod<bool>(
        widget.record.channel == 'zalo'
            ? 'openZaloConversation'
            : 'openSmsConversation',
        {'phone': widget.record.phone},
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Không mở được hội thoại: $error')),
      );
    }
  }

  Future<void> _confirmZaloSent() async {
    try {
      final updated = await widget.channel.invokeMethod<bool>(
        'setPaymentTrackingZaloStatus',
        {'id': widget.record.id, 'deliveryStatus': 'sent_confirmed'},
      );
      if (updated == true && mounted) {
        await _refreshRecord();
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Đã ghi nhận người dùng xác nhận gửi Zalo.')),
        );
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Không cập nhật được trạng thái: $error')),
      );
    }
  }

  Future<void> _recordZaloReply() async {
    final controller = TextEditingController();
    final message = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Ghi nhận phản hồi Zalo'),
        content: TextField(
          controller: controller,
          autofocus: true,
          minLines: 2,
          maxLines: 5,
          decoration: const InputDecoration(
            hintText: 'Nhập nội dung khách đã nhắn',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Hủy'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: const Text('Lưu'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (message == null || message.trim().isEmpty) return;
    try {
      final updated = await widget.channel.invokeMethod<bool>(
        'setPaymentTrackingZaloReply',
        {'id': widget.record.id, 'message': message.trim()},
      );
      if (updated == true && mounted) {
        await _refreshRecord();
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Đã lưu nội dung phản hồi Zalo.')),
        );
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Không lưu được phản hồi: $error')),
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
    final record = _record;
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
                ? SizedBox(
                    height: 180,
                    child: Center(
                      child: Text(
                        record.channel == 'zalo'
                            ? 'Chưa quét ảnh đơn hàng cho khoản Zalo này.'
                            : 'Khoản này chưa có ảnh đơn hàng.',
                      ),
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
                  leading: Icon(
                    record.channel == 'zalo'
                        ? Icons.chat_bubble_outline
                        : Icons.sms_outlined,
                  ),
                  title: const Text('Kênh liên hệ'),
                  subtitle: Text(record.channel == 'zalo' ? 'Zalo' : 'SMS'),
                ),
                ListTile(
                  leading: const Icon(Icons.payments_outlined),
                  title: const Text('Số tiền'),
                  subtitle: Text(widget.amountText),
                ),
                if (record.smsStatus == 'simulated')
                  const ListTile(
                    leading: Icon(Icons.info_outline),
                    title: Text('SMS ảo'),
                    subtitle: Text(
                      'Có trong mục Đã gửi của ứng dụng SMS; khách không nhận tin nhắn.',
                    ),
                  ),
                if (record.channel == 'zalo')
                  ListTile(
                    leading: const Icon(Icons.outbox_outlined),
                    title: const Text('Trạng thái Zalo'),
                    subtitle: Text(_zaloStatusLabel(record.deliveryStatus)),
                    trailing: record.deliveryStatus == 'sent_confirmed'
                        ? const Icon(Icons.check_circle, color: Colors.green)
                        : IconButton(
                            tooltip: 'Xác nhận đã bấm Gửi trong Zalo',
                            onPressed: _confirmZaloSent,
                            icon: const Icon(Icons.check_circle_outline),
                          ),
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
                  title: Text(
                    record.channel == 'zalo' &&
                            record.deliveryStatus != 'sent_confirmed'
                        ? 'Tạo lúc'
                        : 'Gửi lúc',
                  ),
                  subtitle: Text(_formatPaymentTime(record.sortTime)),
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
                          Expanded(
                          child: Text(
                            record.channel == 'zalo'
                                ? 'Phản hồi Zalo đã ghi thủ công'
                                : 'Khách đã phản hồi qua SMS',
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
                      record.channel == 'zalo'
                          ? 'CallLog không đọc được tin nhắn Zalo tự động. Nội dung này do người dùng ghi nhận; chưa xác nhận khách đã chuyển tiền.'
                          : 'Đây là dấu hiệu khách đã nhắn lại, chưa xác nhận đã chuyển tiền. SMS không có mã đơn nên nếu số này có nhiều đơn đang chờ, tất cả đơn cùng số sẽ được làm nổi bật.',
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
              onTap: _openConversation,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            record.channel == 'zalo'
                                ? 'Nội dung chia sẻ qua Zalo'
                                : 'Nội dung tin nhắn SMS',
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
                      record.smsStatus == 'simulated'
                          ? 'Chạm để xem trong ứng dụng SMS · khách không nhận tin'
                          : record.channel == 'zalo'
                          ? 'Chạm để mở liên kết Zalo theo số điện thoại'
                          : 'Chạm để mở hội thoại SMS với khách',
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
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (record.channel == 'zalo')
              OutlinedButton.icon(
                onPressed: _recordZaloReply,
                icon: const Icon(Icons.edit_note_outlined),
                label: const Text('Ghi nội dung khách phản hồi'),
              ),
            if (record.imagePath.isNotEmpty)
              FilledButton.icon(
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
          ],
        ),
      ),
    );
  }
}
