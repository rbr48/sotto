import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:sodium/sodium.dart';

import '../core/test_hooks.dart';
import '../crypto/encoding.dart';
import '../crypto/sotto_crypto.dart';
import '../guest/guest_host.dart';
import '../guest/guest_link.dart';
import '../guest/guest_visit.dart';
import '../relay/relay_client.dart';
import 'call_code.dart';
import 'call_manager.dart';
import 'trusted_callers.dart';
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
    this.guestLinkPayload,
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
  static const _hostNameSetting = 'sotto.settings.host_name';

  final Uri relayUrl;
  final Uri linkBase;

  /// Professionals' devices keep their identity in the OS keystore; the
  /// browser (guests, for now) gets a temporary identity per page load.
  final bool persistentIdentity;
  final SecretStore _settings;

  /// Set when the app was opened from a guest link (`#g=…`): this device is
  /// a guest for the duration of the page, with a temporary identity.
  final String? guestLinkPayload;
  bool get isGuest => guestLinkPayload != null;

  GuestVisit? _visit;

  /// The guest's visit (guest mode only).
  GuestVisit? get guestVisit => _visit;

  /// Set in guest mode if the link is invalid or expired.
  GuestLinkProblem? guestLinkProblem;

  GuestLinkStore? _links;
  GuestHost? _host;

  late final TrustedCallers trustedCallers = TrustedCallers(_settings)
    ..addListener(_onTrustedChanged);

  /// Peer of a call that admitted a guest from the waiting room (shown
  /// differently from a trusted caller's auto-answer).
  String? _admittedGuestId;

  /// The professional's waiting room (not in guest mode).
  GuestHost? get guestHost => _host;

  String _hostName = '';

  /// The name guests see on the professional's links.
  String get hostName => _hostName;

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
      final identity = _identity = isGuest
          ? Identity.generate(sodium)
          : await _loadIdentity(sodium);
      _hideIp = await _readSetting(_hideIpSetting) == '1';
      _hostName = await _readSetting(_hostNameSetting) ?? '';
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
        // A guest's page answers the call that admits it from the waiting room.
        autoAnswer: _decideAutoAnswer,
      );
      manager.addListener(_onCallChanged);

      if (!isGuest) {
        try {
          await trustedCallers.load();
        } catch (_) {
          // Keystore unavailable: auto-answer stays off.
        }
      }

      if (guestLinkPayload case final payload?) {
        try {
          final link = GuestLink.parse(sodium, payload);
          _visit = GuestVisit(
            link: link,
            send: _sendGuestMessage,
            newKnockId: () => b64Encode(sodium.randombytes.buf(12)),
          )..addListener(notifyListeners);
        } on GuestLinkException catch (e) {
          guestLinkProblem = e.problem;
        }
      } else {
        final links = _links = GuestLinkStore(sodium, _settings);
        try {
          await links.load();
          await links.ensurePersonal();
        } catch (_) {
          // Keystore unavailable: links work until the app restarts.
        }
        _host = GuestHost(
          links: links,
          send: _sendGuestMessage,
          onAdmit: (guest) async {
            manager.dismiss();
            _admittedGuestId = guest.guest.id;
            await manager.call(
              guest.guest,
              video: guest.video,
              inviteExtras: {'knock': guest.knockId},
            );
          },
        )..addListener(notifyListeners);
        _publishGuestLink();
      }

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

  /// Auto-answer: a guest's page answers the call that admits it; a
  /// professional's device answers verified trusted callers if switched on.
  AutoAnswer? _decideAutoAnswer(OpenedMessage invite) {
    if (_visit?.isAdmission(invite) == true) {
      return const AutoAnswer(delay: Duration.zero, video: true);
    }
    if (isGuest) return null;
    return trustedCallers.decide(
      invite.sender,
      videoCall: invite.body['video'] != false,
    );
  }

  /// Whether this device's camera is part of the current call (false for
  /// voice calls and voice-only auto-answers).
  bool get sendingVideo =>
      call.active &&
      (localRenderer.srcObject?.getVideoTracks().isNotEmpty ?? false);

  /// Whether the current call was answered automatically because of the
  /// callee's auto-answer setting (not a guest being admitted).
  bool get autoAnswered {
    final call = this.call;
    return call.autoAnswered && call.peer?.id != _admittedGuestId && !isGuest;
  }

  void _onTrustedChanged() {
    publishForTests('auto-answer', '${trustedCallers.enabled}');
    notifyListeners();
  }

  /// Marks the peer of the last call as a trusted caller. The UI must have
  /// had the user confirm they compared the safety number.
  Future<void> trustPeer({
    required String name,
    required bool allowVideo,
  }) async {
    final peer = call.peer;
    if (peer == null || isGuest || peer.id == _admittedGuestId) return;
    await trustedCallers.trust(
      TrustedCaller(
        identity: peer,
        name: name.trim().isEmpty ? 'Trusted caller' : name.trim(),
        allowVideo: allowVideo,
      ),
    );
  }

  /// Whether the last call's peer can be offered as a trusted caller.
  bool get canTrustPeer {
    final peer = call.peer;
    return peer != null &&
        !isGuest &&
        peer.id != _admittedGuestId &&
        trustedCallers.find(peer) == null;
  }

  void _sendGuestMessage(
    PublicIdentity to,
    String type,
    Map<String, Object?> body,
  ) => _relay?.send(to.id, _codec!.seal(recipient: to, type: type, body: body));

  /// The professional's personal guest link (not in guest mode).
  String? get personalGuestLink {
    final link = _links?.personal;
    return link == null ? null : _guestLinkUrl(link);
  }

  /// Active one-time links with their URLs.
  List<({GuestLinkRecord record, String url})> get oneTimeGuestLinks => [
    for (final link in _links?.activeOneTime ?? const <GuestLinkRecord>[])
      (record: link, url: _guestLinkUrl(link)),
  ];

  String _guestLinkUrl(GuestLinkRecord link) => GuestLink.url(
    linkBase,
    GuestLink.sign(
      _sodium!,
      _identity!,
      linkId: link.id,
      secret: link.secret,
      hostName: _hostName.isEmpty ? 'Sotto user' : _hostName,
      expiresAt: link.expiresAt,
    ),
  );

  void _publishGuestLink() {
    if (personalGuestLink case final link?) publishForTests('guest-link', link);
    final oneTime = oneTimeGuestLinks;
    if (oneTime.isNotEmpty) publishForTests('one-time-link', oneTime.last.url);
  }

  Future<void> rotatePersonalGuestLink() async {
    await _links?.rotatePersonal();
    _publishGuestLink();
    notifyListeners();
  }

  Future<void> createOneTimeGuestLink() async {
    await _links?.createOneTime();
    _publishGuestLink();
    notifyListeners();
  }

  Future<void> revokeGuestLink(String id) async {
    await _links?.revoke(id);
    notifyListeners();
  }

  Future<void> setHostName(String name) async {
    _hostName = name.trim();
    _publishGuestLink();
    notifyListeners();
    try {
      await _settings.write(_hostNameSetting, _hostName);
    } catch (_) {
      // Not persisted; still applies until the app restarts.
    }
  }

  /// Admits a waiting guest (only when not already in a call).
  Future<void> admitGuest(String knockId) async {
    if (call.active) return;
    await _host?.admit(knockId);
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
    if (opened.type.startsWith('guest.')) {
      _host?.handle(opened);
      _visit?.handle(opened);
      return;
    }
    unawaited(manager.handle(opened));
  }

  void _onCallChanged() {
    if (call.phase == CallPhase.connecting && autoAnswered) {
      publishForTests('auto-answered', 'true');
      // Audible cue that a call was picked up automatically (where the
      // platform supports system sounds).
      SystemSound.play(SystemSoundType.alert);
    }
    if (call.phase == CallPhase.calling || call.phase == CallPhase.incoming) {
      publishForTests('auto-answered', 'false');
    }
    if (call.phase == CallPhase.calling || call.phase == CallPhase.incoming) {
      _micEnabled = true;
      _cameraEnabled = true;
      _route = null;
    }
    if (call.phase == CallPhase.connected) {
      publishForTests('sending-video', '$sendingVideo');
    }
    if (call.phase == CallPhase.connected && _route == null) {
      unawaited(_detectRoute());
    }
    publishForTests('call-phase', call.phase.name);
    notifyListeners();
  }

  /// Reads the selected ICE candidate pair after connecting, retrying for
  /// about 15 s: stats can lag well behind the "connected" event on a busy
  /// device.
  Future<void> _detectRoute() async {
    for (final delay in const [300, 700, 1000, 1000, 2000, 2000, 4000, 4000]) {
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
    _host?.dispose();
    trustedCallers.dispose();
    _visit?.dispose();
    unawaited(_relay?.stop());
    _identity?.dispose();
    if (_ready) {
      localRenderer.dispose();
      remoteRenderer.dispose();
    }
    super.dispose();
  }
}
