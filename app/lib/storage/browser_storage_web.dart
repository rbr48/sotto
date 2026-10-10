import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import '../crypto/identity_store.dart';
import 'browser_storage.dart';
import 'vault_file.dart';

/// "Remember me on this browser": IndexedDB, with every secret encrypted
/// (AES-GCM) under a key that Web Crypto creates as non-extractable, so no
/// script, ours included, can read the key itself. The vault is stored as
/// it is (it is already encrypted with the vault key, one of the secrets).
///
/// Anyone who can use this browser profile can still open Sotto here, as
/// with the desktop apps and the system keystore: it is for one's own
/// computer, and the app lock's PIN guards the screens.
BrowserStorageBackend defaultBrowserStorage() => _IndexedDbStorage();

const String _databaseName = 'sotto';
const String _table = 'kv';
const String _wrappingKey = 'wrapping-key';
const String _vaultRecord = 'vault';
const String _secretPrefix = 'secret:';

class _IndexedDbStorage implements BrowserStorageBackend {
  web.IDBDatabase? _db;

  @override
  bool get supported => true;

  Future<web.IDBDatabase> _database() async => _db ??= await _openDatabase();

  @override
  Future<BrowserStorage?> open() async {
    final db = await _database();
    final key = await _get(db, _wrappingKey);
    if (key == null) return null;
    return _storage(db, key as web.CryptoKey);
  }

  @override
  Future<BrowserStorage> create() async {
    final db = await _database();
    var key = await _get(db, _wrappingKey);
    if (key == null) {
      key = await web.window.crypto.subtle
          .generateKey(
            _algorithm({'name': 'AES-GCM'.toJS, 'length': 256.toJS}),
            false, // not extractable
            ['encrypt'.toJS, 'decrypt'.toJS].toJS,
          )
          .toDart;
      await _put(db, _wrappingKey, key!);
    }
    return _storage(db, key as web.CryptoKey);
  }

  @override
  Future<void> erase() async {
    _db?.close();
    _db = null;
    await _done(web.window.indexedDB.deleteDatabase(_databaseName));
  }

  BrowserStorage _storage(web.IDBDatabase db, web.CryptoKey key) =>
      BrowserStorage(
        secrets: _EncryptedSecrets(db, key),
        vaultFile: _VaultRecord(db),
      );
}

class _EncryptedSecrets implements SecretStore {
  _EncryptedSecrets(this._db, this._key);

  final web.IDBDatabase _db;
  final web.CryptoKey _key;

  @override
  Future<String?> read(String key) async {
    final stored = await _get(_db, '$_secretPrefix$key');
    if (stored == null) return null;
    final bytes = (stored as JSUint8Array).toDart;
    final iv = bytes.sublist(0, 12);
    final plain = await web.window.crypto.subtle
        .decrypt(_gcm(iv), _key, bytes.sublist(12).toJS)
        .toDart;
    return utf8.decode((plain! as JSArrayBuffer).toDart.asUint8List());
  }

  @override
  Future<void> write(String key, String value) async {
    final random = Uint8List(12).toJS;
    web.window.crypto.getRandomValues(random);
    final iv = random.toDart;
    final cipher = await web.window.crypto.subtle
        .encrypt(_gcm(iv), _key, Uint8List.fromList(utf8.encode(value)).toJS)
        .toDart;
    final sealed = Uint8List.fromList([
      ...iv,
      ...(cipher! as JSArrayBuffer).toDart.asUint8List(),
    ]);
    await _put(_db, '$_secretPrefix$key', sealed.toJS);
  }

  @override
  Future<void> delete(String key) => _delete(_db, '$_secretPrefix$key');

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

class _VaultRecord implements VaultFile {
  _VaultRecord(this._db);

  final web.IDBDatabase _db;

  @override
  Future<Uint8List?> read() async {
    final stored = await _get(_db, _vaultRecord);
    return stored == null ? null : (stored as JSUint8Array).toDart;
  }

  @override
  Future<void> write(Uint8List bytes) => _put(_db, _vaultRecord, bytes.toJS);

  @override
  Future<void> delete() => _delete(_db, _vaultRecord);
}

JSObject _algorithm(Map<String, JSAny> fields) {
  final object = JSObject();
  fields.forEach((name, value) => object.setProperty(name.toJS, value));
  return object;
}

JSObject _gcm(Uint8List iv) =>
    _algorithm({'name': 'AES-GCM'.toJS, 'iv': iv.toJS});

Future<web.IDBDatabase> _openDatabase([int? version]) async {
  final request = version == null
      ? web.window.indexedDB.open(_databaseName)
      : web.window.indexedDB.open(_databaseName, version);
  request.onupgradeneeded = (web.Event _) {
    final db = request.result! as web.IDBDatabase;
    if (!db.objectStoreNames.contains(_table)) db.createObjectStore(_table);
  }.toJS;
  final db = (await _done(request))! as web.IDBDatabase;
  if (!db.objectStoreNames.contains(_table)) {
    // An empty database (created by something else): add the table.
    db.close();
    return _openDatabase(db.version + 1);
  }
  // "Forget this browser" in another tab deletes the database: let it.
  db.onversionchange = (web.Event _) {
    db.close();
  }.toJS;
  return db;
}

Future<JSAny?> _get(web.IDBDatabase db, String key) =>
    _done(db.transaction(_table.toJS).objectStore(_table).get(key.toJS));

Future<void> _put(web.IDBDatabase db, String key, JSAny value) => _done(
  db
      .transaction(_table.toJS, 'readwrite')
      .objectStore(_table)
      .put(value, key.toJS),
);

Future<void> _delete(web.IDBDatabase db, String key) => _done(
  db.transaction(_table.toJS, 'readwrite').objectStore(_table).delete(key.toJS),
);

Future<JSAny?> _done(web.IDBRequest request) {
  final completer = Completer<JSAny?>();
  request.onsuccess = (web.Event _) {
    completer.complete(request.result);
  }.toJS;
  request.onerror = (web.Event _) {
    completer.completeError(
      StateError('browser storage: ${request.error?.message ?? 'failed'}'),
    );
  }.toJS;
  return completer.future;
}
