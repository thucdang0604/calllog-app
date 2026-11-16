import 'package:flutter/foundation.dart';

/// Tên giá trị tương ứng với enum `BarcodeScanOutcome` ở native Android.
class BarcodeScanToneOutcome {
  static const String newCode = 'NEW_CODE';
  static const String duplicatePending = 'DUPLICATE_PENDING';
  static const String duplicateSession = 'DUPLICATE_SESSION';
  static const String duplicateShared = 'DUPLICATE_SHARED';
}

/// Cấu hình tập trung cho âm thanh, rung và các cảnh báo của ứng dụng.
@immutable
class AppSettings {
  const AppSettings({
    this.soundMasterEnabled = true,
    this.barcodeSoundEnabled = true,
    this.barcodeSoundVolume = 90,
    this.barcodeSoundNewEnabled = true,
    this.barcodeSoundPendingEnabled = true,
    this.barcodeSoundSessionEnabled = true,
    this.barcodeSoundSharedEnabled = true,
    this.timeMarkShutterSoundEnabled = true,
    this.vibrationMasterEnabled = true,
    this.barcodeVibrationEnabled = true,
    this.timeMarkVibrationEnabled = true,
    this.overlayVibrationEnabled = true,
    this.barcodeCameraDupWarningEnabled = true,
    this.barcodePostScanDupDialogEnabled = true,
    this.defaultSmsWarningEnabled = true,
    this.callRecordingSetupWarningEnabled = true,
    this.callRecordingSilenceWarningEnabled = true,
    this.autoCheckUpdateEnabled = true,
  });

  // Âm thanh
  final bool soundMasterEnabled;
  final bool barcodeSoundEnabled;
  final int barcodeSoundVolume;
  final bool barcodeSoundNewEnabled;
  final bool barcodeSoundPendingEnabled;
  final bool barcodeSoundSessionEnabled;
  final bool barcodeSoundSharedEnabled;
  final bool timeMarkShutterSoundEnabled;

  // Rung
  final bool vibrationMasterEnabled;
  final bool barcodeVibrationEnabled;
  final bool timeMarkVibrationEnabled;
  final bool overlayVibrationEnabled;

  // Cảnh báo & thông báo nhắc
  final bool barcodeCameraDupWarningEnabled;
  final bool barcodePostScanDupDialogEnabled;
  final bool defaultSmsWarningEnabled;
  final bool callRecordingSetupWarningEnabled;
  final bool callRecordingSilenceWarningEnabled;
  final bool autoCheckUpdateEnabled;

  bool isBarcodeSoundActiveFor(String outcome) {
    if (!soundMasterEnabled || !barcodeSoundEnabled) return false;
    switch (outcome) {
      case BarcodeScanToneOutcome.newCode:
        return barcodeSoundNewEnabled;
      case BarcodeScanToneOutcome.duplicatePending:
        return barcodeSoundPendingEnabled;
      case BarcodeScanToneOutcome.duplicateSession:
        return barcodeSoundSessionEnabled;
      case BarcodeScanToneOutcome.duplicateShared:
        return barcodeSoundSharedEnabled;
      default:
        return true;
    }
  }

  bool get isTimeMarkShutterSoundActive =>
      soundMasterEnabled && timeMarkShutterSoundEnabled;

  bool get isBarcodeVibrationActive =>
      vibrationMasterEnabled && barcodeVibrationEnabled;

  bool get isTimeMarkVibrationActive =>
      vibrationMasterEnabled && timeMarkVibrationEnabled;

  bool get isOverlayVibrationActive =>
      vibrationMasterEnabled && overlayVibrationEnabled;

