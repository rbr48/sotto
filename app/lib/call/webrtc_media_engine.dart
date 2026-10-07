import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'media_engine.dart';

/// [MediaEngine] backed by flutter_webrtc. The video renderers belong to the
/// caller (they outlive individual calls); this engine only sets their
/// sources.
class WebRtcMediaEngine implements MediaEngine {
  WebRtcMediaEngine({
    required this.localRenderer,
    required this.remoteRenderer,
    required this.iceServers,
    this.relayOnly = false,
  });

  final RTCVideoRenderer localRenderer;
  final RTCVideoRenderer remoteRenderer;

  /// Fetched when the call starts, so TURN credentials are fresh.
  final Future<List<Map<String, dynamic>>> Function() iceServers;

  /// "Hide my IP address": only use TURN relay candidates, so the other
  /// person never learns this device's IP address.
  final bool relayOnly;

  final _candidates = StreamController<Map<String, Object?>>.broadcast();
  final _states = StreamController<MediaConnectionState>.broadcast();
  final _pendingCandidates = <RTCIceCandidate>[];
  MediaStream? _localStream;
  RTCPeerConnection? _pc;
  bool _remoteDescriptionSet = false;
  bool _closed = false;

  @override
  Stream<Map<String, Object?>> get localCandidates => _candidates.stream;

  @override
  Stream<MediaConnectionState> get connectionStates => _states.stream;

  @override
  Future<void> prepare({required bool video}) async {
    final stream = await navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': video
          ? {
              'facingMode': 'user',
              'width': {'ideal': 1280},
              'height': {'ideal': 720},
            }
          : false,
    });
    if (_closed) {
      await _stop(stream);
      return;
    }
    _localStream = stream;
    localRenderer.srcObject = stream;

    final pc = await createPeerConnection({
      'iceServers': await iceServers(),
      'iceTransportPolicy': relayOnly ? 'relay' : 'all',
      'sdpSemantics': 'unified-plan',
    });
    _pc = pc;
    pc.onIceCandidate = (candidate) {
      if (candidate.candidate == null || _closed) return;
      _candidates.add({
        'candidate': candidate.candidate,
        'sdpMid': candidate.sdpMid,
        'sdpMLineIndex': candidate.sdpMLineIndex,
      });
    };
    pc.onTrack = (event) {
      if (event.streams.isNotEmpty && !_closed) {
        remoteRenderer.srcObject = event.streams.first;
      }
    };
    pc.onConnectionState = (state) {
      if (_closed) return;
      switch (state) {
        case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
          _states.add(MediaConnectionState.connected);
        case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
          _states.add(MediaConnectionState.failed);
        default:
          break;
      }
    };
    for (final track in stream.getTracks()) {
      await pc.addTrack(track, stream);
    }
  }

  @override
  Future<String> createOffer() async {
    final pc = _pc!;
    final offer = await pc.createOffer();
    await pc.setLocalDescription(offer);
    return offer.sdp!;
  }

  @override
  Future<String> acceptOffer(String sdp) async {
    final pc = _pc!;
    await pc.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));
    await _applyPendingCandidates();
    final answer = await pc.createAnswer();
    await pc.setLocalDescription(answer);
    return answer.sdp!;
  }

  @override
  Future<void> acceptAnswer(String sdp) async {
    await _pc!.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
    await _applyPendingCandidates();
  }

  @override
  Future<void> addRemoteCandidate(Map<String, dynamic> candidate) async {
    final iceCandidate = RTCIceCandidate(
      candidate['candidate'] as String?,
      candidate['sdpMid'] as String?,
      candidate['sdpMLineIndex'] as int?,
    );
    if (_remoteDescriptionSet) {
      await _pc?.addCandidate(iceCandidate);
    } else {
      _pendingCandidates.add(iceCandidate);
    }
  }

  /// Candidates can arrive before the remote description; apply them now.
  Future<void> _applyPendingCandidates() async {
    _remoteDescriptionSet = true;
    for (final candidate in _pendingCandidates) {
      await _pc?.addCandidate(candidate);
    }
    _pendingCandidates.clear();
  }

  @override
  void setMicEnabled(bool enabled) {
    for (final track
        in _localStream?.getAudioTracks() ?? <MediaStreamTrack>[]) {
      track.enabled = enabled;
    }
  }

  @override
  void setCameraEnabled(bool enabled) {
    for (final track
        in _localStream?.getVideoTracks() ?? <MediaStreamTrack>[]) {
      track.enabled = enabled;
    }
  }

  @override
  Future<void> switchCamera() async {
    final tracks = _localStream?.getVideoTracks() ?? <MediaStreamTrack>[];
    if (tracks.isNotEmpty) await Helper.switchCamera(tracks.first);
  }

  @override
  Future<MediaRoute?> currentRoute() async {
    final pc = _pc;
    if (pc == null) return null;
    final reports = await pc.getStats();
    final byId = {for (final report in reports) report.id: report};

    // The transport names the selected pair; older stacks only flag the pair.
    String? pairId;
    for (final report in reports) {
      if (report.type == 'transport') {
        pairId = report.values['selectedCandidatePairId'] as String?;
        if (pairId != null) break;
      }
    }
    final pair = pairId != null
        ? byId[pairId]
        : reports.where((r) {
            final v = r.values;
            return r.type == 'candidate-pair' &&
                (v['selected'] == true ||
                    (v['nominated'] == true && v['state'] == 'succeeded'));
          }).firstOrNull;
    if (pair == null) return null;
    String? typeOf(Object? candidateId) =>
        byId[candidateId]?.values['candidateType'] as String?;
    final local = typeOf(pair.values['localCandidateId']);
    final remote = typeOf(pair.values['remoteCandidateId']);
    if (local == null && remote == null) return null;
    return local == 'relay' || remote == 'relay'
        ? MediaRoute.relayed
        : MediaRoute.direct;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    localRenderer.srcObject = null;
    remoteRenderer.srcObject = null;
    final pc = _pc;
    _pc = null;
    await pc?.close();
    final stream = _localStream;
    _localStream = null;
    if (stream != null) await _stop(stream);
    await _candidates.close();
    await _states.close();
  }

  static Future<void> _stop(MediaStream stream) async {
    for (final track in stream.getTracks()) {
      await track.stop();
    }
    await stream.dispose();
  }
}
