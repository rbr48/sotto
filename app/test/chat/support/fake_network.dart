import 'dart:async';
import 'dart:typed_data';

import 'package:sotto/chat/chat_manager.dart';
import 'package:sotto/chat/chat_rtc.dart';
import 'package:sotto/chat/chat_session.dart';

/// A connection that links to its peer when the answer is applied, the way
/// a real one connects once the SDP is exchanged.
class FakeRtc implements ChatRtc {
  FakeRtc(this.registry, {this.neverOpens = false});

  final Map<String, FakeRtc> registry;
  final bool neverOpens;
  bool relayOnly = false;
  bool closed = false;
  final addedCandidates = <Map<String, dynamic>>[];

  /// Every text frame this connection has sent, in order.
  final sentFrames = <String>[];

  /// Every binary frame (a file chunk) this connection has sent, in order.
  final sentBinary = <Uint8List>[];

  final _frames = StreamController<String>();
  final _binaryFrames = StreamController<Uint8List>();
  final _opened = Completer<void>();
  final _lost = Completer<void>();
  final _candidates = StreamController<Map<String, Object?>>.broadcast();
  FakeRtc? peer;
  bool _open = false;
  late final ChatTransport _transport = _FakeTransport(this);

  @override
  ChatTransport get transport => _transport;

  @override
  Future<void> get opened => _opened.future;

  @override
  Future<void> get lost => _lost.future;

  @override
  Stream<Map<String, Object?>> get localCandidates => _candidates.stream;

  @override
  Future<String> createOffer() async {
    final sdp = 'offer-${identityHashCode(this)}';
    registry[sdp] = this;
    scheduleMicrotask(
      () => _candidates.add({
        'candidate': 'candidate:$sdp',
        'sdpMid': '0',
        'sdpMLineIndex': 0,
      }),
    );
    return sdp;
  }

  @override
  Future<String> acceptOffer(String sdp) async {
    final offerer = registry[sdp];
    if (offerer == null) throw StateError('no such offer');
    if (!neverOpens) _link(offerer);
    return 'answer-$sdp';
  }

  @override
  Future<void> acceptAnswer(String sdp) async {
    if (peer == null && !neverOpens) throw StateError('no link yet');
  }

  @override
  Future<void> addCandidate(Map<String, dynamic> candidate) async {
    addedCandidates.add(candidate);
  }

  @override
  Future<void> close() async {
    closed = true;
    _markLost();
    // Not awaited: a controller nobody listens to never completes its close,
    // and that must not hang the caller (chat_rtc.dart does the same).
    if (!_frames.isClosed) unawaited(_frames.close());
    if (!_binaryFrames.isClosed) unawaited(_binaryFrames.close());
    if (!_candidates.isClosed) unawaited(_candidates.close());
  }

  void _link(FakeRtc other) {
    peer = other;
    other.peer = this;
    _markOpen();
    other._markOpen();
  }

  void _markOpen() {
    _open = true;
    if (!_opened.isCompleted) _opened.complete();
  }

  void _markLost() {
    if (!_lost.isCompleted) _lost.complete();
  }
}

class _FakeTransport implements ChatTransport {
  _FakeTransport(this.owner);

  final FakeRtc owner;

  @override
  bool send(String frame) {
    final peer = owner.peer;
    if (!owner._open || peer == null || owner.closed) return false;
    owner.sentFrames.add(frame);
    scheduleMicrotask(() {
      if (!peer.closed && !peer._frames.isClosed) peer._frames.add(frame);
    });
    return true;
  }

  @override
  bool sendBinary(Uint8List data) {
    final peer = owner.peer;
    if (!owner._open || peer == null || owner.closed) return false;
    owner.sentBinary.add(data);
    scheduleMicrotask(() {
      if (!peer.closed && !peer._binaryFrames.isClosed) {
        peer._binaryFrames.add(data);
      }
    });
    return true;
  }

  @override
  Stream<String> get frames => owner._frames.stream;

  @override
  Stream<Uint8List> get binaryFrames => owner._binaryFrames.stream;

  @override
  int get bufferedAmount => 0;

  @override
  Future<int> bufferedAmountNow() async => 0;

  @override
  Future<void> close() async {
    if (!owner._frames.isClosed) unawaited(owner._frames.close());
    if (!owner._binaryFrames.isClosed) unawaited(owner._binaryFrames.close());
  }
}

/// Delivers envelopes between devices, one microtask later, as a relay does.
class FakeNetwork {
  final managers = <String, List<ChatManager>>{};
  final registry = <String, FakeRtc>{};
  final rtcs = <String, List<FakeRtc>>{};
  final sent = <({String from, String to, String type})>[];

  /// The body of every envelope sent through the network, in order.
  final bodies = <Map<String, Object?>>[];

  /// Whether texts sent through the relay arrive. Tests of a failing direct
  /// chat turn this off, so the message really cannot get through.
  bool relayText = true;

  void deliver(
    String from,
    String to,
    String type,
    Map<String, Object?> body,
    String? callId,
  ) {
    sent.add((from: from, to: to, type: type));
    bodies.add(Map<String, Object?>.from(body));
    if (!relayText && type == ChatManager.relayText) return;
    for (final device in managers[to] ?? const <ChatManager>[]) {
      scheduleMicrotask(
        () => device.handle(
          from: from,
          type: type,
          body: Map<String, dynamic>.from(body),
          callId: callId,
        ),
      );
    }
  }
}
