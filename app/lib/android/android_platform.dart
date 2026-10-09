import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Whether this is the Android app.
bool get isAndroid =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

/// What Android currently allows Sotto to do in the background.
@immutable
class AndroidStatus {
  const AndroidStatus({
    this.batteryUnrestricted = true,
    this.notificationsAllowed = true,
    this.fullScreenAllowed = true,
  });

  /// Not "battery optimized": otherwise Android cuts the network while the
  /// phone sleeps, and calls stop ringing after a while.
  final bool batteryUnrestricted;

  /// Notifications may be shown (Android 13+ asks the user).
  final bool notificationsAllowed;

  /// Calls may ring full screen on a locked phone (Android 14+ setting).
  final bool fullScreenAllowed;

  /// Everything is in place for calls to ring while the app is closed.
  bool get ready => batteryUnrestricted && notificationsAllowed;
}

/// The `sotto/android` channel to the native side
/// (`android/app/src/main/kotlin/…/Bridge.kt`); faked in tests.
abstract interface class AndroidPlatform {
  /// Taps on the call notifications: "answer", "decline" or "hangUp".
  Stream<String> get actions;

  Future<void> setRingWhenClosed(bool on);
  Future<AndroidStatus> status();
  Future<void> requestNotifications();
  Future<void> requestBatteryExemption();
  Future<void> openFullScreenSettings();

  Future<void> showIncomingCall({
    required String title,
    required String body,
    required bool video,
  });
  Future<void> cancelIncomingCall();
  Future<void> showKnock({required String title, required String body});
  Future<void> cancelKnock();

  /// A message from a contact, while the app is in the background: only a
  /// title and a short line, never the text.
  Future<void> showMessage({required String title, required String body});
  Future<void> cancelMessage();

  /// The call ended: the app stops showing over the lock screen.
  Future<void> callFinished();

  /// During a call: keeps the microphone working outside the app, with an
  /// "Ongoing call" notification (timer from [since] once connected).
  Future<void> startCallService({
    required String title,
    required String name,
    DateTime? since,
    bool video = false,
  });
  Future<void> stopCallService();
}

class MethodChannelAndroid implements AndroidPlatform {
  MethodChannelAndroid() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'action' && call.arguments is String) {
        _actions.add(call.arguments as String);
      }
    });
  }

  static const _channel = MethodChannel('sotto/android');
  final _actions = StreamController<String>.broadcast();

  @override
  Stream<String> get actions => _actions.stream;

  Future<void> _call(String method, [Map<String, Object?>? args]) async {
    try {
      await _channel.invokeMethod<void>(method, args);
    } catch (e) {
      debugPrint('Android $method failed: $e');
    }
  }

  @override
  Future<void> setRingWhenClosed(bool on) =>
      _call('setRingWhenClosed', {'on': on});

  @override
  Future<AndroidStatus> status() async {
    try {
      final map = await _channel.invokeMapMethod<String, Object?>('status');
      return AndroidStatus(
        batteryUnrestricted: map?['batteryUnrestricted'] != false,
        notificationsAllowed: map?['notificationsAllowed'] != false,
        fullScreenAllowed: map?['fullScreenAllowed'] != false,
      );
    } catch (e) {
      debugPrint('Android status failed: $e');
      return const AndroidStatus();
    }
  }

  @override
  Future<void> requestNotifications() => _call('requestNotifications');

  @override
  Future<void> requestBatteryExemption() => _call('requestBatteryExemption');

  @override
  Future<void> openFullScreenSettings() => _call('openFullScreenSettings');

  @override
  Future<void> showIncomingCall({
    required String title,
    required String body,
    required bool video,
  }) =>
      _call('showIncomingCall', {'title': title, 'body': body, 'video': video});

  @override
  Future<void> cancelIncomingCall() => _call('cancelIncomingCall');

  @override
  Future<void> showKnock({required String title, required String body}) =>
      _call('showKnock', {'title': title, 'body': body});

  @override
  Future<void> cancelKnock() => _call('cancelKnock');

  @override
  Future<void> showMessage({required String title, required String body}) =>
      _call('showMessage', {'title': title, 'body': body});

  @override
  Future<void> cancelMessage() => _call('cancelMessage');

  @override
  Future<void> callFinished() => _call('callFinished');

  @override
  Future<void> startCallService({
    required String title,
    required String name,
    DateTime? since,
    bool video = false,
  }) => _call('startCallService', {
    'title': title,
    'name': name,
    'since': since?.millisecondsSinceEpoch,
    'video': video,
  });

  @override
  Future<void> stopCallService() => _call('stopCallService');
}
