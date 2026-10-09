import 'dart:async';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'chat_frames.dart';
import 'chat_store.dart';
import 'file_storage.dart';

/// The data channel of one chat session, as the session needs it. The WebRTC
/// engine provides it; tests use an in-memory pair.
abstract interface class ChatTransport {
  /// Queues one frame. False when the channel is closed.
  bool send(String frame);

  /// Queues one binary chunk frame. False when the channel is closed.
  bool sendBinary(Uint8List data) => false;

  /// Incoming frames, in order, until the channel closes.
  Stream<String> get frames;

  /// Incoming binary frames, in order, until the channel closes.
  Stream<Uint8List> get binaryFrames => const Stream.empty();

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

/// The other person is currently typing (or stopped typing).
final class PeerTyping extends ChatSessionEvent {
  const PeerTyping(this.typing);
  final bool typing;
}

/// The other person has read the messages with these [ids].
final class MessagesRead extends ChatSessionEvent {
  const MessagesRead(this.ids);
  final List<String> ids;
}

/// A file offer was received from the peer.
final class FileOfferReceived extends ChatSessionEvent {
  const FileOfferReceived(this.message);
  final ChatMessage message;
}

/// Progress update for an active file transfer (0.0 to 1.0).
final class FileTransferProgress extends ChatSessionEvent {
  const FileTransferProgress(this.id, this.progress);
  final String id;
  final double progress;
}

/// File transfer completed and verified.
final class FileTransferCompleted extends ChatSessionEvent {
  const FileTransferCompleted(this.id, this.filePath);
  final String id;
  final String? filePath;
}

/// File transfer was declined, cancelled, or failed.
final class FileTransferFailed extends ChatSessionEvent {
  const FileTransferFailed(this.id, this.reason);
  final String id;
  final String reason;
}

/// The session is over. [reason] is 'closed' (this side), 'bye' (the other
/// side), 'idle', 'version' (the other side speaks another version), or
/// 'lost' (the channel broke).
final class SessionEnded extends ChatSessionEvent {
  const SessionEnded(this.reason);
  final String reason;
}

class _IncomingFileTransfer {
  _IncomingFileTransfer({
    required this.id,
    required this.name,
    required this.size,
    required this.mime,
    required this.sha256,
    required this.totalChunks,
  });

  final String id;
  final String name;
  final int size;
  final String mime;
  final String sha256;
  final int totalChunks;
  final chunks = <int, Uint8List>{};
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
  StreamSubscription<Uint8List>? _binarySubscription;
  bool _peerHello = false;
  bool _ended = false;
  late DateTime _lastActivity;

  /// Outgoing file byte payloads waiting to stream on accept, by fileId.
  final _outgoingFiles = <String, Uint8List>{};

