import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:sodium/sodium.dart';

import '../core/test_hooks.dart';
import '../crypto/encoding.dart';
import '../crypto/sotto_crypto.dart';
import '../relay/relay_client.dart';
import 'call_code.dart';
import 'call_manager.dart';
import 'media_engine.dart';
import 'webrtc_media_engine.dart';

/// Everything the call screen needs: the user's identity and call link, the
/// relay connection, and the current call.
///
/// Incoming relay messages are opened as end-to-end envelopes (the sender
/// must match the relay-authenticated address) and handed to [CallManager].
class CallController extends ChangeNotifier {
  CallController({
    required this.relayUrl,
    required this.linkBase,
    this.persistentIdentity = !kIsWeb,
    SecretStore? settings,
  }) : _settings = settings ?? (kIsWeb ? MemorySecretStore() : OsSecretStore());

  /// Used only if the relay offers no STUN/TURN servers (e.g. a bare local
  /// test relay). The Sotto relay hands out its own STUN and TURN servers.
  static const fallbackIceServers = [
    {
      'urls': ['stun:stun.l.google.com:19302'],
    },
  ];

  static const _hideIpSetting = 'sotto.settings.hide_ip';

  final Uri relayUrl;
  final Uri linkBase;

  /// Professionals' devices keep their identity in the OS keystore; the
  /// browser (guests, for now) gets a temporary identity per page load.
  final bool persistentIdentity;
  final SecretStore _settings;

  final RTCVideoRenderer localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer remoteRenderer = RTCVideoRenderer();

  Sodium? _sodium;
  Identity? _identity;
  EnvelopeCodec? _codec;
  RelayClient? _relay;
  CallManager? _manager;
  final _subscriptions = <StreamSubscription<Object?>>[];

  bool _ready = false;
  bool get ready => _ready;

  /// Set if startup failed (e.g. libsodium could not load).
  String? startupError;

  /// Set if the identity could not be stored and a temporary one is used.
  String? identityWarning;

  String? _callLink;
  String? get callLink => _callLink;

  RelayStatus get relayStatus => _relay?.status ?? RelayStatus.offline;

  CallState get call => _manager?.state ?? CallState.idle;

  bool _hideIp = false;

  /// "Hide my IP address": calls only use the TURN relay, so the other
  /// person never sees this device's IP address.
  bool get hideIp => _hideIp;

  /// Whether the relay offered a TURN server (needed for [hideIp]).
  bool get turnAvailable =>
      _relay?.iceServers.any(
        (s) => (s['urls'] as List).any((u) => '$u'.startsWith('turn')),
      ) ??
      false;

  MediaRoute? _route;

  /// How the current call's media travels, once connected.
  MediaRoute? get route => _route;

  bool _micEnabled = true;
  bool get micEnabled => _micEnabled;
  bool _cameraEnabled = true;
  bool get cameraEnabled => _cameraEnabled;

  /// Safety number with the current call's peer.
  String? get safetyNumber {
    final peer = call.peer;
    final sodium = _sodium;
    final identity = _identity;
    if (peer == null || sodium == null || identity == null) return null;
    return SafetyNumber.compute(sodium, identity.publicIdentity, peer);
  }

  Future<void> start() async {
    try {
      final sodium = _sodium = await SottoCrypto.init();
      final identity = _identity = await _loadIdentity(sodium);
      _hideIp = await _readSetting(_hideIpSetting) == '1';
      _codec = EnvelopeCodec(sodium, identity);
      await localRenderer.initialize();
      await remoteRenderer.initialize();

      final manager = _manager = CallManager(
        send: (to, type, body, callId) => _relay?.send(
          to.id,
          _codec!.seal(recipient: to, type: type, body: body, callId: callId),
        ),
        createMedia: () => WebRtcMediaEngine(
          localRenderer: localRenderer,
          remoteRenderer: remoteRenderer,
          iceServers: _iceServersForCall,
          relayOnly: _hideIp,
        ),
        newCallId: () => b64Encode(sodium.randombytes.buf(16)),
      );
      manager.addListener(_onCallChanged);

      final relay = _relay = RelayClient(
        url: relayUrl,
        sodium: sodium,
        identity: identity,
      );
      _subscriptions
        ..add(relay.statusChanges.listen((_) => notifyListeners()))
        ..add(relay.messages.listen(_onRelayMessage));
      relay.start();

      _callLink = CallCode.link(linkBase, identity.card(sodium));
      publishForTests('call-link', _callLink!);
      _ready = true;
    } catch (e) {
      startupError = '$e';
    }
    notifyListeners();
  }

