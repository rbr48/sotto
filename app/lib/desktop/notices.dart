import 'dart:convert';

import 'package:flutter/foundation.dart';

/// A desktop notification.
@immutable
class Notice {
  const Notice(this.title, this.body);

  final String title;
  final String body;

  @override
  bool operator ==(Object other) =>
      other is Notice && other.title == title && other.body == body;

  @override
  int get hashCode => Object.hash(title, body);

  @override
  String toString() => 'Notice($title: $body)';
}

/// The user's desktop choices, kept in the vault.
@immutable
class DesktopPrefs {
  const DesktopPrefs({
    this.keepInTray = true,
    this.notifications = true,
    this.showNames = false,
  });

  /// Closing the window keeps Sotto running in the system tray, so calls
  /// and knocking guests still reach the user.
  final bool keepInTray;

  /// Notifications for knocking guests and incoming calls while Sotto is in
  /// the background.
  final bool notifications;

  /// Put names in notifications. Off by default: the operating system may
  /// keep notifications in its history, and others may see the screen.
  final bool showNames;

  DesktopPrefs copyWith({
    bool? keepInTray,
    bool? notifications,
    bool? showNames,
  }) => DesktopPrefs(
    keepInTray: keepInTray ?? this.keepInTray,
    notifications: notifications ?? this.notifications,
    showNames: showNames ?? this.showNames,
  );

  String encode() => jsonEncode({
    'tray': keepInTray,
    'notify': notifications,
    'names': showNames,
  });

  static DesktopPrefs decode(String? stored) {
    if (stored == null) return const DesktopPrefs();
    try {
      final json = jsonDecode(stored) as Map<String, dynamic>;
      return DesktopPrefs(
        keepInTray: json['tray'] as bool? ?? true,
        notifications: json['notify'] as bool? ?? true,
        showNames: json['names'] as bool? ?? false,
      );
    } catch (_) {
      return const DesktopPrefs();
    }
  }
}

/// What to show, if anything. Nothing while Sotto is in front (the app
/// shows it), and no names unless the user chose so, never while locked.
abstract final class NoticeRules {
  static Notice? knock({
    required String guestName,
    required DesktopPrefs prefs,
    required bool inFront,
    required bool locked,
  }) {
    if (!prefs.notifications || inFront) return null;
    return prefs.showNames && !locked
        ? Notice('$guestName is waiting', 'Open Sotto to admit them.')
        : const Notice(
            'A guest is waiting',
            'Someone knocked on your link. Open Sotto to admit them.',
          );
  }

  static Notice? incomingCall({
    required String callerName,
    required bool video,
    required DesktopPrefs prefs,
    required bool inFront,
    required bool locked,
  }) {
    if (!prefs.notifications || inFront) return null;
    final title = video ? 'Incoming video call' : 'Incoming voice call';
    return prefs.showNames && !locked
        ? Notice(title, callerName)
        : Notice(title, 'Open Sotto to answer.');
  }
}