  /// Incoming file transfers in progress, by fileId.
  final _incomingFiles = <String, _IncomingFileTransfer>{};

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
    _binarySubscription = transport.binaryFrames.listen(
      (bytes) => _incoming = _incoming.then((_) => _onBinaryChunk(bytes)),
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

  /// Offers to send a file to the contact.
  Future<ChatMessage> offerFile({
    required String name,
    required Uint8List bytes,
    required String mime,
  }) async {
    _ensureOpen();
    if (ChatFrames.isBlockedFileType(name)) {
      throw ArgumentError('Blocked file type: $name');
    }
    if (bytes.length > maxFileSizeNative) {
      throw ArgumentError('File exceeds max size limit');
    }
    final cleaned = ChatFrames.cleanFileName(name);
    final hash = sha256.convert(bytes).toString();
    final chunks = (bytes.length / fileChunkSize).ceil();
    final id = _newId();
    final message = ChatMessage(
      id: id,
      contactId: contactId,
      outgoing: true,
      ts: clock().millisecondsSinceEpoch,
      text: cleaned,
      state: ChatState.sending,
      fileId: id,
      fileName: cleaned,
      fileSize: bytes.length,
      fileMime: mime,
      fileSha256: hash,
      fileStatus: 'offered',
    );
    _outgoingFiles[id] = bytes;
    await store.add(message);
    _write(
      FileOfferFrame(
        id: id,
        name: cleaned,
        size: bytes.length,
        mime: mime,
        sha256: hash,
        chunks: chunks == 0 ? 1 : chunks,
      ),
    );
    return message;
  }

  /// Accepts an offered file from the contact.
  Future<void> acceptFile(String fileId) async {
    _ensureOpen();
    final msg = await store.find(contactId, fileId);
    if (msg == null || msg.fileName == null) return;
    final totalChunks = ((msg.fileSize ?? 0) / fileChunkSize).ceil();
    _incomingFiles[fileId] = _IncomingFileTransfer(
      id: fileId,
      name: msg.fileName!,
      size: msg.fileSize ?? 0,
      mime: msg.fileMime ?? 'application/octet-stream',
      sha256: msg.fileSha256 ?? '',
      totalChunks: totalChunks == 0 ? 1 : totalChunks,
    );
    await store.updateMessage(msg.copyWith(fileStatus: 'transferring'));
    _write(FileAcceptFrame(id: fileId));
  }

  /// Declines an offered file from the contact.
  Future<void> declineFile(String fileId) async {
    _ensureOpen();
    final msg = await store.find(contactId, fileId);
    if (msg != null) {
      await store.updateMessage(msg.copyWith(fileStatus: 'declined'));
    }
    _write(FileDeclineFrame(id: fileId));
  }

  /// Cancels an active file transfer.
  Future<void> cancelFile(String fileId, {String? reason}) async {
    _outgoingFiles.remove(fileId);
    _incomingFiles.remove(fileId);
    final msg = await store.find(contactId, fileId);
    if (msg != null) {
      await store.updateMessage(msg.copyWith(fileStatus: 'cancelled'));
    }
    _write(FileCancelFrame(id: fileId, reason: reason));
  }

  Future<void> _streamFileChunks(String fileId, Uint8List bytes) async {
    final totalChunks = (bytes.length / fileChunkSize).ceil();
    final count = totalChunks == 0 ? 1 : totalChunks;
    for (var i = 0; i < count; i++) {
      if (_ended || !_outgoingFiles.containsKey(fileId)) return;
      final start = i * fileChunkSize;
      final end = (start + fileChunkSize) > bytes.length
          ? bytes.length
          : start + fileChunkSize;
      final slice = bytes.sublist(start, end);
      final chunkBytes = ChatFrames.encodeChunk(
        fileId: fileId,
        chunkIndex: i,
        payload: slice,
      );
      transport.sendBinary(chunkBytes);
      final progress = (i + 1) / count;
      _events.add(FileTransferProgress(fileId, progress));
      await Future<void>.delayed(Duration.zero);
    }
    _write(FileDoneFrame(id: fileId));
  }

  Future<void> _onBinaryChunk(Uint8List bytes) async {
    if (_ended) return;
    _lastActivity = clock();
    try {
      final (:fileId, :chunkIndex, :payload) = ChatFrames.decodeChunk(bytes);
      final transfer = _incomingFiles[fileId];
      if (transfer == null) return;
      transfer.chunks[chunkIndex] = payload;
      final progress = transfer.chunks.length / transfer.totalChunks;
      _events.add(FileTransferProgress(fileId, progress));
    } catch (_) {}
  }

  /// Sends again a message from an earlier attempt. It keeps its id, so the
  /// other side stores it once.
  void resend(ChatMessage message) {
    _ensureOpen();
    _outbox[message.id] = message.withState(ChatState.sending);
    _unsent.add(message.id);
    _sendOutbox();
  }

  /// Sends a typing indicator frame to the other device.
  void sendTyping(bool typing) {
    if (!isReady) return;
    _write(TypingFrame(typing: typing));
  }

  /// Sends read receipts for [ids] to the other device.
  void sendReadReceipts(List<String> ids) {
    if (!isReady || ids.isEmpty) return;
    _write(ReadFrame(ids: ids));
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
            read: false,
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
      case TypingFrame(:final typing):
        if (!_peerHello) return;
        _events.add(PeerTyping(typing));
      case ReadFrame(:final ids):
        if (!_peerHello) return;
        for (final id in ids) {
          await store.setState(contactId, id, ChatState.read);
        }
        _events.add(MessagesRead(ids));
      case FileOfferFrame(
        :final id,
        :final name,
        :final size,
        :final mime,
        :final sha256,
      ):
        if (!_peerHello) return;
        if (!_contactNow) {
          _write(const ByeFrame());
          await _end('not-contact');
          return;
        }
        if (!await store.contains(contactId, id)) {
          final message = ChatMessage(
            id: id,
            contactId: contactId,
            outgoing: false,
            ts: clock().millisecondsSinceEpoch,
            text: name,
            state: ChatState.received,
            read: false,
            fileId: id,
            fileName: name,
            fileSize: size,
            fileMime: mime,
            fileSha256: sha256,
            fileStatus: 'offered',
          );
          await store.add(message);
          _events.add(MessageReceived(message));
          _events.add(FileOfferReceived(message));
        }
      case FileAcceptFrame(:final id):
        if (!_peerHello) return;
        final bytes = _outgoingFiles[id];
        if (bytes == null) return;
        final existing = await store.find(contactId, id);
        if (existing != null) {
          await store.updateMessage(
            existing.copyWith(fileStatus: 'transferring'),
          );
        }
        unawaited(_streamFileChunks(id, bytes));
      case FileDeclineFrame(:final id):
        if (!_peerHello) return;
        _outgoingFiles.remove(id);
        final existing = await store.find(contactId, id);
        if (existing != null) {
          await store.updateMessage(existing.copyWith(fileStatus: 'declined'));
          _events.add(FileTransferFailed(id, 'declined'));
        }
      case FileDoneFrame(:final id):
        if (!_peerHello) return;
        final transfer = _incomingFiles.remove(id);
        if (transfer == null) return;
        if (transfer.chunks.length != transfer.totalChunks) {
          _write(FileCancelFrame(id: id, reason: 'incomplete'));
          final existing = await store.find(contactId, id);
          if (existing != null) {
            await store.updateMessage(existing.copyWith(fileStatus: 'failed'));
          }
          _events.add(FileTransferFailed(id, 'incomplete'));
          return;
        }
        final builder = BytesBuilder(copy: false);
        for (var i = 0; i < transfer.totalChunks; i++) {
          final chunk = transfer.chunks[i];
          if (chunk == null) {
            _write(FileCancelFrame(id: id, reason: 'missing-chunk'));
            final existing = await store.find(contactId, id);
            if (existing != null) {
              await store.updateMessage(
                existing.copyWith(fileStatus: 'failed'),
              );
            }
            _events.add(FileTransferFailed(id, 'missing-chunk'));
            return;
          }
          builder.add(chunk);
        }
        final fullBytes = builder.takeBytes();
        final computedHash = sha256.convert(fullBytes).toString();
        if (computedHash != transfer.sha256) {
          _write(FileCancelFrame(id: id, reason: 'damaged'));
          final existing = await store.find(contactId, id);
          if (existing != null) {
            await store.updateMessage(existing.copyWith(fileStatus: 'failed'));
          }
          _events.add(FileTransferFailed(id, 'damaged'));
          return;
        }
        final savedPath = await ChatFileStorage.saveReceivedBlob(
          fileId: id,
          name: transfer.name,
          bytes: fullBytes,
        );
        _write(FileAckFrame(id: id));
        final existing = await store.find(contactId, id);
        if (existing != null) {
          await store.updateMessage(
            existing.copyWith(fileStatus: 'completed', filePath: savedPath),
          );
        }
        _events.add(FileTransferCompleted(id, savedPath));
      case FileAckFrame(:final id):
        if (!_peerHello) return;
        _outgoingFiles.remove(id);
        final existing = await store.find(contactId, id);
        if (existing != null) {
          await store.updateMessage(existing.copyWith(fileStatus: 'completed'));
        }
        _events.add(FileTransferCompleted(id, null));
      case FileCancelFrame(:final id, :final reason):
        _outgoingFiles.remove(id);
        _incomingFiles.remove(id);
        final existing = await store.find(contactId, id);
        if (existing != null) {
          await store.updateMessage(existing.copyWith(fileStatus: 'cancelled'));
        }
        _events.add(FileTransferFailed(id, reason ?? 'cancelled'));
      case ByeFrame():
        await _end('bye');
    }
  }

  Future<void> _end(String reason) async {
    if (_ended) return;
    _ended = true;
    for (final id in _outbox.keys.toList()) {
      await store.setState(contactId, id, ChatState.notSent, reason: reason);
      _events.add(MessageNotSent(id));
    }
    _outbox.clear();
    _unsent.clear();
    _outgoingFiles.clear();
    _incomingFiles.clear();
    await _subscription?.cancel();
    await _binarySubscription?.cancel();
    await transport.close();
    _events.add(SessionEnded(reason));
    await _events.close();
  }
}