  factory AppSettings.fromMap(Map<dynamic, dynamic>? raw) {
    if (raw == null) return const AppSettings();

    bool readBool(String key, bool fallback) {
      final value = raw[key];
      return value is bool ? value : fallback;
    }

    int readInt(String key, int fallback) {
      final value = raw[key];
      if (value is num) return value.toInt().clamp(0, 100);
      return fallback;
    }

    return AppSettings(
      soundMasterEnabled: readBool('soundMasterEnabled', true),
      barcodeSoundEnabled: readBool('barcodeSoundEnabled', true),
      barcodeSoundVolume: readInt('barcodeSoundVolume', 90),
      barcodeSoundNewEnabled: readBool('barcodeSoundNewEnabled', true),
      barcodeSoundPendingEnabled: readBool('barcodeSoundPendingEnabled', true),
      barcodeSoundSessionEnabled: readBool('barcodeSoundSessionEnabled', true),
      barcodeSoundSharedEnabled: readBool('barcodeSoundSharedEnabled', true),
      timeMarkShutterSoundEnabled: readBool('timeMarkShutterSoundEnabled', true),
      vibrationMasterEnabled: readBool('vibrationMasterEnabled', true),
      barcodeVibrationEnabled: readBool('barcodeVibrationEnabled', true),
      timeMarkVibrationEnabled: readBool('timeMarkVibrationEnabled', true),
      overlayVibrationEnabled: readBool('overlayVibrationEnabled', true),
      barcodeCameraDupWarningEnabled: readBool('barcodeCameraDupWarningEnabled', true),
      barcodePostScanDupDialogEnabled: readBool('barcodePostScanDupDialogEnabled', true),
      defaultSmsWarningEnabled: readBool('defaultSmsWarningEnabled', true),
      callRecordingSetupWarningEnabled: readBool('callRecordingSetupWarningEnabled', true),
      callRecordingSilenceWarningEnabled: readBool('callRecordingSilenceWarningEnabled', true),
      autoCheckUpdateEnabled: readBool('autoCheckUpdateEnabled', true),
    );
  }

  Map<String, dynamic> toMap() => <String, dynamic>{
        'soundMasterEnabled': soundMasterEnabled,
        'barcodeSoundEnabled': barcodeSoundEnabled,
        'barcodeSoundVolume': barcodeSoundVolume.clamp(0, 100),
        'barcodeSoundNewEnabled': barcodeSoundNewEnabled,
        'barcodeSoundPendingEnabled': barcodeSoundPendingEnabled,
        'barcodeSoundSessionEnabled': barcodeSoundSessionEnabled,
        'barcodeSoundSharedEnabled': barcodeSoundSharedEnabled,
        'timeMarkShutterSoundEnabled': timeMarkShutterSoundEnabled,
        'vibrationMasterEnabled': vibrationMasterEnabled,
        'barcodeVibrationEnabled': barcodeVibrationEnabled,
        'timeMarkVibrationEnabled': timeMarkVibrationEnabled,
        'overlayVibrationEnabled': overlayVibrationEnabled,
        'barcodeCameraDupWarningEnabled': barcodeCameraDupWarningEnabled,
        'barcodePostScanDupDialogEnabled': barcodePostScanDupDialogEnabled,
        'defaultSmsWarningEnabled': defaultSmsWarningEnabled,
        'callRecordingSetupWarningEnabled': callRecordingSetupWarningEnabled,
        'callRecordingSilenceWarningEnabled': callRecordingSilenceWarningEnabled,
        'autoCheckUpdateEnabled': autoCheckUpdateEnabled,
      };

