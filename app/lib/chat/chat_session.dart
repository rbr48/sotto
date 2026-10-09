import 'dart:async';

import 'chat_frames.dart';
import 'chat_store.dart';

/// The data channel of one chat session, as the session needs it. The WebRTC
/// engine provides it; tests use an in-memory pair.
abstract interface class ChatTransport {
  /// Queues one frame. False when the channel is closed.
  bool send(String frame);

  /// Incoming frames, in order, until the channel closes.
  Stream<String> get frames;

  Future<void> close();
}

sealed class ChatSessionEvent {
  const ChatSessionEvent();
}

final class MessageReceived extends ChatSessionEvent {
  const MessageReceived(this.message);
  final ChatMessage message;
}

/// The other device has stored the message and checked it.
final class MessageDelivered extends ChatSessionEvent {
  const MessageDelivered(this.id);
  final String id;
}

/// The session ended before the message was delivered. It can be sent again
/// in a later session.
final class MessageNotSent extends ChatSessionEvent {
  const MessageNotSent(this.id);
  final String id;
}

/// The session is over. [reason] is 'closed' (this side), 'bye' (the other
/// side), 'idle', 'version' (the other side speaks another version), or
/// 'lost' (the channel broke).
final class SessionEnded extends ChatSessionEvent {
  const SessionEnded(this.reason);
  final String reason;
}

/// One chat over one data channel, as specified in `docs/MESSAGING_PLAN.md`.
///
/// Both sides send `hello` first. Messages go out only after the other side's
/// `hello`, are stored when they arrive, and are acknowledged. A message that
/// arrives again (for example after a resend) is acknowledged but not stored
/// twice.
class ChatSession {
  ChatSession({
    required this.contactId,
    required this.transport,
    required this.store,
    required this.clock,
    String Function()? newId,
    this.idleTimeout = const Duration(minutes: 5),
    this.isContact,
  }) : _newId = newId ?? ChatFrames.newId;

  final String contactId;
  final ChatTransport transport;
  final ChatStore store;
  final DateTime Function() clock;
  final String Function() _newId;

  /// Whether the other person is still a contact. When not, the session ends
  /// and nothing more from them is stored. Null: no check.
  final bool Function()? isContact;

  bool get _contactNow => isContact?.call() ?? true;

  /// How long the session can be silent (with the chat not open) before it
  /// closes.
  final Duration idleTimeout;

  final _events = StreamController<ChatSessionEvent>.broadcast();

  Stream<ChatSessionEvent> get events => _events.stream;

  /// Messages sent but not yet acknowledged, by id.
  final _outbox = <String, ChatMessage>{};

  /// Ids of outbox messages still to be written to the channel, in order.
  final _unsent = <String>[];

  /// Frames are handled one at a time, so the duplicate check and the store
  /// writes never interleave.
  Future<void> _incoming = Future<void>.value();

  StreamSubscription<String>? _subscription;
  bool _peerHello = false;
  bool _ended = false;
  late DateTime _lastActivity;

  /// Whether messages can be sent now.
  bool get isReady => _peerHello && !_ended;

  bool get isEnded => _ended;

  /// Starts the session. [resend] are messages from an earlier session that
  /// were never delivered; they are sent once the session is ready.
  Future<void> start({List<ChatMessage> resend = const []}) async {
    _lastActivity = clock();
    for (final message in resend) {
      await store.setState(contactId, message.id, ChatState.sending);
      _outbox[message.id] = message.withState(ChatState.sending);
      _unsent.add(message.id);
    }
    _subscription = transport.frames.listen(
      (raw) => _incoming = _incoming.then((_) => _onFrame(raw)),
      onDone: () => _incoming = _incoming.then((_) => _end('lost')),
    );
    _write(const HelloFrame());
  }

