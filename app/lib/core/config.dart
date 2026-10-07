import 'package:flutter/foundation.dart';

/// Build-time configuration. Override with
/// `--dart-define=SOTTO_RELAY_URL=wss://example.com/dev/rooms`.
abstract final class SottoConfig {
  static const String _relayOverride = String.fromEnvironment(
    'SOTTO_RELAY_URL',
  );
  static const String _defaultRelay =
      'wss://sotto.izhaanintellect.fun/dev/rooms';

  /// Relay used by the Phase 1 test call screen.
  ///
  /// The web build talks to the server it was loaded from, so a self-hosted
  /// copy works without rebuilding.
  static String get devRoomsUrl {
    if (_relayOverride.isNotEmpty) return _relayOverride;
    if (kIsWeb) return devRoomsUrlFor(Uri.base);
    return _defaultRelay;
  }

  @visibleForTesting
  static String devRoomsUrlFor(Uri page) {
    if (page.scheme != 'http' && page.scheme != 'https') return _defaultRelay;
    return Uri(
      scheme: page.scheme == 'https' ? 'wss' : 'ws',
      host: page.host,
      port: page.hasPort ? page.port : null,
      path: '/dev/rooms',
    ).toString();
  }
}
