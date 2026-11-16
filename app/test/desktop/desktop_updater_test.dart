import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium.dart';
import 'package:sotto/core/update_check.dart';
import 'package:sotto/crypto/sotto_crypto.dart';
import 'package:sotto/desktop/desktop_updater.dart';
import 'package:sotto/desktop/update_verifier.dart';

const _installer = 'sotto-windows-x64-setup.exe';

void main() {
  late Sodium sodium;
  late KeyPair releaseKey;
  late HttpServer server;
  late Uri serverUrl;

  setUpAll(() async {
    sodium = await SottoCrypto.init();
    releaseKey = sodium.crypto.sign.keyPair();
  });

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    serverUrl = Uri.parse('http://${server.address.host}:${server.port}');
  });

  tearDown(() async {
    await server.close(force: true);
  });

  /// The checksum list a release publishes, for [payload].
  String sumsFor(List<int> payload, {String name = _installer}) {
    final digest = sha256Hex(payload);
    return '$digest  $name\n';
  }

  Uint8List sign(String text, {KeyPair? key}) => sodium.crypto.sign.detached(
    message: Uint8List.fromList(utf8.encode(text)),
    secretKey: (key ?? releaseKey).secretKey,
  );

  /// Serves a release: the installer, its checksums and their signature.
  void serveRelease({
    required List<int> payload,
    required String sums,
    required Uint8List signature,
  }) {
    server.listen((request) async {
      final path = request.uri.path;
      final body = switch (path) {
        '/$_installer' => payload,
        '/SHA256SUMS.txt' => utf8.encode(sums),
        '/SHA256SUMS.txt.sig' => signature,
        _ => null,
      };
      if (body == null) {
        request.response.statusCode = HttpStatus.notFound;
      } else {
        request.response.headers.contentType = ContentType.binary;
        request.response.contentLength = body.length;
        request.response.add(body);
      }
      await request.response.close();
    });
  }

  UpdateInfo updateFor({bool signed = true}) => UpdateInfo(
    version: '0.9.9',
    url: Uri.parse('https://example.com/release'),
    assetUrl: serverUrl.resolve('/$_installer'),
    assetName: _installer,
    sumsUrl: signed ? serverUrl.resolve('/SHA256SUMS.txt') : null,
    sumsSignatureUrl: signed ? serverUrl.resolve('/SHA256SUMS.txt.sig') : null,
  );

  DesktopUpdater updaterTrusting({KeyPair? key}) => DesktopUpdater(
    verifier: UpdateVerifier(sodium, (key ?? releaseKey).publicKey),
  );

  test('downloads a signed update and tracks progress', () async {
    final payload = List.generate(1024, (i) => i % 256);
    final sums = sumsFor(payload);
    serveRelease(payload: payload, sums: sums, signature: sign(sums));
    final progressValues = <double>[];

    final file = await updaterTrusting().download(
      updateFor(),
      onProgress: progressValues.add,
    );

    try {
      expect(await file.readAsBytes(), payload);
      expect(progressValues, isNotEmpty);
      expect(progressValues.last, 1.0);
    } finally {
      await file.parent.delete(recursive: true);
    }
  });

  test('refuses a release that is not signed', () async {
    await expectLater(
      updaterTrusting().download(updateFor(signed: false)),
      throwsA(isA<UpdateVerificationException>()),
    );
  });

  test('refuses checksums signed by another key', () async {
    final payload = [1, 2, 3];
    final sums = sumsFor(payload);
    final impostor = sodium.crypto.sign.keyPair();
    serveRelease(
      payload: payload,
      sums: sums,
      signature: sign(sums, key: impostor),
    );
    await expectLater(
      updaterTrusting().download(updateFor()),
      throwsA(
        isA<UpdateVerificationException>().having(
          (e) => e.message,
          'message',
          contains('not signed by the Sotto release key'),
        ),
      ),
    );
  });

  test(
    'refuses an installer that does not match the signed checksum',
    () async {
      final signedPayload = [1, 2, 3];
      final sums = sumsFor(signedPayload);
      // The file served is not the one the release signed.
      serveRelease(payload: [9, 9, 9], sums: sums, signature: sign(sums));
      await expectLater(
        updaterTrusting().download(updateFor()),
        throwsA(isA<UpdateVerificationException>()),
      );
    },
  );

  test('refuses an installer the signed list does not name', () async {
    final payload = [4, 5, 6];
    final sums = sumsFor(payload, name: 'some-other-file.exe');
    serveRelease(payload: payload, sums: sums, signature: sign(sums));
    await expectLater(
      updaterTrusting().download(updateFor()),
      throwsA(
        isA<UpdateVerificationException>().having(
          (e) => e.message,
          'message',
          contains(_installer),
        ),
      ),
    );
  });

  test('DesktopUpdater throws on HTTP error', () async {
    server.listen((request) async {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
    });

    final updater = updaterTrusting();
    final update = UpdateInfo(
      version: '0.9.9',
      url: Uri.parse('https://example.com/release'),
      assetUrl: serverUrl.resolve('/missing.exe'),
      sumsUrl: serverUrl.resolve('/SHA256SUMS.txt'),
      sumsSignatureUrl: serverUrl.resolve('/SHA256SUMS.txt.sig'),
    );

    expect(() => updater.download(update), throwsA(isA<HttpException>()));
  });

  test(
    'replacing the AppImage writes the new file in place, executable',
    () async {
      final dir = await Directory.systemTemp.createTemp('sotto_appimage_');
      try {
        final target = File('${dir.path}/Sotto.AppImage');
        await target.writeAsString('old');
        final newFile = File('${dir.path}/download.AppImage');
        await newFile.writeAsString('new');

        await DesktopUpdater.replaceAppImage(newFile, target.path);

        expect(await target.readAsString(), 'new');
        expect(await File('${target.path}.new').exists(), isFalse);
        if (!Platform.isWindows) {
          final mode = (await target.stat()).mode;
          expect(mode & 0x49, isNot(0), reason: 'an execute bit is set');
        }
      } finally {
        await dir.delete(recursive: true);
      }
    },
  );
}

String sha256Hex(List<int> bytes) => sha256.convert(bytes).toString();
