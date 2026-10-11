import 'dart:typed_data';

import 'file_backend.dart';

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

FileBackend defaultFileBackend([Object? directory]) => MemoryFileBackend();
