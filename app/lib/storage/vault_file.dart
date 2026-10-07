import 'dart:typed_data';

export 'vault_file_stub.dart' if (dart.library.io) 'vault_file_io.dart';

/// Where the vault's encrypted bytes are kept.
abstract interface class VaultFile {
  /// The stored bytes, or `null` if nothing was stored yet.
  Future<Uint8List?> read();

  /// Replaces the stored bytes; never leaves a half-written file behind.
  Future<void> write(Uint8List bytes);

  Future<void> delete();
}

/// Keeps the vault in memory only: the browser (nothing outlives the tab)
/// and tests.
class MemoryVaultFile implements VaultFile {
  Uint8List? bytes;

  @override
  Future<Uint8List?> read() async => bytes;

  @override
  Future<void> write(Uint8List bytes) async => this.bytes = bytes;

  @override
  Future<void> delete() async => bytes = null;
}
