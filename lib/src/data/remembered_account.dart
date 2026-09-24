import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// A credential the rep has signed in with before, offered back to them on the
/// login screen so a re-login is one tap rather than two fields.
class RememberedAccount {
  const RememberedAccount({
    required this.username,
    required this.password,
    this.fullName,
  });

  final String username;
  final String password;

  /// The display name the server returned, when it gave one. Shown in place of
  /// the username on the suggestion, because a rep recognises their own name
  /// faster than their login.
  final String? fullName;

  /// What the suggestion calls this account.
  String get label =>
      (fullName != null && fullName!.trim().isNotEmpty) ? fullName! : username;

  /// Initial for the avatar. Falls back to '?' so an account whose label is
  /// whitespace still renders something rather than throwing on `[0]`.
  String get initial {
    final trimmed = label.trim();
    return trimmed.isEmpty ? '?' : trimmed.substring(0, 1).toUpperCase();
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'username': username,
        'password': password,
        if (fullName != null) 'fullName': fullName,
      };

  static RememberedAccount? fromJson(Map<String, dynamic> json) {
    final username = json['username'] as String?;
    final password = json['password'] as String?;
    if (username == null || password == null) return null;
    if (username.isEmpty || password.isEmpty) return null;

    return RememberedAccount(
      username: username,
      password: password,
      fullName: json['fullName'] as String?,
    );
  }
}

/// Stores the last account that signed in successfully.
///
/// Deliberately *not* `shared_preferences`, which is where the session token
/// lives. That file is plaintext, and `android:allowBackup` is unset — so it
/// defaults to true and the file is eligible for Google's cloud backup. A
/// short-lived token is one thing; a password that opens the account for as
/// long as it goes unchanged is another. This goes to the platform keystore
/// instead: EncryptedSharedPreferences on Android, the Keychain on iOS, both
/// excluded from backup.
///
/// Every method swallows its failures. A keystore that will not open is a
/// reason to lose the convenience of the suggestion, never a reason to block
/// the rep from typing their password in by hand.
class RememberedAccountStore {
  const RememberedAccountStore();

  static const String _key = 'dyn_gis.remembered_account';

  // Android needs no options here: since v11 the plugin always encrypts with
  // AES-GCM under a Keystore-wrapped key, so the old `encryptedSharedPreferences`
  // flag is gone rather than merely defaulted.
  static const FlutterSecureStorage _storage = FlutterSecureStorage(
    iOptions: IOSOptions(
      // Only ever read while the rep is looking at the login screen, so it
      // never needs to be available on a locked phone. `_this_device` keeps a
      // saved password from riding an iCloud backup onto a different handset.
      accessibility: KeychainAccessibility.unlocked_this_device,
    ),
  );

  Future<RememberedAccount?> load() async {
    try {
      final raw = await _storage.read(key: _key);
      if (raw == null || raw.isEmpty) return null;

      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;

      return RememberedAccount.fromJson(decoded);
    } catch (_) {
      return null;
    }
  }

  Future<void> save(RememberedAccount account) async {
    try {
      await _storage.write(key: _key, value: jsonEncode(account.toJson()));
    } catch (_) {
      // Nothing to do but lose the suggestion next time.
    }
  }

  /// Drops the stored credential. Signing out does *not* call this — the whole
  /// point of the suggestion is to survive a sign-out — so this only runs when
  /// the rep dismisses the suggestion themselves.
  Future<void> clear() async {
    try {
      await _storage.delete(key: _key);
    } catch (_) {
      // Same again: best effort.
    }
  }
}
