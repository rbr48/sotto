import 'dart:typed_data';

import 'package:sodium/sodium.dart';

import 'encoding.dart';
import 'envelope.dart';
import 'identity.dart';
import 'safety_number.dart';
import 'test_vectors.dart';

/// Checks this platform's crypto against vectors produced by an independent
/// implementation. Returns a list of failures (empty when everything passes).
///
/// Runs in unit tests on the Dart VM and in the web build (`?selftest=1`), so
/// both platforms are proven to produce identical results.
List<String> runCryptoSelfTest(Sodium sodium) {
  final failures = <String>[];
  void check(String name, bool Function() condition) {
    try {
      if (!condition()) failures.add(name);
    } catch (e) {
      failures.add('$name ($e)');
    }
  }

  Identity fromHex(String hex) {
    final bytes = Uint8List.fromList([
      for (var i = 0; i < hex.length; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16),
    ]);
    final master = SecureKey.fromList(sodium, bytes);
    try {
      return Identity.fromMasterSecret(sodium, master);
    } finally {
      master.dispose();
    }
  }

  final a = fromHex(CryptoTestVectors.masterA);
  final b = fromHex(CryptoTestVectors.masterB);
  try {
    check(
      'identity A keys',
      () =>
          a.id == CryptoTestVectors.aSign &&
          b64Encode(a.publicIdentity.boxKey) == CryptoTestVectors.aBox,
    );
    check(
      'identity B keys',
      () =>
          b.id == CryptoTestVectors.bSign &&
          b64Encode(b.publicIdentity.boxKey) == CryptoTestVectors.bBox,
    );
    check(
      'identity card',
      () => a.card(sodium).encode() == CryptoTestVectors.aCard,
    );
    check(
      'identity card verifies',
      () =>
          IdentityCard.verify(sodium, CryptoTestVectors.aCard) ==
          a.publicIdentity,
    );
    check(
      'safety number',
      () =>
          SafetyNumber.compute(sodium, a.publicIdentity, b.publicIdentity) ==
              CryptoTestVectors.safetyNumber &&
          SafetyNumber.compute(sodium, b.publicIdentity, a.publicIdentity) ==
              CryptoTestVectors.safetyNumber,
    );
    check('open reference envelope', () {
      final codec = EnvelopeCodec(
        sodium,
        b,
        clock: () => DateTime.fromMillisecondsSinceEpoch(
          CryptoTestVectors.innerTimestampMs,
          isUtc: true,
        ),
      );
      final opened = codec.open(
        CryptoTestVectors.sealedAtoB,
        expectedSender: a.id,
      );
      return opened.type == 'test.hello' &&
          opened.body['text'] == 'hello' &&
          opened.sender == a.publicIdentity;
    });
    check('seal and open round trip', () {
      final sealed = EnvelopeCodec(sodium, b).seal(
        recipient: a.publicIdentity,
        type: 'test.reply',
        body: {'ok': true},
      );
      final opened = EnvelopeCodec(
        sodium,
        a,
      ).open(sealed, expectedSender: b.id);
      return opened.type == 'test.reply' && opened.body['ok'] == true;
    });
  } finally {
    a.dispose();
    b.dispose();
  }
  return failures;
}
