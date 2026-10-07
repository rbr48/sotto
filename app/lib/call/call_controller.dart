import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:sodium/sodium.dart';

import '../contacts/contact_book.dart';
import '../contacts/contact_link.dart';
import '../core/test_hooks.dart';
import '../crypto/encoding.dart';
import '../crypto/sotto_crypto.dart';
import '../guest/guest_host.dart';
import '../guest/guest_link.dart';
import '../guest/guest_visit.dart';
import '../history/call_history.dart';
import '../relay/relay_client.dart';
import '../sound/call_sounds.dart';
import 'call_code.dart';
import 'call_manager.dart';
import 'devices.dart';
import 'media_engine.dart';
import 'webrtc_media_engine.dart';

/// Everything the call screens need: the relay connection, the current
/// call, guest links and the waiting room.
///
/// Incoming relay messages are opened as end-to-end envelopes (the sender
/// must match the relay-authenticated address) and handed to [CallManager].
///
/// Three uses:
/// - the professional's app ([identity], [contacts], [history] and
///   [devices] given; settings in the vault),
/// - a guest's page ([guestLinkPayload] set; temporary identity),
/// - a quick call from a browser (`?call=` or `#c=` links; temporary
///   identity, nothing stored).
class CallController extends ChangeNotifier {
  CallController({
    required this.relayUrl,
    required this.linkBase,
    this.guestLinkPayload,
    Identity? identity,
    SecretStore? settings,
    this.contacts,
    this.history,
    this.devices,
    String Function()? hostName,
    SoundOutput? sounds,
  }) : _sounds = sounds, // ignore: prefer_initializing_formals
       _givenIdentity = identity,
       _settings = settings ?? MemorySecretStore(),
       _hostName = hostName ?? (() => '');

  /// Used only if the relay offers no STUN/TURN servers (e.g. a bare local
  /// test relay). The Sotto relay hands out its own STUN and TURN servers.
  static const fallbackIceServers = [
    {
      'urls': ['stun:stun.l.google.com:19302'],
    },
  ];

  static const hideIpSetting = 'sotto.settings.hide_ip';
  static const soundsSetting = 'sotto.settings.sounds';

  final Uri relayUrl;
  final Uri linkBase;
  final Identity? _givenIdentity;
  final SecretStore _settings;
  final String Function() _hostName;

  /// The professional's contacts (auto-answer, names); `null` for guests and
  /// quick calls.
  final ContactBook? contacts;

  /// Where finished calls are recorded; `null` keeps no history.
  final CallHistory? history;

  /// Chosen camera/microphone/speaker; `null` uses the system defaults.
  final DeviceSettings? devices;

  /// Set when the app was opened from a guest link (`#g=…`): this device is
  /// a guest for the duration of the page, with a temporary identity.
  final String? guestLinkPayload;
  bool get isGuest => guestLinkPayload != null;

  /// The professional's app (not a guest page or a browser quick call).
  bool get isProfessional => contacts != null;

  GuestVisit? _visit;

  /// The guest's visit (guest mode only).
  GuestVisit? get guestVisit => _visit;

  /// Set in guest mode if the link is invalid or expired.
  GuestLinkProblem? guestLinkProblem;

  GuestLinkStore? _links;
  GuestHost? _host;

  /// Peer and name of a call that admitted a guest from the waiting room
  /// (shown differently from a trusted contact's auto-answer).
  String? _admittedGuestId;
  String? _admittedGuestName;

  /// The professional's waiting room (professional's app only).
  GuestHost? get guestHost => _host;

  final RTCVideoRenderer localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer remoteRenderer = RTCVideoRenderer();

  Sodium? _sodium;

  /// libsodium, once started.
  Sodium? get sodium => _sodium;
  Identity? _identity;
  EnvelopeCodec? _codec;
  RelayClient? _relay;
  CallManager? _manager;
  CallRecorder? _recorder;
  final _subscriptions = <StreamSubscription<Object?>>[];

  bool _ready = false;
  bool get ready => _ready;

  /// Set if startup failed (e.g. libsodium could not load).
  String? startupError;

  String? _callLink;

  /// This device's Sotto ID.
  String? get ownId => _identity?.id;

  /// Plain call link (`?call=`): anyone with it can ring this device.
  String? get callLink => _callLink;

  RelayStatus get relayStatus => _relay?.status ?? RelayStatus.offline;

  CallState get call => _manager?.state ?? CallState.idle;

  bool _hideIp = false;

  final SoundOutput? _sounds;
  late final CallSounds? _callSounds = _sounds == null
      ? null
      : CallSounds(_sounds, enabled: () => _soundsOn);
  bool _soundsOn = true;

  /// Ringtone, ringback and chimes.
  bool get soundsOn => _soundsOn;
  final _knownKnocks = <String>{};
  final _newGuests = StreamController<WaitingGuest>.broadcast();
  final _incomingCalls = StreamController<CallState>.broadcast();
  String? _lastIncomingId;

  /// Guests who just started waiting (for desktop notifications).
  Stream<WaitingGuest> get newGuests => _newGuests.stream;

