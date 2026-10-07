import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sotto/core/server_address.dart';

void main() {
  group('parse', () {
    test('a host name becomes https + wss on the same host', () {
      final server = ServerAddress.parse('  sotto.example.com ');
      expect(server.web.toString(), 'https://sotto.example.com/');
      expect(server.relay.toString(), 'wss://sotto.example.com/relay');
      expect(server.label, 'sotto.example.com');
      expect(ServerAddress.parse('https://sotto.example.com/'), server);
    });

    test('ports are kept; plain http only for this computer', () {
      final local = ServerAddress.parse('http://localhost:8080');
      expect(local.web.toString(), 'http://localhost:8080/');
      expect(local.relay.toString(), 'ws://localhost:8080/relay');
      expect(local.label, 'localhost:8080');
      expect(
        ServerAddress.parse('https://calls.clinic.org:8443').relay.toString(),
        'wss://calls.clinic.org:8443/relay',
      );
      expect(
        () => ServerAddress.parse('http://sotto.example.com'),
        throwsFormatException,
      );
    });

    test('rejects things that are not a plain server address', () {
      for (final bad in [
        '',
        'ftp://sotto.example.com',
        'https://user:pw@sotto.example.com',
        'https://sotto.example.com/relay',
        'https://sotto.example.com/?x=1',
        'https://sotto.example.com/#c=abc',
        'https://',
      ]) {
        expect(
          () => ServerAddress.parse(bad),
          throwsFormatException,
          reason: bad,
        );
      }
    });

    test('stored form round-trips', () {
      final server = ServerAddress.parse('sotto.example.com');
      expect(ServerAddress.decode(server.encode()), server);
      expect(ServerAddress.decode('{broken'), isNull);
      expect(ServerAddress.decode(null), isNull);
    });
  });

  group('checkServer', () {
    Future<(HttpServer, ServerAddress)> serve(
      void Function(WebSocket socket) onSocket,
    ) async {
      final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      http.listen((request) async {
        if (request.uri.path != '/relay') {
          request.response.statusCode = 404;
          await request.response.close();
          return;
        }
        onSocket(await WebSocketTransformer.upgrade(request));
      });
      return (http, ServerAddress.parse('http://localhost:${http.port}'));
    }

    test('a relay that sends its login challenge is accepted', () async {
      final (http, server) = await serve(
        (socket) => socket.add(jsonEncode({'type': 'challenge', 'nonce': 'x'})),
      );
      addTearDown(() => http.close(force: true));
      expect(await checkServer(server), isNull);
    });

    test('other servers and silence are reported', () async {
      final (http, server) = await serve((socket) => socket.add('hello'));
      addTearDown(() => http.close(force: true));
      expect(await checkServer(server), contains('not a Sotto relay'));

      final (quiet, quietServer) = await serve((_) {});
      addTearDown(() => quiet.close(force: true));
      expect(
        await checkServer(
          quietServer,
          timeout: const Duration(milliseconds: 300),
        ),
        contains('did not answer'),
      );

      expect(
        await checkServer(ServerAddress.parse('http://localhost:1')),
        contains('Could not reach'),
      );
    });
  });
}
