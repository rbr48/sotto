import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// One Sotto per desktop session: a second start (e.g. from the menu while
/// Sotto, started at login, waits in the tray) shows the running window and
/// exits, so the same identity doesn't ring twice.
///
/// The first instance holds an exclusive lock on `instance.lock` in [dir];
/// a later one finds it locked, touches `instance.show`, which the first
/// one watches, and quits.
class SingleInstance {
  SingleInstance._(this._lock, this._watch);

  final RandomAccessFile _lock;
  final StreamSubscription<FileSystemEvent> _watch;

  /// Called in the first instance when another start asked to be shown.
  static void Function()? onActivate;

  /// Returns the claim if this is the first instance, or `null` after
  /// asking the running one to show itself.
  static Future<SingleInstance?> claim(Directory dir) async {
    await dir.create(recursive: true);
    final lockFile = await File('${dir.path}/instance.lock')
        .open(mode: FileMode.append);
    final show = File('${dir.path}/instance.show');
    try {
      await lockFile.lock(FileLock.exclusive);
    } on FileSystemException {
      await lockFile.close();
      await show.writeAsString('${DateTime.now().microsecondsSinceEpoch}');
      return null;
    }
    if (!await show.exists()) await show.writeAsString('');
    final watch = dir
        .watch(events: FileSystemEvent.modify | FileSystemEvent.create)
        .where((event) => event.path.endsWith('instance.show'))
        .listen((_) => onActivate?.call());
    return SingleInstance._(lockFile, watch);
  }

  @visibleForTesting
  Future<void> release() async {
    await _watch.cancel();
    await _lock.unlock();
    await _lock.close();
  }
}