  AppSettings copyWith({
    bool? soundMasterEnabled,
    bool? barcodeSoundEnabled,
    int? barcodeSoundVolume,
    bool? barcodeSoundNewEnabled,
    bool? barcodeSoundPendingEnabled,
    bool? barcodeSoundSessionEnabled,
    bool? barcodeSoundSharedEnabled,
    bool? timeMarkShutterSoundEnabled,
    bool? vibrationMasterEnabled,
    bool? barcodeVibrationEnabled,
    bool? timeMarkVibrationEnabled,
    bool? overlayVibrationEnabled,
    bool? barcodeCameraDupWarningEnabled,
    bool? barcodePostScanDupDialogEnabled,
    bool? defaultSmsWarningEnabled,
    bool? callRecordingSetupWarningEnabled,
    bool? callRecordingSilenceWarningEnabled,
    bool? autoCheckUpdateEnabled,
  }) {
    return AppSettings(
      soundMasterEnabled: soundMasterEnabled ?? this.soundMasterEnabled,
      barcodeSoundEnabled: barcodeSoundEnabled ?? this.barcodeSoundEnabled,
      barcodeSoundVolume: (barcodeSoundVolume ?? this.barcodeSoundVolume).clamp(0, 100),
      barcodeSoundNewEnabled: barcodeSoundNewEnabled ?? this.barcodeSoundNewEnabled,
      barcodeSoundPendingEnabled: barcodeSoundPendingEnabled ?? this.barcodeSoundPendingEnabled,
      barcodeSoundSessionEnabled: barcodeSoundSessionEnabled ?? this.barcodeSoundSessionEnabled,
      barcodeSoundSharedEnabled: barcodeSoundSharedEnabled ?? this.barcodeSoundSharedEnabled,
      timeMarkShutterSoundEnabled: timeMarkShutterSoundEnabled ?? this.timeMarkShutterSoundEnabled,
      vibrationMasterEnabled: vibrationMasterEnabled ?? this.vibrationMasterEnabled,
      barcodeVibrationEnabled: barcodeVibrationEnabled ?? this.barcodeVibrationEnabled,
      timeMarkVibrationEnabled: timeMarkVibrationEnabled ?? this.timeMarkVibrationEnabled,
      overlayVibrationEnabled: overlayVibrationEnabled ?? this.overlayVibrationEnabled,
      barcodeCameraDupWarningEnabled:
          barcodeCameraDupWarningEnabled ?? this.barcodeCameraDupWarningEnabled,
      barcodePostScanDupDialogEnabled:
          barcodePostScanDupDialogEnabled ?? this.barcodePostScanDupDialogEnabled,
      defaultSmsWarningEnabled: defaultSmsWarningEnabled ?? this.defaultSmsWarningEnabled,
      callRecordingSetupWarningEnabled:
          callRecordingSetupWarningEnabled ?? this.callRecordingSetupWarningEnabled,
      callRecordingSilenceWarningEnabled:
          callRecordingSilenceWarningEnabled ?? this.callRecordingSilenceWarningEnabled,
      autoCheckUpdateEnabled: autoCheckUpdateEnabled ?? this.autoCheckUpdateEnabled,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AppSettings &&
          runtimeType == other.runtimeType &&
          soundMasterEnabled == other.soundMasterEnabled &&
          barcodeSoundEnabled == other.barcodeSoundEnabled &&
          barcodeSoundVolume == other.barcodeSoundVolume &&
          barcodeSoundNewEnabled == other.barcodeSoundNewEnabled &&
          barcodeSoundPendingEnabled == other.barcodeSoundPendingEnabled &&
          barcodeSoundSessionEnabled == other.barcodeSoundSessionEnabled &&
          barcodeSoundSharedEnabled == other.barcodeSoundSharedEnabled &&
          timeMarkShutterSoundEnabled == other.timeMarkShutterSoundEnabled &&
          vibrationMasterEnabled == other.vibrationMasterEnabled &&
          barcodeVibrationEnabled == other.barcodeVibrationEnabled &&
          timeMarkVibrationEnabled == other.timeMarkVibrationEnabled &&
          overlayVibrationEnabled == other.overlayVibrationEnabled &&
          barcodeCameraDupWarningEnabled == other.barcodeCameraDupWarningEnabled &&
          barcodePostScanDupDialogEnabled == other.barcodePostScanDupDialogEnabled &&
          defaultSmsWarningEnabled == other.defaultSmsWarningEnabled &&
          callRecordingSetupWarningEnabled == other.callRecordingSetupWarningEnabled &&
          callRecordingSilenceWarningEnabled == other.callRecordingSilenceWarningEnabled &&
          autoCheckUpdateEnabled == other.autoCheckUpdateEnabled;

  @override
  int get hashCode => Object.hash(
        soundMasterEnabled,
        barcodeSoundEnabled,
        barcodeSoundVolume,
        barcodeSoundNewEnabled,
        barcodeSoundPendingEnabled,
        barcodeSoundSessionEnabled,
        barcodeSoundSharedEnabled,
        timeMarkShutterSoundEnabled,
        vibrationMasterEnabled,
        barcodeVibrationEnabled,
        timeMarkVibrationEnabled,
        overlayVibrationEnabled,
        barcodeCameraDupWarningEnabled,
        barcodePostScanDupDialogEnabled,
        defaultSmsWarningEnabled,
        callRecordingSetupWarningEnabled,
        callRecordingSilenceWarningEnabled,
        autoCheckUpdateEnabled,
      );
}
