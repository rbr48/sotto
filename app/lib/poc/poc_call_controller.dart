import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'dev_room_signaling.dart';

enum PocCallStatus {
  idle,
  joining,
  waitingForPeer,
  connecting,
  connected,
  failed,
}

/// Phase 1 proof of concept: a 1:1 WebRTC call between two peers in a
/// dev room. The peer that joins second creates the offer.
///
/// Uses public STUN only, so it is expected to work on the same network or
/// simple NATs. TURN arrives in Phase 4.
class PocCallController extends ChangeNotifier {
  PocCallController({
    this.iceServers = const [
      {'urls': 'stun:stun.l.google.com:19302'},
    ],
  });

  final List<Map<String, dynamic>> iceServers;

  final RTCVideoRenderer localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer remoteRenderer = RTCVideoRenderer();

  PocCallStatus _status = PocCallStatus.idle;
  PocCallStatus get status => _status;

  String? _error;
  String? get error => _error;

  bool _micEnabled = true;
  bool get micEnabled => _micEnabled;

  bool _cameraEnabled = true;
  bool get cameraEnabled => _cameraEnabled;

  bool get inRoom =>
      _status != PocCallStatus.idle && _status != PocCallStatus.failed;

  DevRoomSignaling? _signaling;
  StreamSubscription<DevRoomEvent>? _events;
  MediaStream? _localStream;
  RTCPeerConnection? _pc;
  final List<RTCIceCandidate> _pendingCandidates = [];
  bool _remoteDescriptionSet = false;
  bool _renderersReady = false;
  bool _disposed = false;

  Future<void> join({required Uri server, required String room}) async {
    if (inRoom) return;
    _error = null;
    _setStatus(PocCallStatus.joining);
    try {
      if (!_renderersReady) {
        await localRenderer.initialize();
        await remoteRenderer.initialize();
        _renderersReady = true;
      }
      _localStream = await navigator.mediaDevices.getUserMedia({
        'audio': true,
        'video': {
          'facingMode': 'user',
          'width': {'ideal': 1280},
          'height': {'ideal': 720},
        },
      });
      localRenderer.srcObject = _localStream;
      _micEnabled = true;
      _cameraEnabled = true;

      final signaling = await DevRoomSignaling.connect(server);
      _signaling = signaling;
      _events = signaling.events.listen(
        _onEvent,
        onError: (Object e) => _fail('Connection to server lost: $e'),
        onDone: () {
          if (inRoom) _fail('Connection to server closed');
        },
      );
      signaling.join(room);
    } catch (e) {
      await _fail('Could not start: $e');
    }
  }

  Future<void> hangUp() async {
    await _teardown();
    _setStatus(PocCallStatus.idle);
  }

  void toggleMic() {
    _micEnabled = !_micEnabled;
    for (final track
        in _localStream?.getAudioTracks() ?? <MediaStreamTrack>[]) {
      track.enabled = _micEnabled;
    }
    notifyListeners();
  }

  void toggleCamera() {
    _cameraEnabled = !_cameraEnabled;
    for (final track
        in _localStream?.getVideoTracks() ?? <MediaStreamTrack>[]) {
      track.enabled = _cameraEnabled;
    }
    notifyListeners();
  }

  Future<void> switchCamera() async {
    final tracks = _localStream?.getVideoTracks() ?? <MediaStreamTrack>[];
    if (tracks.isNotEmpty) await Helper.switchCamera(tracks.first);
  }

  Future<void> _onEvent(DevRoomEvent event) async {
    try {
      switch (event) {
        case RoomJoined(:final peers):
          if (peers == 0) {
            _setStatus(PocCallStatus.waitingForPeer);
          } else {
            await _startPeerConnection();
            await _sendOffer();
          }
        case PeerJoined():
          // The newcomer sends the offer; we prepare and wait for it.
          await _startPeerConnection();
        case PeerLeft():
          await _closePeerConnection();
          remoteRenderer.srcObject = null;
          _setStatus(PocCallStatus.waitingForPeer);
        case SignalReceived(:final data):
          await _onSignal(data);
        case RoomError(:final code):
          await _fail(_describeRoomError(code));
      }
    } catch (e) {
      await _fail('Call setup failed: $e');
    }
  }

