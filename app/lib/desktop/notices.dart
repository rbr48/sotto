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

/// The user's choices for running in the background (desktop and
/// Android), kept in the vault.
@immutable
class DesktopPrefs {
  const DesktopPrefs({
    this.keepInTray = true,
    this.notifications = true,
    this.showNames = false,
    this.startAtLogin = false,
    this.ringWhenClosed = true,
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

  /// Desktop: start Sotto (in the tray) when the user logs in.
  final bool startAtLogin;

  /// Android: keep running after the app is closed, so calls and knocking
  /// guests still ring.
  final bool ringWhenClosed;

  DesktopPrefs copyWith({
    bool? keepInTray,
    bool? notifications,
    bool? showNames,
    bool? startAtLogin,
    bool? ringWhenClosed,
  }) => DesktopPrefs(
    keepInTray: keepInTray ?? this.keepInTray,
    notifications: notifications ?? this.notifications,
    showNames: showNames ?? this.showNames,
    startAtLogin: startAtLogin ?? this.startAtLogin,
    ringWhenClosed: ringWhenClosed ?? this.ringWhenClosed,
  );

  String encode() => jsonEncode({
    'tray': keepInTray,
    'notify': notifications,
    'names': showNames,
    'login': startAtLogin,
    'ring': ringWhenClosed,
  });

  static DesktopPrefs decode(String? stored) {
    if (stored == null) return const DesktopPrefs();
    try {
      final json = jsonDecode(stored) as Map<String, dynamic>;
      return DesktopPrefs(
        keepInTray: json['tray'] as bool? ?? true,
        notifications: json['notify'] as bool? ?? true,
        showNames: json['names'] as bool? ?? false,
        startAtLogin: json['login'] as bool? ?? false,
        ringWhenClosed: json['ring'] as bool? ?? true,
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

  /// Android's ringing notification while the app is in the background.
  /// A call always rings (the notifications setting covers the other
  /// notices); the caller's name only if the user chose so, never while
  /// locked.
  static Notice androidCall({
    required String callerName,
    required bool video,
    required DesktopPrefs prefs,
    required bool locked,
  }) => Notice(
    video ? 'Incoming video call' : 'Incoming voice call',
    prefs.showNames && !locked ? callerName : 'Sotto',
  );

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
