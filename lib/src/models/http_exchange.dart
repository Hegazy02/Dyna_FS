import 'dart:convert';

/// One upload attempt, captured for the on-screen debug log.
///
/// Uploads happen in the foreground service's isolate, where `debugPrint` goes
/// nowhere you can see on a phone in the field. Recording each exchange and
/// shipping it to the UI is the only way to watch what the app is actually
/// sending once it is off the cable.
class HttpExchange {
  const HttpExchange({
    required this.at,
    required this.url,
    required this.requestBody,
    required this.pingCount,
    required this.durationMs,
    this.statusCode,
    this.responseBody,
    this.error,
    this.authPreview,
  });

  factory HttpExchange.fromJson(Map<String, dynamic> json) => HttpExchange(
        at: DateTime.parse(json['at'] as String),
        url: json['url'] as String? ?? '',
        requestBody: json['req'] as String? ?? '',
        pingCount: json['n'] as int? ?? 0,
        durationMs: json['ms'] as int? ?? 0,
        statusCode: json['status'] as int?,
        responseBody: json['res'] as String?,
        error: json['err'] as String?,
        authPreview: json['auth'] as String?,
      );

  final DateTime at;
  final String url;
  final String requestBody;
  final int pingCount;
  final int durationMs;

  /// Null when the request never got a reply (offline, timeout).
  final int? statusCode;
  final String? responseBody;
  final String? error;

  /// The bearer token, heavily abbreviated. Enough to tell whether the app is
  /// sending the token you expect, without putting a working credential on
  /// screen in full.
  final String? authPreview;

  bool get succeeded =>
      statusCode != null && statusCode! >= 200 && statusCode! < 300;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'at': at.toIso8601String(),
        'url': url,
        'req': requestBody,
        'n': pingCount,
        'ms': durationMs,
        if (statusCode != null) 'status': statusCode,
        if (responseBody != null) 'res': responseBody,
        if (error != null) 'err': error,
        if (authPreview != null) 'auth': authPreview,
      };

  /// Bodies are truncated before they cross to the UI isolate: a full batch of
  /// 100 pings is far more than anyone reads on a phone screen, and the log is
  /// re-sent on every 30s status tick.
  static String truncate(String value, int limit) =>
      value.length <= limit ? value : '${value.substring(0, limit)}\n…truncated';

  /// Re-indents JSON so a payload is readable on a narrow screen. Falls back
  /// to the raw text for anything that is not JSON (an HTML error page, say).
  static String prettyJson(String raw) {
    try {
      return const JsonEncoder.withIndent('  ').convert(jsonDecode(raw));
    } catch (_) {
      return raw;
    }
  }

  /// Abbreviates a bearer token to `eyJhbGci…Pd94 (812 chars)`.
  ///
  /// Enough to tell which token is in use, and the length catches the case
  /// where one arrived truncated. Never returns the token whole — a short
  /// token is more likely to be a shared secret than a JWT, so it gets the
  /// heavier redaction rather than the lighter one.
  static String previewToken(String token) {
    if (token.isEmpty) return '(none)';
    if (token.length <= 20) {
      return '${token.substring(0, 2)}… (${token.length} chars)';
    }
    return '${token.substring(0, 8)}…${token.substring(token.length - 4)} '
        '(${token.length} chars)';
  }
}
