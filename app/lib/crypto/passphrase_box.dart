import 'dart:typed_data';

import 'package:sodium/sodium_sumo.dart';

/// Seals bytes under a key that a passphrase derives.
///
/// Argon2id (the `argon2id13` variant) turns the passphrase and a salt into a
/// 32-byte key, and XChaCha20-Poly1305 IETF encrypts with that key. The caller
/// supplies the salt, the nonce and the additional data. That keeps the
/// ciphertext's header under the caller's control: the caller builds the
/// additional data, so the same bytes come out for the same inputs.
///
/// Nonces must be random and never reused with the same passphrase and salt.
abstract final class PassphraseBox {
  /// Encrypts [plain]. The result is the ciphertext followed by its 16-byte
  /// authentication tag.
  static Uint8List seal({
    required SodiumSumo sodium,
    required String passphrase,
    required Uint8List salt,
    required Uint8List nonce,
    required int opsLimit,
    required int memLimit,
    required Uint8List additionalData,
    required Uint8List plain,
  }) {
    final aead = sodium.crypto.aeadXChaCha20Poly1305IETF;
    final key = _deriveKey(sodium, passphrase, salt, opsLimit, memLimit);
    try {
      return aead.encrypt(
        message: plain,
        nonce: nonce,
        key: key,
        additionalData: additionalData,
      );
    } finally {
      key.dispose();
    }
  }

  /// Decrypts [cipher]. Returns `null` when the passphrase is wrong, or when
  /// the ciphertext, nonce, salt, cost or additional data was changed.
  static Uint8List? open({
    required SodiumSumo sodium,
    required String passphrase,
    required Uint8List salt,
    required Uint8List nonce,
    required int opsLimit,
    required int memLimit,
    required Uint8List additionalData,
    required Uint8List cipher,
  }) {
    final aead = sodium.crypto.aeadXChaCha20Poly1305IETF;
    final key = _deriveKey(sodium, passphrase, salt, opsLimit, memLimit);
    try {
      return aead.decrypt(
        cipherText: cipher,
        nonce: nonce,
        key: key,
        additionalData: additionalData,
      );
    } catch (_) {
      return null;
    } finally {
      key.dispose();
    }
  }

  static SecureKey _deriveKey(
    SodiumSumo sodium,
    String passphrase,
    Uint8List salt,
    int opsLimit,
    int memLimit,
  ) => sodium.crypto.pwhash.callStr(
    outLen: sodium.crypto.aeadXChaCha20Poly1305IETF.keyBytes,
    password: passphrase,
    salt: salt,
    opsLimit: opsLimit,
    memLimit: memLimit,
    alg: CryptoPwhashAlgorithm.argon2id13,
  );
}
