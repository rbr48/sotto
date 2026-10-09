import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:local_notifier/local_notifier.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../app/app_controller.dart';
import '../call/call_controller.dart';
import '../chat/chat_arrival.dart';
import '../core/l10n/language.dart';
import 'autostart.dart';
import 'notices.dart';
import 'single_instance.dart';

/// Whether this is the Windows, Linux or macOS app.
bool get isDesktop =>
    !kIsWeb &&
    switch (defaultTargetPlatform) {
      TargetPlatform.linux ||
      TargetPlatform.windows ||
      TargetPlatform.macOS => true,
      _ => false,
    };

/// Desktop integration: a tray icon, closing the window to the tray (so
/// calls and knocking guests still arrive), and system notifications while
/// Sotto is in the background.
///
/// Everything here is optional: without a tray host (some Linux desktops)
/// or a notification service, Sotto works as a normal window.
class DesktopIntegration with TrayListener, WindowListener {
  DesktopIntegration(this.app, {this.startHidden = false});

  final AppController app;

  /// Started at login (`--hidden`): go straight to the tray.
  final bool startHidden;
  bool? _appliedLogin;

  bool _trayReady = false;
  bool _notifierReady = false;
  bool _toldAboutTray = false;
  CallController? _watched;
  final _subscriptions = <StreamSubscription<Object?>>[];

  /// Whether the window is in front (set from the app lifecycle).
  bool inFront = true;

  /// Default companion window dimensions (portrait mobile/dialer layout).
  static const defaultWindowSize = Size(420, 680);

  /// Minimum usable dimensions before content gets uncomfortably cramped.
  static const minWindowSize = Size(360, 520);

  Future<void> start() async {
    SingleInstance.onActivate = () => unawaited(_showWindow());
    try {
      await windowManager.ensureInitialized();
      windowManager.addListener(this);
      await windowManager.setMinimumSize(minWindowSize);
      final isMax = await windowManager.isMaximized();
      if (!isMax) {
        final size = await windowManager.getSize();
        if (size.width >= 1000) {
          await windowManager.setSize(defaultWindowSize);
        }
      }
    } catch (e) {
      debugPrint('Window manager unavailable: $e');
    }
    try {
      if (!await _hasTrayHost()) {
        throw StateError('no tray host on this desktop');
      }
      await trayManager.setIcon(
        defaultTargetPlatform == TargetPlatform.windows
            ? 'assets/tray/sotto.ico'
            : 'assets/tray/sotto.png',
      );
      if (defaultTargetPlatform != TargetPlatform.linux) {
        // Linux tray icons (AppIndicator) have no tooltip.
        await trayManager.setToolTip('Sotto');
      }
      await trayManager.setContextMenu(
        Menu(
          items: [
            MenuItem(key: 'show', label: 'Open Sotto'),
            MenuItem.separator(),
            MenuItem(key: 'quit', label: 'Quit Sotto'),
          ],
        ),
      );
      trayManager.addListener(this);
      _trayReady = true;
      app.trayAvailable = true;
    } catch (e) {
      debugPrint('No system tray: $e');
    }
    try {
      await localNotifier.setup(appName: 'Sotto');
      _notifierReady = true;
    } catch (e) {
      debugPrint('No notifications: $e');
    }
    app.addListener(_onAppChanged);
    _onAppChanged();
    if (startHidden && _trayReady) {
      try {
        await windowManager.hide();
      } catch (_) {
        // The window stays open.
      }
    }
  }

