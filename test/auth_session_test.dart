import 'package:dyn_gis/src/models/auth_session.dart';
import 'package:flutter_test/flutter_test.dart';

/// The exact token shape the backend returns, used so the claim names stay
/// pinned to reality rather than to a guess.
const String _sampleToken =
    'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJiZTE3MWI1YS1lMzkyLTQ1Zj'
    'AtOGU4Ny0zYTI4MmMxMGZlZWYiLCJqdGkiOiIxYTdiZTg3My05OGVkLTQzZjEtOTNjNy0x'
    'ZWM0MjBhZjJkOTAiLCJodHRwOi8vc2NoZW1hcy54bWxzb2FwLm9yZy93cy8yMDA1LzA1L2'
    'lkZW50aXR5L2NsYWltcy9uYW1lIjoiSGVnYXp5QGR5bmFvcHMzNjUubmV0IiwiaHR0cDov'
    'L3NjaGVtYXMueG1sc29hcC5vcmcvd3MvMjAwNS8wNS9pZGVudGl0eS9jbGFpbXMvZW1haW'
    'xhZGRyZXNzIjoiSGVnYXp5QGR5bmFvcHMzNjUubmV0IiwiQ3VycmVudFVzZXJJZCI6ImJl'
    'MTcxYjVhLWUzOTItNDVmMC04ZTg3LTNhMjgyYzEwZmVlZiIsIkN1cnJlbnRVc2VyU2Vzc2'
    'lvbklkIjoiN2M4NDIwY2YtM2ExMC00NDBiLTlmMjAtNjc4OTUwYjY3ZjhhIiwiQ3VycmVu'
    'dENvbXBhbnlJZCI6IiIsIkN1cnJlbnRVc2VyQ29tcGFueUlkIjoiIiwiQ3VycmVudFVzZX'
    'JSb2xlIjoiU3VwZXJBZG1pbiIsIlVzZXJTYWxlc21hbklkIjoiMDU2NjQ3NjMyNSIsIlVz'
    'ZXJGdWxsTmFtZSI6IkhlZ2F6eUBkeW5hb3BzMzY1Lm5ldCIsIklzU3VwZXJBZG1pbiI6Il'
    'RydWUiLCJleHAiOjE3ODk3MDc2NzMsImlzcyI6IkR5bmFPcHMzNTYiLCJhdWQiOiJBcGku'
    'RHluYU9wczM1NiJ9.3eBDNmpQTvhPCxBZ_vYmEQznL6VA5VpPlErK7AQPd94';

/// The `exp` claim inside [_sampleToken].
const int _sampleExp = 1789707673;

Map<String, dynamic> sampleData() => <String, dynamic>{
      'token': _sampleToken,
      'expireAt': '2026-09-17T22:01:13.813763',
      'userId': 'be171b5a-e392-45f0-8e87-3a282c10feef',
      'isSuperAdmin': true,
    };

void main() {
  group('AuthSession.fromLoginData', () {
    test('pulls identity out of the response and the token claims', () {
      final session = AuthSession.fromLoginData(
        sampleData(),
        username: 'Hegazy@dynaops365.net',
      );

      expect(session.userId, 'be171b5a-e392-45f0-8e87-3a282c10feef');
      expect(session.token, _sampleToken);
      expect(session.isSuperAdmin, isTrue);
      expect(session.username, 'Hegazy@dynaops365.net');
      expect(session.fullName, 'Hegazy@dynaops365.net');
      expect(session.salesmanId, '0566476325');
      expect(session.role, 'SuperAdmin');
      expect(session.isValid, isTrue);
    });

    test('trusts the JWT exp claim over the naive expireAt string', () {
      final session = AuthSession.fromLoginData(sampleData());

      // exp is epoch seconds and unambiguous; expireAt carries no timezone and
      // in this very sample disagrees with exp by seven hours.
      expect(
        session.expireAt.millisecondsSinceEpoch,
        _sampleExp * 1000,
      );
      expect(session.expireAt.isUtc, isTrue);
    });

    test('falls back to expireAt when the token has no exp claim', () {
      final session = AuthSession.fromLoginData(<String, dynamic>{
        'token': 'not.a.jwt',
        'expireAt': '2030-01-02T03:04:05',
        'userId': 'user-1',
      });

      // A naive string is read as UTC, so a stale token is never honoured.
      expect(session.expireAt, DateTime.utc(2030, 1, 2, 3, 4, 5));
    });

    test('falls back to the CurrentUserId claim when userId is absent', () {
      final data = sampleData()..remove('userId');
      expect(
        AuthSession.fromLoginData(data).userId,
        'be171b5a-e392-45f0-8e87-3a282c10feef',
      );
    });

    test('treats a missing expiry as already expired', () {
      final session = AuthSession.fromLoginData(<String, dynamic>{
        'token': 'not.a.jwt',
        'userId': 'user-1',
      });

      expect(session.isExpired, isTrue);
    });

    test('a token-less response is not a usable session', () {
      final session = AuthSession.fromLoginData(<String, dynamic>{
        'userId': 'user-1',
      });

      expect(session.isValid, isFalse);
    });
  });

  group('AuthSession persistence', () {
    test('survives an encode/decode round trip', () {
      final original = AuthSession.fromLoginData(
        sampleData(),
        username: 'Hegazy@dynaops365.net',
      );
      final restored = AuthSession.decode(original.encode());

      expect(restored.token, original.token);
      expect(restored.userId, original.userId);
      expect(restored.expireAt, original.expireAt);
      expect(restored.salesmanId, original.salesmanId);
      expect(restored.username, original.username);
      expect(restored.isSuperAdmin, original.isSuperAdmin);
    });
  });

  group('AuthSession.decodeJwtClaims', () {
    test('returns empty rather than throwing on malformed input', () {
      expect(AuthSession.decodeJwtClaims(''), isEmpty);
      expect(AuthSession.decodeJwtClaims('one.two'), isEmpty);
      expect(AuthSession.decodeJwtClaims('a.!!!not-base64!!!.c'), isEmpty);
    });

    test('reads claims without needing base64 padding', () {
      final claims = AuthSession.decodeJwtClaims(_sampleToken);
      expect(claims['CurrentUserRole'], 'SuperAdmin');
      expect(claims['exp'], _sampleExp);
    });
  });

  group('expiry', () {
    test('isExpired and isNearingExpiry track the clock', () {
      final future = AuthSession(
        token: 't',
        userId: 'u',
        expireAt: DateTime.now().toUtc().add(const Duration(days: 2)),
      );
      final soon = AuthSession(
        token: 't',
        userId: 'u',
        expireAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
      );
      final past = AuthSession(
        token: 't',
        userId: 'u',
        expireAt: DateTime.now().toUtc().subtract(const Duration(minutes: 1)),
      );

      expect(future.isExpired, isFalse);
      expect(future.isNearingExpiry, isFalse);
      expect(soon.isExpired, isFalse);
      expect(soon.isNearingExpiry, isTrue);
      expect(past.isExpired, isTrue);
    });
  });
}
