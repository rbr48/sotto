import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// A Sotto server: the web address (guest and contact links point there) and
/// its relay (`/relay` on the same host).
@immutable
class ServerAddress {
  const ServerAddress({required this.web, required this.relay});

  final Uri web;
  final Uri relay;

  /// `sotto.example.com` or `localhost:8080`.
  String get label => web.hasPort ? '${web.host}:${web.port}' : web.host;

  /// Parses what a user types: `sotto.example.com`, `https://sotto.example.com`
  /// or, for testing on this computer, `http://localhost:8080`.
  /// Throws [FormatException] with a message for the user.
  static ServerAddress parse(String input) {
    var text = input.trim();
    if (text.isEmpty) throw const FormatException('Enter the server address.');
    if (!text.contains('://')) text = 'https://$text';
    final Uri uri;
    try {
      uri = Uri.parse(text);
    } on FormatException {
      throw const FormatException('That is not a valid address.');
    }
    if (uri.host.isEmpty || uri.userInfo.isNotEmpty) {
      throw const FormatException('That is not a valid address.');
    }
    if (uri.scheme != 'https' && uri.scheme != 'http') {
      throw const FormatException('Use an https:// address.');
    }
    if (uri.scheme == 'http' && !_isLocal(uri.host)) {
      throw const FormatException(
        'Use https:// (plain http is only allowed for this computer).',
      );
    }
    if ((uri.path.isNotEmpty && uri.path != '/') ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const FormatException(
        'Enter only the server name, e.g. sotto.example.com.',
      );
    }
    final port = uri.hasPort ? uri.port : null;
    return ServerAddress(
      web: Uri(scheme: uri.scheme, host: uri.host, port: port, path: '/'),
      relay: Uri(
        scheme: uri.scheme == 'https' ? 'wss' : 'ws',
        host: uri.host,
        port: port,
        path: '/relay',
      ),
    );
  }

  static bool _isLocal(String host) =>
      host == 'localhost' || host == '127.0.0.1' || host == '::1';

  String encode() =>
      jsonEncode({'web': web.toString(), 'relay': relay.toString()});

  static ServerAddress? decode(String? stored) {
    if (stored == null) return null;
    try {
      final json = jsonDecode(stored) as Map<String, dynamic>;
      return ServerAddress(
        web: Uri.parse(json['web'] as String),
        relay: Uri.parse(json['relay'] as String),
      );
    } catch (_) {
      return null;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is ServerAddress && other.web == web && other.relay == relay;

  @override
  int get hashCode => Object.hash(web, relay);
}

/// Checks that a Sotto relay answers at [server]: it must send its login
/// challenge. Returns `null` if it does, otherwise a message for the user.
Future<String?> checkServer(
  ServerAddress server, {
  Duration timeout = const Duration(seconds: 8),
}) async {
  WebSocketChannel? channel;
  try {
    channel = WebSocketChannel.connect(server.relay);
    await channel.ready.timeout(timeout);
    final first = await channel.stream.first.timeout(timeout);
    Object? json;
    try {
      json = jsonDecode('$first');
    } on FormatException {
      json = null;
    }
    if (json is Map && json['type'] == 'challenge') return null;
    return 'That server answered, but it is not a Sotto relay.';
  } on TimeoutException {
    return 'The server did not answer in time.';
  } catch (_) {
    return 'Could not reach a Sotto server at ${server.label}.';
  } finally {
    unawaited(channel?.sink.close());
  }
}
