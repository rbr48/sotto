import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:sodium/sodium_sumo.dart';

import '../crypto/encoding.dart';

/// Why a backup could not be created or opened.
enum BackupProblem {
  /// The text is not a Sotto backup.
  notABackup,

  /// Made by a newer version of Sotto.
  unsupportedVersion,

  /// Wrong passphrase, or the file was changed or damaged.
  wrongPassphrase,

  /// The passphrase is too short.
  weakPassphrase,
}

class BackupException implements Exception {
  const BackupException(this.problem);
  final BackupProblem problem;

  @override
  String toString() => 'BackupException: ${problem.name}';
}

/// What a backup holds: the identity's master secret and the vault's
/// contents (contacts, guest links, settings, optionally call history).
@immutable
class BackupContents {
  const BackupContents({
    required this.masterSecret,
    required this.values,
    required this.createdAt,
  });

  final Uint8List masterSecret;
  final Map<String, String> values;
  final DateTime createdAt;
}

/// Encrypted backups: Argon2id derives a key from the user's passphrase, and
/// XChaCha20-Poly1305 encrypts the contents.
///
/// A backup is one line of JSON:
///
/// ```
/// {"sotto":"backup","v":1,"kdf":{"alg":"argon2id13","ops":3,"mem":67108864,
///  "salt":"…"},"nonce":"…","data":"…"}
/// ```
///
/// The additional data binds the header:
/// `"sotto-backup-v1\0" || JSON[v, alg, ops, mem, salt, nonce]`, so changing
/// the parameters makes decryption fail. See `docs/PROTOCOL.md` §8.
abstract final class Backup {
  static const int minPassphraseLength = 12;

  /// Argon2id cost: 3 passes over 64 MiB. Slow enough to make guessing
  /// passphrases expensive, light enough for older phones.
  static const int defaultOpsLimit = 3;
  static const int defaultMemLimit = 64 * 1024 * 1024;

  /// Limits accepted when opening, so a crafted file can't make the app
  /// spend minutes or gigabytes.
  static const int _maxOpsLimit = 10;
  static const int _minMemLimit = 8 * 1024 * 1024;
  static const int _maxMemLimit = 1024 * 1024 * 1024;

  static const String _alg = 'argon2id13';
  static const String fileExtension = 'sottobackup';

  static String create(
    SodiumSumo sodium, {
    required String passphrase,
    required Uint8List masterSecret,
    required Map<String, String> values,
    DateTime? now,
    int opsLimit = defaultOpsLimit,
    int memLimit = defaultMemLimit,
    @visibleForTesting Uint8List? fixedSalt,
    @visibleForTesting Uint8List? fixedNonce,
  }) {
    if (passphrase.trim().length < minPassphraseLength) {
      throw const BackupException(BackupProblem.weakPassphrase);
    }
    final aead = sodium.crypto.aeadXChaCha20Poly1305IETF;
    // Tests pin the salt and nonce to check the exact bytes. Production
    // passes neither, and the random draws happen in the same order as before.
    final salt =
        fixedSalt ?? sodium.randombytes.buf(sodium.crypto.pwhash.saltBytes);
    final nonce = fixedNonce ?? sodium.randombytes.buf(aead.nonceBytes);
    final key = _deriveKey(sodium, passphrase, salt, opsLimit, memLimit);
    try {
      final plain = utf8.encode(
        jsonEncode({
          'master': b64Encode(masterSecret),
          'values': values,
          'created': (now ?? DateTime.now()).toUtc().toIso8601String(),
        }),
      );
      final data = aead.encrypt(
        message: plain,
        nonce: nonce,
        key: key,
        additionalData: _additionalData(opsLimit, memLimit, salt, nonce),
      );
      return jsonEncode({
        'sotto': 'backup',
        'v': 1,
        'kdf': {
          'alg': _alg,
          'ops': opsLimit,
          'mem': memLimit,
          'salt': b64Encode(salt),
        },
        'nonce': b64Encode(nonce),
        'data': b64Encode(data),
      });
    } finally {
      key.dispose();
    }
  }

