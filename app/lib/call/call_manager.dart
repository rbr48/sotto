import 'dart:async';

import 'package:flutter/foundation.dart';

import '../crypto/envelope.dart';
import '../crypto/identity.dart';
import 'media_engine.dart';
import 'trusted_callers.dart';

enum CallPhase {
  /// No call.
  idle,

  /// Outgoing: invite sent, no reply yet (recipient may be offline).
  calling,

  /// Outgoing: the other device is ringing.
  ringing,

  /// Incoming: our device is ringing.
  incoming,

  /// Accepted; setting up the media connection.
  connecting,
  connected,

  /// Finished; see [CallState.endReason].
  ended,
}

enum CallEndReason {
  /// We hung up.
  hungUp,

  /// The other person hung up.
  remoteHungUp,

  /// We declined an incoming call.
  declined,

  /// The other person declined our call.
  remoteDeclined,

  /// The other person was already in a call.
  busy,

  /// Nobody answered in time.
  noAnswer,

  /// We cancelled our call before it was answered.
  cancelled,

  /// An incoming call stopped ringing before we answered.
  missed,

  /// Media connection could not be established or broke.
  failed,
}

@immutable
class CallState {
  const CallState({
    required this.phase,
    this.peer,
    this.callId,
    this.outgoing = false,
    this.video = true,
    this.endReason,
    this.error,
    this.autoAnswered = false,
  });

  static const idle = CallState(phase: CallPhase.idle);

  final CallPhase phase;
  final PublicIdentity? peer;
  final String? callId;
  final bool outgoing;
  final bool video;
  final CallEndReason? endReason;

  /// Technical detail when [endReason] is [CallEndReason.failed].
  final String? error;

  /// The call was answered automatically (by the callee's settings, or
  /// because a guest was admitted from the waiting room).
  final bool autoAnswered;

  bool get active => phase != CallPhase.idle && phase != CallPhase.ended;

  CallState copyWith({
    CallPhase? phase,
    CallEndReason? endReason,
    String? error,
    bool? autoAnswered,
  }) => CallState(
    phase: phase ?? this.phase,
    peer: peer,
    callId: callId,
    outgoing: outgoing,
    video: video,
    endReason: endReason ?? this.endReason,
    error: error ?? this.error,
    autoAnswered: autoAnswered ?? this.autoAnswered,
  );
}

/// Sends an end-to-end encrypted call message to [to].
typedef CallMessageSender = void Function(
  PublicIdentity to,
  String type,
  Map<String, Object?> body,
  String callId,
);

/// The 1:1 call flow. All decisions happen on the devices, because the relay
/// can't read the messages:
///
/// ```
/// caller                          callee
///   call.invite  ───────────────▶   (busy? → call.busy)
///                ◀───────────────   call.ringing
///   (no reply in 45 s → call.cancel, "no answer")
///                ◀───────────────   call.accept | call.reject
///   sdp.offer    ───────────────▶
///                ◀───────────────   sdp.answer
///   ice.candidate ◀─────────────▶   ice.candidate
///   call.end / call.cancel ◀────▶   call.end
/// ```
class CallManager extends ChangeNotifier {
  CallManager({
    required this.send,
    required this.createMedia,
    required this.newCallId,
    this.autoAnswer,
    this.ringTimeout = const Duration(seconds: 45),
    this.incomingTimeout = const Duration(seconds: 60),
    this.connectTimeout = const Duration(seconds: 30),
  });

  final CallMessageSender send;
  final MediaEngine Function() createMedia;
  final String Function() newCallId;

  /// Decides whether an incoming invite is answered automatically: `null`
  /// rings normally, otherwise the call is accepted after the returned delay
  /// (during which the user can still decline), with or without camera.
  final AutoAnswer? Function(OpenedMessage invite)? autoAnswer;

  /// How long an outgoing call rings before giving up.
  final Duration ringTimeout;

  /// How long an incoming call rings if the caller never cancels.
  final Duration incomingTimeout;

  /// How long media setup may take after the call is accepted.
  final Duration connectTimeout;

  CallState _state = CallState.idle;
  CallState get state => _state;

  MediaEngine? _media;
  MediaEngine? get media => _media;

  Timer? _timer;
  Timer? _autoAnswerTimer;
  final _subscriptions = <StreamSubscription<Object?>>[];
  Future<void> _queue = Future.value();

