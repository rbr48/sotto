import 'dart:async';

import 'package:flutter/foundation.dart';

import '../diagnostics/event_log.dart';
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
    this.readReceiptsEnabled = _readReceiptsAlwaysOn,
    this.autoDownloadFiles = _autoDownloadOff,
    this.maxFileBytes = platformMaxFileBytes,
    this.offerReadyWait = const Duration(seconds: 5),
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

  /// Whether files from contacts download without asking ("Download files
  /// automatically" in Settings, off unless switched on). Read for each
  /// offer, so a change applies to the next one. Voice notes from contacts
  /// download either way. See [ChatSession.autoAcceptFiles] for the limits.
  final bool Function() autoDownloadFiles;

  static bool _autoDownloadOff() => false;

  /// The largest file this device sends or accepts (the browser's is
  /// smaller, see [platformMaxFileBytes]).
  final int maxFileBytes;

  /// How long [offerFile] waits for a chat being opened to become ready
  /// before it queues the file instead.
  final Duration offerReadyWait;

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
        // A queued file was never offered: it stays queued.
        final pendingFile =
            (fileStatus == 'offered' || fileStatus == 'transferring') &&
            !(message.outgoing && message.state == ChatState.queued);
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
  ///
  /// [replyToId] names the message in this chat that the new one answers: a
  /// copy of its text becomes the quote. [forwarded] marks a text forwarded
  /// from another chat. Neither goes through the relay (see [_relayable]).
  Future<ChatMessage> sendText(
    String contact,
    String text, {
    String? replyToId,
    bool forwarded = false,
  }) async {
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
    final replyTo = replyToId == null ? null : await _quote(contact, replyToId);
    _ensureTicker();
    final live = _activeFor(contact);
    final session = live?.session;
    if (session != null && !session.isEnded) {
      return session.sendText(cleaned, replyTo: replyTo, forwarded: forwarded);
    }

    final message = ChatMessage(
      id: _newId(),
      contactId: contact,
      outgoing: true,
      ts: clock().millisecondsSinceEpoch,
      text: cleaned,
      state: ChatState.sending,
      replyTo: replyTo,
      forwarded: forwarded,
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

  /// The quote for a reply to message [id] in the chat with [contact]. A
  /// message that is gone, or deleted for everyone, has no text to quote.
  Future<ChatReply> _quote(String contact, String id) async {
    final target = await store.find(contact, id);
    if (target == null || target.deletedForAll) {
      throw ArgumentError.value(
        id,
        'replyToId',
        'is not a message to reply to',
      );
    }
    return (id: target.id, text: ChatFrames.quoteText(target.text));
  }

  /// Sets your reaction on message [id] in the chat with [contact]; an empty
  /// [emoji] removes it. Applied at once. Sent when the contact can take it:
  /// now if a chat is ready, otherwise with the next chat that lists the
  /// feature (see [ChatSession.flushControls]). Returns false when the message
  /// is gone or was deleted for everyone. Throws [ArgumentError] for an emoji
  /// that is not a reaction (see [ChatFrames.cleanEmoji]).
  Future<bool> react(String contact, String id, String emoji) async {
    if (!isContact(contact)) {
      throw ArgumentError.value(contact, 'contact', 'is not a contact');
    }
    final String cleaned;
    try {
      cleaned = ChatFrames.cleanEmoji(emoji);
    } on ChatFrameException {
      throw ArgumentError.value(emoji, 'emoji', 'is not a reaction');
    }
    final message = await store.find(contact, id);
    if (message == null || message.deletedForAll) return false;
    final changed = await store.changeMessage(
      contact,
      id,
      (m) => m.deletedForAll ? null : m.withReaction('me', cleaned),
    );
    if (!changed) return false;
    await store.queueControl(
      contact,
      ReactFrame(id: id, emoji: cleaned, ts: clock().millisecondsSinceEpoch),
    );
    await _flushControls(contact);
    return true;
  }

  /// Replaces the text of your own message [id] in the chat with [contact],
  /// and marks it edited. Allowed for 15 minutes after the message was sent,
  /// for text messages only. Applied and sent as [react] does. Returns false
  /// when the edit is not allowed. Throws [ArgumentError] for text that is
  /// empty or too long.
  Future<bool> edit(String contact, String id, String text) async {
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
    final message = await store.find(contact, id);
    if (message == null ||
        !message.outgoing ||
        message.deletedForAll ||
        message.isAttachment) {
      return false;
    }
    final now = clock().millisecondsSinceEpoch;
    if (!ChatFrames.withinWindow(message.ts, now, editWindow)) return false;
    final changed = await store.changeMessage(
      contact,
      id,
      (m) => m.deletedForAll ? null : m.copyWith(text: cleaned, editedAt: now),
    );
    if (!changed) return false;
    _setQuotes(contact, id, ChatFrames.quoteText(cleaned));
    await store.queueControl(
      contact,
      EditFrame(id: id, ts: now, text: cleaned),
    );
    await _flushControls(contact);
    return true;
  }

  /// Deletes your own message [id] in the chat with [contact] for everyone,
  /// within an hour of its being sent. The text is removed here at once, and
  /// the record stays; so does the text of every quote of it, with none. The
  /// other device may keep its copy: this is best effort. Text messages only.
  /// Returns false when the delete is not allowed.
  Future<bool> deleteForEveryone(String contact, String id) async {
    if (!isContact(contact)) {
      throw ArgumentError.value(contact, 'contact', 'is not a contact');
    }
    final message = await store.find(contact, id);
    if (message == null ||
        !message.outgoing ||
        message.deletedForAll ||
        message.isAttachment) {
      return false;
    }
    final now = clock().millisecondsSinceEpoch;
    if (!ChatFrames.withinWindow(message.ts, now, deleteWindow)) return false;
    final changed = await store.changeMessage(
      contact,
      id,
      (m) => m.deletedForAll
          ? null
          : m.copyWith(text: '', deletedForAll: true, reactions: const {}),
    );
    if (!changed) return false;
    _setQuotes(contact, id, '');
    // The other side has not stored the text yet: it must not be sent again.
    final stored =
        message.state == ChatState.delivered || message.state == ChatState.read;
    if (!stored) _forget(contact, id);
    await store.queueControl(contact, DeleteFrame(id: id, ts: now));
    await _flushControls(contact);
    return true;
  }

  /// Gives the quote of message [id] to each reply to it that is still waiting
  /// to go in the chat with [contact]: empty once the message is deleted for
  /// everyone, its new text once it is edited. So a reply sent later does not
  /// carry the text it had before. The store is already changed (see
  /// [ChatStore.changeMessage]).
  void _setQuotes(String contact, String id, String quote) {
    ChatMessage withQuote(ChatMessage m) =>
        m.replyTo?.id == id ? m.copyWith(replyTo: (id: id, text: quote)) : m;
    final waiting = _waiting[contact];
    if (waiting != null) {
      for (var i = 0; i < waiting.length; i++) {
        waiting[i] = withQuote(waiting[i]);
      }
    }
    final live = _activeFor(contact);
    if (live != null) {
      for (var i = 0; i < live.resend.length; i++) {
        live.resend[i] = withQuote(live.resend[i]);
      }
      live.session?.setQuotesOf(id, quote);
    }
  }

  /// Sends the pending controls for [contact] if a chat with it is ready.
  Future<void> _flushControls(String contact) async {
    final session = _activeFor(contact)?.session;
    if (session != null && !session.isEnded) await session.flushControls();
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
        message.deletedForAll ||
        (message.state != ChatState.notSent &&
            message.state != ChatState.queued)) {
      return;
    }
    // A file is never sent as a text. A queued one is offered when the chat
    // is ready (see [flushOutbox]).
    if (message.isAttachment) {
      if (message.state == ChatState.queued) await flushOutbox(contact);
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
        message.deletedForAll ||
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
    _forget(contact, id);
    await store.deleteMessage(contact, id);
  }

  /// Takes message [id] off every list that would send it.
  void _forget(String contact, String id) {
    _waiting[contact]?.removeWhere((m) => m.id == id);
    final live = _activeFor(contact);
    live?.resend.removeWhere((m) => m.id == id);
    live?.session?.forget(id);
  }

  /// Archives or unarchives the chat with [contact]. Local only: nothing is
  /// sent, and no session is touched.
  Future<void> setArchived(String contact, bool archived) async {
    await store.setArchived(contact, archived);
    _emit(ChatUpdate(contact, const ChatSettingsChanged()));
  }

  /// Mutes or unmutes the chat with [contact]. Local only, as [setArchived].
  Future<void> setMuted(String contact, bool muted) async {
    await store.setMuted(contact, muted);
    _emit(ChatUpdate(contact, const ChatSettingsChanged()));
  }

  /// Pins or unpins the chat with [contact]. Local only, as [setArchived]. A
  /// pin past [ChatStore.maxPinnedChats] is refused with
  /// [ChatPinResult.limitReached], and nothing changes.
  Future<ChatPinResult> setPinned(String contact, bool pinned) async {
    final result = await store.setPinned(
      contact,
      pinned,
      at: clock().millisecondsSinceEpoch,
    );
    if (result != ChatPinResult.limitReached) {
      _emit(ChatUpdate(contact, const ChatSettingsChanged()));
    }
    return result;
  }

  /// Stars or unstars message [id] in the chat with [contact], on this device
  /// only. Returns false when the message is gone, deleted for everyone, or
  /// already in that state.
  Future<bool> setStarred(String contact, String id, bool starred) async {
    final changed = await store.changeMessage(
      contact,
      id,
      (m) => m.deletedForAll || m.starred == starred
          ? null
          : m.copyWith(starred: starred),
    );
    if (changed) _emit(ChatUpdate(contact, MessageChanged(id)));
    return changed;
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
        .where((m) => !m.deletedForAll)
        .toList();
    if (queued.isEmpty) return;
    final live = _activeFor(contact);
    final session = live?.session;
    if (session != null && !session.isEnded && session.isReady) {
      for (final msg in queued) {
        if (session.isEnded) return;
        if (msg.isAttachment) {
          // Offered once; the session moves it from queued to sending.
          await session.offerStoredFile(msg);
        } else {
          await store.setState(contact, msg.id, ChatState.sending);
          session.resend(msg.withState(ChatState.sending));
        }
      }
      return;
    }
    // No direct chat is ready: the texts also go through the relay, so they
    // reach a device whose app is in the background.
    for (final msg in queued.where(_relayable).take(maxRelayPerFlush)) {
      _sendThroughRelay(msg);
    }
    // A chat being opened sends the queue itself once its channel is open.
    if (live != null || _signalling.isOpening(contact)) return;
    _perform(_signalling.open(contact, clock()));
  }

  /// Whether [message] can go through the relay: an outgoing plain text that
  /// is not deleted. Files need the direct chat. So do replies and forwarded
  /// texts: the relay has not heard the other side's `hello`, so it cannot
  /// know whether the other side reads the reply quote or the forwarded mark.
  /// Sent that way, the message would be stored there without them, and the
  /// direct chat would then find it already stored.
  static bool _relayable(ChatMessage message) =>
      message.outgoing &&
      !message.isAttachment &&
      !message.deletedForAll &&
      message.replyTo == null &&
      !message.forwarded;

  /// Sends a text message through the relay (see [_relayable]).
  void _sendThroughRelay(ChatMessage message) {
    if (_disposed || !_relayable(message)) return;
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
      final arrived = clock().millisecondsSinceEpoch;
      final message = ChatMessage(
        id: messageId,
        contactId: from,
        outgoing: false,
        ts: ChatFrames.receivedTs(ts, arrived),
        text: text,
        state: ChatState.received,
        read: false,
        arrivedAt: arrived,
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
    await store.setStateAt(
      from,
      messageId,
      ChatState.delivered,
      at: clock().millisecondsSinceEpoch,
    );
    _emit(ChatUpdate(from, MessageDelivered(messageId)));
    // A reaction or edit that waited for this message can go now.
    await _flushControls(from);
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
  ///
  /// The file is checked as [prepareOutgoingFile] does, whether it goes at
  /// once or is queued: an image has its metadata removed, and a file that
  /// cannot be cleaned or is refused throws [ArgumentError], the same either
  /// way. When the chat is not ready within [offerReadyWait], the file is
  /// kept on this device and queued; it is offered once the contact is
  /// online (never through the relay).
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
    final file = prepareOutgoingFile(
      name: name,
      bytes: bytes,
      mime: mime,
      voice: voice,
      maxFileBytes: maxFileBytes,
    );
    _ensureTicker();
    if (_activeFor(contact) == null && !_signalling.isOpening(contact)) {
      _perform(_signalling.open(contact, clock()));
    }
    ChatSession? ready() {
      final session = _activeFor(contact)?.session;
      return session != null && !session.isEnded && session.isReady
          ? session
          : null;
    }

    // Waits a little for a chat being opened to become ready.
    const step = Duration(milliseconds: 200);
    var waited = Duration.zero;
    while (ready() == null && waited < offerReadyWait && !_disposed) {
      await Future<void>.delayed(step);
      waited += step;
    }
    final session = ready();
    if (session != null) return session.offerPrepared(file);

    // The contact is offline: the file is kept here and queued.
    final id = _newId();
    final queued = await store.keepOutgoingFile(
      ChatMessage(
        id: id,
        contactId: contact,
        outgoing: true,
        ts: clock().millisecondsSinceEpoch,
        text: file.name,
        state: ChatState.queued,
        fileId: id,
        fileName: file.name,
        fileSize: file.bytes.length,
        fileMime: file.mime,
        fileSha256: file.sha256,
        fileStatus: 'offered',
        voiceNote: file.voice,
      ),
      file.bytes,
    );
    await store.add(queued);
    // A chat that became ready meanwhile offers it now.
    unawaited(flushOutbox(contact));
    return queued;
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
        if (!_relayable(m) || m.ts < since) continue;
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

  /// Publishes [event] to the listeners, as a session does. A widget test uses
  /// it to show an open chat a change made without a live session.
  @visibleForTesting
  void publishForTest(ChatManagerEvent event) => _emit(event);

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
        maxFileBytes: maxFileBytes,
        autoAcceptFiles: autoDownloadFiles,
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
    // Queued texts go with the start. Queued files are not texts: the
    // session offers them itself once the other side is ready.
    final queued = (await store.messages(live.contact)).where(
      (m) => m.outgoing && m.state == ChatState.queued && !m.isAttachment,
    );
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