  /// Opens a backup. Throws [BackupException].
  static BackupContents open(
    SodiumSumo sodium,
    String text,
    String passphrase,
  ) {
    final int ops, mem;
    final Uint8List salt, nonce, data;
    try {
      final json = jsonDecode(text.trim()) as Map<String, dynamic>;
      if (json['sotto'] != 'backup') {
        throw const BackupException(BackupProblem.notABackup);
      }
      if (json['v'] != 1) {
        throw const BackupException(BackupProblem.unsupportedVersion);
      }
      final kdf = json['kdf'] as Map<String, dynamic>;
      if (kdf['alg'] != _alg) {
        throw const BackupException(BackupProblem.unsupportedVersion);
      }
      ops = kdf['ops'] as int;
      mem = kdf['mem'] as int;
      salt = b64Decode(kdf['salt'] as String);
      nonce = b64Decode(json['nonce'] as String);
      data = b64Decode(json['data'] as String);
    } on BackupException {
      rethrow;
    } catch (_) {
      throw const BackupException(BackupProblem.notABackup);
    }
    final aead = sodium.crypto.aeadXChaCha20Poly1305IETF;
    if (ops < 1 ||
        ops > _maxOpsLimit ||
        mem < _minMemLimit ||
        mem > _maxMemLimit ||
        salt.length != sodium.crypto.pwhash.saltBytes ||
        nonce.length != aead.nonceBytes) {
      throw const BackupException(BackupProblem.notABackup);
    }

    final key = _deriveKey(sodium, passphrase, salt, ops, mem);
    final Uint8List plain;
    try {
      plain = aead.decrypt(
        cipherText: data,
        nonce: nonce,
        key: key,
        additionalData: _additionalData(ops, mem, salt, nonce),
      );
    } catch (_) {
      throw const BackupException(BackupProblem.wrongPassphrase);
    } finally {
      key.dispose();
    }
    try {
      final json = jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;
      final master = b64Decode(json['master'] as String);
      if (master.length != sodium.crypto.kdf.keyBytes) {
        throw const FormatException('master secret');
      }
      return BackupContents(
        masterSecret: master,
        values: (json['values'] as Map<String, dynamic>).map(
          (k, v) => MapEntry(k, v as String),
        ),
        createdAt: DateTime.parse(json['created'] as String),
      );
    } catch (_) {
      throw const BackupException(BackupProblem.notABackup);
    }
  }

  /// A random passphrase the user can write down: 25 characters from the
  /// Crockford base32 alphabet in groups of five (125 bits).
  static String generatePassphrase(Sodium sodium) {
    const alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
    final groups = <String>[];
    for (var g = 0; g < 5; g++) {
      final buffer = StringBuffer();
      for (var i = 0; i < 5; i++) {
        buffer.write(alphabet[sodium.randombytes.uniform(alphabet.length)]);
      }
      groups.add('$buffer');
    }
    return groups.join('-');
  }

  static SecureKey _deriveKey(
    SodiumSumo sodium,
    String passphrase,
    Uint8List salt,
    int ops,
    int mem,
  ) => sodium.crypto.pwhash.callStr(
    outLen: sodium.crypto.aeadXChaCha20Poly1305IETF.keyBytes,
    password: passphrase.trim(),
    salt: salt,
    opsLimit: ops,
    memLimit: mem,
    alg: CryptoPwhashAlgorithm.argon2id13,
  );

  static Uint8List _additionalData(
    int ops,
    int mem,
    Uint8List salt,
    Uint8List nonce,
  ) => concatBytes([
    domainLabel('sotto-backup-v1'),
    utf8.encode(
      jsonEncode([1, _alg, ops, mem, b64Encode(salt), b64Encode(nonce)]),
    ),
  ]);

  /// Vault entries that belong to this device and are never backed up.
  static const deviceOnlyKeys = {
    'sotto.lock.v1',
    'sotto.devices.v1',
    'sotto.settings.desktop',
  };
}