  Future<void> _startPeerConnection() async {
    await _closePeerConnection();
    _setStatus(PocCallStatus.connecting);
    final pc = await createPeerConnection({
      'iceServers': iceServers,
      'sdpSemantics': 'unified-plan',
    });
    _pc = pc;
    pc.onIceCandidate = (candidate) {
      if (candidate.candidate == null) return;
      _signaling?.signal({
        'kind': 'candidate',
        'candidate': candidate.candidate,
        'sdpMid': candidate.sdpMid,
        'sdpMLineIndex': candidate.sdpMLineIndex,
      });
    };
    pc.onTrack = (event) {
      if (event.streams.isNotEmpty) {
        remoteRenderer.srcObject = event.streams.first;
        notifyListeners();
      }
    };
    pc.onConnectionState = (state) {
      switch (state) {
        case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
          _setStatus(PocCallStatus.connected);
        case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
          _fail('Could not connect to the other device (try the same network)');
        default:
          break;
      }
    };
    final stream = _localStream;
    if (stream != null) {
      for (final track in stream.getTracks()) {
        await pc.addTrack(track, stream);
      }
    }
  }

  Future<void> _sendOffer() async {
    final pc = _pc!;
    final offer = await pc.createOffer();
    await pc.setLocalDescription(offer);
    _signaling?.signal({'kind': 'offer', 'sdp': offer.sdp, 'type': offer.type});
  }

  Future<void> _onSignal(Map<String, dynamic> data) async {
    final pc = _pc;
    if (pc == null) return;
    switch (data['kind']) {
      case 'offer':
        await pc.setRemoteDescription(
          RTCSessionDescription(
            data['sdp'] as String?,
            data['type'] as String?,
          ),
        );
        await _remoteDescriptionApplied();
        final answer = await pc.createAnswer();
        await pc.setLocalDescription(answer);
        _signaling?.signal({
          'kind': 'answer',
          'sdp': answer.sdp,
          'type': answer.type,
        });
      case 'answer':
        await pc.setRemoteDescription(
          RTCSessionDescription(
            data['sdp'] as String?,
            data['type'] as String?,
          ),
        );
        await _remoteDescriptionApplied();
      case 'candidate':
        final candidate = RTCIceCandidate(
          data['candidate'] as String?,
          data['sdpMid'] as String?,
          data['sdpMLineIndex'] as int?,
        );
        if (_remoteDescriptionSet) {
          await pc.addCandidate(candidate);
        } else {
          _pendingCandidates.add(candidate);
        }
    }
  }

  /// Candidates can arrive before the remote description; apply them now.
  Future<void> _remoteDescriptionApplied() async {
    _remoteDescriptionSet = true;
    final pc = _pc!;
    for (final candidate in _pendingCandidates) {
      await pc.addCandidate(candidate);
    }
    _pendingCandidates.clear();
  }

  Future<void> _closePeerConnection() async {
    final pc = _pc;
    _pc = null;
    _remoteDescriptionSet = false;
    _pendingCandidates.clear();
    await pc?.close();
  }

  Future<void> _teardown() async {
    await _events?.cancel();
    _events = null;
    final signaling = _signaling;
    _signaling = null;
    await _closePeerConnection();
    if (signaling != null) {
      try {
        await signaling.close();
      } catch (_) {
        // Already closed.
      }
    }
    for (final track in _localStream?.getTracks() ?? <MediaStreamTrack>[]) {
      await track.stop();
    }
    await _localStream?.dispose();
    _localStream = null;
    if (_renderersReady) {
      localRenderer.srcObject = null;
      remoteRenderer.srcObject = null;
    }
  }

  Future<void> _fail(String message) async {
    await _teardown();
    _error = message;
    _setStatus(PocCallStatus.failed);
  }

  void _setStatus(PocCallStatus status) {
    if (_disposed) return;
    _status = status;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(
      _teardown().whenComplete(() {
        if (_renderersReady) {
          localRenderer.dispose();
          remoteRenderer.dispose();
        }
      }),
    );
    super.dispose();
  }
}

String _describeRoomError(String code) => switch (code) {
  'room-full' => 'That room already has two people in it.',
  'bad-room' => 'Room codes must be 4–64 letters, numbers, - or _.',
  'too-many-rooms' => 'The server is full. Try again later.',
  _ => 'Server error: $code',
};
