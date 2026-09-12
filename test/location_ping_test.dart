import 'dart:convert';

import 'package:dyn_gis/src/config/app_config.dart';
import 'package:dyn_gis/src/models/location_ping.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';

void main() {
  group('LocationPing', () {
    test('survives an encode/decode round trip', () {
      final original = LocationPing(
        latitude: 30.044420,
        longitude: 31.235712,
        recordedAt: DateTime.utc(2026, 9, 10, 18, 22, 4),
        trigger: PingTrigger.movement,
        accuracy: 12.5,
        altitude: 45,
        speed: 3.2,
        heading: 178.4,
        isMocked: false,
        batteryLevel: 84,
      );

      final restored = LocationPing.decode(original.encode());

      expect(restored.latitude, original.latitude);
      expect(restored.longitude, original.longitude);
      expect(restored.recordedAt, original.recordedAt);
      expect(restored.trigger, PingTrigger.movement);
      expect(restored.accuracy, 12.5);
      expect(restored.speed, 3.2);
      expect(restored.batteryLevel, 84);
    });

    test('timestamps are serialised as UTC', () {
      final ping = LocationPing(
        latitude: 1,
        longitude: 2,
        recordedAt: DateTime.utc(2026, 1, 2, 3, 4, 5),
        trigger: PingTrigger.heartbeat,
      );

      expect(ping.toJson()['recordedAt'], '2026-01-02T03:04:05.000Z');
    });

    test('drops fields the platform reports as unavailable', () {
      final position = Position(
        latitude: 10,
        longitude: 20,
        timestamp: DateTime.utc(2026, 5, 1),
        accuracy: 0,
        altitude: 0,
        altitudeAccuracy: 0,
        heading: 0,
        headingAccuracy: 0,
        speed: 0,
        speedAccuracy: 0,
        isMocked: false,
        // Every optional reading is flagged as absent.
        hasAccuracy: false,
        hasAltitude: false,
        hasAltitudeAccuracy: false,
        hasHeading: false,
        hasHeadingAccuracy: false,
        hasSpeed: false,
        hasSpeedAccuracy: false,
      );

      final json = LocationPing.fromPosition(
        position,
        trigger: PingTrigger.start,
      ).toJson();

      // Absent readings must be omitted, not sent as a misleading 0.
      expect(json.containsKey('accuracy'), isFalse);
      expect(json.containsKey('altitude'), isFalse);
      expect(json.containsKey('speed'), isFalse);
      expect(json.containsKey('heading'), isFalse);
      expect(json['lat'], 10);
      expect(json['trigger'], 'start');
    });

    test('converts m/s to km/h for the wire', () {
      final ping = LocationPing(
        latitude: 1,
        longitude: 2,
        recordedAt: DateTime.utc(2026, 1, 1),
        trigger: PingTrigger.movement,
        speed: 10, // m/s
      );

      expect(ping.toWirePing()['speedKmh'], 36);
      // The stored form stays in the platform's own unit and full precision.
      expect(ping.toJson()['speed'], 10);
    });

    test('wire speed and heading are integers, never decimals', () {
      LocationPing at({double? speed, double? heading}) => LocationPing(
            latitude: 1,
            longitude: 2,
            recordedAt: DateTime.utc(2026, 1, 1),
            trigger: PingTrigger.movement,
            speed: speed,
            heading: heading,
          );

      // 7.7 m/s is 27.72 km/h, which must not serialise with a fraction.
      final rounded = at(speed: 7.7, heading: 178.4).toWirePing();
      expect(rounded['speedKmh'], 28);
      expect(rounded['headingDeg'], 178);
      expect(rounded['speedKmh'], isA<int>());
      expect(rounded['headingDeg'], isA<int>());

      // Stationary: the exact payload the server rejected as `0.0`.
      expect(jsonEncode(at().toWirePing()), contains('"speedKmh":0,'));

      // A non-finite reading must not blow up round().
      final broken = at(speed: double.nan, heading: double.infinity);
      expect(broken.toWirePing()['speedKmh'], 0);
      expect(broken.toWirePing()['headingDeg'], 0);
    });

    test('wire timestamps are naive, second-precision, no offset', () {
      // The API's own samples look like "2026-09-09T09:59:00" — no
      // milliseconds, no zone marker. Written from local parts rather than a
      // fixed string so the assertion means the same thing on a CI box in UTC
      // and a laptop in Riyadh.
      expect(
        LocationPing.formatWireTimestamp(
          DateTime.utc(2026, 9, 9, 9, 59, 0, 813),
        ),
        _naive(DateTime.utc(2026, 9, 9, 9, 59, 0, 813).toLocal()),
      );
      expect(
        LocationPing.formatWireTimestamp(DateTime.utc(2026, 1, 2, 3, 4, 5)),
        matches(RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}$')),
      );
    });

    test('a default build sends the rep\'s local clock, not UTC', () {
      // The whole point of the default: a fix taken at 09:59 on the rep's
      // phone reaches the supervisor as 09:59. Only meaningful on a machine
      // that is not itself on UTC, so it says so rather than passing vacuously.
      expect(AppConfig.sendLocalTimestamps, isTrue);

      final DateTime instant = DateTime.utc(2026, 9, 9, 9, 59);
      final String wire = LocationPing.formatWireTimestamp(instant);

      expect(wire, _naive(instant.toLocal()));
      if (instant.toLocal().hour != instant.hour) {
        expect(wire, isNot(_naive(instant)));
      }
    });

    test('carries the mock-provider flag through', () {
      final position = Position(
        latitude: 10,
        longitude: 20,
        timestamp: DateTime.utc(2026, 5, 1),
        accuracy: 5,
        altitude: 0,
        altitudeAccuracy: 0,
        heading: 0,
        headingAccuracy: 0,
        speed: 0,
        speedAccuracy: 0,
        isMocked: true,
      );

      final ping = LocationPing.fromPosition(
        position,
        trigger: PingTrigger.heartbeat,
      );

      expect(ping.isMocked, isTrue);
      expect(LocationPing.decode(ping.encode()).isMocked, isTrue);
    });
  });
}

/// Renders a DateTime the way the wire format does, from whatever zone it is
/// already in. Lets the timestamp assertions state the rule rather than a
/// string that only holds in one timezone.
String _naive(DateTime t) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.year.toString().padLeft(4, '0')}-${two(t.month)}-${two(t.day)}'
      'T${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
}
