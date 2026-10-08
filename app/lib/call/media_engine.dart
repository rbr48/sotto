import 'devices.dart';

enum MediaConnectionState {
  connecting,
  connected,

  /// The connection stopped carrying packets (e.g. the network changed). It
  /// may come back by itself, or after an ICE restart.
  disconnected,
  failed,
  closed,
}

/// How well the connection is doing, from the device's own statistics
/// (never sent anywhere).
enum CallQuality { good, fair, poor }

/// Round-trip time and packet loss over the last few seconds.
class QualitySample {
  const QualitySample({
    this.roundTrip,
    this.packetLoss,
    this.sendLoss,
    this.sendBitrate,
  });

  final Duration? roundTrip;

  /// Fraction of incoming packets lost, 0–1.
  final double? packetLoss;

  /// Fraction of this device's outgoing video lost on the way, as the other
  /// side reports it, 0–1.
  final double? sendLoss;

  /// The bandwidth WebRTC estimates this device can send, in bits/s.
  final int? sendBitrate;

  /// How well this device's upload carries its video: what [VideoAdapter]
  /// acts on. Each side adapts what it sends; the other side does the same
  /// for its own upload.
  ///
  /// Loss and round trip judge it. The bandwidth estimate follows what is
  /// sent (lowered video lowers it too), so it only counts when it falls
  /// below what even low video needs, and not while video is paused.
  CallQuality? uploadAt(VideoLevel level) {
    final rtt = roundTrip?.inMilliseconds;
    final loss = sendLoss;
    final rate = level == VideoLevel.paused ? null : sendBitrate;
    if (rtt == null && loss == null && rate == null) return null;
    if ((loss ?? 0) > 0.10 ||
        (rtt ?? 0) > 600 ||
        (rate != null && rate < 100000)) {
      return CallQuality.poor;
    }
    if ((loss ?? 0) > 0.03 || (rtt ?? 0) > 300) return CallQuality.fair;
    return CallQuality.good;
  }

  /// Thresholds roughly where voice gets choppy (fair) and hard to follow
  /// (poor).
  CallQuality? get quality {
    final rtt = roundTrip?.inMilliseconds;
    final loss = packetLoss;
    if (rtt == null && loss == null) return null;
    if ((loss ?? 0) > 0.10 || (rtt ?? 0) > 600) return CallQuality.poor;
    if ((loss ?? 0) > 0.03 || (rtt ?? 0) > 300) return CallQuality.fair;
    return CallQuality.good;
  }
}

/// How much video this device sends, stepped down when its upload
/// struggles (see [VideoAdapter]).
enum VideoLevel {
  /// What the camera and the connection allow.
  full,

  /// At most about 500 kbit/s, at two thirds of the resolution.
  reduced,

  /// At most about 150 kbit/s, at a third of the resolution.
  low,

  /// No video is sent; the voice goes on. The camera stays open, so video
  /// comes back as soon as the connection allows.
  paused,
}

/// How the media of a connected call travels.
enum MediaRoute {
  /// Device to device (possibly through NAT), no server in between.
  direct,

  /// Through the TURN server: neither side sees the other's IP address.
  relayed,
}

/// The media side of a call (camera, microphone, WebRTC peer connection).
///
/// [CallManager] drives the call flow through this interface, so the flow can
/// be tested without real devices. One engine is used for one call.
abstract interface class MediaEngine {
  /// Opens camera/microphone and creates the peer connection.
  Future<void> prepare({required bool video});

  /// Caller side: returns the SDP offer. With [iceRestart], during a call,
  /// the offer asks both sides to look for a new network path (after a
  /// network change), keeping the call and its media.
  Future<String> createOffer({bool iceRestart = false});

  /// Callee side: applies the offer (the first one, or an ICE restart
  /// during the call) and returns the SDP answer.
  Future<String> acceptOffer(String sdp);

  /// Caller side: applies the answer.
  Future<void> acceptAnswer(String sdp);

  /// Applies a remote ICE candidate (buffered until the remote description
  /// is known).
  Future<void> addRemoteCandidate(Map<String, dynamic> candidate);

  /// Local ICE candidates to send to the other side.
  Stream<Map<String, Object?>> get localCandidates;

  Stream<MediaConnectionState> get connectionStates;

  void setMicEnabled(bool enabled);
  void setCameraEnabled(bool enabled);
  Future<void> switchCamera();

  /// The route of the connected call, or `null` if not known (yet).
  Future<MediaRoute?> currentRoute();

  /// Connection statistics since the previous sample.
  Future<QualitySample?> qualitySample();

  /// Limits the video this device sends (nothing to do in a voice call).
  /// Returns whether the video sender took the change.
  Future<bool> setVideoLevel(VideoLevel level);

  /// Switches to another camera, microphone or audio output during the
  /// call (`null` = system default).
  Future<void> useDevice(DeviceKind kind, String? deviceId);

  /// Stops all media and closes the connection. Safe to call more than once.
  Future<void> close();
}
