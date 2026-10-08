import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'devices.dart';
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
    this.devices = _defaultDevices,
  });

  static DeviceSelection _defaultDevices() => const DeviceSelection();

  final RTCVideoRenderer localRenderer;
  final RTCVideoRenderer remoteRenderer;

  /// Fetched when the call starts, so TURN credentials are fresh.
  final Future<List<Map<String, dynamic>>> Function() iceServers;

  /// "Hide my IP address": only use TURN relay candidates, so the other
  /// person never learns this device's IP address.
  final bool relayOnly;

  /// The user's chosen camera, microphone and speaker (read when the call
  /// starts).
  final DeviceSelection Function() devices;

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
    final chosen = devices();
    MediaStream stream;
    var noCamera = false;
    try {
      stream = await navigator.mediaDevices.getUserMedia({
        'audio': _audioConstraints(chosen.microphoneId),
        'video': video ? _videoConstraints(chosen.cameraId) : false,
      });
    } catch (e) {
      if (!video) rethrow;
      // No camera (or it is blocked or busy): join with the microphone
      // alone rather than not at all. The other side's video still comes
      // through.
      debugPrint('camera unavailable, joining with voice: $e');
      stream = await navigator.mediaDevices.getUserMedia({
        'audio': _audioConstraints(chosen.microphoneId),
        'video': false,
      });
      noCamera = true;
    }
    if (_closed) {
      await _stop(stream);
      return;
    }
    _localStream = stream;
    localRenderer.srcObject = stream;
    if (chosen.speakerId case final speaker?) {
      await _selectSpeaker(speaker);
    }

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
        case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
          _states.add(MediaConnectionState.disconnected);
        case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
          _states.add(MediaConnectionState.failed);
        default:
          break;
      }
    };
    for (final track in stream.getTracks()) {
      await pc.addTrack(track, stream);
    }
    if (noCamera) {
      // Still ask for the other side's video.
      await pc.addTransceiver(
        kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
        init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
      );
    }
  }

  @override
  Future<String> createOffer({bool iceRestart = false}) async {
    final pc = _pc!;
    // restartIce() makes the next offer an ICE restart on every platform
    // (the `iceRestart` offer option is ignored by the native stacks).
    if (iceRestart) await pc.restartIce();
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
      await _addCandidate(iceCandidate);
    } else {
      _pendingCandidates.add(iceCandidate);
    }
  }

  /// Candidates can arrive before the remote description; apply them now.
  Future<void> _applyPendingCandidates() async {
    _remoteDescriptionSet = true;
    for (final candidate in _pendingCandidates) {
      await _addCandidate(candidate);
    }
    _pendingCandidates.clear();
  }

  /// A late candidate of the network path an ICE restart replaced is
  /// refused; that's harmless.
  Future<void> _addCandidate(RTCIceCandidate candidate) async {
    try {
      await _pc?.addCandidate(candidate);
    } catch (e) {
      debugPrint('Ignored ICE candidate: $e');
    }
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

  static Object _audioConstraints(String? deviceId) =>
      deviceId == null ? true : {'deviceId': deviceId};

  static Map<String, Object> _videoConstraints(String? deviceId) => {
    if (deviceId != null) 'deviceId': deviceId else 'facingMode': 'user',
    'width': {'ideal': 1280},
    'height': {'ideal': 720},
  };

  Future<void> _selectSpeaker(String deviceId) async {
    try {
      await remoteRenderer.audioOutput(deviceId);
    } catch (_) {
      // Not supported here (e.g. Safari): the system default plays.
    }
  }

  @override
  Future<void> useDevice(DeviceKind kind, String? deviceId) async {
    if (_closed) return;
    if (kind == DeviceKind.speaker) {
      await _selectSpeaker(deviceId ?? 'default');
      return;
    }
    final stream = _localStream;
    final pc = _pc;
    if (stream == null || pc == null) return;
    final video = kind == DeviceKind.camera;
    final old = video ? stream.getVideoTracks() : stream.getAudioTracks();
    if (old.isEmpty) return; // e.g. a voice call has no camera to switch
    final fresh = await navigator.mediaDevices.getUserMedia({
      'audio': video ? false : _audioConstraints(deviceId),
      'video': video ? _videoConstraints(deviceId) : false,
    });
    final track = video
        ? fresh.getVideoTracks().first
        : fresh.getAudioTracks().first;
    if (_closed) {
      await _stop(fresh);
      return;
    }
    track.enabled = old.first.enabled;
    for (final sender in await pc.getSenders()) {
      if (sender.track?.kind == track.kind) await sender.replaceTrack(track);
    }
    for (final previous in old) {
      await stream.removeTrack(previous);
      await previous.stop();
    }
    await stream.addTrack(track);
    localRenderer.srcObject = stream;
  }

  int? _lostBefore;
  int? _receivedBefore;

  @override
  Future<QualitySample?> qualitySample() async {
    final pc = _pc;
    if (pc == null) return null;
    final reports = await pc.getStats();
    var lost = 0;
    var received = 0;
    var sawInbound = false;
    for (final report in reports) {
      final v = report.values;
      if (report.type == 'inbound-rtp') {
        sawInbound = true;
        lost += (v['packetsLost'] as num?)?.toInt() ?? 0;
        received += (v['packetsReceived'] as num?)?.toInt() ?? 0;
      }
    }
    double? loss;
    if (sawInbound && _lostBefore != null && _receivedBefore != null) {
      final newLost = lost - _lostBefore!;
      final newReceived = received - _receivedBefore!;
      final total = newLost + newReceived;
      if (total > 0) loss = (newLost / total).clamp(0, 1).toDouble();
    }
    if (sawInbound) {
      _lostBefore = lost;
      _receivedBefore = received;
    }
    return QualitySample(
      roundTrip: roundTripFromStats(reports),
      packetLoss: loss,
      sendLoss: sendLossFromStats(reports),
      sendBitrate: sendBitrateFromStats(reports),
    );
  }

  @override
  Future<bool> setVideoLevel(VideoLevel level) {
    // One change at a time: the browser rejects parameters read before
    // another change finished.
    final next = _videoLevelQueue.then((_) => _applyVideoLevel(level));
    _videoLevelQueue = next.then((_) {}, onError: (_) {});
    return next;
  }

  Future<void> _videoLevelQueue = Future.value();

  Future<bool> _applyVideoLevel(VideoLevel level) async {
    final pc = _pc;
    if (pc == null || _closed) return false;
    var applied = false;
    for (final sender in await pc.getSenders()) {
      if (sender.track?.kind != 'video') continue;
      final parameters = sender.parameters;
      final encodings = parameters.encodings;
      if (encodings == null || encodings.isEmpty) continue;
      for (final encoding in encodings) {
        encoding.active = level != VideoLevel.paused;
        encoding.maxBitrate = switch (level) {
          VideoLevel.reduced => 500000,
          VideoLevel.low => 150000,
          _ => null,
        };
        encoding.scaleResolutionDownBy = switch (level) {
          VideoLevel.reduced => 1.5,
          VideoLevel.low => 3.0,
          _ => 1.0,
        };
      }
      try {
        applied = await sender.setParameters(parameters);
      } catch (e) {
        // Not every platform lets the encoding change: the call goes on,
        // and WebRTC's own congestion control still lowers the bitrate.
        debugPrint('video level not changed: $e');
      }
    }
    return applied;
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

/// Round-trip time from WebRTC statistics: the worst `roundTripTime` of the
/// `remote-inbound-rtp` reports (measured with RTCP, in seconds everywhere).
///
/// The selected candidate pair's `currentRoundTripTime` isn't used: Firefox
/// reports it in milliseconds instead of seconds, which made a good call look
/// poor. Until the first RTCP report (about a second into the call) there is
/// no round-trip time; packet loss still counts.
@visibleForTesting
Duration? roundTripFromStats(Iterable<StatsReport> reports) {
  double? worst;
  for (final report in reports) {
    final rtt = report.values['roundTripTime'];
    if (report.type == 'remote-inbound-rtp' && rtt is num && rtt >= 0) {
      if (worst == null || rtt > worst) worst = rtt.toDouble();
    }
  }
  return worst == null ? null : Duration(microseconds: (worst * 1e6).round());
}

/// Loss of this device's outgoing video as the other side reports it
/// (`fractionLost` of the video `remote-inbound-rtp`, 0–1), or `null` before
/// the first report.
@visibleForTesting
double? sendLossFromStats(Iterable<StatsReport> reports) {
  double? worst;
  for (final report in reports) {
    final v = report.values;
    final lost = v['fractionLost'];
    if (report.type == 'remote-inbound-rtp' &&
        v['kind'] == 'video' &&
        lost is num &&
        lost >= 0) {
      if (worst == null || lost > worst) worst = lost.toDouble();
    }
  }
  return worst?.clamp(0, 1).toDouble();
}

/// WebRTC's estimate of the bandwidth this device can send
/// (`availableOutgoingBitrate` of the selected candidate pair), in bits/s.
@visibleForTesting
int? sendBitrateFromStats(Iterable<StatsReport> reports) {
  int? best;
  for (final report in reports) {
    final v = report.values;
    final rate = v['availableOutgoingBitrate'];
    final selected = v['nominated'] == true || v['selected'] == true;
    if (report.type == 'candidate-pair' &&
        v['state'] == 'succeeded' &&
        selected &&
        rate is num &&
        rate > 0) {
      if (best == null || rate > best) best = rate.toInt();
    }
  }
  return best;
}
