import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import 'vault_file.dart';

/// The vault file in the app's private support directory.
Future<VaultFile> defaultVaultFile() async {
  final directory = await getApplicationSupportDirectory();
  await directory.create(recursive: true);
  return DiskVaultFile('${directory.path}${Platform.pathSeparator}sotto.vault');
}

/// A vault file on disk, replaced atomically (write a temporary file, then
/// rename it over the old one).
class DiskVaultFile implements VaultFile {
  DiskVaultFile(this.path);

  final String path;

  @override
  Future<Uint8List?> read() async {
    final file = File(path);
    if (!await file.exists()) return null;
    return file.readAsBytes();
  }

  @override
  Future<void> write(Uint8List bytes) async {
    final temporary = File('$path.tmp');
    await temporary.writeAsBytes(bytes, flush: true);
    await temporary.rename(path);
  }

  @override
  Future<void> delete() async {
    for (final name in [path, '$path.tmp']) {
      final file = File(name);
      if (await file.exists()) await file.delete();
    }
  }
}
