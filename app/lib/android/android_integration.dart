import 'dart:async';

import 'package:flutter/widgets.dart';

import '../app/app_controller.dart';
import '../call/call_controller.dart';
import '../call/call_manager.dart';
import '../chat/chat_arrival.dart';
import '../core/l10n/language.dart';
import '../desktop/notices.dart';
import '../guest/guest_host.dart';
import 'android_platform.dart';

/// Android: "Ring even when Sotto is closed", and ringing through the
/// system while the app is in the background.
///
/// - The background service (`SottoService.kt`) keeps the app connected
///   after its window is closed; it follows [DesktopPrefs.ringWhenClosed].
/// - While the app isn't in front, an incoming call rings as a full-screen
///   call notification with Answer and Decline (the system plays the
///   ringtone, so silent mode and Do Not Disturb apply), and a knocking
///   guest shows a notification. Names only if the user chose so, never
///   while the app is locked.
/// - During a call, a microphone service (`CallService.kt`) with an
///   "Ongoing call" notification keeps the call going when the user leaves
///   the app (Android mutes the microphone of background apps otherwise).
class AndroidIntegration extends ChangeNotifier {
  AndroidIntegration(this.app, {AndroidPlatform? platform})
    : _platform = platform ?? MethodChannelAndroid();

  final AppController app;
  final AndroidPlatform _platform;

  AndroidStatus _status = const AndroidStatus();

  /// What Android currently allows (refreshed when the app comes to front).
  AndroidStatus get status => _status;

  bool _inFront = false;
  bool? _appliedRing;
  bool _askedForNotifications = false;
  CallController? _watched;
  bool _ringing = false;
  bool _wasActive = false;

  /// What the ongoing-call service last showed (to update it only on change).
  (String, String, DateTime?, bool)? _callService;
  StreamSubscription<String>? _actions;
  final _callSubscriptions = <StreamSubscription<Object?>>[];

  Future<void> start() async {
    _inFront =
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    _actions = _platform.actions.listen(_onAction);
    app.addListener(_onAppChanged);
    _onAppChanged();
    await refresh();
  }

  /// Whether the window is in front (set from the app lifecycle).
  bool get inFront => _inFront;
  set inFront(bool value) {
    if (value == _inFront) return;
    _inFront = value;
    _watched?.systemAlerts = !value;
    if (value) {
      // The app shows the call and the waiting guests itself now.
      _stopRinging();
      unawaited(_platform.cancelKnock());
      unawaited(_platform.cancelMessage());
      unawaited(refresh());
    }
  }

  Future<void> refresh() async {
    _status = await _platform.status();
    notifyListeners();
  }

  Future<void> requestNotifications() => _platform.requestNotifications();
  Future<void> requestBatteryExemption() => _platform.requestBatteryExemption();
  Future<void> openFullScreenSettings() => _platform.openFullScreenSettings();

  void _onAppChanged() {
    if (app.stage == AppStage.ready) {
      final ring = app.desktopPrefs.ringWhenClosed;
      if (ring != _appliedRing) {
        _appliedRing = ring;
        unawaited(_platform.setRingWhenClosed(ring));
        if (ring) unawaited(_askForNotifications());
      }
    }
    final calls = app.calls;
    if (calls == _watched) return;
    _watched?.removeListener(_onCallChanged);
    for (final subscription in _callSubscriptions) {
      unawaited(subscription.cancel());
    }
    _callSubscriptions.clear();
    _watched = calls;
    if (calls == null) return;
    calls
      ..systemAlerts = !_inFront
      ..addListener(_onCallChanged);
    _callSubscriptions
      ..add(calls.incomingCalls.listen((call) => _onIncoming(calls, call)))
      ..add(calls.newGuests.listen(_onKnock))
      ..add(calls.newChatMessages.listen(onChatMessage));
  }

  /// A message from a contact arrived. A notice shows while the app is in the
  /// background (see [NoticeRules.chatMessage]), in the app's language.
  void onChatMessage(ChatArrival arrival) {
    final notice = NoticeRules.chatWords(
      kind: NoticeRules.chatMessage(
        prefs: app.desktopPrefs,
        inFront: _inFront,
        viewing: arrival.viewing,
        locked: app.lock.locked,
      ),
      senderName: arrival.senderName,
      l10n: localizationsForNotices(),
    );
    if (notice == null) return;
    unawaited(_platform.showMessage(title: notice.title, body: notice.body));
  }

  /// Ringing needs notifications: ask once, while the user is looking.
  Future<void> _askForNotifications() async {
    if (_askedForNotifications || !_inFront) return;
    await refresh();
    if (_status.notificationsAllowed) return;
    _askedForNotifications = true;
    await _platform.requestNotifications();
  }

  void _onIncoming(CallController calls, CallState call) {
    if (_inFront) return;
    final notice = NoticeRules.androidCall(
      callerName: calls.peerName,
      video: call.video,
      prefs: app.desktopPrefs,
      locked: app.lock.locked,
    );
    _ringing = true;
    unawaited(
      _platform.showIncomingCall(
        title: notice.title,
        body: notice.body,
        video: call.video,
      ),
    );
  }

  void _onKnock(WaitingGuest guest) {
    final notice = NoticeRules.knock(
      guestName: guest.name,
      prefs: app.desktopPrefs,
      inFront: _inFront,
      locked: app.lock.locked,
    );
    if (notice == null) return;
    unawaited(_platform.showKnock(title: notice.title, body: notice.body));
  }

  void _onCallChanged() {
    final calls = _watched;
    final call = calls?.call ?? CallState.idle;
    if (_ringing && call.phase != CallPhase.incoming) _stopRinging();
    if (_wasActive && !call.active) unawaited(_platform.callFinished());
    _wasActive = call.active;
    _updateCallService(calls, call);
  }

  /// The microphone is in use from the start of an outgoing call, and from
  /// answering an incoming one, until the call ends.
  void _updateCallService(CallController? calls, CallState call) {
    final usesMicrophone = switch (call.phase) {
      CallPhase.calling || CallPhase.ringing => true,
      CallPhase.connecting || CallPhase.connected => true,
      _ => false,
    };
    if (calls == null || !usesMicrophone) {
      if (_callService != null) {
        _callService = null;
        unawaited(_platform.stopCallService());
      }
      return;
    }
    final shown = (
      call.video ? 'Video call' : 'Voice call',
      app.desktopPrefs.showNames && !app.lock.locked ? calls.peerName : 'Sotto',
      calls.connectedAt,
      // The camera too, while this device sends video.
      calls.sendingVideo,
    );
    if (shown == _callService) return;
    _callService = shown;
    unawaited(
      _platform.startCallService(
        title: shown.$1,
        name: shown.$2,
        since: shown.$3,
        video: shown.$4,
      ),
    );
  }

  void _stopRinging() {
    if (!_ringing) return;
    _ringing = false;
    unawaited(_platform.cancelIncomingCall());
  }

  void _onAction(String action) {
    final calls = _watched;
    if (calls == null) return;
    switch (action) {
      case 'answer':
        unawaited(calls.accept());
      case 'decline':
        _ringing = false;
        unawaited(calls.decline());
      case 'hangUp':
        unawaited(calls.hangUp());
    }
  }

  @override
  void dispose() {
    app.removeListener(_onAppChanged);
    _watched?.removeListener(_onCallChanged);
    for (final subscription in _callSubscriptions) {
      unawaited(subscription.cancel());
    }
    unawaited(_actions?.cancel());
    super.dispose();
  }
}
