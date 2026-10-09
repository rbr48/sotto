import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sotto/core/update_check.dart';
import 'package:sotto/desktop/desktop_updater.dart';

void main() {
  late HttpServer server;
  late Uri serverUrl;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    serverUrl = Uri.parse('http://${server.address.host}:${server.port}');
  });

  tearDown(() async {
    await server.close(force: true);
  });

  test('DesktopUpdater downloads asset and tracks progress', () async {
    final payload = List.generate(1024, (i) => i % 256);
    server.listen((request) async {
      request.response.headers.contentType = ContentType.binary;
      request.response.contentLength = payload.length;
      request.response.add(payload);
      await request.response.close();
    });

    final updater = DesktopUpdater();
    final progressValues = <double>[];

    final update = UpdateInfo(
      version: '0.9.9',
      url: Uri.parse('https://example.com/release'),
      assetUrl: serverUrl.resolve('/sotto-windows-x64-setup.exe'),
      assetName: 'sotto-windows-x64-setup.exe',
      assetSize: payload.length,
    );

    final downloadedFile = await updater.download(
      update,
      onProgress: (p) => progressValues.add(p),
    );

    try {
      expect(await downloadedFile.exists(), isTrue);
      expect(await downloadedFile.readAsBytes(), payload);
      expect(progressValues.isNotEmpty, isTrue);
      expect(progressValues.last, 1.0);
    } finally {
      await downloadedFile.delete().catchError((_) => downloadedFile);
      await downloadedFile.parent.delete().catchError(
        (_) => downloadedFile.parent,
      );
    }
  });

  test('DesktopUpdater throws on HTTP error', () async {
    server.listen((request) async {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
    });

    final updater = DesktopUpdater();
    final update = UpdateInfo(
      version: '0.9.9',
      url: Uri.parse('https://example.com/release'),
      assetUrl: serverUrl.resolve('/missing.exe'),
    );

    expect(() => updater.download(update), throwsA(isA<HttpException>()));
  });
}
