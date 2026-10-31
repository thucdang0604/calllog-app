import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class PaymentAccountSettingsScreen extends StatefulWidget {
  const PaymentAccountSettingsScreen({super.key});

  @override
  State<PaymentAccountSettingsScreen> createState() =>
      _PaymentAccountSettingsScreenState();
}

class _PaymentAccountSettingsScreenState
    extends State<PaymentAccountSettingsScreen> {
  static const MethodChannel _channel = MethodChannel('call_log_manager');
  final _accountNumberController = TextEditingController();
  final _accountNameController = TextEditingController();

  List<_BankOption> _banks = [];
  _BankOption? _selectedBank;
  bool _loading = true;
  bool _saving = false;
  bool _verified = false;
  bool _previewLoaded = false;
  String? _loadError;

  String get _qrUrl {
    final bank = _selectedBank;
    final account = _accountNumberController.text.trim();
    final name = _accountNameController.text.trim();
    if (bank == null || account.isEmpty || name.isEmpty) return '';
    final bankId = Uri.encodeComponent(bank.bin);
    final encodedAccount = Uri.encodeComponent(account);
    final accountName = Uri.encodeQueryComponent(name);
    // Deliberately omit amount and transfer memo so this remains a static QR.
    return 'https://img.vietqr.io/image/$bankId-$encodedAccount-qr_only.png'
        '?accountName=$accountName';
  }

  @override
  void initState() {
    super.initState();
    _loadBanksAndAccount();
  }

  @override
  void dispose() {
    _accountNumberController.dispose();
    _accountNameController.dispose();
    super.dispose();
  }

  void _invalidateVerification() {
    if (!mounted) return;
    setState(() {
      _verified = false;
      _previewLoaded = false;
    });
  }

  Future<void> _loadBanksAndAccount() async {
    HttpClient? client;
    try {
      client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
      final request = await client
          .getUrl(Uri.https('api.vietqr.io', '/v2/banks'))
          .timeout(const Duration(seconds: 12));
      final response = await request.close().timeout(
        const Duration(seconds: 12),
      );
      final body = await response.transform(utf8.decoder).join();
      client.close(force: true);
      client = null;
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException('Máy chủ danh sách ngân hàng trả lỗi.');
      }
      final decoded = jsonDecode(body);
      final rawBanks = decoded is Map<String, dynamic> ? decoded['data'] : null;
      final banks = rawBanks is List
          ? rawBanks
                .whereType<Map>()
                .map((item) => _BankOption.fromMap(item))
                .where((bank) => bank.bin.isNotEmpty && bank.name.isNotEmpty)
                .toList()
          : <_BankOption>[];
      if (banks.isEmpty) throw const FormatException('Danh sách ngân hàng trống.');

      final saved = await _channel.invokeMapMethod<dynamic, dynamic>(
        'getPaymentAccountSettings',
      );
      if (!mounted) return;
      final savedBin = saved?['bankBin']?.toString() ?? '';
      setState(() {
        _banks = banks;
        _selectedBank = _findBankByBin(banks, savedBin);
        _accountNumberController.text =
            saved?['accountNumber']?.toString() ?? '';
        _accountNameController.text = saved?['accountName']?.toString() ?? '';
        _verified = saved?['verified'] == true;
        _loading = false;
        _loadError = null;
      });
    } catch (error) {
      client?.close(force: true);
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = 'Không tải được ngân hàng: $error';
      });
    }
  }

  Future<void> _chooseBank() async {
    if (_banks.isEmpty) return;
    final selected = await showModalBottomSheet<_BankOption>(
      context: context,
      isScrollControlled: true,
      builder: (context) => _BankPicker(banks: _banks),
    );
    if (selected == null || !mounted) return;
    setState(() {
      _selectedBank = selected;
      _verified = false;
      _previewLoaded = false;
    });
  }

  Future<void> _save() async {
    final bank = _selectedBank;
    final accountNumber = _accountNumberController.text.trim();
    final accountName = _accountNameController.text.trim();
    if (bank == null || accountNumber.length < 6 || accountName.isEmpty) {
      _showMessage('Hãy nhập ngân hàng, số tài khoản và tên chủ tài khoản.');
      return;
    }
    if (!_verified) {
      _showMessage('Hãy quét thử QR và xác nhận đúng tài khoản trước khi lưu.');
      return;
    }

    setState(() => _saving = true);
    try {
      await _channel.invokeMethod<bool>('savePaymentAccountSettings', {
        'bankName': bank.name,
        'bankBin': bank.bin,
        'bankId': bank.bin,
        'accountNumber': accountNumber,
        'accountName': accountName,
        'verified': true,
      });
      if (!mounted) return;
      _showMessage('Đã lưu tài khoản nhận tiền cho QR Zalo.');
      Navigator.of(context).pop(true);
    } catch (error) {
      _showMessage('Không lưu được tài khoản: $error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  _BankOption? _findBankByBin(List<_BankOption> banks, String bin) {
    for (final bank in banks) {
      if (bank.bin == bin) return bank;
    }
    return null;
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final qrUrl = _qrUrl;
    return Scaffold(
      appBar: AppBar(title: const Text('Tài khoản nhận chuyển khoản')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _loadError != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_loadError!, textAlign: TextAlign.center),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: () {
                        setState(() {
                          _loading = true;
                          _loadError = null;
                        });
                        _loadBanksAndAccount();
                      },
                      icon: const Icon(Icons.refresh),
                      label: const Text('Tải lại'),
                    ),
                  ],
                ),
              ),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
              children: [
                const Text(
                  'QR dùng khi chia sẻ qua Zalo. Mã chỉ có ngân hàng và số tài khoản; khách tự nhập số tiền trong ứng dụng ngân hàng.',
                ),
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  onPressed: _chooseBank,
                  icon: const Icon(Icons.account_balance_outlined),
                  label: Text(
                    _selectedBank == null
                        ? 'Chọn ngân hàng'
                        : '${_selectedBank!.shortName} · ${_selectedBank!.name}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _accountNumberController,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  onChanged: (_) => _invalidateVerification(),
                  decoration: const InputDecoration(
                    labelText: 'Số tài khoản',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _accountNameController,
                  textCapitalization: TextCapitalization.characters,
                  onChanged: (_) => _invalidateVerification(),
                  decoration: const InputDecoration(
                    labelText: 'Tên chủ tài khoản',
                    hintText: 'Ví dụ: NGUYEN VAN A',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 18),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: [
                        const Text(
                          'Xem trước QR tĩnh',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 8),
                        SizedBox(
                          width: 240,
                          height: 240,
                          child: qrUrl.isEmpty
                              ? const Center(
                                  child: Text('Nhập đủ thông tin để tạo QR xem trước.'),
                                )
                              : Image.network(
                                  qrUrl,
                                  key: ValueKey(qrUrl),
                                  fit: BoxFit.contain,
                                  frameBuilder:
                                      (context, child, frame, synchronous) {
                                        if (frame != null && !_previewLoaded) {
                                          WidgetsBinding.instance
                                              .addPostFrameCallback((_) {
                                                if (mounted && !_previewLoaded) {
                                                  setState(() =>
                                                      _previewLoaded = true);
                                                }
                                              });
                                        }
                                        return frame == null
                                            ? const Center(
                                                child:
                                                    CircularProgressIndicator(),
                                              )
                                            : child;
                                      },
                                  errorBuilder: (_, __, ___) => const Center(
                                    child: Text('Không tải được ảnh QR.'),
                                  ),
                                ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '${_selectedBank?.name ?? 'Chưa chọn ngân hàng'}\n'
                          '${_accountNameController.text.trim()} · ${_accountNumberController.text.trim()}',
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Số tiền: không có sẵn',
                          style: TextStyle(color: Colors.green.shade800),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Ứng dụng không tra cứu chủ tài khoản tự động. Hãy mở ứng dụng ngân hàng, quét QR và kiểm tra tên người nhận cùng số tài khoản trước khi xác nhận.',
                ),
                CheckboxListTile(
                  value: _verified,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  onChanged: qrUrl.isEmpty || !_previewLoaded
                      ? null
                      : (value) => setState(() => _verified = value ?? false),
                  title: const Text('Tôi đã quét thử và xác nhận đúng tài khoản của mình.'),
                ),
                FilledButton.icon(
                  onPressed: _saving ? null : _save,
                  icon: _saving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.save_outlined),
                  label: Text(_saving ? 'Đang lưu...' : 'Lưu tài khoản'),
                ),
              ],
            ),
    );
  }
}

