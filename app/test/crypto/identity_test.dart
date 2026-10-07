import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium.dart';
import 'package:sotto/crypto/encoding.dart';
import 'package:sotto/crypto/self_test.dart';
import 'package:sotto/crypto/sotto_crypto.dart';

void main() {
  late Sodium sodium;

  setUpAll(() async {
    sodium = await SottoCrypto.init();
  });

  test('matches the independently generated test vectors', () {
    expect(runCryptoSelfTest(sodium), isEmpty);
  });

  test('the same master secret always gives the same identity', () {
    final master = sodium.crypto.kdf.keygen();
    final first = Identity.fromMasterSecret(sodium, master);
    final second = Identity.fromMasterSecret(sodium, master);
    expect(first.publicIdentity, second.publicIdentity);
    expect(first.publicIdentity.signKey, isNot(first.publicIdentity.boxKey));
  });

  test('generated identities are unique', () {
    final ids = {for (var i = 0; i < 20; i++) Identity.generate(sodium).id};
    expect(ids, hasLength(20));
  });

  group('identity cards', () {
    test('a card verifies and yields the public identity', () {
      final identity = Identity.generate(sodium);
      final card = identity.card(sodium).encode();
      expect(IdentityCard.verify(sodium, card), identity.publicIdentity);
      expect(
        IdentityCard.verify(sodium, jsonDecode(card)),
        identity.publicIdentity,
      );
    });

    test('swapping in another encryption key breaks the card', () {
      final identity = Identity.generate(sodium);
      final attacker = Identity.generate(sodium);
      final json = identity.card(sodium).toJson()
        ..['box'] = b64Encode(attacker.publicIdentity.boxKey);
      expect(
        () => IdentityCard.verify(sodium, json),
        throwsA(isA<InvalidIdentityException>()),
      );
    });

    test('malformed cards are rejected', () {
      for (final card in [
        'nope',
        '{}',
        '{"v":2}',
        '{"v":1,"sign":"AA","box":"AA","sig":"AA"}',
        {'v': 1, 'sign': 5},
      ]) {
        expect(
          () => IdentityCard.verify(sodium, card),
          throwsA(isA<InvalidIdentityException>()),
          reason: '$card',
        );
      }
    });
  });

  group('safety numbers', () {
    test('both people see the same 12 groups of 5 digits', () {
      final a = Identity.generate(sodium).publicIdentity;
      final b = Identity.generate(sodium).publicIdentity;
      final number = SafetyNumber.compute(sodium, a, b);
      expect(number, matches(RegExp(r'^\d{5}( \d{5}){11}$')));
      expect(SafetyNumber.compute(sodium, b, a), number);
    });

    test('a different person gives a different number', () {
      final a = Identity.generate(sodium).publicIdentity;
      final b = Identity.generate(sodium).publicIdentity;
      final c = Identity.generate(sodium).publicIdentity;
      expect(
        SafetyNumber.compute(sodium, a, b),
        isNot(SafetyNumber.compute(sodium, a, c)),
      );
    });
  });

  group('IdentityStore', () {
    test('creates an identity once and reloads the same one', () async {
      final secrets = MemorySecretStore();
      final created = await IdentityStore(sodium, secrets).loadOrCreate();
      final reloaded = await IdentityStore(sodium, secrets).loadOrCreate();
      expect(reloaded.publicIdentity, created.publicIdentity);
    });

    test(
      'load returns null when nothing is stored, and delete removes it',
      () async {
        final secrets = MemorySecretStore();
        final store = IdentityStore(sodium, secrets);
        expect(await store.load(), isNull);
        await store.loadOrCreate();
        await store.delete();
        expect(await store.load(), isNull);
      },
    );

    test(
      'a corrupt stored secret is reported, not silently replaced',
      () async {
        final secrets = MemorySecretStore();
        await secrets.write(IdentityStore.masterSecretKey, 'AAAA');
        expect(
          () => IdentityStore(sodium, secrets).load(),
          throwsA(isA<InvalidIdentityException>()),
        );
      },
    );
  });
}
