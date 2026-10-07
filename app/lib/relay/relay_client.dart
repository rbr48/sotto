import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:sodium/sodium.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../crypto/encoding.dart';
import '../crypto/identity.dart';

enum RelayStatus { offline, connecting, online }

/// An envelope received from the relay. [from] is the sender's ID as
/// authenticated by the relay; the envelope itself is verified separately.
class RelayMessage {
  const RelayMessage({required this.from, required this.body});
  final String from;
  final String body;
}

/// What the call layer needs from a relay connection (faked in tests).
abstract interface class RelayConnection {
  RelayStatus get status;
  Stream<RelayStatus> get statusChanges;
  Stream<RelayMessage> get messages;

  /// Sends an envelope. While offline, it is held for up to
  /// [RelayClient.outgoingTtl] and sent after reconnecting.
  void send(String to, String body);
}

/// Connects to the Sotto relay (`server/src/relay/relay.ts`), logs in by
/// signing the relay's challenge with the identity key, and reconnects with
/// exponential backoff when the connection drops.
class RelayClient implements RelayConnection {
  RelayClient({
    required this.url,
    required this._sodium,
    required this._identity,
    WebSocketChannel Function(Uri url)? connect,
    Duration Function(int attempt)? backoff,
    DateTime Function()? clock,
  }) : _connect = connect ?? WebSocketChannel.connect,
       _backoff = backoff ?? defaultBackoff,
       _clock = clock ?? DateTime.now;

  static const Duration outgoingTtl = Duration(seconds: 60);
  static const int maxOutgoing = 200;
  static const Duration loginTimeout = Duration(seconds: 10);

  final Uri url;
  final Sodium _sodium;
  final Identity _identity;
  final WebSocketChannel Function(Uri) _connect;
  final Duration Function(int attempt) _backoff;
  final DateTime Function() _clock;

  final _messages = StreamController<RelayMessage>.broadcast();
  final _statusChanges = StreamController<RelayStatus>.broadcast();
  final _outgoing = <({DateTime at, String json})>[];

  RelayStatus _status = RelayStatus.offline;
  WebSocketChannel? _channel;
  bool _running = false;
  Completer<void>? _wake;

  /// Last error reported by the relay (for diagnostics), e.g. `auth-failed`.
  String? lastError;

  @override
  RelayStatus get status => _status;

  @override
  Stream<RelayStatus> get statusChanges => _statusChanges.stream;

  @override
  Stream<RelayMessage> get messages => _messages.stream;

  /// 1 s, 2 s, 4 s … capped at 30 s, with jitter so clients don't reconnect
  /// in lockstep after a server restart.
  static Duration defaultBackoff(int attempt) {
    final base = min(30000, 1000 * pow(2, min(attempt, 5)).toInt());
    return Duration(milliseconds: base ~/ 2 + Random().nextInt(base ~/ 2 + 1));
  }

  /// The string signed at login: the host the client connected to, exactly
  /// as it appears in the HTTP Host header.
  @visibleForTesting
  static String hostOf(Uri url) =>
      url.hasPort ? '${url.host}:${url.port}' : url.host;

  static List<int> authMessage(List<int> nonce, String host) => concatBytes([
    domainLabel('sotto-relay-auth-v1'),
    nonce,
    utf8.encode(host.toLowerCase()),
  ]);

  void start() {
    if (_running) return;
    _running = true;
    unawaited(_run());
  }

  Future<void> stop() async {
    _running = false;
    _wake?.complete();
    await _channel?.sink.close();
    _setStatus(RelayStatus.offline);
  }

  /// Skips the current backoff wait and reconnects now (e.g. network is back).
  void reconnectNow() {
    if (_wake case final wake? when !wake.isCompleted) wake.complete();
  }

  @override
  void send(String to, String body) {
    final json = jsonEncode({'type': 'send', 'to': to, 'body': body});
    if (_status == RelayStatus.online) {
      _channel?.sink.add(json);
      return;
    }
    _outgoing.add((at: _clock(), json: json));
    while (_outgoing.length > maxOutgoing) {
      _outgoing.removeAt(0);
    }
  }

  Future<void> _run() async {
    var attempt = 0;
    while (_running) {
      _setStatus(RelayStatus.connecting);
      var reachedOnline = false;
      try {
        final channel = _connect(url);
        _channel = channel;
        await channel.ready;
        reachedOnline = await _session(channel);
      } catch (_) {
        // Connection failed; retry below.
      }
      _channel = null;
      if (!_running) break;
      _setStatus(RelayStatus.offline);
      if (reachedOnline) attempt = 0;
      final wake = _wake = Completer<void>();
      await Future.any([
        Future<void>.delayed(_backoff(attempt++)),
        wake.future,
      ]);
    }
    _setStatus(RelayStatus.offline);
  }

  /// Runs one connection until it closes. Returns whether login succeeded.
  Future<bool> _session(WebSocketChannel channel) async {
    var loggedIn = false;
    final timeout = Timer(loginTimeout, () {
      if (!loggedIn) channel.sink.close();
    });
    try {
      await for (final raw in channel.stream) {
        if (raw is! String) continue;
        final Map<String, dynamic> message;
        try {
          message = jsonDecode(raw) as Map<String, dynamic>;
        } catch (_) {
          continue;
        }
        switch (message['type']) {
          case 'challenge':
            final nonce = b64Decode(message['nonce'] as String);
            final signature = _sodium.crypto.sign.detached(
              message: Uint8List.fromList(authMessage(nonce, hostOf(url))),
              secretKey: _identity.signSecretKey,
            );
            channel.sink.add(
              jsonEncode({
                'type': 'auth',
                'id': _identity.id,
                'sig': b64Encode(signature),
              }),
            );
          case 'ready':
            loggedIn = true;
            _setStatus(RelayStatus.online);
            _flushOutgoing(channel);
          case 'message':
            final from = message['from'];
            final body = message['body'];
            if (from is String && body is String) {
              _messages.add(RelayMessage(from: from, body: body));
            }
          case 'error':
            lastError = message['code'] as String?;
        }
      }
    } finally {
      timeout.cancel();
    }
    return loggedIn;
  }

  void _flushOutgoing(WebSocketChannel channel) {
    final cutoff = _clock().subtract(outgoingTtl);
    for (final item in _outgoing) {
      if (item.at.isAfter(cutoff)) channel.sink.add(item.json);
    }
    _outgoing.clear();
  }

  void _setStatus(RelayStatus status) {
    if (_status == status) return;
    _status = status;
    _statusChanges.add(status);
  }
}
