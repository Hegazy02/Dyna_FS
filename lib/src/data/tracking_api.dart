import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../config/app_config.dart';
import '../models/auth_session.dart';
import '../models/http_exchange.dart';
import '../models/location_ping.dart';

enum UploadResult {
  /// Server accepted the batch; it can be deleted from the queue.
  accepted,

  /// Transient problem (offline, timeout, server error). Keep and retry.
  retryable,

  /// The token was refused. Keep the data — it is still perfectly good — and
  /// get the user to sign in again before trying any more uploads.
  unauthorized,

  /// The server will never accept this batch. Drop it or it blocks the queue
  /// head forever and every later fix starves behind it.
  rejected,
}

/// Uploads batches of location fixes to the backend.
class TrackingApi {
  /// [endpoint] defaults to the build-time [AppConfig] value; it is a
  /// parameter so tests can drive this without a --dart-define.
  ///
  /// [onExchange] receives every attempt, for the on-screen debug log.
  TrackingApi({
    http.Client? client,
    Uri? endpoint,
    this.onExchange,
  })  : _client = client ?? http.Client(),
        _target =
            endpoint ?? (AppConfig.isConfigured ? AppConfig.ingestUri : null);

  final http.Client _client;

  /// Null when no ingest path was configured at build time.
  final Uri? _target;

  /// Called once per upload attempt, for the on-screen debug log.
  final void Function(HttpExchange)? onExchange;

  /// POSTs a batch on behalf of a signed-in user. Never throws — callers get
  /// an [UploadResult] instead, so a network blip can't take down the
  /// tracking service.
  Future<UploadResult> send({
    required AuthSession session,
    required List<LocationPing> pings,
  }) async {
    if (pings.isEmpty) return UploadResult.accepted;

    // A build made without --dart-define=DYN_GIS_INGEST_PATH should hold data
    // rather than throw it away; a rebuilt APK can still deliver the backlog.
    final target = _target;
    if (target == null) return UploadResult.retryable;

    // No identity in the body: the endpoint takes only `pings`, and the
    // bearer token is what tells the server whose fixes these are.
    final body = jsonEncode(<String, dynamic>{
      'pings': pings.map((p) => p.toWirePing()).toList(growable: false),
    });

    final started = DateTime.now();
    try {
      final response = await _client
          .post(
            target,
            headers: <String, String>{
              'Content-Type': 'application/json; charset=utf-8',
              'Accept': 'application/json',
              'Authorization': 'Bearer ${session.token}',
            },
            body: body,
          )
          .timeout(AppConfig.requestTimeout);

      _record(
        target: target,
        session: session,
        body: body,
        pingCount: pings.length,
        started: started,
        statusCode: response.statusCode,
        responseBody: response.body,
      );

      return _classify(response.statusCode);
    } on TimeoutException {
      _record(
        target: target,
        session: session,
        body: body,
        pingCount: pings.length,
        started: started,
        error: 'Timed out after ${AppConfig.requestTimeout.inSeconds}s',
      );
      return UploadResult.retryable;
    } on SocketException catch (e) {
      _record(
        target: target,
        session: session,
        body: body,
        pingCount: pings.length,
        started: started,
        error: 'No connection: ${e.message}',
      );
      return UploadResult.retryable;
    } on http.ClientException catch (e) {
      _record(
        target: target,
        session: session,
        body: body,
        pingCount: pings.length,
        started: started,
        error: 'Client error: ${e.message}',
      );
      return UploadResult.retryable;
    } catch (e) {
      _record(
        target: target,
        session: session,
        body: body,
        pingCount: pings.length,
        started: started,
        error: e.toString(),
      );
      return UploadResult.retryable;
    }
  }

  void _record({
    required Uri target,
    required AuthSession session,
    required String body,
    required int pingCount,
    required DateTime started,
    int? statusCode,
    String? responseBody,
    String? error,
  }) {
    final sink = onExchange;
    if (sink == null) return;

    sink(
      HttpExchange(
        at: started,
        url: target.toString(),
        requestBody: HttpExchange.truncate(
          HttpExchange.prettyJson(body),
          AppConfig.debugBodyLimit,
        ),
        pingCount: pingCount,
        durationMs: DateTime.now().difference(started).inMilliseconds,
        statusCode: statusCode,
        responseBody: responseBody == null
            ? null
            : HttpExchange.truncate(responseBody, 800),
        error: error,
        authPreview: HttpExchange.previewToken(session.token),
      ),
    );
  }

  UploadResult _classify(int statusCode) {
    if (statusCode >= 200 && statusCode < 300) return UploadResult.accepted;

    // A refused token is not a data problem. The batch is kept and the service
    // stops hammering the endpoint until the user has signed in again.
    if (statusCode == HttpStatus.unauthorized ||
        statusCode == HttpStatus.forbidden) {
      return UploadResult.unauthorized;
    }

    // Only statuses where retrying genuinely cannot help are treated as fatal.
    const fatal = <int>{
      HttpStatus.badRequest, // 400 - malformed payload
      HttpStatus.requestEntityTooLarge, // 413 - batch too big
      HttpStatus.unprocessableEntity, // 422 - failed validation
    };
    if (fatal.contains(statusCode)) return UploadResult.rejected;

    return UploadResult.retryable;
  }

  void dispose() => _client.close();
}
