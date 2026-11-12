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
    extends State<PaymentReconciliationScreen>
    with SingleTickerProviderStateMixin {
  static const MethodChannel _channel = MethodChannel('call_log_manager');
  static const EventChannel _paymentEvents = EventChannel(
    'call_log_manager/payment_tracking_events',
  );

  List<_PaymentRecord> _records = [];
  final _searchController = TextEditingController();
  late TabController _tabController;
  String _channelFilter = 'all';
  StreamSubscription<dynamic>? _paymentEventsSubscription;
  bool _isLoading = true;
  bool _backupBusy = false;
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
      _filteredRecords.where((record) => record.isPending).toList();

  List<_PaymentRecord> get _received =>
      _filteredRecords.where((record) => record.isReceived).toList();

  List<_PaymentRecord> get _done =>
      _filteredRecords.where((record) => record.isDone).toList();

  List<_PaymentRecord> get _allReceived =>
      _records.where((record) => record.isReceived).toList();

  List<_PaymentRecord> get _allDone =>
      _records.where((record) => record.isDone).toList();

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
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
    _tabController.dispose();
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

  Future<void> _setStatus(_PaymentRecord record, String status) async {
    try {
      await _channel.invokeMethod<bool>('setPaymentTrackingStatus', {
        'id': record.id,
        'status': status,
      });
      await _loadRecords(showLoading: false);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Không cập nhật được trạng thái: $error')),
      );
    }
  }

  Future<void> _saveImageAndMarkDone(_PaymentRecord record) async {
    try {
      await _channel.invokeMethod<String>('savePaymentTrackingImage', {
        'id': record.id,
      });
      await _loadRecords(showLoading: false);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('✅ Đã lưu ảnh POD và chuyển sang danh sách Đã xong (Done)!'),
          backgroundColor: Colors.green,
          duration: Duration(seconds: 2),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Không lưu được ảnh POD: $error')),
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

  Future<void> _clearDoneRecords() async {
    if (_allDone.isEmpty) return;
    final shouldClear = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Xóa các khoản Đã xong (Done)?'),
        content: Text(
          'Sẽ xóa toàn bộ ${_allDone.length} khoản đã hoàn tất (Done) và ảnh lưu kèm. '
          'Các khoản đang chờ và đã nhận sẽ được giữ lại.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Hủy'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Xóa tất cả'),
          ),
        ],
      ),
    );
    if (shouldClear != true) return;

    try {
      final removed = await _channel.invokeMethod<int>(
        'clearDonePaymentRecords',
      );
      await _loadRecords();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Đã xóa ${removed ?? 0} khoản đã xong (Done).')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Không xóa được danh sách: $error')),
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

  Future<void> _handleBackup(bool importing) async {
    if (_backupBusy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(importing ? 'Khôi phục lịch sử đối soát?' : 'Xuất bản sao đối soát?'),
        content: Text(importing
            ? 'Chỉ thêm các khoản chưa có trong app; không ghi đè dữ liệu hiện tại. Chọn bản sao do app này tạo.'
            : 'Bản sao chứa số điện thoại, nội dung và ảnh đối soát, không được mã hóa. Hãy lưu ở nơi riêng tư.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Hủy')),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(importing ? 'Chọn bản sao' : 'Chọn nơi lưu'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _backupBusy = true);
    try {
      final summary = await _channel.invokeMapMethod<String, dynamic>(
        importing ? 'importPaymentBackup' : 'exportPaymentBackup',
      );
      if (summary == null) return;
      if (importing) await _loadRecords(showLoading: false);
      if (!mounted) return;
      final count = summary['records'] as int? ?? 0;
      final extra = importing
          ? ' · bỏ qua ${summary['skipped'] ?? 0} khoản đã có'
          : ' · ${summary['images'] ?? 0} ảnh${(summary['missingImages'] as int? ?? 0) > 0 ? ' · thiếu ${summary['missingImages']} ảnh cũ' : ''}';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(importing ? 'Đã khôi phục $count khoản$extra.' : 'Đã sao lưu $count khoản$extra.'),
      ));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(importing ? 'Không khôi phục được: $error' : 'Không sao lưu được: $error'),
      ));
    } finally {
      if (mounted) setState(() => _backupBusy = false);
    }
  }

  String _formatTime(int timestamp) {
    return _formatPaymentTime(timestamp);
  }

  @override
  Widget build(BuildContext context) {
    final pendingRecords = _pending;
    final receivedRecords = _received;
    final doneRecords = _done;
    final pendingTotal = pendingRecords.fold<int>(
      0,
      (total, record) => total + record.amountValue,
    );
    final receivedTotal = receivedRecords.fold<int>(
      0,
      (total, record) => total + record.amountValue,
    );
    final doneTotal = doneRecords.fold<int>(
      0,
      (total, record) => total + record.amountValue,
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Đối soát chuyển khoản'),
        actions: [
          PopupMenuButton<String>(
            enabled: !_backupBusy,
            tooltip: 'Tùy chọn mở rộng',
            icon: const Icon(Icons.more_vert),
            onSelected: (action) {
              if (action == 'export') {
                _handleBackup(false);
              } else if (action == 'import') {
                _handleBackup(true);
              } else if (action == 'clear_received') {
                _clearReceivedRecords();
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'export', child: Text('Xuất bản sao đối soát')),
              const PopupMenuItem(value: 'import', child: Text('Khôi phục từ bản sao')),
              if (_allReceived.isNotEmpty)
                const PopupMenuItem(
                  value: 'clear_received',
                  child: Text('Xóa danh sách Đã nhận (Chưa POD)', style: TextStyle(color: Colors.red)),
                ),
            ],
          ),
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
            onPressed: _allDone.isEmpty ? null : _clearDoneRecords,
            tooltip: 'Xóa tất cả khoản Đã xong (Done)',
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
          : Column(
              children: [
                // Top control bar: Summary + Search + Filters
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _buildSummaryCard(pendingTotal, receivedTotal, doneTotal),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _searchController,
                        decoration: InputDecoration(
                          prefixIcon: const Icon(Icons.search, size: 20),
                          hintText: 'Tìm SĐT, mã đơn, số tiền, nội dung',
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 8,
                          ),
                          suffixIcon: _searchController.text.isEmpty
                              ? null
                              : IconButton(
                                  iconSize: 18,
                                  onPressed: () => setState(
                                    _searchController.clear,
                                  ),
                                  icon: const Icon(Icons.clear),
                                ),
                          border: const OutlineInputBorder(),
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                      const SizedBox(height: 6),
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            ChoiceChip(
                              visualDensity: VisualDensity.compact,
                              label: const Text(
                                'Tất cả kênh',
                                style: TextStyle(fontSize: 12),
                              ),
                              selected: _channelFilter == 'all',
                              onSelected: (_) =>
                                  setState(() => _channelFilter = 'all'),
                            ),
                            const SizedBox(width: 6),
                            ChoiceChip(
                              visualDensity: VisualDensity.compact,
                              avatar: const Icon(Icons.sms_outlined, size: 14),
                              label: const Text(
                                'SMS',
                                style: TextStyle(fontSize: 12),
                              ),
                              selected: _channelFilter == 'sms',
                              onSelected: (_) =>
                                  setState(() => _channelFilter = 'sms'),
                            ),
                            const SizedBox(width: 6),
                            ChoiceChip(
                              visualDensity: VisualDensity.compact,
                              avatar: const Icon(Icons.chat_bubble_outline, size: 14),
                              label: const Text(
                                'Zalo',
                                style: TextStyle(fontSize: 12),
                              ),
                              selected: _channelFilter == 'zalo',
                              onSelected: (_) =>
                                  setState(() => _channelFilter = 'zalo'),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                // TabBar
                Material(
                  color: Theme.of(context).colorScheme.surface,
                  elevation: 1,
                  child: TabBar(
                    controller: _tabController,
                    labelColor: Theme.of(context).colorScheme.primary,
                    unselectedLabelColor: Colors.grey.shade600,
                    indicatorColor: Theme.of(context).colorScheme.primary,
                    indicatorWeight: 3,
                    tabs: [
                      Tab(
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Text(
                              'Chờ chuyển',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            if (pendingRecords.isNotEmpty) ...[
                              const SizedBox(width: 4),
                              _buildBadge(
                                pendingRecords.length,
                                Colors.orange.shade800,
                              ),
                            ],
                          ],
                        ),
                      ),
                      Tab(
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Text(
                              'Đã nhận',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            if (receivedRecords.isNotEmpty) ...[
                              const SizedBox(width: 4),
                              _buildBadge(
                                receivedRecords.length,
                                Colors.blue.shade700,
                              ),
                            ],
                          ],
                        ),
                      ),
                      Tab(
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Text(
                              'Đã xong',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            if (doneRecords.isNotEmpty) ...[
                              const SizedBox(width: 4),
                              _buildBadge(
                                doneRecords.length,
                                Colors.green.shade700,
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                // TabBarView
                Expanded(
                  child: TabBarView(
                    controller: _tabController,
                    children: [
                      _buildPendingTab(pendingRecords),
                      _buildReceivedTab(receivedRecords),
                      _buildDoneTab(doneRecords),
                    ],
                  ),
                ),
              ],
            ),
    );
  }

  Widget _buildBadge(int count, Color color) {
    if (count <= 0) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        count > 99 ? '99+' : '$count',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 10,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Widget _buildSummaryCard(int pendingTotal, int receivedTotal, int doneTotal) {
    final repliedPendingCount = _pending
        .where((record) => record.customerReplied)
        .length;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
      decoration: BoxDecoration(
        color: Colors.grey.shade100,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: _buildSummaryItem(
                  label: 'Chờ chuyển',
                  count: _pending.length,
                  total: pendingTotal,
                  color: Colors.orange.shade800,
                  onTap: () => _tabController.animateTo(0),
                ),
              ),
              Container(width: 1, height: 36, color: Colors.grey.shade300),
              Expanded(
                child: _buildSummaryItem(
                  label: 'Đã nhận',
                  count: _received.length,
                  total: receivedTotal,
                  color: Colors.blue.shade700,
                  onTap: () => _tabController.animateTo(1),
                ),
              ),
              Container(width: 1, height: 36, color: Colors.grey.shade300),
              Expanded(
                child: _buildSummaryItem(
                  label: 'Đã xong',
                  count: _done.length,
                  total: doneTotal,
                  color: Colors.green.shade700,
                  onTap: () => _tabController.animateTo(2),
                ),
              ),
            ],
          ),
          if (repliedPendingCount > 0) ...[
            const SizedBox(height: 6),
            InkWell(
              onTap: () => _tabController.animateTo(0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.mark_chat_read, size: 14, color: Colors.blue.shade700),
                  const SizedBox(width: 4),
                  Text(
                    'Có $repliedPendingCount khách vừa phản hồi tin nhắn',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.blue.shade900,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSummaryItem({
    required String label,
    required int count,
    required int total,
    required Color color,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 2),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: Colors.grey.shade700,
                  ),
                ),
                const SizedBox(width: 3),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0.5),
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '$count',
                    style: const TextStyle(
                      fontSize: 9,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              _formatAmount(total),
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: color,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPendingTab(List<_PaymentRecord> records) {
    if (records.isEmpty) {
      return RefreshIndicator(
        onRefresh: _loadRecords,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(24),
          children: [
            _buildEmptyState('Không có khoản nào đang chờ chuyển.'),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _loadRecords,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
        itemCount: records.length,
        itemBuilder: (context, index) =>
            _buildRecordCard(records[index], status: 'pending'),
      ),
    );
  }

  Widget _buildReceivedTab(List<_PaymentRecord> records) {
    if (records.isEmpty) {
      return RefreshIndicator(
        onRefresh: _loadRecords,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(24),
          children: [
            _buildEmptyState('Chưa có khoản đã nhận nào cần xử lý POD.'),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _loadRecords,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        itemCount: records.length + 1,
        itemBuilder: (context, index) {
          if (index == 0) {
            return Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.blue.shade50,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.blue.shade100),
              ),
              child: Row(
                children: [
                  Icon(Icons.info_outline, size: 16, color: Colors.blue.shade800),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Bấm biểu tượng tải xuống để lưu POD và chuyển đơn sang "Đã xong".',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.blue.shade900,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            );
          }
          return _buildRecordCard(records[index - 1], status: 'received');
        },
      ),
    );
  }

  Widget _buildDoneTab(List<_PaymentRecord> records) {
    if (records.isEmpty) {
      return RefreshIndicator(
        onRefresh: _loadRecords,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(24),
          children: [
            _buildEmptyState('Chưa có đơn hàng nào hoàn tất.'),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _loadRecords,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        itemCount: records.length + 1,
        itemBuilder: (context, index) {
          if (index == 0) {
            return Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.green.shade50,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.green.shade200),
              ),
              child: Row(
                children: [
                  Icon(Icons.check_circle_outline, size: 16, color: Colors.green.shade800),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Đã hoàn tất & tải POD. Các đơn này chỉ lưu trong app để đối soát, không hiện trên popup nổi.',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.green.shade900,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  if (records.isNotEmpty) ...[
                    const SizedBox(width: 6),
                    TextButton.icon(
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.red.shade700,
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        visualDensity: VisualDensity.compact,
                      ),
                      onPressed: _clearDoneRecords,
                      icon: const Icon(Icons.delete_sweep, size: 16),
                      label: const Text('Xóa sạch', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                    ),
                  ],
                ],
              ),
            );
          }
          return _buildRecordCard(records[index - 1], status: 'done');
        },
      ),
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

  Widget _buildRecordCard(_PaymentRecord record, {required String status}) {
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
            errorBuilder: (_, __, ___) => _recordIcon(status, record.channel),
            ),
          )
        : _recordIcon(status, record.channel);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      color: status == 'done'
          ? Colors.green.shade50.withValues(alpha: 0.4)
          : (record.channel == 'zalo'
              ? Colors.blue.shade50
              : record.smsStatus == 'simulated'
                  ? Colors.deepOrange.shade50
                  : (record.customerReplied ? Colors.lightBlue.shade50 : null)),
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
            if (status == 'done')
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.green.shade100,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.check, size: 14, color: Colors.green.shade800),
                    const SizedBox(width: 2),
                    Text(
                      'Đã xong',
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.green.shade900,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              )
            else if (record.customerReplied)
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
            if (status == 'received') ...[
              if (record.imagePath.isNotEmpty)
                IconButton(
                  tooltip: 'Tải ảnh POD & Chuyển sang Đã xong',
                  icon: const Icon(Icons.download_for_offline, color: Colors.blue),
                  onPressed: () => _saveImageAndMarkDone(record),
                ),
              IconButton(
                tooltip: 'Chuyển sang Đã xong',
                icon: const Icon(Icons.task_alt, color: Colors.green),
                onPressed: () => _setStatus(record, 'done'),
              ),
            ],
            if (status == 'done')
              IconButton(
                tooltip: 'Chuyển lại về Đã nhận',
                icon: const Icon(Icons.undo, color: Colors.grey),
                onPressed: () => _setStatus(record, 'received'),
              ),
            IconButton(
              tooltip: 'Xóa khoản này',
              onPressed: () => _deleteRecord(record),
              icon: const Icon(Icons.delete_outline),
            ),
            if (status != 'done')
              Checkbox(
                value: status == 'received',
                onChanged: (value) => _setReceived(record, value ?? false),
              ),
          ],
        ),
      ),
    );
  }

  Widget _recordIcon(String status, String channel) {
    final isDone = status == 'done';
    final isReceived = status == 'received';
    return CircleAvatar(
      backgroundColor: isDone
          ? Colors.green.shade100
          : (isReceived ? Colors.blue.shade50 : Colors.orange.shade50),
      child: Icon(
        isDone
            ? Icons.task_alt
            : (isReceived
                ? Icons.check
                : channel == 'zalo'
                    ? Icons.chat_bubble_outline
                    : Icons.sms_outlined),
        color: isDone
            ? Colors.green.shade800
            : (isReceived ? Colors.blue.shade700 : Colors.orange.shade800),
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
    required this.status,
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
  final String status;
  bool get isPending => status == 'pending';
  bool get isReceived => status == 'received';
  bool get isDone => status == 'done';
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
      status: map['status']?.toString() ?? 'pending',
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
          content: Text(
            '✅ Đã lưu ảnh POD vào Pictures/PaymentReceipts và chuyển sang danh sách Đã xong (Done)!',
          ),
          backgroundColor: Colors.green,
        ),
      );
      Navigator.of(context).pop(true);
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
                    record.isDone
                        ? Icons.task_alt
                        : (record.isReceived
                            ? Icons.check_circle_outline
                            : Icons.hourglass_top),
                    color: record.isDone
                        ? Colors.green.shade700
                        : (record.isReceived ? Colors.blue.shade700 : null),
                  ),
                  title: const Text('Trạng thái'),
                  subtitle: Text(
                    record.isDone
                        ? 'Đã xong · Đã tải ảnh POD'
                        : (record.isReceived
                            ? 'Đã nhận (Chờ tải POD)'
                            : 'Đang chờ chuyển khoản'),
                  ),
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
                  _isSavingImage
                      ? 'Đang tải ảnh...'
                      : (record.isDone
                          ? 'Tải lại ảnh về thư viện'
                          : 'Tải ảnh POD về thư viện & Hoàn tất'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
