import 'dart:async';

import 'package:sotto/call/devices.dart';
import 'package:sotto/call/media_engine.dart';

/// Records what the call flow asks of the media layer.
class FakeMediaEngine implements MediaEngine {
  final log = <String>[];
  final _candidates = StreamController<Map<String, Object?>>.broadcast();
  final _states = StreamController<MediaConnectionState>.broadcast();
  bool failPrepare = false;
  bool closed = false;
  bool micEnabled = true;

  void emitCandidate(String candidate) =>
      _candidates.add({'candidate': candidate});
  void emitState(MediaConnectionState state) => _states.add(state);

  @override
  Future<void> prepare({required bool video}) async {
    log.add('prepare(video: $video)');
    if (failPrepare) throw StateError('no camera');
  }

  @override
  Future<String> createOffer() async {
    log.add('createOffer');
    return 'offer-sdp';
  }

  @override
  Future<String> acceptOffer(String sdp) async {
    log.add('acceptOffer($sdp)');
    return 'answer-sdp';
  }

  @override
  Future<void> acceptAnswer(String sdp) async => log.add('acceptAnswer($sdp)');

  @override
  Future<void> addRemoteCandidate(Map<String, dynamic> candidate) async =>
      log.add('addRemoteCandidate(${candidate['candidate']})');

  @override
  Stream<Map<String, Object?>> get localCandidates => _candidates.stream;

  @override
  Stream<MediaConnectionState> get connectionStates => _states.stream;

  @override
  void setMicEnabled(bool enabled) => micEnabled = enabled;

  @override
  void setCameraEnabled(bool enabled) {}

  @override
  Future<void> switchCamera() async {}

  MediaRoute? route;

  @override
  Future<MediaRoute?> currentRoute() async => route;

  QualitySample? quality;
  final usedDevices = <(DeviceKind, String?)>[];

  @override
  Future<QualitySample?> qualitySample() async => quality;

  @override
  Future<void> useDevice(DeviceKind kind, String? deviceId) async =>
      usedDevices.add((kind, deviceId));

  @override
  Future<void> close() async {
    closed = true;
    log.add('close');
  }
}
