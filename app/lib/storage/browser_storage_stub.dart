import 'browser_storage.dart';

/// The native apps keep their identity in the system keystore instead.
BrowserStorageBackend defaultBrowserStorage() => const _Unsupported();

class _Unsupported implements BrowserStorageBackend {
  const _Unsupported();

  @override
  bool get supported => false;

  @override
  Future<BrowserStorage?> open() async => null;

  @override
  Future<BrowserStorage> create() =>
      throw UnsupportedError('only the browser remembers this way');

  @override
  Future<void> erase() async {}
}