  /// Starts an outgoing call. [inviteExtras] are added to the invite body
  /// (e.g. the guest knock being admitted).
  Future<void> call(
    PublicIdentity peer, {
    bool video = true,
    Map<String, Object?> inviteExtras = const {},
  }) => _serial(() async {
    if (_state.active) throw StateError('already in a call');
    final callId = newCallId();
    _setState(
      CallState(
        phase: CallPhase.calling,
        peer: peer,
        callId: callId,
        outgoing: true,
        video: video,
      ),
    );
    final media = _startMedia();
    try {
      await media.prepare(video: video);
    } catch (e) {
      await _end(
        CallEndReason.failed,
        error: 'Camera or microphone unavailable: $e',
      );
      return;
    }
    if (!_isCurrent(callId)) return;
    send(peer, 'call.invite', {...inviteExtras, 'video': video}, callId);
    _startTimer(ringTimeout, callId, () async {
      send(peer, 'call.cancel', const {}, callId);
      await _end(CallEndReason.noAnswer);
    });
  });

  /// Answers the ringing incoming call.
  Future<void> accept() => _serial(() => _accept(auto: false));

  Future<void> _accept({
    required bool auto,
    String? onlyCallId,
    bool withVideo = true,
  }) async {
    if (_state.phase != CallPhase.incoming) return;
    if (onlyCallId != null && _state.callId != onlyCallId) return;
    _autoAnswerTimer?.cancel();
    final callId = _state.callId!;
    _setState(_state.copyWith(phase: CallPhase.connecting, autoAnswered: auto));
    final media = _startMedia();
    try {
      await media.prepare(video: _state.video && withVideo);
    } catch (e) {
      send(_state.peer!, 'call.reject', const {}, callId);
      await _end(
        CallEndReason.failed,
        error: 'Camera or microphone unavailable: $e',
      );
      return;
    }
    if (!_isCurrent(callId)) return;
    send(
      _state.peer!,
      'call.accept',
      auto ? const {'auto': true} : const {},
      callId,
    );
    _startTimer(connectTimeout, callId, () => _fail('Connection timed out'));
  }

  /// Declines the ringing incoming call.
  Future<void> decline() => _serial(() async {
    if (_state.phase != CallPhase.incoming) return;
    send(_state.peer!, 'call.reject', const {}, _state.callId!);
    await _end(CallEndReason.declined);
  });

  /// Hangs up, cancels an outgoing call, or declines an incoming one.
  Future<void> hangUp() => _serial(() async {
    final peer = _state.peer;
    final callId = _state.callId;
    if (peer == null || callId == null) return;
    switch (_state.phase) {
      case CallPhase.calling || CallPhase.ringing:
        send(peer, 'call.cancel', const {}, callId);
        await _end(CallEndReason.cancelled);
      case CallPhase.incoming:
        send(peer, 'call.reject', const {}, callId);
        await _end(CallEndReason.declined);
      case CallPhase.connecting || CallPhase.connected:
        send(peer, 'call.end', const {}, callId);
        await _end(CallEndReason.hungUp);
      case CallPhase.idle || CallPhase.ended:
        break;
    }
  });

  /// Clears an ended call so the screen returns to idle.
  void dismiss() {
    if (_state.phase == CallPhase.ended) _setState(CallState.idle);
  }

  /// Handles a verified call message from the relay.
  Future<void> handle(OpenedMessage message) => _serial(() => _handle(message));

