enum MediaConnectionState { connecting, connected, failed, closed }

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

  /// Caller side: returns the SDP offer.
  Future<String> createOffer();

  /// Callee side: applies the offer and returns the SDP answer.
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

  /// Stops all media and closes the connection. Safe to call more than once.
  Future<void> close();
}
