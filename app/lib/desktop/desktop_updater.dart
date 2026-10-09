import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/update_check.dart';
import '../core/version.dart';

/// Downloads desktop installer packages in the background and executes
/// silent self-updates without requiring external browser steps.
class DesktopUpdater {
  DesktopUpdater({HttpClient Function()? createClient})
    : _createClient = createClient ?? _defaultClient;

  final HttpClient Function() _createClient;
  HttpClient? _activeClient;
  bool _cancelled = false;

  static HttpClient _defaultClient() =>
      HttpClient()..connectionTimeout = const Duration(seconds: 15);

  /// Downloads the release asset into a temporary file.
  /// [onProgress] receives a normalized value between `0.0` and `1.0`.
  Future<File> download(
    UpdateInfo update, {
    void Function(double progress)? onProgress,
  }) async {
    final url = update.assetUrl;
    if (url == null) {
      throw StateError('No asset URL available for update ${update.version}');
    }
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
      final filename = update.assetName ?? 'sotto-setup.exe';
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
      return file;
    } finally {
      _activeClient = null;
      client.close();
    }
  }

  /// Cancels any active download in progress.
  void cancel() {
    _cancelled = true;
    _activeClient?.close(force: true);
  }

  /// Silently runs the downloaded installer and relaunches the updated app.
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
        await Process.run('chmod', ['+x', installerFile.path]);
        final currentAppImage = Platform.environment['APPIMAGE'];
        if (currentAppImage != null) {
          await installerFile.copy(currentAppImage);
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
}

class UpdateCancelledException implements Exception {
  const UpdateCancelledException(this.message);
  final String message;
  @override
  String toString() => message;
}
