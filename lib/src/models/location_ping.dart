import 'dart:convert';
import 'dart:math' as math;

import 'package:geolocator/geolocator.dart';

import '../config/app_config.dart';

/// Why a fix was recorded. Useful server-side for separating "the vehicle
/// moved" from "the device is still alive but parked".
enum PingTrigger {
  /// First fix after the service (re)started.
  start,

  /// The device moved further than the configured distance filter.
  movement,

  /// The periodic keep-alive fix.
  heartbeat,
}

/// One location sample, as stored in the offline queue and sent to the backend.
class LocationPing {
  const LocationPing({
    required this.latitude,
    required this.longitude,
    required this.recordedAt,
    required this.trigger,
    this.accuracy,
    this.altitude,
    this.altitudeAccuracy,
    this.speed,
    this.speedAccuracy,
    this.heading,
    this.isMocked = false,
    this.batteryLevel,
  });

  /// Builds a ping from a geolocator fix, dropping fields the platform flagged
  /// as unavailable rather than shipping their zero-value placeholders.
  factory LocationPing.fromPosition(
    Position position, {
    required PingTrigger trigger,
    int? batteryLevel,
    Position? previous,
  }) {
    final derived = _derive(position, previous);

    return LocationPing(
      latitude: position.latitude,
      longitude: position.longitude,
      recordedAt: position.timestamp.toUtc(),
      trigger: trigger,
      accuracy: position.hasAccuracy ? position.accuracy : null,
      altitude: position.hasAltitude ? position.altitude : null,
      altitudeAccuracy:
          position.hasAltitudeAccuracy ? position.altitudeAccuracy : null,
      speed: position.hasSpeed ? position.speed : derived?.speed,
      speedAccuracy: position.hasSpeedAccuracy ? position.speedAccuracy : null,
      heading: position.hasHeading ? position.heading : derived?.heading,
      isMocked: position.isMocked,
      batteryLevel: batteryLevel,
    );
  }

  factory LocationPing.fromJson(Map<String, dynamic> json) {
    return LocationPing(
      latitude: (json['lat'] as num).toDouble(),
      longitude: (json['lng'] as num).toDouble(),
      recordedAt: DateTime.parse(json['recordedAt'] as String).toUtc(),
      trigger: PingTrigger.values.firstWhere(
        (t) => t.name == json['trigger'],
        orElse: () => PingTrigger.heartbeat,
      ),
      accuracy: (json['accuracy'] as num?)?.toDouble(),
      altitude: (json['altitude'] as num?)?.toDouble(),
      altitudeAccuracy: (json['altitudeAccuracy'] as num?)?.toDouble(),
      speed: (json['speed'] as num?)?.toDouble(),
      speedAccuracy: (json['speedAccuracy'] as num?)?.toDouble(),
      heading: (json['heading'] as num?)?.toDouble(),
      isMocked: json['isMocked'] as bool? ?? false,
      batteryLevel: json['batteryLevel'] as int?,
    );
  }

  final double latitude;
  final double longitude;

  /// When the fix was taken, in UTC. The backend should trust this over the
  /// time the request arrives: queued pings can be replayed hours late.
  final DateTime recordedAt;
  final PingTrigger trigger;

  /// Horizontal accuracy in metres. Treat large values as low-confidence.
  final double? accuracy;
  final double? altitude;
  final double? altitudeAccuracy;

  /// Metres per second.
  final double? speed;
  final double? speedAccuracy;

  /// Degrees clockwise from true north.
  final double? heading;

  /// True when the fix came from a mock provider — i.e. someone is faking GPS.
  final bool isMocked;

  /// Battery percentage at capture time, so dispatch can see a phone dying.
  final int? batteryLevel;

  /// The shape `POST /api/LocationPings/batch` expects.
  ///
  /// Deliberately narrower than [toJson]: the queue keeps every reading at
  /// full fidelity (accuracy, altitude, battery, mock flag, trigger) for
  /// diagnostics and in case the API grows fields later, while only what the
  /// endpoint actually accepts goes on the wire.
  Map<String, dynamic> toWirePing() => <String, dynamic>{
        'at': formatWireTimestamp(recordedAt),
        'lat': latitude,
        'lng': longitude,
        // Geolocator reports metres per second; the API wants km/h.
        //
        // Emitted as whole numbers, not doubles. These bind to integers
        // server-side, and System.Text.Json refuses a decimal literal for an
        // integer field even when the fraction is zero — `0.0` comes back as
        // "Speed Kmh must be a number". Integers are also the safer choice
        // either way, since .NET binds `28` to a double happily but not `28.0`
        // to an int.
        'speedKmh': _roundToInt((speed ?? 0) * 3.6),
        'headingDeg': _roundToInt(heading ?? 0),
        // The API models this as an enum and its own sample only ever uses
        // "Gps". Sending a value it does not know would fail the whole batch,
        // so every fix is reported as Gps regardless of the actual provider.
        'source': 'Gps',
      };

