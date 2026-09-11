import 'dart:convert';
import 'dart:io';

import 'package:dyn_gis/src/data/auth_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'auth_session_test.dart' show sampleData;

void main() {
  // login() persists on success, so the storage platform needs a test double.
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  AuthRepository repoReturning(int statusCode, Object body) => AuthRepository(
        client: MockClient(
          (_) async => http.Response(
            body is String ? body : jsonEncode(body),
            statusCode,
            headers: const <String, String>{
              'content-type': 'application/json; charset=utf-8',
            },
          ),
        ),
      );

  Future<LoginResult> login(AuthRepository repo) =>
      repo.login(username: 'user', password: 'pass');

  group('AuthRepository.login', () {
    test('returns a session on the documented success envelope', () async {
      final repo = repoReturning(200, <String, dynamic>{
        'status': true,
        'message': 'Operation successful',
        'data': sampleData(),
      });

      final result = await login(repo);

      expect(result, isA<LoginSuccess>());
      final session = (result as LoginSuccess).session;
      expect(session.userId, 'be171b5a-e392-45f0-8e87-3a282c10feef');
      expect(session.salesmanId, '0566476325');
      expect(session.username, 'user');
    });

    test('caches the session so the next launch skips the login screen',
        () async {
      final repo = repoReturning(200, <String, dynamic>{
        'status': true,
        'message': 'Operation successful',
        'data': sampleData(),
      });

      await login(repo);

      final restored = await repo.load();
      expect(restored, isNotNull);
      expect(restored!.userId, 'be171b5a-e392-45f0-8e87-3a282c10feef');
      expect(await repo.hasUsableSession(), isTrue);
    });

    test('surfaces the server message on bad credentials', () async {
      // This is the real 401 body the API returns.
      final repo = repoReturning(401, <String, dynamic>{
        'status': false,
        'message': 'Invalid login attempt.',
        'data': null,
        'traceId': null,
      });

      final result = await login(repo);

      expect(result, isA<LoginRejected>());
      expect((result as LoginRejected).message, 'Invalid login attempt.');
    });

    test('treats a 500 as a failure rather than a rejected credential',
        () async {
      final repo = repoReturning(500, <String, dynamic>{
        'status': false,
        'message': 'Something broke.',
      });

      expect(await login(repo), isA<LoginFailed>());
    });

    test('rejects a success envelope with no usable token', () async {
      final repo = repoReturning(200, <String, dynamic>{
        'status': true,
        'message': 'Operation successful',
        'data': <String, dynamic>{'userId': 'user-1'},
      });

      expect(await login(repo), isA<LoginFailed>());
      expect(await repo.load(), isNull);
    });

    test('handles a non-JSON body without throwing', () async {
      final repo = repoReturning(502, '<html>Bad Gateway</html>');
      expect(await login(repo), isA<LoginFailed>());
    });

    test('reports being offline instead of crashing', () async {
      final repo = AuthRepository(
        client: MockClient((_) async => throw const SocketException('offline')),
      );

      final result = await login(repo);
      expect(result, isA<LoginFailed>());
      expect((result as LoginFailed).message, 'No internet connection.');
    });
  });

  group('session lifecycle', () {
    test('a refused token blocks uploads until the next sign-in', () async {
      final repo = repoReturning(200, <String, dynamic>{
        'status': true,
        'message': 'Operation successful',
        'data': sampleData(),
      });
      await login(repo);
      expect(await repo.hasUsableSession(), isTrue);

      // The background service flags the token as refused.
      await repo.markReauthRequired();
      expect(await repo.isReauthRequired(), isTrue);
      expect(await repo.hasUsableSession(), isFalse);

      // Signing in again clears the flag.
      await login(repo);
      expect(await repo.isReauthRequired(), isFalse);
      expect(await repo.hasUsableSession(), isTrue);
    });

    test('signing out forgets the session', () async {
      final repo = repoReturning(200, <String, dynamic>{
        'status': true,
        'message': 'Operation successful',
        'data': sampleData(),
      });
      await login(repo);

      await repo.clear();

      expect(await repo.load(), isNull);
      expect(await repo.hasUsableSession(), isFalse);
    });

    test('an expired cached session is not usable', () async {
      final repo = repoReturning(200, <String, dynamic>{
        'status': true,
        'message': 'Operation successful',
        'data': <String, dynamic>{
          // No exp claim, and an expireAt already in the past.
          'token': 'not.a.jwt',
          'expireAt': '2020-01-01T00:00:00',
          'userId': 'user-1',
        },
      });

      await login(repo);

      expect(await repo.load(), isNotNull);
      expect(await repo.hasUsableSession(), isFalse);
    });
  });
}
