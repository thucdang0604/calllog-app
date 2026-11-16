import 'package:flutter/material.dart';
import '../models/app_settings.dart';
import '../services/app_settings_service.dart';
import '../services/floating_window_service.dart';
import 'tab_guide_banner.dart';

/// Tab "Cài đặt": cấu hình tập trung toàn bộ Độ mờ bong bóng/popup, Âm thanh, Rung và Cảnh báo.
class AppSettingsTab extends StatefulWidget {
  const AppSettingsTab({super.key});

  @override
  State<AppSettingsTab> createState() => _AppSettingsTabState();
}

class _AppSettingsTabState extends State<AppSettingsTab> {
  double? _draggingVolume;
  int _bubbleOpacity = 80;
  int _panelOpacity = 95;
  double? _draggingBubbleOpacity;
  double? _draggingPanelOpacity;

  @override
  void initState() {
    super.initState();
    AppSettingsService.load();
    _loadFloatingOpacity();
  }

  Future<void> _loadFloatingOpacity() async {
    final opacity = await FloatingWindowService.getFloatingOpacity();
    if (!mounted) return;
    setState(() {
      _bubbleOpacity = opacity['bubbleOpacity'] ?? 80;
      _panelOpacity = opacity['panelOpacity'] ?? 95;
    });
  }