class _BankOption {
  const _BankOption({
    required this.name,
    required this.shortName,
    required this.bin,
  });

  final String name;
  final String shortName;
  final String bin;

  factory _BankOption.fromMap(Map<dynamic, dynamic> map) => _BankOption(
    name: map['name']?.toString() ?? '',
    shortName: map['shortName']?.toString() ?? map['code']?.toString() ?? '',
    bin: map['bin']?.toString() ?? '',
  );
}

class _BankPicker extends StatefulWidget {
  const _BankPicker({required this.banks});

  final List<_BankOption> banks;

  @override
  State<_BankPicker> createState() => _BankPickerState();
}

class _BankPickerState extends State<_BankPicker> {
  final _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = _query.toLowerCase();
    final filtered = widget.banks.where((bank) {
      return bank.name.toLowerCase().contains(query) ||
          bank.shortName.toLowerCase().contains(query) ||
          bank.bin.contains(query);
    }).toList();
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.8,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: TextField(
                controller: _searchController,
                autofocus: true,
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: 'Tìm tên, mã hoặc BIN ngân hàng',
                  border: OutlineInputBorder(),
                ),
                onChanged: (value) => setState(() => _query = value.trim()),
              ),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: filtered.length,
                itemBuilder: (context, index) {
                  final bank = filtered[index];
                  return ListTile(
                    title: Text(bank.name),
                    subtitle: Text('${bank.shortName} · BIN ${bank.bin}'),
                    onTap: () => Navigator.of(context).pop(bank),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
