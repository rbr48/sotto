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