  Future<void> _confirmReset(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Khôi phục cài đặt mặc định?'),
        content: const Text(
          'Toàn bộ tùy chọn độ mờ bong bóng/popup, âm thanh, rung và cảnh báo sẽ được đưa về mặc định ban đầu.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Hủy'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Khôi phục'),
          ),
        ],
      ),
    );
    if (ok == true) {
      setState(() {
        _draggingVolume = null;
        _draggingBubbleOpacity = null;
        _draggingPanelOpacity = null;
        _bubbleOpacity = 80;
        _panelOpacity = 95;
      });
      await AppSettingsService.resetDefaults();
      await FloatingWindowService.setFloatingOpacity(
        bubbleOpacity: 80,
        panelOpacity: 95,
      );
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Đã khôi phục cài đặt mặc định'),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AppSettings>(
      valueListenable: AppSettingsService.notifier,
      builder: (context, settings, _) {
        final effectiveVolume =
            (_draggingVolume ?? settings.barcodeSoundVolume.toDouble()).clamp(0.0, 100.0);
        final effectiveBubbleOpacity =
            (_draggingBubbleOpacity ?? _bubbleOpacity.toDouble()).clamp(20.0, 100.0);
        final effectivePanelOpacity =
            (_draggingPanelOpacity ?? _panelOpacity.toDouble()).clamp(50.0, 100.0);
        final barcodeAudioActive = settings.soundMasterEnabled && settings.barcodeSoundEnabled;

        return ListView(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 24),
          children: [
            const TabGuideBanner(
              title: 'Hướng dẫn cài đặt & sử dụng Cài đặt',
              accentColor: Colors.blueGrey,
              margin: EdgeInsets.only(bottom: 10),
              sections: [
                TabGuideSection(
                  heading: 'Cài đặt giao diện nổi',
                  steps: [
                    'Kéo thanh Độ mờ Bong bóng trôi nổi (gợi ý 60%–80%) để không che bản đồ khi chạy xe.',
                    'Kéo thanh Độ mờ Popup thao tác nhanh (gợi ý 80%–95%) để vừa nhìn xuyên app giao hàng vừa đọc rõ SĐT.',
                  ],
                ),
                TabGuideSection(
                  heading: 'Cách tùy chỉnh Âm thanh, Rung & Cảnh báo',
                  steps: [
                    'Dùng 2 công tắc tổng Âm thanh và Rung để bật/tắt nhanh toàn bộ phản hồi (vẫn nghe lại file ghi âm bình thường).',
                    'Bấm biểu tượng phát cạnh từng trạng thái quét mã để nghe thử ngay mức âm lượng hiện tại.',
                    'Có thể tắt từng banner/hộp thoại nhắc nếu đã quen thao tác; bấm nút "Mặc định" để khôi phục tất cả thông số.',
                  ],
                ),
              ],
            ),
            _buildSummaryBanner(context, settings),
            const SizedBox(height: 12),

            // 1. Độ mờ bong bóng & popup
            _SettingsSectionCard(
              icon: Icons.opacity,
              accentColor: Colors.teal,
              title: 'Bong bóng & Popup',
              subtitle: 'Chỉnh độ trong suốt cửa sổ nổi áp dụng tức thì',
              children: [
                _buildOpacitySlider(
                  preview: Opacity(
                    opacity: effectiveBubbleOpacity / 100.0,
                    child: Container(
                      width: 24,
                      height: 24,
                      decoration: const BoxDecoration(
                        color: Colors.blue,
                        shape: BoxShape.circle,
                      ),
                      alignment: Alignment.center,
                      child: const Text(
                        'LOG',
                        style: TextStyle(
                          fontSize: 8,
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                  title: 'Độ mờ bong bóng trôi nổi',
                  helper: 'Mẹo: Chỉnh 60% - 80% để icon mờ nhẹ, không che bản đồ và app giao hàng.',
                  value: effectiveBubbleOpacity,
                  min: 20,
                  max: 100,
                  divisions: 16,
                  onChanged: (val) {
                    final nextInt = val.round();
                    setState(() => _draggingBubbleOpacity = val);
                    if (nextInt != _bubbleOpacity) {
                      _bubbleOpacity = nextInt;
                      FloatingWindowService.setFloatingOpacity(bubbleOpacity: nextInt);
                    }
                  },
                  onChangeEnd: (val) {
                    final nextInt = val.round();
                    setState(() {
                      _draggingBubbleOpacity = null;
                      _bubbleOpacity = nextInt;
                    });
                    FloatingWindowService.setFloatingOpacity(bubbleOpacity: nextInt);
                  },
                ),
                const Divider(height: 1),
                _buildOpacitySlider(
                  preview: Opacity(
                    opacity: effectivePanelOpacity / 100.0,
                    child: Container(
                      width: 24,
                      height: 18,
                      decoration: BoxDecoration(
                        color: const Color(0xFF2C3E50),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      alignment: Alignment.center,
                      child: const Icon(
                        Icons.view_agenda,
                        size: 12,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  title: 'Độ mờ popup thao tác nhanh',
                  helper: 'Mẹo: Chỉnh 80% - 95% để vừa nhìn xuyên nền vừa đọc rõ số điện thoại.',
                  value: effectivePanelOpacity,
                  min: 50,
                  max: 100,
                  divisions: 10,
                  onChanged: (val) {
                    final nextInt = val.round();
                    setState(() => _draggingPanelOpacity = val);
                    if (nextInt != _panelOpacity) {
                      _panelOpacity = nextInt;
                      FloatingWindowService.setFloatingOpacity(panelOpacity: nextInt);
                    }
                  },
                  onChangeEnd: (val) {
                    final nextInt = val.round();
                    setState(() {
                      _draggingPanelOpacity = null;
                      _panelOpacity = nextInt;
                    });
                    FloatingWindowService.setFloatingOpacity(panelOpacity: nextInt);
                  },
                ),
              ],
            ),
            const SizedBox(height: 12),

            // 2. Âm thanh
            _SettingsSectionCard(
              icon: Icons.volume_up_rounded,
              accentColor: Colors.blue,
              title: 'Âm thanh',
              subtitle: 'Âm báo khi quét mã và tiếng chụp ảnh nhanh',
              children: [
                _buildSwitchTile(
                  title: 'Âm thanh phản hồi chung',
                  subtitle:
                      'Bật hoặc tắt nhanh toàn bộ âm báo quét mã và chụp TimeMark (không ảnh hưởng phát ghi âm cuộc gọi)',
                  value: settings.soundMasterEnabled,
                  onChanged: (v) => AppSettingsService.update(
                    settings.copyWith(soundMasterEnabled: v),
                  ),
                ),
                const Divider(height: 1),
                _buildSwitchTile(
                  title: 'Âm thanh khi quét mã',
                  subtitle: 'Phát âm thanh phân biệt từng trạng thái ngay trên camera',
                  value: settings.barcodeSoundEnabled,
                  enabled: settings.soundMasterEnabled,
                  onChanged: (v) => AppSettingsService.update(
                    settings.copyWith(barcodeSoundEnabled: v),
                  ),
                ),
                Opacity(
                  opacity: barcodeAudioActive ? 1.0 : 0.45,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              'Âm lượng quét mã',
                              style: TextStyle(
                                fontSize: 13.5,
                                fontWeight: FontWeight.w600,
                                color: Colors.grey[800],
                              ),
                            ),
                            Text(
                              '${effectiveVolume.round()}%',
                              style: TextStyle(
                                fontSize: 13.5,
                                fontWeight: FontWeight.bold,
                                color: Colors.blue[700],
                              ),
                            ),
                          ],
                        ),
                        Slider(
                          value: effectiveVolume,
                          min: 0,
                          max: 100,
                          divisions: 20,
                          label: '${effectiveVolume.round()}%',
                          onChanged: barcodeAudioActive
                              ? (val) => setState(() => _draggingVolume = val)
                              : null,
                          onChangeEnd: barcodeAudioActive
                              ? (val) {
                                  final rounded = val.round();
                                  setState(() => _draggingVolume = null);
                                  AppSettingsService.update(
                                    settings.copyWith(barcodeSoundVolume: rounded),
                                  );
                                }
                              : null,
                        ),
                      ],
                    ),
                  ),
                ),
                _buildToneToggleTile(
                  title: 'Âm báo mã mới (ti-TING!)',
                  subtitle: 'Hai nốt cao khi quét thành công mã mới trong ngày',
                  value: settings.barcodeSoundNewEnabled,
                  enabled: barcodeAudioActive,
                  outcome: BarcodeScanToneOutcome.newCode,
                  volume: effectiveVolume.round(),
                  onChanged: (v) => AppSettingsService.update(
                    settings.copyWith(barcodeSoundNewEnabled: v),
                  ),
                ),
                _buildToneToggleTile(
                  title: 'Âm báo trùng Hôm nay (BIP-BIP)',
                  subtitle: 'Hai tiếng đều khi mã đã nằm trong danh sách Hôm nay',
                  value: settings.barcodeSoundPendingEnabled,
                  enabled: barcodeAudioActive,
                  outcome: BarcodeScanToneOutcome.duplicatePending,
                  volume: effectiveVolume.round(),
                  onChanged: (v) => AppSettingsService.update(
                    settings.copyWith(barcodeSoundPendingEnabled: v),
                  ),
                ),
                _buildToneToggleTile(
                  title: 'Âm báo trùng phiên đang quét',
                  subtitle: 'Tiếng bíp ngắn khi lia trúng mã vừa quét ở cùng phiên',
                  value: settings.barcodeSoundSessionEnabled,
                  enabled: barcodeAudioActive,
                  outcome: BarcodeScanToneOutcome.duplicateSession,
                  volume: effectiveVolume.round(),
                  onChanged: (v) => AppSettingsService.update(
                    settings.copyWith(barcodeSoundSessionEnabled: v),
                  ),
                ),
                _buildToneToggleTile(
                  title: 'Âm báo trùng mục Đã chia sẻ',
                  subtitle: 'Nhịp cảnh báo hạ giọng khi mã đã từng chia sẻ/copy hôm nay',
                  value: settings.barcodeSoundSharedEnabled,
                  enabled: barcodeAudioActive,
                  outcome: BarcodeScanToneOutcome.duplicateShared,
                  volume: effectiveVolume.round(),
                  onChanged: (v) => AppSettingsService.update(
                    settings.copyWith(barcodeSoundSharedEnabled: v),
                  ),
                ),
                const Divider(height: 1),
                _buildSwitchTile(
                  title: 'Tiếng chụp ảnh TimeMark',
                  subtitle: 'Phát tiếng màn trập khi bấm chụp trên camera TimeMark nhanh',
                  value: settings.timeMarkShutterSoundEnabled,
                  enabled: settings.soundMasterEnabled,
                  onChanged: (v) => AppSettingsService.update(
                    settings.copyWith(timeMarkShutterSoundEnabled: v),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // 2. Rung chung
            _SettingsSectionCard(
              icon: Icons.vibration,
              accentColor: Colors.deepPurple,
              title: 'Rung phản hồi',
              subtitle: 'Quản lý chế độ rung chung và từng công cụ',
              children: [
                _buildSwitchTile(
                  title: 'Rung chung toàn ứng dụng',
                  subtitle: 'Công tắc tổng cho mọi phản hồi rung trên máy',
                  value: settings.vibrationMasterEnabled,
                  onChanged: (v) => AppSettingsService.update(
                    settings.copyWith(vibrationMasterEnabled: v),
                  ),
                ),
                const Divider(height: 1),
                _buildSwitchTile(
                  title: 'Rung khi quét mã vạch',
                  subtitle: 'Rung ngắn với mã mới, rung nhiều nhịp khi cảnh báo mã trùng',
                  value: settings.barcodeVibrationEnabled,
                  enabled: settings.vibrationMasterEnabled,
                  onChanged: (v) => AppSettingsService.update(
                    settings.copyWith(barcodeVibrationEnabled: v),
                  ),
                ),
                _buildSwitchTile(
                  title: 'Rung khi chụp ảnh TimeMark',
                  subtitle: 'Rung nhẹ xác nhận đã chụp mỗi tấm ảnh',
                  value: settings.timeMarkVibrationEnabled,
                  enabled: settings.vibrationMasterEnabled,
                  onChanged: (v) => AppSettingsService.update(
                    settings.copyWith(timeMarkVibrationEnabled: v),
                  ),
                ),
                _buildSwitchTile(
                  title: 'Rung nút trên bong bóng nổi',
                  subtitle: 'Rung phản hồi khi cập nhật thời lượng cuộc gọi hoặc mở gửi nhanh',
                  value: settings.overlayVibrationEnabled,
                  enabled: settings.vibrationMasterEnabled,
                  onChanged: (v) => AppSettingsService.update(
                    settings.copyWith(overlayVibrationEnabled: v),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // 3. Các cảnh báo & nhắc nhở
            _SettingsSectionCard(
              icon: Icons.warning_amber_rounded,
              accentColor: Colors.orange,
              title: 'Cảnh báo & Nhắc nhở',
              subtitle: 'Kiểm soát bảng cảnh báo trùng mã, mic và quyền hệ thống',
              children: [
                _buildSwitchTile(
                  title: 'Cảnh báo mã trùng trên camera quét',
                  subtitle:
                      'Hiện nhãn màu vàng/cam và bộ đếm mã trùng ngay trong khung quét mã',
                  value: settings.barcodeCameraDupWarningEnabled,
                  onChanged: (v) => AppSettingsService.update(
                    settings.copyWith(barcodeCameraDupWarningEnabled: v),
                  ),
                ),
                _buildSwitchTile(
                  title: 'Hộp thoại xử lý trùng sau phiên quét',
                  subtitle:
                      'Hỏi giữ toàn bộ hoặc bỏ qua mã trùng khi kết thúc quét. Khi tắt sẽ tự động bỏ qua mã cũ đã có trong ngày',
                  value: settings.barcodePostScanDupDialogEnabled,
                  onChanged: (v) => AppSettingsService.update(
                    settings.copyWith(barcodePostScanDupDialogEnabled: v),
                  ),
                ),
                const Divider(height: 1),
                _buildSwitchTile(
                  title: 'Cảnh báo giữ quyền SMS mặc định',
                  subtitle:
                      'Hiện thanh nhắc ở đầu app khi Delivery Support đang được đặt làm app SMS mặc định',
                  value: settings.defaultSmsWarningEnabled,
                  onChanged: (v) => AppSettingsService.update(
                    settings.copyWith(defaultSmsWarningEnabled: v),
                  ),
                ),
                _buildSwitchTile(
                  title: 'Nhắc cấp quyền Ghi âm cuộc gọi',
                  subtitle:
                      'Hiện thẻ hướng dẫn trên tab Giao hàng nếu thiếu quyền Micro, Điện thoại hoặc Cửa sổ nổi',
                  value: settings.callRecordingSetupWarningEnabled,
                  onChanged: (v) => AppSettingsService.update(
                    settings.copyWith(callRecordingSetupWarningEnabled: v),
                  ),
                ),
                _buildSwitchTile(
                  title: 'Cảnh báo ghi âm không có tiếng (câm)',
                  subtitle:
                      'Hiện cảnh báo màu cam khi hệ thống chặn micro lúc đang gọi và trên danh sách file ghi âm',
                  value: settings.callRecordingSilenceWarningEnabled,
                  onChanged: (v) => AppSettingsService.update(
                    settings.copyWith(callRecordingSilenceWarningEnabled: v),
                  ),
                ),
                const Divider(height: 1),
                _buildSwitchTile(
                  title: 'Tự động kiểm tra cập nhật mới',
                  subtitle: 'Tự kiểm tra phiên bản mới từ GitHub khi mở ứng dụng',
                  value: settings.autoCheckUpdateEnabled,
                  onChanged: (v) => AppSettingsService.update(
                    settings.copyWith(autoCheckUpdateEnabled: v),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: const [
                Icon(Icons.verified, size: 14, color: Colors.blue),
                SizedBox(width: 6),
                Text(
                  'Delivery Support • Thiết kế bởi Thức Đặng',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Colors.blueGrey,
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  Widget _buildOpacitySlider({
    required Widget preview,
    required String title,
    required String helper,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required ValueChanged<double> onChanged,
    required ValueChanged<double> onChangeEnd,
  }) {
    final pct = value.round();
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              preview,
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.blue.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '$pct%',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: Colors.blue,
                  ),
                ),
              ),
            ],
          ),
          Slider(
            value: value,
            min: min,
            max: max,
            divisions: divisions,
            label: '$pct%',
            activeColor: Colors.blue[700],
            onChanged: onChanged,
            onChangeEnd: onChangeEnd,
          ),
          Text(
            helper,
            style: TextStyle(fontSize: 11.5, color: Colors.grey[600]),
          ),
        ],
      ),
    );
  }

  Widget _buildSummaryBanner(BuildContext context, AppSettings settings) {
    final activeSounds = [
      settings.barcodeSoundNewEnabled,
      settings.barcodeSoundPendingEnabled,
      settings.barcodeSoundSessionEnabled,
      settings.barcodeSoundSharedEnabled,
    ].where((e) => e).length;
    final soundLabel = !settings.soundMasterEnabled
        ? 'Âm thanh: Đang tắt'
        : 'Âm thanh: Bật (${settings.barcodeSoundEnabled ? "$activeSounds/4 âm quét" : "Tắt quét mã"})';
    final vibLabel = settings.vibrationMasterEnabled ? 'Rung: Bật' : 'Rung: Đang tắt';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.blueGrey.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.blueGrey.shade200),
      ),
      child: Row(
        children: [
          Icon(Icons.tune_rounded, color: Colors.blueGrey.shade700, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Cài đặt ứng dụng',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 14.5,
                    color: Colors.blueGrey.shade900,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '$soundLabel • $vibLabel',
                  style: TextStyle(fontSize: 12, color: Colors.blueGrey.shade700),
                ),
              ],
            ),
          ),
          TextButton.icon(
            onPressed: () => _confirmReset(context),
            icon: const Icon(Icons.restart_alt, size: 18),
            label: const Text('Mặc định'),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              visualDensity: VisualDensity.compact,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSwitchTile({
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
    bool enabled = true,
  }) {
    return Opacity(
      opacity: enabled ? 1.0 : 0.45,
      child: SwitchListTile.adaptive(
        dense: false,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
        title: Text(
          title,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          subtitle,
          style: TextStyle(fontSize: 12, color: Colors.grey[600]),
        ),
        value: enabled ? value : false,
        onChanged: enabled ? onChanged : null,
      ),
    );
  }

  Widget _buildToneToggleTile({
    required String title,
    required String subtitle,
    required bool value,
    required bool enabled,
    required String outcome,
    required int volume,
    required ValueChanged<bool> onChanged,
  }) {
    return Opacity(
      opacity: enabled ? 1.0 : 0.45,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(fontSize: 11.5, color: Colors.grey[600]),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Nghe thử âm này',
              onPressed: () => AppSettingsService.previewScanTone(
                outcome,
                volume: volume > 0 ? volume : 90,
              ),
              icon: Icon(
                Icons.play_circle_outline_rounded,
                color: Colors.blue[700],
              ),
            ),
            Switch.adaptive(
              value: enabled ? value : false,
              onChanged: enabled ? onChanged : null,
            ),
          ],
        ),
      ),
    );
  }
}

class _SettingsSectionCard extends StatelessWidget {
  const _SettingsSectionCard({
    required this.icon,
    required this.accentColor,
    required this.title,
    required this.subtitle,
    required this.children,
  });

  final IconData icon;
  final Color accentColor;
  final String title;
  final String subtitle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 1.5,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: accentColor.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: accentColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(icon, color: accentColor, size: 22),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          fontSize: 15.5,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        subtitle,
                        style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          ...children,
          const SizedBox(height: 4),
        ],
      ),
    );
  }
}
