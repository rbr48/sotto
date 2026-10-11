import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import 'file_backend.dart';

class IoFileBackend implements FileBackend {
  IoFileBackend([Future<Directory> Function()? directory])
    : _directory = directory ?? _defaultDirectory;

  final Future<Directory> Function() _directory;

  static Future<Directory> _defaultDirectory() async {
    final support = await getApplicationSupportDirectory();
    return Directory('${support.path}/received_files');
  }

  @override
  Future<void> write(String name, Uint8List bytes) async {
    final dir = await _directory();
    await dir.create(recursive: true);
    final file = File('${dir.path}/$name');
    await file.writeAsBytes(bytes, flush: true);
  }

  @override
  Future<Uint8List?> read(String name) async {
    final file = File('${(await _directory()).path}/$name');
    if (!await file.exists()) return null;
    return file.readAsBytes();
  }

  @override
  Future<void> delete(String name) async {
    final file = File('${(await _directory()).path}/$name');
    if (await file.exists()) {
      await file.delete();
    }
  }

  @override
  Future<void> deleteAll() async {
    try {
      final dir = await _directory();
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
  }
}

FileBackend defaultFileBackend([Future<Directory> Function()? directory]) =>
    IoFileBackend(directory);
