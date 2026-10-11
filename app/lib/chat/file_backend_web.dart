import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'file_backend.dart';

class WebFileBackend implements FileBackend {
  web.IDBDatabase? _db;

  static const String _dbName = 'sotto_files';
  static const String _storeName = 'files';

  Future<web.IDBDatabase> _database([int? version]) async {
    if (_db != null) return _db!;
    final request = version == null
        ? web.window.indexedDB.open(_dbName)
        : web.window.indexedDB.open(_dbName, version);
    request.onupgradeneeded = (web.Event _) {
      final db = request.result! as web.IDBDatabase;
      if (!db.objectStoreNames.contains(_storeName)) {
        db.createObjectStore(_storeName);
      }
    }.toJS;
    final db = (await _done(request))! as web.IDBDatabase;
    if (!db.objectStoreNames.contains(_storeName)) {
      db.close();
      return _database(db.version + 1);
    }
    db.onversionchange = (web.Event _) {
      db.close();
      _db = null;
    }.toJS;
    return _db = db;
  }

  @override
  Future<void> write(String name, Uint8List bytes) async {
    final db = await _database();
    final tx = db.transaction(_storeName.toJS, 'readwrite');
    final store = tx.objectStore(_storeName);
    await _done(store.put(bytes.toJS, name.toJS));
  }

  @override
  Future<Uint8List?> read(String name) async {
    final db = await _database();
    final tx = db.transaction(_storeName.toJS);
    final store = tx.objectStore(_storeName);
    final result = await _done(store.get(name.toJS));
    if (result == null) return null;
    return (result as JSUint8Array).toDart;
  }

  @override
  Future<void> delete(String name) async {
    final db = await _database();
    final tx = db.transaction(_storeName.toJS, 'readwrite');
    final store = tx.objectStore(_storeName);
    await _done(store.delete(name.toJS));
  }

  @override
  Future<void> deleteAll() async {
    _db?.close();
    _db = null;
    await _done(web.window.indexedDB.deleteDatabase(_dbName));
  }

  Future<JSAny?> _done(web.IDBRequest request) {
    final completer = Completer<JSAny?>();
    request.onsuccess = (web.Event _) {
      completer.complete(request.result);
    }.toJS;
    request.onerror = (web.Event _) {
      completer.completeError(
        StateError('web file storage: ${request.error?.message ?? 'failed'}'),
      );
    }.toJS;
    return completer.future;
  }
}

FileBackend defaultFileBackend([Object? directory]) => WebFileBackend();
