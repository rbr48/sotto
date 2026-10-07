import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium.dart';
import 'package:sotto/crypto/encoding.dart';
import 'package:sotto/crypto/sotto_crypto.dart';
import 'package:sotto/relay/relay_client.dart';

/// Minimal relay speaking the same login protocol as server/src/relay.
class FakeRelay {
  FakeRelay(this.sodium);

  final Sodium sodium;
  late HttpServer _server;
  final sockets = <WebSocket>[];
  final received = <Map<String, dynamic>>[];
  final loggedIn = <String>[];

  Uri get url => Uri.parse('ws://127.0.0.1:${_server.port}/relay');

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((request) async {
      final host = request.headers.value('host')!;
      final socket = await WebSocketTransformer.upgrade(request);
      sockets.add(socket);
      final nonce = sodium.randombytes.buf(32);
      socket.add(jsonEncode({'type': 'challenge', 'nonce': b64Encode(nonce)}));
      socket.listen((raw) {
        final message = jsonDecode(raw as String) as Map<String, dynamic>;
        if (message['type'] != 'auth') {
          received.add(message);
          return;
        }
        final ok = sodium.crypto.sign.verifyDetached(
          message: Uint8List.fromList(RelayClient.authMessage(nonce, host)),
          signature: b64Decode(message['sig'] as String),
          publicKey: b64Decode(message['id'] as String),
        );
        if (!ok) {
          socket.add(jsonEncode({'type': 'error', 'code': 'auth-failed'}));
          socket.close(4001);
          return;
        }
        loggedIn.add(message['id'] as String);
        socket.add(jsonEncode({'type': 'ready', 'id': message['id']}));
      });
    });
  }

  void deliver(String from, String body) {
    for (final socket in sockets) {
      socket.add(jsonEncode({'type': 'message', 'from': from, 'body': body}));
    }
  }

  Future<void> dropConnections() async {
    for (final socket in sockets) {
      await socket.close();
    }
    sockets.clear();
  }

  Future<void> stop() => _server.close(force: true);
}

Future<void> eventually(bool Function() condition) async {
  for (var i = 0; i < 300; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('condition not met in time');
}

void main() {
  late Sodium sodium;
  late FakeRelay relay;
  late Identity identity;
  RelayClient? client;

  setUpAll(() async => sodium = await SottoCrypto.init());
  setUp(() async {
    relay = FakeRelay(sodium);
    await relay.start();
    identity = Identity.generate(sodium);
  });
  tearDown(() async {
    await client?.stop();
    client = null;
    await relay.stop();
  });

  RelayClient newClient({DateTime Function()? clock}) => client = RelayClient(
    url: relay.url,
    sodium: sodium,
    identity: identity,
    backoff: (_) => const Duration(milliseconds: 20),
    clock: clock,
  );

  test(
    'logs in with a signature bound to the host, then sends and receives',
    () async {
      final c = newClient();
      final messages = <RelayMessage>[];
      c.messages.listen(messages.add);
      c.start();
      await eventually(() => c.status == RelayStatus.online);
      expect(relay.loggedIn, [identity.id]);

      c.send('recipient-id', 'envelope-1');
      await eventually(() => relay.received.isNotEmpty);
      expect(relay.received.single, {
        'type': 'send',
        'to': 'recipient-id',
        'body': 'envelope-1',
      });

      relay.deliver('sender-id', 'envelope-2');
      await eventually(() => messages.isNotEmpty);
      expect(messages.single.from, 'sender-id');
      expect(messages.single.body, 'envelope-2');
    },
  );

  test('holds messages while offline and sends them after login', () async {
    final c = newClient();
    c.send('someone', 'early');
    c.start();
    await eventually(() => relay.received.isNotEmpty);
    expect(relay.received.single['body'], 'early');
  });

  test('drops held messages older than 60 s', () async {
    var now = DateTime(2026);
    final c = newClient(clock: () => now);
    c.send('someone', 'stale');
    now = now.add(const Duration(seconds: 61));
    c.send('someone', 'fresh');
    c.start();
    await eventually(() => relay.received.isNotEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(relay.received.map((m) => m['body']), ['fresh']);
  });

  test('reconnects and logs in again after the connection drops', () async {
    final c = newClient();
    final statuses = <RelayStatus>[];
    c.statusChanges.listen(statuses.add);
    c.start();
    await eventually(() => c.status == RelayStatus.online);
    await relay.dropConnections();
    await eventually(
      () => relay.loggedIn.length == 2 && c.status == RelayStatus.online,
    );
    expect(
      statuses,
      containsAllInOrder([
        RelayStatus.online,
        RelayStatus.offline,
        RelayStatus.online,
      ]),
    );
  });

  test('the signed host includes a non-default port only', () {
    expect(
      RelayClient.hostOf(Uri.parse('wss://sotto.example/relay')),
      'sotto.example',
    );
    expect(
      RelayClient.hostOf(Uri.parse('ws://localhost:8080/relay')),
      'localhost:8080',
    );
  });

  test('backoff grows to at most 30 s', () {
    for (var attempt = 0; attempt < 10; attempt++) {
      final delay = RelayClient.defaultBackoff(attempt);
      expect(delay, lessThanOrEqualTo(const Duration(seconds: 30)));
      expect(delay, greaterThanOrEqualTo(const Duration(milliseconds: 500)));
    }
    expect(
      RelayClient.defaultBackoff(9),
      greaterThanOrEqualTo(const Duration(seconds: 15)),
    );
  });
}
