import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium_sumo.dart';
import 'package:sotto/crypto/passphrase_box.dart';
import 'package:sotto/crypto/sotto_crypto.dart';

void main() {
  late SodiumSumo sodium;
  setUpAll(
    () async => sodium = SottoCrypto.passwordHashing(await SottoCrypto.init())!,
  );

  // Cheap cost keeps these tests fast; the backup tests cover the defaults.
  const correctPassphrase = 'correct passphrase';
  const ops = 1;
  const mem = 8 << 20;
  final salt = Uint8List.fromList(List.generate(16, (i) => i + 1));
  final nonce = Uint8List.fromList(List.generate(24, (i) => i + 101));
  final additionalData = Uint8List.fromList('sotto-test-ad'.codeUnits);
  final plain = Uint8List.fromList('the bytes to protect'.codeUnits);

  Uint8List seal({
    String passphrase = correctPassphrase,
    Uint8List? plainText,
  }) => PassphraseBox.seal(
    sodium: sodium,
    passphrase: passphrase,
    salt: salt,
    nonce: nonce,
    opsLimit: ops,
    memLimit: mem,
    additionalData: additionalData,
    plain: plainText ?? plain,
  );

  Uint8List? open(
    Uint8List cipher, {
    String passphrase = correctPassphrase,
    Uint8List? useSalt,
    Uint8List? useNonce,
    Uint8List? useAdditionalData,
    int useOps = ops,
    int useMem = mem,
  }) => PassphraseBox.open(
    sodium: sodium,
    passphrase: passphrase,
    salt: useSalt ?? salt,
    nonce: useNonce ?? nonce,
    opsLimit: useOps,
    memLimit: useMem,
    additionalData: useAdditionalData ?? additionalData,
    cipher: cipher,
  );

  test('round trip returns the sealed bytes', () {
    final cipher = seal();
    expect(cipher.length, plain.length + 16, reason: 'ciphertext plus tag');
    expect(open(cipher), plain);
  });

  test('the same inputs seal to the same bytes', () {
    expect(seal(), seal());
    expect(seal(), isNot(seal(plainText: Uint8List.fromList([1, 2, 3]))));
  });

  test('a wrong passphrase opens to null', () {
    expect(open(seal(), passphrase: 'correct passphrasE'), isNull);
  });

  test('changed bytes, nonce, salt, data or cost open to null', () {
    final cipher = seal();
    final flipped = Uint8List.fromList(cipher)..[3] ^= 1;
    expect(open(flipped), isNull, reason: 'ciphertext');
    expect(
      open(cipher, useNonce: Uint8List.fromList(nonce)..[0] ^= 1),
      isNull,
      reason: 'nonce',
    );
    expect(
      open(cipher, useSalt: Uint8List.fromList(salt)..[0] ^= 1),
      isNull,
      reason: 'salt',
    );
    expect(
      open(cipher, useAdditionalData: Uint8List.fromList([1, 2, 3])),
      isNull,
      reason: 'additional data',
    );
    expect(open(cipher, useMem: 16 << 20), isNull, reason: 'memory cost');
    expect(open(cipher, useOps: 2), isNull, reason: 'time cost');
  });

  test('a ciphertext shorter than the tag opens to null', () {
    expect(open(Uint8List(3)), isNull);
  });
}
