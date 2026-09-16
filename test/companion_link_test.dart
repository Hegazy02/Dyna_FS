import 'dart:convert';

import 'package:dyn_gis/src/service/companion_link.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CompanionLink.parse', () {
    test('reads both verbs, whichever slash count the caller wrote', () {
      // A URI parser puts the verb in the host for `dyngis://signin` and in the
      // path for `dyngis:/signin`, and the caller is a web page whose exact
      // spelling we do not control. A sign-out that silently did nothing would
      // be the worst failure here, so both shapes are accepted.
      expect(
        CompanionLink.parse(Uri.parse('dyngis://signin'))?.request,
        CompanionRequest.signIn,
      );
      expect(
        CompanionLink.parse(Uri.parse('dyngis:/signin'))?.request,
        CompanionRequest.signIn,
      );
      expect(
        CompanionLink.parse(Uri.parse('dyngis://signout'))?.request,
        CompanionRequest.signOut,
      );
      expect(
        CompanionLink.parse(Uri.parse('dyngis:/signout'))?.request,
        CompanionRequest.signOut,
      );
    });

    test('is case-insensitive, as schemes and hosts are on the wire', () {
      expect(
        CompanionLink.parse(Uri.parse('DYNGIS://SignOut'))?.request,
        CompanionRequest.signOut,
      );
    });

    test('ignores anything that is not ours', () {
      // The activity also receives the launcher intent and, in other builds,
      // https links. None of them should move the session.
      for (final String link in <String>[
        'https://daralshayuat.dynaops365.net',
        'dyngis://',
        'dyngis://something-else',
        'otherapp://signout',
      ]) {
        expect(
          CompanionLink.parse(Uri.parse(link))?.request,
          isNull,
          reason: link,
        );
      }
    });

    test('adopts a session the PWA passes in', () {
      final String payload = base64Url.encode(
        utf8.encode(
          jsonEncode(<String, dynamic>{
            'token': _jwt(DateTime.now().add(const Duration(days: 1))),
            'userId': 'user-42',
            'expireAt': '2026-09-17T22:01:13.813763',
            'isSuperAdmin': false,
          }),
        ),
      );

      final CompanionCall? call =
          CompanionLink.parse(Uri.parse('dyngis://signin?handoff=$payload'));

      expect(call?.request, CompanionRequest.signIn);
      expect(call?.session?.userId, 'user-42');
    });

    test('drops a payload that cannot be trusted', () {
      // A custom scheme is not a verified channel — anything on the device can
      // send one — so an expired, malformed or identity-less token has to be
      // refused rather than stored. The rep then just sees the login screen.
      final String expired = base64Url.encode(
        utf8.encode(
          jsonEncode(<String, dynamic>{
            'token': _jwt(DateTime.now().subtract(const Duration(hours: 1))),
            'userId': 'user-42',
          }),
        ),
      );

      for (final String handoff in <String>[expired, 'not-base64!!', '']) {
        final CompanionCall? call =
            CompanionLink.parse(Uri.parse('dyngis://signin?handoff=$handoff'));
        // Still a sign-in request — just one with nothing to adopt.
        expect(call?.request, CompanionRequest.signIn, reason: handoff);
        expect(call?.session, isNull, reason: handoff);
      }
    });
  });
}

/// A JWT whose `exp` claim says [expiry]. AuthSession reads expiry from the
/// claim rather than the payload's `expireAt` string, so the test has to put
/// it where the code actually looks.
String _jwt(DateTime expiry) {
  String seg(Map<String, dynamic> claims) =>
      base64Url.encode(utf8.encode(jsonEncode(claims))).replaceAll('=', '');

  return '${seg(<String, dynamic>{'alg': 'HS256'})}'
      '.${seg(<String, dynamic>{
        'exp': expiry.toUtc().millisecondsSinceEpoch ~/ 1000,
        'CurrentUserId': 'user-42',
      })}'
      '.signature';
}
