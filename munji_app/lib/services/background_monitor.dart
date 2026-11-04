import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

/// Keeps monitoring running with the screen off.
///
/// Android: starts MonitorService (android/app/src/main/kotlin), a
/// foreground service with a "Munji is monitoring" notification. Without
/// it Android suspends or kills the app soon after the screen locks, and
/// the caregiver sees "no recent data".
///
/// iOS: nothing to start. The `bluetooth-central` background mode in
/// Info.plist lets iOS keep the link to the patch and wake the app for its
/// data. (iOS still stops everything if the user swipes the app away.)
class BackgroundMonitor {
  BackgroundMonitor._();

  static const _channel = MethodChannel('munji/monitor');
  static bool _running = false;
  static int? _sdk;

  static bool get _android =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static bool get isRunning => _running;

  /// Android API level, or null elsewhere. Cached after the first call.
  static Future<int?> androidSdk() async {
    if (!_android) return null;
    if (_sdk != null) return _sdk;
    try {
      _sdk = await _channel.invokeMethod<int>('sdkInt');
    } catch (e) {
      debugPrint('[monitor] sdkInt failed: $e');
    }
    return _sdk;
  }

  /// Start, for a signed-in patient with a paired patch. Safe to call again.
  static Future<void> start({required bool isArabic}) async {
    if (!_android || _running) return;

    // Android 14 refuses this kind of service without the Bluetooth
    // permission, so never try before pairing has granted it.
    if (!await Permission.bluetoothConnect.isGranted) return;

    // Android 13+: without this the service still runs, but the
    // notification is hidden. Asked once; a "no" is respected.
    final n = await Permission.notification.status;
    if (n.isDenied) await Permission.notification.request();

    try {
      final ok = await _channel.invokeMethod<bool>('start', {
        'title': isArabic ? 'منجي يراقب' : 'Munji is monitoring',
        'text': isArabic
            ? 'المراقبة مستمرة والشاشة مقفلة'
            : 'Monitoring continues with the screen off',
        'channel': isArabic ? 'المراقبة' : 'Monitoring',
      });
      _running = ok == true;
    } catch (e) {
      debugPrint('[monitor] start failed: $e');
    }
  }

  /// Stop: sign-out, forgotten device, deleted account.
  static Future<void> stop() async {
    if (!_android || !_running) return;
    try {
      await _channel.invokeMethod<bool>('stop');
    } catch (e) {
      debugPrint('[monitor] stop failed: $e');
    }
    _running = false;
  }
}
