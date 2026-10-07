import 'vault_file.dart';

/// Without a file system (web) the vault lives in memory for the session.
Future<VaultFile> defaultVaultFile() async => MemoryVaultFile();
