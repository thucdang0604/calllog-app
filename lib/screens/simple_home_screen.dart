import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import '../models/app_settings.dart';
import '../models/call_recording_item.dart';
import '../services/app_settings_service.dart';
import '../services/call_recording_service.dart';
import '../services/timemark_service.dart';
import 'call_recordings_screen.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../providers/call_log_provider.dart';
import '../services/app_update_service.dart';
import '../services/license_api_service.dart';
import '../widgets/app_settings_tab.dart';
import '../widgets/floating_window_widget.dart';
import '../widgets/fake_gps_widget.dart';
import '../widgets/tab_guide_banner.dart';
import '../widgets/timemark_camera_widget.dart';
import 'payment_reconciliation_screen.dart';
import 'payment_account_settings_screen.dart';
import 'barcode_scanner_screen.dart';

class SimpleHomeScreen extends StatefulWidget {
  const SimpleHomeScreen({super.key});

  @override
  State<SimpleHomeScreen> createState() => _SimpleHomeScreenState();
}

class _SimpleHomeScreenState extends State<SimpleHomeScreen>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  static const MethodChannel _eventsChannel = MethodChannel(
    'call_log_manager_events',
  );
  final AppUpdateService _appUpdateService = AppUpdateService();
  late final TabController _tabController;
  final Set<int> _visitedTabs = <int>{0};
  bool _isCallLogDefaultSmsApp = false;
  StreamSubscription<CallRecordingEvent>? _recordingEventSub;
  List<CallRecordingItem> _recordings = const [];
  final ValueNotifier<CallPlaybackState> _playbackStateNotifier =
      ValueNotifier<CallPlaybackState>(const CallPlaybackState.idle());
  final ValueNotifier<double?> _homeAudioDragMsNotifier = ValueNotifier<double?>(
    null,
  );
  bool _hasCallRecPerms = true;
  bool _hasOverlayPerm = true;
  bool _isRefreshingRecordingState = false;
  DateTime? _lastUpdateCheckAt;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 5, vsync: this)
      ..addListener(_onTabChanged);
    WidgetsBinding.instance.addObserver(this);
    _eventsChannel.setMethodCallHandler(_handleNativeEvent);
    _recordingEventSub = CallRecordingService.events.listen(
      _handleRecordingEvent,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      AppSettingsService.load();
      _refreshDefaultSmsStatus();
      _loadCallLogs(force: false);
      _refreshCallRecordingState();
      _checkForAppUpdate();
    });
  }

  void _onTabChanged() {
    final idx = _tabController.index;
    if (_visitedTabs.contains(idx) || !mounted) return;
    setState(() {
      _visitedTabs.add(idx);
    });
  }

  Future<void> _handleNativeEvent(MethodCall call) async {
    if (call.method == 'captureTimeMark') {
      try {
        await TimeMarkService.openQuickCamera();
      } catch (_) {}
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshDefaultSmsStatus();
      _refreshCallRecordingState();
      _appUpdateService.resumePendingInstallation(context);
      final now = DateTime.now();
      if (_lastUpdateCheckAt == null ||
          now.difference(_lastUpdateCheckAt!) >= const Duration(minutes: 5)) {
        _checkForAppUpdate(delay: false);
      }
    }
  }

  @override
  void dispose() {
    _eventsChannel.setMethodCallHandler(null);
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    _recordingEventSub?.cancel();
    _playbackStateNotifier.dispose();
    _homeAudioDragMsNotifier.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _handleRecordingEvent(CallRecordingEvent event) {
    if (!mounted) return;
    if (event.type == 'recordings_updated') {
      _reloadRecordingsOnly();
    } else if (event.type == 'playback' && event.playbackState != null) {
      _playbackStateNotifier.value = event.playbackState!;
    }
  }

  Future<void> _refreshCallRecordingState() async {
    if (_isRefreshingRecordingState) return;
    _isRefreshingRecordingState = true;
    try {
      final results = await Future.wait<dynamic>([
        CallRecordingService.hasPermissions(),
        CallRecordingService.hasOverlayPermission(),
        CallRecordingService.getRecordings(),
        CallRecordingService.getPlaybackState(),
      ]);
      if (!mounted) return;
      _playbackStateNotifier.value = results[3] as CallPlaybackState;
      setState(() {
        _hasCallRecPerms = results[0] as bool;
        _hasOverlayPerm = results[1] as bool;
        _recordings = results[2] as List<CallRecordingItem>;
      });
    } finally {
      _isRefreshingRecordingState = false;
    }
  }

  Future<void> _reloadRecordingsOnly() async {
    final loaded = await CallRecordingService.getRecordings();
    if (!mounted) return;
    setState(() {
      _recordings = loaded;
    });
  }

  Future<void> _openCallRecordingsScreen() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const CallRecordingsScreen()),
    );
    await _refreshCallRecordingState();
  }

  Future<void> _requestCallRecPermissionsFromHome() async {
    final granted = await CallRecordingService.requestPermissions();
    await _refreshCallRecordingState();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          granted
              ? 'Đã cấp quyền Micro & Điện thoại cho ghi âm cuộc gọi'
              : 'Vui lòng cấp quyền Micro & Điện thoại trong Cài đặt ứng dụng',
        ),
        backgroundColor: granted ? Colors.green[700] : Colors.orange[800],
      ),
    );
  }

  Future<void> _togglePlayRecording(CallRecordingItem recording) async {
    try {
      final current = _playbackStateNotifier.value;
      if (current.isPlayingFile(recording.filePath)) {
        final next = await CallRecordingService.pause();
        if (mounted) _playbackStateNotifier.value = next;
      } else {
        final next = await CallRecordingService.play(recording.filePath);
        if (mounted) _playbackStateNotifier.value = next;
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

  CallRecordingItem? _findRecordingByPath(String filePath) {
    if (filePath.isEmpty) return null;
    for (final rec in _recordings) {
      if (rec.filePath == filePath) {
        return rec;
      }
    }
    return null;
  }

  Widget _buildCallRecordingSetupBanner() {
    if (_hasCallRecPerms && _hasOverlayPerm) {
      return const SizedBox.shrink();
    }
    return ValueListenableBuilder<AppSettings>(
      valueListenable: AppSettingsService.notifier,
      builder: (context, settings, _) {
        if (!settings.callRecordingSetupWarningEnabled) {
          return const SizedBox.shrink();
        }
        return Container(
          margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Colors.amber[50],
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.amber[300]!),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.mic, color: Colors.amber[900], size: 18),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Cấp quyền để hiện nút Ghi âm chủ động trong cuộc gọi',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: Colors.amber[900],
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: _openCallRecordingsScreen,
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: const Text('Chi tiết', style: TextStyle(fontSize: 12)),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  if (!_hasCallRecPerms)
                    ElevatedButton.icon(
                      onPressed: _requestCallRecPermissionsFromHome,
                      icon: const Icon(Icons.mic, size: 15),
                      label: const Text('Cấp Micro, ĐT & Nhật ký'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blue[700],
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        textStyle: const TextStyle(fontSize: 12),
                      ),
                    ),
                  if (!_hasOverlayPerm)
                    ElevatedButton.icon(
                      onPressed: CallRecordingService.openOverlaySettings,
                      icon: const Icon(Icons.layers_outlined, size: 15),
                      label: const Text('Hiện nút Ghi âm trên cuộc gọi'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.orange[800],
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        textStyle: const TextStyle(fontSize: 12),
                      ),
                    ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildHomeInlinePlayer() {
    return ValueListenableBuilder<CallPlaybackState>(
      valueListenable: _playbackStateNotifier,
      builder: (context, playbackState, _) {
        if (!playbackState.isActive) return const SizedBox.shrink();
        final activeRec = _findRecordingByPath(playbackState.filePath);
        final totalMs = playbackState.durationMs > 0
            ? playbackState.durationMs
            : (activeRec?.durationMs ?? 1);
        final safeMax = totalMs > 0 ? totalMs.toDouble() : 1.0;

        return ValueListenableBuilder<double?>(
          valueListenable: _homeAudioDragMsNotifier,
          builder: (context, dragMs, _) {
            final rawPos = dragMs ?? playbackState.positionMs.toDouble();
            final sliderValue = rawPos.clamp(0.0, safeMax);

            return Container(
              margin: const EdgeInsets.fromLTRB(16, 4, 16, 6),
              padding: const EdgeInsets.fromLTRB(12, 8, 6, 4),
              decoration: BoxDecoration(
                color: Colors.blue[900],
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.audiotrack, color: Colors.white, size: 16),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          activeRec != null
                              ? '${activeRec.displayTitle} • ${activeRec.formattedDateTime}'
                              : 'Đang phát ghi âm cuộc gọi',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: playbackState.isPlaying ? 'Tạm dừng' : 'Tiếp tục',
                        visualDensity: VisualDensity.compact,
                        icon: Icon(
                          playbackState.isPlaying
                              ? Icons.pause_circle
                              : Icons.play_circle,
                          color: Colors.white,
                          size: 24,
                        ),
                        onPressed: () async {
                          final next = playbackState.isPlaying
                              ? await CallRecordingService.pause()
                              : await CallRecordingService.resume();
                          if (mounted) _playbackStateNotifier.value = next;
                        },
                      ),
                      if (activeRec != null)
                        IconButton(
                          tooltip: 'Chia sẻ .m4a',
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(
                            Icons.share,
                            color: Colors.white70,
                            size: 18,
                          ),
                          onPressed: () =>
                              CallRecordingService.shareRecording(activeRec),
                        ),
                      IconButton(
                        tooltip: 'Dừng phát',
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.close, color: Colors.white70, size: 20),
                        onPressed: () async {
                          final next = await CallRecordingService.stop();
                          if (mounted) _playbackStateNotifier.value = next;
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
                              enabledThumbRadius: 5.5,
                            ),
                            trackHeight: 2.5,
                            activeTrackColor: Colors.lightBlueAccent,
                            inactiveTrackColor: Colors.white24,
                            thumbColor: Colors.white,
                          ),
                          child: Slider(
                            min: 0,
                            max: safeMax,
                            value: sliderValue,
                            onChangeStart: (v) =>
                                _homeAudioDragMsNotifier.value = v,
                            onChanged: (v) => _homeAudioDragMsNotifier.value = v,
                            onChangeEnd: (v) async {
                              _homeAudioDragMsNotifier.value = null;
                              final next = await CallRecordingService.seekTo(
                                v.round(),
                              );
                              if (mounted) _playbackStateNotifier.value = next;
                            },
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: Text(
                          CallRecordingItem.formatDurationMs(totalMs),
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 11,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildCallLeadingWithPlay({
    required Color typeColor,
    required IconData typeIcon,
    required CallRecordingItem? matchedRecording,
  }) {
    final typeAvatar = CircleAvatar(
      backgroundColor: typeColor,
      radius: matchedRecording != null ? 18 : 22,
      child: Icon(
        typeIcon,
        color: Colors.white,
        size: matchedRecording != null ? 16 : 18,
      ),
    );

    if (matchedRecording == null) {
      return typeAvatar;
    }

    return ValueListenableBuilder<CallPlaybackState>(
      valueListenable: _playbackStateNotifier,
      builder: (context, playbackState, _) {
        final isPlaying = playbackState.isPlayingFile(matchedRecording.filePath);
        final isActive = playbackState.isActiveFile(matchedRecording.filePath);

        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            typeAvatar,
            const SizedBox(width: 6),
            Tooltip(
              message: isPlaying ? 'Tạm dừng ghi âm' : 'Nghe ghi âm cuộc gọi',
              child: Material(
                color: isActive ? Colors.blue[700] : Colors.teal[50],
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () => _togglePlayRecording(matchedRecording),
                  child: Padding(
                    padding: const EdgeInsets.all(6),
                    child: Icon(
                      isPlaying ? Icons.pause : Icons.play_arrow,
                      size: 20,
                      color: isActive ? Colors.white : Colors.teal[800],
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildEmptyCallsRecordingShortcut() {
    return _buildCallRecordingSummaryBar(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
    );
  }

  Widget _buildCallRecordingSummaryBar({
    EdgeInsets padding = const EdgeInsets.only(bottom: 8),
  }) {
    return Padding(
      padding: padding,
      child: Row(
        children: [
          Icon(Icons.mic_none, size: 15, color: Colors.teal[700]),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              'Ghi âm chủ động từng cuộc gọi • Tự xóa sau 30 ngày',
              style: TextStyle(fontSize: 11.5, color: Colors.grey[700]),
            ),
          ),
          TextButton.icon(
            onPressed: _openCallRecordingsScreen,
            icon: const Icon(Icons.library_music, size: 16),
            label: Text(
              'Kho ghi âm (${_recordings.length})',
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
            style: TextButton.styleFrom(
              foregroundColor: Colors.blue[700],
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _checkForAppUpdate({
    bool forceCheck = false,
    bool delay = true,
  }) async {
    if (!forceCheck) {
      final settings = await AppSettingsService.load();
      if (!settings.autoCheckUpdateEnabled || !mounted) return;
    }
    if (delay) await Future<void>.delayed(const Duration(seconds: 3));
    if (!mounted) return;
    if (!forceCheck && !AppSettingsService.current.autoCheckUpdateEnabled) {
      return;
    }
    _lastUpdateCheckAt = DateTime.now();
    await _appUpdateService.checkForUpdate(context, forceCheck: forceCheck);
  }

  Future<void> _refreshDefaultSmsStatus() async {
    try {
      const channel = MethodChannel('call_log_manager');
      final isDefault =
          await channel.invokeMethod<bool>('isCallLogDefaultSmsApp') ?? false;
      if (mounted && isDefault != _isCallLogDefaultSmsApp) {
        setState(() => _isCallLogDefaultSmsApp = isDefault);
      }
    } on PlatformException {
      // The warning is optional on devices that do not expose SMS role status.
    }
  }

  Future<void> _openDefaultSmsSettings() async {
    try {
      const channel = MethodChannel('call_log_manager');
      await channel.invokeMethod<bool>('openSmsDefaultSettings');
    } on PlatformException {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Không mở được cài đặt ứng dụng SMS.')),
      );
    }
  }

  Future<void> _loadCallLogs({bool force = true}) async {
    try {
      final provider = Provider.of<CallLogProvider>(context, listen: false);
      await provider.loadCallLogs(forceRefresh: force);
    } catch (e) {
      // Ignore
    }
  }

  Widget _buildDefaultSmsBanner() {
    if (!_isCallLogDefaultSmsApp) return const SizedBox.shrink();
    return ValueListenableBuilder<AppSettings>(
      valueListenable: AppSettingsService.notifier,
      builder: (context, settings, _) {
        if (!settings.defaultSmsWarningEnabled) return const SizedBox.shrink();
        return Container(
          color: const Color(0xFFFFF3CD),
          padding: const EdgeInsets.only(left: 12, right: 4, top: 4, bottom: 4),
          child: Row(
            children: [
              const Icon(
                Icons.warning_amber_rounded,
                color: Color(0xFF9A6500),
                size: 21,
              ),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'Delivery Support đang là app SMS mặc định; tin mới có thể không báo.',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Color(0xFF684700),
                    fontSize: 12,
                  ),
                ),
              ),
              IconButton(
                onPressed: _openDefaultSmsSettings,
                tooltip: 'Đổi ứng dụng SMS mặc định',
                icon: const Icon(
                  Icons.settings_outlined,
                  color: Color(0xFF684700),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildDeliveryTab() {
    return Consumer<CallLogProvider>(
      builder: (context, provider, child) {
        return RefreshIndicator(
          onRefresh: () => _loadCallLogs(force: true),
          child: SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 20),
            child: Column(
              children: [
                const TabGuideBanner(
                  title: 'Hướng dẫn cài đặt & sử dụng Giao hàng',
                  accentColor: Colors.blue,
                  sections: [
                    TabGuideSection(
                      heading: 'Cài đặt ban đầu',
                      steps: [
                        'Bật công tắc "Bong bóng trôi nổi" và cấp quyền Hiển thị trên ứng dụng khác.',
                        'Cấp quyền Nhật ký cuộc gọi để đồng bộ danh sách cuộc gọi giao hàng gần nhất.',
                        'Cấp quyền Micro & Điện thoại (ở thẻ nhắc phía trên hoặc trong Kho ghi âm) để hiện nút Ghi âm chủ động từng cuộc gọi.',
                      ],
                    ),
                    TabGuideSection(
                      heading: 'Cách sử dụng khi đi giao',
                      steps: [
                        'Chạm bong bóng nổi để xem 2–6 cuộc gọi gần nhất ngay trên màn hình app giao hàng.',
                        'Trong cuộc gọi bấm nút Ghi âm chủ động, hoặc bấm Thêm → Ghi âm trên máy Xiaomi và chọn thư mục đồng bộ trong Kho ghi âm nếu VoLTE chặn mic app (không cần Trợ năng).',
                        'Bấm biểu tượng "₫" trên popup để xem nhanh các đơn đang chờ chuyển khoản ngay trên đường; chỉnh độ mờ bong bóng/popup trong tab Cài đặt.',
                      ],
                    ),
                  ],
                ),
                const FloatingWindowWidget(),
                _buildCallRecordingSetupBanner(),
                _buildLatestCallsPreview(provider),
                if (provider.getLatestCalls(count: 4).isEmpty)
                  _buildEmptyCallsRecordingShortcut(),
                _buildHomeInlinePlayer(),
                const SizedBox(height: 8),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildMessagingQrTab() {
    return SingleChildScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 20),
      child: Column(
        children: [
          const TabGuideBanner(
            title: 'Hướng dẫn cài đặt & sử dụng Nhắn tin QR',
            accentColor: Colors.green,
            sections: [
              TabGuideSection(
                heading: '1. Cài đặt SMS & Quyền nhận phản hồi',
                steps: [
                  'Bấm "Cấp quyền SMS" ở cuối thẻ dưới để gửi SMS nhanh trực tiếp từ popup nổi qua SIM.',
                  'Bấm "Cấp quyền nhận SMS" để app tự nhận biết khi khách trả lời SMS trên các đơn đang chờ chuyển khoản.',
                  'Nếu bật "SMS ảo cho icon SMS từ app": mở SMS từ app giao hàng sẽ ghi vào mục Đã gửi mà không tốn cước. Xong việc nhớ giữ app SMS chính làm mặc định để không lỡ tin nhắn mới.',
                ],
              ),
              TabGuideSection(
                heading: '2. Soạn mẫu tin & Nút ghi chú nhanh',
                steps: [
                  'Nhập mẫu nội dung đứng trước số tiền (VD: Số TK + Ngân hàng + Tên chủ TK). App tự bỏ dấu tiếng Việt để tối ưu vừa 1 SMS (160 ký tự) và hiển thị xem trước ngay bên dưới.',
                  'Tạo tối đa 6 "Nút mẫu ghi chú nhanh" (nhãn ngắn + nội dung đính sau số tiền) để bấm 1 chạm trên popup nổi không cần gõ tay.',
                ],
              ),
              TabGuideSection(
                heading: '3. Cài đặt Tài khoản & QR tĩnh Zalo',
                steps: [
                  'Mở mục "Cấu hình Tài khoản QR Zalo" bên dưới, chọn đúng ngân hàng (VietQR), nhập Số tài khoản và Tên chủ tài khoản.',
                  'Đợi QR tĩnh xem trước tải xong, dùng app ngân hàng quét thử kiểm tra đúng người nhận rồi tick xác nhận và Lưu.',
                ],
              ),
              TabGuideSection(
                heading: '4. Cách gửi SMS / QR Zalo từ popup nổi',
                steps: [
                  'Chạm bong bóng nổi → chọn biểu tượng tin nhắn cạnh SĐT khách → nhập Số tiền (và chạm ghi chú nhanh nếu cần).',
                  'Bấm nút SMS để gửi SIM và quét mã vận đơn; hoặc bấm nút Z (Zalo) để quét mã đơn, tự chuẩn bị QR tĩnh & mở thẳng Zalo theo SĐT khách (chỉ việc dán nội dung và gửi ảnh QR).',
                ],
              ),
            ],
            highlightNote:
                'Mọi đơn gửi qua SMS hay Zalo có kèm số tiền đều tự lưu sang tab Đối soát (mục Chờ chuyển) để bạn theo dõi tiền về.',
          ),
          const _SmsTemplateConfigWidget(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Card(
              color: Colors.green.shade50.withValues(alpha: 0.5),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
                side: BorderSide(color: Colors.green.shade200),
              ),
              child: ListTile(
                leading: Icon(
                  Icons.account_balance_outlined,
                  color: Colors.green.shade800,
                ),
                title: const Text(
                  'Cấu hình Tài khoản QR Zalo',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                ),
                subtitle: const Text(
                  'Thiết lập ngân hàng và quét xác nhận QR tĩnh',
                  style: TextStyle(fontSize: 12),
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push<bool>(
                  MaterialPageRoute<bool>(
                    builder: (_) => const PaymentAccountSettingsScreen(),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildUtilitiesTab() {
    return SingleChildScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 20),
      child: Column(
        children: [
          const TabGuideBanner(
            title: 'Hướng dẫn cài đặt & sử dụng Tiện ích',
            accentColor: Colors.purple,
            sections: [
              TabGuideSection(
                heading: 'Fake GPS (Vị trí giả lập)',
                steps: [
                  'Bật Tùy chọn nhà phát triển trên Android → Chọn ứng dụng vị trí giả (Mock location) → chọn Delivery Support.',
                  'Chọn điểm trên bản đồ hoặc từ danh sách đã lưu rồi bật Fake GPS; tắt ngay khi không cần để GPS thật hoạt động bình thường.',
                ],
              ),
              TabGuideSection(
                heading: 'TimeMark & Quét Mã Vạch / QR',
                steps: [
                  'TimeMark: Chụp ảnh giao hàng gắn sẵn thời gian, tọa độ GPS và mã đơn (hỗ trợ chụp 1 chạm hoặc chụp liên tiếp).',
                  'Quét Mã Vạch & QR Code: Hỗ trợ quét liên tục nhiều mã, âm báo và cảnh báo phân biệt mã mới / mã đã quét hôm nay / mã đã chia sẻ.',
                ],
              ),
            ],
          ),
          const FakeGpsWidget(),
          const TimeMarkCameraWidget(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Card(
              color: Colors.purple.shade50.withValues(alpha: 0.5),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
                side: BorderSide(color: Colors.purple.shade200),
              ),
              child: ListTile(
                leading: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.purple.shade100,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    Icons.qr_code_scanner,
                    color: Colors.purple.shade800,
                  ),
                ),
                title: const Text(
                  'Quét Mã Vạch & QR Code',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                ),
                subtitle: const Text(
                  'Quét liên tục, xem danh sách, copy & chia sẻ',
                  style: TextStyle(fontSize: 12),
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const BarcodeScannerScreen(),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 50,
        leading: const _DonateCardWidget(),
        leadingWidth: 84,
        titleSpacing: 0,
        centerTitle: false,
        title: const Text(
          'Delivery Support',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
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
            icon: const Icon(Icons.refresh, color: Colors.white),
            onPressed: () {
              _loadCallLogs(force: true);
              _refreshCallRecordingState();
              AppSettingsService.load(force: true);
            },
            tooltip: 'Làm mới',
          ),
        ],
      ),
      body: Column(
        children: [
          _buildDefaultSmsBanner(),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              physics: const NeverScrollableScrollPhysics(),
              children: [
                _LazyKeepAliveTab(
                  shouldBuild: _visitedTabs.contains(0),
                  builder: (_) => _buildDeliveryTab(),
                ),
                _LazyKeepAliveTab(
                  shouldBuild: _visitedTabs.contains(1),
                  builder: (_) => _buildMessagingQrTab(),
                ),
                _LazyKeepAliveTab(
                  shouldBuild: _visitedTabs.contains(2),
                  builder: (_) => const PaymentReconciliationScreen(embedded: true),
                ),
                _LazyKeepAliveTab(
                  shouldBuild: _visitedTabs.contains(3),
                  builder: (_) => _buildUtilitiesTab(),
                ),
                _LazyKeepAliveTab(
                  shouldBuild: _visitedTabs.contains(4),
                  builder: (_) => const AppSettingsTab(),
                ),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: Material(
        color: Colors.white,
        elevation: 6,
        child: SafeArea(
          top: false,
          child: Container(
            height: 50,
            decoration: BoxDecoration(
              border: Border(
                top: BorderSide(color: Colors.grey.shade200, width: 1),
              ),
            ),
            child: TabBar(
              controller: _tabController,
              labelColor: Colors.blue[700],
              unselectedLabelColor: Colors.grey[600],
              labelPadding: const EdgeInsets.symmetric(horizontal: 2),
              indicator: BoxDecoration(
                border: Border(
                  top: BorderSide(color: Colors.blue[700]!, width: 2.5),
                ),
                color: Colors.blue.withValues(alpha: 0.06),
              ),
              indicatorSize: TabBarIndicatorSize.tab,
              dividerColor: Colors.transparent,
              tabs: const [
                _CompactBottomTab(
                  icon: Icons.local_shipping_outlined,
                  label: 'Giao hàng',
                ),
                _CompactBottomTab(
                  icon: Icons.sms_outlined,
                  label: 'Nhắn tin QR',
                ),
                _CompactBottomTab(
                  icon: Icons.receipt_long_outlined,
                  label: 'Đối soát',
                ),
                _CompactBottomTab(
                  icon: Icons.widgets_outlined,
                  label: 'Tiện ích',
                ),
                _CompactBottomTab(
                  icon: Icons.settings_outlined,
                  label: 'Cài đặt',
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Hiển thị các cuộc gọi gần nhất
  Widget _buildLatestCallsPreview(CallLogProvider provider) {
    if (provider.isLoading && provider.allCallLogs.isEmpty) {
      return Container(
        margin: const EdgeInsets.fromLTRB(16, 4, 16, 12),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.grey[50],
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.grey.shade200),
        ),
        child: Row(
          children: [
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 12),
            Text(
              'Đang tải nhật ký cuộc gọi...',
              style: TextStyle(color: Colors.grey[700], fontSize: 13.5),
            ),
          ],
        ),
      );
    }

    if (provider.hasError) {
      return Container(
        margin: const EdgeInsets.fromLTRB(16, 4, 16, 12),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.red[50],
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.red.shade200),
        ),
        child: Row(
          children: [
            Icon(Icons.error_outline, color: Colors.red[700], size: 22),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                provider.errorMessage,
                style: TextStyle(color: Colors.red[900], fontSize: 13),
              ),
            ),
            TextButton(
              onPressed: () => _loadCallLogs(force: true),
              child: const Text('Thử lại'),
            ),
          ],
        ),
      );
    }

    if (!provider.hasPermission) {
      return Container(
        margin: const EdgeInsets.fromLTRB(16, 4, 16, 12),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.orange[50],
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.orange.shade200),
        ),
        child: Row(
          children: [
            Icon(Icons.security, color: Colors.orange[800], size: 22),
            const SizedBox(width: 10),
            const Expanded(
              child: Text(
                'Cấp quyền đọc nhật ký để hiển thị 4 cuộc gọi gần nhất.',
                style: TextStyle(fontSize: 13),
              ),
            ),
            ElevatedButton(
              onPressed: () async {
                final granted = await provider.requestPermission();
                if (granted) {
                  await _loadCallLogs(force: true);
                }
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.orange[800],
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              ),
              child: const Text('Cấp quyền', style: TextStyle(fontSize: 12.5)),
            ),
          ],
        ),
      );
    }

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
          _buildCallRecordingSummaryBar(),
          ...latestCalls.map(
            (call) => Card(
              margin: const EdgeInsets.only(bottom: 8),
              elevation: 2,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
              child: ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                horizontalTitleGap: 10,
                leading: _buildCallLeadingWithPlay(
                  typeColor: _getCallTypeColor(call.callType),
                  typeIcon: _getCallTypeIcon(call.callType),
                  matchedRecording: CallRecordingService.matchRecordingForCall(
                    call,
                    _recordings,
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

class SmsQuickNote {
  String label;
  String content;

  SmsQuickNote({required this.label, required this.content});

  String get displayLabel {
    final trimmedLabel = label.trim();
    if (trimmedLabel.isNotEmpty) return trimmedLabel;
    return content.trim();
  }

  Map<String, String> toJson() => {
        'label': label.trim(),
        'content': content.trim(),
      };

  factory SmsQuickNote.fromDynamic(dynamic item) {
    if (item is Map) {
      final l = (item['label'] ?? '').toString().trim();
      final c = (item['content'] ?? '').toString().trim();
      return SmsQuickNote(
        label: l.isNotEmpty ? l : c,
        content: c.isNotEmpty ? c : l,
      );
    } else if (item is String) {
      final s = item.trim();
      return SmsQuickNote(label: s, content: s);
    }
    return SmsQuickNote(label: '', content: '');
  }
}

class _SmsTemplateConfigWidget extends StatefulWidget {
  const _SmsTemplateConfigWidget();

  @override
  State<_SmsTemplateConfigWidget> createState() =>
      _SmsTemplateConfigWidgetState();
}

class _SmsTemplateConfigWidgetState extends State<_SmsTemplateConfigWidget>
    with WidgetsBindingObserver {
  static const _regularLicenseSyncInterval = Duration(hours: 12);
  static const _pendingLicenseSyncInterval = Duration(minutes: 5);
  static const _pendingLicenseSyncWindow = Duration(days: 3);
  final TextEditingController _controller = TextEditingController();
  final LicenseApiService _licenseApi = LicenseApiService();
  List<SmsQuickNote> _quickNotes = [];
  int? _previewSelectedNoteIndex;
  bool _hasSmsPermission = false;
  bool _hasIncomingSmsPermission = false;
  bool _isAutoFakeSmsIntent = false;
  Map<String, dynamic>? _licenseDetails;
  bool _isLoading = true;
  bool _isSyncingLicense = false;
  int _lastLicenseSyncAttemptAt = 0;

  String _lastSyncKey(String deviceId) => 'sms_license_last_sync_$deviceId';
  String _pendingOrderKey(String deviceId) => 'sms_license_pending_order_$deviceId';

  Future<void> _markPendingOrder(String deviceId) async {
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setInt(_pendingOrderKey(deviceId), DateTime.now().millisecondsSinceEpoch);
    } catch (_) {
      // The order remains available on the server if local storage is unavailable.
    }
  }

  Future<void> _clearPendingOrder(String deviceId) async {
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.remove(_pendingOrderKey(deviceId));
    } catch (_) {}
  }

  Future<void> _recordLicenseSync(String deviceId) async {
    try {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setInt(_lastSyncKey(deviceId), DateTime.now().millisecondsSinceEpoch);
    } catch (_) {}
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadConfig();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _syncLicenseFromServer();
  }

  Future<void> _loadConfig() async {
    try {
      const channel = MethodChannel('call_log_manager');
      final String template = await channel.invokeMethod('getSmsTemplate');
      final List<dynamic>? rawQuickNotes =
          await channel.invokeMethod<List<dynamic>>('getSmsQuickNotes');
      final quickNotes = rawQuickNotes != null
          ? rawQuickNotes
              .map((e) => SmsQuickNote.fromDynamic(e))
              .where((e) => e.displayLabel.isNotEmpty)
              .toList()
          : <SmsQuickNote>[
              SmsQuickNote(label: 'Bảo vệ', content: 'gui hang tai bao ve'),
              SmsQuickNote(label: 'Cô nước', content: 'gui hang co ban nuoc'),
              SmsQuickNote(
                label: 'Shopee 0đ',
                content: 'don shopee 0d gui trong thung EMG',
              ),
            ];
      final bool hasPerm = await channel.invokeMethod('hasSmsPermission');
      final bool hasIncomingPerm = await channel.invokeMethod(
        'hasIncomingSmsPermission',
      );
      final bool autoFakeIntent =
          await channel.invokeMethod('getAutoFakeSmsIntent') ?? false;

      final licenseInfo = await _readLicenseDetails(channel);

      if (mounted) {
        setState(() {
          _controller.text = template;
          _quickNotes = quickNotes;
          _hasSmsPermission = hasPerm;
          _hasIncomingSmsPermission = hasIncomingPerm;
          _isAutoFakeSmsIntent = autoFakeIntent;
          _licenseDetails = licenseInfo;
          _isLoading = false;
        });
        unawaited(_syncLicenseFromServer());
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<Map<String, dynamic>?> _readLicenseDetails(
    MethodChannel channel,
  ) async {
    try {
      final String? licenseStr = await channel.invokeMethod<String>(
        'getSmsLicenseDetails',
      );
      if (licenseStr == null || licenseStr.isEmpty) return null;
      return jsonDecode(licenseStr) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  Future<void> _syncLicenseFromServer({bool force = false}) async {
    if (!_licenseApi.isConfigured || _isSyncingLicense) return;
    _isSyncingLicense = true;
    try {
      const channel = MethodChannel('call_log_manager');
      final deviceId = await channel.invokeMethod<String>('getDeviceId');
      if (deviceId == null || deviceId.isEmpty) return;
      SharedPreferences? preferences;
      try {
        preferences = await SharedPreferences.getInstance();
      } catch (_) {
        // A storage failure must not prevent an online license check.
      }
      final now = DateTime.now().millisecondsSinceEpoch;
      final pendingAt = preferences?.getInt(_pendingOrderKey(deviceId)) ?? 0;
      final lastSyncAt = preferences?.getInt(_lastSyncKey(deviceId)) ?? 0;
      final hasRecentOrder = pendingAt > 0 && now >= pendingAt &&
          now - pendingAt < _pendingLicenseSyncWindow.inMilliseconds;
      final interval = hasRecentOrder
          ? _pendingLicenseSyncInterval
          : _regularLicenseSyncInterval;
      if (!force && lastSyncAt > 0 && now >= lastSyncAt &&
          now - lastSyncAt < interval.inMilliseconds) {
        return;
      }
      if (!force && now >= _lastLicenseSyncAttemptAt &&
          now - _lastLicenseSyncAttemptAt < const Duration(minutes: 1).inMilliseconds) {
        return;
      }
      _lastLicenseSyncAttemptAt = now;
      final previousDetails = await _readLicenseDetails(channel);
      final response = await _licenseApi.syncLicense(
        deviceId,
        trialUsed: previousDetails?['usedTrial'] as int? ?? 0,
      );
      final token = response['licenseToken']?.toString();
      if (token == null || token.isEmpty) return;
      final bool? applied = await channel.invokeMethod<bool>(
        'applyServerLicenseToken',
        {'token': token},
      );
      if (applied == true && mounted) {
        await _recordLicenseSync(deviceId);
        if (response['license'] is Map &&
            (response['license'] as Map)['status'] == 'active') {
          await _clearPendingOrder(deviceId);
        }
        final details = await _readLicenseDetails(channel);
        if (mounted && details != null) {
          setState(() => _licenseDetails = details);
        }
      }
    } catch (_) {
      // Keep the last verified token available during temporary network outages.
    } finally {
      _isSyncingLicense = false;
    }
  }

  Future<void> _saveTemplate({bool showFeedback = true}) async {
    try {
      const channel = MethodChannel('call_log_manager');
      await channel.invokeMethod('saveSmsTemplate', {
        'template': _controller.text,
      });
      await channel.invokeMethod('saveSmsQuickNotes', {
        'notes': _quickNotes.map((e) => e.toJson()).toList(),
      });
      if (mounted && showFeedback) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('✅ Đã lưu mẫu tin nhắn & các nút ghi chú SMS!'),
            backgroundColor: Colors.green,
            duration: Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      if (mounted && showFeedback) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('❌ Lỗi khi lưu: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  void _showAddEditQuickNoteDialog({int? index}) {
    final isEditing = index != null && index >= 0 && index < _quickNotes.length;
    final existingNote = isEditing ? _quickNotes[index] : null;
    final labelController = TextEditingController(
      text: existingNote?.label ?? '',
    );
    final contentController = TextEditingController(
      text: existingNote?.content ?? '',
    );

    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isEditing ? 'Sửa nút ghi chú' : 'Thêm nút ghi chú (Tối đa 6)'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: labelController,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: 'VD: Bảo vệ, Cô nước, Shopee 0đ',
                  labelText: 'Tên nút / Viết tắt (Hiển thị ngắn gọn)',
                  border: OutlineInputBorder(),
                  helperText: 'Tên xuất hiện trên nút chip ở bong bóng nổi.',
                ),
                maxLength: 20,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: contentController,
                decoration: const InputDecoration(
                  hintText: 'VD: gui hang tai bao ve',
                  labelText: 'Nội dung SMS đầy đủ (Gửi cho khách)',
                  border: OutlineInputBorder(),
                  helperText: 'Nội dung thực tế được ghép vào tin nhắn SMS.',
                ),
                maxLength: 80,
              ),
              const SizedBox(height: 4),
              Text(
                'Mẹo: Viết tắt giúp nút nhỏ gọn, dễ bấm khi thao tác trên đường.',
                style: TextStyle(fontSize: 11, color: Colors.grey[600]),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Hủy'),
          ),
          ElevatedButton(
            onPressed: () {
              var label = labelController.text.trim();
              var content = contentController.text.trim();
              if (label.isEmpty && content.isEmpty) return;
              if (label.isEmpty) label = content;
              if (content.isEmpty) content = label;

              final item = SmsQuickNote(label: label, content: content);
              setState(() {
                if (isEditing) {
                  _quickNotes[index] = item;
                } else {
                  if (_quickNotes.length < 6) {
                    _quickNotes.add(item);
                  }
                }
              });
              Navigator.of(ctx).pop();
              _saveTemplate(showFeedback: false);
            },
            child: Text(isEditing ? 'Lưu' : 'Thêm'),
          ),
        ],
      ),
    );
  }

  void _deleteQuickNote(int index) {
    if (index >= 0 && index < _quickNotes.length) {
      setState(() {
        _quickNotes.removeAt(index);
      });
      _saveTemplate(showFeedback: false);
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
                  ? 'Icon SMS từ app sẽ tạo SMS ảo; SMS nhanh trong popup vẫn gửi qua SIM'
                  : 'Icon SMS từ app sẽ hiện lựa chọn SMS ảo hoặc gửi thật',
            ),
            backgroundColor: enabled ? Colors.green[700] : Colors.grey[700],
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Không đổi được cài đặt: $error')));
    }
  }

  Future<void> _showLicenseModal() async {
    await _syncLicenseFromServer(force: true);
    const deviceIdChannel = MethodChannel('call_log_manager');
    String deviceId = '';
    try {
      deviceId =
          (await deviceIdChannel.invokeMethod<String>('getDeviceId') ?? '')
              .trim()
              .toUpperCase();
    } catch (_) {
      deviceId = '';
    }
    Map<String, dynamic>? licenseInfo = _licenseDetails;
    final deviceIdPattern = RegExp(
      r'^SMS-(?:[A-F0-9]{4}-[A-F0-9]{4}|[A-F0-9]{8}-[A-F0-9]{8})$',
    );
    if (!deviceIdPattern.hasMatch(deviceId)) {
      final cachedDeviceId = (licenseInfo?['deviceId']?.toString() ?? '')
          .trim()
          .toUpperCase();
      if (deviceIdPattern.hasMatch(cachedDeviceId)) {
        deviceId = cachedDeviceId;
      } else {
        licenseInfo = await _readLicenseDetails(deviceIdChannel);
        deviceId = (licenseInfo?['deviceId']?.toString() ?? '')
            .trim()
            .toUpperCase();
      }
    }
    if (!mounted) return;
    if (!deviceIdPattern.hasMatch(deviceId)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Không đọc được mã thiết bị hợp lệ.')),
      );
      return;
    }
    if (licenseInfo != _licenseDetails && licenseInfo != null) {
      setState(() => _licenseDetails = licenseInfo);
    }
    const plans = [
      {'id': '30D', 'title': '30 ngày', 'price': '50.000đ'},
      {'id': '90D', 'title': '90 ngày', 'price': '140.000đ'},
      {'id': '1Y', 'title': '1 năm', 'price': '365.000đ'},
      {'id': 'PERM', 'title': 'Vĩnh viễn', 'price': '999.999đ'},
    ];
    final isLicensed = _licenseDetails?['isLicensed'] == true;
    final hasPermanentLicense = isLicensed && _licenseDetails?['plan'] == 'PERM';
    final remainingTrial = _licenseDetails?['remainingTrial'] as int? ?? 0;
    Map<String, dynamic>? order;
    Timer? paymentTimer;
    var creatingOrder = false;
    var checkingPayment = false;
    var automaticPaymentCheckStopped = false;
    var automaticPaymentCheckCount = 0;
    var sheetIsOpen = true;
    String? paymentMessage;

    Future<void> checkPayment(StateSetter update) async {
      if (checkingPayment || order == null || !sheetIsOpen) return;
      checkingPayment = true;
      try {
        final status = await _licenseApi.checkOrderStatus(
          deviceId: deviceId,
          paymentCode: order!['paymentCode'].toString(),
        );
        final state = status['status']?.toString();
        if (state == 'paid') {
          const channel = MethodChannel('call_log_manager');
          final previousDetails = await _readLicenseDetails(channel);
          final synced = await _licenseApi.syncLicense(
            deviceId,
            trialUsed: previousDetails?['usedTrial'] as int? ?? 0,
          );
          final token = synced['licenseToken']?.toString();
          if (token == null || token.isEmpty) {
            throw const LicenseApiException(
              'Chưa nhận được dữ liệu kích hoạt.',
            );
          }
          final applied = await channel.invokeMethod<bool>(
            'applyServerLicenseToken',
            {'token': token},
          );
          if (applied != true) {
            throw const LicenseApiException(
              'Không xác minh được license trên thiết bị này.',
            );
          }
          await _recordLicenseSync(deviceId);
          await _clearPendingOrder(deviceId);
          paymentTimer?.cancel();
          await _loadConfig();
          if (sheetIsOpen && mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Đã xác nhận chuyển khoản và kích hoạt SMS!'),
                backgroundColor: Colors.green,
              ),
            );
            Navigator.of(context).pop();
          }
        } else if (state == 'expired') {
          await _clearPendingOrder(deviceId);
          paymentTimer?.cancel();
          automaticPaymentCheckStopped = true;
          if (sheetIsOpen) {
            update(() {
              order = null;
              paymentMessage = 'Đơn đã hết hạn. Hãy tạo đơn mới.';
            });
          }
        } else if (state == 'pending' && sheetIsOpen) {
          update(
            () => paymentMessage =
                'Đang chờ quản lý xác nhận đã nhận tiền trong tài khoản.',
          );
        }
      } catch (error) {
        if (sheetIsOpen) update(() => paymentMessage = error.toString());
      } finally {
        checkingPayment = false;
      }
    }

    Future<void> createOrder(String planId, StateSetter update) async {
      if (creatingOrder || order?['plan'] == planId) return;
      update(() {
        creatingOrder = true;
        paymentMessage = null;
      });
      try {
        final created = await _licenseApi.createOrder(
          deviceId: deviceId,
          plan: planId,
        );
        await _markPendingOrder(deviceId);
        if (!sheetIsOpen) return;
        update(() {
          order = created;
          automaticPaymentCheckStopped = false;
          automaticPaymentCheckCount = 0;
          paymentMessage =
              'Chuyển khoản xong, gửi mã máy qua Telegram để quản lý đối soát.';
        });
        paymentTimer?.cancel();
        paymentTimer = Timer.periodic(const Duration(minutes: 5), (_) {
          if (!sheetIsOpen) {
            paymentTimer?.cancel();
            return;
          }
          if (automaticPaymentCheckCount >= 2) {
            paymentTimer?.cancel();
            automaticPaymentCheckStopped = true;
            update(() {
              paymentMessage =
                  'Đã dừng tự kiểm tra sau 15 phút để tiết kiệm chi phí. Sau khi quản lý duyệt, hãy mở lại app hoặc bấm kiểm tra trạng thái.';
            });
            return;
          }
          automaticPaymentCheckCount += 1;
          unawaited(checkPayment(update));
        });
        unawaited(checkPayment(update));
      } catch (error) {
        if (sheetIsOpen) update(() => paymentMessage = error.toString());
      } finally {
        if (sheetIsOpen) update(() => creatingOrder = false);
      }
    }

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, update) {
          final expiryValue = order?['expiresAt'];
          final expiry = expiryValue is num
              ? DateTime.fromMillisecondsSinceEpoch(
                  expiryValue.toInt(),
                ).toLocal().toString().substring(0, 16)
              : '';
          return SafeArea(
            child: Container(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(ctx).size.height * 0.9,
              ),
              padding: EdgeInsets.fromLTRB(
                16,
                18,
                16,
                MediaQuery.of(ctx).viewInsets.bottom + 20,
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
                    const Text(
                      'Bản quyền SMS',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Mã thiết bị: $deviceId',
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    if (isLicensed)
                      Text(
                        'Đang dùng gói ${_licenseDetails?['plan'] ?? ''} · '
                        '${_licenseDetails?['expiresAtFormatted'] ?? 'Vĩnh viễn'}',
                      )
                    else
                      Text(
                        remainingTrial > 0
                            ? 'Còn $remainingTrial/10 tin nhắn trải nghiệm.'
                            : 'Đã dùng hết lượt trải nghiệm miễn phí.',
                      ),
                    const SizedBox(height: 14),
                    if (hasPermanentLicense)
                      const Text('Gói vĩnh viễn đã kích hoạt. Không cần chuyển khoản thêm.'),
                    if (!hasPermanentLicense) ...[
                      const Text(
                        'Chọn gói bản quyền',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 8),
                    ],
                    if (!hasPermanentLicense) for (final plan in plans)
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton(
                          onPressed: creatingOrder || order?['plan'] == plan['id']
                              ? null
                              : () => createOrder(plan['id']!, update),
                          child: Row(
                            children: [
                              Expanded(child: Text(plan['title']!)),
                              Text(
                                plan['price']!,
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              if (creatingOrder) ...[
                                const SizedBox(width: 8),
                                const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    if (order != null) ...[
                      const Divider(),
                      Center(
                        child: Image.network(
                          order!['qrUrl'].toString(),
                          width: 210,
                          height: 210,
                          errorBuilder: (_, __, ___) =>
                              const Text('Không tải được ảnh QR.'),
                        ),
                      ),
                      Text(
                        'Ngân hàng: ${order!['bank']}'
                        '\nSố tài khoản: ${order!['accountNumber']}'
                        '\nChủ tài khoản: ${order!['accountName']}'
                        '\nSố tiền: ${(order!['amount'] as num).toInt()}đ'
                        '\nNội dung: ${order!['transferContent']}',
                        style: const TextStyle(fontSize: 12, height: 1.45),
                      ),
                      if (expiry.isNotEmpty)
                        Text(
                          'Đơn có hiệu lực đến $expiry',
                          style: const TextStyle(
                            fontSize: 11,
                            color: Colors.grey,
                          ),
                        ),
                      OutlinedButton.icon(
                        onPressed: () {
                          final content = order!['transferContent'].toString();
                          Clipboard.setData(ClipboardData(text: content));
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text(
                                'Đã sao chép nội dung chuyển khoản.',
                              ),
                            ),
                          );
                        },
                        icon: const Icon(Icons.copy, size: 16),
                        label: const Text('Sao chép nội dung chuyển khoản'),
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        'Sau khi chuyển khoản, gửi mã máy và mã đơn cho bot/quản lý trên Telegram. Quản lý kiểm tra tiền vào tài khoản rồi duyệt; app sẽ tự kích hoạt khi đồng bộ.',
                        style: TextStyle(fontSize: 12, height: 1.4),
                      ),
                      OutlinedButton.icon(
                        onPressed: () async {
                          final telegramMessage =
                              order!['telegramMessage']?.toString() ??
                              'Mã máy: $deviceId\n'
                                  'Mã đơn: ${order!['paymentCode']}\n'
                                  'Gói: ${order!['planTitle']}\n'
                                  'Số tiền: ${(order!['amount'] as num).toInt()}đ';
                          try {
                            const channel = MethodChannel('call_log_manager');
                            await channel.invokeMethod<bool>('shareText', {
                              'text': telegramMessage,
                            });
                          } catch (_) {
                            await Clipboard.setData(
                              ClipboardData(text: telegramMessage),
                            );
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text(
                                    'Đã sao chép thông tin. Hãy dán vào Telegram.',
                                  ),
                                ),
                              );
                            }
                          }
                        },
                        icon: const Icon(Icons.send, size: 18),
                        label: const Text('Gửi mã máy qua Telegram'),
                      ),
                      Row(
                        children: [
                          if (automaticPaymentCheckStopped)
                            const Icon(Icons.info_outline, size: 18)
                          else
                            const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              paymentMessage ?? 'Đang chờ xác nhận...',
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                        ],
                      ),
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: () => checkPayment(update),
                          child: const Text('Kiểm tra trạng thái kích hoạt'),
                        ),
                      ),
                    ] else if (paymentMessage != null)
                      Text(
                        paymentMessage!,
                        style: TextStyle(color: Colors.red[700], fontSize: 12),
                      ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    ).whenComplete(() {
      sheetIsOpen = false;
      paymentTimer?.cancel();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    super.dispose();
  }

  String _removeVietnameseAccents(String str) {
    const vietnameseMap = {
      'a': 'aàáảãạăằắẳẵặâầấẩẫậ',
      'A': 'AÀÁẢÃẠĂẰẮẲẴẶÂẦẤẨẪẬ',
      'd': 'dđ',
      'D': 'DĐ',
      'e': 'eèéẻẽẹêềếểễệ',
      'E': 'EÈÉẺẼẸÊỀẾỂỄỆ',
      'i': 'iìíỉĩị',
      'I': 'IÌÍỈĨỊ',
      'o': 'oòóỏõọôồốổỗộơờớởỡợ',
      'O': 'OÒÓỎÕỌÔỒỐỔỖỘƠỜỚỞỠỢ',
      'u': 'uùúủũụưừứửữự',
      'U': 'UÙÚỦŨỤƯỪỨỬỮỰ',
      'y': 'yỳýỷỹỵ',
      'Y': 'YỲÝỶỸỴ',
    };
    var result = str;
    vietnameseMap.forEach((nonAccent, accents) {
      for (int i = 0; i < accents.length; i++) {
        result = result.replaceAll(accents[i], nonAccent);
      }
    });
    return result;
  }

  Widget _buildLiveSmsPreview() {
    final selectedNote = (_previewSelectedNoteIndex != null &&
            _previewSelectedNoteIndex! >= 0 &&
            _previewSelectedNoteIndex! < _quickNotes.length)
        ? _quickNotes[_previewSelectedNoteIndex!].content
        : (_previewSelectedNoteIndex == -1
            ? ''
            : (_quickNotes.isNotEmpty ? _quickNotes.first.content : ''));

    final templateText = _controller.text.trim();
    final parts = <String>[];
    if (templateText.isNotEmpty) parts.add(templateText);
    parts.add('250k');
    if (selectedNote.trim().isNotEmpty) parts.add(selectedNote.trim());
    final sampleText = parts.join(' ');

    final previewSms = _removeVietnameseAccents(sampleText);
    final charCount = previewSms.length;
    final int smsCount = charCount == 0
        ? 1
        : (charCount <= 160 ? 1 : ((charCount - 1) ~/ 153) + 1);
    final isOver160 = charCount > 160;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isOver160 ? Colors.orange.shade300 : Colors.blue.shade200,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 6,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.chat_bubble_outline_rounded,
                    size: 16,
                    color: isOver160 ? Colors.orange.shade800 : Colors.blue.shade700,
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      'Xem trước SMS thực tế gửi khách:',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: isOver160 ? Colors.orange.shade900 : Colors.blue.shade900,
                      ),
                    ),
                  ),
                ],
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: isOver160 ? Colors.orange.shade100 : Colors.green.shade100,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: isOver160 ? Colors.orange.shade400 : Colors.green.shade400,
                  ),
                ),
                child: Text(
                  isOver160
                      ? '$charCount ký tự · $smsCount tin (tốn phí)'
                      : '$charCount/160 ký tự · 1 tin',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: isOver160 ? Colors.orange.shade900 : Colors.green.shade900,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(10),
                topRight: Radius.circular(10),
                bottomRight: Radius.circular(10),
                bottomLeft: Radius.circular(2),
              ),
              border: Border.all(color: Colors.grey.shade300),
            ),
            child: Text(
              previewSms.isEmpty ? '(Chưa có nội dung mẫu)' : previewSms,
              style: TextStyle(
                fontSize: 12.5,
                color: previewSms.isEmpty ? Colors.grey : Colors.grey.shade900,
                fontFamily: 'monospace',
                height: 1.35,
              ),
            ),
          ),
          if (_quickNotes.isNotEmpty) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Text(
                  'Thử gắn nút:',
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.grey.shade700,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(right: 4),
                          child: ChoiceChip(
                            label: const Text('Không ghi chú', style: TextStyle(fontSize: 11)),
                            selected: _previewSelectedNoteIndex == -1,
                            onSelected: (val) {
                              setState(() {
                                _previewSelectedNoteIndex = val ? -1 : null;
                              });
                            },
                            padding: EdgeInsets.zero,
                            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                        ),
                        ...List.generate(_quickNotes.length, (idx) {
                          final isSelected = (_previewSelectedNoteIndex == null && idx == 0) ||
                              _previewSelectedNoteIndex == idx;
                          return Padding(
                            padding: const EdgeInsets.only(right: 4),
                            child: ChoiceChip(
                              label: Text(
                                _quickNotes[idx].displayLabel,
                                style: const TextStyle(fontSize: 11),
                              ),
                              selected: isSelected,
                              onSelected: (val) {
                                setState(() {
                                  _previewSelectedNoteIndex = val ? idx : -1;
                                });
                              },
                              padding: EdgeInsets.zero,
                              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                          );
                        }),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
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
              Expanded(
                child: Text(
                  'Cấu hình Tin nhắn Nhanh (SMS)',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Colors.green[800],
                  ),
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

          // === Cấu hình SMS ảo cho icon SMS từ app ===
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
                              'SMS ảo cho icon SMS từ app',
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
                            ? 'Tự ghi vào Đã gửi; SMS nhanh số tiền trong popup vẫn gửi qua SIM'
                            : 'Icon SMS hiện lựa chọn ảo hoặc thật; SMS nhanh số tiền luôn gửi qua SIM',
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
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: _controller,
            builder: (_, __, ___) => _buildLiveSmsPreview(),
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Expanded(
                child: Text(
                  'Nút mẫu ghi chú nhanh (Tối đa 6)',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${_quickNotes.length}/6',
                style: TextStyle(
                  fontSize: 12,
                  color: _quickNotes.length >= 6 ? Colors.orange : Colors.grey[600],
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Chọn trên cửa sổ nổi để bấm 1 chạm đính kèm vào tin nhắn (tự động bỏ dấu để tối ưu 160 ký tự)',
            style: TextStyle(fontSize: 11, color: Colors.grey[600]),
          ),
          const SizedBox(height: 8),
          if (_quickNotes.isEmpty)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.grey[100],
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Center(
                child: Text(
                  'Chưa có mẫu ghi chú nào. Hãy thêm mẫu bên dưới.',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ),
            )
          else
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: List.generate(_quickNotes.length, (idx) {
                final note = _quickNotes[idx];
                final hasDistinctContent = note.label.isNotEmpty &&
                    note.content.isNotEmpty &&
                    note.label.trim().toLowerCase() !=
                        note.content.trim().toLowerCase();
                return Tooltip(
                  message: 'SMS gửi đi: "${note.content}"',
                  child: InputChip(
                    avatar: CircleAvatar(
                      backgroundColor: Colors.blue[700],
                      child: Text(
                        '${idx + 1}',
                        style: const TextStyle(fontSize: 10, color: Colors.white),
                      ),
                    ),
                    label: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          note.displayLabel,
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        if (hasDistinctContent)
                          Text(
                            note.content,
                            style: TextStyle(
                              fontSize: 10,
                              color: Colors.blueGrey[800],
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                      ],
                    ),
                    onPressed: () => _showAddEditQuickNoteDialog(index: idx),
                    onDeleted: () => _deleteQuickNote(idx),
                    deleteIcon: const Icon(Icons.close, size: 16),
                    deleteButtonTooltipMessage: 'Xóa mẫu này',
                    backgroundColor: Colors.blue.withValues(alpha: 0.08),
                    side: BorderSide(color: Colors.blue.withValues(alpha: 0.3)),
                  ),
                );
              }),
            ),
          const SizedBox(height: 8),
          if (_quickNotes.length < 6)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => _showAddEditQuickNoteDialog(),
                icon: const Icon(Icons.add, size: 18),
                label: Text('Thêm nút ghi chú (${6 - _quickNotes.length} vị trí còn lại)'),
                style: TextButton.styleFrom(
                  foregroundColor: Colors.blue[800],
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                ),
              ),
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

class _LazyKeepAliveTab extends StatefulWidget {
  const _LazyKeepAliveTab({required this.shouldBuild, required this.builder});

  final bool shouldBuild;
  final WidgetBuilder builder;

  @override
  State<_LazyKeepAliveTab> createState() => _LazyKeepAliveTabState();
}

class _LazyKeepAliveTabState extends State<_LazyKeepAliveTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => widget.shouldBuild;

  @override
  void didUpdateWidget(covariant _LazyKeepAliveTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.shouldBuild != oldWidget.shouldBuild) {
      updateKeepAlive();
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (!widget.shouldBuild) {
      return const SizedBox.shrink();
    }
    return widget.builder(context);
  }
}

class _CompactBottomTab extends StatelessWidget {
  const _CompactBottomTab({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Tab(
      height: 48,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18),
          const SizedBox(height: 2),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              label,
              maxLines: 1,
              softWrap: false,
              style: const TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
