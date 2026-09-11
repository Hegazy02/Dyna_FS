import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:geolocator/geolocator.dart';

/// How ready the device is to report location.
enum TrackingReadiness {
  /// Background ("Allow all the time") location granted. Fully reliable.
  ready,

  /// Foreground-only location. Tracking still works while the service runs,
  /// but Android will cut it off after a reboot or a long background stint.
  foregroundOnly,

  /// The user has location switched off device-wide.
  locationServiceDisabled,

  /// Refused, but we are still allowed to ask again.
  denied,

  /// Refused permanently ("Don't allow" twice, or blocked by policy). Only the
  /// system settings screen can undo this.
  permanentlyDenied,
}

/// Sequences the runtime permissions this app needs, in the order Android
/// actually accepts them.
///
/// The awkward part is background location. Since Android 11 (API 30) the
/// system silently denies any in-app request for `ACCESS_BACKGROUND_LOCATION`
/// that is bundled with the foreground request, and it will only grant it from
/// the app's own settings page. So the flow has to be:
///
///   1. ask for foreground location and get it,
///   2. then send the user to settings to upgrade to "Allow all the time".
///
/// On API 29 the upgrade can still be granted by a normal dialog, and below
/// API 29 background location does not exist as a separate grant at all.
class PermissionGate {
  const PermissionGate._();

  static int? _sdkInt;

  /// Android API level, cached. Returns 0 on non-Android platforms.
  static Future<int> androidSdkInt() async {
    if (!Platform.isAndroid) return 0;
    final cached = _sdkInt;
    if (cached != null) return cached;

    final info = await DeviceInfoPlugin().androidInfo;
    return _sdkInt = info.version.sdkInt;
  }

  /// Read-only status check. Shows no dialogs, so it is safe on every resume.
  static Future<TrackingReadiness> check() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      return TrackingReadiness.locationServiceDisabled;
    }
    return _classify(await Geolocator.checkPermission());
  }

  /// Interactive flow. Safe to call more than once; each step is a no-op when
  /// the permission is already held.
  static Future<TrackingReadiness> request() async {
    // Android 13+ needs POST_NOTIFICATIONS before the foreground service
    // notification is visible. The service still runs without it, but an
    // invisible tracker is exactly what users report as spyware, so ask first.
    if (await androidSdkInt() >= 33) {
      final status = await FlutterForegroundTask.checkNotificationPermission();
      if (status != NotificationPermission.granted) {
        await FlutterForegroundTask.requestNotificationPermission();
      }
    }

    if (!await Geolocator.isLocationServiceEnabled()) {
      return TrackingReadiness.locationServiceDisabled;
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.denied) {
      return TrackingReadiness.denied;
    }
    if (permission == LocationPermission.deniedForever) {
      return TrackingReadiness.permanentlyDenied;
    }

    // API 29 is the one release where the background upgrade can be granted
    // from an in-app dialog. Geolocator adds ACCESS_BACKGROUND_LOCATION to the
    // request automatically because it is declared in our manifest.
    final sdkInt = await androidSdkInt();
    if (permission == LocationPermission.whileInUse && sdkInt == 29) {
      permission = await Geolocator.requestPermission();
    }

    return _classify(permission);
  }

  /// Asks the OS to stop dozing this app. Aggressive OEM battery managers
  /// (Xiaomi, Oppo, Huawei, Samsung) are the single biggest cause of
  /// background tracking dying overnight, and this is the one exemption that
  /// can be requested from code rather than from a settings menu.
  static Future<bool> ensureBatteryExemption() async {
    if (!Platform.isAndroid) return true;
    try {
      if (await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
        return true;
      }
      return await FlutterForegroundTask.requestIgnoreBatteryOptimization();
    } catch (_) {
      return false;
    }
  }

  /// Opens this app's system settings page, where "Allow all the time" and a
  /// permanently denied permission can both be fixed.
  static Future<void> openAppSettings() => Geolocator.openAppSettings();

  /// Opens the device-wide location toggle.
  static Future<void> openLocationSettings() =>
      Geolocator.openLocationSettings();

  static TrackingReadiness _classify(LocationPermission permission) {
    switch (permission) {
      case LocationPermission.always:
        return TrackingReadiness.ready;
      case LocationPermission.whileInUse:
        return TrackingReadiness.foregroundOnly;
      case LocationPermission.denied:
        return TrackingReadiness.denied;
      case LocationPermission.deniedForever:
        return TrackingReadiness.permanentlyDenied;
      case LocationPermission.unableToDetermine:
        return TrackingReadiness.denied;
    }
  }
}
