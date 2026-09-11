import 'dart:convert';

/// A signed-in user, as returned by `/api/Auth/Login`.
///
/// Cached on the device so the app goes straight to tracking on later
/// launches. The JWT doubles as the credential for the location endpoint, and
/// [userId] is the identity every fix is attributed to — there is no
/// app-generated device id any more.
class AuthSession {
  const AuthSession({
    required this.token,
    required this.userId,
    required this.expireAt,
    this.isSuperAdmin = false,
    this.username,
    this.fullName,
    this.salesmanId,
    this.role,
  });

  /// Builds a session from the `data` object of a successful login response,
  /// enriching it with claims read out of the JWT itself.
  factory AuthSession.fromLoginData(
    Map<String, dynamic> data, {
    String? username,
  }) {
    final token = data['token'] as String? ?? '';
    final claims = decodeJwtClaims(token);

    final responseUserId = (data['userId'] as String?)?.trim();
    final claimUserId = (claims['CurrentUserId'] as String?)?.trim();

    return AuthSession(
      token: token,
      userId: (responseUserId != null && responseUserId.isNotEmpty)
          ? responseUserId
          : (claimUserId ?? ''),
      expireAt: _resolveExpiry(data['expireAt'], claims),
      isSuperAdmin: data['isSuperAdmin'] as bool? ?? false,
      username: username,
      fullName: _nonEmpty(claims['UserFullName']),
      salesmanId: _nonEmpty(claims['UserSalesmanId']),
      role: _nonEmpty(claims['CurrentUserRole']),
    );
  }

  factory AuthSession.fromJson(Map<String, dynamic> json) {
    return AuthSession(
      token: json['token'] as String? ?? '',
      userId: json['userId'] as String? ?? '',
      expireAt: DateTime.parse(json['expireAt'] as String).toUtc(),
      isSuperAdmin: json['isSuperAdmin'] as bool? ?? false,
      username: json['username'] as String?,
      fullName: json['fullName'] as String?,
      salesmanId: json['salesmanId'] as String?,
      role: json['role'] as String?,
    );
  }

  /// The JWT. Sent as `Authorization: Bearer <token>` on location uploads.
  final String token;

  /// Who the fixes belong to. Replaces the old generated device id.
  final String userId;

  /// When [token] stops being accepted, in UTC.
  final DateTime expireAt;

  final bool isSuperAdmin;

  /// What was typed at the login screen, kept only to prefill the field again.
  final String? username;

  final String? fullName;

  /// `UserSalesmanId` claim. For a field-force app this is usually the id the
  /// business actually reports on, so it is forwarded alongside [userId].
  final String? salesmanId;

  final String? role;

  bool get isValid => token.isNotEmpty && userId.isNotEmpty;

  bool get isExpired => DateTime.now().toUtc().isAfter(expireAt);

  /// True once the session is close enough to expiry that the user should be
  /// asked to sign in again while they still have a working app in their hand,
  /// rather than mid-shift.
  bool get isNearingExpiry => DateTime.now()
      .toUtc()
      .isAfter(expireAt.subtract(const Duration(hours: 6)));

  Map<String, dynamic> toJson() => <String, dynamic>{
        'token': token,
        'userId': userId,
        'expireAt': expireAt.toIso8601String(),
        'isSuperAdmin': isSuperAdmin,
        if (username != null) 'username': username,
        if (fullName != null) 'fullName': fullName,
        if (salesmanId != null) 'salesmanId': salesmanId,
        if (role != null) 'role': role,
      };

  String encode() => jsonEncode(toJson());

  static AuthSession decode(String raw) =>
      AuthSession.fromJson(jsonDecode(raw) as Map<String, dynamic>);

  /// Reads the claim set out of a JWT without verifying the signature — the
  /// server does the verifying; this is only to pick up identity fields the
  /// login response does not repeat. Returns empty on anything malformed.
  static Map<String, dynamic> decodeJwtClaims(String token) {
    try {
      final parts = token.split('.');
      if (parts.length != 3) return const <String, dynamic>{};

      final payload = utf8.decode(base64Url.decode(base64Url.normalize(parts[1])));
      final decoded = jsonDecode(payload);
      return decoded is Map<String, dynamic> ? decoded : const <String, dynamic>{};
    } catch (_) {
      return const <String, dynamic>{};
    }
  }

  /// The JWT `exp` claim wins over the response's `expireAt` string.
  ///
  /// `exp` is unambiguous — epoch seconds, always UTC. The `expireAt` field
  /// carries no timezone marker (`2026-09-17T22:01:13.813763`), so parsing it
  /// would silently guess the device's own offset and could hand back a
  /// session that looks valid hours after the server stopped accepting it.
  static DateTime _resolveExpiry(Object? expireAt, Map<String, dynamic> claims) {
    final exp = claims['exp'];
    if (exp is int) {
      return DateTime.fromMillisecondsSinceEpoch(exp * 1000, isUtc: true);
    }

    if (expireAt is String && expireAt.isNotEmpty) {
      final parsed = DateTime.tryParse(expireAt);
      // Treated as UTC when the string is naive: expiring a little early is
      // recoverable, honouring a dead token is not.
      if (parsed != null) {
        return parsed.isUtc ? parsed : DateTime.utc(
              parsed.year,
              parsed.month,
              parsed.day,
              parsed.hour,
              parsed.minute,
              parsed.second,
              parsed.millisecond,
            );
      }
    }

    // No usable expiry: assume already stale so the 401 path takes over.
    return DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  }

  static String? _nonEmpty(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}
