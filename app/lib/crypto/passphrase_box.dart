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
    final key = derive(
      sodium: sodium,
      passphrase: passphrase,
      salt: salt,
      opsLimit: opsLimit,
      memLimit: memLimit,
    );
    try {
      return key.seal(
        nonce: nonce,
        additionalData: additionalData,
        plain: plain,
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
    final key = derive(
      sodium: sodium,
      passphrase: passphrase,
      salt: salt,
      opsLimit: opsLimit,
      memLimit: memLimit,
    );
    try {
      return key.open(
        nonce: nonce,
        additionalData: additionalData,
        cipher: cipher,
      );
    } finally {
      key.dispose();
    }
  }

  /// Derives the key once, for a caller that seals or opens many messages
  /// under one passphrase and salt. Argon2id is the slow step, so each
  /// message then costs only the cipher. The caller must [PassphraseKey.dispose]
  /// the key.
  static PassphraseKey derive({
    required SodiumSumo sodium,
    required String passphrase,
    required Uint8List salt,
    required int opsLimit,
    required int memLimit,
  }) => PassphraseKey._(
    sodium,
    sodium.crypto.pwhash.callStr(
      outLen: sodium.crypto.aeadXChaCha20Poly1305IETF.keyBytes,
      password: passphrase,
      salt: salt,
      opsLimit: opsLimit,
      memLimit: memLimit,
      alg: CryptoPwhashAlgorithm.argon2id13,
    ),
  );
}

/// The 32-byte key of a passphrase, from [PassphraseBox.derive]. Each message
/// still needs its own nonce, and the same nonce must never be used twice with
/// this key.
final class PassphraseKey {
  PassphraseKey._(this._sodium, this._key);

  final SodiumSumo _sodium;
  final SecureKey _key;

  /// Encrypts [plain]: the ciphertext followed by its 16-byte tag.
  Uint8List seal({
    required Uint8List nonce,
    required Uint8List additionalData,
    required Uint8List plain,
  }) => _sodium.crypto.aeadXChaCha20Poly1305IETF.encrypt(
    message: plain,
    nonce: nonce,
    key: _key,
    additionalData: additionalData,
  );

  /// Decrypts [cipher]. Returns `null` when it was not sealed with this key,
  /// nonce and additional data.
  Uint8List? open({
    required Uint8List nonce,
    required Uint8List additionalData,
    required Uint8List cipher,
  }) {
    try {
      return _sodium.crypto.aeadXChaCha20Poly1305IETF.decrypt(
        cipherText: cipher,
        nonce: nonce,
        key: _key,
        additionalData: additionalData,
      );
    } catch (_) {
      return null;
    }
  }

  /// Wipes the key. The key cannot be used afterwards.
  void dispose() => _key.dispose();
}