  /// Calls that just started ringing here (for desktop notifications).
  Stream<CallState> get incomingCalls => _incomingCalls.stream;

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

  CallQuality? _quality;

  /// Connection quality of the current call, from local statistics.
  CallQuality? get quality => _quality;
  Timer? _qualityTimer;

  DateTime? _connectedAt;

  /// When the current call connected (for the call timer).
  DateTime? get connectedAt => _connectedAt;

  bool _micEnabled = true;
  bool get micEnabled => _micEnabled;
  bool _cameraEnabled = true;
  bool get cameraEnabled => _cameraEnabled;

  /// Safety number with the current call's peer.
  String? get safetyNumber {
    final peer = call.peer;
    return peer == null ? null : safetyNumberWith(peer);
  }

  String? safetyNumberWith(PublicIdentity peer) {
    final sodium = _sodium;
    final identity = _identity;
    if (sodium == null || identity == null) return null;
    return SafetyNumber.compute(sodium, identity.publicIdentity, peer);
  }

  /// The current call's peer as a contact, if they are one.
  Contact? get peerContact {
    final peer = call.peer;
    return peer == null ? null : contacts?.find(peer);
  }

  /// A name for the current call's peer.
  String get peerName => _describe(call.peer).name;

  ({String name, bool guest}) _describe(PublicIdentity? peer) {
    if (peer == null) return (name: 'Unknown caller', guest: false);
    if (peer.id == _admittedGuestId) {
      return (name: '${_admittedGuestName ?? 'Guest'} (guest)', guest: true);
    }
    if (contacts?.find(peer) case final contact?) {
      return (name: contact.label, guest: false);
    }
    if (_visit case final visit? when visit.link.host == peer) {
      return (name: visit.link.hostName, guest: false);
    }
    return (name: 'Unknown caller', guest: false);
  }

