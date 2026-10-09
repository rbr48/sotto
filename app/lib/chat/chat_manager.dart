import 'dart:async';

import 'chat_frames.dart';
import 'chat_rtc.dart';
import 'chat_session.dart';
import 'chat_signalling.dart';
import 'chat_store.dart';

/// Something that happened in chats, for the screens to show.
sealed class ChatManagerEvent {
  const ChatManagerEvent();
}

/// Something happened in the chat with [contact].
final class ChatUpdate extends ChatManagerEvent {
  const ChatUpdate(this.contact, this.event);
  final String contact;
  final ChatSessionEvent event;
}

/// Opening the chat with [contact] failed (see [ChatSignalling] for the
/// reasons). Messages waiting for it are marked not sent.
final class ChatOpenFailure extends ChatManagerEvent {
  const ChatOpenFailure(this.contact, this.reason);
  final String contact;
  final String reason;
}

/// Runs the chats of this device: sets them up through [ChatSignalling],
/// connects them with [ChatRtc], and runs each one as a [ChatSession].
///
/// Every envelope goes out through [send] and comes in through [handle]. The
/// connection is made by [createRtc], so tests can run the whole flow without
/// a network.
class ChatManager {
  ChatManager({
    required this.myId,
    required this.store,
    required this.isContact,
    required this.send,
    required this.iceServers,
    required this.hideIp,
    required this.createRtc,
    required this.clock,
    String Function()? newId,
    this.connectTimeout = const Duration(seconds: 30),
  }) : _newId = newId ?? ChatFrames.newId,
       _signalling = ChatSignalling(
         myId: myId,
         isContact: isContact,
         newId: newId,
       );

  final String myId;
  final ChatStore store;

  /// Whether a Sotto ID is a contact. Only contacts can open a chat.
  final bool Function(String contactId) isContact;

  /// Seals and sends an envelope of [type] to the contact [to].
  final void Function(
    String to,
    String type,
    Map<String, Object?> body,
    String? callId,
  )
  send;

  /// STUN and TURN servers for a connection.
  final Future<List<Map<String, dynamic>>> Function() iceServers;

  /// "Hide my IP address": connections use relays only.
  final bool Function() hideIp;

  final ChatRtcFactory createRtc;
  final DateTime Function() clock;

  /// How long a connection may take to open before the chat fails.
  final Duration connectTimeout;

  final String Function() _newId;
  final ChatSignalling _signalling;
  final _events = StreamController<ChatManagerEvent>.broadcast();

  /// Chats in progress or open, by session id.
  final _live = <String, _Live>{};

  /// Messages waiting for a chat with a contact that is being opened.
  final _waiting = <String, List<ChatMessage>>{};

  Timer? _ticker;
  String? _viewing;
  bool _disposed = false;

  Stream<ChatManagerEvent> get events => _events.stream;

  /// Starts the periodic check for idle and unanswered chats. Started on the
  /// first chat activity, so a device that never chats runs no timer.
  void _ensureTicker() {
    if (_disposed) return;
    _ticker ??= Timer.periodic(
      const Duration(seconds: 30),
      (_) => unawaited(tick()),
    );
  }

  /// The chat with [contact] is open on screen (or none is). An open chat
  /// does not time out.
  void viewing(String? contact) => _viewing = contact;

  /// Whether the chat with [contact] is the one open on screen.
  bool isViewing(String contact) => _viewing == contact;

  /// Whether a chat with [contact] is open, or being opened.
  bool isActive(String contact) =>
      _activeFor(contact) != null || _signalling.isOpening(contact);

  /// Sends a text message to [contact], opening the chat first if needed.
  /// The message is stored at once; it is marked not sent if it can't go.
  Future<ChatMessage> sendText(String contact, String text) async {
    if (!isContact(contact)) {
      throw ArgumentError.value(contact, 'contact', 'is not a contact');
    }
    final cleaned = ChatFrames.cleanText(text);
    if (cleaned.isEmpty || cleaned.runes.length > maxTextChars) {
      throw ArgumentError.value(
        text,
        'text',
        'must be 1 to $maxTextChars characters',
      );
    }
    _ensureTicker();
    final live = _activeFor(contact);
    final session = live?.session;
    if (session != null && !session.isEnded) return session.sendText(cleaned);

    final message = ChatMessage(
      id: _newId(),
      contactId: contact,
      outgoing: true,
      ts: clock().millisecondsSinceEpoch,
      text: cleaned,
      state: ChatState.sending,
    );
    // Queued before the write, so a chat that ends during the write still
    // marks the message not sent (store writes run in the order asked for).
    if (live != null) {
      live.resend.add(message);
    } else {
      (_waiting[contact] ??= []).add(message);
      if (!_signalling.isOpening(contact)) {
        _perform(_signalling.open(contact, clock()));
      }
    }
    await store.add(message);
    return message;
  }

