import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:geolocator/geolocator.dart';

import '../config/app_config.dart';
import '../data/auth_repository.dart';
import '../data/ping_queue.dart';
import '../data/tracking_api.dart';
import '../models/auth_session.dart';
import '../models/http_exchange.dart';
import '../models/location_ping.dart';

/// Entry point for the background isolate.
///
/// `vm:entry-point` is mandatory: without it, tree-shaking strips this function
/// from release builds and the service starts into nothing — the classic
/// "works in debug, dead in the APK" failure.
@pragma('vm:entry-point')
void startLocationTask() {
  FlutterForegroundTask.setTaskHandler(LocationTaskHandler());
}

/// Commands the UI isolate can send to the running service.
class TaskCommand {
  const TaskCommand._();

  static const String flushNow = 'flush-now';
  static const String reportStatus = 'report-status';
}

/// Captures fixes and ships them to the backend.
///
/// This runs inside the foreground service's own Flutter engine, not the UI
/// isolate. That is the whole point: the activity can be destroyed, the app
/// swiped out of recents, or the screen off, and this keeps running.
class LocationTaskHandler extends TaskHandler {
  /// Most recent upload attempts, newest first, for the on-screen debug log.
  final List<HttpExchange> _exchanges = <HttpExchange>[];

  late final TrackingApi _api = TrackingApi(onExchange: _rememberExchange);
  final AuthRepository _auth = AuthRepository();
  final Battery _battery = Battery();

  /// Assigned first thing in [onStart]. `PingQueue.open` handles its own
  /// failures and always returns a usable queue, so this is never unset by the
  /// time any callback can run.
  late PingQueue _queue;

  /// The signed-in user, re-read from storage on every tick so a fresh login
  /// in the UI isolate is picked up without restarting the service.
  AuthSession? _session;

  /// Set when the server refuses the token. Uploads pause (fixes keep
  /// queueing) until the user signs in again.
  bool _reauthRequired = false;

  StreamSubscription<Position>? _positionSub;
  Position? _lastPosition;
  DateTime? _lastRecordedAt;

  /// The last fix actually queued, as opposed to the last one received. The
  /// distance gate and the derived-velocity fallback both measure from here.
  Position? _lastReportedPosition;

  bool _ticking = false;
  bool _flushing = false;
  int _consecutiveFailures = 0;
  DateTime? _retryAfter;

  int _delivered = 0;
  int _discarded = 0;
  DateTime? _lastDeliveryAt;
  String? _lastError;

  int? _cachedBattery;
  DateTime? _batteryReadAt;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    _queue = await PingQueue.open();
    if (!_queue.isDurable) {
      _lastError = 'SQLite unavailable - queueing in memory only';
    }

