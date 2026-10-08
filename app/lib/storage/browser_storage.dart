import '../crypto/identity_store.dart';
import 'vault_file.dart';

export 'browser_storage_stub.dart'
    if (dart.library.js_interop) 'browser_storage_web.dart';

/// Where a browser keeps a remembered identity ("Remember me on this
/// browser"): its secrets and the encrypted vault.
class BrowserStorage {
  const BrowserStorage({required this.secrets, required this.vaultFile});

  final SecretStore secrets;
  final VaultFile vaultFile;
}

/// Storage that survives reloading the page, if the browser offers it.
///
/// Off by default: a browser session keeps nothing unless the user turns on
/// "Remember me on this browser".
abstract interface class BrowserStorageBackend {
  /// Whether this platform can remember anything (only the browser can).
  bool get supported;

  /// The remembered identity's storage, or `null` if nothing is remembered.
  Future<BrowserStorage?> open();

  /// Creates (or reopens) the storage.
  Future<BrowserStorage> create();

  /// Deletes everything Sotto remembered in this browser.
  Future<void> erase();
}

/// For tests: keeps "browser storage" in memory, across [AppController]s.
class MemoryBrowserStorage implements BrowserStorageBackend {
  BrowserStorage? _stored;

  @override
  bool get supported => true;

  @override
  Future<BrowserStorage?> open() async => _stored;

  @override
  Future<BrowserStorage> create() async => _stored ??= BrowserStorage(
    secrets: MemorySecretStore(),
    vaultFile: MemoryVaultFile(),
  );

  @override
  Future<void> erase() async => _stored = null;
}
