import 'package:call_log_manager/providers/call_log_provider.dart';
import 'package:call_log_manager/screens/simple_home_screen.dart';
import 'package:call_log_manager/services/app_settings_service.dart';
import 'package:call_log_manager/widgets/app_settings_tab.dart';
import 'package:call_log_manager/widgets/fake_gps_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const mainChannel = MethodChannel('call_log_manager');
  const updatesChannel = MethodChannel('call_log_manager_updates');
  const eventsChannel = MethodChannel('call_log_manager_events');

  late Map<String, dynamic> settingsStore;
  final savedSettingsPayloads = <Map<String, dynamic>>[];
  final invokedMethods = <String>[];

  setUp(() async {
    savedSettingsPayloads.clear();
    invokedMethods.clear();
    settingsStore = <String, dynamic>{
      'soundMasterEnabled': true,
      'barcodeSoundEnabled': true,
      'barcodeSoundVolume': 90,
      'barcodeSoundNewEnabled': true,
      'barcodeSoundPendingEnabled': true,
      'barcodeSoundSessionEnabled': true,
      'barcodeSoundSharedEnabled': true,
      'timeMarkShutterSoundEnabled': true,
      'vibrationMasterEnabled': true,
      'barcodeVibrationEnabled': true,
      'timeMarkVibrationEnabled': true,
      'overlayVibrationEnabled': true,
      'barcodeCameraDupWarningEnabled': true,
      'barcodePostScanDupDialogEnabled': true,
      'defaultSmsWarningEnabled': true,
      'callRecordingSetupWarningEnabled': true,
      'callRecordingSilenceWarningEnabled': true,
      // Disable background update network calls during widget tests
      'autoCheckUpdateEnabled': false,
    };

    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    messenger.setMockMethodCallHandler(mainChannel, (call) async {
      invokedMethods.add(call.method);
      switch (call.method) {
        case 'getAppSettings':
          return Map<String, dynamic>.from(settingsStore);
        case 'saveAppSettings':
          final args = Map<String, dynamic>.from(call.arguments as Map);
          settingsStore = Map<String, dynamic>.from(args['settings'] as Map);
          savedSettingsPayloads.add(settingsStore);
          return Map<String, dynamic>.from(settingsStore);
        case 'resetAppSettings':
          return Map<String, dynamic>.from(settingsStore);
        case 'previewScanTone':
          return true;
        case 'isCallLogDefaultSmsApp':
          return false;
        case 'hasPermission':
          return true;
        case 'getCallLogs':
          return <dynamic>[];
        case 'hasCallRecordingPermissions':
          return true;
        case 'hasOverlayPermission':
          return true;
        case 'getCallRecordings':
          return <dynamic>[];
        case 'getCallRecordingPlaybackState':
          return <String, dynamic>{'status': 'idle', 'positionMs': 0, 'durationMs': 0};
        case 'isFloatingWindowVisible':
          return false;
        case 'getFloatingOpacity':
          return <String, dynamic>{'bubbleOpacity': 80, 'panelOpacity': 95};
        case 'setFloatingOpacity':
          return true;
        case 'getPaymentTrackingRecords':
          return <dynamic>[];
        case 'getDisplayCallCount':
          return 4;
        case 'isIgnoringBatteryOptimizations':
          return true;
        case 'getSmsTemplate':
          return 'em gui hang a';
        case 'getSmsQuickNotes':
          return <dynamic>[];
        case 'hasSmsPermission':
        case 'hasIncomingSmsPermission':
        case 'getAutoFakeSmsIntent':
        case 'isFakeGpsRunning':
        case 'isMockLocationEnabled':
          return false;
        case 'getSmsLicenseDetails':
          return <String, dynamic>{'isLicensed': false, 'trialUsed': 0};
        default:
          return null;
      }
    });

    messenger.setMockMethodCallHandler(updatesChannel, (call) async => null);
    messenger.setMockMethodCallHandler(eventsChannel, (call) async => null);
    await AppSettingsService.load(force: true);
  });

  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(mainChannel, null);
    messenger.setMockMethodCallHandler(updatesChannel, null);
    messenger.setMockMethodCallHandler(eventsChannel, null);
  });

  testWidgets(
      'Delivery Support renders 5 compact bottom tabs, guides, lazy load, and Settings opacity',
      (tester) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      ChangeNotifierProvider<CallLogProvider>(
        create: (_) => CallLogProvider(),
        child: const MaterialApp(home: SimpleHomeScreen()),
      ),
    );
    await tester.pumpAndSettle();

    // App renamed to Delivery Support
    expect(find.text('Delivery Support'), findsOneWidget);
    expect(find.text('APP NVPTTT'), findsNothing);

    // 5 main bottom tabs are visible without overflow on 360px phone width
    expect(find.text('Giao hàng'), findsOneWidget);
    expect(find.text('Nhắn tin QR'), findsOneWidget);
    expect(find.text('Đối soát'), findsOneWidget);
    expect(find.text('Tiện ích'), findsOneWidget);
    expect(find.text('Cài đặt'), findsOneWidget);

    // Tab 0 content visible; opacity controls moved out of FloatingWindowWidget
    expect(find.text('Bong bóng trôi nổi'), findsOneWidget);
    expect(find.text('Độ mờ bong bóng trôi nổi'), findsNothing);
    expect(invokedMethods, isNot(contains('getSmsTemplate')));
    expect(invokedMethods, isNot(contains('getPaymentTrackingRecords')));
    expect(invokedMethods, isNot(contains('isFakeGpsRunning')));
    expect(invokedMethods, isNot(contains('getFloatingOpacity')));

    // Expand guide on Giao hàng tab
    await tester.tap(find.text('Hướng dẫn cài đặt & sử dụng Giao hàng'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Ghi âm chủ động'), findsWidgets);

    // Tab 1 ('Nhắn tin QR'): verify SMS & QR Zalo guide and widgets
    await tester.tap(find.text('Nhắn tin QR'));
    await tester.pumpAndSettle();
    expect(invokedMethods, contains('getSmsTemplate'));
    await tester.tap(find.text('Hướng dẫn cài đặt & sử dụng Nhắn tin QR'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Tài khoản & QR tĩnh Zalo'), findsWidgets);

    // Tab 2 ('Đối soát'): dedicated embedded Payment Reconciliation tab + guide
    await tester.tap(find.text('Đối soát'));
    await tester.pumpAndSettle();
    expect(invokedMethods, contains('getPaymentTrackingRecords'));
    expect(find.text('Đối soát chuyển khoản'), findsOneWidget);
    expect(find.text('Chờ chuyển'), findsWidgets);
    await tester.tap(find.text('Hướng dẫn cài đặt & đối soát chuyển khoản'));
    await tester.pumpAndSettle();
    expect(find.textContaining('khớp tiền & chốt đơn'), findsOneWidget);

    // Tab 4 ('Cài đặt'): guide, opacity sliders, sound, vibration & warnings
    await tester.tap(find.text('Cài đặt'));
    await tester.pumpAndSettle();

    expect(invokedMethods, contains('getFloatingOpacity'));
    expect(find.text('Cài đặt ứng dụng'), findsOneWidget);
    expect(find.text('Bong bóng & Popup'), findsOneWidget);
    expect(find.text('Độ mờ bong bóng trôi nổi'), findsOneWidget);
    expect(find.text('Độ mờ popup thao tác nhanh'), findsOneWidget);

    await tester.drag(find.byType(Slider).first, const Offset(-40, 0));
    await tester.pumpAndSettle();
    expect(invokedMethods, contains('setFloatingOpacity'));

    final settingsScroll = find.descendant(
      of: find.byType(AppSettingsTab),
      matching: find.byType(Scrollable),
    );
    await tester.scrollUntilVisible(
      find.text('Âm thanh phản hồi chung'),
      250,
      scrollable: settingsScroll,
    );
    await tester.tap(find.text('Âm thanh phản hồi chung'));
    await tester.pumpAndSettle();
    expect(savedSettingsPayloads, isNotEmpty);
    expect(savedSettingsPayloads.last['soundMasterEnabled'], isFalse);

    await tester.scrollUntilVisible(
      find.text('Rung chung toàn ứng dụng'),
      250,
      scrollable: settingsScroll,
    );
    expect(find.text('Rung chung toàn ứng dụng'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Cảnh báo & Nhắc nhở'),
      250,
      scrollable: settingsScroll,
    );
    expect(find.text('Cảnh báo & Nhắc nhở'), findsOneWidget);

    // Tab 3 ('Tiện ích'): guide, FakeGps lazy load, no unsolicited device GPS poll
    await tester.tap(find.text('Tiện ích'));
    await tester.pumpAndSettle();
    expect(invokedMethods, contains('isFakeGpsRunning'));
    expect(invokedMethods, isNot(contains('getCurrentDeviceLocation')));
    expect(find.text('Hướng dẫn cài đặt & sử dụng Tiện ích'), findsOneWidget);
    final utilitiesScroll = find.ancestor(
      of: find.byType(FakeGpsWidget),
      matching: find.byWidgetPredicate(
        (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
      ),
    );
    await tester.scrollUntilVisible(
      find.text('Quét Mã Vạch & QR Code'),
      250,
      scrollable: utilitiesScroll,
    );
    expect(find.text('Quét Mã Vạch & QR Code'), findsOneWidget);
  });
}