  /// Sends again a message that was not sent. It is the same message (same
  /// id), so the history gains no copy.
  Future<void> retry(String contact, String messageId) async {
    if (!isContact(contact)) {
      throw ArgumentError.value(contact, 'contact', 'is not a contact');
    }
    final message = await store.find(contact, messageId);
    if (message == null ||
        !message.outgoing ||
        message.state != ChatState.notSent) {
      return;
    }
    _ensureTicker();
    final again = message.withState(ChatState.sending);
    final live = _activeFor(contact);
    final session = live?.session;
    if (session != null && !session.isEnded) {
      await store.setState(contact, messageId, ChatState.sending);
      session.resend(again);
    } else if (live != null) {
      await store.setState(contact, messageId, ChatState.sending);
      live.resend.add(again);
    } else {
      await store.setState(contact, messageId, ChatState.sending);
      (_waiting[contact] ??= []).add(again);
      if (!_signalling.isOpening(contact)) {
        _perform(_signalling.open(contact, clock()));
      }
    }
  }

  /// Ends the chat with [contact] from this side.
  Future<void> close(String contact) async {
    final live = _activeFor(contact);
    if (live == null) return;
    _perform(_signalling.close(live.sessionId));
    if (live.session case final session?) {
      await session.close();
    } else {
      await _end(live, 'closed');
    }
  }

  /// Handles one chat envelope (`chat.*`) from [from], whose sender the relay
  /// and the envelope have verified.
  void handle({
    required String from,
    required String type,
    required Map<String, dynamic> body,
    required String? callId,
  }) {
    if (_disposed) return;
    _ensureTicker();
    _perform(
      _signalling.handle(
        from: from,
        type: type,
        body: body,
        callId: callId,
        now: clock(),
      ),
    );
  }

  /// Times out chats that nobody answered, and closes idle sessions.
  Future<void> tick() async {
    if (_disposed) return;
    _perform(_signalling.tick(clock()));
    _settleWaiting();
    for (final live in _live.values.toList()) {
      await live.session?.tick(viewing: _viewing == live.contact);
    }
  }

