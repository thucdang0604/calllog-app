import 'dart:async';

import 'package:flutter/material.dart';

import '../models/app_settings.dart';
import '../models/call_recording_item.dart';
import '../services/app_settings_service.dart';
import '../services/call_recording_service.dart';

enum _CallFilter { all, incoming, outgoing }

class CallRecordingsScreen extends StatefulWidget {
  const CallRecordingsScreen({super.key});

  @override
  State<CallRecordingsScreen> createState() => _CallRecordingsScreenState();
}

class _CallRecordingsScreenState extends State<CallRecordingsScreen>
    with WidgetsBindingObserver {
  final TextEditingController _searchController = TextEditingController();
  StreamSubscription<CallRecordingEvent>? _eventSub;

  List<CallRecordingItem> _recordings = const [];
  CallPlaybackState _playbackState = const CallPlaybackState.idle();
  CallRecordingDiagnostic _diagnostic = const CallRecordingDiagnostic();
  SystemCallRecSyncStatus _syncStatus = const SystemCallRecSyncStatus();
  bool _isLoading = true;
  bool _isSyncingSystem = false;
  bool _didInitialAutoSync = false;
  bool _showXiaomiGuide = false;
  bool _hasPermissions = false;
  bool _hasOverlayPermission = false;
  String _audioSource = 'auto';

  String _searchQuery = '';
  _CallFilter _filter = _CallFilter.all;
  bool _isSelectionMode = false;
  final Set<String> _selectedIds = <String>{};

  bool _isDraggingSlider = false;
  double _sliderDragMs = 0;

  static const List<(String, String)> _audioSources = [
    ('auto', 'Tự động (Thử MIC -> Camcorder -> Voice Recognition)'),
    ('mic', 'Microphone thường (MIC)'),
    ('camcorder', 'Camcorder Mic (Ít lọc âm / hợp Loa ngoài)'),
    ('voice_recognition', 'Voice Recognition'),
    ('voice_communication', 'Voice Communication (VoIP/Loa)'),
    ('unprocessed', 'Unprocessed Mic (Thô không lọc âm)'),
    ('voice_call', 'Voice Call (Thu 2 chiều hệ thống)'),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _eventSub = CallRecordingService.events.listen(_handleRecordingEvent);
    AppSettingsService.load();
    _loadAll();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshStatusAndRecordings();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _eventSub?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  void _handleRecordingEvent(CallRecordingEvent event) {
    if (!mounted) return;
    if (event.type == 'recordings_updated') {
      _reloadRecordingsOnly();
    } else if (event.type == 'playback' && event.playbackState != null) {
      setState(() {
        _playbackState = event.playbackState!;
      });
    }
  }

  Future<void> _loadAll() async {
    setState(() => _isLoading = true);
    await _refreshStatusAndRecordings();
    if (mounted) {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _refreshStatusAndRecordings() async {
    final results = await Future.wait<dynamic>([
      CallRecordingService.hasPermissions(),
      CallRecordingService.hasOverlayPermission(),
      CallRecordingService.getRecordings(),
      CallRecordingService.getAudioSource(),
      CallRecordingService.getPlaybackState(),
      CallRecordingService.getDiagnostic(),
      CallRecordingService.getSystemSyncStatus(),
    ]);
    if (!mounted) return;
    final loaded = results[2] as List<CallRecordingItem>;
    final diag = results[5] as CallRecordingDiagnostic;
    final syncStatus = results[6] as SystemCallRecSyncStatus;
    setState(() {
      _hasPermissions = results[0] as bool;
      _hasOverlayPermission = results[1] as bool;
      _recordings = loaded;
      _audioSource = results[3] as String;
      _playbackState = results[4] as CallPlaybackState;
      _diagnostic = diag;
      _syncStatus = syncStatus;
      if (!_didInitialAutoSync && !syncStatus.isReady && diag.silencedBySystem) {
        _showXiaomiGuide = true;
      }
      _selectedIds.removeWhere((id) => !loaded.any((r) => r.id == id));
      if (_selectedIds.isEmpty) {
        _isSelectionMode = false;
      }
    });

    if (!_didInitialAutoSync) {
      _didInitialAutoSync = true;
      if (syncStatus.isReady) {
        unawaited(_syncSystemRecordings(quiet: true));
      }
    }
  }

  Future<void> _syncSystemRecordings({bool quiet = false}) async {
    if (_isSyncingSystem) return;
    setState(() => _isSyncingSystem = true);
    try {
      final res = await CallRecordingService.syncSystemRecordings();
      final updatedList = await CallRecordingService.getRecordings();
      if (!mounted) return;
      setState(() {
        _syncStatus = res.status;
        _recordings = updatedList;
        _isSyncingSystem = false;
      });
      if (!quiet) {
        final msg = res.importedCount > 0
            ? 'Đã đồng bộ thêm ${res.importedCount} file ghi âm từ máy'
            : 'Đã quét ${res.scannedCount} file — chưa có file mới cần đồng bộ';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(msg),
            backgroundColor:
                res.importedCount > 0 ? Colors.green[700] : Colors.blueGrey[700],
          ),
        );
      }
    } catch (_) {
      if (mounted) {
        setState(() => _isSyncingSystem = false);
      }
    }
  }

  Future<void> _pickSystemFolder() async {
    final res = await CallRecordingService.pickSystemCallRecFolder();
    if (!mounted || res == null) return;
    final updatedList = await CallRecordingService.getRecordings();
    if (!mounted) return;
    setState(() {
      _syncStatus = res.status;
      _recordings = updatedList;
      _showXiaomiGuide = false;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          res.importedCount > 0
              ? 'Đã kết nối "${res.status.folderLabel}" và đồng bộ ${res.importedCount} file'
              : 'Đã kết nối thư mục "${res.status.folderLabel}" — máy sẽ tự đồng bộ sau mỗi cuộc gọi',
        ),
        backgroundColor: Colors.green[700],
      ),
    );
  }

  Future<void> _requestMediaSyncPermission() async {
    setState(() => _isSyncingSystem = true);
    final granted = await CallRecordingService.requestSystemMediaPermission();
    if (!mounted) return;
    await _refreshStatusAndRecordings();
    if (!mounted) return;
    setState(() => _isSyncingSystem = false);
    if (granted) {
      await _syncSystemRecordings(quiet: false);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text(
            'Chưa được cấp quyền Audio. Bạn nên dùng nút "Chọn thư mục ghi âm máy" cho ổn định nhất.',
          ),
          backgroundColor: Colors.orange[800],
        ),
      );
    }
  }

  Future<void> _handlePullToRefresh() async {
    if (_syncStatus.isReady) {
      await _syncSystemRecordings(quiet: true);
    }
    await _refreshStatusAndRecordings();
  }

  Future<void> _reloadRecordingsOnly() async {
    final loaded = await CallRecordingService.getRecordings();
    if (!mounted) return;
    setState(() {
      _recordings = loaded;
      _selectedIds.removeWhere((id) => !loaded.any((r) => r.id == id));
      if (_selectedIds.isEmpty) {
        _isSelectionMode = false;
      }
    });
  }

  List<CallRecordingItem> get _filteredRecordings {
    final q = _searchQuery.trim().toLowerCase();
    return _recordings.where((item) {
      if (_filter == _CallFilter.incoming && !item.isIncoming) return false;
      if (_filter == _CallFilter.outgoing && !item.isOutgoing) return false;
      if (q.isNotEmpty) {
        final haystack =
            '${item.contactName} ${item.phoneNumber} ${item.formattedDateTime}'
                .toLowerCase();
        if (!haystack.contains(q)) return false;
      }
      return true;
    }).toList();
  }

  CallRecordingItem? get _activePlayingItem {
    if (!_playbackState.isActive) return null;
    for (final item in _recordings) {
      if (item.filePath == _playbackState.filePath) {
        return item;
      }
    }
    return null;
  }

  Future<void> _requestPermissions() async {
    final granted = await CallRecordingService.requestPermissions();
    if (!mounted) return;
    await _refreshStatusAndRecordings();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          granted
              ? 'Đã cấp quyền Micro và Điện thoại cho ghi âm cuộc gọi'
              : 'Vui lòng cấp quyền Micro & Điện thoại trong Cài đặt ứng dụng',
        ),
        backgroundColor: granted ? Colors.green[700] : Colors.orange[800],
      ),
    );
  }

  Future<void> _togglePlay(CallRecordingItem item) async {
    try {
      if (_playbackState.isPlayingFile(item.filePath)) {
        final next = await CallRecordingService.pause();
        if (mounted) setState(() => _playbackState = next);
      } else {
        final next = await CallRecordingService.play(item.filePath);
        if (mounted) setState(() => _playbackState = next);
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Không phát được file ghi âm: $e'),
          backgroundColor: Colors.red[700],
        ),
      );
    }
  }

  Future<void> _shareItem(CallRecordingItem item) async {
    try {
      await CallRecordingService.shareRecording(item);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Không thể chia sẻ file: $e'),
          backgroundColor: Colors.red[700],
        ),
      );
    }
  }

  Future<void> _deleteSingle(CallRecordingItem item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Xóa file ghi âm?'),
        content: Text(
          'Xóa ghi âm cuộc gọi "${item.displayTitle}" lúc ${item.formattedDateTime}?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Hủy'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red[700]),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Xóa'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final removed = await CallRecordingService.deleteRecordings([item.id]);
    await _refreshStatusAndRecordings();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Đã xóa $removed file ghi âm')),
    );
  }

  Future<void> _deleteSelected() async {
    if (_selectedIds.isEmpty) return;
    final count = _selectedIds.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Xóa nhiều file ghi âm'),
        content: Text('Xác nhận xóa $count file ghi âm đã chọn?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Hủy'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red[700]),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Xóa'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final removed = await CallRecordingService.deleteRecordings(
      _selectedIds.toList(),
    );
    if (!mounted) return;
    setState(() {
      _selectedIds.clear();
      _isSelectionMode = false;
    });
    await _refreshStatusAndRecordings();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Đã xóa $removed file ghi âm')),
    );
  }

  Future<void> _showDeleteByDateSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetCtx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Chủ động xóa ghi âm theo ngày',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              Text(
                'Ngoài cơ chế tự động dọn file quá 30 ngày, bạn có thể chọn ngày để dọn nhanh bộ nhớ.',
                style: TextStyle(fontSize: 13, color: Colors.grey[700]),
              ),
              const SizedBox(height: 12),
              ListTile(
                leading: CircleAvatar(
                  backgroundColor: Colors.orange[50],
                  child: Icon(Icons.today, color: Colors.orange[800]),
                ),
                title: const Text('Xóa các file trong 1 ngày cụ thể'),
                subtitle: const Text(
                  'Chọn một ngày để xóa toàn bộ cuộc gọi đã ghi âm trong ngày đó',
                ),
                onTap: () {
                  Navigator.of(sheetCtx).pop();
                  _pickDateAndDelete(beforeDate: false);
                },
              ),
              ListTile(
                leading: CircleAvatar(
                  backgroundColor: Colors.red[50],
                  child: Icon(Icons.history_toggle_off, color: Colors.red[700]),
                ),
                title: const Text('Xóa từ 1 ngày trở về trước'),
                subtitle: const Text(
                  'Xóa toàn bộ ghi âm cũ tính từ cuối ngày được chọn trở về trước',
                ),
                onTap: () {
                  Navigator.of(sheetCtx).pop();
                  _pickDateAndDelete(beforeDate: true);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _pickDateAndDelete({required bool beforeDate}) async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: now,
      firstDate: now.subtract(const Duration(days: 365)),
      lastDate: now,
      helpText: beforeDate
          ? 'Chọn ngày mốc (xóa từ ngày này trở về trước)'
          : 'Chọn ngày cần xóa toàn bộ ghi âm',
    );
    if (picked == null || !mounted) return;

    final dayStart = DateTime(picked.year, picked.month, picked.day).millisecondsSinceEpoch;
    final dayEnd = DateTime(
      picked.year,
      picked.month,
      picked.day,
      23,
      59,
      59,
      999,
    ).millisecondsSinceEpoch;

    final matchingCount = _recordings.where((item) {
      if (beforeDate) return item.startedAtMs <= dayEnd;
      return item.startedAtMs >= dayStart && item.startedAtMs <= dayEnd;
    }).length;

    final dateLabel =
        '${picked.day.toString().padLeft(2, '0')}/${picked.month.toString().padLeft(2, '0')}/${picked.year}';

    if (matchingCount == 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            beforeDate
                ? 'Không có file ghi âm nào từ $dateLabel trở về trước'
                : 'Không có file ghi âm nào trong ngày $dateLabel',
          ),
        ),
      );
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          beforeDate
              ? 'Xóa từ $dateLabel trở về trước?'
              : 'Xóa ghi âm ngày $dateLabel?',
        ),
        content: Text(
          'Sẽ xóa vĩnh viễn $matchingCount file ghi âm khớp điều kiện này. Thao tác không thể hoàn tác.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Hủy'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red[700]),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('Xóa ($matchingCount)'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final removed = beforeDate
        ? await CallRecordingService.deleteRecordingsBeforeDate(picked)
        : await CallRecordingService.deleteRecordingsOnDate(picked);
    await _refreshStatusAndRecordings();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Đã xóa $removed file ghi âm'),
        backgroundColor: Colors.green[700],
      ),
    );
  }

  Future<void> _showAudioSourcePicker() async {
    final chosen = await showModalBottomSheet<String>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetCtx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Chọn nguồn thu âm cuộc gọi',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              Text(
                'Tự động sẽ ưu tiên MIC và tự chuyển nguồn nếu Android báo nguồn đang chọn bị câm.',
                style: TextStyle(fontSize: 12.5, color: Colors.grey[700]),
              ),
              const SizedBox(height: 8),
              ..._audioSources.map((entry) {
                final key = entry.$1;
                final label = entry.$2;
                final selected = _audioSource == key;
                return ListTile(
                  dense: true,
                  leading: Icon(
                    selected
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                    color: selected ? Colors.blue[700] : Colors.grey,
                  ),
                  title: Text(
                    label,
                    style: TextStyle(
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                  onTap: () => Navigator.of(sheetCtx).pop(key),
                );
              }),
            ],
          ),
        ),
      ),
    );

    if (chosen == null || chosen == _audioSource) return;
    await CallRecordingService.setAudioSource(chosen);
    if (!mounted) return;
    setState(() => _audioSource = chosen);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Đã đổi nguồn thu sang: ${CallRecordingItem.audioSourceDisplayLabel(chosen)}',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filteredRecordings;
    final totalBytes = _recordings.fold<int>(
      0,
      (sum, item) => sum + item.fileSizeBytes,
    );
    final incomingCount = _recordings.where((e) => e.isIncoming).length;
    final outgoingCount = _recordings.where((e) => e.isOutgoing).length;
    final activeItem = _activePlayingItem;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          _isSelectionMode
              ? 'Đã chọn ${_selectedIds.length} file'
              : 'Kho ghi âm cuộc gọi',
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
        ),
        backgroundColor: Colors.blue[700],
        foregroundColor: Colors.white,
        actions: _isSelectionMode
            ? [
                IconButton(
                  tooltip: 'Chọn tất cả đang lọc',
                  icon: const Icon(Icons.select_all),
                  onPressed: () {
                    setState(() {
                      if (_selectedIds.length == filtered.length) {
                        _selectedIds.clear();
                        _isSelectionMode = false;
                      } else {
                        _selectedIds
                          ..clear()
                          ..addAll(filtered.map((e) => e.id));
                      }
                    });
                  },
                ),
                IconButton(
                  tooltip: 'Xóa đã chọn',
                  icon: const Icon(Icons.delete_forever),
                  onPressed: _selectedIds.isEmpty ? null : _deleteSelected,
                ),
                IconButton(
                  tooltip: 'Thoát chọn',
                  icon: const Icon(Icons.close),
                  onPressed: () {
                    setState(() {
                      _selectedIds.clear();
                      _isSelectionMode = false;
                    });
                  },
                ),
              ]
            : [
                if (_recordings.isNotEmpty)
                  IconButton(
                    tooltip: 'Chọn nhiều file để xóa',
                    icon: const Icon(Icons.checklist),
                    onPressed: () {
                      setState(() => _isSelectionMode = true);
                    },
                  ),
                IconButton(
                  tooltip: 'Xóa theo ngày',
                  icon: const Icon(Icons.delete_sweep),
                  onPressed: _showDeleteByDateSheet,
                ),
                IconButton(
                  tooltip: 'Cài đặt nguồn thu âm',
                  icon: const Icon(Icons.tune),
                  onPressed: _showAudioSourcePicker,
                ),
              ],
      ),
      body: Column(
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 280),
            child: SingleChildScrollView(
              child: _buildStatusOrSetupCard(),
            ),
          ),
          _buildStorageAndFilterSection(
            totalCount: _recordings.length,
            totalBytes: totalBytes,
            incomingCount: incomingCount,
            outgoingCount: outgoingCount,
          ),
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : RefreshIndicator(
                    onRefresh: _handlePullToRefresh,
                    child: filtered.isEmpty
                        ? _buildEmptyState()
                        : ListView.builder(
                            padding: const EdgeInsets.fromLTRB(12, 4, 12, 20),
                            itemCount: filtered.length,
                            itemBuilder: (context, index) =>
                                _buildRecordingCard(filtered[index]),
                          ),
                  ),
          ),
          if (activeItem != null || _playbackState.isActive)
            _buildBottomPlayerBar(activeItem),
        ],
      ),
    );
  }

  Widget _buildStatusOrSetupCard() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!_hasPermissions || !_hasOverlayPermission)
          _buildMissingPermissionsCard(),
        _buildSystemSyncCard(),
      ],
    );
  }

  Widget _buildMissingPermissionsCard() {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 10, 12, 4),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.amber[50],
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.amber[300]!),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.mic_external_on, color: Colors.amber[900], size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Kích hoạt nút Ghi âm chủ động trong cuộc gọi',
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                    color: Colors.amber[900],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '1) Cấp quyền Micro, Điện thoại & Nhật ký cuộc gọi.\n'
            '2) Cấp quyền "Hiển thị trên ứng dụng khác" để hiện nút "Ghi âm" khi đang gọi (không cần bật Trợ năng nên không ảnh hưởng app ngân hàng).',
            style: TextStyle(fontSize: 12, color: Colors.grey[800], height: 1.35),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (!_hasPermissions)
                ElevatedButton.icon(
                  onPressed: _requestPermissions,
                  icon: const Icon(Icons.mic, size: 16),
                  label: const Text('Cấp Micro, ĐT & Nhật ký'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blue[700],
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    textStyle: const TextStyle(fontSize: 12.5),
                  ),
                ),
              if (!_hasOverlayPermission)
                ElevatedButton.icon(
                  onPressed: CallRecordingService.openOverlaySettings,
                  icon: const Icon(Icons.layers_outlined, size: 16),
                  label: const Text('Cấp Hiển thị trên ứng dụng khác'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.orange[800],
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    textStyle: const TextStyle(fontSize: 12.5),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSystemSyncCard() {
    final isReady = _syncStatus.isReady;
    final hasSilenceDiag =
        _diagnostic.hasAttempt && _diagnostic.silencedBySystem;
    final bgColor = isReady
        ? Colors.teal[50]!
        : (hasSilenceDiag ? Colors.orange[50]! : Colors.blue[50]!);
    final borderColor = isReady
        ? Colors.teal[200]!
        : (hasSilenceDiag ? Colors.orange[300]! : Colors.blue[200]!);
    final accentColor = isReady
        ? Colors.teal[800]!
        : (hasSilenceDiag ? Colors.orange[900]! : Colors.blue[900]!);

    final folderSummary = _syncStatus.hasTreePermission
        ? 'Thư mục: ${_syncStatus.folderLabel}'
        : (_syncStatus.hasMediaPermission
            ? 'Đang bật quét Audio hệ thống'
            : 'Chưa kết nối thư mục ghi âm máy');

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      padding: const EdgeInsets.fromLTRB(12, 9, 10, 9),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _showXiaomiGuide = !_showXiaomiGuide),
            borderRadius: BorderRadius.circular(8),
            child: Row(
              children: [
                Icon(
                  isReady
                      ? Icons.sync_lock
                      : (hasSilenceDiag
                          ? Icons.warning_amber_rounded
                          : Icons.folder_copy_outlined),
                  color: accentColor,
                  size: 19,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        isReady
                            ? 'Tự đồng bộ ghi âm 2 chiều từ máy'
                            : (hasSilenceDiag
                                ? 'Máy đang chặn mic VoLTE — Dùng Ghi âm máy'
                                : 'Đồng bộ ghi âm 2 chiều của máy (Không cần Trợ năng)'),
                        style: TextStyle(
                          fontSize: 12.8,
                          fontWeight: FontWeight.w700,
                          color: accentColor,
                        ),
                      ),
                      Text(
                        folderSummary,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11.5, color: Colors.grey[800]),
                      ),
                    ],
                  ),
                ),
                if (isReady)
                  TextButton.icon(
                    onPressed:
                        _isSyncingSystem ? null : () => _syncSystemRecordings(),
                    icon: _isSyncingSystem
                        ? SizedBox(
                            width: 13,
                            height: 13,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: accentColor,
                            ),
                          )
                        : Icon(Icons.sync, size: 15, color: accentColor),
                    label: Text(
                      _isSyncingSystem ? 'Đang quét' : 'Đồng bộ',
                      style: TextStyle(
                        fontSize: 11.8,
                        fontWeight: FontWeight.w700,
                        color: accentColor,
                      ),
                    ),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                Icon(
                  _showXiaomiGuide ? Icons.expand_less : Icons.expand_more,
                  color: accentColor,
                ),
              ],
            ),
          ),
          if (_showXiaomiGuide || !isReady) ...[
            const SizedBox(height: 8),
            if (hasSilenceDiag)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.only(bottom: 7),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.78),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.orange[200]!),
                ),
                child: Text(
                  'Chẩn đoán lần thu gần nhất (${_diagnostic.brand} ${_diagnostic.model}): '
                  'Android / VoLTE đã khóa micro app thứ 3 (nguồn thử: ${_diagnostic.attemptedSources.isNotEmpty ? _diagnostic.attemptedSources : _diagnostic.audioSource}'
                  ', Loa ngoài: ${_diagnostic.speakerOn ? 'Đang bật' : 'Tắt'}) vì Trợ năng đang TẮT để bảo vệ app ngân hàng.',
                  style: TextStyle(
                    fontSize: 11.5,
                    color: Colors.orange[950],
                    height: 1.32,
                  ),
                ),
              ),
            Text(
              'Cách thu 2 chiều VoLTE rõ tiếng mà không bật Trợ năng:\n'
              '1) Trên màn hình cuộc gọi Xiaomi: bấm "Thêm (⋮) → Ghi âm" (hoặc bật "Tự động ghi âm cuộc gọi" trong Cài đặt ứng dụng Điện thoại).\n'
              '2) Bấm nút bên dưới chọn thư mục "${_syncStatus.suggestedFolder}" (chỉ cần 1 lần) — sau mỗi cuộc gọi Delivery Support tự nhập file vào đây.',
              style: TextStyle(
                fontSize: 11.8,
                color: Colors.grey[850],
                height: 1.36,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ElevatedButton.icon(
                  onPressed: _isSyncingSystem ? null : _pickSystemFolder,
                  icon: const Icon(Icons.folder_open, size: 16),
                  label: Text(
                    _syncStatus.hasTreePermission
                        ? 'Đổi thư mục (${_syncStatus.folderLabel})'
                        : 'Chọn thư mục ghi âm máy',
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.teal[700],
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 11,
                      vertical: 8,
                    ),
                    textStyle: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (!_syncStatus.hasMediaPermission)
                  OutlinedButton.icon(
                    onPressed:
                        _isSyncingSystem ? null : _requestMediaSyncPermission,
                    icon: const Icon(Icons.audio_file_outlined, size: 15),
                    label: const Text('Quét quyền Audio'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.teal[800],
                      side: BorderSide(color: Colors.teal[300]!),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                      textStyle: const TextStyle(fontSize: 12),
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildStorageAndFilterSection({
    required int totalCount,
    required int totalBytes,
    required int incomingCount,
    required int outgoingCount,
  }) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '$totalCount file • ${CallRecordingItem.formatFileSizeBytes(totalBytes)}',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: Colors.grey[700],
                  ),
                ),
              ),
              InkWell(
                onTap: _showAudioSourcePicker,
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.blue[50],
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.blue[200]!),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.graphic_eq, size: 14, color: Colors.blue[700]),
                      const SizedBox(width: 4),
                      Text(
                        _audioSource,
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: Colors.blue[800],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 6),
              TextButton.icon(
                onPressed: _showDeleteByDateSheet,
                icon: Icon(Icons.calendar_month, size: 16, color: Colors.red[700]),
                label: Text(
                  'Xóa theo ngày',
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.red[700],
                    fontWeight: FontWeight.w600,
                  ),
                ),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          TextField(
            controller: _searchController,
            onChanged: (value) => setState(() => _searchQuery = value),
            decoration: InputDecoration(
              hintText: 'Tìm theo tên danh bạ, số điện thoại, ngày...',
              prefixIcon: const Icon(Icons.search, size: 20),
              suffixIcon: _searchQuery.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear, size: 18),
                      onPressed: () {
                        _searchController.clear();
                        setState(() => _searchQuery = '');
                      },
                    ),
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 9,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
          const SizedBox(height: 6),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                ChoiceChip(
                  label: Text('Tất cả ($totalCount)'),
                  selected: _filter == _CallFilter.all,
                  onSelected: (_) => setState(() => _filter = _CallFilter.all),
                ),
                const SizedBox(width: 8),
                ChoiceChip(
                  label: Text('Cuộc gọi đến ($incomingCount)'),
                  selected: _filter == _CallFilter.incoming,
                  onSelected: (_) =>
                      setState(() => _filter = _CallFilter.incoming),
                ),
                const SizedBox(width: 8),
                ChoiceChip(
                  label: Text('Cuộc gọi đi ($outgoingCount)'),
                  selected: _filter == _CallFilter.outgoing,
                  onSelected: (_) =>
                      setState(() => _filter = _CallFilter.outgoing),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 60),
          child: Column(
            children: [
              Icon(Icons.spatial_audio_off, size: 52, color: Colors.grey[400]),
              const SizedBox(height: 12),
              Text(
                _recordings.isEmpty
                    ? 'Chưa có file ghi âm nào'
                    : 'Không tìm thấy ghi âm phù hợp',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: Colors.grey[700],
                ),
              ),
              const SizedBox(height: 6),
              Text(
                _recordings.isEmpty
                    ? 'Khi có cuộc gọi đến hoặc đi phát sinh thời gian thoại, hệ thống sẽ tự động cắt đoạn chờ chuông và lưu phần thoại tối đa 30 ngày tại đây.'
                    : 'Thử đổi bộ lọc hoặc từ khóa tìm kiếm khác.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: Colors.grey[600]),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildRecordingCard(CallRecordingItem item) {
    final isPlaying = _playbackState.isPlayingFile(item.filePath);
    final isActive = _playbackState.isActiveFile(item.filePath);
    final isSelected = _selectedIds.contains(item.id);
    final callColor = item.isOutgoing ? Colors.blue[700]! : Colors.green[700]!;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      elevation: isActive ? 3 : 1.5,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: isActive ? Colors.blue[400]! : Colors.transparent,
          width: 1.2,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onLongPress: () {
          setState(() {
            _isSelectionMode = true;
            _selectedIds.add(item.id);
          });
        },
        onTap: _isSelectionMode
            ? () {
                setState(() {
                  if (isSelected) {
                    _selectedIds.remove(item.id);
                    if (_selectedIds.isEmpty) _isSelectionMode = false;
                  } else {
                    _selectedIds.add(item.id);
                  }
                });
              }
            : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          child: Row(
            children: [
              if (_isSelectionMode)
                Checkbox(
                  value: isSelected,
                  onChanged: (checked) {
                    setState(() {
                      if (checked == true) {
                        _selectedIds.add(item.id);
                      } else {
                        _selectedIds.remove(item.id);
                        if (_selectedIds.isEmpty) _isSelectionMode = false;
                      }
                    });
                  },
                )
              else
                CircleAvatar(
                  backgroundColor: callColor,
                  radius: 20,
                  child: Icon(
                    item.isOutgoing ? Icons.call_made : Icons.call_received,
                    color: Colors.white,
                    size: 18,
                  ),
                ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.displayTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 14.5,
                      ),
                    ),
                    if (item.contactName.trim().isNotEmpty &&
                        item.phoneNumber.trim().isNotEmpty)
                      Text(
                        item.phoneNumber,
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey[700],
                        ),
                      ),
                    const SizedBox(height: 2),
                    Text(
                      '${item.formattedDateTime} • ${item.formattedDuration} • ${item.formattedFileSize} • ${item.isSystemDialer ? "Hệ thống 2 chiều" : item.audioSource} • Còn ${item.daysRemainingBeforeAutoDelete}d',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: Colors.grey[600],
                      ),
                    ),
                    if (item.isSystemDialer)
                      Container(
                        margin: const EdgeInsets.only(top: 4),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.teal[50],
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: Colors.teal[200]!),
                        ),
                        child: Text(
                          'Ghi âm hệ thống · 2 chiều VoLTE',
                          style: TextStyle(
                            fontSize: 10.5,
                            color: Colors.teal[800],
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    if (item.isSilentRecording)
                      ValueListenableBuilder<AppSettings>(
                        valueListenable: AppSettingsService.notifier,
                        builder: (context, settings, _) {
                          if (!settings.callRecordingSilenceWarningEnabled) {
                            return const SizedBox.shrink();
                          }
                          return Padding(
                            padding: const EdgeInsets.only(top: 3),
                            child: Text(
                              '⚠ File không có tín hiệu âm (bị hệ thống chặn mic khi gọi)',
                              style: TextStyle(
                                fontSize: 11,
                                color: Colors.orange[800],
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          );
                        },
                      ),
                  ],
                ),
              ),
              if (!_isSelectionMode) ...[
                IconButton(
                  tooltip: isPlaying ? 'Tạm dừng' : 'Nghe ghi âm',
                  icon: Icon(
                    isPlaying
                        ? Icons.pause_circle_filled
                        : Icons.play_circle_fill,
                    color: isActive ? Colors.blue[700] : Colors.teal[700],
                    size: 32,
                  ),
                  onPressed: () => _togglePlay(item),
                ),
                PopupMenuButton<String>(
                  padding: EdgeInsets.zero,
                  icon: Icon(Icons.more_vert, color: Colors.grey[700]),
                  onSelected: (action) {
                    if (action == 'share') {
                      _shareItem(item);
                    } else if (action == 'delete') {
                      _deleteSingle(item);
                    }
                  },
                  itemBuilder: (context) => [
                    const PopupMenuItem(
                      value: 'share',
                      child: Row(
                        children: [
                          Icon(Icons.share, size: 18),
                          SizedBox(width: 8),
                          Text('Chia sẻ file ghi âm'),
                        ],
                      ),
                    ),
                    PopupMenuItem(
                      value: 'delete',
                      child: Row(
                        children: [
                          Icon(Icons.delete_outline,
                              size: 18, color: Colors.red[700]),
                          const SizedBox(width: 8),
                          Text(
                            'Xóa file này',
                            style: TextStyle(color: Colors.red[700]),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBottomPlayerBar(CallRecordingItem? activeItem) {
    final totalMs = _playbackState.durationMs > 0
        ? _playbackState.durationMs
        : (activeItem?.durationMs ?? 1);
    final safeMax = totalMs > 0 ? totalMs.toDouble() : 1.0;
    final rawPos = _isDraggingSlider
        ? _sliderDragMs
        : _playbackState.positionMs.toDouble();
    final sliderValue = rawPos.clamp(0.0, safeMax);

    return Material(
      elevation: 8,
      color: Colors.blue[900],
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const Icon(Icons.audiotrack, color: Colors.white, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      activeItem != null
                          ? '${activeItem.displayTitle} (${activeItem.formattedDateTime})'
                          : 'Đang phát ghi âm cuộc gọi',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: _playbackState.isPlaying ? 'Tạm dừng' : 'Tiếp tục',
                    icon: Icon(
                      _playbackState.isPlaying
                          ? Icons.pause_circle
                          : Icons.play_circle,
                      color: Colors.white,
                      size: 28,
                    ),
                    onPressed: () async {
                      final next = _playbackState.isPlaying
                          ? await CallRecordingService.pause()
                          : await CallRecordingService.resume();
                      if (mounted) setState(() => _playbackState = next);
                    },
                  ),
                  if (activeItem != null)
                    IconButton(
                      tooltip: 'Chia sẻ file',
                      icon: const Icon(
                        Icons.share,
                        color: Colors.white70,
                        size: 20,
                      ),
                      onPressed: () => _shareItem(activeItem),
                    ),
                  IconButton(
                    tooltip: 'Dừng phát',
                    icon: const Icon(
                      Icons.close,
                      color: Colors.white70,
                      size: 22,
                    ),
                    onPressed: () async {
                      final next = await CallRecordingService.stop();
                      if (mounted) setState(() => _playbackState = next);
                    },
                  ),
                ],
              ),
              Row(
                children: [
                  Text(
                    CallRecordingItem.formatDurationMs(sliderValue.round()),
                    style: const TextStyle(color: Colors.white70, fontSize: 11),
                  ),
                  Expanded(
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        thumbShape: const RoundSliderThumbShape(
                          enabledThumbRadius: 6,
                        ),
                        trackHeight: 3,
                        activeTrackColor: Colors.lightBlueAccent,
                        inactiveTrackColor: Colors.white24,
                        thumbColor: Colors.white,
                      ),
                      child: Slider(
                        min: 0,
                        max: safeMax,
                        value: sliderValue,
                        onChangeStart: (v) {
                          setState(() {
                            _isDraggingSlider = true;
                            _sliderDragMs = v;
                          });
                        },
                        onChanged: (v) {
                          setState(() => _sliderDragMs = v);
                        },
                        onChangeEnd: (v) async {
                          setState(() => _isDraggingSlider = false);
                          final next = await CallRecordingService.seekTo(
                            v.round(),
                          );
                          if (mounted) setState(() => _playbackState = next);
                        },
                      ),
                    ),
                  ),
                  Text(
                    CallRecordingItem.formatDurationMs(totalMs),
                    style: const TextStyle(color: Colors.white70, fontSize: 11),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