    await _reloadSession();
    await _subscribeToPositions();
    await _capture(PingTrigger.start);
    unawaited(_flush());
  }

  void _rememberExchange(HttpExchange exchange) {
    _exchanges.insert(0, exchange);
    if (_exchanges.length > AppConfig.debugExchangeCount) {
      _exchanges.removeRange(AppConfig.debugExchangeCount, _exchanges.length);
    }
  }

  /// Re-reads the cached session. Cheap, and it means a token minted by a
  /// fresh login is used on the very next upload without a service restart.
  Future<void> _reloadSession() async {
    try {
      _session = await _auth.load();
      _reauthRequired = await _auth.isReauthRequired();
    } catch (error) {
      _lastError = 'session: $error';
    }
  }

  /// Fires every `heartbeatSeconds`, driven by the native service rather than a
  /// Dart timer, so it survives Doze better than `Timer.periodic` would.
  @override
  void onRepeatEvent(DateTime timestamp) {
    unawaited(_tick());
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    // Wrapped because a stop that races a still-running onStart would find the
    // queue unassigned, and throwing here leaves the service half-torn-down.
    try {
      await _positionSub?.cancel();
      _positionSub = null;

      // Best-effort final drain so a clean stop does not strand the tail.
      await _flush(force: true);
      await _queue.close();
    } catch (error) {
      debugPrint('shutdown: $error');
    } finally {
      _api.dispose();
    }
  }

  @override
  void onReceiveData(Object data) {
    if (data == TaskCommand.flushNow) {
      unawaited(_flush(force: true));
    } else if (data == TaskCommand.reportStatus) {
      unawaited(_publishStatus());
    }
  }

  Future<void> _tick() async {
    if (_ticking) return; // a slow fix must not stack up ticks
    _ticking = true;
    try {
      // The stream can die silently (permission revoked, provider reset).
      // Re-arm it here so a single failure is not permanent.
      if (_positionSub == null) await _subscribeToPositions();

      await _reloadSession();
      await _capture(PingTrigger.heartbeat);
      await _flush();
      await _publishStatus();
    } finally {
      _ticking = false;
    }
  }

  Future<void> _subscribeToPositions() async {
    try {
      await _positionSub?.cancel();

      // Both platforms are asked to sample continuously, with no native
      // distance filter, and the reporting cadence is enforced in Dart by
      // [_hasMovedEnough] instead. Pushing the filter down into the platform
      // request is what starves the velocity solution: Android turns
      // `intervalDuration` into `setMinUpdateIntervalMillis`, duty-cycles the
      // GNSS receiver between updates, and then reports fixes with no speed
      // and no bearing. See [AppConfig.gpsSampleSeconds].
      final LocationSettings settings = Platform.isAndroid
          ? AndroidSettings(
              accuracy: LocationAccuracy.high,
              distanceFilter: 0,
              intervalDuration: Duration(seconds: AppConfig.gpsSampleSeconds),
              // No foregroundNotificationConfig on purpose: this service
              // already runs as a `location` foreground service via
              // flutter_foreground_task. Setting it here starts a *second*
              // service and shows a duplicate permanent notification.
            )
          : AppleSettings(
              accuracy: LocationAccuracy.high,
              distanceFilter: 0,
              allowBackgroundLocationUpdates: true,
              pauseLocationUpdatesAutomatically: false,
              showBackgroundLocationIndicator: true,
            );

      _positionSub =
          Geolocator.getPositionStream(locationSettings: settings).listen(
        (Position position) {
          // Every fix updates _lastPosition, so the heartbeat always has a
          // genuinely fresh one to reuse, but only a fix that clears the
          // distance gate becomes a ping.
          _lastPosition = position;
          if (_hasMovedEnough(position)) {
            unawaited(_record(position, PingTrigger.movement));
          }
        },
        onError: (Object error) {
          _lastError = 'position stream: $error';
          _positionSub?.cancel();
          _positionSub = null; // picked back up by the next tick
        },
        cancelOnError: false,
      );
    } catch (error) {
      _lastError = 'subscribe: $error';
      _positionSub = null;
    }
  }

  Future<void> _capture(PingTrigger trigger) async {
    // While the device is moving, the position stream is already delivering
    // fresh fixes. Firing a second high-accuracy request on top of that wakes
    // the GPS twice for the same information, so reuse a recent fix instead.
    // When the device is parked the stream goes quiet, the last fix ages out,
    // and the active request below runs as normal.
    final recent = _lastPosition;
    if (trigger == PingTrigger.heartbeat &&
        recent != null &&
        _isFresh(recent)) {
      await _record(recent, trigger);
      return;
    }

    try {
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 25),
        ),
      );
      _lastPosition = position;
      await _record(position, trigger);
    } catch (error) {
      _lastError = 'capture: $error';

      // Indoors or in a tunnel a fresh fix can simply not arrive. Reporting
      // the last known position keeps the "device is alive" signal flowing;
      // recordedAt still carries the real age of the fix, so the backend can
      // tell a stale point from a current one.
      final last = _lastPosition;
      if (last != null) await _record(last, trigger);
    }
  }

  /// True when a fix is recent enough to stand in for a new one — under half
  /// the heartbeat, so a stationary device still gets a genuine fresh fix
  /// every interval.
  bool _isFresh(Position position) {
    final age = DateTime.now().toUtc().difference(position.timestamp.toUtc());
    return !age.isNegative && age.inSeconds * 2 < AppConfig.heartbeatSeconds;
  }

  /// True when [position] is far enough from the last reported fix to earn a
  /// movement ping. This is the reporting cadence that used to be the native
  /// `distanceFilter`; moving it into Dart is what lets the platform keep
  /// sampling continuously without multiplying the pings we send.
  bool _hasMovedEnough(Position position) {
    final last = _lastReportedPosition;
    if (last == null) return true;

    final metres = Geolocator.distanceBetween(
      last.latitude,
      last.longitude,
      position.latitude,
      position.longitude,
    );

    return metres >= AppConfig.distanceFilterMeters;
  }

  Future<void> _record(Position position, PingTrigger trigger) async {
    final fixTime = position.timestamp.toUtc();

    // A fix carries the moment it was taken, so an identical timestamp means
    // the exact same reading — which happens when _capture falls back to the
    // last known position several times in a row. Recording it again would
    // only inflate the queue with rows the backend has to deduplicate anyway.
    if (_lastRecordedAt == fixTime) return;

    final previous = _lastReportedPosition;

    try {
      await _queue.enqueue(
        LocationPing.fromPosition(
          position,
          trigger: trigger,
          batteryLevel: await _batteryLevel(),
          // Let the ping fall back to a computed velocity when the receiver
          // hands us a fix without one — indoors, on the first fix after a
          // cold start, or any time the Doppler solution has not converged.
          previous: previous,
        ),
        // Stamped with whoever is signed in, so this fix can never be
        // uploaded under a different account later.
        userId: _session?.userId ?? '',
      );
      _lastRecordedAt = fixTime;
      _lastReportedPosition = position;
    } catch (error) {
      _lastError = 'enqueue: $error';
    }
  }

  Future<int?> _batteryLevel() async {
    final readAt = _batteryReadAt;
    if (readAt != null &&
        DateTime.now().difference(readAt) < const Duration(seconds: 60)) {
      return _cachedBattery;
    }
    try {
      _cachedBattery = await _battery.batteryLevel;
    } catch (_) {
      _cachedBattery = null;
    }
    _batteryReadAt = DateTime.now();
    return _cachedBattery;
  }

  /// Drains the queue oldest-first, honouring exponential backoff so an
  /// offline device does not burn battery retrying every 30 seconds.
  Future<void> _flush({bool force = false}) async {
    if (_flushing) return;

    // Nobody signed in yet, or the server already refused this token. Either
    // way the fixes stay queued — they are still good data, they just cannot
    // be attributed or authorised until the user signs in.
    final session = _session;
    if (session == null || _reauthRequired) return;

    final now = DateTime.now();
    final retryAfter = _retryAfter;
    if (!force && retryAfter != null && now.isBefore(retryAfter)) return;

    _flushing = true;
    try {
      while (true) {
        final batch = await _queue.peek(
          AppConfig.batchSize,
          userId: session.userId,
        );
        if (batch.isEmpty) break;

        final sent = await _deliver(batch);
        if (!sent) {
          _consecutiveFailures++;
          _retryAfter = DateTime.now().add(_backoff());
          break;
        }

        _consecutiveFailures = 0;
        _retryAfter = null;
        if (batch.length < AppConfig.batchSize) break;
      }
    } catch (error) {
      _lastError = 'flush: $error';
    } finally {
      _flushing = false;
    }
  }

  /// Returns true when the batch left the queue (delivered or discarded),
  /// false when it should be retried later.
  Future<bool> _deliver(List<QueuedPing> batch) async {
    final session = _session;
    if (session == null) return false;

    final result = await _api.send(
      session: session,
      pings: batch.map((q) => q.ping).toList(growable: false),
    );

    switch (result) {
      case UploadResult.unauthorized:
        // The token is dead. Keep every queued fix, stop trying, and flag the
        // UI so the login screen appears next time the app is opened.
        _reauthRequired = true;
        _lastError = 'sign-in required';
        await _auth.markReauthRequired();
        return false;

      case UploadResult.accepted:
        await _queue.remove(batch.map((q) => q.id).toList(growable: false));
        _delivered += batch.length;
        _lastDeliveryAt = DateTime.now();
        _lastError = null;
        return true;

      case UploadResult.retryable:
        return false;

      case UploadResult.rejected:
        if (batch.length == 1) {
          // One ping the server refuses outright is a real poison pill; drop
          // it so the rest of the backlog can move.
          await _queue.remove(<int>[batch.first.id]);
          _discarded++;
          _lastError = 'server rejected a ping; discarded';
          return true;
        }
        // More likely an oversized batch than 100 bad points, so halve and
        // retry rather than binning the lot.
        final mid = batch.length ~/ 2;
        if (!await _deliver(batch.sublist(0, mid))) return false;
        return _deliver(batch.sublist(mid));
    }
  }

  Duration _backoff() {
    final exponent = math.min(_consecutiveFailures, 6);
    final seconds = math.min(
      AppConfig.maxBackoffSeconds,
      AppConfig.heartbeatSeconds * (1 << exponent),
    );
    return Duration(seconds: seconds);
  }

  Future<void> _publishStatus() async {
    final session = _session;
    final pending = session == null
        ? await _queue.length()
        : await _queue.pendingFor(session.userId);

    FlutterForegroundTask.sendDataToMain(jsonEncode(<String, dynamic>{
      'userId': session?.userId ?? '',
      'signedInAs': session?.fullName ?? session?.username ?? '',
      'salesmanId': session?.salesmanId ?? '',
      'reauthRequired': _reauthRequired,
      'pending': pending,
      'delivered': _delivered,
      'discarded': _discarded,
      'lastDeliveryAt': _lastDeliveryAt?.toIso8601String(),
      'lastFixAt': _lastPosition?.timestamp.toUtc().toIso8601String(),
      'lastLat': _lastPosition?.latitude,
      'lastLng': _lastPosition?.longitude,
      'streaming': _positionSub != null,
      'durableQueue': _queue.isDurable,
      'configured': AppConfig.isConfigured,
      'lastError': _lastError,
      'exchanges':
          _exchanges.map((e) => e.toJson()).toList(growable: false),
    }));

    // Surfacing backlog in the notification makes a field device debuggable
    // without a cable: a number that only grows means uploads are failing.
    final String text;
    if (_reauthRequired) {
      text = 'Sign in required - $pending queued';
    } else if (session == null) {
      text = 'Not signed in - $pending queued';
    } else if (pending == 0) {
      text = 'Up to date';
    } else {
      text = '$pending queued${_consecutiveFailures > 0 ? ' - retrying' : ''}';
    }
    try {
      await FlutterForegroundTask.updateService(notificationText: text);
    } catch (error) {
      debugPrint('notification update failed: $error');
    }
  }
}