  Future<void> start() async {
    try {
      final sodium = _sodium = await SottoCrypto.init();
      final identity = _identity = _givenIdentity ?? Identity.generate(sodium);
      _hideIp = await _readSetting(hideIpSetting) == '1';
      _soundsOn = await _readSetting(soundsSetting) != '0';
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
          devices: () => devices?.effective ?? const DeviceSelection(),
        ),
        newCallId: () => b64Encode(sodium.randombytes.buf(16)),
        autoAnswer: _decideAutoAnswer,
      );
      manager.addListener(_onCallChanged);
      if (history case final history?) {
        _recorder = CallRecorder(history: history, describePeer: _describe);
      }
      devices?.onDeviceGone = _onDeviceGone;

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
      } else if (isProfessional) {
        final links = _links = GuestLinkStore(sodium, _settings);
        try {
          await links.load();
          await links.ensurePersonal();
        } catch (_) {
          // Storage unavailable: links work until the app restarts.
        }
        _host = GuestHost(
          links: links,
          send: _sendGuestMessage,
          onAdmit: (guest) async {
            manager.dismiss();
            _admittedGuestId = guest.guest.id;
            _admittedGuestName = guest.name;
            await manager.call(
              guest.guest,
              video: guest.video,
              inviteExtras: {'knock': guest.knockId},
            );
          },
        )..addListener(_onHostChanged);
        publishGuestLinks();
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

  Future<void> setSoundsOn(bool value) async {
    _soundsOn = value;
    if (!value) _callSounds?.onCallState(CallState.idle, autoAnswered: false);
    notifyListeners();
    try {
      await _settings.write(soundsSetting, value ? '1' : '0');
    } catch (_) {
      // Not persisted; still applies until the app restarts.
    }
  }

  /// Chimes when a new guest starts waiting.
  void _onHostChanged() {
    final waiting = {for (final guest in _host!.waiting) guest.knockId};
    if (waiting.difference(_knownKnocks).isNotEmpty) _callSounds?.onKnock();
    for (final guest in _host!.waiting) {
      if (!_knownKnocks.contains(guest.knockId)) _newGuests.add(guest);
    }
    _knownKnocks
      ..clear()
      ..addAll(waiting);
    notifyListeners();
  }

  Future<void> setHideIp(bool value) async {
    _hideIp = value;
    publishForTests('hide-ip', '$value');
    notifyListeners();
    try {
      await _settings.write(hideIpSetting, value ? '1' : '0');
    } catch (_) {
      // Not persisted; still applies until the app restarts.
    }
  }

  /// Auto-answer: a guest's page answers the call that admits it; the
  /// professional's app answers verified contacts chosen for auto-answer,
  /// if switched on.
  AutoAnswer? _decideAutoAnswer(OpenedMessage invite) {
    if (_visit?.isAdmission(invite) == true) {
      return const AutoAnswer(delay: Duration.zero, video: true);
    }
    return contacts?.decide(
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

  /// Whether the last call's peer can be added to contacts (not a guest,
  /// not already a contact).
  bool get canAddPeerToContacts {
    final peer = call.peer;
    return peer != null &&
        isProfessional &&
        peer.id != _admittedGuestId &&
        contacts?.find(peer) == null;
  }

  /// Adds the current/last call's peer to contacts. [verified] means the
  /// user confirmed they compared the safety number.
  Future<void> addPeerToContacts({
    required String name,
    String organisation = '',
    required bool verified,
  }) async {
    final peer = call.peer;
    if (peer == null || !isProfessional || peer.id == _admittedGuestId) {
      return;
    }
    await contacts!.add(
      peer,
      name: name.trim().isEmpty ? 'Contact' : name,
      organisation: organisation,
      verified: verified,
    );
  }

  /// History entry of the call that just ended (to add a note).
  String? get lastHistoryId => _recorder?.lastRecordId;

  /// This person's contact link (`#c=`), with the name and organisation
  /// they chose.
  String contactLink({required String name, String organisation = ''}) =>
      ContactLink.create(
        _sodium!,
        _identity!,
        base: linkBase,
        name: name.isEmpty ? 'Sotto user' : name,
        organisation: organisation,
      );

  void _sendGuestMessage(
    PublicIdentity to,
    String type,
    Map<String, Object?> body,
  ) => _relay?.send(to.id, _codec!.seal(recipient: to, type: type, body: body));

  /// The professional's personal guest link.
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
      hostName: _hostName().isEmpty ? 'Sotto user' : _hostName(),
      expiresAt: link.expiresAt,
    ),
  );

  /// Republishes links for the tests (after the name changes).
  void publishGuestLinks() {
    if (personalGuestLink case final link?) publishForTests('guest-link', link);
    final oneTime = oneTimeGuestLinks;
    if (oneTime.isNotEmpty) publishForTests('one-time-link', oneTime.last.url);
    notifyListeners();
  }

  Future<void> rotatePersonalGuestLink() async {
    await _links?.rotatePersonal();
    publishGuestLinks();
  }

  Future<void> createOneTimeGuestLink() async {
    await _links?.createOneTime();
    publishGuestLinks();
  }

  Future<void> revokeGuestLink(String id) async {
    await _links?.revoke(id);
    notifyListeners();
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
    final call = this.call;
    if (call.phase == CallPhase.connecting && autoAnswered) {
      publishForTests('auto-answered', 'true');
    }
    if (call.phase == CallPhase.incoming && call.callId != _lastIncomingId) {
      _lastIncomingId = call.callId;
      _incomingCalls.add(call);
    }
    // Ringtone/ringback, and a chime when a call is answered automatically.
    _callSounds?.onCallState(call, autoAnswered: autoAnswered);
    if (call.phase == CallPhase.calling || call.phase == CallPhase.incoming) {
      publishForTests('auto-answered', 'false');
      _micEnabled = true;
      _cameraEnabled = true;
      _route = null;
      _quality = null;
      _connectedAt = null;
    }
    if (call.phase == CallPhase.connected) {
      _connectedAt ??= DateTime.now();
      publishForTests('sending-video', '$sendingVideo');
      _qualityTimer ??= Timer.periodic(
        const Duration(seconds: 2),
        (_) => _sampleQuality(),
      );
      if (_route == null) unawaited(_detectRoute());
    }
    if (!call.active) {
      _qualityTimer?.cancel();
      _qualityTimer = null;
    }
    unawaited(_recorder?.observe(call));
    publishForTests('call-phase', call.phase.name);
    notifyListeners();
  }

  Future<void> _sampleQuality() async {
    if (call.phase != CallPhase.connected) return;
    final sample = await _manager?.media?.qualitySample();
    final quality = sample?.quality;
    if (quality != null && quality != _quality) {
      _quality = quality;
      publishForTests('quality', quality.name);
      notifyListeners();
    }
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

  /// Uses another device now and for future calls.
  Future<void> useDevice(DeviceKind kind, String? deviceId) async {
    await devices?.choose(kind, deviceId);
    if (call.active) await _manager?.media?.useDevice(kind, deviceId);
  }

  /// A device in use was unplugged: switch the call to the default.
  void _onDeviceGone(DeviceKind kind) {
    if (call.active) unawaited(_manager?.media?.useDevice(kind, null));
  }

  /// Calls the person behind a call link, contact link or code.
  /// Throws [InvalidIdentityException] for an invalid link.
  Future<void> callSomeone(String linkOrCode, {bool video = true}) async {
    final peer = ContactLink.parse(_sodium!, linkOrCode).identity;
    await callPeer(peer, video: video);
  }

  /// Calls a known person (a contact, or someone from the history).
  Future<void> callPeer(PublicIdentity peer, {bool video = true}) async {
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
    _qualityTimer?.cancel();
    _callSounds?.dispose();
    unawaited(_newGuests.close());
    unawaited(_incomingCalls.close());
    _manager?.dispose();
    _host?.dispose();
    _visit?.dispose();
    unawaited(_relay?.stop());
    if (_givenIdentity == null) _identity?.dispose();
    if (_ready) {
      localRenderer.dispose();
      remoteRenderer.dispose();
    }
    super.dispose();
  }
}
