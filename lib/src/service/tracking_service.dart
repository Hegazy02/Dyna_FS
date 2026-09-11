import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import '../config/app_config.dart';
import 'location_task_handler.dart';

/// Owns the lifecycle of the background tracking service from the UI isolate.
class TrackingService {
  const TrackingService._();

  static const int serviceId = 7411;

  /// Must run before [start], and again in the background isolate's engine.
  /// Cheap and idempotent, so `main()` just always calls it.
  static void init() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'dyn_gis_tracking',
        channelName: 'Location tracking',
        channelDescription:
            'Keeps location reporting running while the app is closed.',
        // LOW keeps the required notification silent and collapsed. Anything
        // higher buzzes the user every time the text updates.
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        onlyAlertOnce: true,
        enableVibration: false,
        playSound: false,
        showWhen: false,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        // Native-driven heartbeat; survives Doze better than a Dart Timer.
        eventAction: ForegroundTaskEventAction.repeat(
          AppConfig.heartbeatSeconds * 1000,
        ),
        autoRunOnBoot: true,
        autoRunOnMyPackageReplaced: true,
        allowWakeLock: true,
        allowWifiLock: true,
        allowAutoRestart: true,
        // Keep reporting after the app is swiped out of recents. This is the
        // difference between a tracker and a stopwatch.
        stopWithTask: false,
      ),
    );
  }

  static Future<bool> get isRunning => FlutterForegroundTask.isRunningService;

  /// Starts the service if it is not already up. Returns false on failure.
  static Future<bool> start() async {
    if (await isRunning) return true;

    final result = await FlutterForegroundTask.startService(
      serviceId: serviceId,
      // Deliberately `location` only, with no `dataSync`.
      //
      // Android 15 caps dataSync foreground services at roughly six hours per
      // day and then force-stops them; the location type has no such timeout.
      // Our uploads are incidental to location tracking, so declaring only
      // `location` is both accurate and the difference between a tracker that
      // runs all shift and one that dies mid-afternoon.
      serviceTypes: <ForegroundServiceTypes>[ForegroundServiceTypes.location],
      notificationTitle: 'Location sharing is on',
      notificationText: 'Starting...',
      callback: startLocationTask,
    );

    return result is ServiceRequestSuccess;
  }

  static Future<bool> stop() async {
    final result = await FlutterForegroundTask.stopService();
    return result is ServiceRequestSuccess;
  }

  /// Asks the service to drain its queue immediately.
  static void requestFlush() =>
      FlutterForegroundTask.sendDataToTask(TaskCommand.flushNow);

  /// Asks the service to broadcast a fresh status snapshot.
  static void requestStatus() =>
      FlutterForegroundTask.sendDataToTask(TaskCommand.reportStatus);
}
