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
        CompanionLink.parse(Uri.parse('dyngis://signin')),
        CompanionRequest.signIn,
      );
      expect(
        CompanionLink.parse(Uri.parse('dyngis:/signin')),
        CompanionRequest.signIn,
      );
      expect(
        CompanionLink.parse(Uri.parse('dyngis://signout')),
        CompanionRequest.signOut,
      );
      expect(
        CompanionLink.parse(Uri.parse('dyngis:/signout')),
        CompanionRequest.signOut,
      );
    });

    test('is case-insensitive, as schemes and hosts are on the wire', () {
      expect(
        CompanionLink.parse(Uri.parse('DYNGIS://SignOut')),
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
          CompanionLink.parse(Uri.parse(link)),
          isNull,
          reason: link,
        );
      }
    });
  });
}
