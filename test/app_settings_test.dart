import 'package:call_log_manager/models/app_settings.dart';
import 'package:call_log_manager/services/app_settings_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AppSettings model', () {
    test('defaults enable all sound, vibration, and alerts at 90% volume', () {
      const settings = AppSettings();
      expect(settings.soundMasterEnabled, isTrue);
      expect(settings.barcodeSoundEnabled, isTrue);
      expect(settings.barcodeSoundVolume, 90);
      expect(settings.vibrationMasterEnabled, isTrue);
      expect(settings.barcodePostScanDupDialogEnabled, isTrue);
      expect(settings.defaultSmsWarningEnabled, isTrue);
      expect(settings.autoCheckUpdateEnabled, isTrue);
      expect(settings.isBarcodeSoundActiveFor(BarcodeScanToneOutcome.newCode), isTrue);
      expect(settings.isTimeMarkShutterSoundActive, isTrue);
      expect(settings.isBarcodeVibrationActive, isTrue);
      expect(settings.isTimeMarkVibrationActive, isTrue);
      expect(settings.isOverlayVibrationActive, isTrue);
    });

    test('fromMap handles partial/invalid values and clamps volume 0..100', () {
      final parsed = AppSettings.fromMap(<String, dynamic>{
        'soundMasterEnabled': false,
        'barcodeSoundVolume': 150,
        'overlayVibrationEnabled': false,
        'barcodeSoundNewEnabled': 'invalid_type',
      });
      expect(parsed.soundMasterEnabled, isFalse);
      expect(parsed.barcodeSoundVolume, 100);
      expect(parsed.overlayVibrationEnabled, isFalse);
      expect(parsed.barcodeSoundNewEnabled, isTrue);

      final lowVol = AppSettings.fromMap(<String, dynamic>{'barcodeSoundVolume': -10});
      expect(lowVol.barcodeSoundVolume, 0);
    });

    test('master switches override child sound and vibration gates', () {
      const soundOff = AppSettings(
        soundMasterEnabled: false,
        barcodeSoundNewEnabled: true,
        timeMarkShutterSoundEnabled: true,
      );
      expect(soundOff.isBarcodeSoundActiveFor(BarcodeScanToneOutcome.newCode), isFalse);
      expect(soundOff.isTimeMarkShutterSoundActive, isFalse);

      final barcodeSoundOff = soundOff.copyWith(
        soundMasterEnabled: true,
        barcodeSoundEnabled: false,
      );
      expect(
        barcodeSoundOff.isBarcodeSoundActiveFor(BarcodeScanToneOutcome.duplicateShared),
        isFalse,
      );
      expect(barcodeSoundOff.isTimeMarkShutterSoundActive, isTrue);

      const vibOff = AppSettings(
        vibrationMasterEnabled: false,
        barcodeVibrationEnabled: true,
        overlayVibrationEnabled: true,
      );
      expect(vibOff.isBarcodeVibrationActive, isFalse);
      expect(vibOff.isTimeMarkVibrationActive, isFalse);
      expect(vibOff.isOverlayVibrationActive, isFalse);
    });

    test('toMap -> fromMap roundtrip preserves every field', () {
      const custom = AppSettings(
        soundMasterEnabled: true,
        barcodeSoundEnabled: false,
        barcodeSoundVolume: 45,
        barcodeSoundNewEnabled: false,
        barcodeSoundPendingEnabled: true,
        barcodeSoundSessionEnabled: false,
        barcodeSoundSharedEnabled: true,
        timeMarkShutterSoundEnabled: false,
        vibrationMasterEnabled: true,
        barcodeVibrationEnabled: false,
        timeMarkVibrationEnabled: true,
        overlayVibrationEnabled: false,
        barcodeCameraDupWarningEnabled: false,
        barcodePostScanDupDialogEnabled: false,
        defaultSmsWarningEnabled: true,
        callRecordingSetupWarningEnabled: false,
        callRecordingSilenceWarningEnabled: false,
        autoCheckUpdateEnabled: false,
      );
      expect(AppSettings.fromMap(custom.toMap()), custom);
    });
  });

  group('AppSettingsService channel bridge', () {
    const channel = MethodChannel('call_log_manager');
    final recordedCalls = <MethodCall>[];
    Map<String, dynamic> nativeStore = const AppSettings().toMap();

    setUp(() {
      recordedCalls.clear();
      nativeStore = const AppSettings().toMap();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        recordedCalls.add(call);
        if (call.method == 'getAppSettings') {
          return Map<String, dynamic>.from(nativeStore);
        }
        if (call.method == 'saveAppSettings') {
          final args = call.arguments as Map<dynamic, dynamic>;
          final next = Map<String, dynamic>.from(args['settings'] as Map);
          nativeStore = next;
          return Map<String, dynamic>.from(nativeStore);
        }
        if (call.method == 'resetAppSettings') {
          nativeStore = const AppSettings().toMap();
          return Map<String, dynamic>.from(nativeStore);
        }
        if (call.method == 'previewScanTone') {
          return true;
        }
        return null;
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('load, update, resetDefaults, and previewScanTone sync properly', () async {
      final loaded = await AppSettingsService.load(force: true);
      expect(loaded, const AppSettings());

      final updated = await AppSettingsService.update(
        loaded.copyWith(
          barcodeSoundVolume: 55,
          barcodePostScanDupDialogEnabled: false,
        ),
      );
      expect(updated.barcodeSoundVolume, 55);
      expect(updated.barcodePostScanDupDialogEnabled, isFalse);
      expect(AppSettingsService.current.barcodeSoundVolume, 55);

      await AppSettingsService.previewScanTone(
        BarcodeScanToneOutcome.duplicateShared,
        volume: 60,
      );
      final previewCall = recordedCalls.lastWhere((c) => c.method == 'previewScanTone');
      expect((previewCall.arguments as Map)['outcome'], BarcodeScanToneOutcome.duplicateShared);
      expect((previewCall.arguments as Map)['volume'], 60);

      final reset = await AppSettingsService.resetDefaults();
      expect(reset, const AppSettings());
      expect(AppSettingsService.current, const AppSettings());
    });
  });
}
