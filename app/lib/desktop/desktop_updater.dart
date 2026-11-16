import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../core/update_check.dart';
import '../core/version.dart';
import '../crypto/sotto_crypto.dart';
import 'update_verifier.dart';

/// Downloads desktop installer packages in the background and executes
/// silent self-updates without requiring external browser steps.
///
/// Nothing is run unless the release's checksums are signed by the release
/// key and the installer matches them (see [UpdateVerifier]).
class DesktopUpdater {
  DesktopUpdater({HttpClient Function()? createClient, this.verifier})
    : _createClient = createClient ?? _defaultClient;

  final HttpClient Function() _createClient;

  /// Checks the update's signature. Null: the key compiled into this build.
  final UpdateVerifier? verifier;
  HttpClient? _activeClient;
  bool _cancelled = false;

  static HttpClient _defaultClient() =>
      HttpClient()..connectionTimeout = const Duration(seconds: 15);

  /// Downloads the release asset into a temporary file, after checking that
  /// the release's checksums are signed by the release key. The file is
  /// checked against its checksum once it has arrived. [onProgress] receives
  /// a normalized value between `0.0` and `1.0`.
  ///
  /// Throws [UpdateVerificationException], and keeps no file, when the update
  /// can't be trusted.
  Future<File> download(
    UpdateInfo update, {
    void Function(double progress)? onProgress,
  }) async {
    final url = update.assetUrl;
    if (url == null) {
      throw StateError('No asset URL available for update ${update.version}');
    }
    final sumsUrl = update.sumsUrl;
    final signatureUrl = update.sumsSignatureUrl;
    if (sumsUrl == null || signatureUrl == null) {
      throw const UpdateVerificationException(
        'this release is not signed, so it cannot be installed in the app',
      );
    }
    final checker =
        verifier ?? UpdateVerifier.forThisBuild(await SottoCrypto.init());

    // The checksums are checked before the installer is downloaded.
    final sums = await _fetchSmall(sumsUrl);
    checker.checkSums(sums, await _fetchSmall(signatureUrl));
    final String sumsText;
    try {
      sumsText = utf8.decode(sums);
    } on FormatException {
      throw const UpdateVerificationException(
        'the release checksums are not readable',
      );
    }
    final filename = update.assetName ?? 'sotto-setup.exe';
    final expected = UpdateVerifier.digestOf(sumsText, filename);

    _cancelled = false;
    final client = _createClient();
    _activeClient = client;

    try {
      final request = await client.getUrl(url);
      request.headers
        ..set(HttpHeaders.userAgentHeader, 'Sotto/$sottoVersion')
        ..set(HttpHeaders.acceptHeader, 'application/octet-stream');

      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      if (response.statusCode != 200) {
        throw HttpException(
          'Download failed with HTTP ${response.statusCode}',
          uri: url,
        );
      }

      final totalBytes = response.contentLength > 0
          ? response.contentLength
          : (update.assetSize ?? 0);

      final tempDir = await Directory.systemTemp.createTemp('sotto_update_');
      final file = File('${tempDir.path}/$filename');
      final sink = file.openWrite();

      int received = 0;
      await for (final chunk in response) {
        if (_cancelled) {
          await sink.close();
          await file.delete().catchError((_) => file);
          throw const UpdateCancelledException('Download cancelled by user');
        }
        sink.add(chunk);
        received += chunk.length;
        if (totalBytes > 0 && onProgress != null) {
          onProgress((received / totalBytes).clamp(0.0, 1.0));
        }
      }
      await sink.flush();
      await sink.close();
      try {
        await UpdateVerifier.checkFile(file, expected);
      } catch (_) {
        await file.delete().catchError((_) => file);
        rethrow;
      }
      return file;
    } finally {
      _activeClient = null;
      client.close();
    }
  }

  /// A small file from the release (checksums, signature), read whole.
  Future<Uint8List> _fetchSmall(Uri url, {int maxBytes = 64 * 1024}) async {
    final client = _createClient();
    try {
      final request = await client.getUrl(url);
      request.headers.set(HttpHeaders.userAgentHeader, 'Sotto/$sottoVersion');
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      if (response.statusCode != 200) {
        throw HttpException(
          'Download failed with HTTP ${response.statusCode}',
          uri: url,
        );
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response) {
        bytes.add(chunk);
        if (bytes.length > maxBytes) {
          throw HttpException('the file is too large', uri: url);
        }
      }
      return bytes.takeBytes();
    } finally {
      client.close();
    }
  }

  /// Cancels any active download in progress.
  void cancel() {
    _cancelled = true;
    _activeClient?.close(force: true);
  }

  /// Silently runs the downloaded installer and relaunches the updated app.
  /// Only call this for a file that [download] returned.
  static Future<void> applyAndRestart(File installerFile) async {
    if (kIsWeb) return;

    if (defaultTargetPlatform == TargetPlatform.windows) {
      final exePath = Platform.resolvedExecutable;
      // Inno Setup /SILENT /CLOSEAPPLICATIONS silently updates the app.
      // Detached cmd process waits for the installer to finish, then
      // restarts Sotto before exiting.
      await Process.start('cmd.exe', [
        '/c',
        'start',
        '/wait',
        '',
        installerFile.path,
        '/SILENT',
        '/CLOSEAPPLICATIONS',
        '/SUPPRESSMSGBOXES',
        '&',
        'start',
        '',
        exePath,
      ], mode: ProcessStartMode.detached);
      exit(0);
    } else if (defaultTargetPlatform == TargetPlatform.linux) {
      if (installerFile.path.endsWith('.AppImage')) {
        final currentAppImage = Platform.environment['APPIMAGE'];
        if (currentAppImage != null) {
          await replaceAppImage(installerFile, currentAppImage);
          await Process.start(
            currentAppImage,
            [],
            mode: ProcessStartMode.detached,
          );
          exit(0);
        }
      }
    }
  }

  /// Puts [newFile] in place of [target], the AppImage that is running. Linux
  /// refuses to write to a file that is running ("text file busy"), but it
  /// lets the name be replaced: the new file is written beside the old one,
  /// then renamed over it. The running process keeps the old file.
  static Future<void> replaceAppImage(File newFile, String target) async {
    final staged = File('$target.new');
    await newFile.copy(staged.path);
    await Process.run('chmod', ['+x', staged.path]);
    await staged.rename(target);
  }
}

class UpdateCancelledException implements Exception {
  const UpdateCancelledException(this.message);
  final String message;
  @override
  String toString() => message;
}
