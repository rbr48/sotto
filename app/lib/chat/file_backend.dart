import 'dart:typed_data';

export 'file_backend_stub.dart'
    if (dart.library.io) 'file_backend_io.dart'
    if (dart.library.js_interop) 'file_backend_web.dart';

/// Underlying storage for encrypted received and outgoing files.
abstract interface class FileBackend {
  Future<void> write(String name, Uint8List bytes);
  Future<Uint8List?> read(String name);
  Future<void> delete(String name);
  Future<void> deleteAll();
}

/// An in-memory implementation of [FileBackend], suitable for unit tests and fallbacks.
class MemoryFileBackend implements FileBackend {
  final Map<String, Uint8List> _files = {};

  @override
  Future<void> write(String name, Uint8List bytes) async {
    _files[name] = bytes;
  }

  @override
  Future<Uint8List?> read(String name) async => _files[name];

  @override
  Future<void> delete(String name) async {
    _files.remove(name);
  }

  @override
  Future<void> deleteAll() async {
    _files.clear();
  }
}
