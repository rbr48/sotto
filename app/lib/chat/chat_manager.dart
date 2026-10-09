import 'dart:async';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../diagnostics/event_log.dart';
import 'chat_frames.dart';
import 'chat_rtc.dart';
import 'chat_session.dart';
import 'chat_signalling.dart';
import 'chat_store.dart';
import 'image_metadata.dart';

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
    this.readReceiptsEnabled = _readReceiptsAlwaysOn,
    void Function(String event)? log,
  }) : _newId = newId ?? ChatFrames.newId,
       _log = log ?? EventLog.instance.add,
       _signalling = ChatSignalling(
         myId: myId,
         isContact: isContact,
         newId: newId,
       );

  final String myId;
  final ChatStore store;

  /// Writes a line to the diagnostic log. Lines name states and reasons only:
  /// never a contact, an id or any text (see [EventLog]).
  final void Function(String event) _log;

  /// A text message sent through the relay, sealed like every envelope, when
  /// no direct chat is ready. The relay keeps it in memory for at most a
  /// minute; the sender sends it again on the next check while it is queued.
  static const relayText = 'chat.text';

  /// The receiver's answer to [relayText]: the message is stored.
  static const relayTextAck = 'chat.text.ack';

  /// At most this many queued messages go through the relay per check.
  static const maxRelayPerFlush = 20;

  /// How long a text that has not been acknowledged keeps being sent through
  /// the relay on each check. The relay can hand a text to a connection that
  /// has just died (it notices only later), so one copy is not enough.
  static const relayRetryWindow = Duration(minutes: 15);

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

  /// Whether this device sends read receipts ("Send read receipts" in
  /// Settings). Read at each use, so a change applies at once. When it is
  /// off, no receipt leaves this device, including the ones sent when a chat
  /// opens.
  final bool Function() readReceiptsEnabled;

  static bool _readReceiptsAlwaysOn() => true;

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

  /// Starts the periodic work and clears what an earlier run left behind.
  /// Call once after the app opens the vault.
  Future<void> start() async {
    if (_disposed) return;
    _ensureTicker();
    await recoverInterrupted();
    await store.sweepExpired(clock: clock);
    await store.encryptLegacyFiles();
    await store.files?.clearOpenCopies();
  }

  /// Messages still "sending" from an earlier run of the app can never go:
  /// their chat died with that run. They are marked not sent (reason
  /// 'interrupted'), so Retry and Queue apply, and file transfers in progress
  /// or unanswered are marked failed. Incoming file offers are expired, since
  /// the sender's chat is gone.
  Future<void> recoverInterrupted() async {
    if (_disposed) return;
    for (final contact in await store.contactIds()) {
      if (_signalling.isOpening(contact) || _activeFor(contact) != null) {
        continue;
      }
      for (final message in await store.messages(contact)) {
        final fileStatus = message.fileStatus;
        final pendingFile =
            fileStatus == 'offered' || fileStatus == 'transferring';
        if (pendingFile) {
          final next = !message.outgoing && fileStatus == 'offered'
              ? 'expired'
              : 'failed';
          await store.updateMessage(message.copyWith(fileStatus: next));
        }
        if (message.outgoing && message.state == ChatState.sending) {
          await store.setState(
            contact,
            message.id,
            ChatState.notSent,
            reason: 'interrupted',
          );
        }
      }
    }
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
    _sendThroughRelay(message);
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
        (message.state != ChatState.notSent &&
            message.state != ChatState.queued)) {
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
      _sendThroughRelay(again);
    } else {
      await store.setState(contact, messageId, ChatState.sending);
      (_waiting[contact] ??= []).add(again);
      if (!_signalling.isOpening(contact)) {
        _perform(_signalling.open(contact, clock()));
      }
      _sendThroughRelay(again);
    }
  }

  /// Moves an unsent message into the outbox [ChatState.queued] to send automatically when online.
  Future<void> queue(String contact, String messageId) async {
    if (!isContact(contact)) {
      throw ArgumentError.value(contact, 'contact', 'is not a contact');
    }
    final message = await store.find(contact, messageId);
    if (message == null ||
        !message.outgoing ||
        message.state != ChatState.notSent) {
      return;
    }
    await store.setState(contact, messageId, ChatState.queued);
  }

  /// Removes the disappearing messages that have expired, now.
  Future<int> sweepExpired() async {
    if (_disposed) return 0;
    return store.sweepExpired(clock: clock);
  }

  /// Deletes a message from this device. A message still waiting to go is
  /// taken off the queue first, so it is not sent after it was deleted.
  Future<void> deleteMessage(String contact, String id) async {
    _waiting[contact]?.removeWhere((m) => m.id == id);
    final live = _activeFor(contact);
    live?.resend.removeWhere((m) => m.id == id);
    live?.session?.forget(id);
    await store.deleteMessage(contact, id);
  }

  /// Deletes the whole chat with [contact] from this device, and stops
  /// anything still waiting to go to it.
  Future<void> deleteChat(String contact) async {
    _waiting.remove(contact);
    final live = _activeFor(contact);
    if (live != null) {
      live.resend.clear();
      live.session?.forgetAll();
    }
    await store.deleteChat(contact);
  }

  /// Cancels a queued message, setting it back to [ChatState.notSent].
  Future<void> unqueue(String contact, String messageId) async {
    final message = await store.find(contact, messageId);
    if (message == null ||
        !message.outgoing ||
        message.state != ChatState.queued) {
      return;
    }
    await store.setState(
      contact,
      messageId,
      ChatState.notSent,
      reason: 'cancelled',
    );
  }

  /// Attempts to send the queued messages for [contact]. A failed attempt
  /// keeps them queued: they go out when a chat with the contact opens, and
  /// the next attempt is made on the next check (see [tick]).
  Future<void> flushOutbox(String contact) async {
    if (!isContact(contact) || _disposed) return;
    final queued = (await store.messages(contact))
        .where((m) => m.outgoing && m.state == ChatState.queued)
        .toList();
    if (queued.isEmpty) return;
    final live = _activeFor(contact);
    final session = live?.session;
    if (session != null && !session.isEnded && session.isReady) {
      for (final msg in queued) {
        await store.setState(contact, msg.id, ChatState.sending);
        if (msg.isAttachment) {
          unawaited(session.offerStoredFile(msg));
        } else {
          session.resend(msg.withState(ChatState.sending));
        }
      }
      return;
    }
    // No direct chat is ready: the texts also go through the relay, so they
    // reach a device whose app is in the background.
    for (final msg in queued.take(maxRelayPerFlush)) {
      _sendThroughRelay(msg);
    }
    // A chat being opened sends the queue itself once its channel is open.
    if (live != null || _signalling.isOpening(contact)) return;
    _perform(_signalling.open(contact, clock()));
  }

  /// Sends a text message through the relay. Files need the direct chat.
  void _sendThroughRelay(ChatMessage message) {
    if (_disposed || message.isAttachment || !message.outgoing) return;
    send(message.contactId, relayText, {
      'id': message.id,
      'ts': message.ts,
      'text': message.text,
    }, null);
    _log('chat: text sent through the relay');
  }

  /// A text that came through the relay: stored once, always acknowledged.
  Future<void> _onRelayText(String from, Map<String, dynamic> body) async {
    if (!isContact(from)) {
      _log('chat: relay text from someone not in contacts dropped');
      return;
    }
    final id = body['id'];
    final ts = body['ts'];
    final raw = body['text'];
    if (!ChatFrames.isId(id) || ts is! int || raw is! String) {
      _log('chat: malformed relay text dropped');
      return;
    }
    final text = ChatFrames.cleanText(raw);
    if (text.isEmpty || text.runes.length > maxTextChars) {
      _log('chat: relay text of a bad length dropped');
      return;
    }
    final messageId = id as String;
    if (!await store.contains(from, messageId)) {
      final message = ChatMessage(
        id: messageId,
        contactId: from,
        outgoing: false,
        ts: ts,
        text: text,
        state: ChatState.received,
        read: false,
        arrivedAt: clock().millisecondsSinceEpoch,
      );
      await store.add(message);
      _emit(ChatUpdate(from, MessageReceived(message)));
      _log('chat: text received through the relay');
    }
    send(from, relayTextAck, {'id': messageId}, null);
  }

  /// The other device stored a text sent through the relay.
  Future<void> _onRelayAck(String from, Map<String, dynamic> body) async {
    final id = body['id'];
    if (!ChatFrames.isId(id)) return;
    final messageId = id as String;
    final message = await store.find(from, messageId);
    if (message == null || !message.outgoing) return;
    // Taken off every list, so a chat that fails later cannot mark it not sent.
    _waiting[from]?.removeWhere((m) => m.id == messageId);
    for (final live in _live.values) {
      if (live.contact == from) {
        live.resend.removeWhere((m) => m.id == messageId);
      }
    }
    if (message.state == ChatState.delivered ||
        message.state == ChatState.read) {
      return;
    }
    await store.setState(from, messageId, ChatState.delivered);
    _emit(ChatUpdate(from, MessageDelivered(messageId)));
    _log('chat: relay text acknowledged');
  }

  /// Marks a message not sent, unless it already got through (for example
  /// through the relay while the direct chat was still failing).
  Future<bool> _markNotSent(String contact, String id, String reason) async {
    // The message may still be on its way into the store; the store applies
    // writes in order, so only a state that is known to be final is kept.
    final current = await store.find(contact, id);
    if (current != null &&
        (current.state == ChatState.delivered ||
            current.state == ChatState.read)) {
      return false;
    }
    await store.setState(contact, id, ChatState.notSent, reason: reason);
    return true;
  }

  /// Attempts to flush queued messages across all contacts.
  Future<void> flushAllOutbox() async {
    if (_disposed) return;
    final ids = await store.contactIds();
    for (final contact in ids) {
      await flushOutbox(contact);
    }
  }

  /// Offers a file or photo to [contact]. A [voice] note is offered as one.
  Future<ChatMessage> offerFile({
    required String contact,
    required String name,
    required Uint8List bytes,
    required String mime,
    bool voice = false,
  }) async {
    if (!isContact(contact)) {
      throw ArgumentError.value(contact, 'contact', 'is not a contact');
    }
    _ensureTicker();
    var live = _activeFor(contact);
    if (live == null && !_signalling.isOpening(contact)) {
      _perform(_signalling.open(contact, clock()));
    }
    if (live?.session != null &&
        !live!.session!.isEnded &&
        live.session!.isReady) {
      return live.session!.offerFile(
        name: name,
        bytes: bytes,
        mime: mime,
        voice: voice,
      );
    }
    // Wait up to 5 seconds for session to become ready
    final deadline = clock().add(const Duration(seconds: 5));
    while (clock().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      live = _activeFor(contact);
      if (live?.session != null &&
          !live!.session!.isEnded &&
          live.session!.isReady) {
        return live.session!.offerFile(
          name: name,
          bytes: bytes,
          mime: mime,
          voice: voice,
        );
      }
    }
    // Peer is offline or session not yet connected: save file locally and queue it
    final cleanedName = ChatFrames.cleanFileName(name);
    if (ChatFrames.isBlockedFileType(name) ||
        ChatFrames.isBlockedFileType(cleanedName)) {
      throw ArgumentError('Blocked file type: $name');
    }
    Uint8List clean;
    try {
      clean = ImageMetadata.clean(bytes, mime);
    } catch (_) {
      clean = bytes;
    }
    if (clean.isEmpty) throw ArgumentError('File is empty');
    if (clean.length > maxFileSizeNative) {
      throw ArgumentError('File exceeds max size limit');
    }
    final hash = sha256.convert(clean).toString();
    final id = _newId();
    final files = store.files;
    final kept = files == null ? null : await files.save(clean);
    final queuedMsg = ChatMessage(
      id: id,
      contactId: contact,
      outgoing: true,
      ts: clock().millisecondsSinceEpoch,
      text: cleanedName,
      state: ChatState.queued,
      fileId: id,
      fileName: cleanedName,
      fileSize: clean.length,
      fileMime: mime,
      fileSha256: hash,
      fileStatus: 'offered',
      filePath: kept?.name,
      fileKey: kept?.key,
      voiceNote: voice,
    );
    await store.add(queuedMsg);
    if (voice && kept == null) {
      await store.keepVoice(queuedMsg, clean);
    }
    return queuedMsg;
  }

  /// Accepts an offered file.
  Future<void> acceptFile(String contact, String fileId) async {
    final live = _activeFor(contact);
    final session = live?.session;
    if (session != null && !session.isEnded) {
      await session.acceptFile(fileId);
    }
  }

  /// Declines an offered file.
  Future<void> declineFile(String contact, String fileId) async {
    final live = _activeFor(contact);
    final session = live?.session;
    if (session != null && !session.isEnded) {
      await session.declineFile(fileId);
    } else {
      final msg = await store.find(contact, fileId);
      if (msg != null) {
        await store.updateMessage(msg.copyWith(fileStatus: 'declined'));
      }
    }
  }

  /// Cancels an active file transfer.
  Future<void> cancelFile(
    String contact,
    String fileId, {
    String? reason,
  }) async {
    final live = _activeFor(contact);
    final session = live?.session;
    if (session != null && !session.isEnded) {
      await session.cancelFile(fileId, reason: reason);
    } else {
      final msg = await store.find(contact, fileId);
      if (msg != null) {
        await store.updateMessage(msg.copyWith(fileStatus: 'cancelled'));
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
    if (type == relayText) {
      unawaited(_onRelayText(from, body));
      return;
    }
    if (type == relayTextAck) {
      unawaited(_onRelayAck(from, body));
      return;
    }
    if (type == 'chat.open') _log('chat: a contact is opening a chat');
    _perform(
      _signalling.handle(
        from: from,
        type: type,
        body: body,
        callId: callId,
        now: clock(),
      ),
    );
    unawaited(flushOutbox(from));
  }

  /// Sends a typing indicator to [contact] if a live session exists.
  void sendTyping(String contact, bool typing) {
    final live = _activeFor(contact);
    live?.session?.sendTyping(typing);
  }

  /// Sends read receipts for [ids] to [contact] if a live session exists.
  void sendReadReceipts(String contact, List<String> ids) {
    if (!readReceiptsEnabled()) return;
    final live = _activeFor(contact);
    live?.session?.sendReadReceipts(ids);
  }

  /// Times out chats that nobody answered, closes idle sessions, sends queued
  /// messages to contacts that are online, and sweeps expired messages.
  Future<void> tick() async {
    if (_disposed) return;
    _perform(_signalling.tick(clock()));
    _settleWaiting();
    for (final live in _live.values.toList()) {
      await live.session?.tick(viewing: _viewing == live.contact);
    }
    await flushAllOutbox();
    await _resendUnacknowledged();
    await store.sweepExpired(clock: clock);
  }

  /// Sends again, through the relay, recent texts that the other side has not
  /// acknowledged: still sending, or not sent for any reason but a cancel. A
  /// contact with a ready direct chat is skipped; that chat sends them.
  Future<void> _resendUnacknowledged() async {
    if (_disposed) return;
    final since = clock().subtract(relayRetryWindow).millisecondsSinceEpoch;
    var budget = maxRelayPerFlush;
    for (final contact in await store.contactIds()) {
      if (budget <= 0) return;
      if (!isContact(contact)) continue;
      final session = _activeFor(contact)?.session;
      if (session != null && !session.isEnded && session.isReady) continue;
      for (final m in await store.messages(contact)) {
        if (budget <= 0) return;
        if (!m.outgoing || m.isAttachment || m.ts < since) continue;
        final pending =
            m.state == ChatState.sending ||
            (m.state == ChatState.notSent && m.reason != 'cancelled');
        if (!pending) continue;
        _sendThroughRelay(m);
        budget--;
      }
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
          _log('chat: chat accepted, connecting');
          _startSession(action);
        case OpenFailed(:final contact, :final reason):
          _log('chat: opening failed ($reason)');
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
      // The error can name addresses, so only the step is logged.
      _log('chat: could not set up the connection');
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
    unawaited(_startSessionWithQueue(live, session));
  }

  /// Starts the session with the messages waiting for it, and with the
  /// queued messages for the contact (they are sent now that it is online).
  Future<void> _startSessionWithQueue(_Live live, ChatSession session) async {
    final waiting = List<ChatMessage>.of(live.resend);
    live.resend.clear();
    final queued = (await store.messages(live.contact))
        .where((m) => m.outgoing && m.state == ChatState.queued);
    // Nothing is awaited between this check and the start, so the chat cannot
    // end in between with these messages still unaccounted for.
    if (live.ended) {
      // The messages that were waiting for this chat are not sent. Queued
      // messages stay queued for the next attempt.
      for (final message in waiting) {
        await _markNotSent(live.contact, message.id, 'failed');
      }
      return;
    }
    _log('chat: direct chat connected');
    unawaited(session.start(resend: [...waiting, ...queued]));
    // Read receipts for what this device has read are sent (again) with each
    // chat, so the other side learns of reads that happened while no chat
    // was open. The other side ignores what it already knows.
    final read = (await store.messages(live.contact))
        .where((m) => !m.outgoing && m.read)
        .toList();
    final recent = read.length > 500 ? read.sublist(read.length - 500) : read;
    if (readReceiptsEnabled()) {
      session.sendReadReceipts([for (final m in recent) m.id]);
    }
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
      if (await _markNotSent(contact, message.id, reason)) {
        _emit(ChatUpdate(contact, MessageNotSent(message.id)));
      }
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
    _log('chat: chat ended ($reason)');
    for (final message in live.resend) {
      if (await _markNotSent(live.contact, message.id, reason)) {
        _emit(ChatUpdate(live.contact, MessageNotSent(message.id)));
      }
    }
    live.resend.clear();
    // A chat that never got a session still has to say why it failed (for
    // example, "Hide my IP" without a relay server). A chat the user closed
    // is not a failure.
    if (live.session == null && reason != 'closed') {
      _emit(ChatOpenFailure(live.contact, reason));
    }
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