  /// Sends a message. It is stored at once and sent when the session is ready.
  Future<ChatMessage> sendText(String text) async {
    _ensureOpen();
    final cleaned = ChatFrames.cleanText(text);
    if (cleaned.isEmpty || cleaned.runes.length > maxTextChars) {
      throw ArgumentError.value(
        text,
        'text',
        'must be 1 to $maxTextChars characters',
      );
    }
    final message = ChatMessage(
      id: _newId(),
      contactId: contactId,
      outgoing: true,
      ts: clock().millisecondsSinceEpoch,
      text: cleaned,
      state: ChatState.sending,
    );
    // Queued before the write. If the session ends during the write, the end
    // marks the message not sent: store writes run in the order they were
    // asked for.
    _outbox[message.id] = message;
    _unsent.add(message.id);
    await store.add(message);
    _lastActivity = clock();
    _sendOutbox();
    return message;
  }

  /// Ends the session from this side.
  Future<void> close() async {
    if (_ended) return;
    _write(const ByeFrame());
    await _end('closed');
  }

  /// Ends the session after [idleTimeout] of silence. A chat that is open on
  /// screen ([viewing]) is kept, and so is a session with messages still
  /// waiting for an answer.
  Future<void> tick({required bool viewing}) async {
    if (_ended) return;
    if (!_contactNow) {
      _write(const ByeFrame());
      await _end('not-contact');
      return;
    }
    if (viewing || _outbox.isNotEmpty) return;
    if (clock().difference(_lastActivity) < idleTimeout) return;
    _write(const ByeFrame());
    await _end('idle');
  }

  void _ensureOpen() {
    if (_ended) throw StateError('the chat session has ended');
  }

  void _sendOutbox() {
    if (!isReady) return;
    while (_unsent.isNotEmpty) {
      final message = _outbox[_unsent.first];
      if (message != null &&
          !_write(
            MessageFrame(id: message.id, ts: message.ts, text: message.text),
          )) {
        return;
      }
      _unsent.removeAt(0);
    }
  }

  /// Writes one frame. A channel that refuses it has broken.
  bool _write(ChatFrame frame) {
    final sent = transport.send(ChatFrames.encode(frame));
    if (!sent) unawaited(_end('lost'));
    return sent;
  }

  Future<void> _onFrame(String raw) async {
    if (_ended) return;
    _lastActivity = clock();
    final ChatFrame frame;
    try {
      frame = ChatFrames.decode(raw);
    } on ChatFrameException catch (e) {
      // Other malformed frames are ignored: the sender resends what matters.
      if (e.reason == 'version') await _end('version');
      return;
    }
    switch (frame) {
      case HelloFrame():
        _peerHello = true;
        // Everything not yet acknowledged goes out again, in order.
        _unsent
          ..clear()
          ..addAll(_outbox.keys);
        _sendOutbox();
      case MessageFrame(:final id, :final ts, :final text):
        if (!_peerHello) return;
        if (!_contactNow) {
          // Someone removed from the contacts gets no more stored.
          _write(const ByeFrame());
          await _end('not-contact');
          return;
        }
        if (!await store.contains(contactId, id)) {
          final message = ChatMessage(
            id: id,
            contactId: contactId,
            outgoing: false,
            ts: ts,
            text: text,
            state: ChatState.received,
          );
          await store.add(message);
          _events.add(MessageReceived(message));
        }
        _write(AckFrame(id: id));
      case AckFrame(:final id):
        if (!_peerHello) return;
        if (_outbox.remove(id) != null) {
          _unsent.remove(id);
          await store.setState(contactId, id, ChatState.delivered);
          _events.add(MessageDelivered(id));
        }
      case ByeFrame():
        await _end('bye');
    }
  }

  Future<void> _end(String reason) async {
    if (_ended) return;
    _ended = true;
    for (final id in _outbox.keys.toList()) {
      await store.setState(contactId, id, ChatState.notSent);
      _events.add(MessageNotSent(id));
    }
    _outbox.clear();
    _unsent.clear();
    await _subscription?.cancel();
    await transport.close();
    _events.add(SessionEnded(reason));
    await _events.close();
  }
}
