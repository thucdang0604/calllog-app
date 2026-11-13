import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/scanned_barcode_item.dart';
import '../services/barcode_scanner_service.dart';

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

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    final list = await BarcodeScannerService.loadHistory();
    if (mounted) {
      setState(() {
        _items = list;
        _isLoading = false;
      });
    }
  }

  Future<void> _startScanning() async {
    final newItems = await BarcodeScannerService.openScanner();
    await _loadData();
    if (mounted && newItems.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('✅ Đã quét thành công ${newItems.length} mã mới!'),
          backgroundColor: Colors.green[700],
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _copyAll() async {
    final targetItems = _filteredItems;
    if (targetItems.isEmpty) return;

    await BarcodeScannerService.copyList(targetItems, withIndex: false);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('📋 Đã sao chép ${targetItems.length} mã vào bộ nhớ tạm!'),
          backgroundColor: Colors.blue[700],
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _shareAll() async {
    final targetItems = _filteredItems;
    if (targetItems.isEmpty) return;

    final success = await BarcodeScannerService.shareList(targetItems);
    if (!success && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Không mở được ứng dụng chia sẻ.'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _deleteItem(ScannedBarcodeItem item) async {
    setState(() {
      _items.removeWhere((e) => e.id == item.id);
    });
    await BarcodeScannerService.deleteImageFile(item.imagePath);
    await BarcodeScannerService.saveHistory(_items);
  }

  Future<void> _confirmClearAll() async {
    if (_items.isEmpty) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Xác nhận xóa tất cả?'),
        content: Text('Bạn có chắc muốn xóa toàn bộ ${_items.length} mã đã quét không?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Hủy'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
            child: const Text('Xóa tất cả'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      final itemsToDelete = List<ScannedBarcodeItem>.from(_items);
      setState(() {
        _items.clear();
      });
      await BarcodeScannerService.deleteAllImages(itemsToDelete);
      await BarcodeScannerService.saveHistory(_items);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Đã xóa sạch danh sách mã đã quét.'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    }
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
              onPressed: () {
                final text = codeController.text.trim();
                if (text.isEmpty) return;

                final newItem = ScannedBarcodeItem(
                  id: '${text}_${DateTime.now().millisecondsSinceEpoch}',
                  code: text,
                  format: format,
                  timestamp: DateTime.now().millisecondsSinceEpoch,
                );

                setState(() {
                  _items.insert(0, newItem);
                });
                BarcodeScannerService.saveHistory(_items);
                Navigator.of(ctx).pop();
              },
              child: const Text('Thêm mã'),
            ),
          ],
        ),
      ),
    );
  }

  List<ScannedBarcodeItem> get _filteredItems {
    var list = _items;
    if (_selectedFilter == 'qr') {
      list = list.where((e) => e.isQrCode).toList();
    } else if (_selectedFilter == 'barcode') {
      list = list.where((e) => !e.isQrCode).toList();
    }

    if (_searchQuery.trim().isNotEmpty) {
      final q = _searchQuery.trim().toLowerCase();
      list = list.where((e) => e.code.toLowerCase().contains(q)).toList();
    }
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filteredItems;
    final totalCount = _items.length;
    final qrCount = _items.where((e) => e.isQrCode).length;
    final barcodeCount = totalCount - qrCount;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Quét Mã Vạch & QR Code', style: TextStyle(fontWeight: FontWeight.bold)),
        actions: [
          if (_items.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep_outlined),
              tooltip: 'Xóa toàn bộ danh sách',
              onPressed: _confirmClearAll,
            ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                // Top Action Dashboard Card
                Container(
                  margin: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                  padding: const EdgeInsets.all(14),
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
                    border: Border.all(color: Colors.purple.withValues(alpha: 0.2)),
                  ),
                  child: Column(
                    children: [
                      // Large Camera Button
                      SizedBox(
                        width: double.infinity,
                        height: 48,
                        child: ElevatedButton.icon(
                          onPressed: _startScanning,
                          icon: const Icon(Icons.qr_code_scanner, size: 22),
                          label: const Text(
                            'BẮT ĐẦU QUÉT MÃ',
                            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
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
                      const SizedBox(height: 10),
                      // Action Row (Copy, Share, Manual Add)
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: filtered.isNotEmpty ? _copyAll : null,
                              icon: const Icon(Icons.copy_rounded, size: 16),
                              label: const Text('Copy tất cả', style: TextStyle(fontSize: 12)),
                              style: OutlinedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(vertical: 8),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(8),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: filtered.isNotEmpty ? _shareAll : null,
                              icon: const Icon(Icons.share_rounded, size: 16),
                              label: const Text('Chia sẻ', style: TextStyle(fontSize: 12)),
                              style: OutlinedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(vertical: 8),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(8),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          OutlinedButton.icon(
                            onPressed: _showAddManualCodeDialog,
                            icon: const Icon(Icons.add, size: 16),
                            label: const Text('Thêm tay', style: TextStyle(fontSize: 12)),
                            style: OutlinedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
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

                // Search & Filter Row
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          decoration: InputDecoration(
                            hintText: 'Tìm kiếm mã...',
                            prefixIcon: const Icon(Icons.search, size: 20),
                            isDense: true,
                            contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(10),
                              borderSide: BorderSide(color: Colors.grey.shade300),
                            ),
                            suffixIcon: _searchQuery.isNotEmpty
                                ? IconButton(
                                    icon: const Icon(Icons.clear, size: 18),
                                    onPressed: () => setState(() => _searchQuery = ''),
                                  )
                                : null,
                          ),
                          onChanged: (val) => setState(() => _searchQuery = val),
                        ),
                      ),
                    ],
                  ),
                ),

                // Filter Tabs (All, QR, Barcode)
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                  child: Row(
                    children: [
                      ChoiceChip(
                        label: Text('Tất cả ($totalCount)'),
                        selected: _selectedFilter == 'all',
                        onSelected: (sel) => setState(() => _selectedFilter = 'all'),
                      ),
                      const SizedBox(width: 6),
                      ChoiceChip(
                        label: Text('QR Code ($qrCount)'),
                        selected: _selectedFilter == 'qr',
                        onSelected: (sel) => setState(() => _selectedFilter = 'qr'),
                      ),
                      const SizedBox(width: 6),
                      ChoiceChip(
                        label: Text('Mã vạch ($barcodeCount)'),
                        selected: _selectedFilter == 'barcode',
                        onSelected: (sel) => setState(() => _selectedFilter = 'barcode'),
                      ),
                    ],
                  ),
                ),

                // Scanned Codes List
                Expanded(
                  child: filtered.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.qr_code_scanner_rounded,
                                size: 64,
                                color: Colors.grey.shade400,
                              ),
                              const SizedBox(height: 12),
                              Text(
                                _items.isEmpty
                                    ? 'Chưa có mã nào được quét.'
                                    : 'Không tìm thấy mã phù hợp.',
                                style: TextStyle(
                                  color: Colors.grey.shade600,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                'Bấm "BẮT ĐẦU QUÉT MÃ" để quét nhanh bằng camera',
                                style: TextStyle(
                                  color: Colors.grey.shade500,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                          itemCount: filtered.length,
                          itemBuilder: (context, index) {
                            final item = filtered[index];
                            final isQr = item.isQrCode;

                            return Card(
                              margin: const EdgeInsets.only(bottom: 8),
                              elevation: 1,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10),
                                side: BorderSide(
                                  color: isQr
                                      ? Colors.purple.withValues(alpha: 0.25)
                                      : Colors.blue.withValues(alpha: 0.25),
                                ),
                              ),
                              child: ListTile(
                                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                                leading: _buildLeadingThumbnail(item, isQr),
                                title: SelectableText(
                                  item.code,
                                  style: const TextStyle(
                                    fontFamily: 'monospace',
                                    fontWeight: FontWeight.bold,
                                    fontSize: 14.5,
                                  ),
                                ),
                                subtitle: Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  child: Row(
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
                                      const SizedBox(width: 8),
                                      Text(
                                        item.formattedDateTime,
                                        style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                                      ),
                                    ],
                                  ),
                                ),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
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
                          },
                        ),
                ),
              ],
            ),
    );
  }
}

