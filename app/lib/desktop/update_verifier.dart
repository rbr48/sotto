import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:sodium/sodium.dart';

import '../core/update_check.dart';
import '../crypto/encoding.dart';

/// An update that can't be trusted, so it is not installed.
class UpdateVerificationException implements Exception {
  const UpdateVerificationException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Checks a downloaded update before it runs.
///
/// A release publishes `SHA256SUMS.txt`, the digest of each file in it, and
/// `SHA256SUMS.txt.sig`, an Ed25519 signature of that list made with the
/// release key. The app holds the public half of that key. An installer runs
/// only when the list carries a valid signature and the installer's digest is
/// in it. Someone who can change the download can't change the installer
/// without also breaking the signature.
class UpdateVerifier {
  UpdateVerifier(this._sodium, this._publicKey) {
    if (_publicKey.length != 32) {
      throw const UpdateVerificationException(
        'the release key in this build is not a valid key',
      );
    }
  }

  /// The verifier for the key compiled into this build.
  factory UpdateVerifier.forThisBuild(Sodium sodium) {
    final key = UpdateChecker.updatePublicKey;
    if (key.isEmpty) {
      throw const UpdateVerificationException(
        'this build has no release key, so it cannot install updates',
      );
    }
    final Uint8List bytes;
    try {
      bytes = b64Decode(key);
    } on FormatException {
      throw const UpdateVerificationException(
        'the release key in this build is not a valid key',
      );
    }
    return UpdateVerifier(sodium, bytes);
  }

  final Sodium _sodium;
  final Uint8List _publicKey;

  /// Throws unless [signature] is the release key's signature of [sums].
  void checkSums(Uint8List sums, Uint8List signature) {
    final valid =
        signature.length == 64 &&
        _sodium.crypto.sign.verifyDetached(
          message: sums,
          signature: signature,
          publicKey: _publicKey,
        );
    if (!valid) {
      throw const UpdateVerificationException(
        'the release is not signed by the Sotto release key',
      );
    }
  }

  /// The SHA-256 (lowercase hex) that [sums] lists for [fileName], in the
  /// `sha256sum` format: `<digest>  <name>`.
  static String digestOf(String sums, String fileName) {
    final pattern = RegExp(r'^([0-9a-f]{64}) [ *](.+)$');
    for (final line in const LineSplitter().convert(sums)) {
      final match = pattern.firstMatch(line);
      if (match != null && match.group(2) == fileName) {
        return match.group(1)!;
      }
    }
    throw UpdateVerificationException(
      'the release lists no checksum for $fileName',
    );
  }

  /// Throws unless [file] has the SHA-256 digest [expected]. The file is read
  /// in pieces, so a large installer doesn't have to fit in memory.
  static Future<void> checkFile(File file, String expected) async {
    final digest = await sha256.bind(file.openRead()).first;
    if (digest.toString() != expected) {
      throw const UpdateVerificationException(
        'the downloaded update does not match the release checksum',
      );
    }
  }
}
