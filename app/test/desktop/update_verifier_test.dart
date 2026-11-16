import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sotto/core/update_check.dart';
import 'package:sotto/crypto/sotto_crypto.dart';
import 'package:sotto/desktop/update_verifier.dart';

void main() {
  test('digestOf finds a file in a sha256sum list, in either mode', () {
    final first = 'a' * 64;
    final second = 'b' * 64;
    final sums =
        '$first  sotto-windows-x64-setup.exe\n'
        '$second *sotto-linux-x86_64.AppImage\n';
    expect(UpdateVerifier.digestOf(sums, 'sotto-windows-x64-setup.exe'), first);
    expect(
      UpdateVerifier.digestOf(sums, 'sotto-linux-x86_64.AppImage'),
      second,
    );
    expect(
      () => UpdateVerifier.digestOf(sums, 'missing.exe'),
      throwsA(isA<UpdateVerificationException>()),
    );
  });

  test('a file is accepted only with its own digest', () async {
    final dir = await Directory.systemTemp.createTemp('sotto_verify_');
    try {
      final file = File('${dir.path}/installer.bin')
        ..writeAsBytesSync([1, 2, 3]);
      await expectLater(
        UpdateVerifier.checkFile(file, 'f' * 64),
        throwsA(isA<UpdateVerificationException>()),
      );
      await UpdateVerifier.checkFile(
        file,
        sha256.convert([1, 2, 3]).toString(),
      );
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test(
    'a release key must be 32 bytes, and a build without one installs nothing',
    () async {
      final sodium = await SottoCrypto.init();
      expect(
        () => UpdateVerifier(sodium, Uint8List(31)),
        throwsA(isA<UpdateVerificationException>()),
      );
      // The tests run without --dart-define, so this build has no release key.
      expect(
        () => UpdateVerifier.forThisBuild(sodium),
        throwsA(isA<UpdateVerificationException>()),
      );
      final update = UpdateInfo(
        version: '1.0.0',
        url: Uri.parse('https://github.com/x/releases/tag/v1.0.0'),
        assetUrl: Uri.parse('https://github.com/x/setup.exe'),
        sumsUrl: Uri.parse('https://github.com/x/SHA256SUMS.txt'),
        sumsSignatureUrl: Uri.parse('https://github.com/x/SHA256SUMS.txt.sig'),
      );
      expect(update.canInstallInApp, isFalse);
    },
  );

  test('checks the signature the release tool makes (RFC 8032 test 1)', () async {
    // The same key, message and signature as tools/release/sign-sums.test.mjs.
    Uint8List hex(String text) => Uint8List.fromList([
      for (var i = 0; i < text.length; i += 2)
        int.parse(text.substring(i, i + 2), radix: 16),
    ]);
    final sodium = await SottoCrypto.init();
    final verifier = UpdateVerifier(
      sodium,
      hex('d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a'),
    );
    final signature = hex(
      'e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b',
    );
    verifier.checkSums(Uint8List(0), signature);
    expect(
      () => verifier.checkSums(Uint8List.fromList([0]), signature),
      throwsA(isA<UpdateVerificationException>()),
    );
  });

  test('only GitHub over HTTPS is an update source', () {
    expect(isTrustedUpdateUrl(Uri.parse('https://github.com/x/y')), isTrue);
    expect(
      isTrustedUpdateUrl(Uri.parse('https://objects.githubusercontent.com/z')),
      isTrue,
    );
    expect(isTrustedUpdateUrl(Uri.parse('http://github.com/x')), isFalse);
    expect(
      isTrustedUpdateUrl(Uri.parse('https://github.com.example.org/x')),
      isFalse,
    );
    expect(isTrustedUpdateUrl(Uri.parse('https://example.com/x')), isFalse);
  });
}
