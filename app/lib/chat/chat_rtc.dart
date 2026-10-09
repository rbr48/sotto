import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'chat_session.dart';

/// The label of a chat's data channel. Both sides use it; nothing else is
/// negotiated.
const chatChannelLabel = 'sotto-chat';

/// The connection of one chat session: a WebRTC peer connection with one data
/// channel and no media. [ChatManager] drives it; tests use a fake.
///
/// Nothing here logs candidates or descriptions: they carry IP addresses.
abstract interface class ChatRtc {
  /// The data channel, as the session's transport. Sends fail until it opens.
  ChatTransport get transport;

  /// Completes when the data channel opens.
  Future<void> get opened;

  /// Completes when the channel or the connection is lost, or is closed here.
  Future<void> get lost;

  /// Local candidates, as the `chat.ice` body fields.
  Stream<Map<String, Object?>> get localCandidates;

  /// The offering side: creates the data channel and returns the offer.
  Future<String> createOffer();

  /// The answering side: applies the offer and returns the answer.
  Future<String> acceptOffer(String sdp);

  /// The offering side: applies the answer.
  Future<void> acceptAnswer(String sdp);

  /// Applies a remote candidate. Candidates that arrive before the remote
  /// description are held until it is set.
  Future<void> addCandidate(Map<String, dynamic> candidate);

  Future<void> close();
}

/// Makes a connection with the given ICE servers. [relayOnly] is "Hide my IP
/// address": only relayed candidates are used.
typedef ChatRtcFactory = Future<ChatRtc> Function({
  required List<Map<String, dynamic>> iceServers,
  required bool relayOnly,
});

/// A [ChatRtc] over flutter_webrtc.
class WebRtcChatRtc implements ChatRtc {
  WebRtcChatRtc._(this._pc) {
    _pc.onDataChannel = _attach;
    _pc.onIceCandidate = (candidate) {
      if (candidate.candidate == null || _closed) return;
      _candidates.add({
        'candidate': candidate.candidate,
        'sdpMid': candidate.sdpMid,
        'sdpMLineIndex': candidate.sdpMLineIndex,
      });
    };
    _pc.onConnectionState = (state) {
      switch (state) {
        case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
        case RTCPeerConnectionState.RTCPeerConnectionStateClosed:
          _fail();
        default:
          break;
      }
    };
  }

  /// Creates the connection. Only the ICE settings reach the browser or the
  /// native library; nothing about the chat is sent to the peer yet.
  static Future<WebRtcChatRtc> create({
    required List<Map<String, dynamic>> iceServers,
    required bool relayOnly,
  }) async {
    final pc = await createPeerConnection({
      'iceServers': iceServers,
      'iceTransportPolicy': relayOnly ? 'relay' : 'all',
      'sdpSemantics': 'unified-plan',
    });
    return WebRtcChatRtc._(pc);
  }

  final RTCPeerConnection _pc;
  final _DataChannelTransport _transport = _DataChannelTransport();
  final _candidates = StreamController<Map<String, Object?>>.broadcast();
  final _opened = Completer<void>();
  final _lost = Completer<void>();
  final _heldCandidates = <Map<String, dynamic>>[];
  bool _remoteSet = false;
  bool _closed = false;

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
    final channel = await _pc.createDataChannel(
      chatChannelLabel,
      RTCDataChannelInit(),
    );
    _attach(channel);
    final offer = await _pc.createOffer();
    await _pc.setLocalDescription(offer);
    return offer.sdp!;
  }

  @override
  Future<String> acceptOffer(String sdp) async {
    await _pc.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));
    await _remoteWasSet();
    final answer = await _pc.createAnswer();
    await _pc.setLocalDescription(answer);
    return answer.sdp!;
  }

  @override
  Future<void> acceptAnswer(String sdp) async {
    await _pc.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
    await _remoteWasSet();
  }

  @override
  Future<void> addCandidate(Map<String, dynamic> candidate) async {
    if (!_remoteSet) {
      _heldCandidates.add(candidate);
      return;
    }
    await _pc.addCandidate(
      RTCIceCandidate(
        candidate['candidate'] as String?,
        candidate['sdpMid'] as String?,
        candidate['sdpMLineIndex'] as int?,
      ),
    );
  }

  Future<void> _remoteWasSet() async {
    _remoteSet = true;
    final held = List<Map<String, dynamic>>.of(_heldCandidates);
    _heldCandidates.clear();
    for (final candidate in held) {
      await addCandidate(candidate);
    }
  }

  void _attach(RTCDataChannel channel) {
    _transport.attach(channel, onBroken: _fail);
    channel.onDataChannelState = (state) {
      switch (state) {
        case RTCDataChannelState.RTCDataChannelOpen:
          if (!_opened.isCompleted) _opened.complete();
        case RTCDataChannelState.RTCDataChannelClosed:
          _fail();
        default:
          break;
      }
    };
    if (channel.state == RTCDataChannelState.RTCDataChannelOpen &&
        !_opened.isCompleted) {
      _opened.complete();
    }
  }

  void _fail() {
    if (!_lost.isCompleted) _lost.complete();
    _transport.markBroken();
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _fail();
    await _transport.close();
    await _candidates.close();
    await _pc.close();
    // close() leaves the native connection registered; dispose() releases it.
    await _pc.dispose();
  }
}

/// The data channel as a [ChatTransport]. Sends are refused until the channel
/// is open, and incoming text frames are queued until a session listens.
class _DataChannelTransport implements ChatTransport {
  final _frames = StreamController<String>();
  final _binaryFrames = StreamController<Uint8List>();
  RTCDataChannel? _channel;
  void Function()? _onBroken;
  bool _broken = false;

  void attach(RTCDataChannel channel, {required void Function() onBroken}) {
    _channel = channel;
    _onBroken = onBroken;
    channel.onMessage = (message) {
      if (message.isBinary) {
        if (!_binaryFrames.isClosed) {
          _binaryFrames.add(message.binary);
        }
      } else {
        if (!_frames.isClosed) {
          _frames.add(message.text);
        }
      }
    };
  }

  void markBroken() {
    _broken = true;
    if (!_frames.isClosed) unawaited(_frames.close());
    if (!_binaryFrames.isClosed) unawaited(_binaryFrames.close());
  }

  @override
  bool send(String frame) {
    final channel = _channel;
    if (_broken || channel == null) return false;
    if (channel.state != RTCDataChannelState.RTCDataChannelOpen) return false;
    unawaited(
      channel.send(RTCDataChannelMessage(frame)).catchError((Object _) {
        _onBroken?.call();
      }),
    );
    return true;
  }

  @override
  bool sendBinary(Uint8List data) {
    final channel = _channel;
    if (_broken || channel == null) return false;
    if (channel.state != RTCDataChannelState.RTCDataChannelOpen) return false;
    unawaited(
      channel.send(RTCDataChannelMessage.fromBinary(data)).catchError((
        Object _,
      ) {
        _onBroken?.call();
      }),
    );
    return true;
  }

  @override
  Stream<String> get frames => _frames.stream;

  @override
  Stream<Uint8List> get binaryFrames => _binaryFrames.stream;

  @override
  Future<void> close() async {
    await _channel?.close();
    markBroken();
  }
}