  Future<Identity> _loadIdentity(Sodium sodium) async {
    if (!persistentIdentity) return Identity.generate(sodium);
    try {
      return await IdentityStore(sodium, OsSecretStore()).loadOrCreate();
    } catch (e) {
      identityWarning =
          'Could not use the system keystore ($e). '
          'Using a temporary identity: your call link will change when the app restarts.';
      return Identity.generate(sodium);
    }
  }

  Future<List<Map<String, dynamic>>> _iceServersForCall() async {
    final servers = await _relay?.freshIceServers() ?? const [];
    return servers.isEmpty ? fallbackIceServers : servers;
  }

  Future<String?> _readSetting(String key) async {
    try {
      return await _settings.read(key);
    } catch (_) {
      return null;
    }
  }

  Future<void> setHideIp(bool value) async {
    _hideIp = value;
    publishForTests('hide-ip', '$value');
    notifyListeners();
    try {
      await _settings.write(_hideIpSetting, value ? '1' : '0');
    } catch (_) {
      // Not persisted; still applies until the app restarts.
    }
  }

  void _onRelayMessage(RelayMessage message) {
    final codec = _codec;
    final manager = _manager;
    if (codec == null || manager == null) return;
    final OpenedMessage opened;
    try {
      opened = codec.open(message.body, expectedSender: message.from);
    } on EnvelopeException catch (e) {
      debugPrint('Dropped envelope: ${e.error.name}');
      return;
    }
    unawaited(manager.handle(opened));
  }

  void _onCallChanged() {
    if (call.phase == CallPhase.calling || call.phase == CallPhase.incoming) {
      _micEnabled = true;
      _cameraEnabled = true;
      _route = null;
    }
    if (call.phase == CallPhase.connected && _route == null) {
      unawaited(_detectRoute());
    }
    publishForTests('call-phase', call.phase.name);
    notifyListeners();
  }

  /// Reads the selected ICE candidate pair a few times after connecting
  /// (stats can lag behind the "connected" event).
  Future<void> _detectRoute() async {
    for (final delay in const [300, 1000, 3000]) {
      await Future<void>.delayed(Duration(milliseconds: delay));
      if (call.phase != CallPhase.connected) return;
      final route = await _manager?.media?.currentRoute();
      if (route != null) {
        _route = route;
        publishForTests('route', route.name);
        notifyListeners();
        return;
      }
    }
  }

  /// Calls the person behind a call link or code.
  /// Throws [InvalidIdentityException] for an invalid link.
  Future<void> callSomeone(String linkOrCode, {bool video = true}) async {
    final peer = CallCode.parse(_sodium!, linkOrCode);
    if (peer.id == _identity!.id) {
      throw const InvalidIdentityException('that is your own call link');
    }
    _manager!.dismiss();
    await _manager!.call(peer, video: video);
  }

  Future<void> accept() async => _manager?.accept();
  Future<void> decline() async => _manager?.decline();
  Future<void> hangUp() async => _manager?.hangUp();
  void dismiss() => _manager?.dismiss();

  void toggleMic() {
    _micEnabled = !_micEnabled;
    _manager?.media?.setMicEnabled(_micEnabled);
    notifyListeners();
  }

  void toggleCamera() {
    _cameraEnabled = !_cameraEnabled;
    _manager?.media?.setCameraEnabled(_cameraEnabled);
    notifyListeners();
  }

  Future<void> switchCamera() async => _manager?.media?.switchCamera();

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _manager?.dispose();
    unawaited(_relay?.stop());
    _identity?.dispose();
    if (_ready) {
      localRenderer.dispose();
      remoteRenderer.dispose();
    }
    super.dispose();
  }
}
