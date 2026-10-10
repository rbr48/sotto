import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sodium/sodium.dart';

import 'encoding.dart';
import 'identity.dart';

/// Minimal key-value store for secrets.
abstract interface class SecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);

  /// Writes [values] and deletes [deleted] as one change. A store that saves
  /// as a whole (the vault) saves all of it in one write, so the change is
  /// stored entirely or not at all. A store that saves key by key applies the
  /// deletes first, then the writes.
  Future<void> writeAll(
    Map<String, String> values, {
    Iterable<String> deleted = const [],
  });
}

/// [SecretStore] backed by the operating system's keystore: Android Keystore,
/// Windows DPAPI/Credential Manager, or libsecret on Linux.
class OsSecretStore implements SecretStore {
  OsSecretStore([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);

  @override
  Future<void> writeAll(
    Map<String, String> values, {
    Iterable<String> deleted = const [],
  }) async {
    for (final key in deleted) {
      await delete(key);
    }
    for (final entry in values.entries) {
      await write(entry.key, entry.value);
    }
  }
}

/// In-memory [SecretStore] for tests and for guests, whose identity must not
/// outlive the call.
class MemorySecretStore implements SecretStore {
  final _values = <String, String>{};

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async => _values[key] = value;

  @override
  Future<void> delete(String key) async => _values.remove(key);

  @override
  Future<void> writeAll(
    Map<String, String> values, {
    Iterable<String> deleted = const [],
  }) async {
    for (final key in deleted) {
      _values.remove(key);
    }
    _values.addAll(values);
  }
}

/// Loads the professional's identity, creating it on first launch.
///
/// Only the 32-byte master secret is stored; both key pairs are re-derived
/// from it (see [Identity.fromMasterSecret]).
class IdentityStore {
  IdentityStore(this._sodium, this._secrets);

  static const String masterSecretKey = 'sotto.identity.master.v1';

  final Sodium _sodium;
  final SecretStore _secrets;

  Future<Identity> loadOrCreate() async {
    final existing = await load();
    if (existing != null) return existing;
    final master = _sodium.crypto.kdf.keygen();
    try {
      await _secrets.write(masterSecretKey, b64Encode(master.extractBytes()));
      return Identity.fromMasterSecret(_sodium, master);
    } finally {
      master.dispose();
    }
  }

  /// The stored identity, or `null` if none exists yet.
  Future<Identity?> load() async {
    final stored = await _secrets.read(masterSecretKey);
    if (stored == null) return null;
    final bytes = b64Decode(stored);
    if (bytes.length != _sodium.crypto.kdf.keyBytes) {
      throw const InvalidIdentityException('stored master secret is corrupt');
    }
    final master = SecureKey.fromList(_sodium, bytes);
    bytes.fillRange(0, bytes.length, 0);
    try {
      return Identity.fromMasterSecret(_sodium, master);
    } finally {
      master.dispose();
    }
  }

  /// Permanently deletes the identity from this device.
  Future<void> delete() => _secrets.delete(masterSecretKey);
}
