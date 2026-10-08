import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'call_manager.dart';

/// Keeps the screen on (Android, desktop, and browsers with the Screen Wake
/// Lock API). Failures are ignored: a screen that dims is a nuisance, not a
/// broken call.
abstract interface class ScreenAwake {
  Future<void> keepOn(bool on);
}

class WakelockScreenAwake implements ScreenAwake {
  WakelockScreenAwake();

  /// While on: the system drops the lock when the app leaves the screen (a
  /// browser tab is hidden, an Android activity is recreated), so it is
  /// taken again each time the app comes back.
  AppLifecycleListener? _returns;

  @override
  Future<void> keepOn(bool on) async {
    _returns?.dispose();
    _returns = on ? AppLifecycleListener(onResume: () => _toggle(true)) : null;
    await _toggle(on);
  }

  static Future<void> _toggle(bool on) async {
    try {
      await WakelockPlus.toggle(enable: on);
    } catch (_) {}
  }
}

/// Video calls keep the screen on, from ringing to hanging up: nobody
/// touches the screen while watching, and it must not dim or lock. Voice
/// calls don't (the phone is at the ear).
class VideoCallScreen {
  VideoCallScreen(this._screen);

  final ScreenAwake _screen;
  bool _keptOn = false;

  bool get keptOn => _keptOn;

  void update(CallState call) => _set(call.active && call.video);

  void release() => _set(false);

  void _set(bool on) {
    if (on == _keptOn) return;
    _keptOn = on;
    unawaited(_screen.keepOn(on));
  }
}
