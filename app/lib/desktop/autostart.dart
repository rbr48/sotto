import 'dart:io';

import 'package:flutter/foundation.dart';

/// "Start Sotto when I log in" (Windows and Linux): registers this
/// executable to start with `--hidden`, so Sotto opens in the tray.
///
/// - Linux: an XDG autostart entry, `~/.config/autostart/sotto.desktop`.
/// - Windows: the user's `Run` key in the registry (no admin rights).
///
/// The path is written again at every start while it is on, so a moved or
/// updated portable bundle keeps starting.
abstract final class Autostart {
  /// Passed when started at login: open in the tray, not as a window.
  static const hiddenFlag = '--hidden';

  static const _runKey = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';
  static const _valueName = 'Sotto';

  static bool get supported =>
      !kIsWeb && (Platform.isLinux || Platform.isWindows);

  /// Turns it on or off. Returns whether it worked.
  static Future<bool> set(bool on, {String? executable}) async {
    if (!supported) return false;
    final exe = executable ?? Platform.resolvedExecutable;
    try {
      if (Platform.isLinux) {
        final file = File(linuxEntryPath(Platform.environment));
        if (on) {
          await file.parent.create(recursive: true);
          await file.writeAsString(linuxEntry(exe));
        } else if (await file.exists()) {
          await file.delete();
        }
        return true;
      }
      final result = await Process.run(
        'reg',
        on
            ? [
                'add', _runKey, '/v', _valueName, '/t', 'REG_SZ', //
                '/d', windowsCommand(exe), '/f',
              ]
            : ['delete', _runKey, '/v', _valueName, '/f'],
      );
      // Deleting a value that isn't there fails, and is fine.
      return on ? result.exitCode == 0 : true;
    } catch (e) {
      debugPrint('Start at login not changed: $e');
      return false;
    }
  }

  @visibleForTesting
  static String linuxEntryPath(Map<String, String> environment) {
    final config = environment['XDG_CONFIG_HOME']?.isNotEmpty == true
        ? environment['XDG_CONFIG_HOME']!
        : '${environment['HOME']}/.config';
    return '$config/autostart/sotto.desktop';
  }

  /// A desktop entry; the path is quoted as the specification asks.
  @visibleForTesting
  static String linuxEntry(String executable) {
    final quoted = executable
        .replaceAll(r'\', r'\\')
        .replaceAll('"', r'\"')
        .replaceAll('`', r'\`')
        .replaceAll(r'$', r'\$');
    return '[Desktop Entry]\n'
        'Type=Application\n'
        'Name=Sotto\n'
        'Comment=Private calls: ring while Sotto waits in the tray\n'
        'Exec="$quoted" $hiddenFlag\n'
        'Terminal=false\n'
        'X-GNOME-Autostart-enabled=true\n';
  }

  @visibleForTesting
  static String windowsCommand(String executable) =>
      '"$executable" $hiddenFlag';
}
