import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:sodium/sodium.dart';

import '../crypto/encoding.dart';
import '../crypto/identity_store.dart';
import 'vault_file.dart';

/// Thrown when the vault exists but can't be opened.
class VaultException implements Exception {
  const VaultException(this.message);
  final String message;

  @override
  String toString() => 'VaultException: $message';
}

/// The app's encrypted on-device storage: contacts, call history and notes,
/// guest links and settings.
///
/// Everything is kept as one key-value map, encrypted with
/// XChaCha20-Poly1305 under a random 256-bit key that lives in the operating
/// system's keystore (never next to the file). The file is rewritten
/// atomically on every change. It is small (kilobytes), so this stays fast,
/// and it works the same on every platform.
///
/// File layout: `"SOTTOVAULT1\0" || nonce (24) || ciphertext`, with the
/// 12-byte header as additional data. The plaintext is
/// `{"v":1,"values":{…}}`.
class Vault implements SecretStore {
  Vault._(this._sodium, this._key, this._file, this._values);

  /// Name of the vault key in the OS keystore.
  static const String keyName = 'sotto.vault.key.v1';

  static final Uint8List _header = Uint8List.fromList(
    utf8.encode('SOTTOVAULT1\u0000'),
  );

  final Sodium _sodium;
  final SecureKey _key;
  final VaultFile _file;
  final Map<String, String> _values;
  Future<void> _writes = Future.value();

  /// Opens the vault, creating an empty one (and its key) on first use.
  ///
  /// Throws [VaultException] if a vault file exists but its key is missing
  /// or it can't be decrypted (damaged, or from another installation).
  static Future<Vault> open({
    required Sodium sodium,
    required SecretStore keys,
    required VaultFile file,
  }) async {
    final aead = sodium.crypto.aeadXChaCha20Poly1305IETF;
    final bytes = await file.read();
    final storedKey = await keys.read(keyName);

    if (bytes == null) {
      final SecureKey key;
      if (storedKey != null) {
        key = _decodeKey(sodium, storedKey);
      } else {
        key = aead.keygen();
        await keys.write(keyName, b64Encode(key.extractBytes()));
      }
      final vault = Vault._(sodium, key, file, {});
      await vault._save();
      return vault;
    }

    if (storedKey == null) {
      throw const VaultException(
        'the key for the stored data is missing from the system keystore',
      );
    }
    final key = _decodeKey(sodium, storedKey);
    final headerLength = _header.length;
    final nonceLength = aead.nonceBytes;
    if (bytes.length < headerLength + nonceLength + aead.aBytes ||
        !bytesEqual(bytes.sublist(0, headerLength), _header)) {
      key.dispose();
      throw const VaultException('the stored data is not a Sotto vault');
    }
    try {
      final plain = aead.decrypt(
        cipherText: bytes.sublist(headerLength + nonceLength),
        nonce: bytes.sublist(headerLength, headerLength + nonceLength),
        key: key,
        additionalData: _header,
      );
      final json = jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;
      if (json['v'] != 1) throw const FormatException('unknown version');
      final values = (json['values'] as Map<String, dynamic>).map(
        (k, v) => MapEntry(k, v as String),
      );
      return Vault._(sodium, key, file, values);
    } catch (_) {
      key.dispose();
      throw const VaultException('the stored data could not be decrypted');
    }
  }

  static SecureKey _decodeKey(Sodium sodium, String stored) {
    final bytes = b64Decode(stored);
    if (bytes.length != sodium.crypto.aeadXChaCha20Poly1305IETF.keyBytes) {
      throw const VaultException('the stored vault key is damaged');
    }
    final key = SecureKey.fromList(sodium, bytes);
    bytes.fillRange(0, bytes.length, 0);
    return key;
  }

  /// Deletes a vault file and its key (e.g. after it could not be opened,
  /// or when the user erases everything).
  static Future<void> erase({
    required SecretStore keys,
    required VaultFile file,
  }) async {
    await file.delete();
    await keys.delete(keyName);
  }

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) {
    _values[key] = value;
    return _save();
  }

  @override
  Future<void> delete(String key) {
    if (_values.remove(key) == null) return _writes;
    return _save();
  }

  /// A copy of everything stored (for backups).
  Map<String, String> snapshot() => Map.of(_values);

  /// Replaces everything stored (when restoring a backup).
  Future<void> replaceAll(Map<String, String> values) {
    _values
      ..clear()
      ..addAll(values);
    return _save();
  }

  /// Moves [keys] from [old] (where earlier versions kept settings) into the
  /// vault, unless the vault already has them.
  Future<void> migrateFrom(SecretStore old, Iterable<String> keys) async {
    for (final key in keys) {
      final value = await old.read(key);
      if (value == null) continue;
      if (!_values.containsKey(key)) await write(key, value);
      await old.delete(key);
    }
  }

  /// Writes are queued so the file always ends up with the latest values.
  Future<void> _save() {
    final result = _writes.then((_) => _file.write(_encrypt()));
    _writes = result.catchError((Object _) {});
    return result;
  }

  Uint8List _encrypt() {
    final aead = _sodium.crypto.aeadXChaCha20Poly1305IETF;
    final nonce = _sodium.randombytes.buf(aead.nonceBytes);
    final plain = utf8.encode(jsonEncode({'v': 1, 'values': _values}));
    final cipher = aead.encrypt(
      message: plain,
      nonce: nonce,
      key: _key,
      additionalData: _header,
    );
    return concatBytes([_header, nonce, cipher]);
  }

  /// Waits for pending writes (tests, and before exporting a backup).
  Future<void> flush() => _writes;

  void dispose() => _key.dispose();
}
