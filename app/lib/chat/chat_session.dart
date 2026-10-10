import 'dart:async';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

import 'chat_frames.dart';
import 'chat_store.dart';
import 'image_metadata.dart';
import 'voice/voice_format.dart';

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

  /// The amount of bytes buffered in the transport output buffer, as last
  /// reported. On native platforms this is a cached value that is updated
  /// asynchronously; use [bufferedAmountNow] before deciding to send.
  int get bufferedAmount => 0;

  /// The amount of bytes buffered in the transport output buffer, asked of
  /// the channel now.
  Future<int> bufferedAmountNow() async => bufferedAmount;

  Future<void> close();
}

/// The largest file this platform sends or accepts: the browser holds files
/// in memory, so its limit is smaller.
const int platformMaxFileBytes = kIsWeb ? maxFileSizeWeb : maxFileSizeNative;

/// A file checked and made ready to offer (see [prepareOutgoingFile]).
typedef PreparedFile = ({
  String name,
  Uint8List bytes,
  String mime,
  String sha256,
  bool voice,
});

/// Checks a file before it is offered, sent at once or queued, and returns
/// what is sent: the cleaned name, and the bytes with an image's metadata
/// (location, camera details, comments) removed.
///
/// A [voice] note must be an audio type with a name to match and be within
/// that type's cap. Throws [ArgumentError] for a blocked type, a MIME type
/// that is too long, an empty file, a file over [maxFileBytes], an image that
/// cannot be read, an image type this app cannot clean, or a voice note that
/// is refused. Nothing is ever sent unclean: an image that cannot be cleaned
/// is refused.
PreparedFile prepareOutgoingFile({
  required String name,
  required Uint8List bytes,
  required String mime,
  bool voice = false,
  int maxFileBytes = platformMaxFileBytes,
}) {
  final cleanedName = ChatFrames.cleanFileName(name);
  if (ChatFrames.isBlockedFileType(name) ||
      ChatFrames.isBlockedFileType(cleanedName)) {
    throw ArgumentError('Blocked file type: $name');
  }
  if (mime.runes.length > maxMimeChars) {
    throw ArgumentError.value(
      mime,
      'mime',
      'must be at most $maxMimeChars characters',
    );
  }
  final Uint8List clean;
  try {
    // Throws ArgumentError for an image type it cannot clean.
    clean = ImageMetadata.clean(bytes, mime);
  } on FormatException {
    throw ArgumentError('Image could not be read');
  }
  if (clean.isEmpty) throw ArgumentError('File is empty');
  if (clean.length > maxFileBytes) {
    throw ArgumentError('File exceeds max size limit');
  }
  if (voice) {
    if (!voiceNameMatches(mime, cleanedName)) {
      throw ArgumentError('Voice note has the wrong file name');
    }
    if (voiceOfferRefused(mime: mime, size: clean.length)) {
      throw ArgumentError('Voice note exceeds the size limit');
    }
  }
  return (
    name: cleanedName,
    bytes: clean,
    mime: mime,
    sha256: sha256.convert(clean).toString(),
    voice: voice,
  );
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
    required this.lastChunkAt,
    required this.voice,
  });

  final String id;
  final String name;
  final int size;
  final String mime;
  final String sha256;
  final int totalChunks;

  /// Whether this is a voice note, which is checked against its format.
  final bool voice;

  /// When the last chunk arrived (or the transfer was accepted).
  DateTime lastChunkAt;

  /// Bytes received so far, in total.
  int received = 0;
  final chunks = <int, Uint8List>{};

  /// Whether the sender reported that it finished sending all chunks.
  bool doneReceived = false;

  /// Fallback timeout waiting for in-flight binary chunks when doneReceived is true.
  Timer? completionTimeout;
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
    this.maxFileBytes = platformMaxFileBytes,
    this.autoAcceptFiles = _never,
    Future<void> Function()? bufferWait,
  }) : _newId = newId ?? ChatFrames.newId,
       _bufferWait = bufferWait ?? _waitForBuffer;

  /// Whether files offered by the contact download without asking ("Download
  /// files automatically" in Settings). Read for each offer, so a change
  /// applies to the next one. Even then, only files up to
  /// [autoAcceptMaxBytes] download, at most [autoAcceptMaxConcurrent] at a
  /// time, and at most [autoAcceptBudgetBytes] in all per session; any other
  /// offer waits to be accepted by hand. Voice notes always download.
  final bool Function() autoAcceptFiles;

  static bool _never() => false;

  /// The largest file that downloads without asking.
  static const autoAcceptMaxBytes = 25 * 1024 * 1024;

  /// At most this many incoming transfers run when a file would download
  /// without asking.
  static const autoAcceptMaxConcurrent = 2;

  /// The bytes that may download without asking in one session, in all.
  static const autoAcceptBudgetBytes = 200 * 1024 * 1024;

  /// Bytes downloaded without asking in this session so far.
  int _autoAcceptedBytes = 0;

  /// Chunks wait while more than this is buffered in the channel.
  static const maxBufferedBytes = 256 * 1024;

  /// Waits a little before the buffered amount is asked again.
  final Future<void> Function() _bufferWait;

  static Future<void> _waitForBuffer() =>
      Future<void>.delayed(const Duration(milliseconds: 15));

  /// The largest file this device accepts (the browser's is smaller).
  final int maxFileBytes;

  /// How long a file transfer may go without a chunk before it fails.
  static const fileStallTimeout = Duration(seconds: 30);

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

  /// Outgoing files offered in this session and not yet accepted. An accept
  /// is honoured only for these, and only once.
  final _offered = <String>{};

  /// Outgoing files being sent (accepted, until acknowledged or stopped).
  final _sending = <String>{};

  /// Queued outgoing files this session has started to offer, so none is
  /// offered twice.
  final _offeringQueued = <String>{};

  /// Incoming file transfers in progress, by fileId.
  final _incomingFiles = <String, _IncomingFileTransfer>{};

  /// Read receipts asked for before the other device was ready.
  final _pendingReads = <String>{};

  /// Whether messages can be sent now.
  bool get isReady => _peerHello && !_ended;

  bool get isEnded => _ended;

  /// Starts the session. [resend] are messages from an earlier session that
  /// were never delivered; they are sent once the session is ready.
  Future<void> start({List<ChatMessage> resend = const []}) async {
    _lastActivity = clock();
    for (final message in resend) {
      // A file is never sent as a text: queued files are offered once the
      // other side is ready (see [offerStoredFile]).
      if (message.isAttachment) continue;
      await store.setState(contactId, message.id, ChatState.sending);
      _outbox[message.id] = message.withState(ChatState.sending);
      _unsent.add(message.id);
    }
    // Each step is chained on the one before, and an error in one step (a
    // full disk, say) is dropped there, so the later frames and the end of
    // the channel are still handled.
    _subscription = transport.frames.listen(
      (raw) => _enqueue(() => _onFrame(raw)),
      onDone: () => _enqueue(() => _end('lost')),
    );
    _binarySubscription = transport.binaryFrames.listen(
      (bytes) => _enqueue(() => _onBinaryChunk(bytes)),
    );
    _write(const HelloFrame());
  }

  void _enqueue(Future<void> Function() step) {
    _incoming = _incoming.then((_) => step()).catchError((Object _) {
      // The error can hold a file name or text. It is not logged.
    });
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
  ///
  /// The file is checked by [prepareOutgoingFile] first (see there for what
  /// is refused, with [ArgumentError]); an image has its metadata removed.
  Future<ChatMessage> offerFile({
    required String name,
    required Uint8List bytes,
    required String mime,
    bool voice = false,
  }) async {
    _ensureOpen();
    return offerPrepared(
      prepareOutgoingFile(
        name: name,
        bytes: bytes,
        mime: mime,
        voice: voice,
        maxFileBytes: maxFileBytes,
      ),
    );
  }

  /// Offers a file that [prepareOutgoingFile] has checked.
  Future<ChatMessage> offerPrepared(PreparedFile file) async {
    _ensureOpen();
    final id = _newId();
    final chunks = (file.bytes.length / fileChunkSize).ceil();
    final offered = await store.keepOutgoingFile(
      ChatMessage(
        id: id,
        contactId: contactId,
        outgoing: true,
        ts: clock().millisecondsSinceEpoch,
        text: file.name,
        state: ChatState.sending,
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
    _offered.add(id);
    await store.add(offered);
    _write(
      FileOfferFrame(
        id: id,
        name: file.name,
        size: file.bytes.length,
        mime: file.mime,
        sha256: file.sha256,
        chunks: chunks == 0 ? 1 : chunks,
        voice: file.voice,
      ),
    );
    return offered;
  }

  /// Offers an outgoing file that was saved and queued while the contact was
  /// offline. It is offered once: its state moves from queued to sending as
  /// it is offered, and a file that is no longer queued, or whose offer was
  /// cancelled, is skipped. Returns whether it was offered.
  Future<bool> offerStoredFile(ChatMessage message) async {
    if (!isReady) return false;
    if (!message.isAttachment || !message.outgoing) return false;
    if (!_offeringQueued.add(message.id)) return false;
    final current = await store.find(contactId, message.id);
    if (_ended ||
        current == null ||
        current.state != ChatState.queued ||
        current.fileStatus != 'offered') {
      _offeringQueued.remove(message.id);
      return false;
    }
    Uint8List bytes;
    try {
      bytes = await store.readFile(current);
    } catch (_) {
      // Gone from this device (for example, the browser let it go).
      await store.setState(contactId, current.id, ChatState.sending);
      await _failFile(current.id, 'unavailable', 'failed');
      return false;
    }
    final hash = sha256.convert(bytes).toString();
    if (bytes.isEmpty ||
        bytes.length > maxFileBytes ||
        (current.fileSha256 != null && current.fileSha256 != hash)) {
      await store.setState(contactId, current.id, ChatState.sending);
      await _failFile(current.id, 'damaged', 'failed');
      return false;
    }
    if (_ended) return false;
    await store.setState(contactId, current.id, ChatState.sending);
    if (_ended) return false;
    _offered.add(current.id);
    final chunks = (bytes.length / fileChunkSize).ceil();
    _write(
      FileOfferFrame(
        id: current.id,
        name: current.fileName ?? 'file',
        size: bytes.length,
        mime: current.fileMime ?? 'application/octet-stream',
        sha256: hash,
        chunks: chunks == 0 ? 1 : chunks,
        voice: current.voiceNote,
      ),
    );
    return true;
  }

  /// Offers every queued outgoing file of this chat (see [offerStoredFile]).
  Future<void> _offerQueuedFiles() async {
    for (final m in await store.messages(contactId)) {
      if (_ended) return;
      if (m.outgoing && m.isAttachment && m.state == ChatState.queued) {
        await offerStoredFile(m);
      }
    }
  }

  /// Accepts an offered file from the contact.
  ///
  /// An offer of a blocked type is declined instead. That covers an offer
  /// stored before the type was blocked.
  Future<void> acceptFile(String fileId) async {
    _ensureOpen();
    if (_incomingFiles.containsKey(fileId)) return;
    final msg = await store.find(contactId, fileId);
    if (msg == null || msg.fileName == null) return;
    // Only an offer still waiting is accepted, and only once.
    if (msg.outgoing || msg.fileStatus != 'offered') return;
    if (_incomingFiles.containsKey(fileId)) return;
    if (ChatFrames.isBlockedFileType(msg.fileName!)) {
      await declineFile(fileId);
      return;
    }
    final totalChunks = ((msg.fileSize ?? 0) / fileChunkSize).ceil();
    _incomingFiles[fileId] = _IncomingFileTransfer(
      id: fileId,
      name: msg.fileName!,
      size: msg.fileSize ?? 0,
      mime: msg.fileMime ?? 'application/octet-stream',
      sha256: msg.fileSha256 ?? '',
      totalChunks: totalChunks == 0 ? 1 : totalChunks,
      lastChunkAt: clock(),
      voice: msg.voiceNote,
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
    _offered.remove(fileId);
    _sending.remove(fileId);
    final incoming = _incomingFiles.remove(fileId);
    incoming?.completionTimeout?.cancel();
    final msg = await store.find(contactId, fileId);
    if (msg != null && _stillOpen(msg.fileStatus)) {
      await store.updateMessage(msg.copyWith(fileStatus: 'cancelled'));
    }
    if (!_ended) _write(FileCancelFrame(id: fileId, reason: reason));
  }

  /// Whether a file in [status] is still offered or on its way.
  static bool _stillOpen(String? status) =>
      status == 'offered' || status == 'transferring';

  /// Sends the chunks of an accepted file. Before each chunk the channel's
  /// buffer is asked for its real size, and the chunk waits while it is over
  /// [maxBufferedBytes]. A chunk the channel refuses stops the transfer.
  Future<void> _streamFileChunks(String fileId, Uint8List bytes) async {
    final totalChunks = (bytes.length / fileChunkSize).ceil();
    final count = totalChunks == 0 ? 1 : totalChunks;
    for (var i = 0; i < count; i++) {
      if (!await _waitForRoom(fileId)) return;
      final start = i * fileChunkSize;
      final end = (start + fileChunkSize) > bytes.length
          ? bytes.length
          : start + fileChunkSize;
      final chunkBytes = ChatFrames.encodeChunk(
        fileId: fileId,
        chunkIndex: i,
        payload: Uint8List.sublistView(bytes, start, end),
      );
      bool sent;
      try {
        sent = transport.sendBinary(chunkBytes);
      } catch (_) {
        sent = false;
      }
      if (!sent) {
        await _stopSending(fileId, 'failed');
        return;
      }
      _emit(FileTransferProgress(fileId, (i + 1) / count));
      // Lets the rest of the app run between chunks.
      await Future<void>.delayed(Duration.zero);
    }
    if (_ended || !_sending.contains(fileId)) return;
    _write(FileDoneFrame(id: fileId));
  }

  /// Waits until the channel has room for the next chunk of [fileId]. False
  /// when the transfer stopped meanwhile, or the buffer did not drain within
  /// [fileStallTimeout] (the transfer is then stopped).
  Future<bool> _waitForRoom(String fileId) async {
    final started = clock();
    while (true) {
      if (_ended || !_sending.contains(fileId)) return false;
      int buffered;
      try {
        buffered = await transport.bufferedAmountNow();
      } catch (_) {
        buffered = transport.bufferedAmount;
      }
      if (_ended || !_sending.contains(fileId)) return false;
      if (buffered <= maxBufferedBytes) return true;
      if (clock().difference(started) >= fileStallTimeout) {
        await _stopSending(fileId, 'stalled');
        return false;
      }
      await _bufferWait();
    }
  }

  /// Stops sending [fileId]: the other side is told, and the file failed.
  Future<void> _stopSending(String fileId, String reason) async {
    if (!_sending.remove(fileId)) return;
    if (!_ended) _write(FileCancelFrame(id: fileId, reason: reason));
    await _failFile(fileId, reason, 'failed');
  }

  void _emit(ChatSessionEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

  Future<void> _onBinaryChunk(Uint8List bytes) async {
    if (_ended) return;
    _lastActivity = clock();
    late final ({String fileId, int chunkIndex, Uint8List payload}) chunk;
    try {
      chunk = ChatFrames.decodeChunk(bytes);
    } catch (_) {
      return;
    }
    final transfer = _incomingFiles[chunk.fileId];
    if (transfer == null) return;
    // A chunk must belong to this file, have the agreed size, and not repeat
    // data beyond the offered size. Anything else is dropped.
    final last = transfer.totalChunks - 1;
    if (chunk.chunkIndex < 0 || chunk.chunkIndex > last) return;
    final expected = chunk.chunkIndex == last
        ? transfer.size - last * fileChunkSize
        : fileChunkSize;
    if (chunk.payload.length != expected) return;
    if (transfer.chunks.containsKey(chunk.chunkIndex)) return;
    transfer.chunks[chunk.chunkIndex] = chunk.payload;
    transfer.received += chunk.payload.length;
    transfer.lastChunkAt = clock();
    final progress = transfer.chunks.length / transfer.totalChunks;
    _events.add(FileTransferProgress(chunk.fileId, progress));

    if (transfer.doneReceived &&
        transfer.chunks.length == transfer.totalChunks) {
      _incomingFiles.remove(chunk.fileId);
      await _finishIncomingTransfer(transfer);
    }
  }

  /// Sends again a message from an earlier attempt. It keeps its id, so the
  /// other side stores it once.
  void resend(ChatMessage message) {
    _ensureOpen();
    // Files are offered, never sent as text (see [offerStoredFile]).
    if (message.isAttachment) return;
    _outbox[message.id] = message.withState(ChatState.sending);
    _unsent.add(message.id);
    _sendOutbox();
  }

  /// Sends a typing indicator frame to the other device.
  void sendTyping(bool typing) {
    if (!isReady) return;
    _write(TypingFrame(typing: typing));
  }

  /// Sends read receipts for [ids] to the other device. Receipts asked for
  /// before the other device is ready are sent when it is.
  void sendReadReceipts(List<String> ids) {
    if (_ended || ids.isEmpty) return;
    if (!isReady) {
      _pendingReads.addAll(ids);
      return;
    }
    _writeReads(ids);
  }

  /// Receipts are sent in frames of at most this many ids, so a long history
  /// stays within the frame size limit.
  static const maxReceiptsPerFrame = 200;

  void _writeReads(Iterable<String> ids) {
    final all = ids.toList();
    for (var i = 0; i < all.length; i += maxReceiptsPerFrame) {
      final end = i + maxReceiptsPerFrame < all.length
          ? i + maxReceiptsPerFrame
          : all.length;
      _write(ReadFrame(ids: all.sublist(i, end)));
    }
  }

  /// Takes a message off the outbox, so it is not sent after it was deleted.
  void forget(String id) {
    _outbox.remove(id);
    _unsent.remove(id);
  }

  /// Takes every message off the outbox (the chat was deleted).
  void forgetAll() {
    _outbox.clear();
    _unsent.clear();
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
    final now = clock();
    for (final transfer in _incomingFiles.values.toList()) {
      if (now.difference(transfer.lastChunkAt) >= fileStallTimeout) {
        transfer.completionTimeout?.cancel();
        _incomingFiles.remove(transfer.id);
        _write(FileCancelFrame(id: transfer.id, reason: 'stalled'));
        await _failFile(transfer.id, 'stalled', 'failed');
      }
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
        // Any queued files waiting for this contact are offered now, once.
        await _offerQueuedFiles();
        if (_pendingReads.isNotEmpty) {
          _writeReads(_pendingReads);
          _pendingReads.clear();
        }
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
            arrivedAt: clock().millisecondsSinceEpoch,
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
        :final blocked,
        :final voice,
      ):
        if (!_peerHello) return;
        if (!_contactNow) {
          _write(const ByeFrame());
          await _end('not-contact');
          return;
        }
        if (!await store.contains(contactId, id)) {
          // Too large, of a blocked type, or a voice note the voice rules
          // refuse: declined, and nothing is kept. A plain file that is audio
          // is judged as a file.
          final refusedVoice =
              voice &&
              (voiceOfferRefused(mime: mime, size: size) ||
                  !voiceNameMatches(mime, name));
          final declined = size > maxFileBytes || blocked || refusedVoice;
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
            fileStatus: declined ? 'declined' : 'offered',
            arrivedAt: clock().millisecondsSinceEpoch,
            voiceNote: voice,
          );
          await store.add(message);
          _events.add(MessageReceived(message));
          if (declined) {
            _write(FileDeclineFrame(id: id));
          } else {
            _events.add(FileOfferReceived(message));
            if (_ended) return;
            if (voice) {
              // Voice notes from contacts always download.
              await acceptFile(id);
            } else if (_mayAutoAccept(size)) {
              _autoAcceptedBytes += size;
              await acceptFile(id);
            }
          }
        }
      case FileAcceptFrame(:final id):
        if (!_peerHello) return;
        // Only a file offered in this session, still offered, and only once:
        // a late accept after a cancel or decline, or a second accept, sends
        // nothing.
        if (!_offered.remove(id)) return;
        _sending.add(id);
        final existing = await store.find(contactId, id);
        if (existing == null ||
            !existing.outgoing ||
            !existing.isAttachment ||
            existing.fileStatus != 'offered') {
          _sending.remove(id);
          return;
        }
        Uint8List bytes;
        try {
          bytes = await store.readFile(existing);
        } catch (_) {
          await _stopSending(id, 'unavailable');
          return;
        }
        if (_ended || !_sending.contains(id)) return;
        await store.updateMessage(
          existing.copyWith(fileStatus: 'transferring'),
        );
        unawaited(
          _streamFileChunks(id, bytes).catchError((Object _) {
            // The error can hold a file name. It is not logged.
          }),
        );
      case FileDeclineFrame(:final id):
        if (!_peerHello) return;
        _offered.remove(id);
        _sending.remove(id);
        final existing = await store.find(contactId, id);
        if (existing != null &&
            existing.outgoing &&
            _stillOpen(existing.fileStatus)) {
          await store.updateMessage(existing.copyWith(fileStatus: 'declined'));
          _events.add(FileTransferFailed(id, 'declined'));
        }
      case FileDoneFrame(:final id):
        if (!_peerHello) return;
        final transfer = _incomingFiles[id];
        if (transfer == null) return;
        transfer.doneReceived = true;
        if (transfer.chunks.length == transfer.totalChunks) {
          _incomingFiles.remove(id);
          await _finishIncomingTransfer(transfer);
        } else {
          // If some binary chunks are still being dispatched/decoded in the
          // Web or mobile event loop, allow up to 5 seconds to arrive.
          transfer.completionTimeout ??= Timer(
            const Duration(seconds: 5),
            () async {
              if (_ended || !_incomingFiles.containsKey(id)) return;
              if (transfer.chunks.length != transfer.totalChunks) {
                _incomingFiles.remove(id);
                _write(FileCancelFrame(id: id, reason: 'incomplete'));
                final existing = await store.find(contactId, id);
                if (existing != null) {
                  await store.updateMessage(
                    existing.copyWith(fileStatus: 'failed'),
                  );
                }
                _events.add(FileTransferFailed(id, 'incomplete'));
              } else {
                _incomingFiles.remove(id);
                await _finishIncomingTransfer(transfer);
              }
            },
          );
        }
      case FileAckFrame(:final id):
        if (!_peerHello) return;
        if (!_sending.remove(id)) return;
        final existing = await store.find(contactId, id);
        if (existing != null && existing.outgoing) {
          await store.updateMessage(existing.copyWith(fileStatus: 'completed'));
        }
        _events.add(FileTransferCompleted(id, null));
      case FileCancelFrame(:final id, :final reason):
        _offered.remove(id);
        _sending.remove(id);
        final incoming = _incomingFiles.remove(id);
        incoming?.completionTimeout?.cancel();
        final existing = await store.find(contactId, id);
        if (existing != null && _stillOpen(existing.fileStatus)) {
          await store.updateMessage(existing.copyWith(fileStatus: 'cancelled'));
          _events.add(FileTransferFailed(id, reason ?? 'cancelled'));
        }
      case ByeFrame():
        await _end('bye');
    }
  }

  Future<void> _finishIncomingTransfer(_IncomingFileTransfer transfer) async {
    final id = transfer.id;
    transfer.completionTimeout?.cancel();
    final builder = BytesBuilder(copy: false);
    for (var i = 0; i < transfer.totalChunks; i++) {
      final chunk = transfer.chunks[i];
      if (chunk == null) {
        _write(FileCancelFrame(id: id, reason: 'missing-chunk'));
        final existing = await store.find(contactId, id);
        if (existing != null) {
          await store.updateMessage(existing.copyWith(fileStatus: 'failed'));
        }
        _events.add(FileTransferFailed(id, 'missing-chunk'));
        return;
      }
      builder.add(chunk);
    }
    final fullBytes = builder.takeBytes();
    final computedHash = sha256.convert(fullBytes).toString();
    // A voice note that does not look like its format is damaged, and is
    // never saved or played.
    final voiceDamaged =
        transfer.voice && !voiceBytesLookRight(transfer.mime, fullBytes);
    if (computedHash != transfer.sha256 || voiceDamaged) {
      _write(FileCancelFrame(id: id, reason: 'damaged'));
      final existing = await store.find(contactId, id);
      if (existing != null) {
        await store.updateMessage(existing.copyWith(fileStatus: 'failed'));
      }
      _events.add(FileTransferFailed(id, 'damaged'));
      return;
    }
    // The browser keeps nothing on disk, so it holds in memory with `web:` path.
    final files = store.files;
    final kept = files == null ? null : await files.save(fullBytes);
    if (kept == null) {
      // Held once: a voice note as one, any other file as a file.
      if (transfer.voice) {
        store.rememberVoice(id, fullBytes);
      } else {
        store.rememberFile(id, fullBytes);
      }
    }
    _write(FileAckFrame(id: id));
    final existing = await store.find(contactId, id);
    if (existing != null) {
      await store.updateMessage(
        existing.copyWith(
          fileStatus: 'completed',
          filePath: kept?.name ?? 'web:$id',
          fileKey: kept?.key,
        ),
      );
    } else {
      // Deleted while it was arriving: don't keep a file nobody can see.
      await files?.remove(kept?.name);
      store.forgetFile(id);
      store.forgetVoice(id);
    }
    _events.add(FileTransferCompleted(id, kept?.name));
  }

  /// Marks a file message as [status] and tells the screens why.
  Future<void> _failFile(String id, String reason, String status) async {
    final existing = await store.find(contactId, id);
    if (existing != null) {
      await store.updateMessage(existing.copyWith(fileStatus: status));
    }
    _emit(FileTransferFailed(id, reason));
  }

  /// Whether a file offered by the contact downloads without asking: the
  /// setting is on, the file is small enough, few enough transfers run, and
  /// this session's budget has room.
  bool _mayAutoAccept(int size) =>
      autoAcceptFiles() &&
      size <= autoAcceptMaxBytes &&
      size <= maxFileBytes &&
      _incomingFiles.length < autoAcceptMaxConcurrent &&
      _autoAcceptedBytes + size <= autoAcceptBudgetBytes;

  /// The file messages of this chat that can no longer go on: transfers in
  /// progress and offers nobody answered fail; incoming offers expire, since
  /// the sender's chat is gone and an accept would reach nobody.
  Future<void> _settleFiles(String reason) async {
    for (final message in await store.messages(contactId)) {
      final status = message.fileStatus;
      if (status != 'offered' && status != 'transferring') continue;
      // A queued file was never offered: it waits for the next session.
      if (message.outgoing && message.state == ChatState.queued) continue;
      if (!message.outgoing && status == 'offered') {
        await _failFile(message.id, reason, 'expired');
      } else {
        await _failFile(message.id, reason, 'failed');
      }
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
    await _settleFiles(reason);
    _offered.clear();
    _sending.clear();
    for (final transfer in _incomingFiles.values) {
      transfer.completionTimeout?.cancel();
    }
    _incomingFiles.clear();
    await _subscription?.cancel();
    await _binarySubscription?.cancel();
    await transport.close();
    _events.add(SessionEnded(reason));
    await _events.close();
  }
}
