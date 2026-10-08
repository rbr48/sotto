import 'package:flutter/foundation.dart';

/// Build-time configuration. Override the relay with
/// `--dart-define=SOTTO_RELAY_URL=wss://example.com/relay`, and the address
/// in links with `--dart-define=SOTTO_LINK_BASE=https://example.com/`.
abstract final class SottoConfig {
  static const String _relayOverride = String.fromEnvironment(
    'SOTTO_RELAY_URL',
  );
  static const String _defaultRelay = 'wss://call.sottocall.com/relay';

  /// The public address in links, when it is not the relay's site
  /// (`--dart-define=SOTTO_LINK_BASE=https://call.example.com/`).
  static const String _linkOverride = String.fromEnvironment('SOTTO_LINK_BASE');

  /// Earlier built-in servers. The same server still answers there, so a
  /// user who picked one of these by hand is moved to the built-in server.
  static const Set<String> formerDefaultHosts = {'sotto.izhaanintellect.fun'};

  /// The relay to connect to. The web build talks to the server it was
  /// loaded from, so a self-hosted copy works without rebuilding.
  static Uri get relayUrl {
    if (_relayOverride.isNotEmpty) return Uri.parse(_relayOverride);
    if (kIsWeb) return relayUrlFor(Uri.base);
    return Uri.parse(_defaultRelay);
  }

  /// Base for call links: the web app's own address, or the relay's site.
  static Uri get linkBase {
    if (_linkOverride.isNotEmpty) return Uri.parse(_linkOverride);
    if (kIsWeb && (Uri.base.scheme == 'http' || Uri.base.scheme == 'https')) {
      return Uri(
        scheme: Uri.base.scheme,
        host: Uri.base.host,
        port: Uri.base.hasPort ? Uri.base.port : null,
        path: Uri.base.path,
      );
    }
    final relay = relayUrl;
    return Uri(
      scheme: relay.scheme == 'ws' ? 'http' : 'https',
      host: relay.host,
      port: relay.hasPort ? relay.port : null,
      path: '/',
    );
  }

  @visibleForTesting
  static Uri relayUrlFor(Uri page) {
    if (page.scheme != 'http' && page.scheme != 'https') {
      return Uri.parse(_defaultRelay);
    }
    return Uri(
      scheme: page.scheme == 'https' ? 'wss' : 'ws',
      host: page.host,
      port: page.hasPort ? page.port : null,
      path: '/relay',
    );
  }
}
