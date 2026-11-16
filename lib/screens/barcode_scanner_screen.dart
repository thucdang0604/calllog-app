import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/scanned_barcode_item.dart';
import '../services/app_settings_service.dart';
import '../services/barcode_scanner_service.dart';

enum _BarcodeSectionTab { today, shared, archive }

class BarcodeScannerScreen extends StatefulWidget {
  const BarcodeScannerScreen({super.key});

  @override
  State<BarcodeScannerScreen> createState() => _BarcodeScannerScreenState();
}

class _BarcodeScannerScreenState extends State<BarcodeScannerScreen> {
  List<ScannedBarcodeItem> _items = [];
  bool _isLoading = true;
  String _searchQuery = '';
  String _selectedFilter = 'all'; // 'all', 'qr', 'barcode'
  _BarcodeSectionTab _activeTab = _BarcodeSectionTab.today;

  bool _isSelectionMode = false;
  final Set<String> _selectedIds = <String>{};
  final Set<String> _expandedArchiveDates = <String>{};

  @override
  void initState() {
    super.initState();
    AppSettingsService.load();
    _loadData();
  }

  Future<void> _loadData() async {
    final list = await BarcodeScannerService.loadHistory();
    if (!mounted) return;
    final partitioned = BarcodeScannerService.partitionByDay(list);
    setState(() {
      _items = list;
      _isLoading = false;
      _selectedIds.removeWhere((id) => !list.any((e) => e.id == id));
      if (_selectedIds.isEmpty) _isSelectionMode = false;
      if (_expandedArchiveDates.isEmpty && partitioned.archiveGroups.isNotEmpty) {
        _expandedArchiveDates.add(partitioned.archiveGroups.first.dateKey);
      }
    });
  }