  /// Ends every chat and closes the event stream.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _ticker?.cancel();
    for (final live in _live.values.toList()) {
      await _end(live, 'closed');
    }
    await _events.close();
  }

  _Live? _activeFor(String contact) {
    for (final live in _live.values) {
      if (live.contact == contact && !live.ended) return live;
    }
    return null;
  }

  void _emit(ChatManagerEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

  /// Carries out what [ChatSignalling] decided.
  void _perform(List<ChatAction> actions) {
    for (final action in actions) {
      switch (action) {
        case SendEnvelope(:final to, :final type, :final body, :final callId):
          send(to, type, body, callId);
        case SessionReady():
          _startSession(action);
        case OpenFailed(:final contact, :final reason):
          unawaited(_openFailed(contact, reason));
        case DropSession(:final sessionId):
          final live = _live[sessionId];
          if (live != null) unawaited(_end(live, 'dropped'));
        case DeliverSignal():
          final live = _live[action.sessionId];
          if (live != null) {
            live.chain = live.chain.then((_) => _apply(live, action));
          }
      }
    }
    _settleWaiting();
  }

  /// Messages waiting for a chat are only sent while that chat is being
  /// opened or is live. Any other messages can never go, so they are marked
  /// not sent (for example, when another device of the contact won the answer).
  void _settleWaiting() {
    for (final contact in _waiting.keys.toList()) {
      if (_signalling.isOpening(contact) || _activeFor(contact) != null) {
        continue;
      }
      unawaited(_openFailed(contact, 'dropped'));
    }
  }

  void _startSession(SessionReady ready) {
    _ensureTicker();
    if (_live.containsKey(ready.sessionId)) return;
    final live = _Live(
      contact: ready.contact,
      sessionId: ready.sessionId,
      offerer: ready.offerer,
      tag: ready.tag,
    );
    // Messages written while the chat was being opened go out with it.
    live.resend.addAll(_waiting.remove(ready.contact) ?? const []);
    _live[ready.sessionId] = live;
    live.chain = _setup(live);
  }

  Future<void> _setup(_Live live) async {
    try {
      final servers = await iceServers();
      if (live.ended) return;
      final relayOnly = hideIp();
      // "Hide my IP address" never falls back to a direct connection, so
      // without a relay server the chat fails at once, with a reason.
      if (relayOnly && !_hasTurn(servers)) {
        await _end(live, 'no-relay');
        return;
      }
      final rtc = await createRtc(iceServers: servers, relayOnly: relayOnly);
      live.rtc = rtc;
      if (live.ended) {
        await rtc.close();
        return;
      }
      final session = ChatSession(
        contactId: live.contact,
        transport: rtc.transport,
        store: store,
        clock: clock,
        newId: _newId,
        isContact: () => isContact(live.contact),
      );
      live.session = session;
      live.sessionSub = session.events.listen(
        (event) => _onSessionEvent(live, event),
      );
      live.candidatesSub = rtc.localCandidates.listen(
        (candidate) => _sendCandidate(live, candidate),
      );
      unawaited(rtc.opened.then((_) => _onOpened(live)));
      unawaited(rtc.lost.then((_) => _end(live, 'lost')));
      live.timer = Timer(connectTimeout, () => _end(live, 'timeout'));
      if (live.offerer) {
        final offer = await rtc.createOffer();
        if (live.ended) return;
        send(live.contact, 'chat.offer', {
          'tag': live.tag,
          'sdp': offer,
        }, live.sessionId);
        _signalSent(live);
      }
    } catch (_) {
      // The error can name addresses, so it is not logged.
      await _end(live, 'failed');
    }
  }

  /// Whether [servers] include a TURN server (`turn:` or `turns:`).
  static bool _hasTurn(List<Map<String, dynamic>> servers) =>
      servers.any((server) {
        final urls = server['urls'];
        final list = urls is List ? urls : [urls];
        return list.any(
          (url) =>
              url is String &&
              (url.startsWith('turn:') || url.startsWith('turns:')),
        );
      });

  void _onOpened(_Live live) {
    final session = live.session;
    if (live.ended || session == null) return;
    live.timer?.cancel();
    final resend = List<ChatMessage>.of(live.resend);
    live.resend.clear();
    unawaited(session.start(resend: resend));
  }

  void _onSessionEvent(_Live live, ChatSessionEvent event) {
    _emit(ChatUpdate(live.contact, event));
    if (event is SessionEnded && !live.ended) {
      unawaited(_end(live, event.reason));
    }
  }

  void _sendCandidate(_Live live, Map<String, Object?> candidate) {
    if (live.ended) return;
    if (!live.signalSent) {
      live.heldCandidates.add(candidate);
      return;
    }
    send(live.contact, 'chat.ice', {
      'tag': live.tag,
      ...candidate,
    }, live.sessionId);
  }

  void _signalSent(_Live live) {
    live.signalSent = true;
    final held = List<Map<String, Object?>>.of(live.heldCandidates);
    live.heldCandidates.clear();
    for (final candidate in held) {
      _sendCandidate(live, candidate);
    }
  }

  /// Applies one connection message, after the connection exists.
  Future<void> _apply(_Live live, DeliverSignal signal) async {
    final rtc = live.rtc;
    if (live.ended || rtc == null) return;
    final body = signal.body;
    switch (signal.type) {
      case 'chat.offer':
        final sdp = body['sdp'];
        if (live.offerer || sdp is! String) return;
        try {
          final answer = await rtc.acceptOffer(sdp);
          if (live.ended) return;
          send(live.contact, 'chat.answer', {
            'tag': live.tag,
            'sdp': answer,
          }, live.sessionId);
          _signalSent(live);
        } catch (_) {
          await _end(live, 'failed');
        }
      case 'chat.answer':
        final sdp = body['sdp'];
        if (!live.offerer || sdp is! String) return;
        try {
          await rtc.acceptAnswer(sdp);
        } catch (_) {
          await _end(live, 'failed');
        }
      case 'chat.ice':
        final candidate = body['candidate'];
        if (candidate is! String) return;
        try {
          await rtc.addCandidate({
            'candidate': candidate,
            'sdpMid': body['sdpMid'],
            'sdpMLineIndex': body['sdpMLineIndex'],
          });
        } catch (_) {
          // One bad candidate is skipped; others may still connect.
        }
    }
  }

  /// The messages waiting for [contact] are not sent. Each is stored as such
  /// before the event goes out: a screen that reloads on the event must see
  /// the new state, and nothing reloads it afterwards.
  Future<void> _openFailed(String contact, String reason) async {
    // Taken at once, so the messages are settled before any other step runs.
    final waiting = _waiting.remove(contact) ?? const <ChatMessage>[];
    for (final message in waiting) {
      await store.setState(
        contact,
        message.id,
        ChatState.notSent,
        reason: reason,
      );
      _emit(ChatUpdate(contact, MessageNotSent(message.id)));
    }
    _emit(ChatOpenFailure(contact, reason));
  }

  /// Ends one chat: messages never sent are marked not sent, the session is
  /// closed, and the connection is released.
  Future<void> _end(_Live live, String reason) async {
    if (live.ended) return;
    live.ended = true;
    live.timer?.cancel();
    _live.remove(live.sessionId);
    for (final message in live.resend) {
      await store.setState(
        live.contact,
        message.id,
        ChatState.notSent,
        reason: reason,
      );
      _emit(ChatUpdate(live.contact, MessageNotSent(message.id)));
    }
    live.resend.clear();
    await live.session?.close();
    await live.sessionSub?.cancel();
    await live.candidatesSub?.cancel();
    await live.rtc?.close();
  }
}

/// One chat session in progress or open.
class _Live {
  _Live({
    required this.contact,
    required this.sessionId,
    required this.offerer,
    required this.tag,
  });

  final String contact;
  final String sessionId;
  final bool offerer;
  final String tag;

  ChatRtc? rtc;
  ChatSession? session;
  StreamSubscription<ChatSessionEvent>? sessionSub;
  StreamSubscription<Map<String, Object?>>? candidatesSub;
  Timer? timer;

  /// Messages to send as soon as the session starts.
  final resend = <ChatMessage>[];

  /// Candidates found before the offer or answer was sent.
  final heldCandidates = <Map<String, Object?>>[];
  bool signalSent = false;
  bool ended = false;

  /// Connection messages are applied one at a time, in order.
  Future<void> chain = Future<void>.value();
}
