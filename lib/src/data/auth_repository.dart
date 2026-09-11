import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../config/app_config.dart';
import '../models/auth_session.dart';

/// Outcome of a sign-in attempt.
sealed class LoginResult {
  const LoginResult();
}

final class LoginSuccess extends LoginResult {
  const LoginSuccess(this.session);
  final AuthSession session;
}

/// The server answered, and said no. [message] is the server's own wording.
final class LoginRejected extends LoginResult {
  const LoginRejected(this.message);
  final String message;
}

/// Could not reach the server, or it replied with something unusable.
final class LoginFailed extends LoginResult {
  const LoginFailed(this.message);
  final String message;
}

/// Signs in and owns the cached session.
///
/// The cache is deliberately read through to the platform on every call
/// ([SharedPreferencesAsync] rather than the cached `getInstance()` API): the
/// UI isolate writes the session at login and the background service isolate
/// reads it on every upload, and a per-isolate cache would leave the service
/// using a token that was replaced minutes ago.
class AuthRepository {
  AuthRepository({http.Client? client}) : _client = client ?? http.Client();

  static const String _sessionKey = 'dyn_gis.auth_session';
  static const String _reauthKey = 'dyn_gis.reauth_required';

  final http.Client _client;

  SharedPreferencesAsync get _prefs => SharedPreferencesAsync();

  /// The cached session, or null when nobody has signed in on this device.
  Future<AuthSession?> load() async {
    try {
      final raw = await _prefs.getString(_sessionKey);
      if (raw == null || raw.isEmpty) return null;

      final session = AuthSession.decode(raw);
      return session.isValid ? session : null;
    } catch (_) {
      // A corrupt blob must not lock the user out of the login screen.
      return null;
    }
  }

  Future<void> save(AuthSession session) async {
    await _prefs.setString(_sessionKey, session.encode());
    await _prefs.setBool(_reauthKey, false);
  }

  /// Forgets the session. Used by sign-out.
  Future<void> clear() async {
    await _prefs.remove(_sessionKey);
    await _prefs.setBool(_reauthKey, false);
  }

  /// Set by the background service when the server rejects the token, so the
  /// UI knows to show the login screen the next time the app is opened.
  Future<void> markReauthRequired() async {
    try {
      await _prefs.setBool(_reauthKey, true);
    } catch (_) {
      // Best effort; the expiry check will catch it too.
    }
  }

  Future<bool> isReauthRequired() async {
    try {
      return await _prefs.getBool(_reauthKey) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// True when tracking can upload right now: signed in, not expired, and not
  /// flagged by the service as rejected.
  Future<bool> hasUsableSession() async {
    final session = await load();
    if (session == null || session.isExpired) return false;
    return !await isReauthRequired();
  }

  Future<LoginResult> login({
    required String username,
    required String password,
  }) async {
    late final http.Response response;
    try {
      response = await _client
          .post(
            AppConfig.loginUri,
            headers: const <String, String>{
              'Content-Type': 'application/json; charset=utf-8',
              'Accept': 'application/json',
            },
            body: jsonEncode(<String, String>{
              'username': username,
              'password': password,
            }),
          )
          .timeout(AppConfig.requestTimeout);
    } on TimeoutException {
      return const LoginFailed('The server took too long to respond.');
    } on SocketException {
      return const LoginFailed('No internet connection.');
    } on http.ClientException {
      return const LoginFailed('Could not reach the server.');
    } catch (_) {
      return const LoginFailed('Could not reach the server.');
    }

    Map<String, dynamic>? body;
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) body = decoded;
    } catch (_) {
      body = null;
    }

    // The API wraps everything in {status, message, data}, including failures,
    // so its own message is the best thing to show the user.
    final message = body?['message'] as String?;
    final succeeded =
        (body?['status'] as bool? ?? false) && response.statusCode < 400;

    if (!succeeded) {
      final text = (message == null || message.trim().isEmpty)
          ? 'Sign in failed (${response.statusCode}).'
          : message.trim();
      // 4xx is a rejected credential; 5xx is the server having a bad day.
      return response.statusCode >= 500
          ? LoginFailed(text)
          : LoginRejected(text);
    }

    final data = body?['data'];
    if (data is! Map<String, dynamic>) {
      return const LoginFailed('The server returned an unexpected response.');
    }

    final session = AuthSession.fromLoginData(data, username: username);
    if (!session.isValid) {
      return const LoginFailed('The server did not return a usable token.');
    }

    await save(session);
    return LoginSuccess(session);
  }

  void dispose() => _client.close();
}