  Future<void> _startScanning() async {
    final prePartition = BarcodeScannerService.partitionByDay(_items);
    final scannedBatch = await BarcodeScannerService.openScanner(
      existingPendingCodes:
          prePartition.today.map((e) => e.code).toSet().toList(),
      existingSharedCodes:
          prePartition.shared.map((e) => e.code).toSet().toList(),
    );
    if (scannedBatch.isEmpty) {
      await _loadData();
      return;
    }

    final currentHistory = await BarcodeScannerService.loadHistory();
    final classified = BarcodeScannerService.classifyScannedBatch(
      scannedBatch,
      currentHistory,
    );

    final newCount = classified.brandNew.length;
    final pendingDupCount = classified.dupInPending.length;
    final sharedDupCount = classified.dupInShared.length;
    final totalDupCount = pendingDupCount + sharedDupCount;

    bool keepAll = false;
    if (totalDupCount > 0) {
      await AppSettingsService.load();
      if (!mounted) {
        await BarcodeScannerService.deleteAllImages(scannedBatch);
        return;
      }
      if (AppSettingsService.current.barcodePostScanDupDialogEnabled) {
        keepAll = await _showPostScanDuplicateDialog(
          totalScanned: scannedBatch.length,
          brandNew: classified.brandNew,
          dupInPending: classified.dupInPending,
          dupInShared: classified.dupInShared,
        );
      }
    }

    final List<ScannedBarcodeItem> itemsToAdd =
        (totalDupCount == 0 || keepAll) ? scannedBatch : classified.brandNew;
    final List<ScannedBarcodeItem> discarded = (totalDupCount > 0 && !keepAll)
        ? [...classified.dupInPending, ...classified.dupInShared]
        : const <ScannedBarcodeItem>[];

    final updated = await BarcodeScannerService.commitScannedBatch(
      currentHistory,
      itemsToAdd: itemsToAdd,
      discardedDuplicates: discarded,
    );
    if (!mounted) return;

    final postPartition = BarcodeScannerService.partitionByDay(updated);
    setState(() {
      _items = updated;
      _activeTab = _BarcodeSectionTab.today;
      _isSelectionMode = false;
      _selectedIds.clear();
      if (_expandedArchiveDates.isEmpty &&
          postPartition.archiveGroups.isNotEmpty) {
        _expandedArchiveDates.add(postPartition.archiveGroups.first.dateKey);
      }
    });

    String message;
    Color bgColor;
    if (totalDupCount == 0) {
      message = '✅ Đã quét thành công $newCount mã mới!';
      bgColor = Colors.green[700]!;
    } else if (keepAll) {
      message =
          '✅ Đã giữ lại toàn bộ ${scannedBatch.length} mã vừa quét vào Hôm nay.';
      bgColor = Colors.green[700]!;
    } else if (newCount > 0) {
      message = '✅ Đã lưu $newCount mã mới · 🔁 Bỏ qua $totalDupCount mã đã có.';
      bgColor = Colors.green[700]!;
    } else {
      message = '🔁 Đã bỏ qua $totalDupCount mã đã có (không thêm mã mới).';
      bgColor = Colors.blueGrey[700]!;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: bgColor,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  Future<bool> _showPostScanDuplicateDialog({
    required int totalScanned,
    required List<ScannedBarcodeItem> brandNew,
    required List<ScannedBarcodeItem> dupInPending,
    required List<ScannedBarcodeItem> dupInShared,
  }) async {
    Widget buildDupPreview(
      String title,
      Color color,
      List<ScannedBarcodeItem> list,
    ) {
      return Container(
        margin: const EdgeInsets.only(top: 8),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '$title (${list.length} mã):',
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                color: color,
              ),
            ),
            const SizedBox(height: 4),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 88),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: list
                      .map(
                        (e) => Padding(
                          padding: const EdgeInsets.symmetric(vertical: 1),
                          child: Text(
                            '• ${e.code}',
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 12,
                            ),
                          ),
                        ),
                      )
                      .toList(),
                ),
              ),
            ),
          ],
        ),
      );
    }

    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text(
          'Kết quả quét ($totalScanned mã)',
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.green.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.green.shade200),
                ),
                child: Text(
                  '✅ Mã mới hôm nay: ${brandNew.length} mã',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 13.5,
                    color: Colors.green.shade800,
                  ),
                ),
              ),
              if (dupInShared.isNotEmpty)
                buildDupPreview(
                  '⚠️ Đã nằm trong Đã chia sẻ',
                  Colors.orange.shade800,
                  dupInShared,
                ),
              if (dupInPending.isNotEmpty)
                buildDupPreview(
                  '🔁 Đã có trong Hôm nay',
                  Colors.blue.shade700,
                  dupInPending,
                ),
              const SizedBox(height: 12),
              Text(
                'Chọn cách xử lý cho lần quét này:',
                style: TextStyle(
                  fontSize: 12.5,
                  color: Colors.grey.shade700,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.purple.shade700,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                  ),
                  child: Text(
                    brandNew.isNotEmpty
                        ? '1. Bỏ qua mã đã có (chỉ giữ ${brandNew.length} mã mới)'
                        : '1. Bỏ qua mã đã có (không thêm mã trùng)',
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: () => Navigator.of(ctx).pop(true),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                  ),
                  child: Text(
                    '2. Giữ lại toàn bộ $totalScanned mã vừa quét',
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return result == true;
  }

  List<ScannedBarcodeItem> _applySearchAndTypeFilter(
    List<ScannedBarcodeItem> source,
  ) {
    var list = source;
    if (_selectedFilter == 'qr') {
      list = list.where((e) => e.isQrCode).toList();
    } else if (_selectedFilter == 'barcode') {
      list = list.where((e) => !e.isQrCode).toList();
    }
    final q = _searchQuery.trim().toLowerCase();
    if (q.isNotEmpty) {
      list = list.where((e) => e.code.toLowerCase().contains(q)).toList();
    }
    return list;
  }

  Future<void> _setItemsSharedState(
    List<ScannedBarcodeItem> targetItems, {
    required bool shared,
    bool exitSelection = false,
  }) async {
    if (targetItems.isEmpty) return;
    final updated = BarcodeScannerService.markItemsSharedState(
      _items,
      targetItems.map((e) => e.id),
      shared: shared,
    );
    setState(() {
      _items = updated;
      if (exitSelection) {
        _isSelectionMode = false;
        _selectedIds.clear();
      }
    });
    await BarcodeScannerService.saveHistory(_items);
  }

  Future<void> _copyItems(
    List<ScannedBarcodeItem> targetItems, {
    String? customMessage,
    bool exitSelection = false,
    bool moveToSharedIfPending = false,
  }) async {
    if (targetItems.isEmpty) return;
    await BarcodeScannerService.copyList(targetItems, withIndex: false);
    if (!mounted) return;

    final pendingTargets =
        moveToSharedIfPending ? targetItems.where((e) => !e.isShared).toList() : const <ScannedBarcodeItem>[];
    if (pendingTargets.isNotEmpty) {
      await _setItemsSharedState(
        pendingTargets,
        shared: true,
        exitSelection: exitSelection,
      );
    } else if (exitSelection) {
      setState(() {
        _isSelectionMode = false;
        _selectedIds.clear();
      });
    }
    if (!mounted) return;

    final String message;
    if (pendingTargets.isNotEmpty) {
      message = pendingTargets.length == targetItems.length
          ? '📋 Đã copy ${targetItems.length} mã và chuyển sang Đã chia sẻ!'
          : '📋 Đã copy ${targetItems.length} mã (${pendingTargets.length} mã chuyển sang Đã chia sẻ)!';
    } else {
      message =
          customMessage ?? '📋 Đã sao chép ${targetItems.length} mã vào bộ nhớ tạm!';
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.blue[700],
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _shareItems(
    List<ScannedBarcodeItem> targetItems, {
    String? title,
    bool exitSelection = false,
    bool moveToSharedIfPending = false,
  }) async {
    if (targetItems.isEmpty) return;
    final success = await BarcodeScannerService.shareList(
      targetItems,
      title: title,
    );
    if (!mounted) return;
    if (!success) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Không mở được ứng dụng chia sẻ.'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    final pendingTargets =
        moveToSharedIfPending ? targetItems.where((e) => !e.isShared).toList() : const <ScannedBarcodeItem>[];
    if (pendingTargets.isNotEmpty) {
      await _setItemsSharedState(
        pendingTargets,
        shared: true,
        exitSelection: exitSelection,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '📤 Đã chuyển ${pendingTargets.length} mã sang mục Đã chia sẻ!',
          ),
          backgroundColor: Colors.green[700],
          duration: const Duration(seconds: 2),
        ),
      );
    } else if (exitSelection) {
      setState(() {
        _isSelectionMode = false;
        _selectedIds.clear();
      });
    }
  }

  Future<void> _restoreItemsToToday(
    List<ScannedBarcodeItem> targetItems, {
    bool exitSelection = false,
  }) async {
    final sharedTargets = targetItems.where((e) => e.isShared).toList();
    if (sharedTargets.isEmpty) return;
    await _setItemsSharedState(
      sharedTargets,
      shared: false,
      exitSelection: exitSelection,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '↩ Đã đưa ${sharedTargets.length} mã quay lại mục Hôm nay.',
        ),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _deleteItem(ScannedBarcodeItem item) async {
    setState(() {
      _items.removeWhere((e) => e.id == item.id);
      _selectedIds.remove(item.id);
      if (_selectedIds.isEmpty) _isSelectionMode = false;
    });
    await BarcodeScannerService.deleteImageFile(item.imagePath);
    await BarcodeScannerService.saveHistory(_items);
  }

  Future<void> _deleteItemsBatch(
    List<ScannedBarcodeItem> targets, {
    required String dialogTitle,
    required String dialogBody,
    required String snackMessage,
  }) async {
    if (targets.isEmpty) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(dialogTitle),
        content: Text(dialogBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Hủy'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            child: const Text('Xóa'),
          ),
        ],
      ),
    );

    if (confirm != true) return;
    final deleteIds = targets.map((e) => e.id).toSet();
    setState(() {
      _items.removeWhere((e) => deleteIds.contains(e.id));
      _selectedIds.removeWhere(deleteIds.contains);
      if (_selectedIds.isEmpty) _isSelectionMode = false;
    });
    await BarcodeScannerService.deleteAllImages(targets);
    await BarcodeScannerService.saveHistory(_items);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(snackMessage),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  void _toggleSelectionMode() {
    setState(() {
      _isSelectionMode = !_isSelectionMode;
      if (!_isSelectionMode) {
        _selectedIds.clear();
      }
    });
  }

  void _toggleItemSelection(ScannedBarcodeItem item) {
    setState(() {
      if (!_isSelectionMode) {
        _isSelectionMode = true;
      }
      if (!_selectedIds.add(item.id)) {
        _selectedIds.remove(item.id);
      }
    });
  }

  void _selectOrClearVisible(List<ScannedBarcodeItem> visible) {
    final visibleIds = visible.map((e) => e.id).toSet();
    final allSelected =
        visibleIds.isNotEmpty && visibleIds.every(_selectedIds.contains);
    setState(() {
      _isSelectionMode = true;
      if (allSelected) {
        _selectedIds.removeAll(visibleIds);
      } else {
        _selectedIds.addAll(visibleIds);
      }
    });
  }

  Widget _buildFormatIcon(bool isQr) {
    return Container(
      width: 48,
      height: 48,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: isQr ? Colors.purple.shade50 : Colors.blue.shade50,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(
        isQr ? Icons.qr_code_2 : Icons.line_weight,
        color: isQr ? Colors.purple.shade700 : Colors.blue.shade700,
        size: 24,
      ),
    );
  }

  Widget _buildLeadingThumbnail(ScannedBarcodeItem item, bool isQr) {
    if (!item.hasImage) {
      return _buildFormatIcon(isQr);
    }

    return InkWell(
      onTap: () => _showPhotoPreviewDialog(item),
      borderRadius: BorderRadius.circular(8),
      child: Tooltip(
        message: 'Xem ảnh ngoại quan',
        child: Stack(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.file(
                File(item.imagePath!),
                width: 48,
                height: 48,
                cacheWidth: 160,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => _buildFormatIcon(isQr),
              ),
            ),
            Positioned(
              right: 2,
              bottom: 2,
              child: Container(
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Icon(
                  Icons.zoom_in,
                  size: 11,
                  color: Colors.white,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showPhotoPreviewDialog(ScannedBarcodeItem item) {
    if (!item.hasImage) return;

    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        insetPadding: const EdgeInsets.all(16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
              color: Colors.grey.shade900,
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.code,
                          style: const TextStyle(
                            color: Colors.white,
                            fontFamily: 'monospace',
                            fontWeight: FontWeight.bold,
                            fontSize: 15,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${item.format} · ${item.formattedDateTime}',
                          style: TextStyle(
                            color: Colors.grey.shade300,
                            fontSize: 11.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.copy_rounded, color: Colors.white, size: 20),
                    tooltip: 'Copy mã',
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: item.code));
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('Đã copy: ${item.code}'),
                          duration: const Duration(seconds: 1),
                        ),
                      );
                    },
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white),
                    tooltip: 'Đóng',
                    onPressed: () => Navigator.of(ctx).pop(),
                  ),
                ],
              ),
            ),
            Container(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.62,
              ),
              color: Colors.black,
              child: InteractiveViewer(
                minScale: 1.0,
                maxScale: 4.5,
                child: Image.file(
                  File(item.imagePath!),
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => const Padding(
                    padding: EdgeInsets.all(32),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.broken_image_outlined, color: Colors.white54, size: 48),
                        SizedBox(height: 8),
                        Text(
                          'Ảnh ngoại quan không còn tồn tại.',
                          style: TextStyle(color: Colors.white70),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              color: Colors.grey.shade100,
              child: Text(
                'Chạm 2 ngón tay để phóng to/thu nhỏ xem chi tiết kiện hàng',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11.5, color: Colors.grey.shade700),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showAddManualCodeDialog() async {
    final codeController = TextEditingController();
    String format = 'Code 128';

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Nhập mã thủ công'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: codeController,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Mã vận đơn / Mã vạch',
                  hintText: 'VD: GHN123456789, SPX987...',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                value: format,
                decoration: const InputDecoration(
                  labelText: 'Loại mã',
                  border: OutlineInputBorder(),
                ),
                items: const [
                  DropdownMenuItem(value: 'Code 128', child: Text('Mã vạch (Code 128)')),
                  DropdownMenuItem(value: 'QR Code', child: Text('Mã QR (QR Code)')),
                  DropdownMenuItem(value: 'EAN-13', child: Text('Mã vạch (EAN-13)')),
                ],
                onChanged: (val) {
                  if (val != null) setDialogState(() => format = val);
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Hủy'),
            ),
            ElevatedButton(
              onPressed: () async {
                final text = codeController.text.trim();
                if (text.isEmpty) return;

                final nowMs = DateTime.now().millisecondsSinceEpoch;
                final newItem = ScannedBarcodeItem(
                  id: '${text}_$nowMs',
                  code: text,
                  format: format,
                  timestamp: nowMs,
                );

                final classified = BarcodeScannerService.classifyScannedBatch(
                  [newItem],
                  _items,
                );
                final dupInShared = classified.dupInShared.isNotEmpty;
                final dupInPending = classified.dupInPending.isNotEmpty;

                if (dupInShared || dupInPending) {
                  final whereText =
                      dupInShared ? 'mục Đã chia sẻ' : 'danh sách Hôm nay';
                  final proceed = await showDialog<bool>(
                    context: ctx,
                    builder: (dupCtx) => AlertDialog(
                      title: const Text('Mã đã tồn tại hôm nay'),
                      content: Text(
                        'Mã "$text" hiện đã có trong $whereText. Bạn vẫn muốn thêm lại vào Hôm nay chứ?',
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.of(dupCtx).pop(false),
                          child: const Text('Bỏ qua'),
                        ),
                        ElevatedButton(
                          onPressed: () => Navigator.of(dupCtx).pop(true),
                          child: const Text('Vẫn thêm'),
                        ),
                      ],
                    ),
                  );
                  if (proceed != true) {
                    if (ctx.mounted) Navigator.of(ctx).pop();
                    return;
                  }
                }

                if (!mounted) return;
                setState(() {
                  _items.insert(0, newItem);
                  _activeTab = _BarcodeSectionTab.today;
                });
                await BarcodeScannerService.saveHistory(_items);
                if (ctx.mounted) Navigator.of(ctx).pop();
              },
              child: const Text('Thêm mã'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBarcodeCard(ScannedBarcodeItem item) {
    final isQr = item.isQrCode;
    final isSelected = _selectedIds.contains(item.id);

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      elevation: isSelected ? 2 : 1,
      color: isSelected ? Colors.purple.shade50.withValues(alpha: 0.45) : null,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(
          color: isSelected
              ? Colors.purple.shade600
              : (isQr
                  ? Colors.purple.withValues(alpha: 0.25)
                  : Colors.blue.withValues(alpha: 0.25)),
          width: isSelected ? 1.5 : 1.0,
        ),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        onLongPress: () => _toggleItemSelection(item),
        onTap: _isSelectionMode ? () => _toggleItemSelection(item) : null,
        leading: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_isSelectionMode)
              Checkbox(
                value: isSelected,
                visualDensity: VisualDensity.compact,
                activeColor: Colors.purple.shade700,
                onChanged: (_) => _toggleItemSelection(item),
              ),
            _buildLeadingThumbnail(item, isQr),
          ],
        ),
        title: _isSelectionMode
            ? Text(
                item.code,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.bold,
                  fontSize: 14.5,
                ),
              )
            : SelectableText(
                item.code,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.bold,
                  fontSize: 14.5,
                ),
              ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Wrap(
            spacing: 6,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                decoration: BoxDecoration(
                  color: Colors.grey.shade200,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  item.format,
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    color: Colors.grey.shade800,
                  ),
                ),
              ),
              if (_activeTab == _BarcodeSectionTab.shared ||
                  _activeTab == _BarcodeSectionTab.archive)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 1.5,
                  ),
                  decoration: BoxDecoration(
                    color: item.isShared
                        ? Colors.green.shade50
                        : Colors.orange.shade50,
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(
                      color: item.isShared
                          ? Colors.green.shade300
                          : Colors.orange.shade300,
                      width: 0.7,
                    ),
                  ),
                  child: Text(
                    item.isShared
                        ? (item.formattedSharedTime != null &&
                                _activeTab == _BarcodeSectionTab.shared
                            ? 'Đã chia sẻ · ${item.formattedSharedTime}'
                            : 'Đã chia sẻ')
                        : 'Chưa chia sẻ',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: item.isShared
                          ? Colors.green.shade800
                          : Colors.orange.shade800,
                    ),
                  ),
                ),
              Text(
                item.formattedDateTime,
                style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
              ),
            ],
          ),
        ),
        trailing: _isSelectionMode
            ? null
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_activeTab == _BarcodeSectionTab.shared)
                    IconButton(
                      icon: Icon(
                        Icons.undo_rounded,
                        size: 18,
                        color: Colors.orange.shade700,
                      ),
                      tooltip: 'Đưa lại về Hôm nay',
                      onPressed: () => _restoreItemsToToday([item]),
                    ),
                  IconButton(
                    icon: const Icon(Icons.copy_rounded, size: 18),
                    tooltip: 'Copy mã',
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: item.code));
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('Đã copy: ${item.code}'),
                          duration: const Duration(seconds: 1),
                        ),
                      );
                    },
                  ),
                  IconButton(
                    icon: Icon(Icons.close, size: 18, color: Colors.grey.shade600),
                    tooltip: 'Xóa mã',
                    onPressed: () => _deleteItem(item),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _buildArchiveDateSection(BarcodeArchiveGroup group) {
    final forceExpandedBySearch = _searchQuery.trim().isNotEmpty;
    final isExpanded =
        forceExpandedBySearch || _expandedArchiveDates.contains(group.dateKey);
    final groupIds = group.items.map((e) => e.id).toSet();
    final allInGroupSelected =
        groupIds.isNotEmpty && groupIds.every(_selectedIds.contains);

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: Column(
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () {
              setState(() {
                if (!_expandedArchiveDates.remove(group.dateKey)) {
                  _expandedArchiveDates.add(group.dateKey);
                }
              });
            },
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
              child: Row(
                children: [
                  Icon(
                    isExpanded
                        ? Icons.keyboard_arrow_down
                        : Icons.keyboard_arrow_right,
                    color: Colors.grey.shade700,
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    Icons.inventory_2_outlined,
                    size: 16,
                    color: Colors.blueGrey.shade700,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '${group.label} (${group.items.length} mã)',
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 13.5,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: allInGroupSelected
                        ? 'Bỏ chọn ngày này'
                        : 'Chọn tất cả mã ngày này',
                    visualDensity: VisualDensity.compact,
                    icon: Icon(
                      allInGroupSelected
                          ? Icons.check_box
                          : Icons.check_box_outline_blank,
                      size: 18,
                      color: allInGroupSelected
                          ? Colors.purple.shade700
                          : Colors.grey.shade600,
                    ),
                    onPressed: () {
                      setState(() {
                        _isSelectionMode = true;
                        _expandedArchiveDates.add(group.dateKey);
                        if (allInGroupSelected) {
                          _selectedIds.removeAll(groupIds);
                        } else {
                          _selectedIds.addAll(groupIds);
                        }
                      });
                    },
                  ),
                  IconButton(
                    tooltip: 'Copy tất cả mã ngày ${group.label}',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.copy_rounded, size: 18),
                    onPressed: () => _copyItems(
                      group.items,
                      customMessage:
                          '📋 Đã copy ${group.items.length} mã ngày ${group.label}!',
                    ),
                  ),
                  IconButton(
                    tooltip: 'Xóa ngày này',
                    visualDensity: VisualDensity.compact,
                    icon: Icon(
                      Icons.delete_outline,
                      size: 18,
                      color: Colors.red.shade400,
                    ),
                    onPressed: () => _deleteItemsBatch(
                      group.items,
                      dialogTitle: 'Xóa mã ngày ${group.label}?',
                      dialogBody:
                          'Xóa toàn bộ ${group.items.length} mã và ảnh ngoại quan của ngày ${group.label}?',
                      snackMessage: 'Đã xóa ${group.items.length} mã ngày ${group.label}.',
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (isExpanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: Column(
                children: group.items.map(_buildBarcodeCard).toList(),
              ),
            ),
        ],
      ),
    );
  }

  void _switchTab(_BarcodeSectionTab nextTab) {
    if (_activeTab == nextTab) return;
    setState(() {
      _activeTab = nextTab;
      _isSelectionMode = false;
      _selectedIds.clear();
    });
  }

  String _activeTabLabel() {
    switch (_activeTab) {
      case _BarcodeSectionTab.today:
        return 'Hôm nay';
      case _BarcodeSectionTab.shared:
        return 'Đã chia sẻ';
      case _BarcodeSectionTab.archive:
        return 'Lưu trữ';
    }
  }

  @override
  Widget build(BuildContext context) {
    final partitioned = BarcodeScannerService.partitionByDay(_items);
    final tabSource = switch (_activeTab) {
      _BarcodeSectionTab.today => partitioned.today,
      _BarcodeSectionTab.shared => partitioned.shared,
      _BarcodeSectionTab.archive => partitioned.archive,
    };

    final filteredVisible = _applySearchAndTypeFilter(tabSource);
    final visibleArchiveGroups = _activeTab == _BarcodeSectionTab.archive
        ? BarcodeScannerService.partitionByDay(
            filteredVisible,
            // Dùng ngày hôm nay làm mốc: mọi item ở đây đều nằm trong mục Lưu trữ
          ).archiveGroups
        : const <BarcodeArchiveGroup>[];

    final tabTotalCount = tabSource.length;
    final tabQrCount = tabSource.where((e) => e.isQrCode).length;
    final tabBarcodeCount = tabTotalCount - tabQrCount;

    final selectedItems =
        _items.where((e) => _selectedIds.contains(e.id)).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Quét Mã Vạch & QR Code',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        actions: [
          if (tabSource.isNotEmpty)
            IconButton(
              icon: Icon(
                _isSelectionMode ? Icons.close : Icons.checklist_rounded,
              ),
              tooltip: _isSelectionMode ? 'Thoát chế độ chọn' : 'Chọn nhiều mã',
              onPressed: _toggleSelectionMode,
            ),
          if (_items.isNotEmpty)
            PopupMenuButton<String>(
              tooltip: 'Tùy chọn xóa',
              onSelected: (value) {
                if (value == 'clear_tab') {
                  final label = _activeTabLabel();
                  _deleteItemsBatch(
                    List<ScannedBarcodeItem>.from(tabSource),
                    dialogTitle: 'Xóa danh sách $label?',
                    dialogBody:
                        'Xóa toàn bộ ${tabSource.length} mã trong mục $label?',
                    snackMessage: 'Đã xóa sạch mục $label.',
                  );
                } else if (value == 'clear_all') {
                  _deleteItemsBatch(
                    List<ScannedBarcodeItem>.from(_items),
                    dialogTitle: 'Xác nhận xóa tất cả?',
                    dialogBody:
                        'Bạn có chắc muốn xóa toàn bộ ${_items.length} mã (Hôm nay, Đã chia sẻ và Lưu trữ)?',
                    snackMessage: 'Đã xóa sạch danh sách mã đã quét.',
                  );
                }
              },
              itemBuilder: (_) => [
                if (tabSource.isNotEmpty)
                  PopupMenuItem(
                    value: 'clear_tab',
                    child: Text(
                      'Xóa mục ${_activeTabLabel()} (${tabSource.length})',
                    ),
                  ),
                const PopupMenuItem(
                  value: 'clear_all',
                  child: Text(
                    'Xóa tất cả mọi ngày',
                    style: TextStyle(color: Colors.red),
                  ),
                ),
              ],
            ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                // Top Action Dashboard Card
                Container(
                  margin: const EdgeInsets.fromLTRB(16, 10, 16, 8),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(14),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.05),
                        blurRadius: 8,
                        offset: const Offset(0, 2),
                      ),
                    ],
                    border: Border.all(
                      color: Colors.purple.withValues(alpha: 0.2),
                    ),
                  ),
                  child: Column(
                    children: [
                      SizedBox(
                        width: double.infinity,
                        height: 46,
                        child: ElevatedButton.icon(
                          onPressed: _startScanning,
                          icon: const Icon(Icons.qr_code_scanner, size: 22),
                          label: const Text(
                            'BẮT ĐẦU QUÉT MÃ',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 15,
                            ),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.purple.shade700,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: filteredVisible.isNotEmpty
                                  ? () => _copyItems(
                                        filteredVisible,
                                        customMessage:
                                            '📋 Đã sao chép ${filteredVisible.length} mã!',
                                        moveToSharedIfPending: _activeTab ==
                                            _BarcodeSectionTab.today,
                                      )
                                  : null,
                              icon: const Icon(Icons.copy_rounded, size: 15),
                              label: const Text(
                                'Copy lọc',
                                style: TextStyle(fontSize: 12),
                              ),
                              style: OutlinedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(vertical: 7),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(8),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: filteredVisible.isNotEmpty
                                  ? () => _shareItems(
                                        filteredVisible,
                                        title: switch (_activeTab) {
                                          _BarcodeSectionTab.today =>
                                            'MÃ QUÉT HÔM NAY',
                                          _BarcodeSectionTab.shared =>
                                            'MÃ ĐÃ CHIA SẺ',
                                          _BarcodeSectionTab.archive =>
                                            'MÃ QUÉT LƯU TRỮ',
                                        },
                                        moveToSharedIfPending: _activeTab ==
                                            _BarcodeSectionTab.today,
                                      )
                                  : null,
                              icon: const Icon(Icons.share_rounded, size: 15),
                              label: const Text(
                                'Chia sẻ',
                                style: TextStyle(fontSize: 12),
                              ),
                              style: OutlinedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(vertical: 7),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(8),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          OutlinedButton.icon(
                            onPressed: _showAddManualCodeDialog,
                            icon: const Icon(Icons.add, size: 15),
                            label: const Text(
                              'Thêm tay',
                              style: TextStyle(fontSize: 12),
                            ),
                            style: OutlinedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 7,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

                // Daily Split Tabs: Hôm nay vs Đã chia sẻ vs Lưu trữ
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      Expanded(
                        child: _buildDayTabButton(
                          label: 'Hôm nay (${partitioned.today.length})',
                          icon: Icons.today_outlined,
                          selected: _activeTab == _BarcodeSectionTab.today,
                          onTap: () => _switchTab(_BarcodeSectionTab.today),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: _buildDayTabButton(
                          label: 'Đã chia sẻ (${partitioned.shared.length})',
                          icon: Icons.check_circle_outline,
                          selected: _activeTab == _BarcodeSectionTab.shared,
                          onTap: () => _switchTab(_BarcodeSectionTab.shared),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: _buildDayTabButton(
                          label: 'Lưu trữ (${partitioned.archive.length})',
                          icon: Icons.archive_outlined,
                          selected: _activeTab == _BarcodeSectionTab.archive,
                          onTap: () => _switchTab(_BarcodeSectionTab.archive),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 6),

                // Search & Select Toggle Row
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 2,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          decoration: InputDecoration(
                            hintText: switch (_activeTab) {
                              _BarcodeSectionTab.today => 'Tìm mã hôm nay...',
                              _BarcodeSectionTab.shared =>
                                'Tìm mã đã chia sẻ...',
                              _BarcodeSectionTab.archive =>
                                'Tìm mã trong lưu trữ...',
                            },
                            prefixIcon: const Icon(Icons.search, size: 20),
                            isDense: true,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 8,
                            ),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(10),
                              borderSide: BorderSide(
                                color: Colors.grey.shade300,
                              ),
                            ),
                            suffixIcon: _searchQuery.isNotEmpty
                                ? IconButton(
                                    icon: const Icon(Icons.clear, size: 18),
                                    onPressed: () =>
                                        setState(() => _searchQuery = ''),
                                  )
                                : null,
                          ),
                          onChanged: (val) =>
                              setState(() => _searchQuery = val),
                        ),
                      ),
                      const SizedBox(width: 8),
                      FilterChip(
                        selected: _isSelectionMode,
                        label: Text(
                          _isSelectionMode ? 'Đang chọn' : 'Chọn mã',
                          style: const TextStyle(fontSize: 12),
                        ),
                        avatar: Icon(
                          _isSelectionMode
                              ? Icons.check_box
                              : Icons.check_box_outline_blank,
                          size: 16,
                        ),
                        onSelected: (_) => _toggleSelectionMode(),
                      ),
                    ],
                  ),
                ),

                // Filter Tabs (All, QR, Barcode)
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 4,
                  ),
                  child: Row(
                    children: [
                      ChoiceChip(
                        label: Text('Tất cả ($tabTotalCount)'),
                        selected: _selectedFilter == 'all',
                        onSelected: (_) =>
                            setState(() => _selectedFilter = 'all'),
                      ),
                      const SizedBox(width: 6),
                      ChoiceChip(
                        label: Text('QR Code ($tabQrCount)'),
                        selected: _selectedFilter == 'qr',
                        onSelected: (_) =>
                            setState(() => _selectedFilter = 'qr'),
                      ),
                      const SizedBox(width: 6),
                      ChoiceChip(
                        label: Text('Mã vạch ($tabBarcodeCount)'),
                        selected: _selectedFilter == 'barcode',
                        onSelected: (_) =>
                            setState(() => _selectedFilter = 'barcode'),
                      ),
                    ],
                  ),
                ),

                // Contextual Multi-Select Action Bar
                if (_isSelectionMode)
                  Container(
                    margin: const EdgeInsets.fromLTRB(16, 2, 16, 6),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.purple.shade50,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Colors.purple.shade200),
                    ),
                    child: Row(
                      children: [
                        TextButton(
                          onPressed: filteredVisible.isEmpty
                              ? null
                              : () => _selectOrClearVisible(filteredVisible),
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 6),
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          child: Text(
                            filteredVisible.isNotEmpty &&
                                    filteredVisible
                                        .every((e) => _selectedIds.contains(e.id))
                                ? 'Bỏ chọn'
                                : 'Chọn tất cả (${filteredVisible.length})',
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        const Spacer(),
                        ElevatedButton.icon(
                          onPressed: selectedItems.isEmpty
                              ? null
                              : () => _copyItems(
                                    selectedItems,
                                    customMessage:
                                        '📋 Đã copy ${selectedItems.length} mã đã chọn!',
                                    exitSelection: true,
                                    moveToSharedIfPending: _activeTab !=
                                        _BarcodeSectionTab.shared,
                                  ),
                          icon: const Icon(Icons.copy_all_rounded, size: 16),
                          label: Text(
                            'Copy (${selectedItems.length})',
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.purple.shade700,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 6,
                            ),
                            minimumSize: Size.zero,
                          ),
                        ),
                        const SizedBox(width: 4),
                        IconButton(
                          tooltip: 'Chia sẻ mã đã chọn',
                          visualDensity: VisualDensity.compact,
                          onPressed: selectedItems.isEmpty
                              ? null
                              : () => _shareItems(
                                    selectedItems,
                                    title: 'MÃ ĐÃ CHỌN',
                                    exitSelection: true,
                                    moveToSharedIfPending: _activeTab !=
                                        _BarcodeSectionTab.shared,
                                  ),
                          icon: const Icon(Icons.share_rounded, size: 19),
                        ),
                        if (_activeTab == _BarcodeSectionTab.shared)
                          IconButton(
                            tooltip: 'Đưa lại về Hôm nay',
                            visualDensity: VisualDensity.compact,
                            onPressed: selectedItems.isEmpty
                                ? null
                                : () => _restoreItemsToToday(
                                      selectedItems,
                                      exitSelection: true,
                                    ),
                            icon: Icon(
                              Icons.undo_rounded,
                              size: 19,
                              color: Colors.orange.shade700,
                            ),
                          ),
                        IconButton(
                          tooltip: 'Xóa mã đã chọn',
                          visualDensity: VisualDensity.compact,
                          onPressed: selectedItems.isEmpty
                              ? null
                              : () => _deleteItemsBatch(
                                    selectedItems,
                                    dialogTitle:
                                        'Xóa ${selectedItems.length} mã đã chọn?',
                                    dialogBody:
                                        'Các mã đã chọn và ảnh ngoại quan kèm theo sẽ bị xóa vĩnh viễn.',
                                    snackMessage:
                                        'Đã xóa ${selectedItems.length} mã đã chọn.',
                                  ),
                          icon: Icon(
                            Icons.delete_outline,
                            size: 20,
                            color: Colors.red.shade600,
                          ),
                        ),
                      ],
                    ),
                  ),

                // Main List Area
                Expanded(
                  child: filteredVisible.isEmpty
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 24),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  switch (_activeTab) {
                                    _BarcodeSectionTab.today =>
                                      Icons.qr_code_scanner_rounded,
                                    _BarcodeSectionTab.shared =>
                                      Icons.check_circle_outline,
                                    _BarcodeSectionTab.archive =>
                                      Icons.inventory_2_outlined,
                                  },
                                  size: 60,
                                  color: Colors.grey.shade400,
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  switch (_activeTab) {
                                    _BarcodeSectionTab.today =>
                                      partitioned.today.isEmpty
                                          ? 'Hôm nay chưa có mã nào chờ xử lý.'
                                          : 'Không tìm thấy mã phù hợp hôm nay.',
                                    _BarcodeSectionTab.shared =>
                                      partitioned.shared.isEmpty
                                          ? 'Chưa có mã nào được copy/chia sẻ hôm nay.'
                                          : 'Không tìm thấy mã phù hợp trong Đã chia sẻ.',
                                    _BarcodeSectionTab.archive =>
                                      partitioned.archive.isEmpty
                                          ? 'Chưa có mã nào trong lưu trữ các ngày trước.'
                                          : 'Không tìm thấy mã phù hợp trong lưu trữ.',
                                  },
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    color: Colors.grey.shade600,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                                if (_activeTab == _BarcodeSectionTab.today &&
                                    partitioned.shared.isNotEmpty) ...[
                                  const SizedBox(height: 8),
                                  TextButton.icon(
                                    onPressed: () =>
                                        _switchTab(_BarcodeSectionTab.shared),
                                    icon: const Icon(
                                      Icons.check_circle_outline,
                                    ),
                                    label: Text(
                                      'Xem ${partitioned.shared.length} mã trong Đã chia sẻ',
                                    ),
                                  ),
                                ],
                                if (_activeTab == _BarcodeSectionTab.today &&
                                    partitioned.archive.isNotEmpty) ...[
                                  const SizedBox(height: 4),
                                  TextButton.icon(
                                    onPressed: () =>
                                        _switchTab(_BarcodeSectionTab.archive),
                                    icon: const Icon(Icons.archive_outlined),
                                    label: Text(
                                      'Xem ${partitioned.archive.length} mã ngày trước trong Lưu trữ',
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        )
                      : _activeTab == _BarcodeSectionTab.archive
                          ? ListView.builder(
                              padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                              itemCount: visibleArchiveGroups.length,
                              itemBuilder: (context, index) =>
                                  _buildArchiveDateSection(
                                visibleArchiveGroups[index],
                              ),
                            )
                          : ListView.builder(
                              padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                              itemCount: filteredVisible.length,
                              itemBuilder: (context, index) =>
                                  _buildBarcodeCard(filteredVisible[index]),
                            ),
                ),
              ],
            ),
    );
  }

  Widget _buildDayTabButton({
    required String label,
    required IconData icon,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Material(
      color: selected ? Colors.purple.shade700 : Colors.grey.shade100,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 6),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 14,
                color: selected ? Colors.white : Colors.grey.shade700,
              ),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    color: selected ? Colors.white : Colors.grey.shade800,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