  Future<void> _handle(OpenedMessage message) async {
    final callId = message.callId;
    if (callId == null) return;

    if (message.type == 'call.invite') {
      if (_state.active) {
        // Duplicate delivery of the invite we are already handling.
        if (_state.callId == callId && _state.peer == message.sender) return;
        send(message.sender, 'call.busy', const {}, callId);
        return;
      }
      _setState(
        CallState(
          phase: CallPhase.incoming,
          peer: message.sender,
          callId: callId,
          video: message.body['video'] != false,
        ),
      );
      send(message.sender, 'call.ringing', const {}, callId);
      _startTimer(incomingTimeout, callId, () => _end(CallEndReason.missed));
      final decision = autoAnswer?.call(message);
      if (decision != null) {
        _autoAnswerTimer = Timer(decision.delay, () {
          _serial(
            () => _accept(
              auto: true,
              onlyCallId: callId,
              withVideo: decision.video,
            ),
          );
        });
      }
      return;
    }

    // Everything else must belong to the current call and come from its peer.
    if (!_state.active ||
        _state.callId != callId ||
        _state.peer?.id != message.sender.id) {
      return;
    }
    final body = message.body;
    switch ((message.type, _state.phase)) {
      case ('call.ringing', CallPhase.calling):
        _setState(_state.copyWith(phase: CallPhase.ringing));
      case ('call.accept', CallPhase.calling || CallPhase.ringing):
        _setState(
          _state.copyWith(
            phase: CallPhase.connecting,
            autoAnswered: body['auto'] == true,
          ),
        );
        _startTimer(
          connectTimeout,
          callId,
          () => _fail('Connection timed out'),
        );
        final offer = await _media!.createOffer();
        if (_isCurrent(callId)) {
          send(_state.peer!, 'sdp.offer', {'sdp': offer}, callId);
        }
      case ('call.reject', CallPhase.calling || CallPhase.ringing):
        await _end(CallEndReason.remoteDeclined);
      case ('call.busy', CallPhase.calling || CallPhase.ringing):
        await _end(CallEndReason.busy);
      case ('call.cancel', CallPhase.incoming):
        await _end(CallEndReason.missed);
      case (
        'call.end' || 'call.cancel',
        CallPhase.connecting || CallPhase.connected,
      ):
        await _end(CallEndReason.remoteHungUp);
      case ('sdp.offer', CallPhase.connecting) when !_state.outgoing:
        final answer = await _media!.acceptOffer(body['sdp'] as String);
        if (_isCurrent(callId)) {
          send(_state.peer!, 'sdp.answer', {'sdp': answer}, callId);
        }
      case ('sdp.answer', CallPhase.connecting) when _state.outgoing:
        await _media!.acceptAnswer(body['sdp'] as String);
      case ('ice.candidate', CallPhase.connecting || CallPhase.connected):
        await _media!.addRemoteCandidate(body);
      default:
        break;
    }
  }

  MediaEngine _startMedia() {
    final media = createMedia();
    _media = media;
    final callId = _state.callId!;
    final peer = _state.peer!;
    _subscriptions.add(
      media.localCandidates.listen((candidate) {
        if (_isCurrent(callId)) send(peer, 'ice.candidate', candidate, callId);
      }),
    );
    _subscriptions.add(
      media.connectionStates.listen((state) {
        switch (state) {
          case MediaConnectionState.connected when _isCurrent(callId):
            _serial(() async {
              if (!_isCurrent(callId) || _state.phase != CallPhase.connecting) {
                return;
              }
              _timer?.cancel();
              _setState(_state.copyWith(phase: CallPhase.connected));
            });
          case MediaConnectionState.failed when _isCurrent(callId):
            _serial(() => _fail('Media connection failed'));
          default:
            break;
        }
      }),
    );
    notifyListeners();
    return media;
  }

  Future<void> _fail(String error) async {
    final peer = _state.peer;
    final callId = _state.callId;
    if (!_state.active || peer == null || callId == null) return;
    send(peer, 'call.end', const {}, callId);
    await _end(CallEndReason.failed, error: error);
  }

  Future<void> _end(CallEndReason reason, {String? error}) async {
    if (!_state.active) return;
    _timer?.cancel();
    _timer = null;
    _autoAnswerTimer?.cancel();
    _autoAnswerTimer = null;
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
    final media = _media;
    _media = null;
    _setState(
      _state.copyWith(phase: CallPhase.ended, endReason: reason, error: error),
    );
    await media?.close();
  }

  bool _isCurrent(String callId) => _state.active && _state.callId == callId;

  void _startTimer(
    Duration duration,
    String callId,
    Future<void> Function() onTimeout,
  ) {
    _timer?.cancel();
    _timer = Timer(duration, () {
      _serial(() async {
        if (_isCurrent(callId)) await onTimeout();
      });
    });
  }

  /// Runs actions one at a time, in order: several of them await WebRTC
  /// calls, and interleaving would reorder the negotiation.
  Future<void> _serial(Future<void> Function() action) {
    final result = _queue.then((_) => action());
    _queue = result.catchError((Object _) {});
    return result;
  }

  void _setState(CallState state) {
    _state = state;
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _autoAnswerTimer?.cancel();
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _media?.close();
    super.dispose();
  }
}