  /// Naive `yyyy-MM-ddTHH:mm:ss`, matching the API's own samples — no
  /// milliseconds, no offset. See [AppConfig.timestampMode] for which zone.
  static String formatWireTimestamp(DateTime value) {
    final t = AppConfig.sendLocalTimestamps ? value.toLocal() : value.toUtc();
    String two(int n) => n.toString().padLeft(2, '0');

    return '${t.year.toString().padLeft(4, '0')}-${two(t.month)}-${two(t.day)}'
        'T${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  /// Longest gap between two fixes that still supports a derived velocity. A
  /// straight line between endpoints two minutes apart says nothing useful
  /// about the route actually driven, or the speed along it.
  static const double _maxDerivationGapSeconds = 120;

  /// Floor for the movement a derivation needs, for fixes that report no
  /// accuracy at all.
  static const double _minDerivationMetres = 10;

  /// Speed and course computed from the previous fix, for the common case of a
  /// receiver that reports a position but no velocity.
  ///
  /// This is dead reckoning between two points, so it is only honest when the
  /// gap is short enough that a straight line approximates the real path, and
  /// the movement is larger than the noise in the two fixes that measured it.
  /// Returns null whenever it cannot meet that bar, leaving the field null
  /// rather than guessing.
  static _DerivedVelocity? _derive(Position position, Position? previous) {
    if (previous == null) return null;
    if (position.hasSpeed && position.hasHeading) return null;

    final seconds =
        position.timestamp.difference(previous.timestamp).inMilliseconds / 1000;
    if (seconds <= 0 || seconds > _maxDerivationGapSeconds) return null;

    final metres = Geolocator.distanceBetween(
      previous.latitude,
      previous.longitude,
      position.latitude,
      position.longitude,
    );

    // Two fixes taken while parked still differ by a few metres. Deriving a
    // speed from that noise would report a stationary vehicle as crawling, so
    // the movement has to clear the accuracy of the fixes that measured it.
    final noise = math.max(
      _minDerivationMetres,
      math.max(
        position.hasAccuracy ? position.accuracy : 0.0,
        previous.hasAccuracy ? previous.accuracy : 0.0,
      ),
    );
    if (metres < noise) return null;

    return _DerivedVelocity(
      speed: metres / seconds,
      // `bearingBetween` is signed (-180..180); the wire format wants a
      // compass course (0..360).
      heading: (Geolocator.bearingBetween(
                previous.latitude,
                previous.longitude,
                position.latitude,
                position.longitude,
              ) +
              360) %
          360,
    );
  }

  /// Rounds to a Dart `int`, so `jsonEncode` writes `28` rather than `28.0`.
  /// Guards against the non-finite values a bad GPS fix can produce, which
  /// `round()` would throw on.
  static int _roundToInt(double value) {
    if (!value.isFinite) return 0;
    return value.round();
  }

  /// Full-fidelity form used for the on-device queue, not for the wire.
  Map<String, dynamic> toJson() => <String, dynamic>{
        'lat': latitude,
        'lng': longitude,
        'recordedAt': recordedAt.toIso8601String(),
        'trigger': trigger.name,
        if (accuracy != null) 'accuracy': accuracy,
        if (altitude != null) 'altitude': altitude,
        if (altitudeAccuracy != null) 'altitudeAccuracy': altitudeAccuracy,
        if (speed != null) 'speed': speed,
        if (speedAccuracy != null) 'speedAccuracy': speedAccuracy,
        if (heading != null) 'heading': heading,
        'isMocked': isMocked,
        if (batteryLevel != null) 'batteryLevel': batteryLevel,
      };

  String encode() => jsonEncode(toJson());

  static LocationPing decode(String raw) =>
      LocationPing.fromJson(jsonDecode(raw) as Map<String, dynamic>);
}

/// Speed (metres per second) and course (degrees) reconstructed from two
/// consecutive fixes, used only when the platform reported neither.
class _DerivedVelocity {
  const _DerivedVelocity({required this.speed, required this.heading});

  final double speed;
  final double heading;
}
