import 'dart:convert';

import 'package:dyn_gis/src/models/auth_session.dart';
import 'package:dyn_gis/src/service/companion_app.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  AuthSession session({DateTime? expireAt}) => AuthSession(
        token: 'header.payload.signature',
        userId: 'user-1',
        expireAt: expireAt ?? DateTime.utc(2026, 9, 17, 22, 1, 13),
        isSuperAdmin: true,
        username: 'rep01',
        salesmanId: '0566476325',
      );

  Map<String, dynamic> decodeHandoff(Uri uri) {
    final String encoded = Uri.splitQueryString(uri.fragment)['handoff']!;
    return jsonDecode(utf8.decode(base64Url.decode(encoded)))
        as Map<String, dynamic>;
  }

  group('CompanionApp', () {
    test('a default build hands off to the real PWA', () {
      // Same guard as the endpoint defaults: a typo here ships an APK that
      // signs the user in and then drops them on a dead link, which nobody
      // would notice until a driver reported it from the field.
      expect(CompanionApp.isConfigured, isTrue);
      expect(
        CompanionApp.uri.toString(),
        'https://daralshayuat.dynaops365.net',
      );
    });

    test('the hand-off carries exactly the Token shape the PWA persists', () {
      final Uri target = CompanionApp.handoffUri(
        CompanionApp.uri!,
        session(),
      );

      // The PWA writes this object straight into localStorage as its session,
      // so the field names are a contract with DynaOps365's `Token` interface,
      // not an internal detail.
      expect(decodeHandoff(target), <String, dynamic>{
        'token': 'header.payload.signature',
        'userId': 'user-1',
        'expireAt': '2026-09-17T22:01:13.000Z',
        'isSuperAdmin': true,
      });
    });

    test('the credential travels in the fragment, never the query string', () {
      final Uri target = CompanionApp.handoffUri(
        CompanionApp.uri!,
        session(),
      );

      // A query string would be sent to the server and land in access logs and
      // Referer headers. A fragment never leaves the client.
      expect(target.query, isEmpty);
      expect(target.fragment, startsWith('handoff='));
      expect(target.toString(), contains('#handoff='));
      expect(target.origin, CompanionApp.uri!.origin);
    });

    test('expireAt is sent as UTC so the PWA logs out at the right moment', () {
      // This app corrects expiry from the JWT `exp` claim; the PWA feeds the
      // value straight to `new Date()`, which needs the zone to be explicit.
      final Uri target = CompanionApp.handoffUri(
        CompanionApp.uri!,
        session(expireAt: DateTime.utc(2026, 1, 2, 3, 4, 5)),
      );

      expect(decodeHandoff(target)['expireAt'], endsWith('Z'));
      expect(decodeHandoff(target)['expireAt'], '2026-01-02T03:04:05.000Z');
    });
  });
}