  /// Applies the tray choice and follows the current call controller.
  void _onAppChanged() {
    unawaited(_applyPreventClose());
    if (app.stage == AppStage.ready &&
        app.desktopPrefs.startAtLogin != _appliedLogin) {
      // Written again at every start, in case the app was moved.
      _appliedLogin = app.desktopPrefs.startAtLogin;
      unawaited(Autostart.set(_appliedLogin!));
    }
    final calls = app.calls;
    if (calls == _watched) return;
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
    _watched = calls;
    if (calls == null) return;
    _subscriptions
      ..add(
        calls.newGuests.listen(
          (guest) => _notify(
            NoticeRules.knock(
              guestName: guest.name,
              prefs: app.desktopPrefs,
              inFront: inFront,
              locked: app.lock.locked,
            ),
          ),
        ),
      )
      ..add(
        calls.incomingCalls.listen(
          (call) => _notify(
            NoticeRules.incomingCall(
              callerName: calls.peerName,
              video: call.video,
              prefs: app.desktopPrefs,
              inFront: inFront,
              locked: app.lock.locked,
            ),
          ),
        ),
      )
      ..add(
        calls.newChatMessages.listen(
          (arrival) => _notify(_chatNotice(arrival)),
        ),
      );
  }

  /// A message from a contact arrived: a notice unless the chat is open in
  /// front of the person (see [NoticeRules.chatMessage]).
  Notice? _chatNotice(ChatArrival arrival) => NoticeRules.chatWords(
    kind: NoticeRules.chatMessage(
      prefs: app.desktopPrefs,
      inFront: inFront,
      viewing: arrival.viewing,
      locked: app.lock.locked,
    ),
    senderName: arrival.senderName,
    l10n: localizationsForNotices(),
  );

  Future<void> _applyPreventClose() async {
    try {
      await windowManager.setPreventClose(
        app.desktopPrefs.keepInTray && _trayReady,
      );
    } catch (_) {
      // No window manager: the window closes normally.
    }
  }

  void _notify(Notice? notice) {
    if (notice == null || !_notifierReady) return;
    final notification = LocalNotification(
      title: notice.title,
      body: notice.body,
    )..onClick = _showWindow;
    unawaited(
      notification.show().catchError((Object e) {
        debugPrint('Notification not shown: $e');
      }),
    );
  }

  Future<void> _showWindow() async {
    // Shown again: the person can see the app, whatever the lifecycle says.
    inFront = true;
    try {
      await windowManager.show();
      await windowManager.focus();
    } catch (_) {
      // Ignore: the window may already be visible.
    }
  }

  @override
  void onWindowClose() {
    if (!app.desktopPrefs.keepInTray || !_trayReady) {
      unawaited(windowManager.destroy());
      return;
    }
    // A window hidden in the tray is not in front, whatever the lifecycle
    // still reports: calls, messages and knocks must notify.
    inFront = false;
    unawaited(windowManager.hide());
    if (!_toldAboutTray) {
      _toldAboutTray = true;
      _notify(
        const Notice(
          'Sotto is still running',
          'Calls, messages and waiting guests still reach you. Quit from the '
              'tray icon.',
        ),
      );
    }
  }

  @override
  void onTrayIconMouseDown() => unawaited(_showWindow());

  @override
  void onTrayIconRightMouseDown() =>
      unawaited(trayManager.popUpContextMenu().catchError((Object _) {}));

  /// Linux desktops show tray icons only if a StatusNotifier host runs (KDE,
  /// Ubuntu's GNOME, XFCE…; plain GNOME has none). Without one, a window
  /// closed to the tray could not be brought back, so it closes normally.
  static Future<bool> _hasTrayHost() async {
    if (defaultTargetPlatform != TargetPlatform.linux) return true;
    try {
      final result = await Process.run('dbus-send', [
        '--session',
        '--print-reply',
        '--dest=org.freedesktop.DBus',
        '/org/freedesktop/DBus',
        'org.freedesktop.DBus.NameHasOwner',
        'string:org.kde.StatusNotifierWatcher',
      ]);
      return '${result.stdout}'.contains('boolean true');
    } catch (_) {
      return false;
    }
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show':
        unawaited(_showWindow());
      case 'quit':
        unawaited(_quit());
    }
  }

  Future<void> _quit() async {
    try {
      await windowManager.setPreventClose(false);
      await trayManager.destroy();
    } finally {
      await windowManager.destroy();
    }
  }

  void dispose() {
    app.removeListener(_onAppChanged);
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    if (_trayReady) trayManager.removeListener(this);
    windowManager.removeListener(this);
  }
}
