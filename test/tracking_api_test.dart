import 'dart:convert';
import 'dart:io';

import 'package:dyn_gis/src/config/app_config.dart';
import 'package:dyn_gis/src/data/tracking_api.dart';
import 'package:dyn_gis/src/models/auth_session.dart';
import 'package:dyn_gis/src/models/http_exchange.dart';
import 'package:dyn_gis/src/models/location_ping.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  final endpoint = Uri.parse('https://gis.example.com/locations');

  AuthSession session({String? salesmanId = '0566476325'}) => AuthSession(
        token: 'jwt-token',
        userId: 'user-1',
        expireAt: DateTime.now().toUtc().add(const Duration(days: 1)),
        salesmanId: salesmanId,
      );

  LocationPing ping() => LocationPing(
        latitude: 30.04,
        longitude: 31.23,
        recordedAt: DateTime.utc(2026, 9, 10),
        trigger: PingTrigger.heartbeat,
      );

  TrackingApi apiReturning(int statusCode) => TrackingApi(
        endpoint: endpoint,
        client: MockClient((_) async => http.Response('', statusCode)),
      );

  Future<UploadResult> send(TrackingApi api, {int count = 1}) => api.send(
        session: session(),
        pings: List<LocationPing>.generate(count, (_) => ping()),
      );

  group('TrackingApi status handling', () {
    test('2xx is accepted', () async {
      expect(await send(apiReturning(200)), UploadResult.accepted);
      expect(await send(apiReturning(202)), UploadResult.accepted);
    });

    test('server errors are retryable', () async {
      expect(await send(apiReturning(500)), UploadResult.retryable);
      expect(await send(apiReturning(503)), UploadResult.retryable);
    });

    test('throttling and timeouts are retryable', () async {
      expect(await send(apiReturning(429)), UploadResult.retryable);
      expect(await send(apiReturning(408)), UploadResult.retryable);
    });

    test('a refused token pauses uploads without losing data', () async {
      // The batch is kept — it is good data, it just needs a fresh sign-in.
      expect(await send(apiReturning(401)), UploadResult.unauthorized);
      expect(await send(apiReturning(403)), UploadResult.unauthorized);
    });

    test('unprocessable payloads are rejected so they cannot stall the queue',
        () async {
      expect(await send(apiReturning(400)), UploadResult.rejected);
      expect(await send(apiReturning(413)), UploadResult.rejected);
      expect(await send(apiReturning(422)), UploadResult.rejected);
    });

    test('network failures are swallowed and reported as retryable', () async {
      final api = TrackingApi(
        endpoint: endpoint,
        client: MockClient((_) async => throw const SocketException('offline')),
      );

      expect(await send(api), UploadResult.retryable);
    });

    test('an empty batch is a no-op success', () async {
      final api = TrackingApi(
        endpoint: endpoint,
        client: MockClient((_) async => fail('should not have been called')),
      );

      expect(
        await api.send(session: session(), pings: const <LocationPing>[]),
        UploadResult.accepted,
      );
    });

    test('a default build points at the real endpoints', () async {
      // Guards against a typo in the shipped defaults, which would otherwise
      // only show up as an APK that queues forever in the field.
      expect(
        AppConfig.ingestUri.toString(),
        'https://daralshayapi.dynaops365.net/api/LocationPings/batch',
      );
      expect(
        AppConfig.loginUri.toString(),
        'https://daralshayapi.dynaops365.net/api/Auth/Login',
      );
      expect(AppConfig.isConfigured, isTrue);
    });
  });

  group('TrackingApi debug log', () {
    test('records a successful exchange with a redacted token', () async {
      final logged = <HttpExchange>[];

      final api = TrackingApi(
        endpoint: endpoint,
        onExchange: logged.add,
        client: MockClient(
          (_) async => http.Response('{"status":true}', 200),
        ),
      );

      await send(api, count: 2);

      expect(logged, hasLength(1));
      final e = logged.single;
      expect(e.statusCode, 200);
      expect(e.succeeded, isTrue);
      expect(e.pingCount, 2);
      expect(e.url, endpoint.toString());
      expect(e.responseBody, '{"status":true}');
      expect(e.error, isNull);

      // The token must never reach the screen whole, at any length.
      expect(e.authPreview, isNot(contains('jwt-token')));
      expect(e.authPreview, contains('9 chars'));
      expect(e.requestBody, contains('"pings"'));
    });

    test('never prints a token in full, short or long', () {
      const short = 'secret123';
      const long =
          'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.payloadpayload.signature';

      expect(HttpExchange.previewToken(short), isNot(contains(short)));
      expect(HttpExchange.previewToken(long), isNot(contains(long)));
      expect(HttpExchange.previewToken(''), '(none)');

      // Still identifiable and length-checkable.
      expect(HttpExchange.previewToken(long), startsWith('eyJhbGci'));
      expect(HttpExchange.previewToken(long), contains('${long.length} chars'));
    });

    test('records failures, including ones with no response at all', () async {
      final logged = <HttpExchange>[];

      final offline = TrackingApi(
        endpoint: endpoint,
        onExchange: logged.add,
        client: MockClient((_) async => throw const SocketException('down')),
      );
      await send(offline);

      final rejected = TrackingApi(
        endpoint: endpoint,
        onExchange: logged.add,
        client: MockClient((_) async => http.Response('bad request', 400)),
      );
      await send(rejected);

      expect(logged, hasLength(2));
      expect(logged[0].statusCode, isNull);
      expect(logged[0].error, contains('No connection'));
      expect(logged[0].succeeded, isFalse);
      expect(logged[1].statusCode, 400);
      expect(logged[1].responseBody, 'bad request');
      expect(logged[1].succeeded, isFalse);
    });

    test('survives a round trip to the UI isolate', () {
      final original = HttpExchange(
        at: DateTime.utc(2026, 9, 11, 8, 30),
        url: 'https://example.com/x',
        requestBody: '{"pings":[]}',
        pingCount: 3,
        durationMs: 412,
        statusCode: 200,
        responseBody: 'ok',
        authPreview: 'eyJhbGci…Pd94',
      );

      final restored = HttpExchange.fromJson(
        jsonDecode(jsonEncode(original.toJson())) as Map<String, dynamic>,
      );

      expect(restored.at, original.at);
      expect(restored.pingCount, 3);
      expect(restored.durationMs, 412);
      expect(restored.statusCode, 200);
      expect(restored.responseBody, 'ok');
      expect(restored.authPreview, 'eyJhbGci…Pd94');
    });

    test('truncates oversized bodies rather than shipping them whole', () {
      final long = 'x' * 5000;
      final trimmed = HttpExchange.truncate(long, 100);

      expect(trimmed.length, lessThan(200));
      expect(trimmed, endsWith('truncated'));
      expect(HttpExchange.truncate('short', 100), 'short');
    });

    test('pretty-prints JSON but passes non-JSON through untouched', () {
      expect(HttpExchange.prettyJson('{"a":1}'), '{\n  "a": 1\n}');
      expect(
        HttpExchange.prettyJson('<html>Bad Gateway</html>'),
        '<html>Bad Gateway</html>',
      );
    });
  });

  group('TrackingApi request shape', () {
    test('sends a bare pings array with the session token as bearer auth',
        () async {
      late http.Request captured;

      final api = TrackingApi(
        endpoint: endpoint,
        client: MockClient((http.Request request) async {
          captured = request;
          return http.Response('', 200);
        }),
      );

      await send(api, count: 3);

      expect(captured.method, 'POST');
      expect(captured.url, endpoint);
      expect(captured.headers['Authorization'], 'Bearer jwt-token');
      expect(captured.headers['Content-Type'], contains('application/json'));

      final body = jsonDecode(captured.body) as Map<String, dynamic>;
      expect(body['pings'], hasLength(3));

      // The endpoint takes only `pings`; identity comes from the token, so
      // nothing else may leak into the body.
      expect(body.keys, <String>['pings']);
    });

    test('each ping matches the documented field set exactly', () async {
      late http.Request captured;

      final api = TrackingApi(
        endpoint: endpoint,
        client: MockClient((http.Request request) async {
          captured = request;
          return http.Response('', 200);
        }),
      );

      await api.send(
        session: session(),
        pings: <LocationPing>[
          LocationPing(
            latitude: 24.755,
            longitude: 46.73,
            recordedAt: DateTime.utc(2026, 9, 9, 9, 59),
            trigger: PingTrigger.heartbeat,
            // 7.777… m/s is 28 km/h.
            speed: 28 / 3.6,
            heading: 5,
            // Rich fields the queue keeps but the endpoint does not accept.
            accuracy: 12.5,
            altitude: 640,
            batteryLevel: 84,
            isMocked: true,
          ),
        ],
      );

      final body = jsonDecode(captured.body) as Map<String, dynamic>;
      final wire = (body['pings'] as List).single as Map<String, dynamic>;

      // Naive, second-precision, no offset — and in the rep's local zone, so
      // the expectation is rendered rather than hardcoded. See
      // AppConfig.timestampMode.
      expect(
        wire['at'],
        LocationPing.formatWireTimestamp(DateTime.utc(2026, 9, 9, 9, 59)),
      );
      expect(wire['at'], matches(RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}$')));
      expect(wire['lat'], 24.755);
      expect(wire['lng'], 46.73);
      expect(wire['source'], 'Gps');

      // Integers, not doubles: the server binds these to int and rejects a
      // decimal literal with "Speed Kmh must be a number".
      expect(wire['speedKmh'], 28);
      expect(wire['speedKmh'], isA<int>());
      expect(wire['headingDeg'], 5);
      expect(wire['headingDeg'], isA<int>());

      // lat/lng stay full-precision doubles.
      expect(wire['lat'], isA<double>());

      // Anything the API does not document must not be sent.
      expect(
        wire.keys.toSet(),
        <String>{'at', 'lat', 'lng', 'speedKmh', 'headingDeg', 'source'},
      );
    });

    test('missing speed and heading are sent as integer zero', () async {
      late http.Request captured;

      final api = TrackingApi(
        endpoint: endpoint,
        client: MockClient((http.Request request) async {
          captured = request;
          return http.Response('', 200);
        }),
      );

      await api.send(session: session(), pings: <LocationPing>[ping()]);

      // The exact case the server rejected: a stationary fix must serialise
      // as `"speedKmh":0`, never `"speedKmh":0.0`.
      expect(captured.body, contains('"speedKmh":0,'));
      expect(captured.body, contains('"headingDeg":0,'));
      expect(captured.body, isNot(contains('"speedKmh":0.0')));
      expect(captured.body, isNot(contains('"headingDeg":0.0')));

      final body = jsonDecode(captured.body) as Map<String, dynamic>;
      final wire = (body['pings'] as List).single as Map<String, dynamic>;
      expect(wire['speedKmh'], 0);
      expect(wire['headingDeg'], 0);
    });
  });
}
