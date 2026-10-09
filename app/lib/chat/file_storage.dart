import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Manages local storage of received files from peer-to-peer transfers
/// in the app's private support directory (`docs/FILE_SHARING_PLAN.md`).
abstract final class ChatFileStorage {
  /// Saves received file bytes into a private sandboxed directory.
  /// Returns the absolute local file path.
  static Future<String> saveReceivedBlob({
    required String fileId,
    required String name,
    required Uint8List bytes,
  }) async {
    if (kIsWeb) {
      return 'web:$fileId';
    }
    final supportDir = await getApplicationSupportDirectory();
    final fileDir = Directory('${supportDir.path}/received_files/$fileId');
    if (!await fileDir.exists()) {
      await fileDir.create(recursive: true);
    }
    final file = File('${fileDir.path}/$name');
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  /// Deletes a previously saved file from local disk.
  static Future<void> deleteFile(String? path) async {
    if (path == null || kIsWeb || path.startsWith('web:')) return;
    try {
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
        final parent = file.parent;
        if (await parent.exists()) {
          await parent.delete(recursive: true);
        }
      }
    } catch (_) {}
  }
}
