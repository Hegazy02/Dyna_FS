import 'dart:convert';

import 'package:dyn_gis/src/data/remembered_account.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const store = RememberedAccountStore();
  const key = 'dyn_gis.remembered_account';

  setUp(() => FlutterSecureStorage.setMockInitialValues(<String, String>{}));

  group('RememberedAccountStore', () {
    test('offers back the account that was saved', () async {
      await store.save(
        const RememberedAccount(
          username: 'rep01',
          password: 'hunter2',
          fullName: 'Mohamed Hegazy',
        ),
      );

      final loaded = await store.load();

      expect(loaded?.username, 'rep01');
      expect(loaded?.password, 'hunter2');
      expect(loaded?.fullName, 'Mohamed Hegazy');
    });

    test('has nothing to suggest on a fresh device', () async {
      expect(await store.load(), isNull);
    });

    test('forgetting an account really removes it', () async {
      await store.save(
        const RememberedAccount(username: 'rep01', password: 'hunter2'),
      );
      await store.clear();

      expect(await store.load(), isNull);
    });

    test('a saved account survives being replaced by a different rep',
        () async {
      await store.save(
        const RememberedAccount(username: 'rep01', password: 'first'),
      );
      await store.save(
        const RememberedAccount(username: 'rep02', password: 'second'),
      );

      final loaded = await store.load();

      // One device, one suggestion: the newest sign-in wins rather than
      // accumulating a list of everyone who ever used this phone.
      expect(loaded?.username, 'rep02');
      expect(loaded?.password, 'second');
    });

    test('a half-written entry is ignored rather than offered', () async {
      FlutterSecureStorage.setMockInitialValues(<String, String>{
        key: jsonEncode(<String, String>{'username': 'rep01'}),
      });

      // A suggestion that fills only the username would put the rep back in
      // front of a password field with no explanation.
      expect(await store.load(), isNull);
    });

    test('a corrupt entry does not throw its way onto the login screen',
        () async {
      FlutterSecureStorage.setMockInitialValues(<String, String>{
        key: 'not json at all',
      });

      expect(await store.load(), isNull);
    });
  });

  group('RememberedAccount', () {
    test('shows the display name, falling back to the username', () {
      const named = RememberedAccount(
        username: 'rep01',
        password: 'x',
        fullName: 'Mohamed Hegazy',
      );
      const unnamed = RememberedAccount(username: 'rep01', password: 'x');

      expect(named.label, 'Mohamed Hegazy');
      expect(unnamed.label, 'rep01');
    });

    test('a blank display name counts as no display name', () {
      const account = RememberedAccount(
        username: 'rep01',
        password: 'x',
        fullName: '   ',
      );

      expect(account.label, 'rep01');
      expect(account.initial, 'R');
    });

    test('the avatar initial never throws on an unusable label', () {
      const account = RememberedAccount(username: '  ', password: 'x');

      expect(account.initial, '?');
    });
  });
}
