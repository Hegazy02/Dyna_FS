import 'dart:convert';

import 'http_exchange.dart';

/// Snapshot broadcast by the background service to the UI isolate.
///
/// Purely diagnostic — the app works fine if nothing ever reads it.
class TrackerStatus {
  const TrackerStatus({
    required this.userId,
    required this.signedInAs,
    required this.salesmanId,
    required this.reauthRequired,
    required this.pending,
    required this.delivered,
    required this.discarded,
    required this.streaming,
    required this.durableQueue,
    required this.configured,
    this.lastDeliveryAt,
    this.lastFixAt,
    this.lastLat,
    this.lastLng,
    this.lastError,
    this.exchanges = const <HttpExchange>[],
  });

  static TrackerStatus? tryParse(Object data) {
    if (data is! String) return null;
    try {
      final json = jsonDecode(data) as Map<String, dynamic>;
      if (!json.containsKey('userId')) return null;

      return TrackerStatus(
        userId: json['userId'] as String? ?? '',
        signedInAs: json['signedInAs'] as String? ?? '',
        salesmanId: json['salesmanId'] as String? ?? '',
        reauthRequired: json['reauthRequired'] as bool? ?? false,
        pending: json['pending'] as int? ?? 0,
        delivered: json['delivered'] as int? ?? 0,
        discarded: json['discarded'] as int? ?? 0,
        streaming: json['streaming'] as bool? ?? false,
        durableQueue: json['durableQueue'] as bool? ?? false,
        configured: json['configured'] as bool? ?? false,
        lastDeliveryAt: _parseDate(json['lastDeliveryAt']),
        lastFixAt: _parseDate(json['lastFixAt']),
        lastLat: (json['lastLat'] as num?)?.toDouble(),
        lastLng: (json['lastLng'] as num?)?.toDouble(),
        lastError: json['lastError'] as String?,
        exchanges: (json['exchanges'] as List<dynamic>? ?? <dynamic>[])
            .whereType<Map<String, dynamic>>()
            .map(HttpExchange.fromJson)
            .toList(growable: false),
      );
    } catch (_) {
      return null;
    }
  }

  /// The signed-in user the fixes are attributed to.
  final String userId;

  /// Display name, for confirming the right person is signed in.
  final String signedInAs;

  final String salesmanId;

  /// True when the server refused the token and uploads are paused.
  final bool reauthRequired;

  final int pending;
  final int delivered;
  final int discarded;
  final bool streaming;
  final bool durableQueue;
  final bool configured;
  final DateTime? lastDeliveryAt;
  final DateTime? lastFixAt;
  final double? lastLat;
  final double? lastLng;
  final String? lastError;

  /// Recent upload attempts, newest first.
  final List<HttpExchange> exchanges;

  static DateTime? _parseDate(Object? raw) {
    if (raw is! String) return null;
    return DateTime.tryParse(raw);
  }
}
